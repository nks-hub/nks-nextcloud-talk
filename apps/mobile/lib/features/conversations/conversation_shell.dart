import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart' show MessageSearchResult;

import '../../app_providers.dart';
import '../../core/brand_mark.dart';
import '../../core/foreground_sync_loop.dart';
import '../../data/app_database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../chat/chat_room_pane.dart' show ChatThreadContext;
import '../newconversation/new_conversation_screen.dart';
import '../onboarding/onboarding_screen.dart';
import '../push/android_web_push_bridge.dart';
import '../search/message_search_screen.dart';
import '../search/message_search_thread_screen.dart';
import '../settings/settings_screen.dart';
import 'conversation_list_actions.dart';
import 'conversation_presence.dart';
import 'conversation_sync_service.dart';
import 'unread_badge.dart';

part 'conversation_account_chrome.dart';
part 'conversation_workspace.dart';

final class ConversationShell extends ConsumerStatefulWidget {
  const ConversationShell({super.key});

  @override
  ConsumerState<ConversationShell> createState() => _ConversationShellState();
}

final class _ConversationShellState extends ConsumerState<ConversationShell>
    with WidgetsBindingObserver {
  String? _scheduledAccountId;
  String? _syncingAccountId;
  String? _selectedConversationToken;
  String? _selectedAccountId;
  ForegroundSyncLoop? _liveSyncLoop;
  StreamSubscription<void>? _pushOpenSubscription;
  StreamSubscription<void>? _deepLinkSubscription;
  var _liveSyncGeneration = 0;
  var _isForeground = true;
  var _handlingPushOpen = false;
  var _handlingDeepLink = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    _isForeground =
        lifecycleState == null || lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _attachPushNavigation();
        _attachDeepLinkNavigation();
      }
    });
  }

  void _attachPushNavigation() {
    final coordinator = ref.read(androidPushCoordinatorProvider);
    if (coordinator == null || _pushOpenSubscription != null) {
      return;
    }
    _pushOpenSubscription = coordinator.notificationOpened.listen((_) {
      unawaited(_drainPushNavigation());
    });
    unawaited(_drainPushNavigation());
  }

  Future<void> _drainPushNavigation() async {
    if (_handlingPushOpen) {
      return;
    }
    final coordinator = ref.read(androidPushCoordinatorProvider);
    if (coordinator == null) {
      return;
    }
    _handlingPushOpen = true;
    try {
      while (mounted) {
        final open = coordinator.takeNextNotificationOpen();
        if (open == null) {
          return;
        }
        await _openPushNotification(open);
      }
    } finally {
      _handlingPushOpen = false;
    }
  }

  Future<void> _openPushNotification(AndroidNotificationOpen open) async {
    final roomToken = open.objectId;
    if (open.app != 'spreed' || roomToken == null || roomToken.isEmpty) {
      return;
    }
    await _openAccountConversation(open.accountId, roomToken);
  }

  void _attachDeepLinkNavigation() {
    final coordinator = ref.read(deepLinkCoordinatorProvider);
    if (coordinator == null || _deepLinkSubscription != null) {
      return;
    }
    _deepLinkSubscription = coordinator.linkAvailable.listen((_) {
      unawaited(_drainDeepLinks());
    });
    unawaited(_drainDeepLinks());
  }

  Future<void> _drainDeepLinks() async {
    if (_handlingDeepLink) {
      return;
    }
    final coordinator = ref.read(deepLinkCoordinatorProvider);
    if (coordinator == null) {
      return;
    }
    _handlingDeepLink = true;
    try {
      while (mounted) {
        final resolved = coordinator.takeNext();
        if (resolved == null) {
          return;
        }
        await _openAccountConversation(
          resolved.accountId,
          resolved.token.value,
        );
      }
    } finally {
      _handlingDeepLink = false;
    }
  }

  /// Selects [accountId], resyncs it and opens [token] once it is cached.
  ///
  /// A missing account or a room that never lands in the cache leaves the
  /// app exactly where it was; this never navigates to a guess.
  Future<void> _openAccountConversation(String accountId, String token) async {
    final accounts = ref.read(accountRepositoryProvider);
    final account = await accounts.getAccount(accountId);
    if (account == null) {
      return;
    }
    await accounts.selectAccount(account.id);
    try {
      await ref
          .read(conversationSyncServiceProvider)
          .sync(account.id, forceFull: true);
    } on ConversationSyncException {
      // A cached room can still be opened while the account retries its sync.
    }
    final conversation = await accounts.getConversation(
      accountId: account.id,
      token: token,
    );
    if (!mounted || conversation == null) {
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => PresenceChatRoomScreen(
          account: account,
          conversation: conversation,
        ),
      ),
    );
  }

  void _scheduleInitialSync(StoredAccount account) {
    _selectedAccountId = account.id;
    if (!_isForeground || _scheduledAccountId == account.id) {
      return;
    }
    _scheduledAccountId = account.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _isForeground && _selectedAccountId == account.id) {
        unawaited(_replaceLiveSync(account.id));
      }
    });
  }

  void _clearSelectedAccount() {
    final needsStop =
        _selectedAccountId != null ||
        _scheduledAccountId != null ||
        _liveSyncLoop != null;
    _selectedAccountId = null;
    _scheduledAccountId = null;
    if (needsStop) {
      unawaited(_stopLiveSync());
    }
  }

  Future<void> _replaceLiveSync(String accountId) async {
    final generation = ++_liveSyncGeneration;
    final previous = _liveSyncLoop;
    _liveSyncLoop = null;
    if (previous != null) {
      await previous.stop();
    }
    if (!mounted ||
        !_isForeground ||
        _selectedAccountId != accountId ||
        generation != _liveSyncGeneration) {
      return;
    }

    var showProgress = true;
    void finishCycle() {
      if (!mounted || _syncingAccountId != accountId) {
        return;
      }
      setState(() => _syncingAccountId = null);
      showProgress = false;
    }

    final loop = ForegroundSyncLoop(
      task: (cancellation) async {
        try {
          await ref
              .read(conversationSyncServiceProvider)
              .sync(accountId, abortTrigger: cancellation);
        } on ConversationSyncException catch (error) {
          if (_isPermanentConversationSyncError(error.code)) {
            finishCycle();
            await cancellation;
            return;
          }
          rethrow;
        }
      },
      successInterval: const Duration(seconds: 15),
      retryBaseDelay: const Duration(seconds: 2),
      retryMaximumDelay: const Duration(seconds: 30),
      onCycleStarted: () {
        if (showProgress && mounted && _syncingAccountId != accountId) {
          setState(() => _syncingAccountId = accountId);
        }
      },
      onSuccess: finishCycle,
      onError: (_) => finishCycle(),
    );
    _liveSyncLoop = loop;
    loop.start();
  }

  Future<void> _stopLiveSync() async {
    ++_liveSyncGeneration;
    final loop = _liveSyncLoop;
    _liveSyncLoop = null;
    if (loop != null) {
      await loop.stop();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    if (_isForeground == resumed) {
      return;
    }
    _isForeground = resumed;
    _scheduledAccountId = null;
    if (!resumed) {
      unawaited(_stopLiveSync());
      return;
    }
    final accountId = _selectedAccountId;
    if (accountId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _isForeground && _selectedAccountId == accountId) {
          _scheduledAccountId = accountId;
          unawaited(_replaceLiveSync(accountId));
        }
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_pushOpenSubscription?.cancel());
    unawaited(_deepLinkSubscription?.cancel());
    unawaited(_stopLiveSync());
    super.dispose();
  }

  Future<void> _refresh(String accountId) async {
    setState(() => _syncingAccountId = accountId);
    try {
      await ref
          .read(conversationSyncServiceProvider)
          .sync(accountId, forceFull: true);
    } on ConversationSyncException {
      // The account-scoped error code is persisted and rendered from Drift.
    } finally {
      if (mounted && _syncingAccountId == accountId) {
        setState(() => _syncingAccountId = null);
      }
    }
  }

  Future<void> _selectAccount(String accountId) async {
    if (_scheduledAccountId == accountId) {
      return;
    }
    _selectedConversationToken = null;
    await ref.read(accountRepositoryProvider).selectAccount(accountId);
  }

  Future<void> _addAccount() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => OnboardingScreen(
          onAccountAdded: (_) => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  Future<void> _reauthenticate(StoredAccount account) async {
    var completed = false;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (routeContext) => OnboardingScreen(
          reauthenticateAccount: account,
          onAccountAdded: (updated) {
            if (updated.id != account.id) {
              return;
            }
            completed = true;
            Navigator.of(routeContext).pop();
          },
        ),
      ),
    );
    if (!mounted || !completed || _selectedAccountId != account.id) {
      return;
    }
    _scheduledAccountId = account.id;
    await _replaceLiveSync(account.id);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appIconBadgeSyncProvider);
    final accountsValue = ref.watch(accountsProvider);
    final selectedValue = ref.watch(selectedAccountProvider);
    return selectedValue.when(
      loading: () => const _LoadingShell(),
      error: (_, _) => const _LoadingShell(),
      data: (selected) {
        if (selected == null) {
          _clearSelectedAccount();
          return const OnboardingScreen();
        }
        _scheduleInitialSync(selected);
        final accounts = accountsValue.valueOrNull ?? [selected];
        final conversationsValue = ref.watch(
          conversationsProvider(selected.id),
        );
        final conversations = conversationsValue.valueOrNull ?? const [];
        return ConversationWorkspace(
          account: selected,
          accounts: accounts,
          unreadByAccount: ref.watch(unreadSummaryProvider).byAccount,
          conversations: conversations,
          selectedConversationToken: _selectedConversationToken,
          loading: conversationsValue.isLoading,
          syncing: _syncingAccountId == selected.id,
          onRefresh: () => _refresh(selected.id),
          onReauthenticate: () => _reauthenticate(selected),
          onSelectAccount: _selectAccount,
          onAddAccount: _addAccount,
          onOpenConversation: (conversation) {
            Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (context) => PresenceChatRoomScreen(
                  account: selected,
                  conversation: conversation,
                ),
              ),
            );
          },
          onSelectConversation: (conversation) {
            setState(() => _selectedConversationToken = conversation.token);
          },
        );
      },
    );
  }
}

