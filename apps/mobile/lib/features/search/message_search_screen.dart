import 'dart:async';

import 'package:flutter/material.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../l10n/generated/app_localizations.dart';
import 'message_search_service.dart';

const Duration _searchDebounce = Duration(milliseconds: 400);

enum _MessageSearchViewState { idle, searching, error, results }

/// Full-screen message search. Tapping a result hands the complete validated
/// result to [onResultSelected] and leaves navigation to the caller.
final class MessageSearchScreen extends StatefulWidget {
  const MessageSearchScreen({
    super.key,
    required this.accountId,
    required this.service,
    required this.onResultSelected,
    this.roomToken,
    this.roomName,
  });

  final String accountId;
  final MessageSearchService service;
  final ValueChanged<MessageSearchResult> onResultSelected;

  /// Restricts the search to one conversation. Null searches all of them.
  ///
  /// The two scopes are different providers on the server and must not be
  /// mixed — see `MessageSearchRequest._fromRoute`. Passing the token here is
  /// the only thing the caller has to do; the service picks the provider.
  final String? roomToken;

  /// Shown in the title so it is obvious the search is not global.
  final String? roomName;

  @override
  State<MessageSearchScreen> createState() => _MessageSearchScreenState();
}

class _MessageSearchScreenState extends State<MessageSearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  int _generation = 0;
  _MessageSearchViewState _viewState = _MessageSearchViewState.idle;
  MessageSearchError? _error;
  List<MessageSearchResult> _results = const [];

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    final term = value.trim();
    if (term.isEmpty) {
      _generation++;
      setState(() {
        _viewState = _MessageSearchViewState.idle;
        _results = const [];
      });
      return;
    }
    _debounce = Timer(_searchDebounce, () => _runSearch(term));
  }

  Future<void> _runSearch(String term) async {
    final generation = ++_generation;
    setState(() {
      _error = null;
      _viewState = _MessageSearchViewState.searching;
    });
    try {
      final results = await widget.service.search(
        accountId: widget.accountId,
        term: term,
        roomToken: widget.roomToken,
      );
      if (!mounted || generation != _generation) {
        return;
      }
      setState(() {
        _results = results;
        _viewState = _MessageSearchViewState.results;
      });
    } on MessageSearchException catch (failure) {
      if (!mounted || generation != _generation) {
        return;
      }
      setState(() {
        _error = failure.code;
        _viewState = _MessageSearchViewState.error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.roomName == null
              ? strings.searchMessagesTitle
              : strings.searchMessagesInConversation(widget.roomName!),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              key: const Key('message-search-field'),
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: _onQueryChanged,
              decoration: InputDecoration(
                hintText: strings.searchMessagesHint,
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                suffixIcon: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _controller,
                  builder: (context, value, _) {
                    if (value.text.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    return IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _controller.clear();
                        _onQueryChanged('');
                      },
                    );
                  },
                ),
              ),
            ),
          ),
          Expanded(child: _buildBody(context, strings)),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations strings) {
    switch (_viewState) {
      case _MessageSearchViewState.idle:
        return Center(
          key: const Key('message-search-idle'),
          child: Text(strings.searchMessagesPrompt),
        );
      case _MessageSearchViewState.searching:
        return const Center(
          key: Key('message-search-loading'),
          child: CircularProgressIndicator(),
        );
      case _MessageSearchViewState.error:
        return Center(
          key: const Key('message-search-error'),
          child: Text(_errorMessage(strings, _error)),
        );
      case _MessageSearchViewState.results:
        if (_results.isEmpty) {
          return Center(
            key: const Key('message-search-no-results'),
            child: Text(strings.searchMessagesNoResults),
          );
        }
        return ListView.builder(
          key: const Key('message-search-results'),
          itemCount: _results.length,
          itemBuilder: (context, index) {
            final result = _results[index];
            return _MessageSearchResultTile(
              result: result,
              onTap: () => widget.onResultSelected(result),
            );
          },
        );
    }
  }
}

class _MessageSearchResultTile extends StatelessWidget {
  const _MessageSearchResultTile({required this.result, required this.onTap});

  final MessageSearchResult result;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final timestamp = result.timestamp;
    return ListTile(
      onTap: onTap,
      title: Text(result.author, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        result.excerpt,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: timestamp == null
          ? null
          : Text(
              MaterialLocalizations.of(
                context,
              ).formatTimeOfDay(TimeOfDay.fromDateTime(timestamp.toLocal())),
              style: Theme.of(context).textTheme.labelSmall,
            ),
    );
  }
}

/// A single "Search failed" line hid which of nine failures happened, which
/// is how a broken response decoder went unnoticed while the server was
/// answering correctly. Each cause now names itself.
String _errorMessage(AppLocalizations strings, MessageSearchError? error) {
  return switch (error) {
    MessageSearchError.accountMissing =>
      strings.searchMessagesErrorAccountMissing,
    MessageSearchError.credentialMissing =>
      strings.searchMessagesErrorCredentialMissing,
    MessageSearchError.reauthenticationRequired =>
      strings.searchMessagesErrorReauthentication,
    MessageSearchError.providerNotFound =>
      strings.searchMessagesErrorProviderMissing,
    MessageSearchError.transientError => strings.searchMessagesErrorTransient,
    MessageSearchError.ocsFailure => strings.searchMessagesErrorServer,
    MessageSearchError.invalidResponse =>
      strings.searchMessagesErrorInvalidResponse,
    MessageSearchError.network => strings.searchMessagesErrorNetwork,
    MessageSearchError.invalidSearchTerm =>
      strings.newConversationErrorInvalidSearchTerm,
    null => strings.searchMessagesError,
  };
}
