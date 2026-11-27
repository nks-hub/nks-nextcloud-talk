import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/search/message_search_screen.dart';
import 'package:nextcloudtalk/features/search/message_search_service.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'accessibility_probe.dart' show expectEveryButtonNamed;
import 'test_support.dart';

MessageSearchResult _result({
  String author = 'Alice',
  String excerpt = 'Hello there',
  String roomToken = 'abcd1234',
  int messageId = 42,
  int? threadId,
}) => parseMessageSearchResult(<String, Object?>{
  'title': author,
  'subline': excerpt,
  'resourceUrl':
      'https://cloud.example.invalid/index.php/apps/spreed/?token=$roomToken',
  'attributes': <String, Object?>{
    'conversation': roomToken,
    'messageId': '$messageId',
    if (threadId != null) 'threadId': '$threadId',
  },
}, path: r'$');

final class _FakeMessageSearchService implements MessageSearchService {
  _FakeMessageSearchService(
    this._handler, {
    this.pageHandler,
    this.filterSupport = const {},
  });

  final FutureOr<List<MessageSearchResult>> Function(String term) _handler;
  final FutureOr<MessageSearchPage> Function(int? cursor)? pageHandler;
  final Set<MessageSearchFilter> filterSupport;
  final List<String> searchedTerms = [];
  final List<String?> searchedScopes = [];
  final List<Future<void>?> abortTriggers = [];
  final List<int?> cursors = [];
  final List<MessageSearchFilters> filtersUsed = [];

  @override
  Future<Set<MessageSearchFilter>> supportedFilters({
    required String accountId,
    String? roomToken,
    Future<void>? abortTrigger,
  }) async => filterSupport;

  @override
  Future<MessageSearchPage> search({
    required String accountId,
    required String term,
    String? roomToken,
    MessageSearchFilters filters = const MessageSearchFilters(),
    int limit = messageSearchDefaultLimit,
    int? cursor,
    Future<void>? abortTrigger,
  }) async {
    searchedTerms.add(term);
    searchedScopes.add(roomToken);
    abortTriggers.add(abortTrigger);
    cursors.add(cursor);
    filtersUsed.add(filters);
    final pages = pageHandler;
    if (pages != null) return pages(cursor);
    return (results: await _handler(term), nextCursor: null);
  }
}

