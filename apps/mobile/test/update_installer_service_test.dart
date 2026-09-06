import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/features/settings/update_check_service.dart';
import 'package:nextcloudtalk/features/settings/update_installer_service.dart';

void main() {
  const installerName = 'NKS-Talk-0.1.0-63-windows-x64-setup.exe';
  final installerUri = Uri.parse(
    'https://github.com/nks-hub/nks-nextcloud-talk/releases/download/'
    'v0.1.0%2B63/$installerName',
  );
  final sumsUri = Uri.parse(
    'https://github.com/nks-hub/nks-nextcloud-talk/releases/download/'
    'v0.1.0%2B63/SHA256SUMS',
  );
  final installerBytes = utf8.encode(
    'fake NKS Talk installer bytes for the update installer test suite',
  );
  final installerHash = sha256.convert(installerBytes).toString();

  UpdateAvailable release({Uri? installer, Uri? sums}) => UpdateAvailable(
    buildNumber: 63,
    name: 'Build 63',
    releaseUri: Uri.parse(
      'https://github.com/nks-hub/nks-nextcloud-talk/releases/tag/v0.1.0%2B63',
    ),
    windowsInstallerAssetUri: installer ?? installerUri,
    sha256SumsAssetUri: sums ?? sumsUri,
  );

  UpdateInstallerService service(
    MockClient client, {
    Duration downloadTimeout = const Duration(seconds: 5),
    int maximumInstallerBytes = 64 * 1024 * 1024,
  }) {
    final built = UpdateInstallerService(
      client: client,
      downloadTimeout: downloadTimeout,
      maximumInstallerBytes: maximumInstallerBytes,
    );
    addTearDown(built.close);
    return built;
  }

  http.Response respondTo(
    http.BaseRequest request, {
    required String sumsBody,
  }) {
    if (request.url.pathSegments.last == 'SHA256SUMS') {
      return http.Response(sumsBody, 200);
    }
    if (request.url.pathSegments.last == installerName) {
      return http.Response.bytes(
        installerBytes,
        200,
        headers: {'content-length': '${installerBytes.length}'},
      );
    }
    return http.Response('not found', 404);
  }

  void forcePlatform(TargetPlatform platform) {
    debugDefaultTargetPlatformOverride = platform;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
  }

  Iterable<Directory> leftoverTempDirs() => Directory.systemTemp
      .listSync()
      .whereType<Directory>()
      .where((d) => d.path.contains('nks-talk-update-'));

  setUp(() => forcePlatform(TargetPlatform.windows));

  test('a good download is verified and offered to install', () async {
    final before = leftoverTempDirs().toList();
    final progress = <int>[];
    final result =
        await service(
          MockClient(
            (request) async => respondTo(
              request,
              sumsBody: '$installerHash  $installerName\n',
            ),
          ),
        ).downloadAndVerify(
          release: release(),
          onProgress: (received, total) => progress.add(received),
        );

    expect(result, isA<UpdateInstallReady>());
    final ready = result as UpdateInstallReady;
    expect(await ready.installerFile.readAsBytes(), installerBytes);
    expect(progress, isNotEmpty);
    expect(progress.last, installerBytes.length);

    addTearDown(() {
      final leftover = leftoverTempDirs().where(
        (d) => !before.map((b) => b.path).contains(d.path),
      );
      for (final dir in leftover) {
        dir.deleteSync(recursive: true);
      }
    });
  });

  test('a checksum mismatch is refused and the download is deleted', () async {
    final before = leftoverTempDirs().map((d) => d.path).toSet();
    final result = await service(
      MockClient(
        (request) async => respondTo(
          request,
          // 64 hex characters that are simply not this file's hash.
          sumsBody: '${'0' * 64}  $installerName\n',
        ),
      ),
    ).downloadAndVerify(release: release());

    expect(result, isA<UpdateInstallVerificationFailed>());
    final after = leftoverTempDirs().map((d) => d.path).toSet();
    expect(
      after.difference(before),
      isEmpty,
      reason: 'the mismatched download must not be left behind',
    );
  });

  test('a SHA256SUMS that does not list the installer is refused', () async {
    final before = leftoverTempDirs().map((d) => d.path).toSet();
    final result = await service(
      MockClient(
        (request) async =>
            respondTo(request, sumsBody: '${'a' * 64}  some-other-file.exe\n'),
      ),
    ).downloadAndVerify(release: release());

    expect(result, isA<UpdateInstallVerificationFailed>());
    final after = leftoverTempDirs().map((d) => d.path).toSet();
    expect(after.difference(before), isEmpty);
  });

  test(
    'a non-GitHub asset host is refused before any request is sent',
    () async {
      final result =
          await service(
            MockClient((request) async {
              fail('must never contact ${request.url}');
            }),
          ).downloadAndVerify(
            release: release(
              installer: Uri.parse('https://malicious.invalid/x.exe'),
            ),
          );

      expect(result, isA<UpdateInstallUnavailable>());
    },
  );

  test('cancelling mid-download refuses and deletes what arrived', () async {
    final before = leftoverTempDirs().map((d) => d.path).toSet();
    final stalled = Completer<http.Response>();
    addTearDown(() {
      if (!stalled.isCompleted) {
        stalled.complete(http.Response.bytes(installerBytes, 200));
      }
    });
    final cancellation = DownloadCancellation();

    final future = service(
      MockClient((request) async {
        if (request.url.pathSegments.last == 'SHA256SUMS') {
          return http.Response('$installerHash  $installerName\n', 200);
        }
        return stalled.future;
      }),
    ).downloadAndVerify(release: release(), cancellation: cancellation);

    await Future<void>.delayed(Duration.zero);
    cancellation.cancel();
    stalled.complete(
      http.Response.bytes(
        installerBytes,
        200,
        headers: {'content-length': '${installerBytes.length}'},
      ),
    );

    final result = await future;
    expect(result, isA<UpdateInstallCancelled>());
    final after = leftoverTempDirs().map((d) => d.path).toSet();
    expect(after.difference(before), isEmpty);
  });

  test('macOS and Linux never download, even with a valid installer', () async {
    for (final platform in const [TargetPlatform.macOS, TargetPlatform.linux]) {
      debugDefaultTargetPlatformOverride = platform;
      final result = await service(
        MockClient(
          (request) async => fail('must never contact ${request.url}'),
        ),
      ).downloadAndVerify(release: release());

      expect(
        result,
        isA<UpdateInstallUnavailable>(),
        reason: '$platform must not download an installer',
      );
    }
    debugDefaultTargetPlatformOverride = null;
  });

  test('starting a file that is not a real installer fails cleanly', () async {
    final dir = await Directory.systemTemp.createTemp('nks-talk-update-test-');
    addTearDown(() => dir.delete(recursive: true));
    final bogus = File('${dir.path}${Platform.pathSeparator}bogus.exe');
    await bogus.writeAsBytes(installerBytes);

    final started = await service(
      MockClient((request) async => fail('must never contact ${request.url}')),
    ).runInstaller(UpdateInstallReady(bogus));

    expect(started, isFalse);
  });
}
