import 'dart:async';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/conversations/desktop_attachment_drop.dart';

import 'test_support.dart';

void main() {
  testWidgets(
    'drag feedback stays visible until the dropped batch is prepared',
    (tester) async {
      final gate = Completer<bool>();
      DesktopAttachmentDropController? controller;
      var calls = 0;
      await tester.pumpWidget(
        localizedTestApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: Scaffold(
            body: DesktopAttachmentDrop(
              child: Builder(
                builder: (context) {
                  controller = DesktopAttachmentDrop.controllerOf(context);
                  return const SizedBox.expand();
                },
              ),
            ),
          ),
        ),
      );
      controller!.bind(Object(), (_) async {
        calls++;
        return gate.future;
      });
      DropTarget target() => tester.widget<DropTarget>(find.byType(DropTarget));
      final event = DropEventDetails(
        localPosition: Offset.zero,
        globalPosition: Offset.zero,
      );
      target().onDragEntered!(event);
      await tester.pump();
      expect(find.text('Drop files to add attachments'), findsOneWidget);
      target().onDragExited!(event);
      await tester.pump();
      expect(
        find.byKey(const Key('desktop-attachment-drop-placeholder')),
        findsNothing,
      );
      target().onDragEntered!(event);
      target().onDragDone!(
        DropDoneDetails(
          localPosition: Offset.zero,
          globalPosition: Offset.zero,
          files: List.generate(
            6,
            (index) =>
                DropItemFile.fromData(Uint8List(1), name: 'file-$index.txt'),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Preparing attachments (6)…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      gate.complete(true);
      await tester.pumpAndSettle();
      expect(calls, 6);
      expect(
        find.byKey(const Key('desktop-attachment-drop-placeholder')),
        findsNothing,
      );
      final failure = Completer<bool>();
      controller!.bind(Object(), (_) => failure.future);
      target().onDragDone!(
        DropDoneDetails(
          localPosition: Offset.zero,
          globalPosition: Offset.zero,
          files: [DropItemFile.fromData(Uint8List(1), name: 'failed.txt')],
        ),
      );
      await tester.pump();
      expect(find.text('Preparing attachments (1)…'), findsOneWidget);
      failure.completeError(StateError('Source unavailable'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('desktop-attachment-drop-placeholder')),
        findsNothing,
      );
      expect(find.text('The attachment could not be sent.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('drag without an active composer shows no drop promise', (
    tester,
  ) async {
    await tester.pumpWidget(
      localizedTestApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: const DesktopAttachmentDrop(child: SizedBox.expand()),
      ),
    );
    tester.widget<DropTarget>(find.byType(DropTarget)).onDragEntered!(
      DropEventDetails(localPosition: Offset.zero, globalPosition: Offset.zero),
    );
    await tester.pump();
    expect(
      find.byKey(const Key('desktop-attachment-drop-placeholder')),
      findsNothing,
    );
  });

  test('a batch stops when the active conversation changes', () async {
    final controller = DesktopAttachmentDropController();
    final owner = Object();
    var submitted = 0;
    controller.bind(owner, (_) async {
      submitted++;
      controller.unbind(owner);
      controller.bind(Object(), (_) async {
        fail('The remaining file must not reach the new conversation');
      });
      return true;
    });
    final file = DropItemFile.fromData(Uint8List(1), name: 'file.txt');
    expect(
      await controller.accept([file, file]),
      DesktopAttachmentDropOutcome.unavailable,
    );
    expect(submitted, 1);
  });

  testWidgets('desktop exposes one controller to the open conversation', (
    tester,
  ) async {
    DesktopAttachmentDropController? controller;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: DesktopAttachmentDrop(
          child: Builder(
            builder: (context) {
              controller = DesktopAttachmentDrop.controllerOf(context);
              return const SizedBox(key: Key('conversation'));
            },
          ),
        ),
      ),
    );
    final submitted = <DropItem>[];
    final owner = Object();
    controller!.bind(owner, (item) async {
      submitted.add(item);
      return true;
    });
    addTearDown(() => controller?.unbind(owner));

    final outcome = await controller!.accept(<DropItem>[
      DropItemFile.fromData(
        Uint8List.fromList(<int>[1]),
        name: 'one.bin',
        path: 'one.bin',
      ),
    ]);

    expect(outcome, DesktopAttachmentDropOutcome.accepted);
    expect(submitted.single.name, 'one.bin');
  });

  testWidgets('multiple files reach the composer but directories do not', (
    tester,
  ) async {
    DesktopAttachmentDropController? controller;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.linux),
        home: DesktopAttachmentDrop(
          child: Builder(
            builder: (context) {
              controller = DesktopAttachmentDrop.controllerOf(context);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    var submissions = 0;
    final owner = Object();
    controller!.bind(owner, (_) async {
      submissions++;
      return true;
    });
    addTearDown(() => controller?.unbind(owner));
    final file = DropItemFile.fromData(
      Uint8List(1),
      name: 'one.bin',
      path: 'one.bin',
    );

    expect(
      await controller!.accept(<DropItem>[file, file]),
      DesktopAttachmentDropOutcome.accepted,
    );
    expect(
      await controller!.accept(<DropItem>[
        DropItemDirectory('folder', const <DropItem>[]),
      ]),
      DesktopAttachmentDropOutcome.invalidSelection,
    );
    expect(submissions, 2);
  });

  testWidgets('mobile leaves the conversation outside a native drop target', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.iOS),
        home: const DesktopAttachmentDrop(
          child: SizedBox(key: Key('conversation')),
        ),
      ),
    );

    expect(find.byKey(const Key('conversation')), findsOneWidget);
    expect(find.byType(DesktopAttachmentDrop), findsOneWidget);
    expect(find.byType(DropTarget), findsNothing);
    expect(
      DesktopAttachmentDrop.maybeControllerOf(
        tester.element(find.byKey(const Key('conversation'))),
      ),
      isNotNull,
    );
  });
}
