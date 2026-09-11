import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nextcloudtalk/features/settings/update_check_service.dart';
import 'package:nextcloudtalk/features/settings/update_installer_service.dart';

void main() {
  const installerName = 'transfer-test-setup.exe';
  final release = UpdateAvailable(
    buildNumber: 65,
    name: 'Build 65',
    releaseUri: Uri.parse('https://github.com/example/talk/releases/tag/v65'),
    installerAssetUri: Uri.parse(
      'https://github.com/example/talk/releases/download/v65/$installerName',
    ),
    sha256SumsAssetUri: Uri.parse(
      'https://github.com/example/talk/releases/download/v65/SHA256SUMS',
    ),
  );

  Set<String> temporaryDirectories() => Directory.systemTemp
      .listSync()
      .whereType<Directory>()
      .where((directory) => directory.path.contains('nks-talk-update-'))
      .map((directory) => directory.path)
      .toSet();

  setUp(() async {
    final previousOverrides = IOOverrides.current;
    final temporary = await Directory.systemTemp.createTemp(
      'talk-transfer-tests-',
    );
    IOOverrides.global = _TransferDirectories(temporary);
    addTearDown(() async {
      IOOverrides.global = previousOverrides;
      await temporary.delete(recursive: true);
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
  });

  test('a cancelled transfer does not close the next download', () async {
    final before = temporaryDirectories();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final waiting = Completer<void>();
    final bytes = utf8.encode('installer transfer retry');
    final digest = sha256.convert(bytes);
    final service = UpdateInstallerService(
      clientFactory: () => _LoopbackClient(server.port),
    );
    var requests = 0;
    addTearDown(() async {
      service.close();
      await server.close(force: true);
      for (final path in temporaryDirectories().difference(before)) {
        await Directory(path).delete(recursive: true);
      }
    });
    server.listen((request) async {
      if (requests++ == 0) {
        waiting.complete();
        return;
      }
      if (request.uri.path.endsWith('SHA256SUMS')) {
        request.response.write('$digest  $installerName\n');
      } else {
        request.response.add(bytes);
      }
      await request.response.close();
    });
    final cancellation = DownloadCancellation();
    final first = service.downloadAndVerify(
      release: release,
      cancellation: cancellation,
    );
    await waiting.future.timeout(const Duration(seconds: 2));
    cancellation.cancel();
    expect(await first, isA<UpdateInstallCancelled>());
    expect(temporaryDirectories().difference(before), isEmpty);
    final retry = await service.downloadAndVerify(release: release);
    expect(retry, isA<UpdateInstallReady>());
    expect(await (retry as UpdateInstallReady).installerFile.readAsBytes(), bytes);
  });

  for (final stop in ['cancel', 'deadline', 'close']) {
    test('$stop returns while the TLS handshake is stalled', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      final hello = Completer<void>();
      final client = _LoopbackClient(server.port, tls: true);
      final service = UpdateInstallerService(
        clientFactory: () => client,
        downloadTimeout: stop == 'deadline'
            ? const Duration(milliseconds: 250)
            : const Duration(seconds: 5),
      );
      addTearDown(() async {
        service.close();
        for (final socket in sockets) {
          socket.destroy();
        }
        await server.close();
      });
      server.listen((socket) {
        sockets.add(socket);
        socket.listen((_) {
          if (!hello.isCompleted) hello.complete();
          // Accept ClientHello but never answer the handshake.
        });
      });
      final cancellation = DownloadCancellation();
      final operation = service.downloadAndVerify(
        release: release,
        cancellation: cancellation,
      );
      await hello.future.timeout(const Duration(seconds: 2));
      if (stop == 'cancel') cancellation.cancel();
      if (stop == 'close') service.close();
      final result = await operation.timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw TimeoutException('TLS operation did not finish'),
      );
      expect(
        result,
        stop == 'deadline'
            ? isA<UpdateInstallUnavailable>()
            : isA<UpdateInstallCancelled>(),
      );
      // Dart's SecureSocket.startConnect cannot close a pending handshake.
      // This proves bounded completion only; tearDown owns the stalled peer.
    });
  }

  for (final phase in ['checksum headers', 'checksum body', 'installer body']) {
    for (final stop in ['cancel', 'deadline', 'close']) {
      test('$stop stops $phase', () async {
        final before = temporaryDirectories();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final waiting = Completer<void>();
        final client = _LoopbackClient(server.port);
        final service = UpdateInstallerService(
          clientFactory: () => client,
          downloadTimeout: stop == 'deadline'
              ? const Duration(milliseconds: 250)
              : const Duration(seconds: 5),
        );
        addTearDown(() async {
          service.close();
          await server.close(force: true);
          for (final path in temporaryDirectories().difference(before)) {
            await Directory(path).delete(recursive: true);
          }
        });
        server.listen((request) async {
          if (phase == 'installer body' &&
              request.uri.path.endsWith('SHA256SUMS')) {
            request.response.write('${'0' * 64}  $installerName\n');
            await request.response.close();
            return;
          }
          if (phase != 'checksum headers') {
            request.response.bufferOutput = false;
            request.response.write('partial');
            await request.response.flush();
          }
          waiting.complete();
          // Leave the response open: cancellation must not need another chunk.
        });

        final cancellation = DownloadCancellation();
        final operation = service.downloadAndVerify(
          release: release,
          cancellation: cancellation,
        );
        await waiting.future.timeout(const Duration(seconds: 2));
        if (stop == 'cancel') cancellation.cancel();
        if (stop == 'close') service.close();
        final result = await operation.timeout(const Duration(seconds: 2));
        expect(
          result,
          stop == 'deadline'
              ? isA<UpdateInstallUnavailable>()
              : isA<UpdateInstallCancelled>(),
        );
        expect(client.closed, isTrue);
        expect(temporaryDirectories().difference(before), isEmpty);
      });
    }
  }
}

final class _TransferDirectories extends IOOverrides {
  _TransferDirectories(this.temporary);

  final Directory temporary;

  @override
  Directory getSystemTempDirectory() => temporary;
}

/// Sends through a real socket while keeping release URL validation enabled.
final class _LoopbackClient extends http.BaseClient {
  _LoopbackClient(this.port, {this.tls = false});

  final int port;
  final bool tls;
  final http.Client _inner = http.Client();
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final local = http.AbortableRequest(
      request.method,
      request.url.replace(
        scheme: tls ? 'https' : 'http',
        host: '127.0.0.1',
        port: port,
      ),
      abortTrigger: request is http.Abortable ? request.abortTrigger : null,
    )..headers.addAll(request.headers);
    return _inner.send(local);
  }

  @override
  void close() {
    closed = true;
    _inner.close();
  }
}
