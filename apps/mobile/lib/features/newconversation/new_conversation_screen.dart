import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import '../../core/desktop_metrics.dart';
import '../../l10n/generated/app_localizations.dart';
import 'new_conversation_service.dart';
import 'conversation_creation_dialog.dart';
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
  var _lifetime = 0;
  Completer<void>? _creationAbort;

  @override
  void didUpdateWidget(covariant NewConversationScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accountId != widget.accountId) {
      _lifetime++;
      _searchGeneration++;
      _debounce?.cancel();
      _searchController.clear();
      _state = const _SearchIdle();
      _creating = false;
      _cancelCreation();
    }
  }

  void _cancelCreation() {
    final abort = _creationAbort;
    if (abort != null && !abort.isCompleted) abort.complete();
    _creationAbort = null;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _cancelCreation();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _searchGeneration++;
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
    if (_creating) return;
    if (recipient.shareType == RecipientShareType.group) {
      await _openCreation(
        StandaloneConversationType.group,
        recipient: recipient,
      );
      return;
    }

    await _runCreation(
      (service) => service.createConversation(
        accountId: widget.accountId,
        recipient: recipient,
      ),
    );
  }

  Future<void> _createStandaloneConversation(
    StandaloneConversationType type,
  ) async {
    await _openCreation(type);
  }

  Future<void> _openCreation(
    StandaloneConversationType type, {
    ConversationRecipient? recipient,
  }) async {
    if (_creating) return;
    final accountId = widget.accountId;
    final lifetime = _lifetime;
    final abort = Completer<void>();
    _creationAbort = abort;
    bool current() =>
        mounted && _lifetime == lifetime && widget.accountId == accountId;
    final service = ref.read(newConversationServiceProvider);
    setState(() => _creating = true);
    try {
      final result = await showDialog<ConversationCreationResult>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ConversationCreationDialog(
          service: service,
          accountId: accountId,
          initialType: type,
          recipient: recipient,
          isCurrent: current,
          abortTrigger: abort.future,
        ),
      );
      if (!mounted || !current() || result == null) return;
      if (result.failedInvitationCount > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(
                context,
              ).newConversationPartialInvitations(result.failedInvitationCount),
            ),
          ),
        );
      }
      widget.onConversationCreated(result.roomToken);
    } finally {
      if (!abort.isCompleted) abort.complete();
      if (current()) {
        _creationAbort = null;
        setState(() => _creating = false);
      }
    }
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
    if (_creating) return;
    final lifetime = _lifetime;
    bool current() => mounted && lifetime == _lifetime;
    setState(() => _creating = true);
    final service = ref.read(newConversationServiceProvider);
    try {
      final token = await create(service);
      if (!mounted || !current()) {
        return;
      }
      widget.onConversationCreated(token);
    } on NewConversationException catch (error) {
      if (!mounted || !current()) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_errorMessage(error.code))));
    } finally {
      if (current()) {
        setState(() => _creating = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(strings.newConversationTitle)),
      // Capped like settings and the room details: a picker stretched across
      // a desktop window puts its label at one edge and its control at the
      // other. SafeArea keeps the list clear of the gesture bar.
      body: ContentColumn(
        child: SafeArea(
          child: Column(
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
        ),
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
    return creationErrorText(strings, error);
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
