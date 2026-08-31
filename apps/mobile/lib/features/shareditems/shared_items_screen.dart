import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import '../../data/app_database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../chat/chat_message_content.dart';
import '../chat/chat_room_pane.dart';
import '../search/message_search_thread_screen.dart';
import 'shared_items_service.dart';

enum _SharedItemsViewState { loading, loaded, empty, error }

final class SharedItemsScreen extends ConsumerStatefulWidget {
  const SharedItemsScreen({
    super.key,
    required this.account,
    required this.conversation,
  });

  final StoredAccount account;
  final CachedConversation conversation;

  @override
  ConsumerState<SharedItemsScreen> createState() => _SharedItemsScreenState();
}

final class _SharedItemsScreenState extends ConsumerState<SharedItemsScreen> {
  _SharedItemsViewState _viewState = _SharedItemsViewState.loading;
  List<SharedItemType> _types = const [];
  SharedItemType? _selectedType;
  List<ChatMessage> _messages = const [];
  SharedItemsError? _error;
  SharedItemsError? _loadMoreError;
  int? _cursor;
  bool _moreItemsPossible = false;
  bool _loadingMore = false;
  bool _openingMessage = false;
  int _requestGeneration = 0;
  int _navigationGeneration = 0;
  Completer<void>? _abortRequest;

  @override
  void initState() {
    super.initState();
    unawaited(_loadOverview());
  }

  @override
  void dispose() {
    _requestGeneration++;
    _navigationGeneration++;
    _cancelRequest();
    super.dispose();
  }

  Future<void> _loadOverview() async {
    final operation = _beginRequest();
    setState(() {
      _viewState = _SharedItemsViewState.loading;
      _selectedType = null;
      _types = const [];
      _messages = const [];
      _error = null;
      _loadMoreError = null;
      _cursor = null;
      _moreItemsPossible = false;
    });
    try {
      final overview = await ref
          .read(sharedItemsServiceProvider)
          .overview(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            abortTrigger: operation.abort.future,
          );
      if (!_ownsRequest(operation.generation)) {
        return;
      }
      final types = SharedItemType.values
          .where(overview.messagesByType.containsKey)
          .toList(growable: false);
      if (types.isEmpty) {
        setState(() {
          _types = const [];
          _viewState = _SharedItemsViewState.empty;
        });
        return;
      }
      setState(() {
        _types = types;
        _selectedType = types.first;
      });
      await _loadCategory(types.first);
    } on SharedItemsException catch (failure) {
      _finishWithError(operation.generation, failure.code);
    }
  }

  Future<void> _loadCategory(SharedItemType type) async {
    final operation = _beginRequest();
    setState(() {
      _selectedType = type;
      _viewState = _SharedItemsViewState.loading;
      _messages = const [];
      _error = null;
      _loadMoreError = null;
      _cursor = null;
      _moreItemsPossible = false;
      _loadingMore = false;
    });
    try {
      final page = await ref
          .read(sharedItemsServiceProvider)
          .page(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            type: type,
            lastKnownMessageId: 0,
            abortTrigger: operation.abort.future,
          );
      if (!_ownsCategory(operation.generation, type)) {
        return;
      }
      setState(() {
        _messages = page.messages;
        _cursor = page.lastKnownMessageId;
        _moreItemsPossible = page.moreItemsPossible;
        _viewState = page.messages.isEmpty
            ? _SharedItemsViewState.empty
            : _SharedItemsViewState.loaded;
      });
    } on SharedItemsException catch (failure) {
      _finishWithError(operation.generation, failure.code, type: type);
    }
  }

  Future<void> _loadMore() async {
    final type = _selectedType;
    final cursor = _cursor;
    if (type == null || cursor == null || !_moreItemsPossible || _loadingMore) {
      return;
    }
    final operation = _beginRequest();
    setState(() {
      _loadingMore = true;
      _loadMoreError = null;
    });
    try {
      final page = await ref
          .read(sharedItemsServiceProvider)
          .page(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            type: type,
            lastKnownMessageId: cursor,
            abortTrigger: operation.abort.future,
          );
      if (!_ownsCategory(operation.generation, type)) {
        return;
      }
      setState(() {
        _messages = List.unmodifiable([..._messages, ...page.messages]);
        _cursor = page.lastKnownMessageId;
        _moreItemsPossible = page.moreItemsPossible;
        _loadingMore = false;
      });
    } on SharedItemsException catch (failure) {
      if (!_ownsCategory(operation.generation, type) ||
          failure.code == SharedItemsError.cancelled) {
        return;
      }
      setState(() {
        _loadingMore = false;
        _loadMoreError = failure.code;
      });
    }
  }

