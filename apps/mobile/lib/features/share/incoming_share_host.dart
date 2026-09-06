import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import '../../data/app_database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../conversations/conversation_avatar_widget.dart';
import 'incoming_share_bridge.dart';
import 'incoming_share_coordinator.dart';

final class IncomingShareTarget {
  const IncomingShareTarget({
    required this.accountId,
    required this.accountLabel,
    required this.roomToken,
    required this.roomLabel,
  });

  final String accountId;
  final String accountLabel;
  final String roomToken;
  final String roomLabel;
}

final class IncomingShareAccount {
  const IncomingShareAccount({
    required this.id,
    required this.label,
    required this.rooms,
    this.account,
  });

  final String id;
  final String label;
  final List<IncomingShareRoom> rooms;

  /// The stored row behind [id], carried so the picker can draw the real
  /// conversation avatars. Absent in tests, where the list is built by hand.
  final StoredAccount? account;
}

final class IncomingShareRoom {
  const IncomingShareRoom({
    required this.token,
    required this.label,
    this.conversation,
    this.subtitle,
  });

  final String token;
  final String label;

  /// The cached row behind [token]; see [IncomingShareAccount.account].
  final CachedConversation? conversation;

  /// What the conversation last carried, the same line the conversation list
  /// shows under the name.
  final String? subtitle;
}

