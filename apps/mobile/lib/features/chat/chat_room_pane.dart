import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart'
    show
        Clipboard,
        ClipboardData,
        HardwareKeyboard,
        KeyDownEvent,
        KeyEvent,
        LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_providers.dart';
import '../../core/desktop_metrics.dart';
import '../../core/foreground_sync_loop.dart';
import '../../core/giphy_reference.dart';
import '../../data/app_database.dart';
import '../../data/chat_repository.dart';
import '../../l10n/generated/app_localizations.dart';
import '../conversations/conversation_avatar_widget.dart';
import '../rooms/room_settings_service.dart';
import 'chat_message_actions_service.dart';
import 'chat_pin_reminder_schedule.dart';
import 'chat_message_content.dart';
import 'chat_participant_avatar.dart';
import 'chat_service.dart';
import 'outgoing_message_status.dart';
import 'composer/attachment_submission.dart';
import 'composer/chat_media_composer.dart';
import 'composer/composer_text_editing.dart';
import 'composer/emoji_picker.dart';
import 'composer/emoji_usage_store.dart';
import 'composer/giphy.dart';
import 'composer/mention_suggestions.dart';

part 'chat_room_pane_actions.dart';
part 'chat_room_pane_composer.dart';
part 'chat_room_pane_composer_widgets.dart';
part 'chat_room_pane_notices.dart';
part 'chat_room_pane_sync.dart';
part 'chat_room_pane_timeline.dart';

enum ChatThreadKind { ordinary, named }

final class ChatThreadContext {
  ChatThreadContext._({
    required this.accountId,
    required this.roomToken,
    required this.rootMessageId,
    required this.kind,
    required this.title,
  });

  static ChatThreadContext? fromCachedRoot({
    required String accountId,
    required String roomToken,
    required CachedChatMessage root,
  }) {
    if (root.deleted ||
        root.accountId != accountId ||
        root.roomToken != roomToken ||
        root.messageId < 1 ||
        (root.threadId != null &&
            root.threadId != 0 &&
            root.threadId != root.messageId)) {
      return null;
    }
    try {
      final message = ChatMessage.fromJson(jsonDecode(root.rawJson));
      if (message.messageId != root.messageId ||
          message.roomToken.value != roomToken ||
          (message.threadId != null &&
              message.threadId != 0 &&
              message.threadId != message.messageId)) {
        return null;
      }
      if (message.isThread == true) {
        final title = message.threadTitle?.trim();
        if (message.threadId != message.messageId ||
            title == null ||
            title.isEmpty) {
          return null;
        }
        return ChatThreadContext._(
          accountId: accountId,
          roomToken: roomToken,
          rootMessageId: message.messageId,
          kind: ChatThreadKind.named,
          title: title,
        );
      }
      return ChatThreadContext._(
        accountId: accountId,
        roomToken: roomToken,
        rootMessageId: message.messageId,
        kind: ChatThreadKind.ordinary,
        title: null,
      );
    } on FormatException {
      return null;
    } on TalkProtocolException {
      return null;
    }
  }

  final String accountId;
  final String roomToken;
  final int rootMessageId;
  final ChatThreadKind kind;
  final String? title;

  bool get isNamed => kind == ChatThreadKind.named;
  int? get replyTo => isNamed ? null : rootMessageId;
  int? get networkThreadId => isNamed ? rootMessageId : null;

  ChatMediaThreadBinding mediaBinding({
    required AccountId accountId,
    required ConversationToken roomToken,
  }) {
    if (accountId.value != this.accountId ||
        roomToken.value != this.roomToken) {
      throw StateError('Chat thread media binding scope changed');
    }
    return isNamed
        ? ChatMediaThreadBinding.named(
            accountId: accountId,
            roomToken: roomToken,
            rootMessageId: rootMessageId,
          )
        : ChatMediaThreadBinding.ordinary(
            accountId: accountId,
            roomToken: roomToken,
            rootMessageId: rootMessageId,
          );
  }

  bool matches({
    required String accountId,
    required String roomToken,
    required int? rootMessageId,
  }) =>
      this.accountId == accountId &&
      this.roomToken == roomToken &&
      this.rootMessageId == rootMessageId;

  @override
  bool operator ==(Object other) =>
      other is ChatThreadContext &&
      other.accountId == accountId &&
      other.roomToken == roomToken &&
      other.rootMessageId == rootMessageId &&
      other.kind == kind &&
      other.title == title;

  @override
  int get hashCode =>
      Object.hash(accountId, roomToken, rootMessageId, kind, title);
}

