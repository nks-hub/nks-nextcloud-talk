import 'dart:io';

import 'package:flutter/foundation.dart';

/// Replacing the running build on the platforms that ship a folder rather
/// than an installer.
///
/// Windows has a real installer that knows how to stop and replace the app, so
/// it never comes through here. macOS ships an application bundle and Linux a
/// directory of files; on both, installing means putting a new directory where
/// the old one is. That cannot be done from inside the process being replaced,
/// so the work is handed to a small shell script which waits for this process
/// to exit first.
///
/// The script is deliberately boring: rename the old directory aside, rename
/// the new one into its place, and start it again. The previous build stays
/// available until another update is requested from the running replacement.
/// A direct launch failure restores the old build.

/// Which directory a platform replaces, and what it starts afterwards.
@immutable
final class BundleSwap {
  const BundleSwap({
    required this.currentDirectory,
    required this.newDirectory,
    required this.relaunchExecutable,
  });

  /// The directory this build runs from, and the one that gets replaced.
  final String currentDirectory;

  /// The unpacked replacement, which must sit on the same filesystem as
  /// [currentDirectory] for the renames to be atomic.
  final String newDirectory;

  /// What the script starts once the new directory is in place. On macOS this
  /// is the bundle, opened with `open`; on Linux the executable itself.
  final String relaunchExecutable;
}

/// The directory the running build occupies.
///
/// On macOS the executable sits at `<bundle>.app/Contents/MacOS/<name>`, so
/// the bundle is three levels up and is what gets replaced. On Linux the
/// executable sits directly in the bundle directory.
///
/// Returns null when the layout is not the one this ships, which is what a
/// build run straight out of a development tree looks like. Refusing there is
/// the point: a swap is only safe when the thing being replaced is known.
Directory? runningBundleDirectory({
  String? executablePath,
  TargetPlatform? platform,
}) {
  final target = platform ?? defaultTargetPlatform;
  final executable = File(executablePath ?? Platform.resolvedExecutable);
  final parent = executable.parent;
  return switch (target) {
    TargetPlatform.linux => parent,
    TargetPlatform.macOS => _macOSBundleOf(parent),
    _ => null,
  };
}

Directory? _macOSBundleOf(Directory macOSDirectory) {
  if (_baseName(macOSDirectory.path) != 'MacOS') {
    return null;
  }
  final contents = macOSDirectory.parent;
  if (_baseName(contents.path) != 'Contents') {
    return null;
  }
  final bundle = contents.parent;
  return bundle.path.endsWith('.app') ? bundle : null;
}

String _baseName(String path) {
  final normalised = path.replaceAll(r'\', '/');
  final trimmed = normalised.endsWith('/')
      ? normalised.substring(0, normalised.length - 1)
      : normalised;
  final slash = trimmed.lastIndexOf('/');
  return slash < 0 ? trimmed : trimmed.substring(slash + 1);
}

/// Wraps [value] for `sh`, so a path holding a space or a quote survives.
///
/// Single quotes take everything literally, and the one character they cannot
/// carry is a single quote itself; the usual close-escape-reopen dance handles
/// that one.
String shellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// The suffix the script renames the old directory to. Checked again inside
/// the script before anything is deleted, so the delete can only ever reach a
/// path the script itself named.
const bundleBackupSuffix = '.nks-previous';

/// Builds the replacement script.
///
/// Handed to `sh -c` rather than written to a file, so the only thing left on
/// disk while it runs is the staging directory, which the script deletes
/// itself as its last act.
///
/// [pid] is the process the script waits for. [waitSeconds] bounds that wait:
/// a build that refuses to exit must not leave a script running forever, and
/// the previous build is still in place when the wait runs out.
String buildSwapScript({
  required int pid,
  required BundleSwap swap,
  required String stagingDirectory,
  required bool useOpen,
  int waitSeconds = 60,
}) {
  final current = shellQuote(swap.currentDirectory);
  final replacement = shellQuote(swap.newDirectory);
  final relaunch = shellQuote(swap.relaunchExecutable);
  final backup = shellQuote('${swap.currentDirectory}$bundleBackupSuffix');
  final staging = shellQuote(stagingDirectory);
  final attempts = waitSeconds * 2;
  final start = useOpen
      ? <String>[
          r'if ! open -n "$relaunch"; then',
          '  rollback',
          '  exit 1',
          'fi',
        ]
      : <String>[
          r'"$relaunch" &',
          r'launched=$!',
          'sleep 1',
          r'if ! kill -0 "$launched" 2>/dev/null; then',
          r'  if ! wait "$launched"; then',
          '    rollback',
          '    exit 1',
          '  fi',
          'fi',
        ];
  final lines = <String>[
    'current=$current',
    'replacement=$replacement',
    'backup=$backup',
    'relaunch=$relaunch',
    'staging=$staging',
    '',
    'waited=0',
    'while kill -0 $pid 2>/dev/null; do',
    r'  waited=$((waited + 1))',
    '  if [ "\$waited" -ge $attempts ]; then',
    '    exit 1',
    '  fi',
    '  sleep 0.5',
    'done',
    '',
    '# The delete below may only ever reach a path this script named itself.',
    r'case "$backup" in',
    '  *$bundleBackupSuffix) ;;',
    '  *) exit 1 ;;',
    'esac',
    '',
    r'if [ -e "$backup" ] && ! rm -r -- "$backup"; then',
    '  exit 1',
    'fi',
    r'mv -- "$current" "$backup" || exit 1',
    r'if ! mv -- "$replacement" "$current"; then',
    '  # Nothing was replaced yet, so put the previous build straight back.',
    r'  mv -- "$backup" "$current"',
    '  exit 1',
    'fi',
    '',
    'rollback() {',
    r'  mv -- "$current" "$replacement" || return 1',
    r'  if ! mv -- "$backup" "$current"; then',
    r'    mv -- "$replacement" "$current"',
    '    return 1',
    '  fi',
    useOpen ? r'  open -n "$relaunch"' : r'  "$relaunch" &',
    '}',
    '',
    ...start,
    '',
    '# Keep the previous build: a launched process may still fail during startup.',
    r'rm -r -- "$staging"',
    '',
  ];
  return lines.join('\n');
}
