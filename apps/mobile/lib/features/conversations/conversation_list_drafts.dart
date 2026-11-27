part of 'conversation_list_actions.dart';

final _accountDrafts = StreamProvider.autoDispose
    .family<List<StoredChatDraft>, String>(
      (ref, id) => ref.watch(chatRepositoryProvider).watchDrafts(id),
    );

typedef _ListedDraft = ({
  StoredChatDraft draft,
  CachedConversation room,
  int? thread,
});

List<_ListedDraft> _matchDrafts(
  String account,
  List<StoredChatDraft> drafts,
  List<CachedConversation> rooms,
  String query,
) {
  final byToken = {for (final room in rooms) room.token: room};
  final result = <_ListedDraft>[];
  for (final draft in drafts) {
    final room = byToken[draft.roomToken];
    if (room == null ||
        draft.accountId != account ||
        room.accountId != account ||
        (!room.displayName.toLowerCase().contains(query) &&
            !draft.draftText.toLowerCase().contains(query))) {
      continue;
    }
    final scope = draft.scopeKey;
    final thread = scope.startsWith('thread:')
        ? int.tryParse(scope.substring(7))
        : null;
    if (scope != 'root' &&
        (thread == null || thread <= 0 || scope != 'thread:$thread')) {
      continue;
    }
    result.add((draft: draft, room: room, thread: thread));
  }
  return result;
}

extension _DraftNavigation on _ConversationListViewState {
  Future<void> _openDraft(_ListedDraft entry) => _openEditor(
    entry.room,
    entry.thread,
    onValidated: () {
      ref.read(composerDraftFocusProvider.notifier).state = (
        accountId: widget.account.id,
        roomToken: entry.room.token,
        threadId: entry.thread,
      );
    },
  );

  Future<void> _openEditor(
    CachedConversation room,
    int? id, {
    required VoidCallback onValidated,
  }) async {
    final generation = ++_openGeneration;
    final route = ModalRoute.of(context);
    final account = widget.account;
    bool current() =>
        generation == _openGeneration &&
        widget.account.id == account.id &&
        route?.isCurrent != false;
    if (account.id != room.accountId) return;
    final token = room.token;
    if (id == null) {
      onValidated();
      widget.onSelect(room);
      return;
    }
    final store = ref.read(chatRepositoryProvider);
    try {
      var root = await store.getMessage(
        accountId: account.id,
        roomToken: token,
        messageId: id,
      );
      if (!mounted || !current()) return;
      if (root == null) {
        await ref
            .read(chatServiceProvider)
            .syncRoom(accountId: account.id, roomToken: token, threadId: id);
        root = await store.getMessage(
          accountId: account.id,
          roomToken: token,
          messageId: id,
        );
      }
      if (!mounted || !current()) return;
      final thread = root == null
          ? null
          : ChatThreadContext.fromCachedRoot(
              accountId: account.id,
              roomToken: token,
              root: root,
            );
      if (thread != null && thread.rootMessageId == id) {
        onValidated();
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            settings: const RouteSettings(name: '/chat/thread'),
            builder: (_) => ChatThreadScreen(
              account: account,
              conversation: room,
              threadContext: thread,
            ),
          ),
        );
        return;
      }
    } on Exception {
      // A missing root cannot safely be opened as an ordinary room.
    }
    if (mounted && current()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context).threadManagementOpenUnavailable,
          ),
        ),
      );
    }
  }
}

final class _DraftTile extends StatelessWidget {
  const _DraftTile({required this.entry, required this.onTap});
  final _ListedDraft entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final draft = entry.draft;
    final thread = entry.thread;
    return ListTile(
      key: ValueKey('draft-${draft.roomToken}-${draft.scopeKey}'),
      leading: Icon(
        thread == null ? Icons.edit_outlined : Icons.forum_outlined,
      ),
      title: Text(
        thread == null
            ? entry.room.displayName
            : '${entry.room.displayName} · ${AppLocalizations.of(context).thread} #$thread',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        draft.draftText.replaceAll(RegExp(r'\s+'), ' ').trim(),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        _formatActivity(context, draft.updatedAtMillis ~/ 1000),
        style: Theme.of(context).textTheme.labelSmall,
      ),
      onTap: onTap,
    );
  }
}
