import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/chat_media_cache.dart';
import 'package:nextcloudtalk/features/chat/composer/emoji_usage_store.dart';
import 'package:nextcloudtalk/features/settings/account_removal_service.dart';
import 'package:nextcloudtalk/features/settings/app_password_revocation_queue.dart';
import 'package:nextcloudtalk/network/account_http_client.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:nextcloudtalk/platform/media/durable_attachment_source_store.dart';

import 'test_support.dart';

enum _RetryScenario { approved, certificateChanged, redirect }

typedef _Certificate = ({SecurityContext context, String fingerprint});

Future<void> main() async {
  final openssl = await _findOpenSsl();
  for (final (scenario, name) in [
    (
      _RetryScenario.approved,
      'revocation retries the approved TLS server after account removal',
    ),
    (
      _RetryScenario.certificateChanged,
      'revocation refuses a replacement certificate trusted by another account',
    ),
    (
      _RetryScenario.redirect,
      'revocation refuses a TLS redirect and keeps the pending entry',
    ),
  ]) {
    test(
      name,
      () => _testRetry(openssl!, scenario),
      skip: openssl == null ? 'OpenSSL is unavailable for loopback TLS' : false,
    );
  }
}

Future<String?> _findOpenSsl() async {
  final executable = Platform.isWindows ? 'openssl.exe' : 'openssl';
  try {
    final result = await Process.run(executable, ['version']);
    return result.exitCode == 0 ? executable : null;
  } on ProcessException {
    return null;
  }
}

Future<void> _testRetry(String openssl, _RetryScenario scenario) async {
  final root = await Directory.systemTemp.createTemp('revocation-tls-test-');
  addTearDown(() => root.delete(recursive: true));
  final approved = await _certificate(openssl, root, 'approved');
  final replacement = scenario == _RetryScenario.certificateChanged
      ? await _certificate(openssl, root, 'replacement')
      : null;
  final endpoint = await _listen(approved.context);
  final port = endpoint.port;
  final revocations = <String>[];
  final redirected = <String>[];
  _respond(endpoint, revocations, (count) {
    if (count == 1) return HttpStatus.serviceUnavailable;
    if (scenario == _RetryScenario.redirect && count == 2) {
      return HttpStatus.seeOther;
    }
    return HttpStatus.ok;
  }, redirected: redirected);
  final serverUrl = 'https://127.0.0.1:$port';
  final database = openTestDatabase();
  addTearDown(database.close);
  final accounts = AccountRepository(database);
  final vault = MemoryCredentialVault();
  const accountId = 'fixture-account';
  Future<void> saveAccount(String id, String fingerprint) async {
    await accounts.upsertAccount(
      accountId: id,
      serverUrl: serverUrl,
      loginName: id,
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026),
      certificateFingerprint: fingerprint,
    );
  }

  await saveAccount(accountId, approved.fingerprint);
  if (replacement != null) {
    await saveAccount('second-account', replacement.fingerprint);
  }
  await vault.writeAppPassword(accountId, 'fixture-password');

  final gate = CertificateTrustGate(
    loadStoredPins: accounts.readCertificatePins,
  );
  await gate.refresh();
  final api = HttpNextcloudApi(client: gate.createClient());
  final queue = AppPasswordRevocationQueue(store: vault, api: api);
  final removal = AccountRemovalService(
    accounts: accounts,
    credentials: vault,
    api: api,
    mediaCache: ChatMediaCache(),
    mediaDiskCache: ChatMediaDiskCache(
      rootDirectory: () async => Directory('${root.path}/previews'),
    ),
    emojiUsage: FileEmojiUsageStore(directory: Directory('${root.path}/emoji')),
    clearChatBackgrounds: (_) async {},
    voiceDirectory: () async => Directory('${root.path}/voice'),
    chatAttachmentDirectory: () async => Directory('${root.path}/attachments'),
    attachmentSources: () async =>
        DurableAttachmentSourceStore(root: Directory('${root.path}/sources')),
    pendingRevocations: queue,
    onAccountPurged: (_) => gate.refresh(),
  );
  final AccountRemovalOutcome removed;
  try {
    removed = await removal.removeAccount(accountId);
  } finally {
    api.close();
  }

  expect(removed.appPasswordRevoked, isFalse);
  expect(revocations, ['DELETE']);
  expect(await queue.pendingRevocationCount(), 1);
  expect(await accounts.getAccount(accountId), isNull);
  expect(await accounts.readCertificatePins(), {
    if (replacement != null) '127.0.0.1': {replacement.fingerprint},
  });
  expect(await vault.readAppPassword(accountId), isNull);

  final retryGate = CertificateTrustGate(
    loadStoredPins: accounts.readCertificatePins,
  );
  await retryGate.refresh();
  final retryApi = HttpNextcloudApi(client: retryGate.createClient());
  addTearDown(retryApi.close);
  final restarted = AppPasswordRevocationQueue(
    store: vault,
    api: retryApi,
    accounts: accounts,
    credentials: vault,
  );
  if (replacement != null) {
    await endpoint.close(force: true);
    final changed = await _listen(replacement.context, port: port);
    final unexpected = <String>[];
    _respond(changed, unexpected, (_) => HttpStatus.ok);
    await restarted.drain();
    expect(unexpected, isEmpty);
    expect(await restarted.pendingRevocationCount(), 1);
    await changed.close(force: true);
    final restored = await _listen(approved.context, port: port);
    _respond(restored, revocations, (_) => HttpStatus.unauthorized);
  } else if (scenario == _RetryScenario.redirect) {
    await restarted.drain();
    expect(revocations, ['DELETE', 'DELETE']);
    expect(redirected, isEmpty);
    expect(await restarted.pendingRevocationCount(), 1);
  }
  await restarted.drain();

  expect(revocations, [
    'DELETE',
    'DELETE',
    if (scenario == _RetryScenario.redirect) 'DELETE',
  ]);
  expect(await restarted.pendingRevocationCount(), 0);
  final ordinaryClient = retryGate.createClient();
  addTearDown(ordinaryClient.close);
  await expectLater(
    ordinaryClient.get(Uri.parse(serverUrl)),
    throwsA(anyOf(isA<HandshakeException>(), isA<http.ClientException>())),
  );
}

