import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/composer/giphy.dart';

void main() {
  group('Giphy live search', () {
    testWidgets('a fast typist makes one request, not one per keystroke', (
      tester,
    ) async {
      final repository = _CountingGiphyRepository();
      final controller = GiphyController(
        repository: repository,
        searchDebounce: const Duration(milliseconds: 300),
      );
      addTearDown(controller.dispose);

      for (final term in const ['c', 'ca', 'cat']) {
        controller.searchAsTyped(term);
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(repository.searchTerms, isEmpty);

      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(repository.searchTerms, <String>['cat']);
      expect(controller.term, 'cat');
    });

    testWidgets('clearing the field goes back to trending', (tester) async {
      final repository = _CountingGiphyRepository();
      final controller = GiphyController(
        repository: repository,
        searchDebounce: const Duration(milliseconds: 300),
      );
      addTearDown(controller.dispose);

      controller.searchAsTyped('cat');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(repository.searchTerms, <String>['cat']);
      expect(repository.trendingCalls, 0);

      controller.searchAsTyped('   ');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(repository.searchTerms, <String>['cat']);
      expect(repository.trendingCalls, 1);
      expect(controller.term, isNull);
    });

    testWidgets('an unchanged term does not repeat the request', (
      tester,
    ) async {
      final repository = _CountingGiphyRepository();
      final controller = GiphyController(
        repository: repository,
        searchDebounce: const Duration(milliseconds: 300),
      );
      addTearDown(controller.dispose);

      controller.searchAsTyped('cat');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      controller.searchAsTyped('cat ');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(repository.searchTerms, <String>['cat']);
    });

    testWidgets('disposing cancels a keystroke that has not fired yet', (
      tester,
    ) async {
      final repository = _CountingGiphyRepository();
      final controller = GiphyController(
        repository: repository,
        searchDebounce: const Duration(milliseconds: 300),
      );

      controller.searchAsTyped('cat');
      await tester.pump(const Duration(milliseconds: 100));
      controller.dispose();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(repository.searchTerms, isEmpty);
      expect(repository.trendingCalls, 0);
    });
  });
}

final class _CountingGiphyRepository implements GiphyRepository {
  final List<String> searchTerms = <String>[];
  int trendingCalls = 0;

  @override
  Future<GiphyAttributionAsset> loadAttributionAsset({
    Future<void>? abortTrigger,
  }) => Future<GiphyAttributionAsset>.error(
    const GiphyException(GiphyError.network),
  );

  @override
  Future<GiphyPage> search({
    required String term,
    required int cursor,
    required int limit,
    Future<void>? abortTrigger,
  }) async {
    searchTerms.add(term);
    return GiphyPage(entries: const <GiphyEntry>[], cursor: 0);
  }

  @override
  Future<GiphyPage> trending({
    required int cursor,
    required int limit,
    Future<void>? abortTrigger,
  }) async {
    trendingCalls++;
    return GiphyPage(entries: const <GiphyEntry>[], cursor: 0);
  }
}