final class ChatThreadScreen extends ConsumerWidget {
  const ChatThreadScreen({
    super.key,
    required this.account,
    required this.conversation,
    required this.threadContext,
    this.jumpToMessageId,
  });

  final StoredAccount account;
  final CachedConversation conversation;
  final ChatThreadContext threadContext;
  final int? jumpToMessageId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final threadId = threadContext.rootMessageId;
    final key = (
      accountId: threadContext.accountId,
      roomToken: threadContext.roomToken,
      threadId: threadId,
    );
    final messages = ref.watch(chatMessagesProvider(key)).valueOrNull;
    final root = messages == null ? null : _findRoot(messages, threadId);
    final liveThreadContext = root == null
        ? null
        : ChatThreadContext.fromCachedRoot(
            accountId: threadContext.accountId,
            roomToken: threadContext.roomToken,
            root: root,
          );
    return Scaffold(
      key: Key('chat-thread-screen-$threadId'),
      appBar: AppBar(
        title: Text(
          liveThreadContext?.isNamed == true
              ? liveThreadContext!.title!
              : AppLocalizations.of(context).thread,
        ),
      ),
      body: SafeArea(
        top: false,
        child: ChatRoomPane(
          account: account,
          conversation: conversation,
          threadId: threadId,
          threadContext: liveThreadContext,
          jumpToMessageId: jumpToMessageId,
        ),
      ),
    );
  }

  CachedChatMessage? _findRoot(List<CachedChatMessage> messages, int threadId) {
    for (final message in messages) {
      if (message.messageId == threadId) {
        return message;
      }
    }
    return null;
  }
}

final class ChatRoomPane extends ConsumerStatefulWidget {
  const ChatRoomPane({
    super.key,
    required this.account,
    required this.conversation,
    this.showHeader = false,
    this.threadId,
    this.threadContext,
    this.jumpToMessageId,
  }) : assert(threadId == null || threadId > 0),
       assert(threadContext == null || threadId != null),
       assert(jumpToMessageId == null || jumpToMessageId > 0);

  final StoredAccount account;
  final CachedConversation conversation;
  final bool showHeader;
  final int? threadId;
  final ChatThreadContext? threadContext;

  /// A message to reveal once the first synchronization settles, instead of
  /// opening at the newest message. Used by message search and by tapping a
  /// quoted original.
  final int? jumpToMessageId;

  @override
  ConsumerState<ChatRoomPane> createState() => _ChatRoomPaneState();
}

