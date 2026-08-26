import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../core/desktop_metrics.dart';
import '../../core/text_prompt_dialog.dart';
import '../../data/app_database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../chat/chat_room_pane.dart';
import '../chat/chat_service.dart';
import 'thread_management_service.dart';

final class ThreadManagementScreen extends ConsumerStatefulWidget {
  const ThreadManagementScreen({
    super.key,
    required this.account,
    required this.conversation,
  });

  final StoredAccount account;
  final CachedConversation conversation;

  @override
  ConsumerState<ThreadManagementScreen> createState() =>
      _ThreadManagementScreenState();
}

final class _ThreadManagementScreenState
    extends ConsumerState<ThreadManagementScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  var _recentLoading = false;
  var _subscribedLoading = false;
  var _subscribedStarted = false;
  Object? _recentError;
  Object? _subscribedError;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this)
      ..addListener(_handleTabChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_refreshRecent());
      }
    });
  }

  @override
  void dispose() {
    _tabController
      ..removeListener(_handleTabChanged)
      ..dispose();
    super.dispose();
  }

  void _handleTabChanged() {
    if (_tabController.index == 1 && !_subscribedStarted) {
      _subscribedStarted = true;
      unawaited(_refreshSubscribed());
    }
  }

  Future<void> _refreshRecent() async {
    if (_recentLoading) {
      return;
    }
    setState(() {
      _recentLoading = true;
      _recentError = null;
    });
    try {
      await ref
          .read(threadManagementServiceProvider)
          .refreshRecent(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
          );
    } on Object catch (error) {
      if (mounted) {
        setState(() => _recentError = error);
      }
    } finally {
      if (mounted) {
        setState(() => _recentLoading = false);
      }
    }
  }

  Future<void> _refreshSubscribed() async {
    if (_subscribedLoading) {
      return;
    }
    setState(() {
      _subscribedLoading = true;
      _subscribedError = null;
    });
    try {
      await ref
          .read(threadManagementServiceProvider)
          .refreshSubscribed(accountId: widget.account.id);
    } on Object catch (error) {
      if (mounted) {
        setState(() => _subscribedError = error);
      }
    } finally {
      if (mounted) {
        setState(() => _subscribedLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final roomKey = (
      accountId: widget.account.id,
      roomToken: widget.conversation.token,
    );
    final recent = ref.watch(recentThreadsProvider(roomKey));
    final subscribed = ref.watch(subscribedThreadsProvider(widget.account.id));
    final conversations = ref
        .watch(conversationsProvider(widget.account.id))
        .valueOrNull;
    final roomNames = <String, String>{
      widget.conversation.token: widget.conversation.displayName,
      for (final conversation in conversations ?? const <CachedConversation>[])
        conversation.token: conversation.displayName,
    };
    final roomRows = <String, CachedConversation>{
      widget.conversation.token: widget.conversation,
      for (final conversation in conversations ?? const <CachedConversation>[])
        conversation.token: conversation,
    };

    return Scaffold(
      key: const Key('thread-management-screen'),
      appBar: AppBar(
        title: Text(strings.threadManagementTitle),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(
              key: const Key('thread-management-recent-tab'),
              text: strings.threadManagementRecentTab,
            ),
            Tab(
              key: const Key('thread-management-subscribed-tab'),
              text: strings.threadManagementSubscribedTab,
            ),
          ],
        ),
      ),
      body: SafeArea(
        top: false,
        child: TabBarView(
          controller: _tabController,
          children: [
            _ThreadListTab(
              tabKey: const Key('thread-management-recent-list'),
              threads: recent.valueOrNull ?? const <CachedThread>[],
              loading: _recentLoading || recent.isLoading,
              error: _recentError ?? recent.error,
              emptyTitle: strings.threadManagementRecentEmpty,
              emptyBody: strings.threadManagementRecentEmptyBody,
              roomNames: roomNames,
              onRefresh: _refreshRecent,
              onOpen: (thread) =>
                  _openDetail(thread, roomRows[thread.roomToken]),
            ),
            _ThreadListTab(
              tabKey: const Key('thread-management-subscribed-list'),
              threads: subscribed.valueOrNull ?? const <CachedThread>[],
              loading: _subscribedLoading || subscribed.isLoading,
              error: _subscribedError ?? subscribed.error,
              emptyTitle: strings.threadManagementSubscribedEmpty,
              emptyBody: strings.threadManagementSubscribedEmptyBody,
              roomNames: roomNames,
              onRefresh: _refreshSubscribed,
              onOpen: (thread) =>
                  _openDetail(thread, roomRows[thread.roomToken]),
            ),
          ],
        ),
      ),
    );
  }

  void _openDetail(CachedThread thread, CachedConversation? conversation) {
    if (conversation == null) {
      final messenger = ScaffoldMessenger.of(context);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            key: const Key('thread-management-room-missing'),
            content: Text(
              AppLocalizations.of(context).threadManagementConversationMissing,
            ),
          ),
        );
      return;
    }
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (context) => ThreadDetailScreen(
            account: widget.account,
            conversation: conversation,
            thread: thread,
          ),
        ),
      ),
    );
  }
}

