import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import '../../l10n/generated/app_localizations.dart';
import 'new_conversation_service.dart';

/// Browses the conversations a server publishes as open and joins one.
///
/// Separate from the recipient search on purpose: those results are people to
/// start a chat with, these are rooms that already exist and that the account
/// is not in yet, so the action is "join", not "create".
final class OpenConversationsSheet extends ConsumerStatefulWidget {
  const OpenConversationsSheet({super.key, required this.accountId});

  final String accountId;

  @override
  ConsumerState<OpenConversationsSheet> createState() =>
      _OpenConversationsSheetState();
}

final class _OpenConversationsSheetState
    extends ConsumerState<OpenConversationsSheet> {
  List<ListedRoom>? _rooms;
  NewConversationError? _error;
  bool _joining = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _rooms = null;
      _error = null;
    });
    try {
      final rooms = await ref
          .read(newConversationServiceProvider)
          .listOpenConversations(accountId: widget.accountId);
      if (mounted) {
        setState(() => _rooms = rooms);
      }
    } on NewConversationException catch (failure) {
      if (mounted) {
        setState(() => _error = failure.code);
      }
    }
  }

  Future<void> _join(ListedRoom room) async {
    final strings = AppLocalizations.of(context);
    var password = '';
    if (room.hasPassword) {
      final entered = await _askPassword(strings);
      if (entered == null || !mounted) {
        return;
      }
      password = entered;
    }
    setState(() => _joining = true);
    try {
      final token = await ref
          .read(newConversationServiceProvider)
          .joinOpenConversation(
            accountId: widget.accountId,
            roomToken: room.token,
            password: password,
          );
      if (mounted) {
        Navigator.of(context).pop(token);
      }
    } on NewConversationException catch (failure) {
      if (!mounted) {
        return;
      }
      setState(() {
        _joining = false;
        _error = failure.code;
      });
    }
  }

  Future<String?> _askPassword(AppLocalizations strings) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('open-conversation-password-dialog'),
        title: Text(strings.openConversationsPasswordTitle),
        // Large text can make the body taller than the screen; without this
        // the actions are pushed off the bottom and the dialog cannot be
        // answered at all.
        scrollable: true,
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: true,
          decoration: InputDecoration(
            labelText: strings.openConversationsPasswordLabel,
          ),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(strings.cancel),
          ),
          FilledButton(
            key: const Key('open-conversation-password-submit'),
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: Text(strings.openConversationsJoin),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          key: const Key('open-conversations-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                strings.openConversations,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const SizedBox(height: 8),
            Flexible(child: _body(strings)),
          ],
        ),
      ),
    );
  }

  Widget _body(AppLocalizations strings) {
    if (_joining || _rooms == null && _error == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(
          key: Key('open-conversations-loading'),
          child: CircularProgressIndicator(),
        ),
      );
    }
    final error = _error;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          key: const Key('open-conversations-error'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_message(strings, error), textAlign: TextAlign.center),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => unawaited(_load()),
              child: Text(strings.retry),
            ),
          ],
        ),
      );
    }
    final rooms = _rooms ?? const <ListedRoom>[];
    if (rooms.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          strings.openConversationsEmpty,
          key: const Key('open-conversations-empty'),
          textAlign: TextAlign.center,
        ),
      );
    }
    return ListView.builder(
      key: const Key('open-conversations-list'),
      shrinkWrap: true,
      itemCount: rooms.length,
      itemBuilder: (context, index) {
        final room = rooms[index];
        return ListTile(
          key: Key('open-conversation-${room.token.value}'),
          leading: Icon(
            room.hasPassword ? Icons.lock_outline : Icons.public_outlined,
          ),
          title: Text(
            room.displayName.isEmpty ? room.token.value : room.displayName,
          ),
          subtitle: room.description.isEmpty
              ? null
              : Text(room.description, maxLines: 2),
          trailing: Text(strings.openConversationsJoin),
          onTap: () => unawaited(_join(room)),
        );
      },
    );
  }

  String _message(AppLocalizations strings, NewConversationError error) {
    return switch (error) {
      NewConversationError.unavailable =>
        strings.newConversationErrorUnavailable,
      NewConversationError.passwordRequired =>
        strings.newConversationErrorPasswordRejected,
      NewConversationError.reauthenticationRequired =>
        strings.newConversationErrorReauthenticationRequired,
      NewConversationError.serviceUnavailable =>
        strings.newConversationErrorServiceUnavailable,
      NewConversationError.network => strings.newConversationErrorNetwork,
      _ => strings.newConversationErrorInvalidResponse,
    };
  }
}
