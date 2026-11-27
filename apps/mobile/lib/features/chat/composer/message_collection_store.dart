import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:talk_protocol/talk_protocol.dart';
import 'package:uuid/uuid.dart';

import 'account_collection_store.dart';

@immutable
final class SavedMessageLink {
  const SavedMessageLink({
    required this.roomToken,
    required this.messageId,
    required this.threadId,
    required this.roomName,
    required this.excerpt,
  });

  final String roomToken;
  final int messageId;
  final int? threadId;
  final String roomName;
  final String excerpt;

  bool matches(SavedMessageLink other) =>
      roomToken == other.roomToken && messageId == other.messageId;

  Map<String, Object?> _toJson() => {
    'room': roomToken,
    'message': messageId,
    'thread': threadId,
    'name': roomName,
    'excerpt': excerpt,
  };
  factory SavedMessageLink._decode(Map<String, Object?> json) =>
      SavedMessageLink(
        roomToken: json['room'] as String,
        messageId: json['message'] as int,
        threadId: json['thread'] as int?,
        roomName: json['name'] as String,
        excerpt: json['excerpt'] as String,
      );
}

@immutable
final class MessageCollection {
  const MessageCollection(this.id, this.name, this.messages);
  final String id;
  final String name;
  final List<SavedMessageLink> messages;
}

final class MessageCollectionStore
    extends AccountCollectionStore<MessageCollection> {
  MessageCollectionStore({Directory? directory})
    : super('message-collections-v1', directory);

  Future<String> create(
    AccountId account,
    String name, {
    SavedMessageLink? message,
  }) async {
    final title = name.trim();
    if (title.isEmpty) throw ArgumentError.value(name);
    var id = const Uuid().v4();
    await update(account, (collections) {
      final index = collections.indexWhere(
        (c) => c.name.toLowerCase() == title.toLowerCase(),
      );
      if (index < 0) {
        collections.add(MessageCollection(id, title, [?message]));
      } else {
        final existing = collections[index];
        id = existing.id;
        if (message != null) {
          collections[index] = _membership(existing, message, true);
        }
      }
    });
    return id;
  }

  Future<void> rename(AccountId account, String id, String name) =>
      update(account, (items) {
        final title = name.trim();
        final index = items.indexWhere((c) => c.id == id);
        if (title.isEmpty ||
            index < 0 ||
            items.any(
              (c) => c.id != id && c.name.toLowerCase() == title.toLowerCase(),
            )) {
          throw StateError('Invalid collection name');
        }
        items[index] = MessageCollection(id, title, items[index].messages);
      });

  Future<void> remove(AccountId account, String id) =>
      update(account, (items) => items.removeWhere((c) => c.id == id));

  Future<void> setSaved(
    AccountId account,
    String id,
    SavedMessageLink message, {
    required bool saved,
  }) => update(account, (items) {
    final index = items.indexWhere((c) => c.id == id);
    if (index < 0) throw StateError('Collection no longer exists');
    items[index] = _membership(items[index], message, saved);
  });

  MessageCollection _membership(
    MessageCollection item,
    SavedMessageLink message,
    bool saved,
  ) => MessageCollection(item.id, item.name, [
    if (saved) message,
    ...item.messages.where((link) => !link.matches(message)),
  ]);

  @override
  MessageCollection decode(Map<String, Object?> json) =>
      MessageCollection(json['id'] as String, json['name'] as String, [
        for (final item in json['messages'] as List<Object?>)
          SavedMessageLink._decode(item as Map<String, Object?>),
      ]);

  @override
  Map<String, Object?> encode(MessageCollection entry) => {
    'id': entry.id,
    'name': entry.name,
    'messages': [for (final link in entry.messages) link._toJson()],
  };
}
