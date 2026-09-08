import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/chat_scroll_controller.dart';

Future<
  ({
    ChatScrollController controller,
    ValueNotifier<List<double>> rows,
    ValueNotifier<List<double>> newer,
    ValueNotifier<Size> viewport,
  })
>
_history(
  WidgetTester tester, {
  double offset = 500,
  bool responsive = false,
}) async {
  final controller = ChatScrollController();
  final rows = ValueNotifier(List<double>.filled(40, 80));
  final newer = ValueNotifier<List<double>>([]);
  final viewport = ValueNotifier(const Size(500, 400));
  addTearDown(controller.dispose);
  addTearDown(rows.dispose);
  addTearDown(newer.dispose);
  addTearDown(viewport.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: ValueListenableBuilder<Size>(
          valueListenable: viewport,
          builder: (_, size, _) => SizedBox(
            width: size.width,
            height: size.height,
            child: AnimatedBuilder(
              animation: Listenable.merge([rows, newer]),
              builder: (_, _) => CustomScrollView(
                controller: controller,
                reverse: true,
                center: const ValueKey('centre'),
                slivers: [
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (_, index) => ChatMessageExtentObserver(
                        key: ValueKey('newer-$index'),
                        controller: controller,
                        messageId: 10001 + index,
                        child: SizedBox(
                          height: newer.value[index],
                          child: Text('Newer $index'),
                        ),
                      ),
                      childCount: newer.value.length,
                    ),
                  ),
                  SliverList(
                    key: const ValueKey('centre'),
                    delegate: SliverChildBuilderDelegate(
                      (_, index) => ChatMessageExtentObserver(
                        key: ValueKey('older-$index'),
                        controller: controller,
                        messageId: 10000 - index,
                        child: SizedBox(
                          key: ValueKey('row-$index'),
                          height:
                              rows.value[index] *
                              (responsive ? size.width / 500 : 1),
                          child: Text('Row $index'),
                        ),
                      ),
                      childCount: rows.value.length,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
  });
  controller.jumpTo(offset);
  await tester.pump();
  return (controller: controller, rows: rows, newer: newer, viewport: viewport);
}

void main() {
  testWidgets('a partially visible tall row remains the fallback anchor', (
    tester,
  ) async {
    final fixture = await _history(tester);
    fixture.rows.value = [...fixture.rows.value]..[5] = 900;
    await tester.pump();
    fixture.controller.jumpTo(600);
    await tester.pump();
    final before = tester.getTopLeft(find.byKey(const ValueKey('row-5'))).dy;
    fixture.rows.value = [...fixture.rows.value]..[5] = 1100;
    await tester.pump();
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('row-5'))).dy,
      closeTo(before, 0.01),
    );
  });

  testWidgets(
    'extent tracking remains bounded while scrolling a long history',
    (tester) async {
      final fixture = await _history(tester);
      fixture.rows.value = List.filled(2000, 80);
      await tester.pump();
      for (final offset in [500.0, 10000.0, 40000.0, 100000.0, 500.0]) {
        fixture.controller.jumpTo(offset);
        await tester.pump();
        expect(fixture.controller.debugTrackedRowCount, lessThan(25));
      }
    },
  );

  testWidgets('a preview resize does not stop a user fling', (tester) async {
    final fixture = await _history(tester);
    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, 160),
      1000,
    );
    await tester.pump(const Duration(milliseconds: 16));
    expect(fixture.controller.position.isScrollingNotifier.value, isTrue);
    fixture.rows.value = [...fixture.rows.value]..[5] = 120;
    await tester.pump(const Duration(milliseconds: 16));
    expect(fixture.controller.position.isScrollingNotifier.value, isTrue);
    final afterResize = fixture.controller.offset;
    await tester.pump(const Duration(milliseconds: 16));
    expect(fixture.controller.offset, greaterThan(afterResize));
  });

  testWidgets(
    'a user scroll after layout is not overwritten by its pending snapshot',
    (tester) async {
      final fixture = await _history(tester);
      tester.binding.addPostFrameCallback(
        (_) => fixture.controller.jumpTo(540),
      );
      fixture.rows.value = [...fixture.rows.value]..[4] = 100;
      await tester.pump();
      await tester.pump();
      expect(fixture.controller.offset, 540);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('row-9'))).dy,
        closeTo(120, 0.01),
      );
    },
  );

  testWidgets(
    'a simultaneous user scroll is not consumed as a resize correction',
    (tester) async {
      final fixture = await _history(tester);
      final before = tester.getTopLeft(find.byKey(const ValueKey('row-9'))).dy;
      fixture.controller.jumpTo(540);
      fixture.rows.value = [...fixture.rows.value]..[4] = 320;
      await tester.pump();
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('row-9'))).dy,
        closeTo(before + 40, 0.01),
      );
    },
  );

  testWidgets(
    'scope reset cancels the old snapshot and keeps live row bindings usable',
    (tester) async {
      final fixture = await _history(tester);
      tester.binding.addPostFrameCallback(
        (_) => fixture.controller.resetExtentTracking(),
      );
      fixture.rows.value = [...fixture.rows.value]..[13] = 100;
      await tester.pump();
      fixture.rows.value = [...fixture.rows.value]..[13] = 120;
      await tester.pump();
      final before = tester.getTopLeft(find.byKey(const ValueKey('row-9'))).dy;
      fixture.rows.value = [...fixture.rows.value]..[4] = 200;
      await tester.pump();
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('row-9'))).dy,
        closeTo(before, 0.01),
      );
    },
  );

  testWidgets('a resize at the oldest boundary retains that boundary', (
    tester,
  ) async {
    final fixture = await _history(tester);
    fixture.controller.jumpTo(fixture.controller.position.maxScrollExtent);
    await tester.pump();
    final before = tester.getTopLeft(find.byKey(const ValueKey('row-39'))).dy;
    fixture.rows.value = [...fixture.rows.value]..[36] = 320;
    await tester.pump();
    expect(
      fixture.controller.offset,
      fixture.controller.position.maxScrollExtent,
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('row-39'))).dy,
      closeTo(before, 0.01),
    );
  });

  for (final indices in [
    <int>[4],
    <int>[3, 4, 5, 6, 7],
  ]) {
    testWidgets(
      '${indices.length} changed rows keep the reading anchor in the first painted frame',
      (tester) async {
        final fixture = await _history(tester);
        final before = tester
            .getTopLeft(find.byKey(const ValueKey('row-9')))
            .dy;
        final changed = [...fixture.rows.value];
        for (final index in indices) {
          changed[index] = 320;
        }
        fixture.rows.value = changed;
        await tester.pump();
        expect(find.byKey(const ValueKey('row-9')), findsOneWidget);
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('row-9'))).dy,
          closeTo(before, 0.01),
        );
        final pixels = fixture.controller.offset;
        await tester.pump();
        expect(fixture.controller.offset, pixels);
      },
    );
  }

  testWidgets(
    'a changed row above the viewport does not move visible content',
    (tester) async {
      final fixture = await _history(tester);
      final before = tester.getTopLeft(find.byKey(const ValueKey('row-9'))).dy;
      final changed = [...fixture.rows.value]..[13] = 200;
      fixture.rows.value = changed;
      await tester.pump();
      expect(fixture.controller.offset, 500);
      expect(tester.getTopLeft(find.byKey(const ValueKey('row-9'))).dy, before);
    },
  );

  testWidgets('newer-sliver resizes leave anchored history alone', (
    tester,
  ) async {
    final fixture = await _history(tester);
    fixture.newer.value = [60, 60];
    await tester.pump();
    final before = tester.getTopLeft(find.byKey(const ValueKey('row-9'))).dy;
    fixture.newer.value = [300, 60];
    await tester.pump();
    expect(fixture.controller.offset, 500);
    expect(tester.getTopLeft(find.byKey(const ValueKey('row-9'))).dy, before);
  });

  testWidgets('the newest end stays pinned when a preview grows', (
    tester,
  ) async {
    final fixture = await _history(tester, offset: 0);
    final before = tester.getRect(find.byKey(const ValueKey('row-0'))).bottom;
    fixture.rows.value = [...fixture.rows.value]..[1] = 320;
    await tester.pump();
    expect(fixture.controller.offset, 0);
    expect(tester.getRect(find.byKey(const ValueKey('row-0'))).bottom, before);
  });

  testWidgets('width-dependent row shrinkage keeps the reading anchor', (
    tester,
  ) async {
    final fixture = await _history(tester, responsive: true);
    final before = tester.getTopLeft(find.byKey(const ValueKey('row-10'))).dy;
    fixture.viewport.value = const Size(250, 400);
    await tester.pump();
    expect(find.byKey(const ValueKey('row-10')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('row-10'))).dy,
      closeTo(before, 0.01),
    );
  });

  testWidgets('a viewport height change keeps the reading anchor', (
    tester,
  ) async {
    final fixture = await _history(tester);
    final before = tester.getTopLeft(find.byKey(const ValueKey('row-9'))).dy;
    fixture.viewport.value = const Size(500, 300);
    await tester.pump();
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('row-9'))).dy,
      closeTo(before, 0.01),
    );
  });
}
