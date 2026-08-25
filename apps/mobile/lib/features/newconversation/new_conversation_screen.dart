import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import 'new_conversation_service.dart';

const Duration _searchDebounce = Duration(milliseconds: 300);

sealed class _SearchState {
  const _SearchState();
}

final class _SearchIdle extends _SearchState {
  const _SearchIdle();
}

final class _SearchLoading extends _SearchState {
  const _SearchLoading();
}

final class _SearchResults extends _SearchState {
  const _SearchResults(this.recipients);

  final List<ConversationRecipient> recipients;
}

final class _SearchFailed extends _SearchState {
  const _SearchFailed(this.error);

  final NewConversationError error;
}

/// Lets the user find a person or group and start a new conversation with
/// them. The screen never navigates on its own: on success it calls
/// [onConversationCreated] with the new room token and leaves opening it,
/// or refreshing any conversation list, to the caller.
final class NewConversationScreen extends ConsumerStatefulWidget {
  const NewConversationScreen({
    super.key,
    required this.accountId,
    required this.onConversationCreated,
  });

  final String accountId;
  final ValueChanged<ConversationToken> onConversationCreated;

  @override
  ConsumerState<NewConversationScreen> createState() =>
      _NewConversationScreenState();
}

final class _NewConversationScreenState
    extends ConsumerState<NewConversationScreen> {
  final _searchController = TextEditingController();
  Timer? _debounce;
  int _searchGeneration = 0;
  _SearchState _state = const _SearchIdle();
  bool _creating = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    final term = value.trim();
    if (term.isEmpty) {
      setState(() => _state = const _SearchIdle());
      return;
    }
    _debounce = Timer(_searchDebounce, () => _runSearch(term));
  }

  Future<void> _runSearch(String term) async {
    final generation = ++_searchGeneration;
    setState(() => _state = const _SearchLoading());
    final service = ref.read(newConversationServiceProvider);
    try {
      final recipients = await service.searchRecipients(
        accountId: widget.accountId,
        searchTerm: term,
      );
      if (!mounted || generation != _searchGeneration) {
        return;
      }
      setState(() => _state = _SearchResults(recipients));
    } on NewConversationException catch (error) {
      if (!mounted || generation != _searchGeneration) {
        return;
      }
      setState(() => _state = _SearchFailed(error.code));
    }
  }

  Future<void> _selectRecipient(ConversationRecipient recipient) async {
    String? roomName;
    if (recipient.shareType == RecipientShareType.group) {
      roomName = await _promptRoomName(recipient.label);
      if (roomName == null) {
        return;
      }
    }

    setState(() => _creating = true);
    final service = ref.read(newConversationServiceProvider);
    try {
      final token = await service.createConversation(
        accountId: widget.accountId,
        recipient: recipient,
        roomName: roomName,
      );
      if (!mounted) {
        return;
      }
      widget.onConversationCreated(token);
    } on NewConversationException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_errorMessage(error.code))));
    } finally {
      if (mounted) {
        setState(() => _creating = false);
      }
    }
  }

  Future<String?> _promptRoomName(String groupLabel) {
    final controller = TextEditingController(text: groupLabel);
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Name this group conversation'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Conversation name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final name = controller.text.trim();
              Navigator.of(dialogContext).pop(name.isEmpty ? null : name);
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New conversation')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              autofocus: true,
              enabled: !_creating,
              decoration: const InputDecoration(
                labelText: 'Search people and groups',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: _onSearchChanged,
              onSubmitted: (value) {
                _debounce?.cancel();
                final term = value.trim();
                if (term.isNotEmpty) {
                  _runSearch(term);
                }
              },
            ),
          ),
          Expanded(child: _buildBody(context)),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    return switch (_state) {
      _SearchIdle() => const _CenteredMessage(
        'Type a name to find someone to chat with.',
      ),
      _SearchLoading() => const Center(child: CircularProgressIndicator()),
      _SearchFailed(:final error) => _CenteredMessage(_errorMessage(error)),
      _SearchResults(recipients: final recipients) when recipients.isEmpty =>
        const _CenteredMessage('No people or groups found.'),
      _SearchResults(:final recipients) => ListView.builder(
        itemCount: recipients.length,
        itemBuilder: (context, index) {
          final recipient = recipients[index];
          return ListTile(
            leading: CircleAvatar(
              child: Icon(
                recipient.shareType == RecipientShareType.group
                    ? Icons.group
                    : Icons.person,
              ),
            ),
            title: Text(recipient.label),
            subtitle: recipient.subline == null
                ? null
                : Text(recipient.subline!),
            enabled: !_creating,
            onTap: _creating ? null : () => _selectRecipient(recipient),
          );
        },
      ),
    };
  }

  String _errorMessage(NewConversationError error) => switch (error) {
    NewConversationError.accountMissing =>
      'This account is no longer available.',
    NewConversationError.credentialMissing =>
      'Sign in again to search for people and groups.',
    NewConversationError.invalidSearchTerm => 'Enter a search term.',
    NewConversationError.roomNameRequired => 'The conversation needs a name.',
    NewConversationError.reauthenticationRequired =>
      'Sign in again to continue.',
    NewConversationError.ocsFailure => 'The server rejected the request.',
    NewConversationError.rateLimited => 'Too many requests. Try again soon.',
    NewConversationError.serviceUnavailable =>
      'The server is temporarily unavailable.',
    NewConversationError.invalidResponse =>
      'The server sent an unexpected response.',
    NewConversationError.network => 'Could not reach the server.',
  };
}

final class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(message, textAlign: TextAlign.center),
      ),
    );
  }
}
