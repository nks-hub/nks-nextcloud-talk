import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/app_version.dart';
import 'update_check_service.dart';

/// Whether this platform may download and run an update itself.
///
/// Windows only. macOS would need a notarised build to run something it just
/// downloaded without Gatekeeper refusing it outright, and this app is not
/// notarised for that — so macOS only ever gets the release page to open by
/// hand, same as [isDesktopUpdateCheckPlatform] intends for every store
/// build. Linux gets a tarball with no installer to run either; a link to the
/// release is the honest answer there too.
// ponytail: a Linux .desktop/AppImage installer is real work for a platform
// with no single packaging convention; offering only the release link is the
// correct lazy choice, not a shortcut taken to avoid it.
bool get canDownloadAndInstallUpdate {
  if (kIsWeb) {
    return false;
  }
  return defaultTargetPlatform == TargetPlatform.windows;
}

/// Hosts a real GitHub release asset may live on. `browser_download_url`
/// always starts on `github.com`, which then answers with a redirect to the
/// asset storage host — refusing every redirect outright would make it
/// impossible to ever download the real file, so redirects are allowed only
/// onto hosts GitHub itself controls.
bool _isGitHubControlledHost(Uri uri) {
  if (uri.scheme != 'https') {
    return false;
  }
  final host = uri.host;
  return host == 'github.com' ||
      host == 'api.github.com' ||
      host.endsWith('.githubusercontent.com');
}

/// Lets a caller stop an in-progress download. Checked between chunks rather
/// than closing a socket outright, which is enough for a person pressing
/// "cancel" and keeps the download loop simple to reason about.
final class DownloadCancellation {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

final class _Cancelled implements Exception {
  const _Cancelled();
}

/// What [UpdateInstallerService.downloadAndVerify] found.
sealed class UpdateInstallResult {
  const UpdateInstallResult();
}

/// Downloaded and its `SHA256SUMS` entry matched — safe to run.
final class UpdateInstallReady extends UpdateInstallResult {
  const UpdateInstallReady(this.installerFile);

  final File installerFile;
}

/// Either the bytes did not hash to the value `SHA256SUMS` published for this
/// file, or that file was never listed there at all. Both mean the same
/// thing: this is not a download to trust, so nothing downloaded survives
/// this result — [UpdateInstallerService] deletes it before returning.
final class UpdateInstallVerificationFailed extends UpdateInstallResult {
  const UpdateInstallVerificationFailed();
}

/// The person cancelled while it was in flight.
final class UpdateInstallCancelled extends UpdateInstallResult {
  const UpdateInstallCancelled();
}

/// GitHub could not be asked, the asset list was missing what this needs, or
/// the download failed outright. Blunt on purpose, same reasoning as
/// [UpdateCheckUnavailable].
final class UpdateInstallUnavailable extends UpdateInstallResult {
  const UpdateInstallUnavailable();
}

/// Downloads the Windows installer for a release [UpdateAvailable] found,
/// verifies it against the release's `SHA256SUMS` before anything is allowed
/// to run, and starts it once — never silently, always at the caller's
/// explicit request.
///
/// Every network hop is bounded the same way [UpdateCheckService] bounds its
/// own request: a deadline, a byte ceiling, and a host allow-list a redirect
/// may never leave.
final class UpdateInstallerService {
  UpdateInstallerService({
    http.Client? client,
    this.downloadTimeout = const Duration(minutes: 5),
    this.maximumInstallerBytes = 64 * 1024 * 1024,
    this.maximumSha256SumsBytes = 16 * 1024,
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final Duration downloadTimeout;
  final int maximumInstallerBytes;
  final int maximumSha256SumsBytes;

  static const _maxRedirects = 5;
  static final _sha256SumsLine = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+)$');

  void close() => _client.close();

  /// Downloads the installer [release] points at, fetches the release's
  /// `SHA256SUMS`, and refuses to hand back a file whose hash does not match
  /// the line published for it.
  Future<UpdateInstallResult> downloadAndVerify({
    required UpdateAvailable release,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    DownloadCancellation? cancellation,
  }) async {
    final installerUri = release.windowsInstallerAssetUri;
    final sumsUri = release.sha256SumsAssetUri;
    if (!canDownloadAndInstallUpdate ||
        installerUri == null ||
        sumsUri == null ||
        !_isGitHubControlledHost(installerUri) ||
        !_isGitHubControlledHost(sumsUri)) {
      return const UpdateInstallUnavailable();
    }
    final cancel = cancellation ?? DownloadCancellation();
    final fileName = _assetFileName(installerUri);

    try {
      return await _downloadAndVerify(
        installerUri: installerUri,
        sumsUri: sumsUri,
        fileName: fileName,
        onProgress: onProgress,
        cancellation: cancel,
      ).timeout(downloadTimeout);
    } on _Cancelled {
      return const UpdateInstallCancelled();
    } on Object {
      return const UpdateInstallUnavailable();
    }
  }

  /// Starts the verified installer. Only ever called with an
  /// [UpdateInstallReady] the caller itself obtained from
  /// [downloadAndVerify], so nothing reaches [Process.start] without having
  /// passed the checksum check first.
  Future<bool> runInstaller(UpdateInstallReady ready) async {
    try {
      await Process.start(
        ready.installerFile.path,
        const <String>[],
        mode: ProcessStartMode.detached,
      );
      return true;
    } on Object {
      return false;
    }
  }

  Future<UpdateInstallResult> _downloadAndVerify({
    required Uri installerUri,
    required Uri sumsUri,
    required String fileName,
    required void Function(int receivedBytes, int? totalBytes)? onProgress,
    required DownloadCancellation cancellation,
  }) async {
    final expectedHash = await _expectedHash(sumsUri, fileName);
    if (expectedHash == null) {
      return const UpdateInstallVerificationFailed();
    }
    if (cancellation.isCancelled) {
      throw const _Cancelled();
    }

    final file = await _downloadToTemp(
      installerUri,
      fileName: fileName,
      onProgress: onProgress,
      cancellation: cancellation,
    );
    final actualHash = sha256.convert(await file.readAsBytes()).toString();
    if (actualHash != expectedHash) {
      await _deleteQuietlyWithParent(file);
      return const UpdateInstallVerificationFailed();
    }
    return UpdateInstallReady(file);
  }

  Future<String?> _expectedHash(Uri sumsUri, String fileName) async {
    final response = await _open(sumsUri);
    if (response.statusCode != 200) {
      throw const FormatException('SHA256SUMS could not be read.');
    }
    final body = await _readBounded(response, maximumSha256SumsBytes);
    for (final line in const LineSplitter().convert(body)) {
      final match = _sha256SumsLine.firstMatch(line.trim());
      if (match != null && match.group(2) == fileName) {
        return match.group(1)!.toLowerCase();
      }
    }
    return null;
  }

  Future<File> _downloadToTemp(
    Uri installerUri, {
    required String fileName,
    required void Function(int receivedBytes, int? totalBytes)? onProgress,
    required DownloadCancellation cancellation,
  }) async {
    final dir = await Directory.systemTemp.createTemp('nks-talk-update-');
    final file = File('${dir.path}${Platform.pathSeparator}$fileName');
    try {
      final response = await _open(installerUri);
      if (response.statusCode != 200) {
        throw const FormatException('Installer download failed.');
      }
      final totalBytes = response.contentLength;
      if (totalBytes != null && totalBytes > maximumInstallerBytes) {
        throw const FormatException('Installer is larger than expected.');
      }

      final sink = file.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.stream) {
          if (cancellation.isCancelled) {
            throw const _Cancelled();
          }
          received += chunk.length;
          if (received > maximumInstallerBytes) {
            throw const FormatException('Installer is larger than expected.');
          }
          sink.add(chunk);
          onProgress?.call(received, totalBytes);
        }
      } finally {
        await sink.close();
      }
      return file;
    } on Object {
      await _deleteQuietlyWithParent(file);
      rethrow;
    }
  }

