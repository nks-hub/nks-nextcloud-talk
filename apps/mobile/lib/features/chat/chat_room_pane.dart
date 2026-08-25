import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_providers.dart';
import '../../core/foreground_sync_loop.dart';
import '../../core/giphy_reference.dart';
import '../../data/app_database.dart';
import '../../data/chat_repository.dart';
import '../../l10n/generated/app_localizations.dart';
import '../conversations/conversation_avatar_widget.dart';
import '../rooms/room_details_screen.dart';
import 'chat_message_actions_service.dart';
import 'chat_message_content.dart';
import 'chat_participant_avatar.dart';
import 'chat_service.dart';
import 'outgoing_message_status.dart';
import 'composer/attachment_submission.dart';
import 'composer/chat_media_composer.dart';
import 'composer/composer_text_editing.dart';
import 'composer/emoji_picker.dart';
import 'composer/giphy.dart';
import 'composer/mention_suggestions.dart';

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
        actions: [
          IconButton(
            key: const Key('open-room-details'),
            tooltip: AppLocalizations.of(context).roomDetailsOpenTooltip,
            icon: const Icon(Icons.info_outline_rounded),
            onPressed: () => unawaited(
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (context) => RoomDetailsScreen(
                    account: account,
                    conversation: conversation,
                  ),
                ),
              ),
            ),
          ),
        ],
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
    this.jumpToMessageId,
  }) : assert(threadId == null || threadId > 0),
       assert(jumpToMessageId == null || jumpToMessageId > 0);

  final StoredAccount account;
  final CachedConversation conversation;
  final bool showHeader;
  final int? threadId;

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
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _jumpTargetKey = GlobalKey();
  final ChatMediaComposerController _mediaComposerController =
      ChatMediaComposerController();
  ForegroundSyncLoop? _syncLoop;
  ChatLiveRoomBinding? _liveBinding;
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

  ChatRoomProviderKey get _key => (
    accountId: widget.account.id,
    roomToken: widget.conversation.token,
    threadId: widget.threadId,
  );

  @override
  void initState() {
    super.initState();
    _pendingJumpMessageId = widget.jumpToMessageId;
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_handleScroll);
    _composer.addListener(_scheduleDraftSave);
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
    _startPendingJump();
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
    // A failed first attempt still resolves the jump: paging back over a
    // cached scope may work, and when it does not the user is told so
    // instead of being left on the newest message without explanation.
    _startPendingJump();
  }

  /// Returns whether the page was fetched. A refused or failed fetch is
  /// already surfaced through [_localError]; the boolean only lets a caller
  /// stop paging instead of retrying the same failure.
  Future<bool> _loadOlder() async {
    if (_loadingOlder) {
      return false;
    }
    final scope = ref.read(chatScopeProvider(_key)).valueOrNull;
    if (scope?.hasHistory != true) {
      return false;
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
      return true;
    } on ChatServiceException catch (error) {
      if (mounted) {
        setState(() => _localError = error.code);
      }
      return false;
    } on Object {
      if (mounted) {
        setState(() => _localError = ChatServiceError.invalidResponse);
      }
      return false;
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
      unawaited(_loadOlder());
    }
  }

  void _startPendingJump() {
    final target = _pendingJumpMessageId;
    if (target == null) {
      return;
    }
    _pendingJumpMessageId = null;
    unawaited(_jumpToMessage(target));
  }

  /// Reveals [messageId] inside this scope, fetching older history pages
  /// while the message is not covered by the scope's confirmed blocks.
  ///
  /// Both entry points - a search result and a tapped quote - land here, so
  /// the fetch, the scroll and the highlight exist exactly once. Paging back
  /// is the only way to reach an uncached message: `planChatGetMerge` only
  /// extends a scope at its two cursor ends, so an ad-hoc fetch anchored on
  /// an arbitrary id would be discarded as stale rather than merged.
  Future<void> _jumpToMessage(int messageId) async {
    final generation = ++_jumpGeneration;
    final key = _key;
    final chat = ref.read(chatRepositoryProvider);
    for (var page = 0; page <= _maximumJumpPages; page++) {
      final scope = await chat.getScope(
        accountId: key.accountId,
        roomToken: key.roomToken,
        threadId: key.threadId,
      );
      if (!_isCurrentJump(key, generation)) {
        return;
      }
      final blocks = _decodeScopeBlocks(scope);
      if (blocks != null && _blockIndexOf(blocks, messageId) != -1) {
        if (await _revealMessage(messageId, key, generation)) {
          return;
        }
        // The id sits inside a confirmed range but has no visible row: it is
        // hidden, expired or deleted server-side. Paging further back cannot
        // produce it.
        break;
      }
      if (scope?.hasHistory != true || !await _loadOlder()) {
        break;
      }
    }
    if (mounted && _isCurrentJump(key, generation)) {
      _reportJumpFailed();
    }
  }

  /// Scrolls the target into view and highlights it. Returns `false` only
  /// when the message never materialized, which is the caller's cue to tell
  /// the user rather than to leave the timeline where it was.
  Future<bool> _revealMessage(
    int messageId,
    ChatRoomProviderKey key,
    int generation,
  ) async {
    if (_jumpTargetId != messageId) {
      setState(() => _jumpTargetId = messageId);
    }
    for (var pass = 0; pass < _maximumRevealPasses; pass++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !_isCurrentJump(key, generation)) {
        // A newer jump or a scope change owns the outcome now.
        return true;
      }
      final targetContext = _jumpTargetKey.currentContext;
      if (targetContext != null && targetContext.mounted) {
        await Scrollable.ensureVisible(
          targetContext,
          alignment: 0.5,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
        if (_isCurrentJump(key, generation)) {
          _highlight(messageId);
        }
        return true;
      }
      _scrollTowards(messageId);
    }
    return false;
  }

  /// Moves the reversed timeline to where [messageId] is estimated to sit so
  /// the list builds the children around it; the next pass then measures the
  /// real position. Off-screen children have no extent yet, so the estimate
  /// improves with every pass instead of landing in one step.
  void _scrollTowards(int messageId) {
    if (!_scrollController.hasClients) {
      return;
    }
    final messages = _visibleMessages();
    final index = messages.indexWhere(
      (message) => message.messageId == messageId,
    );
    if (index < 0 || messages.length < 2) {
      return;
    }
    final position = _scrollController.position;
    // The timeline is reversed: the newest message sits at offset zero and
    // the oldest at the far end.
    final fraction = (messages.length - 1 - index) / (messages.length - 1);
    final offset = position.maxScrollExtent * fraction;
    _scrollController.jumpTo(
      offset.clamp(position.minScrollExtent, position.maxScrollExtent),
    );
  }

  /// The same rows the timeline renders, filtered by the scope's blocks so
  /// an index here matches an index there.
  List<CachedChatMessage> _visibleMessages() {
    final key = _key;
    return _messagesWithinBlocks(
      ref.read(chatMessagesProvider(key)).valueOrNull ??
          const <CachedChatMessage>[],
      _decodeScopeBlocks(ref.read(chatScopeProvider(key)).valueOrNull),
    );
  }

  void _highlight(int messageId) {
    _highlightTimer?.cancel();
    setState(() => _highlightedMessageId = messageId);
    _highlightTimer = Timer(_highlightDuration, () {
      if (mounted) {
        setState(() => _highlightedMessageId = null);
      }
    });
  }

  void _reportJumpFailed() {
    setState(() => _jumpTargetId = null);
    final strings = AppLocalizations.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: const Key('chat-jump-not-found'),
          content: Text(strings.jumpToMessageNotFound),
        ),
      );
  }

  bool _isCurrentJump(ChatRoomProviderKey key, int generation) =>
      mounted && generation == _jumpGeneration && key == _key;

  void _startReply(CachedChatMessage message) {
    if (message.systemMessage.isNotEmpty || message.deleted) {
      return;
    }
    setState(() => _replyTo = message);
  }

  Future<void> _send() async {
    final message = _composer.text.trim();
    if (message.isEmpty || _sending || widget.conversation.readOnly != 0) {
      return;
    }
    await _sendMessage(message, clearComposer: true);
  }

  Future<void> _sendGiphyForScope(
    GiphyEntry entry,
    HttpGiphyRepository repository,
    ChatRoomProviderKey targetKey,
    int giphyGeneration,
  ) async {
    if (!_isCurrentGiphyScope(targetKey, giphyGeneration)) {
      return;
    }
    if (!isSupportedGiphyResource(entry.resourceUrl)) {
      if (mounted) {
        setState(() => _localError = ChatServiceError.invalidResponse);
      }
      return;
    }
    // A GIF is sent as a reference, not as a file in the user's storage. The
    // bubble resolves that reference through the account's own server and
    // renders the animation inline.
    await _sendMessage(
      entry.resourceUrl.toString(),
      clearComposer: false,
      expectedKey: targetKey,
    );
  }

  Future<void> _sendMessage(
    String message, {
    required bool clearComposer,
    ChatRoomProviderKey? expectedKey,
  }) async {
    final targetKey = _key;
    if (expectedKey != null && expectedKey != targetKey) {
      return;
    }
    if (message.isEmpty || _sending || widget.conversation.readOnly != 0) {
      return;
    }
    final replyTo = targetKey.threadId == null ? _replyTo : null;
    final generation = ++_sendGeneration;
    setState(() => _sending = true);
    try {
      await ref
          .read(chatServiceProvider)
          .sendText(
            accountId: targetKey.accountId,
            roomToken: targetKey.roomToken,
            message: message,
            threadId: targetKey.threadId,
            replyTo: replyTo?.messageId,
          );
      if (!_isCurrentSendScope(targetKey, generation)) {
        return;
      }
      if (replyTo != null && _replyTo?.messageId == replyTo.messageId) {
        setState(() => _replyTo = null);
      }
      if (clearComposer && _composer.text.trim() == message) {
        _composer.clear();
      }
      if (_scrollController.hasClients) {
        await _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
      if (_isCurrentSendScope(targetKey, generation)) {
        setState(() => _localError = null);
      }
    } on ChatServiceException catch (error) {
      if (_isCurrentSendScope(targetKey, generation)) {
        setState(() => _localError = error.code);
      }
    } on Object {
      if (_isCurrentSendScope(targetKey, generation)) {
        setState(() => _localError = ChatServiceError.invalidResponse);
      }
    } finally {
      if (_isCurrentSendScope(targetKey, generation)) {
        setState(() => _sending = false);
      }
    }
  }

  bool _isCurrentSendScope(ChatRoomProviderKey targetKey, int generation) {
    return mounted && generation == _sendGeneration && targetKey == _key;
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
              labels: _emojiPickerLabels(strings),
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

  EmojiPickerLabels _emojiPickerLabels(AppLocalizations strings) {
    return EmojiPickerLabels(
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
    );
  }

  void _showMessageActions(
    CachedChatMessage message,
    ChatMessage? parsed, {
    required bool canReply,
    required bool canEdit,
    required bool canDelete,
    required bool canReact,
  }) {
    final strings = AppLocalizations.of(context);
    final copyText = message.displayText;
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        builder: (sheetContext) => SafeArea(
          child: Wrap(
            children: [
              if (canReply)
                ListTile(
                  key: const Key('message-action-reply'),
                  leading: const Icon(Icons.reply_rounded),
                  title: Text(strings.messageActionReply),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _startReply(message);
                  },
                ),
              if (copyText.isNotEmpty)
                ListTile(
                  key: const Key('message-action-copy'),
                  leading: const Icon(Icons.copy_rounded),
                  title: Text(strings.messageActionCopy),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_copyMessageText(copyText));
                  },
                ),
              if (canEdit)
                ListTile(
                  key: const Key('message-action-edit'),
                  leading: const Icon(Icons.edit_outlined),
                  title: Text(strings.messageActionEdit),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_startEditMessage(message, parsed));
                  },
                ),
              if (canDelete)
                ListTile(
                  key: const Key('message-action-delete'),
                  leading: const Icon(Icons.delete_outline_rounded),
                  title: Text(strings.messageActionDelete),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_confirmDeleteMessage(message));
                  },
                ),
              if (canReact)
                ListTile(
                  key: const Key('message-action-react'),
                  leading: const Icon(Icons.add_reaction_outlined),
                  title: Text(strings.messageActionReact),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_openReactionPicker(message));
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _copyMessageText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) {
      return;
    }
    final strings = AppLocalizations.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(strings.messageCopied)));
  }

  Future<void> _startEditMessage(
    CachedChatMessage message,
    ChatMessage? parsed,
  ) async {
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _EditMessageDialog(
        initialText: parsed?.message ?? message.displayText,
      ),
    );
    final trimmed = result?.trim();
    if (trimmed == null || trimmed.isEmpty || !mounted) {
      return;
    }
    final targetKey = _key;
    try {
      await ref
          .read(chatMessageActionsServiceProvider)
          .editMessage(
            accountId: targetKey.accountId,
            roomToken: targetKey.roomToken,
            messageId: message.messageId,
            message: trimmed,
          );
    } on ChatMessageActionException catch (error) {
      _showActionError(error.code);
    } on Object {
      _showActionError(ChatMessageActionError.invalidResponse);
    }
  }

  Future<void> _confirmDeleteMessage(CachedChatMessage message) async {
    final strings = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('delete-message-dialog'),
        title: Text(strings.deleteMessageConfirmTitle),
        content: Text(strings.deleteMessageConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            key: const Key('confirm-delete-message'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.messageActionDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    final targetKey = _key;
    try {
      await ref
          .read(chatMessageActionsServiceProvider)
          .deleteMessage(
            accountId: targetKey.accountId,
            roomToken: targetKey.roomToken,
            messageId: message.messageId,
          );
    } on ChatMessageActionException catch (error) {
      _showActionError(error.code);
    } on Object {
      _showActionError(ChatMessageActionError.invalidResponse);
    }
  }

  Future<void> _toggleReaction(
    CachedChatMessage message,
    ChatMessage? parsed,
    String emoji,
  ) async {
    final selfReacted = parsed?.reactionsSelf.contains(emoji) ?? false;
    final targetKey = _key;
    try {
      final service = ref.read(chatMessageActionsServiceProvider);
      if (selfReacted) {
        await service.deleteReaction(
          accountId: targetKey.accountId,
          roomToken: targetKey.roomToken,
          messageId: message.messageId,
          reaction: emoji,
        );
      } else {
        await service.addReaction(
          accountId: targetKey.accountId,
          roomToken: targetKey.roomToken,
          messageId: message.messageId,
          reaction: emoji,
        );
      }
    } on ChatMessageActionException catch (error) {
      _showActionError(error.code);
    } on Object {
      _showActionError(ChatMessageActionError.invalidResponse);
    }
  }

  Future<void> _openReactionPicker(CachedChatMessage message) async {
    final strings = AppLocalizations.of(context);
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (final emoji in _quickReactionEmoji)
                    InkWell(
                      key: Key('quick-reaction-$emoji'),
                      borderRadius: BorderRadius.circular(24),
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        unawaited(
                          _toggleReaction(
                            message,
                            _parseCachedMessage(message),
                            emoji,
                          ),
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Text(
                          emoji,
                          style: const TextStyle(fontSize: 28),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              TextButton.icon(
                key: const Key('open-full-reaction-picker'),
                onPressed: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_openFullReactionPicker(message));
                },
                icon: const Icon(Icons.add_reaction_outlined),
                label: Text(strings.reactionPickerMore),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openFullReactionPicker(CachedChatMessage message) async {
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
              labels: _emojiPickerLabels(strings),
              onSelected: (choice) {
                Navigator.of(sheetContext).pop();
                unawaited(
                  _toggleReaction(
                    message,
                    _parseCachedMessage(message),
                    choice.glyph,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  void _showActionError(ChatMessageActionError code) {
    if (!mounted) {
      return;
    }
    final strings = AppLocalizations.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(_messageActionErrorMessage(strings, code))),
      );
  }

  Future<void> _requestGiphy({bool refresh = false}) async {
    if (_sending || widget.conversation.readOnly != 0) {
      return;
    }
    final targetKey = _key;
    final generation = ++_giphyGeneration;
    final provider = giphyRepositoryProvider(targetKey.accountId);
    final subscription = ref.listenManual<AsyncValue<HttpGiphyRepository?>>(
      provider,
      (_, _) {},
      fireImmediately: true,
    );
    if (!_giphyRequested) {
      setState(() => _giphyRequested = true);
    }
    try {
      if (refresh) {
        ref.invalidate(provider);
      }
      final repository = await ref.read(provider.future);
      if (!_isCurrentGiphyScope(targetKey, generation) || repository == null) {
        return;
      }
      await _showGiphyPicker(repository, targetKey, generation);
    } on Object {
      // The watched provider exposes a localized retry state in the composer.
    } finally {
      subscription.close();
    }
  }

  bool _isCurrentGiphyScope(ChatRoomProviderKey targetKey, int generation) {
    return mounted && generation == _giphyGeneration && targetKey == _key;
  }

  Future<void> _showGiphyPicker(
    HttpGiphyRepository repository,
    ChatRoomProviderKey targetKey,
    int generation,
  ) async {
    if (!_isCurrentGiphyScope(targetKey, generation)) {
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
                  poweredByGiphy: strings.giphyPoweredBy,
                ),
                thumbnailBuilder: (_, entry) => ExcludeSemantics(
                  child: _GiphyThumbnail(repository: repository, entry: entry),
                ),
                onAttributionPressed: _openGiphyAttribution,
                onSelected: (entry) {
                  Navigator.of(sheetContext).pop();
                  unawaited(
                    _sendGiphyForScope(
                      entry,
                      repository,
                      targetKey,
                      generation,
                    ),
                  );
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

  Future<void> _openGiphyAttribution(Uri uri) async {
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object {
      // The picker remains usable when no external browser is available.
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
    final statusesValue = ref.watch(outgoingMessageStatusesProvider(_key));
    final scopeValue = ref.watch(chatScopeProvider(_key));
    final attachmentDependencies = widget.conversation.readOnly == 0
        ? ref.watch(chatAttachmentDependenciesProvider(_key))
        : null;
    final mentionSource = widget.conversation.readOnly == 0
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
    final readOnly = widget.conversation.readOnly != 0;
    final canReplyToMessage = !readOnly && widget.threadId == null;
    final profileCanEdit = actionsProfile?.edit ?? false;
    final profileCanDelete = actionsProfile?.delete ?? false;
    final profileCanReact = !readOnly && (actionsProfile?.canReact ?? false);
    void handleMessageActions(CachedChatMessage message, ChatMessage? parsed) {
      final outgoing = message.actorId == widget.account.loginName;
      _showMessageActions(
        message,
        parsed,
        canReply: canReplyToMessage,
        canEdit: profileCanEdit && outgoing,
        canDelete: profileCanDelete && outgoing,
        canReact: profileCanReact,
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
    final giphy = _giphyRequested && widget.conversation.readOnly == 0
        ? ref.watch(giphyRepositoryProvider(widget.account.id))
        : null;
    final giphyRepository = giphy?.valueOrNull;
    final giphyAttachmentSupported =
        attachmentDependencies?.valueOrNull?.profile.supports(
          AttachmentMetadata(
            kind: AttachmentMessageKind.file,
            replyTo: null,
            threadId: widget.threadId,
            silent: false,
          ),
        ) ??
        false;
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
        onPressed: _sending ? null : () => unawaited(_showEmojiPicker()),
        tooltip: strings.openEmojiPicker,
        icon: const Icon(Icons.emoji_emotions_outlined),
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
                  blocks: scopeBlocks,
                  pending: pending,
                  hasOlder: scope?.hasHistory ?? false,
                  loadingOlder: _loadingOlder,
                  controller: _scrollController,
                  onLoadOlder: () => unawaited(_loadOlder()),
                  onRetry: _sync,
                  onResend: _confirmResend,
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
        _ChatComposer(
          replyTo: _replyTo,
          onCancelReply: () => setState(() => _replyTo = null),
          controller: _composer,
          sending: _sending,
          readOnly: widget.conversation.readOnly != 0,
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
            controller: _mediaComposerController,
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
    required this.blocks,
    required this.pending,
    required this.hasOlder,
    required this.loadingOlder,
    required this.controller,
    required this.onLoadOlder,
    required this.onRetry,
    required this.onResend,
    required this.onOpenThread,
    required this.onMessageActions,
    required this.onReactionTap,
    required this.onJumpToMessage,
    required this.jumpTargetId,
    required this.jumpTargetKey,
    required this.highlightedMessageId,
    required this.deliveryStates,
    required this.lastCommonRead,
  });

  final StoredAccount account;
  final CachedConversation conversation;
  final int? threadId;
  final List<CachedChatMessage> messages;

  /// The scope's confirmed message-id ranges, `null` when the scope itself
  /// hasn't loaded yet. More than one entry means the client knows about a
  /// gap between two cached ranges (see [_gapBeforeContentIndex]).
  final List<ChatBlock>? blocks;
  final List<StoredTextSendOperation> pending;
  final bool hasOlder;
  final bool loadingOlder;
  final ScrollController controller;
  final VoidCallback onLoadOlder;
  final VoidCallback onRetry;
  final ValueChanged<StoredTextSendOperation> onResend;
  final ValueChanged<CachedChatMessage> onOpenThread;
  final void Function(CachedChatMessage message, ChatMessage? parsed)
  onMessageActions;
  final void Function(
    CachedChatMessage message,
    ChatMessage? parsed,
    String emoji,
  )
  onReactionTap;
  final ValueChanged<int> onJumpToMessage;

  /// The message a jump is currently resolving. It carries [jumpTargetKey]
  /// so the pane can measure it once the list has built it.
  final int? jumpTargetId;
  final GlobalKey jumpTargetKey;
  final int? highlightedMessageId;
  final Map<int, OutgoingMessageDeliveryState> deliveryStates;
  final int? lastCommonRead;

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
          final gapBeforeThis = _gapBeforeContentIndex(contentIndex);
          final groupedWithPrevious =
              !gapBeforeThis &&
              previous != null &&
              _messagesShareGroup(previous, message);
          final groupedWithNext =
              next != null && _messagesShareGroup(message, next);
          final startsDay =
              gapBeforeThis ||
              previous == null ||
              !_sameLocalDay(previous.timestamp, message.timestamp);
          return KeyedSubtree(
            key: ValueKey(
              'chat-message-${account.id}-${conversation.token}-${message.messageId}',
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (gapBeforeThis)
                  const _ChatHistoryGapNotice(key: Key('chat-history-gap')),
                if (startsDay) _DaySeparator(timestamp: message.timestamp),
                _MessageBubble(
                  key: message.messageId == jumpTargetId ? jumpTargetKey : null,
                  account: account,
                  message: message,
                  parsed: parsed,
                  highlighted: message.messageId == highlightedMessageId,
                  onJumpToMessage: onJumpToMessage,
                  showAuthor: !groupedWithPrevious,
                  showAvatar: !groupedWithNext,
                  groupedWithPrevious: groupedWithPrevious,
                  groupEnd: !groupedWithNext,
                  showReplyPreview: _shouldShowReplyPreview(parsed, threadId),
                  onOpenThread: threadId == null ? onOpenThread : null,
                  onMessageActions: onMessageActions,
                  onReactionTap: onReactionTap,
                  deliveryState:
                      deliveryStates[message.messageId] ??
                      _serverDeliveryState(message.messageId, lastCommonRead),
                ),
              ],
            ),
          );
        }
        final operation = pending[contentIndex - messages.length];
        return _PendingMessageBubble(
          key: ValueKey('chat-pending-${operation.operationId}'),
          account: account,
          operation: operation,
          onRetry: onRetry,
          onResend: () => onResend(operation),
        );
      },
    );
  }

  /// Whether the scope's confirmed ranges show a gap between the message at
  /// `index - 1` and the one at `index`. [messages] only ever contains rows
  /// [_messagesWithinBlocks] already verified as covered by some block, so a
  /// change of block between two consecutive entries always means real
  /// unfetched history sits between them, not merely an absent cache row.
  bool _gapBeforeContentIndex(int index) {
    final ranges = blocks;
    if (ranges == null || ranges.length < 2 || index <= 0) {
      return false;
    }
    final previousBlock = _blockIndexOf(ranges, messages[index - 1].messageId);
    final currentBlock = _blockIndexOf(ranges, messages[index].messageId);
    return previousBlock != currentBlock;
  }
}

final class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    super.key,
    required this.account,
    required this.message,
    required this.parsed,
    required this.highlighted,
    required this.onJumpToMessage,
    required this.showAuthor,
    required this.showAvatar,
    required this.groupedWithPrevious,
    required this.groupEnd,
    required this.showReplyPreview,
    required this.onOpenThread,
    required this.onMessageActions,
    required this.onReactionTap,
    required this.deliveryState,
  });

  final StoredAccount account;
  final CachedChatMessage message;
  final ChatMessage? parsed;

  /// Draws a short-lived ring around the bubble so the user can see where a
  /// jump landed.
  final bool highlighted;
  final ValueChanged<int> onJumpToMessage;
  final bool showAuthor;
  final bool showAvatar;
  final bool groupedWithPrevious;
  final bool groupEnd;
  final bool showReplyPreview;
  final ValueChanged<CachedChatMessage>? onOpenThread;
  final void Function(CachedChatMessage message, ChatMessage? parsed)
  onMessageActions;
  final void Function(
    CachedChatMessage message,
    ChatMessage? parsed,
    String emoji,
  )
  onReactionTap;
  final OutgoingMessageDeliveryState? deliveryState;

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
                  child: GestureDetector(
                    key: Key('chat-message-target-${message.messageId}'),
                    behavior: HitTestBehavior.opaque,
                    onLongPress: message.deleted
                        ? null
                        : () => onMessageActions(message, parsed),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOut,
                      decoration: BoxDecoration(
                        color: outgoing
                            ? scheme.primaryContainer
                            : scheme.surfaceContainerHigh,
                        borderRadius: _bubbleRadius(
                          outgoing: outgoing,
                          groupEnd: groupEnd,
                        ),
                        border: highlighted
                            ? Border.all(color: scheme.tertiary, width: 2)
                            : null,
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
                                    ? AppLocalizations.of(
                                        context,
                                      ).deletedMessage
                                    : message.displayText,
                                foregroundColor: outgoing
                                    ? scheme.onPrimaryContainer
                                    : scheme.onSurface,
                                showReplyPreview: showReplyPreview,
                                onReactionTap: message.deleted
                                    ? null
                                    : (emoji) =>
                                          onReactionTap(message, parsed, emoji),
                                onOpenParent: onJumpToMessage,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (parsed?.lastEditTimestamp != null) ...[
                                  Text(
                                    AppLocalizations.of(context).edited,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: outgoing
                                              ? scheme.onPrimaryContainer
                                              : scheme.onSurfaceVariant,
                                        ),
                                  ),
                                  const SizedBox(width: 6),
                                ],
                                Text(
                                  _formatMessageClock(
                                    context,
                                    message.timestamp,
                                  ),
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(
                                        color: outgoing
                                            ? scheme.onPrimaryContainer
                                            : scheme.onSurfaceVariant,
                                      ),
                                ),
                                if (outgoing && deliveryState != null) ...[
                                  const SizedBox(width: 6),
                                  _DeliveryMark(
                                    key: Key(
                                      'chat-delivery-${message.messageId}',
                                    ),
                                    state: deliveryState!,
                                    color: scheme.onPrimaryContainer,
                                  ),
                                ],
                              ],
                            ),
                            if (canOpenThread) ...[
                              const SizedBox(height: 2),
                              TextButton.icon(
                                key: Key(
                                  'chat-open-thread-${message.messageId}',
                                ),
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
                                icon: const Icon(
                                  Icons.forum_outlined,
                                  size: 18,
                                ),
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
    required this.account,
    required this.operation,
    required this.onRetry,
    required this.onResend,
  });

  final StoredAccount account;
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
    final resourceUrl = exactGiphyResource(operation.message);
    final isGiphy = resourceUrl != null;
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
                if (isGiphy)
                  ChatPendingGiphyReference(
                    account: account,
                    resourceUrl: resourceUrl,
                    foregroundColor: scheme.onSecondaryContainer,
                  )
                else
                  Text(
                    normalizeGiphyReferencePreview(operation.message),
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
              cacheHeight: 480,
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

/// The controller has to outlive the closing transition of the dialog, so the
/// dialog owns it. Disposing it right after `showDialog` returns tears it down
/// while the still-mounted text field depends on it, which trips the framework
/// assertion `_dependents.isEmpty` and takes the whole app down.
final class _EditMessageDialog extends StatefulWidget {
  const _EditMessageDialog({required this.initialText});

  final String initialText;

  @override
  State<_EditMessageDialog> createState() => _EditMessageDialogState();
}

final class _EditMessageDialogState extends State<_EditMessageDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return AlertDialog(
      key: const Key('edit-message-dialog'),
      title: Text(strings.editMessageTitle),
      content: TextField(
        key: const Key('edit-message-field'),
        controller: _controller,
        autofocus: true,
        minLines: 1,
        maxLines: 5,
        maxLength: 32000,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        FilledButton(
          key: const Key('confirm-edit-message'),
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(strings.editMessageSave),
        ),
      ],
    );
  }
}

final class _ChatComposer extends StatelessWidget {
  const _ChatComposer({
    required this.controller,
    required this.sending,
    required this.readOnly,
    required this.mediaComposer,
    required this.replyTo,
    required this.onCancelReply,
    required this.mentionSource,
  });

  final TextEditingController controller;
  final bool sending;
  final bool readOnly;
  final Widget mediaComposer;
  final CachedChatMessage? replyTo;
  final VoidCallback onCancelReply;
  final MentionSuggestionSource? mentionSource;

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
                    if (replyTo != null)
                      _ReplyBanner(message: replyTo!, onCancel: onCancelReply),
                    MentionSuggestionsBar(
                      controller: controller,
                      source: mentionSource,
                      enabled: !sending,
                      labels: MentionSuggestionsLabels(
                        noResults: strings.mentionSuggestionsEmpty,
                        error: strings.mentionSuggestionsError,
                      ),
                    ),
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

/// Every own message the server already returned counts as delivered. The
/// read step comes from the server's common read marker, never from local
/// activity, so it also covers attachments and voice messages that never pass
/// through the text outbox.
OutgoingMessageDeliveryState? _serverDeliveryState(
  int messageId,
  int? lastCommonRead,
) {
  if (messageId < 1) {
    return null;
  }
  if (lastCommonRead != null && lastCommonRead >= messageId) {
    return OutgoingMessageDeliveryState.read;
  }
  return OutgoingMessageDeliveryState.sent;
}

int? _cursorValue(String? raw) {
  final parsed = raw == null ? null : int.tryParse(raw);
  return parsed == null || parsed < 0 ? null : parsed;
}

/// Only server-confirmed delivery is rendered. `sent` means the server stored
/// the message, `read` additionally means it is at or below the common read
/// marker; neither is inferred from local activity.
final class _DeliveryMark extends StatelessWidget {
  const _DeliveryMark({super.key, required this.state, required this.color});

  final OutgoingMessageDeliveryState state;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final (icon, label) = switch (state) {
      OutgoingMessageDeliveryState.read => (
        Icons.done_all_rounded,
        strings.messageRead,
      ),
      OutgoingMessageDeliveryState.sent => (
        Icons.done_rounded,
        strings.messageSent,
      ),
      OutgoingMessageDeliveryState.failed => (
        Icons.error_outline_rounded,
        strings.outboxFailed,
      ),
      OutgoingMessageDeliveryState.sending => (
        Icons.schedule_send_rounded,
        strings.outboxSending,
      ),
    };
    return Icon(icon, size: 14, color: color, semanticLabel: label);
  }
}

final class _ReplyBanner extends StatelessWidget {
  const _ReplyBanner({required this.message, required this.onCancel});

  final CachedChatMessage message;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      key: const Key('chat-reply-banner'),
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(Icons.reply_rounded, size: 18, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  strings.replyingTo(message.actorDisplayName),
                  style: Theme.of(
                    context,
                  ).textTheme.labelMedium?.copyWith(color: scheme.primary),
                ),
                Text(
                  message.displayText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: const Key('chat-cancel-reply'),
            tooltip: strings.cancelReply,
            onPressed: onCancel,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
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

String _messageActionErrorMessage(
  AppLocalizations strings,
  ChatMessageActionError error,
) {
  return switch (error) {
    ChatMessageActionError.credentialMissing ||
    ChatMessageActionError.reauthenticationRequired =>
      strings.syncCredentialMissing,
    ChatMessageActionError.talkUnavailable => strings.talkUnavailable,
    ChatMessageActionError.actionUnsupported =>
      strings.messageActionUnsupported,
    ChatMessageActionError.messageMissing =>
      strings.messageActionMessageMissing,
    ChatMessageActionError.rateLimited => strings.syncRateLimited,
    ChatMessageActionError.serviceUnavailable ||
    ChatMessageActionError.network => strings.chatUnavailable,
    ChatMessageActionError.accountMissing ||
    ChatMessageActionError.conversationMissing ||
    ChatMessageActionError.invalidResponse => strings.chatInvalidResponse,
  };
}

/// Decodes a scope's stored `blocks` column, or `null` when the scope
/// hasn't loaded yet or its blocks are unreadable. A missing/undecodable
/// scope means the client cannot yet judge what is contiguous, so callers
/// fall back to showing the cache unfiltered rather than hiding everything.
List<ChatBlock>? _decodeScopeBlocks(StoredChatScope? scope) {
  if (scope == null) {
    return null;
  }
  try {
    return decodeChatScopeBlocks(scope.blocksJson);
  } on Object {
    return null;
  }
}

/// Keeps only cached messages the scope's blocks actually cover. With no
/// scope info yet ([blocks] is `null`) nothing is filtered, since there is
/// nothing to judge coverage against.
List<CachedChatMessage> _messagesWithinBlocks(
  List<CachedChatMessage> messages,
  List<ChatBlock>? blocks,
) {
  if (blocks == null) {
    return messages;
  }
  return messages
      .where((message) => _blockIndexOf(blocks, message.messageId) != -1)
      .toList(growable: false);
}

int _blockIndexOf(List<ChatBlock> blocks, int messageId) {
  final cursor = ChatCursor.parse(messageId.toString());
  for (var index = 0; index < blocks.length; index++) {
    if (blocks[index].contains(cursor)) {
      return index;
    }
  }
  return -1;
}

/// A visible divider marking a gap the client honestly knows about: two
/// cached ranges with unfetched messages between them. The current fetch
/// protocol only ever extends a scope's history/future cursor at its two
/// ends (see `planChatGetMerge`), so there is no request that can close an
/// interior gap; this only ever renders when a future feature (for example
/// jumping to a specific message) caches a range disconnected from what is
/// already known, which is why it does not offer a "load" action that
/// would have nothing to call.
final class _ChatHistoryGapNotice extends StatelessWidget {
  const _ChatHistoryGapNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = AppLocalizations.of(context).chatHistoryGapNotice;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Semantics(
        label: label,
        child: Row(
          children: [
            Expanded(child: Divider(color: scheme.outlineVariant)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(child: Divider(color: scheme.outlineVariant)),
          ],
        ),
      ),
    );
  }
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
