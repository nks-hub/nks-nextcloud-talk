import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';
import 'package:uuid/uuid.dart';

import '../../../l10n/generated/app_localizations.dart';
import 'account_collection_dialog.dart';
import 'account_collection_store.dart';
import 'composer_text_editing.dart';

final replyTemplateStoreProvider = Provider<ReplyTemplateStore>(
  (ref) => ReplyTemplateStore(),
);

final class ReplyTemplate {
  const ReplyTemplate({
    required this.id,
    required this.name,
    required this.text,
  });
  final String id;
  final String name;
  final String text;
}

final class ReplyTemplateStore extends AccountCollectionStore<ReplyTemplate> {
  ReplyTemplateStore({Directory? directory})
    : super('reply-templates-v1', directory);

  Future<void> save(
    AccountId account, {
    String? id,
    required String name,
    required String text,
  }) {
    if (name.trim().isEmpty ||
        name.trim().length > 320 ||
        text.trim().isEmpty ||
        text.length > composerMaximumCharacters) {
      throw ArgumentError('Invalid template');
    }
    return update(account, (items) {
      final entry = ReplyTemplate(
        id: id ?? const Uuid().v4(),
        name: name.trim(),
        text: text,
      );
      if (id == null) {
        items.add(entry);
      } else {
        final index = items.indexWhere((e) => e.id == id);
        if (index < 0) throw StateError('Template no longer exists');
        items[index] = entry;
      }
    });
  }

  Future<void> remove(AccountId account, String id) =>
      update(account, (items) => items.removeWhere((e) => e.id == id));

  @override
  ReplyTemplate decode(Map<String, Object?> json) => ReplyTemplate(
    id: json['id'] as String,
    name: json['name'] as String,
    text: json['text'] as String,
  );

  @override
  Map<String, Object?> encode(ReplyTemplate entry) => {
    'id': entry.id,
    'name': entry.name,
    'text': entry.text,
  };
}

Future<String?> showReplyTemplates(
  BuildContext context, {
  required AccountId account,
  required ReplyTemplateStore store,
}) => showDialog<String>(
  context: context,
  builder: (context) {
    final strings = AppLocalizations.of(context);
    Future<void> edit([ReplyTemplate? entry]) async {
      final value = await editAccountCollectionItem(
        context,
        title: entry == null
            ? strings.newReplyTemplate
            : strings.messageActionEdit,
        nameLabel: strings.replyTemplateName,
        name: entry?.name ?? '',
        textLabel: strings.replyTemplateText,
        text: entry?.text ?? '',
      );
      if (value == null || !context.mounted) return;
      await saveAccountCollectionChange(
        context,
        () => store.save(
          account,
          id: entry?.id,
          name: value.name,
          text: value.text,
        ),
      );
    }

    return AccountCollectionDialog<ReplyTemplate>(
      account: account,
      store: store,
      title: strings.replyTemplates,
      action: TextButton.icon(
        onPressed: edit,
        icon: const Icon(Icons.add),
        label: Text(strings.newReplyTemplate),
      ),
      content: (context, entries) => entries.isEmpty
          ? Center(child: Text(strings.replyTemplatesEmpty))
          : ListView.builder(
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final entry = entries[index];
                return ListTile(
                  title: Text(entry.name),
                  subtitle: Text(
                    entry.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => Navigator.pop(context, entry.text),
                  trailing: PopupMenuButton<bool>(
                    onSelected: (editing) {
                      if (editing) {
                        edit(entry);
                      } else {
                        saveAccountCollectionChange(
                          context,
                          () => store.remove(account, entry.id),
                        );
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: true,
                        child: Text(strings.messageActionEdit),
                      ),
                      PopupMenuItem(
                        value: false,
                        child: Text(strings.messageActionDelete),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  },
);
