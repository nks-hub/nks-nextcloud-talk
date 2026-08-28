import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/search/message_search_screen.dart';
import 'package:nextcloudtalk/features/search/message_search_service.dart';
import 'package:talk_protocol/talk_protocol.dart';

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
  _FakeMessageSearchService(this._handler);

  final FutureOr<List<MessageSearchResult>> Function(String term) _handler;
  final List<String> searchedTerms = [];

  @override
  Future<List<MessageSearchResult>> search({
    required String accountId,
    required String term,
    String? roomToken,
    int limit = messageSearchDefaultLimit,
  }) async {
    searchedTerms.add(term);
    return _handler(term);
  }
}

void main() {
  Future<void> pumpScreen(
    WidgetTester tester,
    MessageSearchService service, {
    ValueChanged<MessageSearchResult>? onResultSelected,
  }) async {
    await tester.pumpWidget(
      localizedTestApp(
        home: MessageSearchScreen(
          accountId: 'account-a',
          service: service,
          onResultSelected: onResultSelected ?? (_) {},
        ),
      ),
    );
  }

  testWidgets('shows the empty-query prompt before any typing', (tester) async {
    final service = _FakeMessageSearchService((_) async => const []);
    await pumpScreen(tester, service);

    expect(find.byKey(const Key('message-search-idle')), findsOneWidget);
    expect(service.searchedTerms, isEmpty);
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
