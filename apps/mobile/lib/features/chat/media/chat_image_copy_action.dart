import 'dart:async';

import 'package:flutter/material.dart';

import '../../../data/app_database.dart';
import '../../../data/chat_media_repository.dart';
import '../../../l10n/generated/app_localizations.dart';
import 'authenticated_image_gallery.dart';
import 'chat_image_exporter.dart';

final class ChatImageCopyAction extends StatelessWidget {
  const ChatImageCopyAction({
    super.key,
    required this.messageContext,
    required this.account,
    required this.image,
    required this.repository,
    this.exporter = const PlatformChatImageExporter(),
  });

  final BuildContext messageContext;
  final StoredAccount account;
  final ChatGalleryImage image;
  final ChatMediaRepository repository;
  final ChatImageExporter exporter;

  Future<void> _copy() async {
    final strings = AppLocalizations.of(messageContext);
    final messenger = ScaffoldMessenger.of(messageContext);
    messenger.showSnackBar(
      SnackBar(content: Text(strings.imageCopying)),
    );
    var copied = false;
    try {
      final original = await repository.loadOriginalFile(
        account: account,
        uri: image.originalUri,
        expectedContentType: image.contentType,
      );
      if (messageContext.mounted) {
        copied = await exporter.copyToClipboard(bytes: original.body);
      }
    } on Object {
      copied = false;
    }
    if (!messageContext.mounted) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(copied ? strings.imageCopied : strings.imageCopyFailed),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListTile(
    key: const Key('message-action-copy-image'),
    leading: const Icon(Icons.image_outlined),
    title: Text(AppLocalizations.of(context).copyImage),
    onTap: () {
      Navigator.of(context).pop();
      unawaited(_copy());
    },
  );
}
