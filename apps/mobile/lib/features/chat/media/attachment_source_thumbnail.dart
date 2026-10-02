import 'dart:io';

import 'package:flutter/material.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../../platform/media/durable_attachment_source_store.dart';

class AttachmentSourceThumbnail extends StatefulWidget {
  const AttachmentSourceThumbnail({
    super.key,
    required this.source,
    required this.store,
  });

  final PreparedAttachmentSource source;
  final DurableAttachmentSourceStore store;

  @override
  State<AttachmentSourceThumbnail> createState() =>
      _AttachmentSourceThumbnailState();
}

class _AttachmentSourceThumbnailState extends State<AttachmentSourceThumbnail> {
  Future<String>? _path;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(AttachmentSourceThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source.handle != widget.source.handle ||
        oldWidget.store != widget.store) {
      _load();
    }
  }

  void _load() {
    _path = widget.source.mimeType.startsWith('image/')
        ? widget.store.resolveVerifiedPath(widget.source)
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final fallback = Icon(
      widget.source.mimeType.startsWith('image/')
          ? Icons.image_outlined
          : Icons.insert_drive_file_outlined,
    );
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: FutureBuilder<String>(
          future: _path,
          builder: (context, snapshot) =>
              _path != null &&
                  snapshot.connectionState == ConnectionState.done &&
                  snapshot.hasData
              ? Image.file(
                  File(snapshot.data!),
                  fit: BoxFit.cover,
                  cacheWidth: 192,
                  errorBuilder: (_, _, _) => fallback,
                )
              : Center(child: fallback),
        ),
      ),
    );
  }
}