final class ThreadDetailScreen extends ConsumerStatefulWidget {
  const ThreadDetailScreen({
    super.key,
    required this.account,
    required this.conversation,
    required this.thread,
  });

  final StoredAccount account;
  final CachedConversation conversation;
  final CachedThread thread;

  @override
  ConsumerState<ThreadDetailScreen> createState() => _ThreadDetailScreenState();
}

final class _ThreadDetailScreenState extends ConsumerState<ThreadDetailScreen> {
  ThreadDetailAccess? _access;
  Object? _error;
  var _busy = false;

  ThreadProviderKey get _key => (
    accountId: widget.account.id,
    roomToken: widget.thread.roomToken,
    threadId: widget.thread.threadId,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_load());
      }
    });
  }

  Future<void> _load() async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final access = await ref
          .read(threadManagementServiceProvider)
          .loadDetail(
            accountId: widget.account.id,
            roomToken: widget.thread.roomToken,
            threadId: widget.thread.threadId,
          );
      if (mounted) {
        setState(() => _access = access);
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = error);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _rename(CachedThread current) async {
    if (_busy || _access?.canRename != true) {
      return;
    }
    final strings = AppLocalizations.of(context);
    final title = await showTextPromptDialog(
      context: context,
      dialogKey: const Key('thread-management-rename-dialog'),
      fieldKey: const Key('thread-management-rename-field'),
      confirmKey: const Key('thread-management-rename-save'),
      title: strings.threadManagementRenameDialogTitle,
      initialValue: current.title,
      fieldLabel: strings.threadManagementNameLabel,
      cancelLabel: strings.cancel,
      confirmLabel: strings.roomDetailsSave,
      maxLength: 4096,
      emptyErrorText: strings.threadManagementNameRequired,
    );
    if (title == null || !mounted) {
      return;
    }
    await _runMutation(
      () => ref
          .read(threadManagementServiceProvider)
          .rename(
            accountId: widget.account.id,
            roomToken: current.roomToken,
            threadId: current.threadId,
            title: title,
          ),
    );
  }

  Future<void> _setNotificationLevel(int level) {
    final current = ref.read(threadDetailProvider(_key)).valueOrNull;
    if (current == null ||
        current.notificationLevel == level ||
        _busy ||
        _access?.canChangeNotifications != true) {
      return Future<void>.value();
    }
    return _runMutation(
      () => ref
          .read(threadManagementServiceProvider)
          .setNotificationLevel(
            accountId: widget.account.id,
            roomToken: current.roomToken,
            threadId: current.threadId,
            level: level,
          ),
    );
  }

  Future<void> _runMutation(
    Future<ThreadDetailAccess> Function() action,
  ) async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final access = await action();
      if (mounted) {
        setState(() => _access = access);
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = error);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _openThread() async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(threadManagementServiceProvider)
          .loadDetail(
            accountId: widget.account.id,
            roomToken: widget.thread.roomToken,
            threadId: widget.thread.threadId,
          );
      final root = await ref
          .read(chatRepositoryProvider)
          .getMessage(
            accountId: widget.account.id,
            roomToken: widget.thread.roomToken,
            messageId: widget.thread.threadId,
          );
      final threadContext = root == null
          ? null
          : ChatThreadContext.fromCachedRoot(
              accountId: widget.account.id,
              roomToken: widget.thread.roomToken,
              root: root,
            );
      if (threadContext == null) {
        throw const _ThreadOpenUnavailable();
      }
      if (!mounted) {
        return;
      }
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (context) => ChatThreadScreen(
            account: widget.account,
            conversation: widget.conversation,
            threadContext: threadContext,
          ),
        ),
      );
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = error);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final watched = ref.watch(threadDetailProvider(_key));
    final current = watched.valueOrNull ?? widget.thread;
    final error = _error ?? watched.error;
    final canRename = _access?.canRename == true && !_busy;
    final canNotify = _access?.canChangeNotifications == true && !_busy;

    return Scaffold(
      key: const Key('thread-management-detail-screen'),
      appBar: AppBar(
        title: Text(strings.threadManagementDetailTitle),
        actions: [
          IconButton(
            key: const Key('thread-management-detail-refresh'),
            tooltip: strings.refresh,
            onPressed: _busy ? null : () => unawaited(_load()),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            key: const Key('thread-management-detail-list'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              if (_busy)
                const LinearProgressIndicator(
                  key: Key('thread-management-detail-progress'),
                ),
              if (error != null) ...[
                const SizedBox(height: 12),
                _ThreadErrorBanner(error: error, onRetry: _load),
              ],
              const SizedBox(height: 16),
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _ThreadDetailHeader(
                        thread: current,
                        roomName: widget.conversation.displayName,
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        key: const Key('thread-management-open-thread'),
                        onPressed: _busy
                            ? null
                            : () => unawaited(_openThread()),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                        ),
                        icon: const Icon(Icons.forum_outlined),
                        label: Text(strings.openThread),
                      ),
                      const SizedBox(height: 16),
                      Card.outlined(
                        clipBehavior: Clip.antiAlias,
                        child: Column(
                          children: [
                            ListTile(
                              key: const Key('thread-management-rename'),
                              minTileHeight: context.actionRowHeight,
                              leading: const Icon(Icons.edit_outlined),
                              title: Text(strings.threadManagementRenameAction),
                              trailing: const Icon(Icons.chevron_right_rounded),
                              enabled: canRename,
                              onTap: canRename
                                  ? () => unawaited(_rename(current))
                                  : null,
                            ),
                            const Divider(height: 1),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                              child: Align(
                                alignment: AlignmentDirectional.centerStart,
                                child: Text(
                                  strings.roomDetailsNotificationDialogTitle,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                              ),
                            ),
                            RadioGroup<int>(
                              groupValue: current.notificationLevel,
                              onChanged: (level) {
                                if (canNotify && level != null) {
                                  unawaited(_setNotificationLevel(level));
                                }
                              },
                              child: Column(
                                children: [
                                  for (var level = 0; level <= 3; level++)
                                    RadioListTile<int>(
                                      key: Key(
                                        'thread-management-notification-$level',
                                      ),
                                      value: level,
                                      enabled: canNotify,
                                      title: Text(
                                        _notificationLevelLabel(strings, level),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_access == null) ...[
                        const SizedBox(height: 12),
                        Text(
                          strings.threadManagementActionsNeedConnection,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _ThreadListTab extends StatelessWidget {
  const _ThreadListTab({
    required this.tabKey,
    required this.threads,
    required this.loading,
    required this.error,
    required this.emptyTitle,
    required this.emptyBody,
    required this.roomNames,
    required this.onRefresh,
    required this.onOpen,
  });

  final Key tabKey;
  final List<CachedThread> threads;
  final bool loading;
  final Object? error;
  final String emptyTitle;
  final String emptyBody;
  final Map<String, String> roomNames;
  final Future<void> Function() onRefresh;
  final ValueChanged<CachedThread> onOpen;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: tabKey,
      children: [
        if (loading && threads.isNotEmpty)
          const LinearProgressIndicator(
            key: Key('thread-management-list-progress'),
          ),
        if (error != null && threads.isNotEmpty)
          _ThreadErrorBanner(error: error!, onRetry: onRefresh),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (threads.isEmpty) {
                    return RefreshIndicator(
                      onRefresh: onRefresh,
                      child: ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          SizedBox(
                            height: constraints.maxHeight,
                            child: loading
                                ? const Center(
                                    child: CircularProgressIndicator(
                                      key: Key(
                                        'thread-management-empty-progress',
                                      ),
                                    ),
                                  )
                                : error == null
                                ? _ThreadEmptyState(
                                    title: emptyTitle,
                                    body: emptyBody,
                                  )
                                : _ThreadFullErrorState(
                                    error: error!,
                                    onRetry: onRefresh,
                                  ),
                          ),
                        ],
                      ),
                    );
                  }
                  return RefreshIndicator(
                    onRefresh: onRefresh,
                    child: ListView.separated(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: threads.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final thread = threads[index];
                        return _ThreadListTile(
                          thread: thread,
                          roomName: roomNames[thread.roomToken],
                          onTap: () => onOpen(thread),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

final class _ThreadListTile extends StatelessWidget {
  const _ThreadListTile({
    required this.thread,
    required this.roomName,
    required this.onTap,
  });

  final CachedThread thread;
  final String? roomName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final title = thread.title.trim().isEmpty ? strings.thread : thread.title;
    final details = <String>[
      ?roomName,
      strings.threadReplies(thread.numReplies),
      _formatActivity(context, thread.lastActivity),
    ].join(' · ');
    final notification = _notificationLevelLabel(
      strings,
      thread.notificationLevel,
    );
    return ListTile(
      key: Key('thread-management-item-${thread.roomToken}-${thread.threadId}'),
      minTileHeight: context.secondaryRowHeight,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: const CircleAvatar(child: Icon(Icons.forum_outlined)),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(details, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: Tooltip(
        message: notification,
        child: Icon(
          _notificationIcon(thread.notificationLevel),
          semanticLabel: notification,
        ),
      ),
      onTap: onTap,
    );
  }
}

final class _ThreadDetailHeader extends StatelessWidget {
  const _ThreadDetailHeader({required this.thread, required this.roomName});

  final CachedThread thread;
  final String roomName;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final title = thread.title.trim().isEmpty ? strings.thread : thread.title;
    return Card.outlined(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const CircleAvatar(radius: 24, child: Icon(Icons.forum_outlined)),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(roomName),
                  const SizedBox(height: 4),
                  Text(
                    '${strings.threadReplies(thread.numReplies)} · '
                    '${_formatActivity(context, thread.lastActivity)}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _ThreadErrorBanner extends StatelessWidget {
  const _ThreadErrorBanner({required this.error, required this.onRetry});

  final Object error;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final strings = AppLocalizations.of(context);
    return Material(
      key: const Key('thread-management-error-banner'),
      color: colors.errorContainer,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: colors.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _threadErrorMessage(strings, error),
                style: TextStyle(color: colors.onErrorContainer),
              ),
            ),
            TextButton(
              onPressed: () => unawaited(onRetry()),
              style: TextButton.styleFrom(
                foregroundColor: colors.onErrorContainer,
                minimumSize: const Size(48, 48),
              ),
              child: Text(strings.retry),
            ),
          ],
        ),
      ),
    );
  }
}

final class _ThreadFullErrorState extends StatelessWidget {
  const _ThreadFullErrorState({required this.error, required this.onRetry});

  final Object error;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 48),
            const SizedBox(height: 16),
            Text(
              _threadErrorMessage(strings, error),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('thread-management-error-retry'),
              onPressed: () => unawaited(onRetry()),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              icon: const Icon(Icons.refresh_rounded),
              label: Text(strings.retry),
            ),
          ],
        ),
      ),
    );
  }
}

final class _ThreadEmptyState extends StatelessWidget {
  const _ThreadEmptyState({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.forum_outlined, size: 48),
            const SizedBox(height: 16),
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(body, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

final class _ThreadOpenUnavailable implements Exception {
  const _ThreadOpenUnavailable();
}

String _threadErrorMessage(AppLocalizations strings, Object error) {
  if (error is _ThreadOpenUnavailable) {
    return strings.threadManagementOpenUnavailable;
  }
  if (error is ChatServiceException) {
    return switch (error.code) {
      ChatServiceError.credentialMissing ||
      ChatServiceError.reauthenticationRequired =>
        strings.syncCredentialMissing,
      ChatServiceError.rateLimited => strings.syncRateLimited,
      ChatServiceError.network => strings.syncNetwork,
      _ => strings.chatUnavailable,
    };
  }
  if (error is! ThreadManagementException) {
    return strings.unexpectedError;
  }
  return switch (error.code) {
    ThreadManagementError.accountMissing ||
    ThreadManagementError.credentialMissing ||
    ThreadManagementError.reauthenticationRequired =>
      strings.syncCredentialMissing,
    ThreadManagementError.conversationMissing ||
    ThreadManagementError.notFound => strings.threadManagementNotFound,
    ThreadManagementError.talkUnavailable => strings.talkUnavailable,
    ThreadManagementError.unsupported => strings.threadManagementUnsupported,
    ThreadManagementError.permissionDenied =>
      strings.threadManagementPermissionDenied,
    ThreadManagementError.rateLimited => strings.syncRateLimited,
    ThreadManagementError.serviceUnavailable => strings.syncUnavailable,
    ThreadManagementError.network => strings.syncNetwork,
    ThreadManagementError.ambiguous => strings.threadManagementAmbiguous,
    ThreadManagementError.invalidInput ||
    ThreadManagementError.invalidResponse => strings.invalidResponse,
  };
}

String _notificationLevelLabel(AppLocalizations strings, int level) {
  return switch (level) {
    0 => strings.roomDetailsNotificationDefault,
    1 => strings.roomDetailsNotificationAlways,
    2 => strings.roomDetailsNotificationMention,
    3 => strings.roomDetailsNotificationNever,
    _ => strings.roomDetailsNotificationUnknown,
  };
}

IconData _notificationIcon(int level) {
  return switch (level) {
    1 => Icons.notifications_active_outlined,
    2 => Icons.alternate_email_rounded,
    3 => Icons.notifications_off_outlined,
    _ => Icons.notifications_none_outlined,
  };
}

String _formatActivity(BuildContext context, int unixSeconds) {
  final date = DateTime.fromMillisecondsSinceEpoch(
    unixSeconds * 1000,
  ).toLocal();
  final now = DateTime.now();
  final localizations = MaterialLocalizations.of(context);
  if (date.year == now.year && date.month == now.month && date.day == now.day) {
    return localizations.formatTimeOfDay(TimeOfDay.fromDateTime(date));
  }
  return localizations.formatCompactDate(date);
}