  /// Deletes [file] and the temporary directory `_downloadToTemp` made just
  /// for it. Every path that refuses a download — a mismatched hash, a
  /// cancellation, a network failure — routes through here, so nothing
  /// downloaded is ever left behind under `Directory.systemTemp`.
  Future<void> _deleteQuietlyWithParent(File file) async {
    try {
      final parent = file.parent;
      if (await parent.exists()) {
        await parent.delete(recursive: true);
      }
    } on Object {
      // Best effort: a file that failed to download or verify is not worth
      // failing the whole result over failing to clean up too.
    }
  }

  /// Sends [uri], following redirects by hand so every hop — not just the
  /// first request — can be checked against [_isGitHubControlledHost] before
  /// it is trusted.
  Future<http.StreamedResponse> _open(
    Uri uri, {
    int redirectsLeft = _maxRedirects,
  }) async {
    final request = http.Request('GET', uri)
      ..headers['User-Agent'] = 'NKS-Talk/$appVersionName'
      ..followRedirects = false
      ..maxRedirects = 0;
    final response = await _client.send(request);
    if (response.statusCode >= 300 && response.statusCode < 400) {
      final location = response.headers['location'];
      if (location == null || redirectsLeft <= 0) {
        throw const FormatException('Redirect could not be followed.');
      }
      final target = uri.resolveUri(Uri.parse(location));
      if (!_isGitHubControlledHost(target)) {
        throw const FormatException('Redirect left GitHub.');
      }
      return _open(target, redirectsLeft: redirectsLeft - 1);
    }
    return response;
  }

  Future<String> _readBounded(
    http.StreamedResponse response,
    int maximumBytes,
  ) async {
    if ((response.contentLength ?? 0) > maximumBytes) {
      throw const FormatException('The answer is too large to read.');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      bytes.add(chunk);
      if (bytes.length > maximumBytes) {
        throw const FormatException('The answer is too large to read.');
      }
    }
    return utf8.decode(bytes.takeBytes());
  }

  String _assetFileName(Uri uri) => Uri.decodeComponent(uri.pathSegments.last);
}
