import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../../l10n/generated/app_localizations.dart';
import 'account_collection_dialog.dart';
import 'message_collection_store.dart';

export 'message_collection_store.dart';

final messageCollectionStoreProvider = Provider<MessageCollectionStore>(
  (ref) => MessageCollectionStore(),
);

Future<void> showSaveToMessageCollection(
  BuildContext context, {
  required AccountId account,
  required MessageCollectionStore store,
  required SavedMessageLink message,
}) =>
    _showCollections(context, account: account, store: store, saving: message);

Future<SavedMessageLink?> showMessageCollections(
  BuildContext context, {
  required AccountId account,
  required MessageCollectionStore store,
}) => _showCollections(context, account: account, store: store);

Future<SavedMessageLink?> _showCollections(
  BuildContext context, {
  required AccountId account,
  required MessageCollectionStore store,
  SavedMessageLink? saving,
}) => showDialog<SavedMessageLink>(
  context: context,
  builder: (context) {
    final strings = AppLocalizations.of(context);
    Future<void> editName([MessageCollection? collection]) async {
      final name = await editAccountCollectionItem(
        context,
        title: collection == null
            ? strings.newMessageCollection
            : strings.messageActionEdit,
        nameLabel: strings.messageCollectionName,
        name: collection?.name ?? '',
      );
      if (name == null || !context.mounted) return;
      if (collection == null) {
        await saveAccountCollectionChange(context, () async {
          await store.create(account, name.name, message: saving);
        });
      } else {
        await saveAccountCollectionChange(
          context,
          () => store.rename(account, collection.id, name.name),
        );
      }
    }

    Future<void> delete(MessageCollection collection) async {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(collection.name),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(strings.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(strings.messageActionDelete),
            ),
          ],
        ),
      );
      if (confirmed == true && context.mounted) {
        await saveAccountCollectionChange(
          context,
          () => store.remove(account, collection.id),
        );
      }
    }

    return AccountCollectionDialog<MessageCollection>(
      account: account,
      store: store,
      title: saving == null
          ? strings.messageCollections
          : strings.saveToCollection,
      action: TextButton.icon(
        onPressed: editName,
        icon: const Icon(Icons.create_new_folder_outlined),
        label: Text(strings.newMessageCollection),
      ),
      content: (context, collections) => collections.isEmpty
          ? Center(child: Text(strings.messageCollectionsEmpty))
          : ListView.builder(
              itemCount: collections.length,
              itemBuilder: (context, index) {
                final collection = collections[index];
                if (saving != null) {
                  return CheckboxListTile(
                    title: Text(collection.name),
                    value: collection.messages.any((m) => m.matches(saving)),
                    onChanged: (checked) => saveAccountCollectionChange(
                      context,
                      () => store.setSaved(
                        account,
                        collection.id,
                        saving,
                        saved: checked == true,
                      ),
                    ),
                  );
                }
                return ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(collection.name),
                  onTap: () async {
                    final selected = await _showMessages(
                      context,
                      account,
                      store,
                      collection,
                    );
                    if (selected != null && context.mounted) {
                      Navigator.pop(context, selected);
                    }
                  },
                  trailing: PopupMenuButton<bool>(
                    onSelected: (edit) =>
                        edit ? editName(collection) : delete(collection),
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

Future<SavedMessageLink?> _showMessages(
  BuildContext context,
  AccountId account,
  MessageCollectionStore store,
  MessageCollection collection,
) {
  final strings = AppLocalizations.of(context);
  return showDialog<SavedMessageLink>(
    context: context,
    builder: (context) => AccountCollectionDialog<MessageCollection>(
      account: account,
      store: store,
      title: collection.name,
      content: (context, collections) {
        final entries =
            collections
                .where((c) => c.id == collection.id)
                .firstOrNull
                ?.messages ??
            const <SavedMessageLink>[];
        if (entries.isEmpty) {
          return Center(child: Text(strings.messageCollectionEmpty));
        }
        return ListView.builder(
          itemCount: entries.length,
          itemBuilder: (context, index) {
            final message = entries[index];
            return ListTile(
              title: Text(
                message.excerpt.isEmpty ? message.roomName : message.excerpt,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: message.excerpt.isEmpty ? null : Text(message.roomName),
              onTap: () => Navigator.pop(context, message),
              trailing: IconButton(
                tooltip: strings.remove,
                icon: const Icon(Icons.bookmark_remove_outlined),
                onPressed: () => saveAccountCollectionChange(
                  context,
                  () => store.setSaved(
                    account,
                    collection.id,
                    message,
                    saved: false,
                  ),
                ),
              ),
            );
          },
        );
      },
    ),
  );
}