  _SharedItemsOperation _beginRequest() {
    _cancelRequest();
    final abort = Completer<void>();
    _abortRequest = abort;
    return _SharedItemsOperation(++_requestGeneration, abort);
  }

  void _cancelRequest() {
    final abort = _abortRequest;
    _abortRequest = null;
    if (abort != null && !abort.isCompleted) {
      abort.complete();
    }
  }

  bool _ownsRequest(int generation) =>
      mounted && generation == _requestGeneration;

  bool _ownsCategory(int generation, SharedItemType type) =>
      _ownsRequest(generation) && _selectedType == type;

  void _finishWithError(
    int generation,
    SharedItemsError error, {
    SharedItemType? type,
  }) {
    if (!_ownsRequest(generation) ||
        (type != null && _selectedType != type) ||
        error == SharedItemsError.cancelled) {
      return;
    }
    setState(() {
      _error = error;
      _viewState = _SharedItemsViewState.error;
    });
  }

  void _retry() {
    final type = _selectedType;
    if (type == null) {
      unawaited(_loadOverview());
    } else {
      unawaited(_loadCategory(type));
    }
  }

  void _selectType(SharedItemType type) {
    if (type != _selectedType) {
      unawaited(_loadCategory(type));
    }
  }

  void _openMessage(ChatMessage message) {
    if (_openingMessage) {
      return;
    }
    setState(() => _openingMessage = true);
    final generation = ++_navigationGeneration;
    final route = ModalRoute.of(context);
    unawaited(_resolveMessage(message, route, generation));
  }

  Future<void> _resolveMessage(
    ChatMessage message,
    ModalRoute<Object?>? route,
    int generation,
  ) async {
    try {
      final target = MessageDestinationTarget.fromChatMessage(message);
      ChatThreadContext? threadContext;
      final threadId = target.threadId;
      if (threadId != null && threadId != target.messageId) {
        try {
          threadContext = await resolveMessageThread(
            repository: ref.read(chatRepositoryProvider),
            accountId: widget.account.id,
            target: target,
            synchronizeThread: () => ref
                .read(chatServiceProvider)
                .syncRoom(
                  accountId: widget.account.id,
                  roomToken: widget.conversation.token,
                  threadId: threadId,
                ),
          );
        } on MessageSearchThreadException catch (failure) {
          if (_ownsNavigation(route, generation)) {
            _showMessageError(failure.code);
          }
          return;
        }
      }
      if (!_ownsNavigation(route, generation)) {
        return;
      }
      if (!mounted) {
        return;
      }
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          settings: const RouteSettings(
            name: '/conversation/shared-items/message',
          ),
          builder: (context) => buildMessageDestination(
            account: widget.account,
            conversation: widget.conversation,
            target: target,
            threadContext: threadContext,
          ),
        ),
      );
    } finally {
      if (mounted && generation == _navigationGeneration) {
        setState(() => _openingMessage = false);
      }
    }
  }

  bool _ownsNavigation(ModalRoute<Object?>? route, int generation) =>
      mounted &&
      generation == _navigationGeneration &&
      route?.isCurrent == true;

  void _showMessageError(MessageSearchThreadError error) {
    final strings = AppLocalizations.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: const Key('shared-items-message-error'),
          content: Text(switch (error) {
            MessageSearchThreadError.unavailable =>
              strings.jumpToMessageNotFound,
            MessageSearchThreadError.credential =>
              strings.syncCredentialMissing,
            MessageSearchThreadError.rateLimited => strings.syncRateLimited,
            MessageSearchThreadError.serviceUnavailable ||
            MessageSearchThreadError.network => strings.chatUnavailable,
          }),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Scaffold(
      key: const Key('shared-items-screen'),
      appBar: AppBar(title: Text(strings.sharedItemsTitle)),
      body: Stack(
        children: [
          Column(
            children: [
              if (_types.isNotEmpty) _categoryPicker(strings),
              Expanded(child: _content(strings)),
            ],
          ),
          if (_openingMessage)
            const Positioned(
              left: 0,
              top: 0,
              right: 0,
              child: LinearProgressIndicator(
                key: Key('shared-items-message-progress'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _categoryPicker(AppLocalizations strings) {
    return SingleChildScrollView(
      key: const Key('shared-items-categories'),
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          for (final type in _types)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: ChoiceChip(
                key: Key('shared-items-category-${type.wireName}'),
                label: Text(_categoryLabel(strings, type)),
                selected: type == _selectedType,
                onSelected: (_) => _selectType(type),
              ),
            ),
        ],
      ),
    );
  }

  Widget _content(AppLocalizations strings) {
    return switch (_viewState) {
      _SharedItemsViewState.loading => const Center(
        child: CircularProgressIndicator(key: Key('shared-items-loading')),
      ),
      _SharedItemsViewState.empty => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            strings.sharedItemsEmpty,
            key: const Key('shared-items-empty'),
            textAlign: TextAlign.center,
          ),
        ),
      ),
      _SharedItemsViewState.error => _errorView(strings),
      _SharedItemsViewState.loaded => _messageList(strings),
    };
  }

  Widget _errorView(AppLocalizations strings) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _errorMessage(strings, _error),
              key: const Key('shared-items-error'),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _retry, child: Text(strings.retry)),
          ],
        ),
      ),
    );
  }

  Widget _messageList(AppLocalizations strings) {
    final extraItem = _moreItemsPossible || _loadMoreError != null ? 1 : 0;
    return ListView.builder(
      key: const Key('shared-items-list'),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
      itemCount: _messages.length + extraItem,
      itemBuilder: (context, index) {
        if (index < _messages.length) {
          final message = _messages[index];
          return _SharedMessageTile(
            account: widget.account,
            message: message,
            onTap: _openingMessage ? null : () => _openMessage(message),
          );
        }
        if (_loadMoreError != null) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Text(
                  _errorMessage(strings, _loadMoreError),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: _loadMore,
                  child: Text(strings.retry),
                ),
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.all(16),
          child: OutlinedButton(
            key: const Key('shared-items-load-more'),
            onPressed: _loadingMore ? null : _loadMore,
            child: _loadingMore
                ? const SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(strings.sharedItemsLoadMore),
          ),
        );
      },
    );
  }
}