void _openMessageSearch(BuildContext context, String accountId) {
  Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (context) => _MessageSearchRoute(accountId: accountId),
    ),
  );
}

final class _MessageSearchRoute extends ConsumerStatefulWidget {
  const _MessageSearchRoute({required this.accountId});

  final String accountId;

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
      children: <Widget>[
        MessageSearchScreen(
          accountId: widget.accountId,
          service: ref.watch(messageSearchServiceProvider),
          onResultSelected: _openResult,
        ),
        IgnorePointer(
          key: const Key('message-search-result-guard'),
          ignoring: _resultPending,
          child: const SizedBox.shrink(),
        ),
      ],
    );
  }

  /// Resolves the result only while this exact search route and account still
  /// own the operation. Navigator and messenger state are deliberately looked
  /// up after the asynchronous work, so a stale completion cannot act on the
  /// route that happened to replace search in the meantime.
  void _openResult(MessageSearchResult result) {
    if (_resultPending) {
      return;
    }
    setState(() => _resultPending = true);
    final generation = ++_generation;
    final route = ModalRoute.of(context);
    unawaited(_resolveResult(result, route, generation));
  }

  Future<void> _resolveResult(
    MessageSearchResult result,
    ModalRoute<Object?>? route,
    int generation,
  ) async {
    try {
      final accounts = ref.read(accountRepositoryProvider);
      final account = await accounts.getAccount(widget.accountId);
      final conversation = account == null
          ? null
          : await accounts.getConversation(
              accountId: widget.accountId,
              token: result.roomToken.value,
            );
      if (!_ownsCompletion(route, generation)) {
        return;
      }
      if (account == null || conversation == null) {
        _closeWithMissingConversation();
        return;
      }

      final threadId = result.threadId;
      ChatThreadContext? threadContext;
      if (threadId != null && threadId != result.messageId) {
        try {
          threadContext = await resolveMessageSearchThread(
            repository: ref.read(chatRepositoryProvider),
            accountId: widget.accountId,
            result: result,
            synchronizeThread: () => ref
                .read(chatServiceProvider)
                .syncRoom(
                  accountId: widget.accountId,
                  roomToken: result.roomToken.value,
                  threadId: threadId,
                ),
          );
        } on MessageSearchThreadException catch (error) {
          if (_ownsCompletion(route, generation)) {
            _showThreadError(error.code);
          }
          return;
        }
      }

      if (!_ownsCompletion(route, generation)) {
        return;
      }
      if (!mounted) {
        return;
      }
      Navigator.of(context).pushReplacement<void, void>(
        MaterialPageRoute<void>(
          builder: (context) => buildMessageSearchDestination(
            account: account,
            conversation: conversation,
            result: result,
            threadContext: threadContext,
          ),
        ),
      );
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _resultPending = false);
      }
    }
  }

  bool _ownsCompletion(ModalRoute<Object?>? route, int generation) {
    if (!mounted || generation != _generation || route?.isCurrent != true) {
      return false;
    }
    return ref.read(selectedAccountProvider).valueOrNull?.id ==
        widget.accountId;
  }

  void _closeWithMissingConversation() {
    final strings = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.of(context).pop();
    if (messenger?.mounted ?? false) {
      messenger!
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            key: const Key('search-conversation-missing'),
            content: Text(strings.jumpToMessageConversationMissing),
          ),
        );
    }
  }

  void _showThreadError(MessageSearchThreadError error) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) {
      return;
    }
    final strings = AppLocalizations.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: const Key('search-thread-unavailable'),
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
}

void _openSettings(BuildContext context) {
  Navigator.of(context).push<void>(
    MaterialPageRoute<void>(builder: (context) => const SettingsScreen()),
  );
}

/// Opens the new-conversation screen and, once the server has created the
/// room, refreshes the list so the caller's own conversation stream is the
/// single source of truth for what exists.
void _openNewConversation(
  BuildContext context,
  String accountId,
  Future<void> Function() onRefresh,
) {
  Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (context) => NewConversationScreen(
        accountId: accountId,
        onConversationCreated: (_) {
          Navigator.of(context).pop();
          unawaited(onRefresh());
        },
      ),
    ),
  );
}

bool _isPermanentConversationSyncError(ConversationSyncError error) {
  return switch (error) {
    ConversationSyncError.rateLimited ||
    ConversationSyncError.serviceUnavailable ||
    ConversationSyncError.network => false,
    ConversationSyncError.accountMissing ||
    ConversationSyncError.credentialMissing ||
    ConversationSyncError.talkUnavailable ||
    ConversationSyncError.conversationProfileUnsupported ||
    ConversationSyncError.reauthenticationRequired ||
    ConversationSyncError.upgradeRequired ||
    ConversationSyncError.invalidResponse => true,
  };
}
