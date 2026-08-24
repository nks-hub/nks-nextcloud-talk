import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import '../../core/foreground_sync_loop.dart';
import '../../data/app_database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../conversations/conversation_avatar_widget.dart';
import 'chat_message_content.dart';
import 'chat_participant_avatar.dart';
import 'chat_service.dart';
import 'composer/attachment_submission.dart';
import 'composer/chat_media_composer.dart';
import 'composer/composer_text_editing.dart';
import 'composer/emoji_picker.dart';
import 'composer/giphy.dart';

final class ChatRoomScreen extends StatelessWidget {
  const ChatRoomScreen({
    super.key,
    required this.account,
    required this.conversation,
  });

  final StoredAccount account;
  final CachedConversation conversation;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('chat-room-screen'),
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            ExcludeSemantics(
              child: ConversationAvatar(
                account: account,
                conversation: conversation,
                radius: 18,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                conversation.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        top: false,
        child: ChatRoomPane(account: account, conversation: conversation),
      ),
    );
  }
}

final class ChatThreadScreen extends StatelessWidget {
  const ChatThreadScreen({
    super.key,
    required this.account,
    required this.conversation,
    required this.threadId,
  }) : assert(threadId > 0);

  final StoredAccount account;
  final CachedConversation conversation;
  final int threadId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: Key('chat-thread-screen-$threadId'),
      appBar: AppBar(title: Text(AppLocalizations.of(context).thread)),
      body: SafeArea(
        top: false,
        child: ChatRoomPane(
          account: account,
          conversation: conversation,
          threadId: threadId,
        ),
      ),
    );
  }
}

final class ChatRoomPane extends ConsumerStatefulWidget {
  const ChatRoomPane({
    super.key,
    required this.account,
    required this.conversation,
    this.showHeader = false,
    this.threadId,
  }) : assert(threadId == null || threadId > 0);

  final StoredAccount account;
  final CachedConversation conversation;
  final bool showHeader;
  final int? threadId;

  @override
  ConsumerState<ChatRoomPane> createState() => _ChatRoomPaneState();
}