void main() {
  Future<void> pumpScreen(
    WidgetTester tester,
    MessageSearchService service, {
    ValueChanged<MessageSearchResult>? onResultSelected,
    Future<List<ConversationRecipient>> Function(String)? searchPeople,
    String? roomToken,
    String? roomName,
  }) async {
    await tester.pumpWidget(
      localizedTestApp(
        home: MessageSearchScreen(
          accountId: 'account-a',
          service: service,
          onResultSelected: (selection) =>
              onResultSelected?.call(selection.result),
          searchPeople: searchPeople,
          roomToken: roomToken,
          roomName: roomName,
        ),
      ),
    );
  }

  testWidgets('a global search sends no room scope', (tester) async {
    final service = _FakeMessageSearchService((_) async => const []);
    await pumpScreen(tester, service);

    await tester.enterText(
      find.byKey(const Key('message-search-field')),
      'popisek',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(service.searchedScopes, [null]);
  });

  testWidgets('a conversation search carries its room token', (tester) async {
    // The two scopes are different providers on the server and answer the
    // opposite way when mixed, so the token has to reach the service exactly
    // when the caller asked for one conversation and never otherwise.
    final service = _FakeMessageSearchService((_) async => const []);
    await pumpScreen(
      tester,
      service,
      roomToken: 'abcd1234',
      roomName: 'Tym NKS',
    );

    expect(find.text('Search in Tym NKS'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('message-search-field')),
      'popisek',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(service.searchedScopes, ['abcd1234']);
  });

  testWidgets('shows the empty-query prompt before any typing', (tester) async {
    final service = _FakeMessageSearchService((_) async => const []);
    await pumpScreen(tester, service);

    expect(find.byKey(const Key('message-search-idle')), findsOneWidget);
    expect(service.searchedTerms, isEmpty);
  });

  testWidgets('a person and date range narrow the same search term', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final service = _FakeMessageSearchService(
      (_) => const [],
      filterSupport: MessageSearchFilter.values.toSet(),
    );
    final people = _recipientChoices();
    await pumpScreen(
      tester,
      service,
      searchPeople: (term) async {
        expect(term, 'Ali');
        return people;
      },
    );
    final query = find.byKey(const Key('message-search-field'));
    await tester.enterText(query, 'invoice');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('message-search-sender')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('message-search-person-field')),
      'Ali',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('Fixture group'), findsNothing);
    await tester.tap(find.text('Alice Example'));
    await tester.pumpAndSettle();
    expect(service.filtersUsed.last.person, 'fixture-alice');

    await tester.tap(find.byKey(const Key('message-search-period')));
    await tester.pumpAndSettle();
    final picker = find.byType(DateRangePickerDialog);
    final material = MaterialLocalizations.of(tester.element(picker));
    await tester.tap(find.byTooltip(material.inputDateModeButtonLabel));
    await tester.pumpAndSettle();
    final dates = find.descendant(of: picker, matching: find.byType(TextField));
    final start = DateTime(2026, 1, 5);
    final end = DateTime(2026, 1, 7);
    await tester.enterText(dates.first, material.formatCompactDate(start));
    await tester.enterText(dates.last, material.formatCompactDate(end));
    await tester.tap(find.text(material.okButtonLabel));
    await tester.pumpAndSettle();

    expect(service.searchedTerms, ['invoice', 'invoice', 'invoice']);
    expect(service.filtersUsed.last.person, 'fixture-alice');
    expect(service.filtersUsed.last.since, start);
    expect(
      service.filtersUsed.last.until,
      DateTime(2026, 1, 7, 23, 59, 59, 999),
    );
    expect(tester.widget<TextField>(query).controller!.text, 'invoice');
    expect(tester.takeException(), isNull);
  });

  testWidgets('retrying a failed page keeps the previous search hits', (
    tester,
  ) async {
    var nextPageRequests = 0;
    final service = _FakeMessageSearchService(
      (_) => const [],
      pageHandler: (cursor) {
        if (cursor == null) {
          return (
            results: [_result(excerpt: 'First search hit')],
            nextCursor: 20,
          );
        }
        if (++nextPageRequests == 1) {
          throw const MessageSearchException(MessageSearchError.network);
        }
        return (
          results: [_result(excerpt: 'Next search hit', messageId: 43)],
          nextCursor: null,
        );
      },
    );
    await pumpScreen(tester, service);
    await tester.enterText(
      find.byKey(const Key('message-search-field')),
      'hello',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    final more = find.byKey(const Key('message-search-load-more'));
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.text("Couldn't load more results."), findsOneWidget);
    expect(find.text('First search hit'), findsOneWidget);

    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.text('First search hit'), findsOneWidget);
    expect(find.text('Next search hit'), findsOneWidget);
    expect(service.cursors, [null, 20, 20]);
    expect(more, findsNothing);
  });

  testWidgets('the clear button says what it does', (tester) async {
    // It only exists once something is typed, which is why the screen-wide
    // audit never saw it: a screen reader used to announce it as "button".
    final semantics = tester.ensureSemantics();
    final service = _FakeMessageSearchService((_) async => const []);
    await pumpScreen(tester, service);

    await tester.enterText(
      find.byKey(const Key('message-search-field')),
      'popisek',
    );
    await tester.pump();

    expectEveryButtonNamed(tester, screen: 'message search');
    semantics.dispose();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  });

  testWidgets('shows a bounded spinner while searching', (tester) async {
    final completer = Completer<List<MessageSearchResult>>();
    final service = _FakeMessageSearchService((_) => completer.future);
    await pumpScreen(tester, service);

    await tester.enterText(
      find.byKey(const Key('message-search-field')),
      'hello',
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byKey(const Key('message-search-loading')), findsOneWidget);

    completer.complete([_result()]);
    await tester.pump();
    await tester.pump();
  });

  testWidgets('does not show an old result after the query changes', (
    tester,
  ) async {
    final firstSearch = Completer<List<MessageSearchResult>>();
    final service = _FakeMessageSearchService((term) {
      if (term == 'first') {
        return firstSearch.future;
      }
      return const <MessageSearchResult>[];
    });
    await pumpScreen(tester, service);

    await tester.enterText(
      find.byKey(const Key('message-search-field')),
      'first',
    );
    await tester.pump(const Duration(milliseconds: 400));

    await tester.enterText(
      find.byKey(const Key('message-search-field')),
      'second',
    );
    firstSearch.complete([_result(excerpt: 'Old result')]);
    await tester.pump();

    expect(find.text('Old result'), findsNothing);

    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(service.searchedTerms, ['first', 'second']);
  });

  testWidgets('a new query aborts the in-flight request before it starts', (
    tester,
  ) async {
    var active = 0;
    var maximumActive = 0;
    late final _FakeMessageSearchService service;
    service = _FakeMessageSearchService((term) {
      active++;
      if (active > maximumActive) {
        maximumActive = active;
      }
      final cancellation = service.abortTriggers.last!;
      if (term == 'first') {
        final result = Completer<List<MessageSearchResult>>();
        unawaited(
          cancellation.then((_) {
            active--;
            result.completeError(
              const MessageSearchException(MessageSearchError.network),
            );
          }),
        );
        return result.future;
      }
      active--;
      return const <MessageSearchResult>[];
    });
    await pumpScreen(tester, service);

    await tester.enterText(
      find.byKey(const Key('message-search-field')),
      'first',
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(active, 1);

    await tester.enterText(
      find.byKey(const Key('message-search-field')),
      'second',
    );
    await tester.pump();
    expect(active, 0);

    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(service.searchedTerms, ['first', 'second']);
    expect(maximumActive, 1);
  });

  testWidgets('closing the screen aborts its in-flight request', (
    tester,
  ) async {
    var active = 0;
    late final _FakeMessageSearchService service;
    service = _FakeMessageSearchService((_) {
      active++;
      final result = Completer<List<MessageSearchResult>>();
      unawaited(
        service.abortTriggers.last!.then((_) {
          active--;
          result.completeError(
            const MessageSearchException(MessageSearchError.network),
          );
        }),
      );
      return result.future;
    });
    await pumpScreen(tester, service);
    await tester.enterText(
      find.byKey(const Key('message-search-field')),
      'first',
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(active, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(active, 0);
  });

  testWidgets('shows results with author, excerpt and tap callback', (
    tester,
  ) async {
    final service = _FakeMessageSearchService(
      (_) async => [_result(threadId: 40)],
    );
    MessageSearchResult? tappedResult;
    await pumpScreen(
      tester,
      service,
      onResultSelected: (result) => tappedResult = result,
    );

    await tester.enterText(
      find.byKey(const Key('message-search-field')),
      'hello',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Hello there'), findsOneWidget);

    await tester.tap(find.text('Alice'));
    await tester.pump();

    expect(tappedResult?.roomToken.value, 'abcd1234');
    expect(tappedResult?.messageId, 42);
    expect(tappedResult?.threadId, 40);
  });

  testWidgets('shows the no-results state for an empty result list', (
    tester,
  ) async {
    final service = _FakeMessageSearchService((_) async => const []);
    await pumpScreen(tester, service);

    await tester.enterText(
      find.byKey(const Key('message-search-field')),
      'nothing',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(find.byKey(const Key('message-search-no-results')), findsOneWidget);
  });

  testWidgets('shows an error state when the search fails', (tester) async {
    final service = _FakeMessageSearchService(
      (_) => throw const MessageSearchException(MessageSearchError.network),
    );
    await pumpScreen(tester, service);

    await tester.enterText(
      find.byKey(const Key('message-search-field')),
      'hello',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(find.byKey(const Key('message-search-error')), findsOneWidget);
  });

  // A shared "Search failed" line for every cause hid a broken response
  // decoder behind what looked like a network problem.
  testWidgets('names the cause of the failure instead of one generic line', (
    tester,
  ) async {
    const cases = <MessageSearchError, String>{
      MessageSearchError.accountMissing: 'This account is no longer available.',
      MessageSearchError.credentialMissing: 'Sign in again to search messages.',
      MessageSearchError.invalidSearchTerm: 'Enter a search term.',
      MessageSearchError.reauthenticationRequired:
          'Your session expired. Sign in again.',
      MessageSearchError.providerNotFound:
          'This server does not offer message search.',
      MessageSearchError.transientError:
          'The server is busy. Try again in a moment.',
      MessageSearchError.ocsFailure: 'The server rejected the search.',
      MessageSearchError.network: 'Could not reach the server.',
      MessageSearchError.invalidResponse:
          'The server sent a search response this app could not read.',
    };

    expect(cases.keys, unorderedEquals(MessageSearchError.values));
    expect(cases.values.toSet(), hasLength(MessageSearchError.values.length));

    for (final entry in cases.entries) {
      final service = _FakeMessageSearchService(
        (_) => throw MessageSearchException(entry.key),
      );
      await pumpScreen(tester, service);

      await tester.enterText(
        find.byKey(const Key('message-search-field')),
        'hello',
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(
        find.text(entry.value),
        findsOneWidget,
        reason: '${entry.key} must be distinguishable on screen',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets('clearing the query returns to the idle state', (tester) async {
    final service = _FakeMessageSearchService((_) async => [_result()]);
    await pumpScreen(tester, service);

    await tester.enterText(
      find.byKey(const Key('message-search-field')),
      'hello',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.text('Alice'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('message-search-field')), '');
    await tester.pump();

    expect(find.byKey(const Key('message-search-idle')), findsOneWidget);
  });
}

List<ConversationRecipient> _recipientChoices() {
  final result = decodeRecipientSearchResponse(
    request: RecipientSearchRequest(
      accountId: AccountId.parse('account-a'),
      server: ServerBase.parse('https://cloud.example.invalid'),
      searchTerm: 'Ali',
    ),
    statusCode: 200,
    json: {
      'ocs': {
        'meta': {'status': 'ok', 'statuscode': 200},
        'data': [
          {'id': 'fixture-alice', 'label': 'Alice Example', 'source': 'users'},
          {'id': 'fixture-group', 'label': 'Fixture group', 'source': 'groups'},
        ],
      },
    },
  );
  return (result as RecipientSearchSuccess).recipients;
}
