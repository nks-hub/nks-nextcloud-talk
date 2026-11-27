part of 'conversation_shell.dart';

void openMessageSearch(
  BuildContext context,
  String accountId, {
  String? roomToken,
  String? roomName,
}) {
  Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/search/messages'),
      builder: (context) => _MessageSearchRoute(
        accountId: accountId,
        roomToken: roomToken,
        roomName: roomName,
      ),
    ),
  );
}

typedef _SearchDestination = ({
  StoredAccount account,
  CachedConversation conversation,
  MessageDestinationTarget target,
  ChatThreadContext? threadContext,
});

final class _MessageSearchRoute extends ConsumerStatefulWidget {
  const _MessageSearchRoute({
    required this.accountId,
    this.roomToken,
    this.roomName,
  });

  final String accountId;
  final String? roomToken;
  final String? roomName;

  @override
  ConsumerState<_MessageSearchRoute> createState() =>
      _MessageSearchRouteState();
}

final class _MessageSearchRouteState
    extends ConsumerState<_MessageSearchRoute> {
  var _generation = 0;
  var _resultPending = false;

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        MessageSearchScreen(
          accountId: widget.accountId,
          service: ref.watch(messageSearchServiceProvider),
          onResultSelected: _openResult,
          searchPeople: (term) => ref
              .read(newConversationServiceProvider)
              .searchRecipients(accountId: widget.accountId, searchTerm: term),
          roomToken: widget.roomToken,
          roomName: widget.roomName,
        ),
        IgnorePointer(
          key: const Key('message-search-result-guard'),
          ignoring: _resultPending,
          child: const SizedBox.shrink(),
        ),
      ],
    );
  }

  bool _accountIsCurrent() =>
      mounted &&
      ref.read(selectedAccountProvider).valueOrNull?.id == widget.accountId;

  void _openResult(MessageSearchSelection selection) {
    if (_resultPending) return;
    setState(() => _resultPending = true);
    final generation = ++_generation;
    final route = ModalRoute.of(context);
    bool current() =>
        generation == _generation &&
        route?.isCurrent == true &&
        _accountIsCurrent() &&
        selection.canOpen(selection.index);

    unawaited(_openDestination(selection, current, generation));
  }

  Future<void> _openDestination(
    MessageSearchSelection selection,
    bool Function() current,
    int generation,
  ) async {
    try {
      final first = await _resolve(selection.result, current);
      if (!mounted || !current()) return;
      if (first == null) {
        final strings = AppLocalizations.of(context);
        Navigator.of(context).pop();
        _showSearchNotice(
          context,
          const Key('search-conversation-missing'),
          strings.jumpToMessageConversationMissing,
        );
        return;
      }

      FocusManager.instance.primaryFocus?.unfocus();
      unawaited(
        Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            settings: const RouteSettings(name: '/search/messages/match'),
            builder: (_) => _SearchResultDestination(
              selection: selection,
              first: first,
              resolve: _resolve,
              accountIsCurrent: _accountIsCurrent,
            ),
          ),
        ),
      );
    } on MessageSearchThreadException catch (error) {
      if (mounted && current()) _showSearchThreadError(context, error.code);
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _resultPending = false);
      }
    }
  }

  Future<_SearchDestination?> _resolve(
    MessageSearchResult result,
    bool Function() current,
  ) async {
    if (!current()) return null;
    final accounts = ref.read(accountRepositoryProvider);
    final account = await accounts.getAccount(widget.accountId);
    if (!current() || account == null) return null;
    final conversation = await accounts.getConversation(
      accountId: widget.accountId,
      token: result.roomToken.value,
    );
    if (!current() || conversation == null) return null;

    final target = MessageDestinationTarget.fromSearchResult(result);
    final threadId = result.threadId;
    final threadContext = threadId != null && threadId != result.messageId
        ? await resolveMessageThread(
            repository: ref.read(chatRepositoryProvider),
            accountId: widget.accountId,
            target: target,
            synchronizeThread: () => ref
                .read(chatServiceProvider)
                .syncRoom(
                  accountId: widget.accountId,
                  roomToken: result.roomToken.value,
                  threadId: threadId,
                  readerIsActive: () =>
                      current() && ref.read(windowActiveProvider),
                ),
          )
        : null;
    if (!current()) return null;
    return (
      account: account,
      conversation: conversation,
      target: target,
      threadContext: threadContext,
    );
  }
}

