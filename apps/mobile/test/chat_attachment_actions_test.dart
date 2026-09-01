import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/chat/chat_message_content.dart';
import 'package:nextcloudtalk/features/chat/media/chat_attachment_exporter.dart';
import 'package:nextcloudtalk/features/chat/media/chat_attachment_opener.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  testWidgets('generic attachment exposes three visible 48dp actions', (
    tester,
  ) async {
    final exporter = _RecordingExporter();
    final opener = _RecordingOpener();
    await tester.pumpWidget(_app(exporter: exporter, opener: opener));

    expect(find.byType(PopupMenuButton), findsNothing);
    expect(find.byTooltip('Open attachment'), findsOneWidget);
    expect(find.byTooltip('Save attachment'), findsOneWidget);
    expect(find.byTooltip('Share attachment'), findsOneWidget);
    expect(find.byIcon(Icons.open_in_new_rounded), findsOneWidget);
    expect(find.byIcon(Icons.save_alt_rounded), findsOneWidget);
    expect(find.byIcon(Icons.share_rounded), findsOneWidget);
    for (final key in const [
      Key('chat-attachment-open-action-81-0'),
      Key('chat-attachment-save-action-81-0'),
      Key('chat-attachment-share-action-81-0'),
    ]) {
      final size = tester.getSize(find.byKey(key));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }

    await tester.tap(find.byKey(const Key('chat-attachment-save-action-81-0')));
    await tester.pumpAndSettle();
    expect(exporter.savedNames, ['report.pdf']);
    expect(find.text('Attachment saved.'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('chat-attachment-share-action-81-0')),
    );
    await tester.pumpAndSettle();
    expect(exporter.sharedNames, ['report.pdf']);

    await tester.tap(find.byKey(const Key('chat-attachment-open-action-81-0')));
    await tester.pumpAndSettle();
    expect(opener.openedNames, ['report.pdf']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelled save is informational and share cancel is silent', (
    tester,
  ) async {
    final exporter = _RecordingExporter(
      saveResult: ChatAttachmentSaveResult.cancelled,
      shareResult: ChatAttachmentShareResult.cancelled,
    );
    await tester.pumpWidget(
      _app(exporter: exporter, opener: _RecordingOpener()),
    );

    await tester.tap(find.byKey(const Key('chat-attachment-save-action-81-0')));
    await tester.pumpAndSettle();
    expect(find.text('Saving cancelled.'), findsOneWidget);

    ScaffoldMessenger.of(
      tester.element(find.byType(ChatMessageContent)),
    ).hideCurrentSnackBar();
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('chat-attachment-share-action-81-0')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('attachment actions wrap without overflow at 200 percent text', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        exporter: _RecordingExporter(),
        opener: _RecordingOpener(),
        width: 160,
        textScaler: const TextScaler.linear(2),
      ),
    );

    expect(find.byTooltip('Open attachment'), findsOneWidget);
    expect(find.byTooltip('Save attachment'), findsOneWidget);
    expect(find.byTooltip('Share attachment'), findsOneWidget);
    for (final key in const [
      Key('chat-attachment-open-action-81-0'),
      Key('chat-attachment-save-action-81-0'),
      Key('chat-attachment-share-action-81-0'),
    ]) {
      final size = tester.getSize(find.byKey(key));
      expect(size.width, lessThanOrEqualTo(160));
      expect(size.height, greaterThanOrEqualTo(48));
      expect(size.height, lessThanOrEqualTo(112), reason: '$key: $size');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('voice attachments keep their existing controls without menu', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        exporter: _RecordingExporter(),
        opener: _RecordingOpener(),
        message: _voiceMessage,
      ),
    );

    expect(find.byKey(const Key('chat-voice-82')), findsOneWidget);
    expect(
      find.byKey(const Key('chat-attachment-save-action-82-0')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  const saveFailures = <ChatAttachmentSaveResult, String>{
    ChatAttachmentSaveResult.downloadFailed:
        'The attachment could not be downloaded.',
    ChatAttachmentSaveResult.reauthenticationRequired:
        'Sign in again to download this attachment.',
    ChatAttachmentSaveResult.tooLarge:
        'This attachment is too large to export.',
    ChatAttachmentSaveResult.invalid: 'This attachment is no longer valid.',
    ChatAttachmentSaveResult.permissionDenied:
        'The selected location does not allow this file to be saved.',
    ChatAttachmentSaveResult.storageFailed:
        'The attachment could not be written to the selected location.',
  };
  for (final entry in saveFailures.entries) {
    testWidgets('save ${entry.key.name} shows its specific recovery message', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          exporter: _RecordingExporter(saveResult: entry.key),
          opener: _RecordingOpener(),
        ),
      );

      await tester.tap(
        find.byKey(const Key('chat-attachment-save-action-81-0')),
      );
      await tester.pumpAndSettle();

      expect(find.text(entry.value), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  const openFailures = <ChatAttachmentOpenResult, String>{
    ChatAttachmentOpenResult.reauthenticationRequired:
        'Sign in again to download this attachment.',
    ChatAttachmentOpenResult.tooLarge:
        'This attachment is too large to export.',
    ChatAttachmentOpenResult.invalid: 'This attachment is no longer valid.',
    ChatAttachmentOpenResult.downloadFailed:
        'The attachment could not be downloaded.',
    ChatAttachmentOpenResult.storageFailed:
        'The attachment could not be written to the selected location.',
    ChatAttachmentOpenResult.openFailed:
        'The action could not be completed. Please try again.',
  };
  for (final entry in openFailures.entries) {
    testWidgets('open ${entry.key.name} shows its specific recovery message', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          exporter: _RecordingExporter(),
          opener: _RecordingOpener(result: entry.key),
        ),
      );

      await tester.tap(
        find.byKey(const Key('chat-attachment-open-action-81-0')),
      );
      await tester.pumpAndSettle();

      expect(find.text(entry.value), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  const shareFailures = <ChatAttachmentShareResult, String>{
    ChatAttachmentShareResult.reauthenticationRequired:
        'Sign in again to download this attachment.',
    ChatAttachmentShareResult.tooLarge:
        'This attachment is too large to export.',
    ChatAttachmentShareResult.invalid: 'This attachment is no longer valid.',
    ChatAttachmentShareResult.downloadFailed:
        'The attachment could not be downloaded.',
    ChatAttachmentShareResult.permissionDenied:
        'The selected location does not allow this file to be saved.',
    ChatAttachmentShareResult.shareFailed:
        'The attachment could not be shared.',
  };
  for (final entry in shareFailures.entries) {
    testWidgets('share ${entry.key.name} shows its specific recovery message', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          exporter: _RecordingExporter(shareResult: entry.key),
          opener: _RecordingOpener(),
        ),
      );

      await tester.tap(
        find.byKey(const Key('chat-attachment-share-action-81-0')),
      );
      await tester.pumpAndSettle();

      expect(find.text(entry.value), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

Widget _app({
  required ChatAttachmentExportAction exporter,
  required ChatAttachmentOpenAction opener,
  ChatMessage? message,
  double width = 420,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  return ProviderScope(
    overrides: [
      chatAttachmentExportActionFactoryProvider.overrideWithValue(
        (_) => exporter,
      ),
      chatAttachmentOpenActionFactoryProvider.overrideWithValue((_) => opener),
    ],
    child: localizedTestApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: MediaQuery(
            data: MediaQueryData(
              size: const Size(800, 600),
              textScaler: textScaler,
            ),
            child: SizedBox(
              width: width,
              child: ChatMessageContent(
                account: _account,
                message: message ?? _fileMessage,
                fallbackText: '',
                foregroundColor: Colors.black,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

final class _RecordingExporter implements ChatAttachmentExportAction {
  _RecordingExporter({
    this.saveResult = ChatAttachmentSaveResult.saved,
    this.shareResult = ChatAttachmentShareResult.shared,
  });

  final ChatAttachmentSaveResult saveResult;
  final ChatAttachmentShareResult shareResult;
  final List<String> savedNames = [];
  final List<String> sharedNames = [];

  @override
  Future<ChatAttachmentSaveResult> save({
    required StoredAccount account,
    required Uri uri,
    required String fileName,
    required String expectedContentType,
  }) async {
    savedNames.add(fileName);
    return saveResult;
  }

  @override
  Future<ChatAttachmentShareResult> share({
    required StoredAccount account,
    required Uri uri,
    required String fileName,
    required String expectedContentType,
  }) async {
    sharedNames.add(fileName);
    return shareResult;
  }
}

final class _RecordingOpener implements ChatAttachmentOpenAction {
  _RecordingOpener({this.result = ChatAttachmentOpenResult.opened});

  final ChatAttachmentOpenResult result;
  final List<String> openedNames = [];

  @override
  Future<ChatAttachmentOpenResult> open({
    required StoredAccount account,
    required Uri uri,
    required String fileName,
    required String expectedContentType,
  }) async {
    openedNames.add(fileName);
    return result;
  }
}

const StoredAccount _account = StoredAccount(
  id: 'account-a',
  serverUrl: 'https://cloud.example.invalid',
  loginName: 'fixture-user',
  serverProductName: 'Nextcloud',
  talkFeaturesJson: '[]',
  selected: true,
  createdAtMillis: 1767225600000,
);

final ChatMessage _fileMessage = ChatMessage.fromJson({
  'id': 81,
  'token': 'rooma123',
  'actorType': 'users',
  'actorId': 'fixture-author',
  'actorDisplayName': 'Fixture author',
  'timestamp': 1767225600,
  'systemMessage': '',
  'messageType': 'comment',
  'isReplyable': true,
  'referenceId': 'reference-81',
  'message': '{file}',
  'messageParameters': {
    'file': {
      'type': 'file',
      'id': '81',
      'name': 'report.pdf',
      'path': 'Talk/report.pdf',
      'mimetype': 'application/pdf',
    },
  },
  'markdown': false,
  'reactions': <String, Object?>{},
  'reactionsSelf': <Object?>[],
  'deleted': null,
});

final ChatMessage _voiceMessage = ChatMessage.fromJson({
  ..._fileMessage.wire,
  'id': 82,
  'referenceId': 'reference-82',
  'messageType': 'voice-message',
  'messageParameters': {
    'file': {
      'type': 'file',
      'id': '82',
      'name': 'voice.m4a',
      'path': 'Talk/voice.m4a',
      'mimetype': 'audio/mp4',
    },
  },
});