final class _ChatRoomPaneState extends ConsumerState<ChatRoomPane>
    with WidgetsBindingObserver {
  final TextEditingController _composer = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  ForegroundSyncLoop? _syncLoop;
  ChatLiveRoomBinding? _liveBinding;
  int _syncGeneration = 0;
  bool _syncing = false;
  bool _loadingOlder = false;
  bool _sending = false;
  bool _initialAttemptFinished = false;
  bool _giphyRequested = false;
  ChatServiceError? _localError;

  ChatRoomProviderKey get _key => (
    accountId: widget.account.id,
    roomToken: widget.conversation.token,
    threadId: widget.threadId,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_handleScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_restartLiveSync());
    });
  }

  @override
  void didUpdateWidget(covariant ChatRoomPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.id == widget.account.id &&
        oldWidget.conversation.token == widget.conversation.token &&
        oldWidget.threadId == widget.threadId) {
      return;
    }
    _composer.clear();
    _localError = null;
    _initialAttemptFinished = false;
    _giphyRequested = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_restartLiveSync());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _syncGeneration++;
    _liveBinding?.close();
    unawaited(_syncLoop?.stop());
    _liveBinding = null;
    _syncLoop = null;
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    _composer.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_restartLiveSync());
      return;
    }
    unawaited(_stopLiveSync());
  }

  Future<void> _sync() => _restartLiveSync();

  Future<void> _restartLiveSync() async {
    final generation = ++_syncGeneration;
    final previousBinding = _liveBinding;
    final previousLoop = _syncLoop;
    _liveBinding = null;
    _syncLoop = null;
    previousBinding?.close();
    await previousLoop?.stop();
    if (!mounted ||
        generation != _syncGeneration ||
        !_isForegroundLifecycleState(WidgetsBinding.instance.lifecycleState)) {
      return;
    }

    final binding = ref
        .read(chatServiceProvider)
        .bindLiveRoom(
          accountId: widget.account.id,
          roomToken: widget.conversation.token,
          threadId: widget.threadId,
        );
    var showProgress = true;
    late final ForegroundSyncLoop loop;
    loop = ForegroundSyncLoop(
      task: (cancellation) => _runLiveCycle(binding, cancellation, generation),
      successInterval: const Duration(seconds: 1),
      retryBaseDelay: const Duration(seconds: 2),
      retryMaximumDelay: const Duration(minutes: 1),
      onCycleStarted: () {
        if (showProgress) {
          _setSyncing(generation, true);
        }
      },
      onSuccess: () {
        showProgress = false;
        _setSyncSuccess(generation);
      },
      onError: (error) {
        showProgress = false;
        _setSyncError(generation, error);
      },
    );
    if (!mounted || generation != _syncGeneration) {
      binding.close();
      return;
    }
    _liveBinding = binding;
    _syncLoop = loop;
    loop.start();
  }

  Future<void> _stopLiveSync() async {
    final generation = ++_syncGeneration;
    final binding = _liveBinding;
    final loop = _syncLoop;
    _liveBinding = null;
    _syncLoop = null;
    binding?.close();
    await loop?.stop();
    if (mounted && generation == _syncGeneration && _syncing) {
      setState(() => _syncing = false);
    }
  }

  Future<void> _runLiveCycle(
    ChatLiveRoomBinding binding,
    Future<void> cancellation,
    int generation,
  ) async {
    try {
      await binding.synchronize(abortTrigger: cancellation);
    } on ChatServiceException catch (error) {
      if (_isTerminalLiveError(error.code)) {
        _setSyncError(generation, error);
        await cancellation;
        return;
      }
      rethrow;
    }
  }

  void _setSyncing(int generation, bool value) {
    if (!mounted || generation != _syncGeneration || _syncing == value) {
      return;
    }
    setState(() => _syncing = value);
  }

  void _setSyncSuccess(int generation) {
    if (!mounted || generation != _syncGeneration) {
      return;
    }
    setState(() {
      _syncing = false;
      _initialAttemptFinished = true;
      _localError = null;
    });
  }

  void _setSyncError(int generation, Object error) {
    if (!mounted || generation != _syncGeneration) {
      return;
    }
    final code = error is ChatServiceException
        ? error.code
        : ChatServiceError.invalidResponse;
    setState(() {
      _syncing = false;
      _initialAttemptFinished = true;
      _localError = code;
    });
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder) {
      return;
    }
    final scope = ref.read(chatScopeProvider(_key)).valueOrNull;
    if (scope?.hasHistory != true) {
      return;
    }
    setState(() => _loadingOlder = true);
    try {
      await ref
          .read(chatServiceProvider)
          .loadOlder(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            threadId: widget.threadId,
          );
      if (mounted) {
        setState(() => _localError = null);
      }
    } on ChatServiceException catch (error) {
      if (mounted) {
        setState(() => _localError = error.code);
      }
    } on Object {
      if (mounted) {
        setState(() => _localError = ChatServiceError.invalidResponse);
      }
    } finally {
      if (mounted) {
        setState(() => _loadingOlder = false);
      }
    }
  }

  void _handleScroll() {
    if (!_scrollController.hasClients || _loadingOlder) {
      return;
    }
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 160) {
      _loadOlder();
    }
  }

  Future<void> _send() async {
    final message = _composer.text.trim();
    if (message.isEmpty || _sending || widget.conversation.readOnly != 0) {
      return;
    }
    setState(() => _sending = true);
    try {
      await ref
          .read(chatServiceProvider)
          .sendText(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            message: message,
            threadId: widget.threadId,
          );
      _composer.clear();
      if (_scrollController.hasClients) {
        await _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
      if (mounted) {
        setState(() => _localError = null);
      }
    } on ChatServiceException catch (error) {
      if (mounted) {
        setState(() => _localError = error.code);
      }
    } on Object {
      if (mounted) {
        setState(() => _localError = ChatServiceError.invalidResponse);
      }
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
    }
  }

  Future<void> _showEmojiPicker() async {
    if (_sending || widget.conversation.readOnly != 0) {
      return;
    }
    final strings = AppLocalizations.of(context);
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) => Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: SizedBox(
            height: MediaQuery.sizeOf(sheetContext).height * 0.72,
            child: EmojiPicker(
              labels: EmojiPickerLabels(
                searchHint: strings.emojiSearchHint,
                noResults: strings.emojiNoResults,
                categoryLabels: <EmojiCategory, String>{
                  EmojiCategory.smileys: strings.emojiCategorySmileys,
                  EmojiCategory.people: strings.emojiCategoryPeople,
                  EmojiCategory.animals: strings.emojiCategoryAnimals,
                  EmojiCategory.food: strings.emojiCategoryFood,
                  EmojiCategory.activities: strings.emojiCategoryActivities,
                  EmojiCategory.travel: strings.emojiCategoryTravel,
                  EmojiCategory.objects: strings.emojiCategoryObjects,
                  EmojiCategory.symbols: strings.emojiCategorySymbols,
                },
              ),
              onSelected: (choice) {
                if (!insertComposerText(_composer, choice.glyph)) {
                  _showComposerLimitError();
                  return;
                }
                Navigator.of(sheetContext).pop();
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _requestGiphy({bool refresh = false}) async {
    if (_sending || widget.conversation.readOnly != 0) {
      return;
    }
    if (!_giphyRequested) {
      setState(() => _giphyRequested = true);
      await Future<void>.delayed(Duration.zero);
    }
    if (refresh) {
      ref.invalidate(giphyRepositoryProvider(widget.account.id));
    }
    try {
      final repository = await ref.read(
        giphyRepositoryProvider(widget.account.id).future,
      );
      if (!mounted || repository == null) {
        return;
      }
      await _showGiphyPicker(repository);
    } on Object {
      // The watched provider exposes a localized retry state in the composer.
    }
  }

  Future<void> _showGiphyPicker(HttpGiphyRepository repository) async {
    if (!mounted) {
      return;
    }
    final strings = AppLocalizations.of(context);
    final controller = GiphyController(repository: repository);
    unawaited(controller.loadTrending());
    try {
      await showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        builder: (sheetContext) => Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: SizedBox(
              height: MediaQuery.sizeOf(sheetContext).height * 0.72,
              child: GiphyPicker(
                controller: controller,
                labels: GiphyPickerLabels(
                  searchHint: strings.giphySearchHint,
                  noResults: strings.giphyNoResults,
                  retry: strings.retry,
                  loadMore: strings.giphyLoadMore,
                ),
                thumbnailBuilder: (_, entry) => ExcludeSemantics(
                  child: _GiphyThumbnail(repository: repository, entry: entry),
                ),
                onSelected: (entry) {
                  if (!controller.insertSelection(_composer, entry)) {
                    _showComposerLimitError();
                    return;
                  }
                  Navigator.of(sheetContext).pop();
                },
              ),
            ),
          ),
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  void _showComposerLimitError() {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).messageTooLong)),
      );
  }

  Future<void> _confirmResend(StoredTextSendOperation operation) async {
    final strings = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('duplicate-risk-dialog'),
        title: Text(strings.duplicateRiskTitle),
        content: Text(strings.duplicateRiskBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            key: const Key('confirm-duplicate-risk'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(strings.confirmResend),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    try {
      await ref
          .read(chatServiceProvider)
          .resendText(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            operationId: operation.operationId,
          );
      if (mounted) {
        setState(() => _localError = null);
      }
    } on ChatServiceException catch (error) {
      if (mounted) {
        setState(() => _localError = error.code);
      }
    } on Object {
      if (mounted) {
        setState(() => _localError = ChatServiceError.invalidResponse);
      }
    }
  }

  void _openThread(CachedChatMessage message) {
    if (widget.threadId != null || message.messageId < 1) {
      return;
    }
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (context) => ChatThreadScreen(
            account: widget.account,
            conversation: widget.conversation,
            threadId: message.messageId,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final messagesValue = ref.watch(chatMessagesProvider(_key));
    final operationsValue = ref.watch(textSendOperationsProvider(_key));
    final scopeValue = ref.watch(chatScopeProvider(_key));
    final attachmentDependencies = widget.conversation.readOnly == 0
        ? ref.watch(chatAttachmentDependenciesProvider(_key))
        : null;
    final messages = messagesValue.valueOrNull ?? const <CachedChatMessage>[];
    final operations =
        operationsValue.valueOrNull ?? const <StoredTextSendOperation>[];
    final pending = operations
        .where((operation) => operation.outboxState != 'completed')
        .toList(growable: false);
    final scope = scopeValue.valueOrNull;
    final showInitialLoading =
        !_initialAttemptFinished && messages.isEmpty && pending.isEmpty;
    final error = _localError ?? _storedError(scope?.lastSyncError);
    final strings = AppLocalizations.of(context);
    final giphy = _giphyRequested && widget.conversation.readOnly == 0
        ? ref.watch(giphyRepositoryProvider(widget.account.id))
        : null;
    final giphyRepository = giphy?.valueOrNull;
    final String giphyTooltip;
    final VoidCallback? giphyAction;
    if (giphy == null) {
      giphyTooltip = strings.openGiphyPicker;
      giphyAction = () => unawaited(_requestGiphy());
    } else if (giphy.isLoading) {
      giphyTooltip = strings.giphyChecking;
      giphyAction = null;
    } else if (giphy.hasError) {
      giphyTooltip = strings.giphyRetry;
      giphyAction = () => unawaited(_requestGiphy(refresh: true));
    } else if (giphyRepository == null) {
      giphyTooltip = strings.giphyUnavailable;
      giphyAction = null;
    } else {
      giphyTooltip = strings.openGiphyPicker;
      giphyAction = () => unawaited(_showGiphyPicker(giphyRepository));
    }
    final idleComposerActions = <Widget>[
      IconButton(
        key: const Key('open-emoji-picker'),
        onPressed: _sending ? null : () => unawaited(_showEmojiPicker()),
        tooltip: strings.openEmojiPicker,
        icon: const Icon(Icons.emoji_emotions_outlined),
      ),
      IconButton(
        key: const Key('open-giphy-picker'),
        onPressed: _sending ? null : giphyAction,
        tooltip: giphyTooltip,
        icon: giphy?.isLoading ?? false
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.gif_box_outlined),
      ),
      IconButton.filled(
        key: const Key('send-message'),
        onPressed: _sending ? null : _send,
        tooltip: strings.sendMessage,
        icon: _sending
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.send_rounded),
      ),
    ];

    return Column(
      key: const Key('chat-room-pane'),
      children: [
        if (widget.showHeader)
          _ChatHeader(
            account: widget.account,
            conversation: widget.conversation,
          ),
        if (_syncing)
          LinearProgressIndicator(
            minHeight: 3,
            semanticsLabel: AppLocalizations.of(context).syncing,
          ),
        if (error != null) _ChatErrorNotice(error: error, onRetry: _sync),
        Expanded(
          child: showInitialLoading
              ? const Center(child: CircularProgressIndicator())
              : _ChatTimeline(
                  account: widget.account,
                  conversation: widget.conversation,
                  threadId: widget.threadId,
                  messages: messages,
                  pending: pending,
                  hasOlder: scope?.hasHistory ?? false,
                  loadingOlder: _loadingOlder,
                  controller: _scrollController,
                  onLoadOlder: _loadOlder,
                  onRetry: _sync,
                  onResend: _confirmResend,
                  onOpenThread: _openThread,
                ),
        ),
        _ChatComposer(
          controller: _composer,
          sending: _sending,
          readOnly: widget.conversation.readOnly != 0,
          mediaComposer: attachmentDependencies == null
              ? const SizedBox.shrink()
              : _buildMediaComposer(
                  attachmentDependencies,
                  idleActions: idleComposerActions,
                ),
        ),
      ],
    );
  }

  Widget _buildMediaComposer(
    AsyncValue<ChatAttachmentDependencies> dependencies, {
    required List<Widget> idleActions,
  }) {
    return dependencies.when(
      loading: () => ChatMediaComposerStatus.loading(idleActions: idleActions),
      error: (_, _) => ChatMediaComposerStatus.unavailable(
        idleActions: idleActions,
        onRetry: () {
          ref.invalidate(chatAttachmentDependenciesProvider(_key));
        },
      ),
      data: (value) {
        try {
          final accountId = AccountId.parse(widget.account.id);
          final server = ServerBase.parse(widget.account.serverUrl);
          final roomToken = ConversationToken.parse(
            widget.conversation.token,
            path: r'$.roomToken',
          );
          return ChatMediaComposer(
            key: ValueKey((
              widget.account.id,
              widget.conversation.token,
              widget.threadId,
            )),
            accountId: accountId,
            server: server,
            roomToken: roomToken,
            threadId: widget.threadId,
            sourceStore: value.source,
            capabilityProfile: value.profile,
            submissionBridge: AttachmentSubmissionBridge.withService(
              accountId: accountId,
              server: server,
              roomToken: roomToken,
              prepare: value.resolver.resolve,
              service: value.service,
            ),
            idleActions: idleActions,
          );
        } on TalkProtocolException {
          return ChatMediaComposerStatus.unavailable(
            idleActions: idleActions,
            onRetry: () {
              ref.invalidate(chatAttachmentDependenciesProvider(_key));
            },
          );
        }
      },
    );
  }
}

final class _ChatHeader extends StatelessWidget {
  const _ChatHeader({required this.account, required this.conversation});

  final StoredAccount account;
  final CachedConversation conversation;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('chat-room-header'),
      constraints: const BoxConstraints(minHeight: 72),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
      child: Row(
        children: [
          ExcludeSemantics(
            child: ConversationAvatar(
              account: account,
              conversation: conversation,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  conversation.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (conversation.description.trim().isNotEmpty)
                  Text(
                    conversation.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

final class _ChatTimeline extends StatelessWidget {
  const _ChatTimeline({
    required this.account,
    required this.conversation,
    required this.threadId,
    required this.messages,
    required this.pending,
    required this.hasOlder,
    required this.loadingOlder,
    required this.controller,
    required this.onLoadOlder,
    required this.onRetry,
    required this.onResend,
    required this.onOpenThread,
  });

  final StoredAccount account;
  final CachedConversation conversation;
  final int? threadId;
  final List<CachedChatMessage> messages;
  final List<StoredTextSendOperation> pending;
  final bool hasOlder;
  final bool loadingOlder;
  final ScrollController controller;
  final VoidCallback onLoadOlder;
  final VoidCallback onRetry;
  final ValueChanged<StoredTextSendOperation> onResend;
  final ValueChanged<CachedChatMessage> onOpenThread;

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty && pending.isEmpty && !hasOlder) {
      return const _EmptyChat();
    }
    final itemCount = messages.length + pending.length + (hasOlder ? 1 : 0);
    return ListView.builder(
      key: const Key('chat-message-list'),
      controller: controller,
      reverse: true,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: itemCount,
      itemBuilder: (context, reverseIndex) {
        final chronologicalIndex = itemCount - reverseIndex - 1;
        if (hasOlder && chronologicalIndex == 0) {
          return Center(
            key: const Key('chat-load-older'),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TextButton.icon(
                onPressed: loadingOlder ? null : onLoadOlder,
                icon: loadingOlder
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.history_rounded),
                label: Text(
                  loadingOlder
                      ? AppLocalizations.of(context).loadingOlderMessages
                      : AppLocalizations.of(context).loadOlderMessages,
                ),
              ),
            ),
          );
        }
        final contentIndex = chronologicalIndex - (hasOlder ? 1 : 0);
        if (contentIndex < messages.length) {
          final message = messages[contentIndex];
          final parsed = _parseCachedMessage(message);
          final previous = contentIndex == 0
              ? null
              : messages[contentIndex - 1];
          final next = contentIndex + 1 >= messages.length
              ? null
              : messages[contentIndex + 1];
          final groupedWithPrevious =
              previous != null && _messagesShareGroup(previous, message);
          final groupedWithNext =
              next != null && _messagesShareGroup(message, next);
          final startsDay =
              previous == null ||
              !_sameLocalDay(previous.timestamp, message.timestamp);
          return KeyedSubtree(
            key: ValueKey(
              'chat-message-${account.id}-${conversation.token}-${message.messageId}',
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (startsDay) _DaySeparator(timestamp: message.timestamp),
                _MessageBubble(
                  account: account,
                  message: message,
                  parsed: parsed,
                  showAuthor: !groupedWithPrevious,
                  showAvatar: !groupedWithNext,
                  groupedWithPrevious: groupedWithPrevious,
                  groupEnd: !groupedWithNext,
                  showReplyPreview: _shouldShowReplyPreview(parsed, threadId),
                  onOpenThread: threadId == null ? onOpenThread : null,
                ),
              ],
            ),
          );
        }
        final operation = pending[contentIndex - messages.length];
        return _PendingMessageBubble(
          key: ValueKey('chat-pending-${operation.operationId}'),
          operation: operation,
          onRetry: onRetry,
          onResend: () => onResend(operation),
        );
      },
    );
  }
}

final class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.account,
    required this.message,
    required this.parsed,
    required this.showAuthor,
    required this.showAvatar,
    required this.groupedWithPrevious,
    required this.groupEnd,
    required this.showReplyPreview,
    required this.onOpenThread,
  });

  final StoredAccount account;
  final CachedChatMessage message;
  final ChatMessage? parsed;
  final bool showAuthor;
  final bool showAvatar;
  final bool groupedWithPrevious;
  final bool groupEnd;
  final bool showReplyPreview;
  final ValueChanged<CachedChatMessage>? onOpenThread;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final strings = AppLocalizations.of(context);
    final isSystem = message.systemMessage.isNotEmpty;
    final outgoing = message.actorId == account.loginName;
    final authorLabel = chatParticipantSemanticsLabel(
      actorType: message.actorType,
      displayName: message.actorDisplayName,
      strings: strings,
    );
    final threadReplies = parsed?.threadReplies ?? 0;
    final canOpenThread =
        onOpenThread != null && (parsed?.isThread == true || threadReplies > 0);
    if (isSystem) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 20),
        child: Semantics(
          label: message.displayText,
          child: Text(
            message.displayText,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.only(top: groupedWithPrevious ? 2 : 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: outgoing
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          if (!outgoing) ...[
            SizedBox(
              width: 32,
              height: 32,
              child: showAvatar
                  ? ExcludeSemantics(
                      child: ChatParticipantAvatar(
                        key: Key('chat-avatar-${message.messageId}'),
                        account: account,
                        actorType: message.actorType,
                        actorId: message.actorId,
                        displayName: message.actorDisplayName,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Align(
              alignment: outgoing
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: Semantics(
                  key: Key('chat-message-semantics-${message.messageId}'),
                  container: true,
                  explicitChildNodes: true,
                  label: authorLabel,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: outgoing
                          ? scheme.primaryContainer
                          : scheme.surfaceContainerHigh,
                      borderRadius: _bubbleRadius(
                        outgoing: outgoing,
                        groupEnd: groupEnd,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 7),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (!outgoing && showAuthor)
                            ExcludeSemantics(
                              child: Text(
                                message.actorDisplayName,
                                style: Theme.of(context).textTheme.labelMedium
                                    ?.copyWith(
                                      color: scheme.primary,
                                      fontWeight: FontWeight.w700,
                                    ),
                              ),
                            ),
                          if (!outgoing && showAuthor)
                            const SizedBox(height: 2),
                          DefaultTextStyle.merge(
                            style: TextStyle(
                              color: outgoing
                                  ? scheme.onPrimaryContainer
                                  : scheme.onSurface,
                              fontStyle: message.deleted
                                  ? FontStyle.italic
                                  : null,
                            ),
                            child: ChatMessageContent(
                              account: account,
                              message: message.deleted ? null : parsed,
                              fallbackText: message.deleted
                                  ? AppLocalizations.of(context).deletedMessage
                                  : message.displayText,
                              foregroundColor: outgoing
                                  ? scheme.onPrimaryContainer
                                  : scheme.onSurface,
                              showReplyPreview: showReplyPreview,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (parsed?.lastEditTimestamp != null) ...[
                                Text(
                                  AppLocalizations.of(context).edited,
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(
                                        color: outgoing
                                            ? scheme.onPrimaryContainer
                                            : scheme.onSurfaceVariant,
                                      ),
                                ),
                                const SizedBox(width: 6),
                              ],
                              Text(
                                _formatMessageClock(context, message.timestamp),
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(
                                      color: outgoing
                                          ? scheme.onPrimaryContainer
                                          : scheme.onSurfaceVariant,
                                    ),
                              ),
                            ],
                          ),
                          if (canOpenThread) ...[
                            const SizedBox(height: 2),
                            TextButton.icon(
                              key: Key('chat-open-thread-${message.messageId}'),
                              onPressed: () => onOpenThread!(message),
                              style: TextButton.styleFrom(
                                foregroundColor: outgoing
                                    ? scheme.onPrimaryContainer
                                    : scheme.primary,
                                minimumSize: const Size(48, 48),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                              ),
                              icon: const Icon(Icons.forum_outlined, size: 18),
                              label: Text(
                                threadReplies > 0
                                    ? strings.threadReplies(threadReplies)
                                    : strings.openThread,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class _DaySeparator extends StatelessWidget {
  const _DaySeparator({required this.timestamp});

  final int timestamp;

  @override
  Widget build(BuildContext context) {
    final date = DateTime.fromMillisecondsSinceEpoch(
      timestamp * 1000,
    ).toLocal();
    final today = DateTime.now();
    final yesterday = DateTime(today.year, today.month, today.day - 1);
    final strings = AppLocalizations.of(context);
    final label = _sameCalendarDay(date, today)
        ? strings.dateHeaderToday
        : _sameCalendarDay(date, yesterday)
        ? strings.dateHeaderYesterday
        : MaterialLocalizations.of(context).formatMediumDate(date);
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Semantics(
      key: Key('chat-day-${date.year}-${date.month}-${date.day}'),
      container: true,
      excludeSemantics: true,
      header: true,
      label: label,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
        child: Row(
          children: [
            const Expanded(child: Divider()),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                label,
                style: Theme.of(
                  context,
                ).textTheme.labelMedium?.copyWith(color: color),
              ),
            ),
            const Expanded(child: Divider()),
          ],
        ),
      ),
    );
  }
}

final class _PendingMessageBubble extends StatelessWidget {
  const _PendingMessageBubble({
    super.key,
    required this.operation,
    required this.onRetry,
    required this.onResend,
  });

  final StoredTextSendOperation operation;
  final VoidCallback onRetry;
  final VoidCallback onResend;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final status = switch (operation.outboxState) {
      'queued' => strings.outboxQueued,
      'sending' => strings.outboxSending,
      'retryable' => strings.outboxRetryable,
      'awaitingConfirmation' => strings.outboxAwaitingConfirmation,
      'failed' => strings.outboxFailed,
      _ => strings.outboxFailed,
    };
    final retryable = operation.outboxState == 'retryable';
    final ambiguous = operation.outboxState == 'awaitingConfirmation';
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: Card(
          color: scheme.secondaryContainer,
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  operation.message,
                  style: TextStyle(color: scheme.onSecondaryContainer),
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      ambiguous || operation.outboxState == 'failed'
                          ? Icons.warning_amber_rounded
                          : Icons.schedule_send_rounded,
                      size: 18,
                      color: scheme.onSecondaryContainer,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        status,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                    if (retryable)
                      IconButton(
                        key: Key('chat-retry-${operation.operationId}'),
                        onPressed: onRetry,
                        tooltip: strings.retrySend,
                        icon: const Icon(Icons.refresh_rounded),
                      ),
                    if (ambiguous)
                      IconButton(
                        key: Key('chat-resend-${operation.operationId}'),
                        onPressed: onResend,
                        tooltip: strings.resendMessage,
                        icon: const Icon(Icons.send_rounded),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _EmptyChat extends StatelessWidget {
  const _EmptyChat();

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chat_bubble_outline_rounded,
              size: 52,
              color: scheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              strings.chatEmpty,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              strings.chatEmptyBody,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

final class _GiphyThumbnail extends StatefulWidget {
  const _GiphyThumbnail({required this.repository, required this.entry});

  final HttpGiphyRepository repository;
  final GiphyEntry entry;

  @override
  State<_GiphyThumbnail> createState() => _GiphyThumbnailState();
}

final class _GiphyThumbnailState extends State<_GiphyThumbnail> {
  late Future<GiphyThumbnail> _thumbnail;

  @override
  void initState() {
    super.initState();
    _thumbnail = widget.repository.loadThumbnail(widget.entry);
  }

  @override
  void didUpdateWidget(covariant _GiphyThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.repository, widget.repository) ||
        oldWidget.entry.thumbnailUrl != widget.entry.thumbnailUrl) {
      _thumbnail = widget.repository.loadThumbnail(widget.entry);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      key: ValueKey<String>('giphy-thumbnail-${widget.entry.resourceUrl}'),
      borderRadius: BorderRadius.circular(10),
      child: ColoredBox(
        color: scheme.surfaceContainerHigh,
        child: FutureBuilder<GiphyThumbnail>(
          future: _thumbnail,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(
                child: CircularProgressIndicator(strokeWidth: 2),
              );
            }
            final thumbnail = snapshot.data;
            if (snapshot.hasError || thumbnail == null) {
              return Icon(
                Icons.broken_image_outlined,
                color: scheme.onSurfaceVariant,
              );
            }
            return Image.memory(
              thumbnail.body,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              cacheWidth: 480,
              errorBuilder: (_, _, _) => Icon(
                Icons.broken_image_outlined,
                color: scheme.onSurfaceVariant,
              ),
            );
          },
        ),
      ),
    );
  }
}

final class _ChatComposer extends StatelessWidget {
  const _ChatComposer({
    required this.controller,
    required this.sending,
    required this.readOnly,
    required this.mediaComposer,
  });

  final TextEditingController controller;
  final bool sending;
  final bool readOnly;
  final Widget mediaComposer;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      elevation: 3,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: readOnly
              ? SizedBox(
                  height: 48,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.lock_outline_rounded),
                      const SizedBox(width: 8),
                      Flexible(child: Text(strings.readOnlyConversation)),
                    ],
                  ),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      key: const Key('chat-composer'),
                      controller: controller,
                      minLines: 1,
                      maxLines: 5,
                      maxLength: 32000,
                      buildCounter:
                          (
                            _, {
                            required currentLength,
                            required isFocused,
                            maxLength,
                          }) => null,
                      textCapitalization: TextCapitalization.sentences,
                      keyboardType: TextInputType.multiline,
                      decoration: InputDecoration(
                        labelText: strings.messageHint,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 4),
                    mediaComposer,
                  ],
                ),
        ),
      ),
    );
  }
}

final class _ChatErrorNotice extends StatelessWidget {
  const _ChatErrorNotice({required this.error, required this.onRetry});

  final ChatServiceError error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Material(
        color: scheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              Icon(Icons.cloud_off_rounded, color: scheme.onErrorContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _chatErrorMessage(strings, error),
                  style: TextStyle(color: scheme.onErrorContainer),
                ),
              ),
              IconButton(
                key: const Key('retry-chat-sync'),
                onPressed: onRetry,
                tooltip: strings.retry,
                color: scheme.onErrorContainer,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

ChatServiceError? _storedError(String? value) {
  if (value == null) {
    return null;
  }
  return ChatServiceError.values
      .where((error) => error.name == value)
      .firstOrNull;
}

String _chatErrorMessage(AppLocalizations strings, ChatServiceError error) {
  return switch (error) {
    ChatServiceError.credentialMissing ||
    ChatServiceError.reauthenticationRequired => strings.syncCredentialMissing,
    ChatServiceError.talkUnavailable ||
    ChatServiceError.chatUnsupported ||
    ChatServiceError.sendUnsupported => strings.chatUnsupported,
    ChatServiceError.rateLimited => strings.syncRateLimited,
    ChatServiceError.serviceUnavailable ||
    ChatServiceError.network => strings.chatUnavailable,
    ChatServiceError.readOnly => strings.readOnlyConversation,
    ChatServiceError.accountMissing ||
    ChatServiceError.conversationMissing ||
    ChatServiceError.invalidResponse => strings.chatInvalidResponse,
  };
}

ChatMessage? _parseCachedMessage(CachedChatMessage cached) {
  try {
    final decoded = jsonDecode(cached.rawJson);
    final message = ChatMessage.fromJson(decoded);
    if (message.messageId != cached.messageId ||
        message.roomToken.value != cached.roomToken) {
      return null;
    }
    return message;
  } on Object {
    return null;
  }
}

bool _shouldShowReplyPreview(ChatMessage? message, int? conversationThreadId) {
  if (conversationThreadId == null) {
    return true;
  }
  final parent = message?.parent;
  final parentId = switch (parent) {
    ChatFullParent() => parent.messageId,
    ChatDeletedParent() => parent.messageId,
    null => null,
  };
  return parentId != conversationThreadId;
}

bool _messagesShareGroup(CachedChatMessage earlier, CachedChatMessage later) {
  if (earlier.systemMessage.isNotEmpty ||
      later.systemMessage.isNotEmpty ||
      earlier.actorType != later.actorType ||
      earlier.actorId != later.actorId ||
      !_sameLocalDay(earlier.timestamp, later.timestamp)) {
    return false;
  }
  final difference = later.timestamp - earlier.timestamp;
  return difference >= 0 && difference <= 5 * 60;
}

bool _sameLocalDay(int leftUnixSeconds, int rightUnixSeconds) {
  final left = DateTime.fromMillisecondsSinceEpoch(
    leftUnixSeconds * 1000,
  ).toLocal();
  final right = DateTime.fromMillisecondsSinceEpoch(
    rightUnixSeconds * 1000,
  ).toLocal();
  return _sameCalendarDay(left, right);
}

bool _sameCalendarDay(DateTime left, DateTime right) =>
    left.year == right.year &&
    left.month == right.month &&
    left.day == right.day;

BorderRadius _bubbleRadius({required bool outgoing, required bool groupEnd}) {
  const rounded = Radius.circular(16);
  const tail = Radius.circular(5);
  return BorderRadius.only(
    topLeft: rounded,
    topRight: rounded,
    bottomLeft: !outgoing && groupEnd ? tail : rounded,
    bottomRight: outgoing && groupEnd ? tail : rounded,
  );
}

String _formatMessageClock(BuildContext context, int unixSeconds) {
  final value = DateTime.fromMillisecondsSinceEpoch(
    unixSeconds * 1000,
  ).toLocal();
  final localizations = MaterialLocalizations.of(context);
  return localizations.formatTimeOfDay(TimeOfDay.fromDateTime(value));
}

bool _isForegroundLifecycleState(AppLifecycleState? state) {
  return state == null || state == AppLifecycleState.resumed;
}

bool _isTerminalLiveError(ChatServiceError error) {
  return switch (error) {
    ChatServiceError.accountMissing ||
    ChatServiceError.conversationMissing ||
    ChatServiceError.credentialMissing ||
    ChatServiceError.talkUnavailable ||
    ChatServiceError.chatUnsupported ||
    ChatServiceError.sendUnsupported ||
    ChatServiceError.readOnly ||
    ChatServiceError.reauthenticationRequired ||
    ChatServiceError.invalidResponse => true,
    ChatServiceError.rateLimited ||
    ChatServiceError.serviceUnavailable ||
    ChatServiceError.network => false,
  };
}
