import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/features/chat/chat_pending_attachments.dart';
import 'package:nextcloudtalk/features/chat/media/attachment_source_thumbnail.dart';
import 'package:nextcloudtalk/platform/media/durable_attachment_source_store.dart';

import 'pending_attachment_fixture.dart';
import 'test_support.dart';

void main() {
  testWidgets('replacing a photo with a document clears the previous thumbnail', (
    tester,
  ) async {
    final setup = await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp(
        'attachment-thumbnail-',
      );
      final store = DurableAttachmentSourceStore(root: root);
      final photo = await store.copyFromStream(
        stream: Stream.value(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
          ),
        ),
        mimeType: 'image/png',
        displayName: 'photo.png',
      );
      final file = await store.copyFromStream(
        stream: Stream.value([1, 2, 3]),
        mimeType: 'application/pdf',
        displayName: 'document.pdf',
      );
      return (root: root, store: store, photo: photo, file: file);
    });
    addTearDown(() => setup!.root.delete(recursive: true));
    Widget thumbnail(source) => MaterialApp(
      home: SizedBox.square(
        dimension: 56,
        child: AttachmentSourceThumbnail(source: source, store: setup!.store),
      ),
    );
    await tester.pumpWidget(thumbnail(setup!.photo));
    for (
      var attempt = 0;
      attempt < 30 && find.byType(Image).evaluate().isEmpty;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(find.byType(Image), findsOneWidget);
    await tester.pumpWidget(thumbnail(setup.file));
    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.insert_drive_file_outlined), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test(
    'active albums retain completed photos and keep separate sends apart',
    () {
      final rows = [
        pendingAttachmentFixture(0, phase: 'completed'),
        pendingAttachmentFixture(1, phase: 'failed'),
        pendingAttachmentFixture(
          0,
          albumId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        ),
      ];
      final batches = pendingAttachmentBatches(
        rows,
        serverUrl: 'https://cloud.example.invalid',
      );
      expect(batches, hasLength(2));
      expect(batches.first.completed, 1);
      expect(batches.first.hasFailure, isTrue);
      expect(batches.first.confirmedMessageIds, {100});
      expect(
        pendingAttachmentBatches(
          rows,
          serverUrl: 'https://other.example.invalid',
        ),
        isEmpty,
      );
      expect(
        pendingAttachmentBatches([
          pendingAttachmentFixture(0, phase: 'completed'),
        ], serverUrl: 'https://cloud.example.invalid'),
        isEmpty,
      );
    },
  );

  test('ambiguous finalization cannot be cancelled or blindly retried', () {
    final job = pendingAttachmentFixture(0, phase: 'awaitingConfirmation');
    expect(attachmentJobCanCancel(job), isFalse);
    expect(attachmentJobCanRetry(job), isFalse);
    expect(attachmentJobCanCancel(pendingAttachmentFixture(0)), isTrue);
    expect(
      attachmentJobCanRetry(pendingAttachmentFixture(0, phase: 'retryable')),
      isTrue,
    );
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'ten pending attachments fit a narrow bubble at text scale $scale',
      (tester) async {
        tester.view.physicalSize = const Size(390, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final jobs = List.generate(
          10,
          (index) => pendingAttachmentFixture(
            index,
            count: 10,
            phase: index < 3
                ? 'completed'
                : index == 3
                ? 'retryable'
                : 'uploading',
          ),
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              attachmentSourceProvider.overrideWith(
                (ref) => throw StateError('No local thumbnail'),
              ),
            ],
            child: localizedTestApp(
              textScale: scale,
              home: Scaffold(
                body: SingleChildScrollView(
                  child: PendingAttachmentBubble(
                    batch: PendingAttachmentBatch('batch', jobs),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('3 of 10 sent'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(
          find.byKey(const Key('retry-pending-attachments')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('pending-attachment-details')));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('photo-9.png'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