final class _ChatRoomPaneState extends ConsumerState<ChatRoomPane>
    with WidgetsBindingObserver {
  static const _quickReactionEmoji = <String>[
    '👍',
    '❤️',
    '😂',
    '😮',
    '😢',
    '😡',
  ];

  /// How many history pages a single jump may fetch before giving up. One
  /// page is [ChatService] `_pageSize` messages, so this reaches roughly a
  /// thousand messages back.
  // ponytail: fixed page budget; make it time- or scope-aware only if real
  // rooms turn out to need deeper jumps.
  static const _maximumJumpPages = 10;

  /// How many layout passes a reveal may take. Every pass nudges the reverse
  /// list closer to the estimated offset of the target, which re-measures the
  /// children around it, so the estimate converges within a few frames.
  static const _maximumRevealPasses = 12;

  static const _highlightDuration = Duration(seconds: 2);

  final TextEditingController _composer = TextEditingController();

  /// Owned explicitly so the emoji panel can hand focus back to the composer
  /// on desktop instead of leaving the caret nowhere once the panel closes.
  final FocusNode _composerFocusNode = FocusNode();
  bool _emojiPickerOpen = false;
  bool _emojiPickerPending = false;
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _jumpTargetKey = GlobalKey();
  final ChatMediaComposerController _mediaComposerController =
      ChatMediaComposerController();
  ForegroundSyncLoop? _syncLoop;
  ChatLiveRoomBinding? _liveBinding;
  StreamSubscription<void>? _connectivityWakeSubscription;
  int _syncGeneration = 0;
  int _sendGeneration = 0;
  int _giphyGeneration = 0;
  bool _syncing = false;
  bool _loadingOlder = false;
  bool _sending = false;
  bool _initialAttemptFinished = false;
  bool _giphyRequested = false;
  ChatServiceError? _localError;
  Timer? _draftTimer;
  Timer? _highlightTimer;
  ChatRepository? _draftStore;
  CachedChatMessage? _replyTo;
  int _jumpGeneration = 0;
  int? _jumpTargetId;
  int? _highlightedMessageId;
  int? _pendingJumpMessageId;
  ChatRoomProviderKey? _lastAutoReadKey;
  int? _lastAutoReadMessageId;

  /// Whether the last attempt for [_lastAutoReadMessageId] gave up for good
  /// (a Dart `Error`, not a retryable service failure). Only this case skips
  /// retrying the same message id outright; see `_markVisibleRead`.
  bool _lastAutoReadUnrecoverable = false;
  ChatRoomProviderKey? _autoReadInFlightKey;
  int? _autoReadInFlightMessageId;

  ChatRoomProviderKey get _key => (
    accountId: widget.account.id,
    roomToken: widget.conversation.token,
    threadId: widget.threadId,
  );

  ChatThreadContext? get _currentThreadContext {
    final threadContext = widget.threadContext;
    if (threadContext == null ||
        !threadContext.matches(
          accountId: widget.account.id,
          roomToken: widget.conversation.token,
          rootMessageId: widget.threadId,
        )) {
      return null;
    }
    return threadContext;
  }

  void _update(VoidCallback callback) => setState(callback);

  @override
  void initState() {
    super.initState();
    _pendingJumpMessageId = widget.jumpToMessageId;
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_handleScroll);
    _composer.addListener(_scheduleDraftSave);
    _connectivityWakeSubscription = ref
        .read(connectivityWakeEventsProvider)
        .listen(
          (_) => _handleConnectivityWake(),
          // Connectivity is only an accelerator. The foreground retry loop
          // remains authoritative when a platform event source is absent.
          onError: (Object _, StackTrace _) {},
        );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _draftStore = ref.read(chatRepositoryProvider);
      unawaited(_restoreDraft(_key));
      unawaited(_restartLiveSync());
    });
  }

  /// Composer text is only durable once the outbox admits it, and admission
  /// can be refused, so the draft is persisted on its own.
  void _scheduleDraftSave() {
    _draftTimer?.cancel();
    _draftTimer = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(_flushDraft(_key, _composer.text)),
    );
  }

  Future<void> _flushDraft(ChatRoomProviderKey key, String text) async {
    _draftTimer?.cancel();
    _draftTimer = null;
    final store = _draftStore;
    if (store == null) {
      return;
    }
    await store.saveDraft(
      accountId: key.accountId,
      roomToken: key.roomToken,
      threadId: key.threadId,
      text: text.trim(),
    );
  }

  Future<void> _restoreDraft(ChatRoomProviderKey key) async {
    final store = _draftStore;
    if (store == null) {
      return;
    }
    final draft = await store.readDraft(
      accountId: key.accountId,
      roomToken: key.roomToken,
      threadId: key.threadId,
    );
    if (draft == null || !mounted || key != _key || _composer.text.isNotEmpty) {
      return;
    }
    _composer.value = TextEditingValue(
      text: draft,
      selection: TextSelection.collapsed(offset: draft.length),
    );
  }

  @override
  void didUpdateWidget(covariant ChatRoomPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.id == widget.account.id &&
        oldWidget.conversation.token == widget.conversation.token &&
        oldWidget.threadId == widget.threadId) {
      return;
    }
    unawaited(
      _flushDraft((
        accountId: oldWidget.account.id,
        roomToken: oldWidget.conversation.token,
        threadId: oldWidget.threadId,
      ), _composer.text),
    );
    _composer.clear();
    _replyTo = null;
    _sendGeneration++;
    _giphyGeneration++;
    _jumpGeneration++;
    _highlightTimer?.cancel();
    _highlightTimer = null;
    _jumpTargetId = null;
    _highlightedMessageId = null;
    _pendingJumpMessageId = widget.jumpToMessageId;
    _sending = false;
    _localError = null;
    _initialAttemptFinished = false;
    _giphyRequested = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_restoreDraft(_key));
      unawaited(_restartLiveSync());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _syncGeneration++;
    _sendGeneration++;
    _giphyGeneration++;
    _jumpGeneration++;
    _liveBinding?.close();
    unawaited(_syncLoop?.stop());
    unawaited(_connectivityWakeSubscription?.cancel());
    _connectivityWakeSubscription = null;
    _liveBinding = null;
    _syncLoop = null;
    _draftTimer?.cancel();
    _highlightTimer?.cancel();
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    _composer
      ..removeListener(_scheduleDraftSave)
      ..dispose();
    _composerFocusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_restartLiveSync());
      return;
    }
    // The process can be killed from here on, so the draft cannot wait for
    // its debounce.
    unawaited(_flushDraft(_key, _composer.text));
    unawaited(_stopLiveSync());
  }

  @override
  void didChangeMetrics() {
    if (!_emojiPickerPending || !mounted) {
      return;
    }
    if (_sending || _isReadOnlyNow()) {
      _emojiPickerPending = false;
      return;
    }
    if (View.of(context).viewInsets.bottom > 0) {
      return;
    }
    setState(() {
      _emojiPickerPending = false;
      _emojiPickerOpen = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final messagesValue = ref.watch(chatMessagesProvider(_key));
    final operationsValue = ref.watch(textSendOperationsProvider(_key));
    final statusesValue = ref.watch(outgoingMessageStatusesProvider(_key));
    final scopeValue = ref.watch(chatScopeProvider(_key));
    final liveConversation = _watchLiveConversation();
    final readOnly = liveConversation.readOnly != 0;
    final attachmentDependencies = !readOnly
        ? ref.watch(chatAttachmentDependenciesProvider(_key))
        : null;
    final mentionSource = !readOnly
        ? ref.watch(
            mentionSuggestionSourceProvider((
              accountId: widget.account.id,
              roomToken: widget.conversation.token,
            )),
          )
        : null;
    final actionsProfile = ref
        .watch(chatMessageActionsProfileProvider(_key))
        .valueOrNull;
    final canReplyToMessage =
        !readOnly &&
        widget.threadId == null &&
        (actionsProfile?.reply ?? false);
    final profileCanEdit = actionsProfile?.edit ?? false;
    final profileCanDelete = actionsProfile?.delete ?? false;
    final profileCanReact = !readOnly && (actionsProfile?.canReact ?? false);
    final pinned = PinnedMessageState.fromCachedConversation(liveConversation);
    // Pins are a whole-room concept, so a thread pane neither shows nor
    // offers them; the root room pane owns that.
    final inRootRoom = widget.threadId == null;
    final profileCanPin = inRootRoom && (actionsProfile?.pin ?? false);
    final profileCanHidePin =
        inRootRoom && (actionsProfile?.hidePinned ?? false);
    final profileCanRemind = actionsProfile?.reminders ?? false;
    final profileCanSchedule =
        !readOnly && inRootRoom && (actionsProfile?.scheduled ?? false);
    void handleMessageActions(CachedChatMessage message, ChatMessage? parsed) {
      final outgoing = message.actorId == widget.account.loginName;
      _showMessageActions(
        message,
        parsed,
        canReply: canReplyToMessage,
        canEdit: !readOnly && profileCanEdit && outgoing,
        canDelete: !readOnly && profileCanDelete && outgoing,
        canReact: profileCanReact,
        canPin: profileCanPin && message.systemMessage.isEmpty,
        isPinned: pinned.messageId == message.messageId,
        canRemind: profileCanRemind && message.systemMessage.isEmpty,
      );
    }

    void handleReactionTap(
      CachedChatMessage message,
      ChatMessage? parsed,
      String emoji,
    ) {
      if (!profileCanReact) {
        return;
      }
      unawaited(_toggleReaction(message, parsed, emoji));
    }

    final scope = scopeValue.valueOrNull;
    final scopeBlocks = _decodeScopeBlocks(scope);
    // Cached rows are keyed only by (account, room, thread); the scope's
    // blocks are the authoritative record of which message IDs the client
    // actually confirmed by fetching them. Filtering here means a stray
    // cached row that falls outside every known block (for example a future
    // jump-to-message feature caching a preview ahead of the surrounding
    // history) is never silently glued into the timeline as if it were
    // contiguous with what is shown around it.
    final messages = _messagesWithinBlocks(
      messagesValue.valueOrNull ?? const <CachedChatMessage>[],
      scopeBlocks,
    );
    final operations =
        operationsValue.valueOrNull ?? const <StoredTextSendOperation>[];
    final deliveryStates = <int, OutgoingMessageDeliveryState>{
      for (final status
          in statusesValue.valueOrNull ?? const <OutgoingMessageStatus>[])
        if (status.messageId != null) status.messageId!: status.state,
    };
    final pending = operations
        .where((operation) => operation.outboxState != 'completed')
        .toList(growable: false);
    final showInitialLoading =
        !_initialAttemptFinished && messages.isEmpty && pending.isEmpty;
    final error = _localError ?? _storedError(scope?.lastSyncError);
    final strings = AppLocalizations.of(context);
    final giphy = _giphyRequested && !readOnly
        ? ref.watch(giphyRepositoryProvider(widget.account.id))
        : null;
    final giphyRepository = giphy?.valueOrNull;
    final threadContext = _currentThreadContext;
    final giphyMetadata = widget.threadId == null
        ? AttachmentMetadata(
            kind: AttachmentMessageKind.file,
            replyTo: _replyTo?.messageId,
            threadId: null,
            silent: false,
          )
        : threadContext == null
        ? null
        : AttachmentMetadata(
            kind: AttachmentMessageKind.file,
            replyTo: threadContext.replyTo,
            threadId: threadContext.networkThreadId,
            silent: false,
          );
    final giphyAttachmentSupported =
        giphyMetadata != null &&
        (attachmentDependencies?.valueOrNull?.profile.supports(giphyMetadata) ??
            false);
    final String giphyTooltip;
    final VoidCallback? giphyAction;
    if (attachmentDependencies?.isLoading ?? false) {
      giphyTooltip = strings.mediaCapabilityChecking;
      giphyAction = null;
    } else if (!giphyAttachmentSupported) {
      giphyTooltip = strings.mediaCapabilityUnavailable;
      giphyAction = null;
    } else if (giphy == null) {
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
      giphyAction = () => unawaited(_requestGiphy());
    }
    final idleComposerActions = <Widget>[
      IconButton(
        key: const Key('open-emoji-picker'),
        onPressed: _sending ? null : _toggleEmojiPicker,
        tooltip: strings.openEmojiPicker,
        isSelected: _emojiPickerOpen,
        icon: const Icon(Icons.emoji_emotions_outlined),
        selectedIcon: const Icon(Icons.emoji_emotions),
      ),
      IconButton(
        key: const Key('open-giphy-picker'),
        onPressed: _sending ? null : giphyAction,
        tooltip: giphyTooltip,
        icon:
            (attachmentDependencies?.isLoading ?? false) ||
                (giphy?.isLoading ?? false)
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.gif_box_outlined),
      ),
      if (profileCanSchedule)
        IconButton(
          key: const Key('schedule-message'),
          onPressed: _sending ? null : () => unawaited(_scheduleMessage()),
          tooltip: strings.scheduleMessage,
          icon: const Icon(Icons.schedule_send_outlined),
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
        PinnedMessageBanner(
          account: widget.account,
          conversation: liveConversation,
          pinned: pinned,
          canHide: profileCanHidePin,
          onOpen: (messageId) => unawaited(_jumpToMessage(messageId)),
          onHide: (messageId) => unawaited(_hidePinnedMessage(messageId)),
        ),
        if (profileCanSchedule && scheduledMessageCount(liveConversation) > 0)
          ListTile(
            key: const Key('open-scheduled-messages'),
            dense: true,
            leading: const Icon(Icons.schedule_send_outlined),
            title: Text(strings.scheduledMessagesOpen),
            onTap: () => unawaited(_openScheduledMessages()),
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
                  blocks: scopeBlocks,
                  pending: pending,
                  hasOlder: scope?.hasHistory ?? false,
                  loadingOlder: _loadingOlder,
                  controller: _scrollController,
                  onLoadOlder: () => unawaited(_loadOlder()),
                  onRetry: _sync,
                  onResend: _confirmResend,
                  onCancel: (operation) => unawaited(_cancelPending(operation)),
                  onOpenThread: _openThread,
                  onMessageActions: handleMessageActions,
                  onReactionTap: handleReactionTap,
                  onJumpToMessage: (messageId) =>
                      unawaited(_jumpToMessage(messageId)),
                  jumpTargetId: _jumpTargetId,
                  jumpTargetKey: _jumpTargetKey,
                  highlightedMessageId: _highlightedMessageId,
                  deliveryStates: deliveryStates,
                  lastCommonRead: _cursorValue(scope?.lastCommonRead),
                ),
        ),
        if (_emojiPickerOpen && !readOnly)
          _InlineEmojiPanel(
            accountId: AccountId.parse(_key.accountId),
            usageStore: ref.read(emojiUsageStoreProvider),
            labels: _emojiPickerLabels(strings),
            onClose: _closeEmojiPicker,
            onSelected: _insertEmoji,
          ),
        _ChatComposer(
          replyTo: _replyTo,
          onCancelReply: () => setState(() => _replyTo = null),
          controller: _composer,
          focusNode: _composerFocusNode,
          // A thread opens beside an existing conversation instead of
          // replacing it, so it reads as a reply the user is about to type —
          // but only where a hardware keyboard is the norm. Auto-raising the
          // soft keyboard on a phone would be hostile.
          autofocus: widget.threadId != null && context.sendsOnEnter,
          sending: _sending,
          onSubmit: _send,
          readOnly: readOnly,
          mentionSource: mentionSource?.valueOrNull,
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
}
