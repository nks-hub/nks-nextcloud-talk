import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/media/image_attachment_upload_controller.dart';
import 'package:nextcloudtalk/features/chat/media/image_attachment_upload_panel.dart';
import 'package:nextcloudtalk/platform/media/image_attachment_picker.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  testWidgets('opens the system picker without an intermediate upload card', (
    tester,
  ) async {
    final selection = Completer<ImageAttachmentUploadRequest?>();
    AttachmentPickerSource? pickedSource;
    final controller = ImageAttachmentUploadController(
      startUpload: (_) async => throw StateError('Upload must not start.'),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _app(
        controller,
        prepare: (source) {
          pickedSource = source;
          return selection.future;
        },
      ),
    );

    await tester.tap(find.byKey(const Key('pick-image-attachment')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('attach-source-gallery')));
    await tester.pumpAndSettle();

    expect(pickedSource, AttachmentPickerSource.gallery);
    expect(controller.state.phase, ImageAttachmentUploadPhase.preparing);
    expect(
      find.byKey(const Key('image-attachment-upload-panel')),
      findsNothing,
    );

    selection.complete(null);
    await tester.pump();
  });

  testWidgets(
    'paperclip includes enabled composer actions after file sources',
    (tester) async {
      final controller = ImageAttachmentUploadController(
        startUpload: (_) async => throw StateError('Upload must not start.'),
      );
      addTearDown(controller.dispose);
      var selected = 0;

      await tester.pumpWidget(
        _app(
          controller,
          menuActions: <AttachmentMenuAction>[
            AttachmentMenuAction(
              key: const Key('menu-giphy'),
              icon: const Icon(Icons.gif_box_outlined),
              label: 'GIF',
              onSelected: () => selected++,
            ),
            const AttachmentMenuAction(
              key: Key('menu-disabled'),
              icon: Icon(Icons.location_on_outlined),
              label: 'Unavailable',
              onSelected: null,
            ),
          ],
        ),
      );

      await tester.tap(find.byKey(const Key('pick-image-attachment')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('attach-source-gallery')), findsOneWidget);
      expect(find.byKey(const Key('attach-source-camera')), findsOneWidget);
      expect(find.byKey(const Key('attach-source-file')), findsOneWidget);
      expect(find.byKey(const Key('menu-giphy')), findsOneWidget);
      final disabled = tester.widget<ListTile>(
        find.byKey(const Key('menu-disabled')),
      );
      expect(disabled.enabled, isFalse);

      await tester.tap(find.byKey(const Key('menu-giphy')));
      await tester.pumpAndSettle();
      expect(selected, 1);
    },
  );

  testWidgets('hides the upload card as soon as chat confirmation completes', (
    tester,
  ) async {
    final events = StreamController<ImageAttachmentUploadEvent>(sync: true);
    addTearDown(events.close);
    final controller = ImageAttachmentUploadController(
      startUpload: (_) async => ImageAttachmentUploadSession(
        events: events.stream,
        cancel: () async {},
      ),
    );
    addTearDown(controller.dispose);
    await controller.startPrepared(_request);
    events.add(ImageAttachmentUploadEvent.awaitingConfirmation());

    await tester.pumpWidget(_app(controller));
    expect(
      find.byKey(const Key('image-attachment-upload-panel')),
      findsOneWidget,
    );

    events.add(ImageAttachmentUploadEvent.completed());
    await tester.pump();

    expect(
      find.byKey(const Key('image-attachment-upload-panel')),
      findsNothing,
    );
  });

  testWidgets('shows progress and 48dp actions at 200 percent text scale', (
    tester,
  ) async {
    final events = StreamController<ImageAttachmentUploadEvent>(sync: true);
    addTearDown(events.close);
    final controller = ImageAttachmentUploadController(
      startUpload: (_) async => ImageAttachmentUploadSession(
        events: events.stream,
        cancel: () async {},
      ),
    );
    addTearDown(controller.dispose);
    await controller.startPrepared(_request);
    events.add(ImageAttachmentUploadEvent.uploading(0.37));

    await tester.pumpWidget(_app(controller));

    expect(
      find.byKey(const Key('image-attachment-upload-panel')),
      findsOneWidget,
    );
    expect(find.text('Uploading… 37%'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const Key('image-attachment-upload-progress')),
          )
          .value,
      0.37,
    );
    for (final key in <String>[
      'pick-image-attachment',
      'cancel-image-attachment-upload',
    ]) {
      final size = tester.getSize(find.byKey(Key(key)));
      expect(size.width, greaterThanOrEqualTo(48), reason: key);
      expect(size.height, greaterThanOrEqualTo(48), reason: key);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows retry and dismiss only for a retryable failure', (
    tester,
  ) async {
    final controller = ImageAttachmentUploadController(
      startUpload: (_) async => throw StateError('Synthetic failure.'),
    );
    addTearDown(controller.dispose);
    await controller.startPrepared(_request);

    await tester.pumpWidget(_app(controller));

    expect(find.text('The attachment could not be sent.'), findsOneWidget);
    expect(
      find.byKey(const Key('retry-image-attachment-upload')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('dismiss-image-attachment-upload')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('cancel-image-attachment-upload')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows a quota-specific message without a retry action for 507', (
    tester,
  ) async {
    final events = StreamController<ImageAttachmentUploadEvent>(sync: true);
    addTearDown(events.close);
    final controller = ImageAttachmentUploadController(
      startUpload: (_) async => ImageAttachmentUploadSession(
        events: events.stream,
        cancel: () async {},
      ),
    );
    addTearDown(controller.dispose);
    await controller.startPrepared(_request);
    events.add(
      ImageAttachmentUploadEvent.failed(
        'dav-quota-exceeded',
        retryAllowed: false,
      ),
    );

    await tester.pumpWidget(_app(controller));

    expect(
      find.text('The attachment could not be sent: storage quota exceeded.'),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('retry-image-attachment-upload')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('dismiss-image-attachment-upload')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'shows a permission-specific message without a retry action for 403',
    (tester) async {
      final events = StreamController<ImageAttachmentUploadEvent>(sync: true);
      addTearDown(events.close);
      final controller = ImageAttachmentUploadController(
        startUpload: (_) async => ImageAttachmentUploadSession(
          events: events.stream,
          cancel: () async {},
        ),
      );
      addTearDown(controller.dispose);
      await controller.startPrepared(_request);
      events.add(
        ImageAttachmentUploadEvent.failed(
          'dav-permission-denied',
          retryAllowed: false,
        ),
      );

      await tester.pumpWidget(_app(controller));

      expect(
        find.text(
          'The attachment could not be sent: you do not have permission to '
          'upload files here.',
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('retry-image-attachment-upload')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('dismiss-image-attachment-upload')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('explains a refused gallery without offering a blind retry', (
    tester,
  ) async {
    final events = StreamController<ImageAttachmentUploadEvent>(sync: true);
    addTearDown(events.close);
    final controller = ImageAttachmentUploadController(
      startUpload: (_) async => ImageAttachmentUploadSession(
        events: events.stream,
        cancel: () async {},
      ),
    );
    addTearDown(controller.dispose);
    await controller.startPrepared(_request);
    events.add(
      ImageAttachmentUploadEvent.failed(
        'gallery-permission-denied',
        retryAllowed: false,
      ),
    );

    await tester.pumpWidget(_app(controller));

    expect(
      find.text(
        'Choosing a photo needs gallery access. Grant it in the system '
        'settings and try again.',
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('retry-image-attachment-upload')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}

Widget _app(
  ImageAttachmentUploadController controller, {
  PrepareAttachmentFromSource? prepare,
  List<AttachmentMenuAction> menuActions = const <AttachmentMenuAction>[],
}) {
  return localizedTestApp(
    home: MediaQuery(
      data: const MediaQueryData(
        size: Size(240, 640),
        textScaler: TextScaler.linear(2),
      ),
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: ImageAttachmentPickerButton(
                    controller: controller,
                    prepare: prepare ?? (_) async => _request,
                    menuActions: menuActions,
                  ),
                ),
                ImageAttachmentUploadPanel(controller: controller),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

final ImageAttachmentUploadRequest _request = ImageAttachmentUploadRequest(
  accountId: AccountId.parse('account-a'),
  server: ServerBase.parse('https://cloud.example.invalid'),
  roomToken: ConversationToken.parse(
    'rooma123',
    path: r'$.roomToken',
    code: TalkProtocolErrorCode.invalidAttachmentModel,
  ),
  source: PreparedAttachmentSource(
    handle: AttachmentSourceHandle.parse('app-owned-image-1'),
    ownership: AttachmentSourceOwnership.appOwnedCopy,
    byteLength: 1024,
    sha256: AttachmentSha256.parse(
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    ),
    mimeType: 'image/jpeg',
    displayName: 'photo.jpg',
  ),
  metadata: AttachmentMetadata(
    kind: AttachmentMessageKind.file,
    replyTo: null,
    threadId: null,
    threadTitle: null,
    silent: false,
  ),
);
