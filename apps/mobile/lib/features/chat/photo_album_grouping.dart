import 'package:talk_protocol/talk_protocol.dart';

/// Indices stay tied to server messages for read cursors, jumps and actions.
List<List<int>> groupPhotoAlbums(
  List<ChatMessage?> messages, {
  required bool Function(int index) canGroup,
  required bool Function(int index) boundaryBefore,
}) {
  final groups = <List<int>>[];
  var current = <int>[];
  final positions = <int>{};
  for (var index = 0; index < messages.length; index++) {
    final message = messages[index];
    final album = message == null
        ? null
        : ChatPhotoAlbumReference.tryParse(message.referenceId);
    if (album == null || !canGroup(index) || message!.isThread == true) {
      if (current.length > 1) groups.add(current);
      current = [];
      positions.clear();
      continue;
    }
    if (current.isNotEmpty) {
      final previous = messages[current.last]!;
      final previousAlbum = ChatPhotoAlbumReference.tryParse(
        previous.referenceId,
      )!;
      if (boundaryBefore(index) ||
          previousAlbum.albumId != album.albumId ||
          previousAlbum.count != album.count ||
          positions.contains(album.index) ||
          previous.roomToken != message.roomToken ||
          previous.actorType != message.actorType ||
          previous.actorId != message.actorId ||
          _threadId(previous) != _threadId(message) ||
          _parentId(previous.parent) != _parentId(message.parent)) {
        if (current.length > 1) groups.add(current);
        current = [];
        positions.clear();
      }
    }
    current.add(index);
    positions.add(album.index);
  }
  if (current.length > 1) groups.add(current);
  return groups;
}

int? _threadId(ChatMessage message) =>
    message.parent == null && message.threadId == message.messageId
    ? null
    : message.threadId;

int? _parentId(ChatMessageParent? parent) => switch (parent) {
  ChatFullParent(:final messageId) ||
  ChatDeletedParent(:final messageId) => messageId,
  null => null,
};
