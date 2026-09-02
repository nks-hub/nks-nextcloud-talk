import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import '../../data/app_database.dart';
import '../../l10n/generated/app_localizations.dart';
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
  });

  final String id;
  final String label;
  final List<IncomingShareRoom> rooms;
}

final class IncomingShareRoom {
  const IncomingShareRoom({required this.token, required this.label});

  final String token;
  final String label;
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
            (room) =>
                IncomingShareRoom(token: room.token, label: _roomLabel(room)),
          )
          .toList(growable: false);
      if (rooms.isEmpty) continue;
      result.add(
        IncomingShareAccount(
          id: account.id,
          label: _accountLabel(account),
          rooms: rooms,
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
  late final Future<List<IncomingShareAccount>> _accounts = widget
      .loadAccounts();
  String? _accountId;
  IncomingShareRoom? _room;
  String? _error;
  var _sending = false;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return AlertDialog(
      key: const Key('incoming-share-target-dialog'),
      title: Text(strings.incomingShareTitle),
      content: SizedBox(
        width: 480,
        child: FutureBuilder<List<IncomingShareAccount>>(
          future: _accounts,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final accounts = snapshot.data ?? const <IncomingShareAccount>[];
            if (snapshot.hasError || accounts.isEmpty) {
              return Text(strings.incomingShareNoTargets);
            }
            final selectedAccount = accounts
                .where((account) => account.id == _accountId)
                .firstOrNull;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String>(
                  key: const Key('incoming-share-account'),
                  initialValue: _accountId,
                  decoration: InputDecoration(
                    labelText: strings.incomingShareAccount,
                  ),
                  items: [
                    for (final account in accounts)
                      DropdownMenuItem(
                        value: account.id,
                        child: Text(account.label),
                      ),
                  ],
                  onChanged: _sending
                      ? null
                      : (value) => setState(() {
                          _accountId = value;
                          _room = null;
                          _error = null;
                        }),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: const Key('incoming-share-room'),
                  initialValue: _room?.token,
                  decoration: InputDecoration(
                    labelText: strings.incomingShareConversation,
                  ),
                  items: [
                    for (final room
                        in selectedAccount?.rooms ??
                            const <IncomingShareRoom>[])
                      DropdownMenuItem(
                        value: room.token,
                        child: Text(room.label),
                      ),
                  ],
                  onChanged: _sending || selectedAccount == null
                      ? null
                      : (value) => setState(() {
                          _room = selectedAccount.rooms.firstWhere(
                            (room) => room.token == value,
                          );
                          _error = null;
                        }),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    strings.incomingShareSendFailed,
                    key: const Key('incoming-share-error'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          key: const Key('incoming-share-cancel'),
          onPressed: _sending ? null : () => Navigator.of(context).pop(false),
          child: Text(strings.cancel),
        ),
        FilledButton(
          key: const Key('incoming-share-send'),
          onPressed: _sending || _accountId == null || _room == null
              ? null
              : _submit,
          child: _sending
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(strings.incomingShareSend),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    final room = _room!;
    final accountId = _accountId!;
    final accounts = await _accounts;
    final account = accounts.firstWhere((item) => item.id == accountId);
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
      if (mounted) Navigator.of(context).pop(true);
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