Future<_Certificate> _certificate(
  String openssl,
  Directory root,
  String name,
) async {
  final configuration = File('${root.path}/$name.cnf');
  await configuration.writeAsString('''
[req]
prompt = no
distinguished_name = subject
x509_extensions = extensions
[subject]
CN = TLS fixture
[extensions]
subjectAltName = IP:127.0.0.1
''');
  final key = File('${root.path}/$name.key');
  final certificate = File('${root.path}/$name.pem');
  final result = await Process.run(openssl, [
    'req',
    '-new',
    '-x509',
    '-newkey',
    'rsa:2048',
    '-nodes',
    '-days',
    '1',
    '-keyout',
    key.path,
    '-out',
    certificate.path,
    '-config',
    configuration.path,
  ]);
  expect(result.exitCode, 0, reason: result.stderr as String);
  final context = SecurityContext(withTrustedRoots: false)
    ..useCertificateChain(certificate.path)
    ..usePrivateKey(key.path);
  final der = base64Decode(
    (await certificate.readAsString()).replaceAll(
      RegExp(r'-----[^-]+-----|\s+'),
      '',
    ),
  );
  return (context: context, fingerprint: certificateFingerprint(der));
}

Future<HttpServer> _listen(SecurityContext context, {int port = 0}) async {
  final server = await HttpServer.bindSecure(
    InternetAddress.loopbackIPv4,
    port,
    context,
  );
  addTearDown(() => server.close(force: true));
  return server;
}

void _respond(
  HttpServer server,
  List<String> revocations,
  int Function(int) status, {
  List<String>? redirected,
}) {
  server.listen((request) async {
    if (request.uri.path == '/ocs/v2.php/core/apppassword') {
      revocations.add(request.method);
      request.response.statusCode = status(revocations.length);
      if (request.response.statusCode == HttpStatus.seeOther) {
        request.response.headers.set(HttpHeaders.locationHeader, '/redirected');
      }
    } else if (request.uri.path == '/redirected') {
      redirected?.add(request.method);
    }
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      '{"ocs":{"meta":{"status":"ok","statuscode":200},"data":[]}}',
    );
    await request.response.close();
  });
}
