import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/app_version.dart';

/// Where every desktop build is published. The repository is public, so the
/// request carries no token and no account of any kind — GitHub sees an
/// anonymous GET and rate-limits it per address.
final defaultLatestReleaseUri = Uri.parse(
  'https://api.github.com/repos/nks-hub/nks-nextcloud-talk/releases/latest',
);

/// `v0.1.0+62` — the release tag every build is published under. Only the
/// build number after the `+` decides which of two builds is newer; the
/// version name in front of it has not moved in a long time.
final _tagPattern = RegExp(r'^v?\d+\.\d+\.\d+\+(\d+)$');

/// `NKS-Talk-0.1.0-63-windows-x64-setup.exe` — the installer asset name for
/// every release, whatever its version and build.
final _windowsInstallerName = RegExp(r'^NKS-Talk-.*-windows-x64-setup\.exe$');

/// Whether this platform may check for a build at all.
///
/// Desktop only, and not as a preference: a build installed from Google Play
/// or the App Store is updated by the store, and pointing the person at a
/// download outside it breaks both stores' rules.
bool get isDesktopUpdateCheckPlatform {
  if (kIsWeb) {
    return false;
  }
  return switch (defaultTargetPlatform) {
    TargetPlatform.windows ||
    TargetPlatform.macOS ||
    TargetPlatform.linux => true,
    _ => false,
  };
}

/// What one check found.
sealed class UpdateCheckResult {
  const UpdateCheckResult();
}

/// Nothing newer is published. Also the answer for a build that is *ahead* of
/// the newest release, which is what a developer running their own build has.
final class UpdateUpToDate extends UpdateCheckResult {
  const UpdateUpToDate();
}

/// A newer build exists. [releaseUri] is the release page to open in a
/// browser. [windowsInstallerAssetUri] and [sha256SumsAssetUri] are set only
/// when the release carries a Windows installer and its checksum list — the
/// one platform this app ever downloads and runs something for; every other
/// platform only ever gets [releaseUri] to open by hand.
@immutable
final class UpdateAvailable extends UpdateCheckResult {
  const UpdateAvailable({
    required this.buildNumber,
    required this.name,
    required this.releaseUri,
    this.windowsInstallerAssetUri,
    this.sha256SumsAssetUri,
  });

  final int buildNumber;
  final String name;
  final Uri releaseUri;
  final Uri? windowsInstallerAssetUri;
  final Uri? sha256SumsAssetUri;
}

/// GitHub could not be asked, or answered something this cannot read. A
/// deliberately blunt single case: from the settings screen there is nothing
/// useful to say beyond "ask again later", and the reasons — offline, rate
/// limited, a redirect, a body that is not the release JSON — all lead there.
final class UpdateCheckUnavailable extends UpdateCheckResult {
  const UpdateCheckUnavailable();
}

/// Asks GitHub for the newest published release and compares its build number
/// with this one.
///
/// Everything is bounded: the whole exchange has one deadline, the body is
/// read with a ceiling instead of into memory unseen, and a redirect is never
/// followed — a 3xx would be some other host answering for the release list,
/// so it counts as no answer at all.
final class UpdateCheckService {
  UpdateCheckService({
    http.Client? client,
    Uri? latestReleaseUri,
    this.currentBuild = appBuildNumber,
    this.timeout = const Duration(seconds: 10),
    this.maximumResponseBytes = 128 * 1024,
  }) : _client = client ?? http.Client(),
       _uri = latestReleaseUri ?? defaultLatestReleaseUri;

  final http.Client _client;
  final Uri _uri;
  final String currentBuild;
  final Duration timeout;
  final int maximumResponseBytes;

  Future<UpdateCheckResult> check() async {
    final current = int.tryParse(currentBuild.trim());
    if (current == null) {
      return const UpdateCheckUnavailable();
    }
    try {
      return await _ask(current).timeout(timeout);
    } on Object {
      return const UpdateCheckUnavailable();
    }
  }

  void close() => _client.close();

  Future<UpdateCheckResult> _ask(int current) async {
    final request = http.Request('GET', _uri)
      ..headers.addAll(<String, String>{
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        // The REST API refuses a request without one, and naming the app is
        // more honest than hiding behind the default.
        'User-Agent': 'NKS-Talk/$appVersionName',
      })
      ..followRedirects = false
      ..maxRedirects = 0;

    final response = await _client.send(request);
    final body = await _readBounded(response);
    if (response.statusCode != 200) {
      return const UpdateCheckUnavailable();
    }

    final decoded = jsonDecode(body);
    if (decoded is! Map<String, Object?>) {
      return const UpdateCheckUnavailable();
    }
    final tag = decoded['tag_name'];
    if (tag is! String) {
      return const UpdateCheckUnavailable();
    }
    final published = _buildNumberOf(tag);
    if (published == null) {
      return const UpdateCheckUnavailable();
    }
    if (published <= current) {
      return const UpdateUpToDate();
    }

    final releaseUri = _releasePage(decoded['html_url']);
    if (releaseUri == null) {
      return const UpdateCheckUnavailable();
    }
    final name = decoded['name'];
    final (installer, sums) = _windowsAssets(decoded['assets']);
    return UpdateAvailable(
      buildNumber: published,
      name: name is String && name.trim().isNotEmpty ? name.trim() : tag,
      releaseUri: releaseUri,
      windowsInstallerAssetUri: installer,
      sha256SumsAssetUri: sums,
    );
  }

  /// Picks the Windows installer and its `SHA256SUMS` list out of the
  /// release's asset array, if both are there. Every asset URL goes through
  /// the same GitHub-only check as the release page: [UpdateInstallerService]
  /// downloads real bytes from whatever this returns, so a stray asset
  /// pointing off GitHub must never survive this far.
  (Uri?, Uri?) _windowsAssets(Object? assets) {
    if (assets is! List<Object?>) {
      return (null, null);
    }
    Uri? installer;
    Uri? sums;
    for (final asset in assets) {
      if (asset is! Map<String, Object?>) {
        continue;
      }
      final name = asset['name'];
      final uri = _releasePage(asset['browser_download_url']);
      if (name is! String || uri == null) {
        continue;
      }
      if (name == 'SHA256SUMS') {
        sums = uri;
      } else if (_windowsInstallerName.hasMatch(name)) {
        installer = uri;
      }
    }
    return (installer, sums);
  }

  Future<String> _readBounded(http.StreamedResponse response) async {
    if ((response.contentLength ?? 0) > maximumResponseBytes) {
      throw const FormatException('The release answer is too large to read.');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      bytes.add(chunk);
      if (bytes.length > maximumResponseBytes) {
        throw const FormatException('The release answer is too large to read.');
      }
    }
    return utf8.decode(bytes.takeBytes());
  }

  int? _buildNumberOf(String tag) {
    final match = _tagPattern.firstMatch(tag.trim());
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  /// The page handed to the browser has to be a GitHub release page. This is
  /// the one value here that turns into an action, so a link pointing
  /// anywhere else is treated as no answer rather than opened.
  Uri? _releasePage(Object? value) {
    if (value is! String) {
      return null;
    }
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'https' || uri.host != 'github.com') {
      return null;
    }
    return uri;
  }
}
