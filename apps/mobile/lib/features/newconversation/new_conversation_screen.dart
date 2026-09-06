import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import '../../core/text_prompt_dialog.dart';
import '../../l10n/generated/app_localizations.dart';
import 'new_conversation_service.dart';
import 'open_conversations_sheet.dart';

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
      roomName = await _promptRoomName(
        initialValue: recipient.label,
        title: AppLocalizations.of(context).newConversationNameDialogTitle,
      );
      if (roomName == null) {
        return;
      }
    }

    await _runCreation(
      (service) => service.createConversation(
        accountId: widget.accountId,
        recipient: recipient,
        roomName: roomName,
      ),
    );
  }

  Future<void> _createStandaloneConversation(
    StandaloneConversationType type,
  ) async {
    final strings = AppLocalizations.of(context);
    final roomName = await _promptRoomName(
      initialValue: '',
      title: switch (type) {
        StandaloneConversationType.group =>
          strings.newConversationNameDialogTitle,
        StandaloneConversationType.public =>
          strings.newConversationPublicNameDialogTitle,
      },
    );
    if (roomName == null) {
      return;
    }
    await _runCreation(
      (service) => service.createStandaloneConversation(
        accountId: widget.accountId,
        type: type,
        roomName: roomName,
      ),
    );
  }

  Future<void> _browseOpenConversations() async {
    final token = await showModalBottomSheet<ConversationToken>(
      context: context,
      isScrollControlled: true,
      builder: (_) => OpenConversationsSheet(accountId: widget.accountId),
    );
    if (token == null || !mounted) {
      return;
    }
    // Joining already put the account in the room, so the caller opens it the
    // same way it opens a conversation it just created.
    widget.onConversationCreated(token);
  }

  Future<void> _runCreation(
    Future<ConversationToken> Function(NewConversationService service) create,
  ) async {
    setState(() => _creating = true);
    final service = ref.read(newConversationServiceProvider);
    try {
      final token = await create(service);
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

  Future<String?> _promptRoomName({
    required String initialValue,
    required String title,
  }) async {
    final strings = AppLocalizations.of(context);
    final name = await showTextPromptDialog(
      context: context,
      title: title,
      initialValue: initialValue,
      fieldLabel: strings.newConversationNameLabel,
      cancelLabel: strings.cancel,
      confirmLabel: strings.newConversationCreate,
      maxLength: 200,
      emptyErrorText: strings.newConversationErrorRoomNameRequired,
    );
    final trimmed = name?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(strings.newConversationTitle)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              autofocus: true,
              enabled: !_creating,
              decoration: InputDecoration(
                labelText: strings.newConversationSearchLabel,
                prefixIcon: const Icon(Icons.search),
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  key: const Key('create-empty-group-conversation'),
                  onPressed: _creating
                      ? null
                      : () => _createStandaloneConversation(
                          StandaloneConversationType.group,
                        ),
                  icon: const Icon(Icons.group_add_outlined),
                  label: Text(strings.newConversationCreateGroupAction),
                ),
                OutlinedButton.icon(
                  key: const Key('create-public-conversation'),
                  onPressed: _creating
                      ? null
                      : () => _createStandaloneConversation(
                          StandaloneConversationType.public,
                        ),
                  icon: const Icon(Icons.public_outlined),
                  label: Text(strings.newConversationCreatePublicAction),
                ),
                OutlinedButton.icon(
                  key: const Key('browse-open-conversations'),
                  onPressed: _creating ? null : _browseOpenConversations,
                  icon: const Icon(Icons.travel_explore_outlined),
                  label: Text(strings.openConversations),
                ),
              ],
            ),
          ),
          Expanded(child: _buildBody(context)),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return switch (_state) {
      _SearchIdle() => _CenteredMessage(strings.newConversationIdle),
      _SearchLoading() => const Center(child: CircularProgressIndicator()),
      _SearchFailed(:final error) => _CenteredMessage(_errorMessage(error)),
      _SearchResults(recipients: final recipients) when recipients.isEmpty =>
        _CenteredMessage(strings.newConversationEmpty),
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

  String _errorMessage(NewConversationError error) {
    final strings = AppLocalizations.of(context);
    return switch (error) {
      NewConversationError.accountMissing =>
        strings.newConversationErrorAccountMissing,
      NewConversationError.credentialMissing =>
        strings.newConversationErrorCredentialMissing,
      NewConversationError.invalidSearchTerm =>
        strings.newConversationErrorInvalidSearchTerm,
      NewConversationError.roomNameRequired =>
        strings.newConversationErrorRoomNameRequired,
      NewConversationError.reauthenticationRequired =>
        strings.newConversationErrorReauthenticationRequired,
      NewConversationError.unavailable =>
        strings.newConversationErrorUnavailable,
      NewConversationError.passwordRequired =>
        strings.newConversationErrorPasswordRejected,
      NewConversationError.ocsFailure => strings.newConversationErrorOcsFailure,
      NewConversationError.rateLimited =>
        strings.newConversationErrorRateLimited,
      NewConversationError.serviceUnavailable =>
        strings.newConversationErrorServiceUnavailable,
      NewConversationError.invalidResponse =>
        strings.newConversationErrorInvalidResponse,
      NewConversationError.network => strings.newConversationErrorNetwork,
    };
  }
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
