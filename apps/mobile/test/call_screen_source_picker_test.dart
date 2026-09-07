import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/calls/call_media_engine.dart';
import 'package:nextcloudtalk/features/calls/call_screen_source_picker.dart';

import 'test_support.dart';

void main() {
  const display = CallScreenSource(
    id: 'display-1',
    name: 'Display 1',
    isWindow: false,
  );
  const window = CallScreenSource(
    id: 'window-2',
    name: 'Document window',
    isWindow: true,
  );
  CallScreenSource? picked;
  var returned = false;

  Future<void> openPicker(
    WidgetTester tester,
    Future<List<CallScreenSource>> Function() load,
  ) async {
    picked = null;
    returned = false;
    await tester.pumpWidget(
      localizedTestApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                picked = await showDialog<CallScreenSource>(
                  context: context,
                  builder: (_) => CallScreenSourcePicker(loadSources: load),
                );
                returned = true;
              },
              child: const Text('Open picker'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open picker'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('a source must be selected and confirmed before returning', (
    tester,
  ) async {
    await openPicker(tester, () async => [display, window]);
    await tester.pumpAndSettle();
    final confirm = find.byKey(const Key('call-screen-source-confirm'));
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    await tester.tap(find.text(window.name));
    await tester.pumpAndSettle();
    expect(returned, isFalse);
    expect(picked, isNull);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(returned, isTrue);
    expect(picked?.id, window.id);
    expect(picked?.isWindow, isTrue);
  });

  testWidgets('cancelling while sources load returns no source', (
    tester,
  ) async {
    final sources = Completer<List<CallScreenSource>>();
    await openPicker(tester, () => sources.future);
    expect(find.byKey(const Key('call-screen-source-loading')), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(returned, isTrue);
    expect(picked, isNull);
    sources.complete([display]);
    await tester.pump();
    expect(find.byType(CallScreenSourcePicker), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed enumeration can be retried without choosing a default', (
    tester,
  ) async {
    var attempts = 0;
    await openPicker(tester, () async {
      if (attempts++ == 0) throw StateError('enumeration refused');
      return [display];
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('call-screen-source-error')), findsOneWidget);
    await tester.tap(find.byKey(const Key('call-screen-source-retry')));
    await tester.pumpAndSettle();
    expect(find.text(display.name), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('call-screen-source-confirm')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('an empty source list offers retry and cannot be confirmed', (
    tester,
  ) async {
    await openPicker(tester, () async => []);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('call-screen-source-retry')), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('call-screen-source-confirm')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets(
    'cancel remains reachable in a small window at double text size',
    (tester) async {
      tester.view.physicalSize = const Size(500, 400);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await openPicker(tester, () async => [display, window]);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(returned, isTrue);
      expect(picked, isNull);
    },
  );
}
