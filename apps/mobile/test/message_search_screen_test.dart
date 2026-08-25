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
}) => parseMessageSearchResult(<String, Object?>{
  'title': author,
  'subline': excerpt,
  'resourceUrl':
      'https://cloud.example.invalid/index.php/apps/spreed/?token=$roomToken',
  'attributes': <String, Object?>{
    'conversation': roomToken,
    'messageId': '$messageId',
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
    void Function(ConversationToken roomToken, int messageId)?
    onResultSelected,
  }) async {
    await tester.pumpWidget(
      localizedTestApp(
        home: MessageSearchScreen(
          accountId: 'account-a',
          service: service,
          onResultSelected: onResultSelected ?? (_, _) {},
        ),
      ),
    );
  }

  testWidgets('shows the empty-query prompt before any typing', (
    tester,
  ) async {
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
    final service = _FakeMessageSearchService((_) async => [_result()]);
    ConversationToken? tappedToken;
    int? tappedMessageId;
    await pumpScreen(
      tester,
      service,
      onResultSelected: (roomToken, messageId) {
        tappedToken = roomToken;
        tappedMessageId = messageId;
      },
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

    expect(tappedToken?.value, 'abcd1234');
    expect(tappedMessageId, 42);
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