final class IncomingShareHost extends ConsumerStatefulWidget {
  const IncomingShareHost({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<IncomingShareHost> createState() => _IncomingShareHostState();
}

final class _IncomingShareHostState extends ConsumerState<IncomingShareHost> {
  IncomingShareCoordinator? _coordinator;
  StreamSubscription<void>? _subscription;
  AppLifecycleListener? _lifecycle;
  var _draining = false;

  @override
  void initState() {
    super.initState();
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    final coordinator = IncomingShareCoordinator(IncomingShareBridge());
    _coordinator = coordinator;
    _subscription = coordinator.shareAvailable.listen((_) => _scheduleDrain());
    _lifecycle = AppLifecycleListener(
      onResume: () => unawaited(coordinator.refresh()),
    );
    unawaited(coordinator.start().then((_) => _scheduleDrain()));
  }

  void _scheduleDrain() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_drain());
    });
  }

  Future<void> _drain() async {
    final coordinator = _coordinator;
    if (_draining || coordinator == null || !mounted) return;
    _draining = true;
    try {
      while (mounted) {
        final share = coordinator.takeNext();
        if (share == null) return;
        if (!mounted) return;
        final sent = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => IncomingShareTargetDialog(
            share: share,
            loadAccounts: _loadAccounts,
            send: (target) => _send(share, target),
          ),
        );
        if (!mounted) return;
        if (sent == true || sent == false) {
          try {
            await coordinator.complete(share);
          } on Object {
            _showCompletionFailure();
          }
        }
      }
    } finally {
      _draining = false;
    }
  }

  Future<List<IncomingShareAccount>> _loadAccounts() async {
    final repository = ref.read(accountRepositoryProvider);
    final accounts = await repository.listAccounts();
    final result = <IncomingShareAccount>[];
    for (final account in accounts) {
      final conversations = await ref.read(
        conversationsProvider(account.id).future,
      );
      final rooms = conversations
          .where((room) => room.readOnly == 0 && !room.isArchived)
          .map(
            (room) => IncomingShareRoom(
              token: room.token,
              label: _roomLabel(room),
              conversation: room,
              subtitle: room.lastMessageText?.trim(),
            ),
          )
          .toList(growable: false);
      if (rooms.isEmpty) continue;
      result.add(
        IncomingShareAccount(
          id: account.id,
          label: _accountLabel(account),
          rooms: rooms,
          account: account,
        ),
      );
    }
    return result;
  }

  Future<void> _send(IncomingShare share, IncomingShareTarget target) async {
    final file = share.file;
    if (file == null) {
      await ref
          .read(chatServiceProvider)
          .sendText(
            accountId: target.accountId,
            roomToken: target.roomToken,
            message: share.text!,
          );
      return;
    }
    final sourceStore = await ref.read(attachmentSourceProvider.future);
    final source = await sourceStore.copyFromStream(
      stream: File(file.path).openRead(),
      mimeType: file.mimeType,
      displayName: file.displayName,
      expectedByteLength: file.byteLength,
    );
    var accepted = false;
    try {
      if (source.sha256.value != file.sha256) {
        throw const FormatException('Shared file changed before admission.');
      }
      final request = await ref
          .read(chatAttachmentContextResolverProvider)
          .resolve(
            accountId: AccountId.parse(target.accountId),
            roomToken: ConversationToken.parse(
              target.roomToken,
              path: r'$.roomToken',
            ),
            source: source,
            metadata: AttachmentMetadata(
              kind: AttachmentMessageKind.file,
              caption: share.text,
              replyTo: null,
              threadId: null,
              silent: false,
            ),
          );
      final service = await ref.read(attachmentServiceProvider.future);
      await service.enqueue(request);
      accepted = true;
    } finally {
      if (!accepted) await sourceStore.discard(source.handle);
    }
  }

  void _showCompletionFailure() {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context).incomingShareCleanupFailed,
          ),
        ),
      );
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    unawaited(_subscription?.cancel());
    unawaited(_coordinator?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

final class IncomingShareTargetDialog extends StatefulWidget {
  const IncomingShareTargetDialog({
    required this.share,
    required this.loadAccounts,
    required this.send,
    super.key,
  });

  final IncomingShare share;
  final Future<List<IncomingShareAccount>> Function() loadAccounts;
  final Future<void> Function(IncomingShareTarget target) send;

  @override
  State<IncomingShareTargetDialog> createState() =>
      _IncomingShareTargetDialogState();
}

final class _IncomingShareTargetDialogState
    extends State<IncomingShareTargetDialog> {
  /// Below this many conversations the search field is more furniture than
  /// help - the whole list is on screen anyway.
  static const _searchFrom = 8;

  late final Future<List<IncomingShareAccount>> _accounts = widget
      .loadAccounts();
  final _query = TextEditingController();
  IncomingShareAccount? _account;
  IncomingShareRoom? _room;
  String? _error;
  var _sending = false;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Dialog(
      key: const Key('incoming-share-target-dialog'),
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 620),
        child: FutureBuilder<List<IncomingShareAccount>>(
          future: _accounts,
          builder: (context, snapshot) {
            final loading = snapshot.connectionState != ConnectionState.done;
            final accounts = snapshot.data ?? const <IncomingShareAccount>[];
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        strings.incomingShareTitle,
                        style: theme.textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _shareSummary(strings),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (!loading && _totalRooms(accounts) >= _searchFrom)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: TextField(
                      key: const Key('incoming-share-search'),
                      controller: _query,
                      enabled: !_sending,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search_rounded),
                        hintText: strings.incomingShareSearch,
                        isDense: true,
                        border: const OutlineInputBorder(),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                Flexible(
                  child: loading
                      ? const Padding(
                          padding: EdgeInsets.all(32),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      : _buildList(strings, accounts, snapshot.hasError),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                    child: Text(
                      strings.incomingShareSendFailed,
                      key: const Key('incoming-share-error'),
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        key: const Key('incoming-share-cancel'),
                        onPressed: _sending
                            ? null
                            : () => Navigator.of(context).pop(false),
                        child: Text(strings.cancel),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        key: const Key('incoming-share-send'),
                        onPressed: _sending || _room == null ? null : _submit,
                        child: _sending
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(strings.incomingShareSend),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// What is being shared, shown under the title so the target is picked with
  /// the item in sight.
  String _shareSummary(AppLocalizations strings) {
    final file = widget.share.file;
    if (file != null) {
      final name = file.displayName.trim();
      return name.isEmpty ? strings.incomingShareFile : name;
    }
    final text = widget.share.text?.trim() ?? '';
    return text.isEmpty ? strings.incomingShareText : text;
  }

  int _totalRooms(List<IncomingShareAccount> accounts) =>
      accounts.fold(0, (sum, account) => sum + account.rooms.length);

  Widget _buildList(
    AppLocalizations strings,
    List<IncomingShareAccount> accounts,
    bool failed,
  ) {
    if (failed || accounts.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Text(strings.incomingShareNoTargets),
      );
    }
    final query = _query.text.trim().toLowerCase();
    // One heading per account and one tile per conversation, flattened into a
    // single scroller so the whole thing scrolls as one - a list per account
    // would give each its own scrollbar.
    final rows = <Widget>[];
    for (final account in accounts) {
      final rooms = query.isEmpty
          ? account.rooms
          : account.rooms
                .where((room) => room.label.toLowerCase().contains(query))
                .toList(growable: false);
      if (rooms.isEmpty) {
        continue;
      }
      // With a single account its name is noise: every row belongs to it.
      if (accounts.length > 1) {
        rows.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
            child: Text(
              account.label,
              style: _accountHeadingStyle(context),
            ),
          ),
        );
      }
      for (final room in rooms) {
        rows.add(_roomTile(account, room));
      }
    }
    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Text(
          strings.incomingShareNoMatches,
          key: const Key('incoming-share-no-matches'),
        ),
      );
    }
    return ListView(padding: EdgeInsets.zero, shrinkWrap: true, children: rows);
  }

  Widget _roomTile(IncomingShareAccount account, IncomingShareRoom room) {
    final selected = _room?.token == room.token && _account?.id == account.id;
    final subtitle = room.subtitle;
    return ListTile(
      key: Key('incoming-share-room-${account.id}-${room.token}'),
      selected: selected,
      enabled: !_sending,
      leading: _avatar(account, room),
      title: Text(room.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null || subtitle.isEmpty
          ? null
          : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: selected ? const Icon(Icons.check_rounded) : null,
      onTap: _sending
          ? null
          : () => setState(() {
              _account = account;
              _room = room;
              _error = null;
            }),
    );
  }

  /// The real avatar when the rows behind the entry came from the database,
  /// and the conversation's initial when they did not.
  Widget _avatar(IncomingShareAccount account, IncomingShareRoom room) {
    final stored = account.account;
    final conversation = room.conversation;
    if (stored != null && conversation != null) {
      return ConversationAvatar(account: stored, conversation: conversation);
    }
    final label = room.label.trim();
    return CircleAvatar(
      child: Text(label.isEmpty ? '?' : label.substring(0, 1).toUpperCase()),
    );
  }

  Future<void> _submit() async {
    final room = _room!;
    final account = _account!;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.send(
        IncomingShareTarget(
          accountId: account.id,
          accountLabel: account.label,
          roomToken: room.token,
          roomLabel: room.label,
        ),
      );
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } on Object {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = 'send-failed';
        });
      }
    }
  }
}

TextStyle? _accountHeadingStyle(BuildContext context) =>
    Theme.of(context).textTheme.labelLarge?.copyWith(
      color: Theme.of(context).colorScheme.primary,
    );

String _accountLabel(StoredAccount account) {
  final server = Uri.tryParse(account.serverUrl)?.host;
  return server == null || server.isEmpty
      ? account.loginName
      : '${account.loginName} · $server';
}

String _roomLabel(CachedConversation room) {
  final label = room.displayName.trim();
  return label.isEmpty ? room.token : label;
}
