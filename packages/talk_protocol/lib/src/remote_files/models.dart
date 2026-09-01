import 'dart:collection';

/// One entry of a user's own Nextcloud Files directory.
///
/// Carries only what a picker needs to show a row and what sharing needs to
/// identify the file. No etag, no owner, no share state: everything stored
/// here ends up on screen, and anything else would be collected for nothing.
final class RemoteFileEntry {
  const RemoteFileEntry({
    required this.path,
    required this.name,
    required this.isDirectory,
    required this.sizeBytes,
    required this.mimeType,
    required this.hasPreview,
    required this.lastModified,
  });

  /// Path relative to the account's own files root, without a leading slash.
  /// `''` is that root itself.
  final String path;

  final String name;
  final bool isDirectory;

  /// `null` when the server reported no length, which it does for directories.
  final int? sizeBytes;

  /// `null` for directories and for files the server did not type.
  final String? mimeType;

  final bool hasPreview;
  final DateTime? lastModified;

  @override
  String toString() =>
      'RemoteFileEntry(isDirectory: $isDirectory, hasPreview: $hasPreview, '
      'name: <redacted>, path: <redacted>)';
}

/// A directory listing: the directory itself plus its immediate children.
final class RemoteDirectoryListing {
  RemoteDirectoryListing({
    required this.path,
    required List<RemoteFileEntry> entries,
  }) : entries = UnmodifiableListView(entries);

  final String path;

  /// Sorted directories first, then by name, because that is the order the
  /// picker shows and sorting once here keeps every caller consistent.
  final List<RemoteFileEntry> entries;

  @override
  String toString() =>
      'RemoteDirectoryListing(entries: ${entries.length}, path: <redacted>)';
}
