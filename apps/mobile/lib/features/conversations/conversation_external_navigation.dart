part of 'conversation_shell.dart';

extension _ExternalMessageNavigation on _ConversationShellState {
  Future<String?> _chooseLinkAccount(List<StoredAccount> accounts) {
    return showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(AppLocalizations.of(context).switchAccount),
        children: [
          for (final account in accounts)
            ListTile(
              key: ValueKey('deep-link-account-${account.id}'),
              title: Text(account.loginName),
              subtitle: Text('${account.loginName} · ${account.serverUrl}'),
              onTap: () => Navigator.pop(context, account.id),
            ),
        ],
      ),
    );
  }

  Future<void> _openExternalMessage(
    StoredAccount account,
    CachedConversation room,
    int? messageId,
    int? threadHint,
    int generation,
  ) async {
    final token = room.token;
    bool current() =>
        mounted &&
        generation == _externalOpenGeneration &&
        _selectedAccountId == account.id &&
        _selectedConversationToken == token;
    final store = ref.read(chatRepositoryProvider);
    final service = ref.read(chatServiceProvider);
    final id = messageId ?? threadHint!;
    Future<CachedChatMessage?> read(int id) => store.getMessage(
      accountId: account.id,
      roomToken: token,
      messageId: id,
    );
    bool readerActive() => current() && ref.read(windowActiveProvider);
    Future<void> sync(int thread) async {
      await service.syncRoom(
        accountId: account.id,
        roomToken: token,
        threadId: thread,
        readerIsActive: readerActive,
      );
    }

    final strings = AppLocalizations.of(context);
    void unavailable() {
      if (!current()) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          key: const Key('external-message-unavailable'),
          content: Text(strings.jumpToMessageNotFound),
        ),
      );
    }

    var cached = await read(id);
    if (!current()) return;
    if (threadHint == null && cached == null) {
      // A notification can carry only a message ID. Its context may identify
      // a thread outside the room timeline even on the first local open.
      try {
        await service.loadMessageContext(
          accountId: account.id,
          roomToken: token,
          messageId: id,
          readerIsActive: readerActive,
        );
        if (!current()) return;
        cached = await read(id);
      } on ChatServiceException {
        // The room's regular jump also supports servers without chat context.
      }
    }
    if (!current()) return;
    if (cached?.deleted == true) {
      unavailable();
      return;
    }
    final threadId = threadHint ?? cached?.threadId;
    if (threadId == null ||
        threadId <= 0 ||
        (threadHint == null && threadId == id)) {
      await WidgetsBinding.instance.endOfFrame;
      if (current()) _jumpInSelectedRoom(id);
      return;
    }

    try {
      ChatThreadContext? thread;
      if (threadId == id) {
        if (cached == null) {
          await sync(threadId);
          if (!current()) return;
          cached = await read(id);
        }
        if (cached != null) {
          thread = ChatThreadContext.fromCachedRoot(
            accountId: account.id,
            roomToken: token,
            root: cached,
          );
        }
      } else {
        thread = await resolveMessageThread(
          repository: store,
          accountId: account.id,
          target: MessageDestinationTarget(
            roomToken: ConversationToken.parse(token, path: 'link.room'),
            messageId: id,
            threadId: threadId,
          ),
          synchronizeThread: () => sync(threadId),
        );
      }
      if (!mounted || !current()) return;
      if (thread == null) {
        unavailable();
        return;
      }
      final destination = ChatThreadScreen(
        account: account,
        conversation: room,
        threadContext: thread,
        jumpToMessageId: id,
      );
      unawaited(
        Navigator.of(
          context,
        ).push<void>(MaterialPageRoute<void>(builder: (_) => destination)),
      );
    } on MessageSearchThreadException catch (error) {
      if (!mounted || !current()) return;
      if (error.code == MessageSearchThreadError.unavailable) {
        unavailable();
      } else {
        _showSearchThreadError(context, error.code);
      }
    } on ChatServiceException {
      if (mounted && current()) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(strings.threadManagementOpenUnavailable)),
        );
      }
    }
  }
}