final class _SharedMessageTile extends StatelessWidget {
  const _SharedMessageTile({
    required this.account,
    required this.message,
    required this.onTap,
  });

  final StoredAccount account;
  final ChatMessage message;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final localizations = MaterialLocalizations.of(context);
    final sentAt = DateTime.fromMillisecondsSinceEpoch(
      message.timestamp * 1000,
    ).toLocal();
    final sentLabel =
        '${localizations.formatShortDate(sentAt)} '
        '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(sentAt))}';
    return Card(
      key: Key('shared-item-${message.messageId}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      message.actorDisplayName,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      sentLabel,
                      textAlign: TextAlign.end,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ChatMessageContent(
                account: account,
                message: message,
                fallbackText: message.message,
                foregroundColor: colors.onSurface,
                showReplyPreview: false,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _SharedItemsOperation {
  const _SharedItemsOperation(this.generation, this.abort);

  final int generation;
  final Completer<void> abort;
}

String _categoryLabel(AppLocalizations strings, SharedItemType type) =>
    switch (type) {
      SharedItemType.audio => strings.sharedItemsCategoryAudio,
      SharedItemType.deckCard => strings.sharedItemsCategoryDeckCards,
      SharedItemType.file => strings.sharedItemsCategoryFiles,
      SharedItemType.location => strings.sharedItemsCategoryLocations,
      SharedItemType.media => strings.sharedItemsCategoryMedia,
      SharedItemType.other => strings.sharedItemsCategoryOther,
      SharedItemType.pinned => strings.sharedItemsCategoryPinned,
      SharedItemType.poll => strings.sharedItemsCategoryPolls,
      SharedItemType.recording => strings.sharedItemsCategoryRecordings,
      SharedItemType.voice => strings.sharedItemsCategoryVoice,
    };

String _errorMessage(AppLocalizations strings, SharedItemsError? error) =>
    switch (error) {
      SharedItemsError.accountMissing ||
      SharedItemsError.conversationMissing ||
      SharedItemsError.roomNotFound => strings.jumpToMessageConversationMissing,
      SharedItemsError.credentialMissing ||
      SharedItemsError.reauthenticationRequired =>
        strings.syncCredentialMissing,
      SharedItemsError.unsupported => strings.sharedItemsUnsupported,
      SharedItemsError.lobbyRestricted => strings.sharedItemsLobbyRestricted,
      SharedItemsError.rateLimited => strings.syncRateLimited,
      SharedItemsError.serviceUnavailable ||
      SharedItemsError.network => strings.chatUnavailable,
      SharedItemsError.invalidResponse => strings.sharedItemsInvalidResponse,
      SharedItemsError.cancelled || null => strings.chatUnavailable,
    };
