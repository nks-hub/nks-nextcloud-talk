import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/composer/mention_suggestions.dart';
import 'package:talk_protocol/talk_protocol.dart';

void main() {
  group('extractMentionQuery', () {
    test('finds no mention without an @ token', () {
      expect(extractMentionQuery('hello world', 11), isNull);
    });

    test('matches an empty query right after a leading @', () {
      final match = extractMentionQuery('@', 1);
      expect(match, const MentionQueryMatch(start: 0, end: 1, query: ''));
    });

    test('collects the query typed after @', () {
      final match = extractMentionQuery('hi @ali', 7);
      expect(match, const MentionQueryMatch(start: 3, end: 7, query: 'ali'));
    });

    test('requires the @ to start the text or follow whitespace', () {
      expect(extractMentionQuery('foo@bar', 7), isNull);
      expect(extractMentionQuery('(@bar', 5), isNull);
    });

    test('a finished token (space after it) is no longer active', () {
      expect(extractMentionQuery('hi @ali ', 8), isNull);
    });

    test('matches up to the caret even mid-string', () {
      final match = extractMentionQuery('hi @ali there', 6);
      expect(match, const MentionQueryMatch(start: 3, end: 6, query: 'al'));
    });

    test('caret outside the text bounds is rejected', () {
      expect(extractMentionQuery('hi', -1), isNull);
      expect(extractMentionQuery('hi', 99), isNull);
    });
  });

  group('mentionSuggestionMarkup', () {
    test('plain ids are not quoted', () {
      expect(mentionSuggestionMarkup(_suggestion(mentionId: 'alice')), '@alice');
    });

    test('ids with a space are quoted', () {
      expect(
        mentionSuggestionMarkup(_suggestion(mentionId: 'guest name')),
        '@"guest name"',
      );
    });

    test('guest ids with a slash are quoted', () {
      expect(
        mentionSuggestionMarkup(_suggestion(mentionId: 'guest/abc123')),
        '@"guest/abc123"',
      );
    });
  });

  group('insertMentionSuggestion', () {
    test('splices the mention markup and a trailing space at the caret', () {
      final controller = TextEditingController(text: 'hi @al')
        ..selection = const TextSelection.collapsed(offset: 6);

      final inserted = insertMentionSuggestion(
        controller,
        _suggestion(mentionId: 'alice', label: 'Alice'),
      );

      expect(inserted, isTrue);
      expect(controller.text, 'hi @alice ');
      expect(controller.selection, const TextSelection.collapsed(offset: 10));
    });

    test('is a no-op when the caret left the mention token', () {
      final controller = TextEditingController(text: 'hi @al done')
        ..selection = const TextSelection.collapsed(offset: 11);

      final inserted = insertMentionSuggestion(
        controller,
        _suggestion(mentionId: 'alice'),
      );

      expect(inserted, isFalse);
      expect(controller.text, 'hi @al done');
    });
  });

  group('MentionSuggestionsBar', () {
    const labels = MentionSuggestionsLabels(
      noResults: 'No matches',
      error: "Couldn't load suggestions",
    );

    Future<void> pumpComposer(
      WidgetTester tester, {
      required TextEditingController controller,
      required MentionSuggestionSource? source,
      bool enabled = true,
    }) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                MentionSuggestionsBar(
                  controller: controller,
                  source: source,
                  enabled: enabled,
                  labels: labels,
                ),
                TextField(controller: controller),
              ],
            ),
          ),
        ),
      );
    }

    testWidgets('shows suggestions once the debounced search resolves', (
      tester,
    ) async {
      final controller = TextEditingController();
      final source = _FakeMentionSource((query) async => <RichChatMentionSuggestion>[
        _suggestion(mentionId: 'alice', label: 'Alice', details: 'alice@talk'),
        _suggestion(mentionId: 'bob', label: 'Bob'),
      ]);
      addTearDown(controller.dispose);

      await pumpComposer(tester, controller: controller, source: source);
      await tester.enterText(find.byType(TextField), '@');
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(const Key('mention-suggestions-list')), findsOneWidget);
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Bob'), findsOneWidget);
      expect(source.queries, ['']);
    });

    testWidgets('filters again as the query keeps changing', (tester) async {
      final controller = TextEditingController();
      final source = _FakeMentionSource((query) async {
        const all = ['Alice', 'Alina', 'Bob'];
        return all
            .where((name) => name.toLowerCase().startsWith(query.toLowerCase()))
            .map((name) => _suggestion(mentionId: name.toLowerCase(), label: name))
            .toList();
      });
      addTearDown(controller.dispose);

      await pumpComposer(tester, controller: controller, source: source);
      await tester.enterText(find.byType(TextField), '@a');
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Alina'), findsOneWidget);
      expect(find.text('Bob'), findsNothing);

      await tester.enterText(find.byType(TextField), '@al');
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Alina'), findsOneWidget);
      expect(source.queries, ['a', 'al']);
    });

    testWidgets('tapping a suggestion inserts it and closes the list', (
      tester,
    ) async {
      final controller = TextEditingController();
      final source = _FakeMentionSource(
        (query) async => <RichChatMentionSuggestion>[
          _suggestion(mentionId: 'alice', label: 'Alice'),
        ],
      );
      addTearDown(controller.dispose);

      await pumpComposer(tester, controller: controller, source: source);
      await tester.enterText(find.byType(TextField), '@al');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('mention-suggestion-alice')), findsOneWidget);

      await tester.tap(find.byKey(const Key('mention-suggestion-alice')));
      await tester.pump();

      expect(controller.text, '@alice ');
      expect(find.byKey(const Key('mention-suggestions-list')), findsNothing);
    });

    testWidgets('closes once the mention token is abandoned', (tester) async {
      final controller = TextEditingController();
      final source = _FakeMentionSource(
        (query) async => <RichChatMentionSuggestion>[
          _suggestion(mentionId: 'alice', label: 'Alice'),
        ],
      );
      addTearDown(controller.dispose);

      await pumpComposer(tester, controller: controller, source: source);
      await tester.enterText(find.byType(TextField), '@al');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('mention-suggestions-list')), findsOneWidget);

      await tester.enterText(find.byType(TextField), '@al ');
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(const Key('mention-suggestions-list')), findsNothing);
      expect(find.text('Alice'), findsNothing);
    });

    testWidgets('shows a localized error row when the search fails', (
      tester,
    ) async {
      final controller = TextEditingController();
      final source = _FakeMentionSource(
        (query) async => throw const MentionSuggestionException(
          MentionSuggestionError.network,
        ),
      );
      addTearDown(controller.dispose);

      await pumpComposer(tester, controller: controller, source: source);
      await tester.enterText(find.byType(TextField), '@al');
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text("Couldn't load suggestions"), findsOneWidget);
      expect(find.byKey(const Key('mention-suggestions-list')), findsNothing);
    });

    testWidgets('shows the empty-results message with no matches', (
      tester,
    ) async {
      final controller = TextEditingController();
      final source = _FakeMentionSource((query) async => const <RichChatMentionSuggestion>[]);
      addTearDown(controller.dispose);

      await pumpComposer(tester, controller: controller, source: source);
      await tester.enterText(find.byType(TextField), '@zz');
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('No matches'), findsOneWidget);
    });

    testWidgets('never shows suggestions while disabled', (tester) async {
      final controller = TextEditingController();
      final source = _FakeMentionSource(
        (query) async => <RichChatMentionSuggestion>[
          _suggestion(mentionId: 'alice', label: 'Alice'),
        ],
      );
      addTearDown(controller.dispose);

      await pumpComposer(
        tester,
        controller: controller,
        source: source,
        enabled: false,
      );
      await tester.enterText(find.byType(TextField), '@al');
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(const Key('mention-suggestions-list')), findsNothing);
      expect(source.queries, isEmpty);
    });

    testWidgets('does nothing without a resolved suggestion source', (
      tester,
    ) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      await pumpComposer(tester, controller: controller, source: null);
      await tester.enterText(find.byType(TextField), '@al');
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(const Key('mention-suggestions-list')), findsNothing);
    });
  });
}

final class _FakeMentionSource implements MentionSuggestionSource {
  _FakeMentionSource(this._responder);

  final Future<List<RichChatMentionSuggestion>> Function(String query)
  _responder;
  final List<String> queries = <String>[];

  @override
  Future<List<RichChatMentionSuggestion>> search({
    required String query,
    Future<void>? abortTrigger,
  }) {
    queries.add(query);
    return _responder(query);
  }
}

RichChatMentionSuggestion _suggestion({
  required String mentionId,
  String? label,
  String source = 'users',
  String? details,
}) => RichChatMentionSuggestion.fromJson(<String, Object?>{
  'id': mentionId,
  'label': label ?? mentionId,
  'source': source,
  'mentionId': mentionId,
  'details': ?details,
});
