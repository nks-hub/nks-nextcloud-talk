import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../../app_providers.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../remote_file_share_service.dart';

/// What the picker did, so the conversation can say it in one line.
enum RemoteFilePickerResult { shared, failed, forbidden, signInRequired }

/// Browses the account's own Nextcloud files and shares one into the room.
///
/// One directory at a time on purpose: a recursive listing is what makes a
/// real account unusable, and it would also pull far more of the user's file
/// names into the app than picking one file needs.
final class RemoteFilePickerScreen extends ConsumerStatefulWidget {
  const RemoteFilePickerScreen({
    super.key,
    required this.accountId,
    required this.roomToken,
  });

  final String accountId;
  final String roomToken;

  @override
  ConsumerState<RemoteFilePickerScreen> createState() =>
      _RemoteFilePickerScreenState();
}

final class _RemoteFilePickerScreenState
    extends ConsumerState<RemoteFilePickerScreen> {
  String _path = '';
  bool _loading = true;
  bool _sharing = false;
  RemoteDirectoryListing? _listing;
  bool _truncated = false;
  RemoteFileError? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load(''));
  }

  Future<void> _load(String path) async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _path = path;
    });
    try {
      final listing = await ref
          .read(remoteFileShareServiceProvider)
          .listDirectory(accountId: widget.accountId, path: path);
      // A slower answer for a folder the user already left must not replace
      // what they are looking at now.
      if (!mounted || generation != _generation) {
        return;
      }
      setState(() {
        _listing = listing;
        _truncated = listing.entries.length >= remoteFilesMaximumEntries;
        _loading = false;
      });
    } on RemoteFileException catch (failure) {
      if (!mounted || generation != _generation) {
        return;
      }
      if (failure.code == RemoteFileError.reauthenticationRequired) {
        Navigator.of(context).pop(RemoteFilePickerResult.signInRequired);
        return;
      }
      setState(() {
        _error = failure.code;
        _loading = false;
      });
    }
  }

  Future<void> _open(RemoteFileEntry entry) async {
    if (entry.isDirectory) {
      await _load(entry.path);
      return;
    }
    final strings = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('remote-file-share-dialog'),
        // Large text turns two lines of body into a dialog taller than the
        // phone; without this the actions are pushed off the bottom and the
        // user cannot confirm or cancel at all.
        scrollable: true,
        title: Text(strings.remoteFilesShareTitle),
        // Says what actually happens: the file is not copied and the access
        // it grants outlives this message.
        content: Text(strings.remoteFilesShareBody(entry.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            key: const Key('remote-file-share-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.remoteFilesShareAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() => _sharing = true);
    try {
      await ref
          .read(remoteFileShareServiceProvider)
          .shareIntoRoom(
            accountId: widget.accountId,
            roomToken: widget.roomToken,
            path: entry.path,
          );
      if (mounted) {
        Navigator.of(context).pop(RemoteFilePickerResult.shared);
      }
    } on RemoteFileException catch (failure) {
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(switch (failure.code) {
        RemoteFileError.reauthenticationRequired =>
          RemoteFilePickerResult.signInRequired,
        RemoteFileError.forbidden => RemoteFilePickerResult.forbidden,
        _ => RemoteFilePickerResult.failed,
      });
    }
  }

  void _up() {
    final segments = _path.split('/')..removeLast();
    unawaited(_load(segments.where((part) => part.isNotEmpty).join('/')));
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final name = _path.isEmpty
        ? strings.remoteFilesTitle
        : _path.split('/').last;
    return PopScope(
      canPop: _path.isEmpty && !_sharing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_sharing) {
          _up();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(name, key: const Key('remote-file-picker-title')),
          leading: BackButton(
            onPressed: _sharing
                ? null
                : () {
                    if (_path.isEmpty) {
                      Navigator.of(context).pop();
                    } else {
                      _up();
                    }
                  },
          ),
        ),
        body: SafeArea(child: _body(strings)),
      ),
    );
  }

  Widget _body(AppLocalizations strings) {
    if (_loading || _sharing) {
      return const Center(
        key: Key('remote-file-picker-loading'),
        child: CircularProgressIndicator(),
      );
    }
    final error = _error;
    if (error != null) {
      return _Message(
        key: const Key('remote-file-picker-error'),
        text: strings.remoteFilesLoadFailed,
        action: TextButton(
          onPressed: () => unawaited(_load(_path)),
          child: Text(strings.retry),
        ),
      );
    }
    final entries = _listing?.entries ?? const <RemoteFileEntry>[];
    if (entries.isEmpty) {
      return _Message(
        key: const Key('remote-file-picker-empty'),
        text: strings.remoteFilesEmpty,
      );
    }
    return Column(
      children: [
        if (_truncated)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              strings.remoteFilesTruncated(remoteFilesMaximumEntries),
              key: const Key('remote-file-picker-truncated'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        Expanded(
          child: ListView.builder(
            key: const Key('remote-file-picker-list'),
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              return ListTile(
                key: Key('remote-file-${entry.path}'),
                leading: Icon(
                  entry.isDirectory
                      ? Icons.folder_outlined
                      : Icons.insert_drive_file_outlined,
                ),
                title: Text(entry.name),
                subtitle: entry.isDirectory || entry.sizeBytes == null
                    ? null
                    : Text(_formatSize(entry.sizeBytes!)),
                trailing: entry.isDirectory
                    ? const Icon(Icons.chevron_right)
                    : null,
                onTap: () => unawaited(_open(entry)),
              );
            },
          ),
        ),
      ],
    );
  }
}

final class _Message extends StatelessWidget {
  const _Message({super.key, required this.text, this.action});

  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: 12), action!],
        ],
      ),
    ),
  );
}

String _formatSize(int bytes) {
  const units = <String>['B', 'kB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return unit == 0
      ? '$bytes ${units[unit]}'
      : '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[unit]}';
}