final class _SearchResultDestination extends StatefulWidget {
  const _SearchResultDestination({
    required this.selection,
    required this.first,
    required this.resolve,
    required this.accountIsCurrent,
  });

  final MessageSearchSelection selection;
  final _SearchDestination first;
  final Future<_SearchDestination?> Function(
    MessageSearchResult result,
    bool Function() current,
  )
  resolve;
  final bool Function() accountIsCurrent;

  @override
  State<_SearchResultDestination> createState() =>
      _SearchResultDestinationState();
}

final class _SearchResultDestinationState
    extends State<_SearchResultDestination> {
  late int _index = widget.selection.index;
  late _SearchDestination _destination = widget.first;
  var _moving = false;

  Future<void> _move(int offset) async {
    final index = _index + offset;
    final route = ModalRoute.of(context);
    final strings = AppLocalizations.of(context);
    bool current() =>
        mounted && route?.isCurrent == true && widget.accountIsCurrent();
    if (_moving || !current() || !widget.selection.canOpen(index)) return;

    setState(() => _moving = true);
    try {
      final result = await widget.selection.load(index);
      if (!current() || result == null) return;
      final destination = await widget.resolve(result, current);
      if (!mounted || !current()) return;
      if (destination == null) {
        _showSearchNotice(
          context,
          const Key('search-conversation-missing'),
          strings.jumpToMessageConversationMissing,
        );
        return;
      }
      setState(() {
        _index = index;
        _destination = destination;
      });
    } on MessageSearchException {
      if (mounted && current()) {
        _showSearchNotice(
          context,
          const Key('search-page-unavailable'),
          strings.searchMessagesLoadMoreError,
        );
      }
    } on MessageSearchThreadException catch (error) {
      if (mounted && current()) _showSearchThreadError(context, error.code);
    } finally {
      if (mounted) setState(() => _moving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final select = widget.selection;
    final target = _destination.target;
    return KeyedSubtree(
      key: ValueKey((
        target.roomToken,
        _destination.threadContext?.rootMessageId,
      )),
      child: buildMessageDestination(
        account: _destination.account,
        conversation: _destination.conversation,
        target: target,
        threadContext: _destination.threadContext,
        searchNavigation: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: SizedBox(
            height: 48,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (_moving)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                IconButton(
                  key: const Key('search-previous-match'),
                  tooltip: strings.searchMessagesPreviousMatch,
                  icon: const Icon(Icons.keyboard_arrow_up_rounded),
                  onPressed: !_moving && select.canOpen(_index - 1)
                      ? () => unawaited(_move(-1))
                      : null,
                ),
                IconButton(
                  key: const Key('search-next-match'),
                  tooltip: strings.searchMessagesNextMatch,
                  icon: const Icon(Icons.keyboard_arrow_down_rounded),
                  onPressed: !_moving && select.canOpen(_index + 1)
                      ? () => unawaited(_move(1))
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

void _showSearchNotice(BuildContext context, Key key, String message) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(key: key, content: Text(message)));
}

void _showSearchThreadError(
  BuildContext context,
  MessageSearchThreadError error,
) {
  final strings = AppLocalizations.of(context);
  _showSearchNotice(
    context,
    const Key('search-thread-unavailable'),
    switch (error) {
      MessageSearchThreadError.unavailable => strings.jumpToMessageNotFound,
      MessageSearchThreadError.credential => strings.syncCredentialMissing,
      MessageSearchThreadError.rateLimited => strings.syncRateLimited,
      MessageSearchThreadError.serviceUnavailable ||
      MessageSearchThreadError.network => strings.chatUnavailable,
    },
  );
}
