part of 'conversation_list_actions.dart';

typedef _UndeliveredRoom = ({
  CachedConversation room,
  List<UndeliveredMessage> messages,
});

List<_UndeliveredRoom> _undeliveredRooms(
  List<UndeliveredMessage> messages,
  List<CachedConversation> rooms,
  String query,
) {
  if (messages.isEmpty) return const [];
  final byToken = {for (final room in rooms) room.token: room};
  final groups = <String, _UndeliveredRoom>{};
  for (final message in messages) {
    final room = byToken[message.room];
    if (room == null ||
        room.accountId != message.account ||
        (!room.displayName.toLowerCase().contains(query) &&
            !message.text.toLowerCase().contains(query))) {
      continue;
    }
    final group = groups.putIfAbsent(
      room.token,
      () => (room: room, messages: []),
    );
    group.messages.add(message);
  }
  return groups.values.toList(growable: false);
}

String _deliveryLabel(AppLocalizations strings, String state) =>
    switch (state) {
      'queued' => strings.outboxQueued,
      'sending' => strings.outboxSending,
      'retryable' => strings.outboxRetryable,
      'awaitingConfirmation' => strings.outboxAwaitingConfirmation,
      _ => strings.outboxFailed,
    };

final class _UndeliveredTile extends StatelessWidget {
  const _UndeliveredTile({required this.group, required this.onOpen});
  final _UndeliveredRoom group;
  final ValueChanged<UndeliveredMessage> onOpen;
  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final first = group.messages.first;
    final count = group.messages.length;
    Widget label(UndeliveredMessage m) => Text(
      "${m.thread == null ? '' : '${strings.thread} #${m.thread} · '}"
      '${_deliveryLabel(strings, m.state)} · ${normalizeGiphyReferencePreview(m.text)}',
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
    return Semantics(
      hint: strings.undeliveredOpenConversation,
      child: ListTile(
        key: ValueKey('undelivered-room-${group.room.token}'),
        leading: Badge.count(
          count: count,
          child: const Icon(Icons.outbox_outlined),
        ),
        title: Text(
          group.room.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: label(first),
        onTap: () => onOpen(first),
        trailing: count == 1
            ? null
            : PopupMenuButton<UndeliveredMessage>(
                key: ValueKey('undelivered-choose-${group.room.token}'),
                tooltip: '${strings.conversationFilterUndelivered} ($count)',
                onSelected: onOpen,
                itemBuilder: (_) => [
                  for (final message in group.messages)
                    PopupMenuItem(value: message, child: label(message)),
                ],
              ),
      ),
    );
  }
}
