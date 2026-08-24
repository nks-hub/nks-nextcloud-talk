import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/media/image_attachment_upload_controller.dart';
import 'package:nextcloudtalk/features/chat/media/image_attachment_upload_panel.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  testWidgets('opens the system picker without an intermediate upload card', (
    tester,
  ) async {
    final selection = Completer<ImageAttachmentUploadRequest?>();
    var pickerOpened = false;
    final controller = ImageAttachmentUploadController(
      startUpload: (_) async => throw StateError('Upload must not start.'),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _app(
        controller,
        prepare: () {
          pickerOpened = true;
          return selection.future;
        },
      ),
    );

    await tester.tap(find.byKey(const Key('pick-image-attachment')));
    await tester.pump();

    expect(pickerOpened, isTrue);
    expect(controller.state.phase, ImageAttachmentUploadPhase.preparing);
    expect(
      find.byKey(const Key('image-attachment-upload-panel')),
      findsNothing,
    );

    selection.complete(null);
    await tester.pump();
  });

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
    expect(find.text('Uploading image… 37%'), findsOneWidget);
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

    expect(find.text('The image could not be sent.'), findsOneWidget);
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
}

Widget _app(
  ImageAttachmentUploadController controller, {
  PrepareImageAttachment? prepare,
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
                    prepare: prepare ?? () async => _request,
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
