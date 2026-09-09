import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../data/app_database.dart';
import '../../../data/chat_media_repository.dart';
import '../../../l10n/generated/app_localizations.dart';

/// Content types this app is willing to read out itself.
///
/// Plain text and Markdown only. Everything else — HTML included — keeps going
/// to whatever the platform opens it with, because reading a document format
/// means interpreting it, and interpreting HTML in the app is exactly what
/// this must not start doing.
const Set<String> readableTextTypes = <String>{
  'text/plain',
  'text/markdown',
  'text/x-markdown',
};

/// How much of a text file is shown. A chat attachment can be a log somebody
/// dropped in; past this the reader gets the beginning and is told the rest is
/// only in the file itself.
const int maximumReadableTextBytes = 1024 * 1024;

bool isReadableText(String contentType) =>
    readableTextTypes.contains(contentType.split(';').first.trim().toLowerCase());

/// Opens a text or Markdown attachment inside the app.
Future<void> showTextAttachmentViewer(
  BuildContext context, {
  required StoredAccount account,
  required Uri uri,
  required String fileName,
  required String contentType,
  required ChatMediaRepository repository,
  VoidCallback? onOpenExternally,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/chat/text'),
      fullscreenDialog: true,
      builder: (_) => TextAttachmentViewer(
        account: account,
        uri: uri,
        fileName: fileName,
        contentType: contentType,
        repository: repository,
        onOpenExternally: onOpenExternally,
      ),
    ),
  );
}

final class TextAttachmentViewer extends StatefulWidget {
  const TextAttachmentViewer({
    super.key,
    required this.account,
    required this.uri,
    required this.fileName,
    required this.contentType,
    required this.repository,
    this.onOpenExternally,
  });

  final StoredAccount account;
  final Uri uri;
  final String fileName;
  final String contentType;
  final ChatMediaRepository repository;

  /// Handing the file to another app stays available, because reading it here
  /// is an addition, not a replacement.
  final VoidCallback? onOpenExternally;

  @override
  State<TextAttachmentViewer> createState() => _TextAttachmentViewerState();
}

final class _TextAttachmentViewerState extends State<TextAttachmentViewer> {
  late Future<({String text, bool truncated})> _content;

  @override
  void initState() {
    super.initState();
    _content = _load();
  }

  Future<({String text, bool truncated})> _load() async {
    final file = await widget.repository.loadOriginalFile(
      account: widget.account,
      uri: widget.uri,
      expectedContentType: widget.contentType,
    );
    final truncated = file.body.length > maximumReadableTextBytes;
    final bytes = truncated
        ? file.body.sublist(0, maximumReadableTextBytes)
        : file.body;
    // A chat attachment is somebody else's file: it can be in any encoding or
    // in none. Malformed bytes become replacement characters instead of an
    // exception, so a mostly readable file stays readable.
    return (text: utf8.decode(bytes, allowMalformed: true), truncated: truncated);
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Scaffold(
      key: const Key('text-attachment-viewer'),
      appBar: AppBar(
        title: Text(widget.fileName, overflow: TextOverflow.ellipsis),
        actions: [
          if (widget.onOpenExternally case final VoidCallback open)
            IconButton(
              key: const Key('text-attachment-open-externally'),
              tooltip: strings.openAttachment,
              icon: const Icon(Icons.open_in_new_rounded),
              onPressed: open,
            ),
        ],
      ),
      body: FutureBuilder<({String text, bool truncated})>(
        future: _content,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              key: const Key('text-attachment-failed'),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.description_outlined, size: 40),
                    const SizedBox(height: 12),
                    Text(
                      strings.attachmentDownloadFailed,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      key: const Key('text-attachment-retry'),
                      onPressed: () => setState(() {
                        _content = _load();
                      }),
                      child: Text(strings.retry),
                    ),
                  ],
                ),
              ),
            );
          }
          final content = snapshot.data!;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (content.truncated)
                Padding(
                  key: const Key('text-attachment-truncated'),
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    strings.textAttachmentTruncated,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              // Selectable and monospaced: the point of reading a log or a
              // Markdown source in place is copying a line out of it. Nothing
              // here interprets the text, so any markup in it stays visible
              // rather than becoming something the app runs.
              SelectableText(
                content.text,
                key: const Key('text-attachment-content'),
                style: const TextStyle(fontFamily: 'monospace', height: 1.4),
                contextMenuBuilder: (context, state) =>
                    AdaptiveTextSelectionToolbar.editableText(
                      editableTextState: state,
                    ),
              ),
            ],
          );
        },
      ),
    );
  }
}
