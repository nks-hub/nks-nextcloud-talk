import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/features/settings/update_check_service.dart';

void main() {
  UpdateCheckService service(
    MockClient client, {
    String currentBuild = '62',
    Duration timeout = const Duration(seconds: 5),
    int maximumResponseBytes = 128 * 1024,
  }) {
    final built = UpdateCheckService(
      client: client,
      currentBuild: currentBuild,
      timeout: timeout,
      maximumResponseBytes: maximumResponseBytes,
    );
    addTearDown(built.close);
    return built;
  }

  http.Response release(
    String tag, {
    String name = 'NKS Talk',
    String htmlUrl =
        'https://github.com/nks-hub/nks-nextcloud-talk/releases/tag/v0.1.0%2B63',
    List<Map<String, Object?>>? assets,
  }) {
    return http.Response(
      jsonEncode(<String, Object?>{
        'tag_name': tag,
        'name': name,
        'html_url': htmlUrl,
        'assets': ?assets,
      }),
      200,
      headers: const {'content-type': 'application/json'},
    );
  }

  Map<String, Object?> asset(String name, String url) => <String, Object?>{
    'name': name,
    'browser_download_url': url,
  };

  test('a newer build is offered with its number, name and page', () async {
    late http.BaseRequest sent;
    final result = await service(
      MockClient((request) async {
        sent = request;
        return release('v0.1.0+63', name: 'Build 63');
      }),
    ).check();

    expect(result, isA<UpdateAvailable>());
    final available = result as UpdateAvailable;
    expect(available.buildNumber, 63);
    expect(available.name, 'Build 63');
    expect(
      available.releaseUri.toString(),
      'https://github.com/nks-hub/nks-nextcloud-talk/releases/tag/v0.1.0%2B63',
    );
    expect(sent.url, defaultLatestReleaseUri);
    expect(sent.followRedirects, isFalse);
    expect(sent.headers['User-Agent'], startsWith('NKS-Talk/'));
  });

  test('the same build is up to date', () async {
    expect(
      await service(MockClient((_) async => release('v0.1.0+62'))).check(),
      isA<UpdateUpToDate>(),
    );
  });

  test('a release older than this build is up to date, never a downgrade', () {
    return expectLater(
      service(MockClient((_) async => release('v0.1.0+61'))).check(),
      completion(isA<UpdateUpToDate>()),
    );
  });

  test('a tag that is not a build number is no answer at all', () async {
    for (final tag in const <String>[
      'nightly',
      'v0.1.0',
      'v0.1.0+',
      'v0.1.0+beta',
      '0.1+63',
    ]) {
      expect(
        await service(MockClient((_) async => release(tag))).check(),
        isA<UpdateCheckUnavailable>(),
        reason: 'tag "$tag" must not be read as a build number',
      );
    }
  });

  test('a server that never answers gives up on the deadline', () async {
    final stalled = Completer<http.Response>();
    addTearDown(() {
      if (!stalled.isCompleted) {
        stalled.complete(http.Response('', 200));
      }
    });

    final result = await service(
      MockClient((_) => stalled.future),
      timeout: const Duration(milliseconds: 50),
    ).check();

    expect(result, isA<UpdateCheckUnavailable>());
  });

  test('a non-200 is never read as a release', () async {
    for (final status in const <int>[301, 403, 404, 429, 500]) {
      expect(
        await service(
          MockClient(
            (_) async => http.Response('{"tag_name":"v0.1.0+99"}', status),
          ),
        ).check(),
        isA<UpdateCheckUnavailable>(),
        reason: 'status $status must not offer a build',
      );
    }
  });

  test('a body past the ceiling is dropped instead of read', () async {
    final result = await service(
      MockClient(
        (_) async => http.Response(
          jsonEncode(<String, Object?>{
            'tag_name': 'v0.1.0+63',
            'name': 'x' * 4096,
            'html_url':
                'https://github.com/nks-hub/nks-nextcloud-talk/releases/'
                'tag/v0.1.0',
          }),
          200,
        ),
      ),
      maximumResponseBytes: 512,
    ).check();

    expect(result, isA<UpdateCheckUnavailable>());
  });

  test('a release page pointing off GitHub is not offered', () async {
    final result = await service(
      MockClient(
        (_) async =>
            release('v0.1.0+63', htmlUrl: 'https://example.invalid/release'),
      ),
    ).check();

    expect(result, isA<UpdateCheckUnavailable>());
  });

  test('the Windows installer and its checksum list are picked out of the '
      'asset array', () async {
    final result = await service(
      MockClient(
        (_) async => release(
          'v0.1.0+63',
          assets: [
            asset(
              'NKS-Talk-0.1.0-63-windows-x64-setup.exe',
              'https://github.com/nks-hub/nks-nextcloud-talk/releases/'
                  'download/v0.1.0%2B63/'
                  'NKS-Talk-0.1.0-63-windows-x64-setup.exe',
            ),
            asset(
              'SHA256SUMS',
              'https://github.com/nks-hub/nks-nextcloud-talk/releases/'
                  'download/v0.1.0%2B63/SHA256SUMS',
            ),
            asset(
              'nks-talk-linux-x64.tar.gz',
              'https://github.com/nks-hub/nks-nextcloud-talk/releases/'
                  'download/v0.1.0%2B63/nks-talk-linux-x64.tar.gz',
            ),
          ],
        ),
      ),
    ).check();

    final available = result as UpdateAvailable;
    expect(
      available.windowsInstallerAssetUri.toString(),
      'https://github.com/nks-hub/nks-nextcloud-talk/releases/download/'
      'v0.1.0%2B63/NKS-Talk-0.1.0-63-windows-x64-setup.exe',
    );
    expect(
      available.sha256SumsAssetUri.toString(),
      'https://github.com/nks-hub/nks-nextcloud-talk/releases/download/'
      'v0.1.0%2B63/SHA256SUMS',
    );
  });

  test('no assets means no installer to offer, not a broken check', () async {
    final result = await service(
      MockClient((_) async => release('v0.1.0+63')),
    ).check();

    final available = result as UpdateAvailable;
    expect(available.windowsInstallerAssetUri, isNull);
    expect(available.sha256SumsAssetUri, isNull);
  });

  test('an installer asset pointing off GitHub is never offered', () async {
    final result = await service(
      MockClient(
        (_) async => release(
          'v0.1.0+63',
          assets: [
            asset(
              'NKS-Talk-0.1.0-63-windows-x64-setup.exe',
              'https://malicious.invalid/NKS-Talk-0.1.0-63-windows-x64-setup.exe',
            ),
            asset(
              'SHA256SUMS',
              'https://github.com/nks-hub/nks-nextcloud-talk/releases/'
                  'download/v0.1.0%2B63/SHA256SUMS',
            ),
          ],
        ),
      ),
    ).check();

    final available = result as UpdateAvailable;
    expect(available.windowsInstallerAssetUri, isNull);
    expect(available.sha256SumsAssetUri, isNotNull);
  });
}
