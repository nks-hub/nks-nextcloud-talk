import 'dart:async';

import 'package:flutter/material.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../core/desktop_metrics.dart';
import '../../l10n/generated/app_localizations.dart';
import 'message_search_service.dart';

const Duration _searchDebounce = Duration(milliseconds: 400);

enum _MessageSearchViewState { idle, searching, error, results }

final class MessageSearchSelection {
  const MessageSearchSelection({
    required this.index,
    required this.result,
    required this.canOpen,
    required this.load,
  });

  final int index;
  final MessageSearchResult result;
  final bool Function(int index) canOpen;
  final Future<MessageSearchResult?> Function(int index) load;
}

final class MessageSearchScreen extends StatefulWidget {
  const MessageSearchScreen({
    super.key,
    required this.accountId,
    required this.service,
    required this.onResultSelected,
    this.searchPeople,
    this.roomToken,
    this.roomName,
  });

  final String accountId;
  final MessageSearchService service;
  final ValueChanged<MessageSearchSelection> onResultSelected;
  final Future<List<ConversationRecipient>> Function(String)? searchPeople;
  final String? roomToken;
  final String? roomName;

  @override
  State<MessageSearchScreen> createState() => _MessageSearchScreenState();
}

class _MessageSearchScreenState extends State<MessageSearchScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _filterCancellation = Completer<void>();
  late final Future<Set<MessageSearchFilter>> _supportedFilters;
  Timer? _debounce;
  Completer<void>? _activeSearchCancellation;
  int _generation = 0;
  _MessageSearchViewState _viewState = _MessageSearchViewState.idle;
  MessageSearchError? _error;
  MessageSearchError? _pageError;
  List<MessageSearchResult> _results = const [];
  int? _nextCursor;
  Future<bool>? _paging;
  ConversationRecipient? _person;
  DateTimeRange? _period;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _supportedFilters = widget.service.supportedFilters(
      accountId: widget.accountId,
      roomToken: widget.roomToken,
      abortTrigger: _filterCancellation.future,
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _cancelActiveSearch();
    _filterCancellation.complete();
    _scrollController.dispose();
    _controller.dispose();
    super.dispose();
  }

  MessageSearchFilters get _filters {
    final period = _period;
    return MessageSearchFilters(
      person: _person?.id,
      since: period?.start,
      until: period == null
          ? null
          : DateTime(
              period.end.year,
              period.end.month,
              period.end.day + 1,
            ).subtract(const Duration(milliseconds: 1)),
    );
  }

  void _onQueryChanged(String value, {bool immediate = false}) {
    _debounce?.cancel();
    _cancelActiveSearch();
    final generation = ++_generation;
    final term = value.trim();
    final idle = term.isEmpty && _filters.isEmpty;
    setState(() {
      _viewState = idle
          ? _MessageSearchViewState.idle
          : _MessageSearchViewState.searching;
      _results = const [];
      _nextCursor = null;
      _paging = null;
      _pageError = null;
    });
    if (idle) return;
    if (immediate) {
      unawaited(_runSearch(term, generation));
    } else {
      _debounce = Timer(_searchDebounce, () => _runSearch(term, generation));
    }
  }

  Future<bool> _runSearch(String term, int generation, {int? cursor}) async {
    final cancellation = Completer<void>();
    _activeSearchCancellation = cancellation;
    try {
      final page = await widget.service.search(
        accountId: widget.accountId,
        term: term,
        roomToken: widget.roomToken,
        filters: _filters,
        cursor: cursor,
        abortTrigger: cancellation.future,
      );
      if (!mounted || generation != _generation) return false;
      setState(() {
        if (cursor == null) {
          _results = page.results;
        } else {
          final seen = {
            for (final result in _results) (result.roomToken, result.messageId),
          };
          _results = [
            ..._results,
            for (final result in page.results)
              if (seen.add((result.roomToken, result.messageId))) result,
          ];
        }
        final next = page.nextCursor;
        _nextCursor = next != null && next > (cursor ?? 0) ? next : null;
        _viewState = _MessageSearchViewState.results;
      });
      return true;
    } on MessageSearchException catch (failure) {
      if (!mounted || generation != _generation) return false;
      setState(() {
        if (cursor == null) {
          _error = failure.code;
          _viewState = _MessageSearchViewState.error;
        } else {
          _pageError = failure.code;
        }
      });
      return false;
    } finally {
      if (identical(_activeSearchCancellation, cancellation)) {
        _activeSearchCancellation = null;
      }
    }
  }

  void _cancelActiveSearch() {
    final cancellation = _activeSearchCancellation;
    _activeSearchCancellation = null;
    cancellation?.complete();
  }

  void _onScroll() {
    if (_scrollController.position.extentAfter < 120 && _pageError == null) {
      unawaited(_loadMore());
    }
  }

  Future<bool> _loadMore() {
    final loading = _paging;
    final cursor = _nextCursor;
    if (loading != null) return loading;
    if (cursor == null) return Future.value(false);

    late final Future<bool> paging;
    paging = _runSearch(_controller.text.trim(), _generation, cursor: cursor)
        .whenComplete(() {
          if (mounted && identical(_paging, paging)) {
            setState(() => _paging = null);
          }
        });
    setState(() {
      _pageError = null;
      _paging = paging;
    });
    return paging;
  }

  void _selectMatch(int index) {
    final generation = _generation;
    bool canOpen(int target) =>
        mounted &&
        generation == _generation &&
        target >= 0 &&
        (target < _results.length || _nextCursor != null);

    widget.onResultSelected(
      MessageSearchSelection(
        index: index,
        result: _results[index],
        canOpen: canOpen,
        load: (target) async {
          if (!canOpen(target)) return null;
          if (target >= _results.length && !await _loadMore()) {
            if (mounted && generation == _generation && _pageError != null) {
              throw MessageSearchException(_pageError!);
            }
            return null;
          }
          if (!mounted || generation != _generation) return null;
          return target < _results.length ? _results[target] : null;
        },
      ),
    );
  }

  Future<void> _choosePerson() async {
    final searchPeople = widget.searchPeople;
    if (searchPeople == null) return;
    final person = await showDialog<ConversationRecipient>(
      context: context,
      builder: (context) => _SearchPersonDialog(search: searchPeople),
    );
    if (!mounted || person == null) return;
    _person = person;
    _onQueryChanged(_controller.text, immediate: true);
  }

  Future<void> _choosePeriod() async {
    final period = await showDateRangePicker(
      context: context,
      firstDate: DateTime(1970),
      lastDate: DateTime.now(),
      initialDateRange: _period,
      builder: (context, child) => DatePickerTheme(
        data: DatePickerTheme.of(context).copyWith(
          rangePickerHeaderHeadlineStyle: Theme.of(
            context,
          ).textTheme.titleMedium,
        ),
        child: child!,
      ),
    );
    if (!mounted || period == null) return;
    _period = period;
    _onQueryChanged(_controller.text, immediate: true);
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
      body: ContentColumn(
        child: SafeArea(
          child: CustomScrollView(
            controller: _scrollController,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
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
                            tooltip: strings.searchMessagesClear,
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
              ),
              SliverToBoxAdapter(
                child: FutureBuilder<Set<MessageSearchFilter>>(
                  future: _supportedFilters,
                  builder: (context, snapshot) => _buildFilters(
                    context,
                    strings,
                    snapshot.data ?? const {},
                  ),
                ),
              ),
              _buildBody(strings),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFilters(
    BuildContext context,
    AppLocalizations strings,
    Set<MessageSearchFilter> filters,
  ) {
    final person =
        widget.searchPeople != null &&
        filters.contains(MessageSearchFilter.person);
    final date = filters.containsAll({
      MessageSearchFilter.since,
      MessageSearchFilter.until,
    });
    if (!person && !date) return const SizedBox.shrink();
    final material = MaterialLocalizations.of(context);
    final period = _period;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            if (person)
              InputChip(
                key: const Key('message-search-sender'),
                avatar: const Icon(Icons.person_outline_rounded),
                label: Text(
                  _person?.label ?? strings.searchMessagesSender,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                selected: _person != null,
                onPressed: _choosePerson,
                onDeleted: _person == null
                    ? null
                    : () {
                        _person = null;
                        _onQueryChanged(_controller.text, immediate: true);
                      },
              ),
            if (date)
              InputChip(
                key: const Key('message-search-period'),
                avatar: const Icon(Icons.calendar_today_outlined),
                label: Text(
                  period == null
                      ? strings.searchMessagesPeriod
                      : '${material.formatCompactDate(period.start)} – '
                            '${material.formatCompactDate(period.end)}',
                ),
                selected: period != null,
                onPressed: _choosePeriod,
                onDeleted: period == null
                    ? null
                    : () {
                        _period = null;
                        _onQueryChanged(_controller.text, immediate: true);
                      },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(AppLocalizations strings) {
    if (_viewState == _MessageSearchViewState.results &&
        (_results.isNotEmpty || _nextCursor != null)) {
      return SliverList.builder(
        key: const Key('message-search-results'),
        itemCount: _results.length + (_nextCursor == null ? 0 : 1),
        itemBuilder: (context, index) {
          if (index == _results.length) return _buildMore(strings);
          return _MessageSearchResultTile(
            result: _results[index],
            onTap: () => _selectMatch(index),
          );
        },
      );
    }
    return SliverFillRemaining(
      hasScrollBody: false,
      child: Center(
        child: switch (_viewState) {
          _MessageSearchViewState.idle => Text(
            strings.searchMessagesPrompt,
            key: const Key('message-search-idle'),
          ),
          _MessageSearchViewState.searching => const CircularProgressIndicator(
            key: Key('message-search-loading'),
          ),
          _MessageSearchViewState.error => Text(
            _errorMessage(strings, _error),
            key: const Key('message-search-error'),
          ),
          _MessageSearchViewState.results => Text(
            strings.searchMessagesNoResults,
            key: const Key('message-search-no-results'),
          ),
        },
      ),
    );
  }

  Widget _buildMore(AppLocalizations strings) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
    child: Column(
      children: [
        if (_pageError != null)
          Text(
            strings.searchMessagesLoadMoreError,
            textAlign: TextAlign.center,
          ),
        if (_paging != null)
          const CircularProgressIndicator()
        else
          TextButton(
            key: const Key('message-search-load-more'),
            onPressed: _loadMore,
            child: Text(
              _pageError == null
                  ? strings.searchMessagesLoadMore
                  : strings.retry,
            ),
          ),
      ],
    ),
  );
}

final class _SearchPersonDialog extends StatefulWidget {
  const _SearchPersonDialog({required this.search});

  final Future<List<ConversationRecipient>> Function(String) search;

  @override
  State<_SearchPersonDialog> createState() => _SearchPersonDialogState();
}

final class _SearchPersonDialogState extends State<_SearchPersonDialog> {
  Timer? _debounce;
  Future<List<ConversationRecipient>>? _people;

  void _onChanged(String input) {
    _debounce?.cancel();
    final term = input.trim();
    setState(() => _people = null);
    if (term.isNotEmpty) {
      _debounce = Timer(_searchDebounce, () {
        final people = widget.search(term);
        setState(() {
          _people = people;
        });
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return AlertDialog(
      scrollable: true,
      title: Text(strings.searchMessagesSender),
      content: SizedBox(
        width: 360,
        height: 220,
        child: Column(
          children: [
            TextField(
              key: const Key('message-search-person-field'),
              autofocus: true,
              onChanged: _onChanged,
              decoration: InputDecoration(
                hintText: strings.searchMessagesFindPerson,
                border: const OutlineInputBorder(),
              ),
            ),
            Expanded(
              child: FutureBuilder<List<ConversationRecipient>>(
                future: _people,
                builder: (context, snapshot) {
                  if (_people == null) return const SizedBox.shrink();
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return Center(child: Text(strings.searchMessagesError));
                  }
                  final people =
                      (snapshot.data ?? const <ConversationRecipient>[])
                          .where(
                            (entry) =>
                                entry.shareType == RecipientShareType.user,
                          )
                          .toList(growable: false);
                  if (people.isEmpty) {
                    return Center(
                      child: Text(strings.roomDetailsAddParticipantEmpty),
                    );
                  }
                  return ListView.builder(
                    itemCount: people.length,
                    itemBuilder: (context, index) {
                      final person = people[index];
                      return ListTile(
                        title: Text(person.label),
                        subtitle: person.subline == null
                            ? null
                            : Text(person.subline!),
                        onTap: () => Navigator.of(context).pop(person),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
      ],
    );
  }
}

class _MessageSearchResultTile extends StatelessWidget {
  const _MessageSearchResultTile({required this.result, required this.onTap});

  final MessageSearchResult result;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final timestamp = result.timestamp?.toLocal();
    final localizations = MaterialLocalizations.of(context);
    final olderThanToday =
        timestamp != null &&
        DateUtils.dateOnly(
          timestamp,
        ).isBefore(DateUtils.dateOnly(DateTime.now()));
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
              [
                if (olderThanToday) localizations.formatCompactDate(timestamp),
                localizations.formatTimeOfDay(
                  TimeOfDay.fromDateTime(timestamp),
                ),
              ].join('\n'),
              textAlign: TextAlign.end,
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
