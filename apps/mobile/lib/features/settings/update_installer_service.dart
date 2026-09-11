import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/app_version.dart';
import 'update_bundle_swap.dart';
import 'update_check_service.dart';

/// Whether this platform may download and install an update itself.
///
/// All three desktops. Windows runs the installer the release carries. macOS
/// and Linux ship a directory rather than an installer, so there the download
/// is unpacked and put in the place of the running one; see
/// [update_bundle_swap.dart] for how that is done without the process
/// replacing itself.
///
/// Never the phones: a build from Google Play or the App Store is updated by
/// the store, and pointing somebody at a download outside it breaks both
/// stores' rules. That is also why this is not a preference.
bool get canDownloadAndInstallUpdate {
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

/// What installing means here: run the file, or put a directory in place of
/// the running one.
enum UpdateInstallKind { runInstaller, replaceBundle }

/// What the release archives unpack to, and what runs inside them. Checked
/// after unpacking, so an archive that is not shaped like ours is refused
/// before anything is put in the running build's place.
const _macOSBundleName = 'nextcloudtalk.app';
const _linuxBundleName = 'bundle';
const _linuxExecutableName = 'nextcloudtalk';

/// Names the directory an update is unpacked into, beside the build it
/// replaces. Recognisable on sight so a leftover can be cleared, and hidden so
/// it does not appear in a file manager while it exists.
const _stagingPrefix = '.nks-talk-update-';

UpdateInstallKind? _installKind(TargetPlatform platform) =>
    switch (platform) {
      TargetPlatform.windows => UpdateInstallKind.runInstaller,
      TargetPlatform.macOS ||
      TargetPlatform.linux => UpdateInstallKind.replaceBundle,
      _ => null,
    };

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

void _exitProcess() => exit(0);

/// Aborts the current HTTP request, including stalled headers or body reads.
final class DownloadCancellation {
  final Completer<void> _abort = Completer<void>();

  bool get isCancelled => _abort.isCompleted;

  Future<void> get _abortTrigger => _abort.future;

  void cancel() {
    if (!_abort.isCompleted) _abort.complete();
  }

  void _check() {
    if (isCancelled) throw const _Cancelled();
  }
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
    http.Client Function()? clientFactory,
    this.downloadTimeout = const Duration(minutes: 5),
    this.maximumInstallerBytes = 128 * 1024 * 1024,
    this.maximumSha256SumsBytes = 16 * 1024,
    this.exitDelay = const Duration(seconds: 2),
    void Function()? quit,
    this.bundleDirectory = runningBundleDirectory,
  }) : _clientFactory = clientFactory ?? http.Client.new,
       quit = quit ?? _exitProcess;

  final http.Client Function() _clientFactory;
  final Duration downloadTimeout;
  final int maximumInstallerBytes;
  final int maximumSha256SumsBytes;

  /// How long the window stays up after the swap script is started, so the
  /// person sees that the update began rather than the app simply vanishing.
  final Duration exitDelay;

  /// Ends this process so the waiting script can replace it. Injected, because
  /// a test must be able to watch this being asked for without dying itself.
  final void Function() quit;

  /// Where the running build lives. Injected for the same reason: a test needs
  /// a stand-in installation it may safely have replaced.
  final Directory? Function() bundleDirectory;
  final Map<DownloadCancellation, http.Client> _downloads = {};

  static const _maxRedirects = 5;
  static final _sha256SumsLine = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+)$');

  void close() {
    for (final download in _downloads.entries) {
      download.key.cancel();
      download.value.close();
    }
  }

  /// Downloads the installer [release] points at, fetches the release's
  /// `SHA256SUMS`, and refuses to hand back a file whose hash does not match
  /// the line published for it.
  Future<UpdateInstallResult> downloadAndVerify({
    required UpdateAvailable release,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
    DownloadCancellation? cancellation,
  }) async {
    final installerUri = release.installerAssetUri;
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
    var timedOut = false;
    final client = _clientFactory();
    _downloads[cancel] = client;
    // AbortableRequest registers only after openUrl. Close this operation's
    // HTTP connections too; the cancellation race below bounds pending TLS.
    unawaited(cancel._abortTrigger.then((_) => client.close()));
    final deadline = Timer(downloadTimeout, () {
      timedOut = true;
      cancel.cancel();
    });
    try {
      cancel._check();
      return await _downloadAndVerify(
        client: client,
        installerUri: installerUri,
        sumsUri: sumsUri,
        fileName: fileName,
        onProgress: onProgress,
        cancellation: cancel,
      );
    } on Object {
      if (cancel.isCancelled && !timedOut) {
        return const UpdateInstallCancelled();
      }
      return const UpdateInstallUnavailable();
    } finally {
      deadline.cancel();
      _downloads.remove(cancel);
      cancel.cancel();
      client.close();
    }
  }

  /// Installs the verified download. Only ever called with an
  /// [UpdateInstallReady] the caller itself obtained from
  /// [downloadAndVerify], so nothing is run or unpacked without having passed
  /// the checksum check first.
  ///
  /// On Windows that means starting the installer, which replaces the build
  /// and restarts it. On macOS and Linux there is no installer: the archive is
  /// unpacked beside the running build and a small script puts it in place
  /// once this process has exited, so this asks the process to exit.
  Future<bool> runInstaller(UpdateInstallReady ready) async {
    return switch (_installKind(defaultTargetPlatform)) {
      UpdateInstallKind.runInstaller => _startInstaller(ready.installerFile),
      UpdateInstallKind.replaceBundle => _replaceRunningBundle(
        ready.installerFile,
      ),
      null => false,
    };
  }

  Future<bool> _startInstaller(File installer) async {
    try {
      await Process.start(
        installer.path,
        const <String>[],
        mode: ProcessStartMode.detached,
      );
      return true;
    } on Object {
      return false;
    }
  }

  /// Unpacks [archive] next to the running build and hands the swap to a
  /// script that waits for this process to exit.
  ///
  /// The staging directory is a sibling of the build being replaced, not
  /// somewhere under the system temp directory: the script replaces by
  /// renaming, and a rename only stays atomic within one filesystem. A staging
  /// directory on another disk would turn the one irreversible moment into a
  /// long copy that can fail halfway.
  Future<bool> _replaceRunningBundle(File archive) async {
    final current = bundleDirectory();
    if (current == null) {
      return false;
    }
    Directory? staging;
    try {
      // A process killed between unpacking and starting the script leaves its
      // staging directory behind, and that is a whole build's worth of files.
      // Nothing else ever writes these, so the next attempt clears them.
      await _clearStaleStaging(current.parent);
      staging = await current.parent.createTemp(_stagingPrefix);
      final unpacked = await _unpack(archive, staging);
      if (unpacked == null) {
        return false;
      }
      if (!await _isTrustedBundle(unpacked)) {
        return false;
      }
      final swap = BundleSwap(
        currentDirectory: current.path,
        newDirectory: unpacked.path,
        relaunchExecutable: defaultTargetPlatform == TargetPlatform.macOS
            ? current.path
            : _join(current.path, _linuxExecutableName),
      );
      final script = buildSwapScript(
        pid: pid,
        swap: swap,
        stagingDirectory: staging.path,
        useOpen: defaultTargetPlatform == TargetPlatform.macOS,
      );
      await Process.start('/bin/sh', <String>[
        '-c',
        script,
      ], mode: ProcessStartMode.detached);
      // The script is already waiting on this process. Leave long enough for
      // the caller to show that the update started, then go.
      Timer(exitDelay, quit);
      return true;
    } on Object {
      if (staging != null) {
        await _deleteQuietly(staging);
      }
      return false;
    }
  }

  /// Unpacks [archive] into [staging] with the system's own tool and returns
  /// the directory that replaces the running one.
  ///
  /// `ditto` rather than a Dart zip reader on macOS, and `tar` on Linux,
  /// because both carry what a plain file-by-file extraction drops: symlinks,
  /// executable bits and, on macOS, the extended attributes the code signature
  /// is checked against. An unpacked bundle that lost those is one Gatekeeper
  /// refuses to start.
  Future<Directory?> _unpack(File archive, Directory staging) async {
    final macOS = defaultTargetPlatform == TargetPlatform.macOS;
    final result = macOS
        ? await Process.run('/usr/bin/ditto', <String>[
            '-x',
            '-k',
            archive.path,
            staging.path,
          ])
        : await Process.run('/usr/bin/env', <String>[
            'tar',
            '-xzf',
            archive.path,
            '-C',
            staging.path,
          ]);
    if (result.exitCode != 0) {
      return null;
    }
    final root = Directory(
      _join(staging.path, macOS ? _macOSBundleName : _linuxBundleName),
    );
    if (!await root.exists()) {
      return null;
    }
    final executable = File(
      macOS
          ? _join(root.path, 'Contents', 'MacOS', _linuxExecutableName)
          : _join(root.path, _linuxExecutableName),
    );
    return await executable.exists() ? root : null;
  }

  /// On macOS, whether the unpacked bundle really replaces this one.
  ///
  /// The checksum already proved the archive is the one GitHub published, so
  /// this is not the first line of defence — it is the one that still holds if
  /// the checksum list itself were ever wrong, and it is what Gatekeeper will
  /// ask anyway when the replacement starts. Failing here now beats replacing
  /// a working build with one that cannot open.
  ///
  /// The team is read off the build that is running rather than written down
  /// here, so this asks the only question worth asking — is the replacement
  /// signed by whoever signed me — and keeps working for anybody who builds
  /// and signs this themselves.
  Future<bool> _isTrustedBundle(Directory bundle) async {
    if (defaultTargetPlatform != TargetPlatform.macOS) {
      return true;
    }
    final verify = await Process.run('/usr/bin/codesign', <String>[
      '--verify',
      '--strict',
      bundle.path,
    ]);
    if (verify.exitCode != 0) {
      return false;
    }
    final current = bundleDirectory();
    if (current == null) {
      return false;
    }
    final signedBy = await _teamIdentifierOf(bundle.path);
    final runningAs = await _teamIdentifierOf(current.path);
    return signedBy != null && signedBy == runningAs;
  }

  /// The signing team of the bundle at [path], or null when it has none — an
  /// ad-hoc signature says `not set`, and a replacement like that must never
  /// stand in for a real one.
  Future<String?> _teamIdentifierOf(String path) async {
    final shown = await Process.run('/usr/bin/codesign', <String>['-dv', path]);
    final described = '${shown.stdout}${shown.stderr}';
    final team = RegExp(
      r'^TeamIdentifier=(\S+)$',
      multiLine: true,
    ).firstMatch(described)?.group(1);
    return team == null || team == 'not' || team == 'not set' ? null : team;
  }

  /// Removes staging directories a previous attempt left behind. Only ever
  /// paths this service itself names, and only directly beside the build.
  Future<void> _clearStaleStaging(Directory beside) async {
    try {
      await for (final entry in beside.list(followLinks: false)) {
        if (entry is! Directory) {
          continue;
        }
        final name = entry.path.split(Platform.pathSeparator).last;
        if (name.startsWith(_stagingPrefix)) {
          await _deleteQuietly(entry);
        }
      }
    } on Object {
      // A directory that cannot even be listed is one to leave alone.
    }
  }

  Future<void> _deleteQuietly(Directory directory) async {
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } on Object {
      // Best effort, exactly as for a refused download.
    }
  }

  String _join(String first, String second, [String? third, String? fourth]) {
    return <String?>[
      first,
      second,
      third,
      fourth,
    ].whereType<String>().join(Platform.pathSeparator);
  }

  Future<UpdateInstallResult> _downloadAndVerify({
    required http.Client client,
    required Uri installerUri,
    required Uri sumsUri,
    required String fileName,
    required void Function(int receivedBytes, int? totalBytes)? onProgress,
    required DownloadCancellation cancellation,
  }) async {
    final expectedHash = await _expectedHash(
      client,
      sumsUri,
      fileName,
      cancellation,
    );
    cancellation._check();
    if (expectedHash == null) {
      return const UpdateInstallVerificationFailed();
    }
    final file = await _downloadToTemp(
      client,
      installerUri,
      fileName: fileName,
      onProgress: onProgress,
      cancellation: cancellation,
    );
    var verified = false;
    try {
      cancellation._check();
      final actualHash = sha256.convert(await file.readAsBytes()).toString();
      cancellation._check();
      if (actualHash != expectedHash) {
        return const UpdateInstallVerificationFailed();
      }
      verified = true;
      return UpdateInstallReady(file);
    } finally {
      if (!verified) await _deleteQuietlyWithParent(file);
    }
  }

  Future<String?> _expectedHash(
    http.Client client,
    Uri sumsUri,
    String fileName,
    DownloadCancellation cancellation,
  ) async {
    final response = await _open(client, sumsUri, cancellation);
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
    http.Client client,
    Uri installerUri, {
    required String fileName,
    required void Function(int receivedBytes, int? totalBytes)? onProgress,
    required DownloadCancellation cancellation,
  }) async {
    final dir = await Directory.systemTemp.createTemp('nks-talk-update-');
    final file = File('${dir.path}${Platform.pathSeparator}$fileName');
    try {
      final response = await _open(client, installerUri, cancellation);
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
          cancellation._check();
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
    http.Client client,
    Uri uri,
    DownloadCancellation cancellation, {
    int redirectsLeft = _maxRedirects,
  }) async {
    cancellation._check();
    final request =
        http.AbortableRequest(
            'GET',
            uri,
            abortTrigger: cancellation._abortTrigger,
          )
          ..headers['User-Agent'] = 'NKS-Talk/$appVersionName'
          ..followRedirects = false
          ..maxRedirects = 0;
    // IOClient may still be awaiting openUrl when its client is closed.
    // Unblock this await too, so the caller can finish its file cleanup.
    final response = await Future.any<http.StreamedResponse>([
      client.send(request),
      cancellation._abortTrigger.then((_) => throw const _Cancelled()),
    ]);
    cancellation._check();
    if (response.statusCode >= 300 && response.statusCode < 400) {
      final location = response.headers['location'];
      if (location == null || redirectsLeft <= 0) {
        throw const FormatException('Redirect could not be followed.');
      }
      final target = uri.resolveUri(Uri.parse(location));
      if (!_isGitHubControlledHost(target)) {
        throw const FormatException('Redirect left GitHub.');
      }
      return _open(
        client,
        target,
        cancellation,
        redirectsLeft: redirectsLeft - 1,
      );
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

  /// The last path segment, already decoded once by [Uri].
  ///
  /// Decoding it a second time turned `%252e%252e%252f` back into `../`, and
  /// this name is joined onto a temp directory that the failure path deletes
  /// with its parent. Anything that still looks like a path after the check
  /// is refused rather than repaired.
  String _assetFileName(Uri uri) {
    final name = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains(r'\')) {
      throw const FormatException('The update names no usable file.');
    }
    return name;
  }
}
