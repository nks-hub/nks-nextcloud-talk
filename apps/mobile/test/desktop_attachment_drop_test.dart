import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/conversations/desktop_attachment_drop.dart';

void main() {
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

  testWidgets('multiple items and directories never reach the composer', (
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
      DesktopAttachmentDropOutcome.invalidSelection,
    );
    expect(
      await controller!.accept(<DropItem>[
        DropItemDirectory('folder', const <DropItem>[]),
      ]),
      DesktopAttachmentDropOutcome.invalidSelection,
    );
    expect(submissions, 0);
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
