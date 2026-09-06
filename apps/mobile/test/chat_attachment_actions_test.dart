import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/chat_media_repository.dart';
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

  testWidgets('a running download shows its percentage until it finishes', (
    tester,
  ) async {
    final opener = _RecordingOpener()..heldProgress = (received: 3, total: 4);
    await tester.pumpWidget(
      _app(exporter: _RecordingExporter(), opener: opener),
    );

    await tester.tap(find.byKey(const Key('chat-attachment-open-action-81-0')));
    await tester.pump();

    expect(
      find.byKey(const Key('chat-attachment-downloading')),
      findsOneWidget,
    );
    expect(find.text('Downloading the attachment… 75%'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byKey(const Key('chat-attachment-downloading-bar')),
    );
    expect(bar.value, 0.75);

    opener.release();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat-attachment-downloading')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a download without a declared length stays indeterminate', (
    tester,
  ) async {
    final opener = _RecordingOpener()
      ..heldProgress = (received: 512, total: null);
    await tester.pumpWidget(
      _app(exporter: _RecordingExporter(), opener: opener),
    );

    await tester.tap(find.byKey(const Key('chat-attachment-open-action-81-0')));
    await tester.pump();

    expect(find.text('Downloading the attachment…'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byKey(const Key('chat-attachment-downloading-bar')),
    );
    expect(bar.value, isNull);

    opener.release();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat-attachment-downloading')), findsNothing);
  });

  testWidgets('a missing response length falls back to the declared size', (
    tester,
  ) async {
    final opener = _RecordingOpener()
      ..heldProgress = (received: 1024, total: null);
    await tester.pumpWidget(
      _app(
        exporter: _RecordingExporter(),
        opener: opener,
        message: _sizedFileMessage,
      ),
    );

    await tester.tap(find.byKey(const Key('chat-attachment-open-action-81-0')));
    await tester.pump();

    expect(find.text('Downloading the attachment… 25%'), findsOneWidget);
    opener.release();
    await tester.pumpAndSettle();
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

  testWidgets('a failed download re-reads the message and opens what it finds', (
    tester,
  ) async {
    // The other half of the repair the voice player already does: a message
    // cached with the path the HPB relay wrote names a file the server does
    // not know, and every download of it fails. The message is re-read once
    // and the download repeated against the address it then carries — so the
    // person taps once, not twice, and never sees the failure at all.
    final opener = _RecordingOpener(result: ChatAttachmentOpenResult.downloadFailed);
    final repaired = Uri.parse(
      'https://cloud.example.invalid/remote.php/dav/files/alice/Talk/room/report.pdf',
    );
    var repairs = 0;

    await tester.pumpWidget(
      _app(
        exporter: _RecordingExporter(),
        opener: opener,
        overrides: [
          attachmentUriRepairProvider.overrideWithValue(({
            required account,
            required roomToken,
            required messageId,
            required index,
            required failedUri,
          }) async {
            repairs++;
            opener.result = ChatAttachmentOpenResult.opened;
            return repaired;
          }),
        ],
      ),
    );

    await tester.tap(find.byKey(const Key('chat-attachment-open-action-81-0')));
    await tester.pumpAndSettle();

    expect(repairs, 1, reason: 'asked once, not once per attempt');
    expect(opener.openedUris.length, 2);
    expect(opener.openedUris.last, repaired);
    expect(
      find.text('The attachment could not be downloaded.'),
      findsNothing,
      reason: 'the download that succeeded is the one that counts',
    );
    expect(tester.takeException(), isNull);
  });

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
          // Nothing to repair: these are the failures that stand, and the
          // message has to be the one the person sees. Left live, the repair
          // would reach the database and the frame would never settle.
          overrides: [_noRepair],
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
  List<Override> overrides = const [],
}) {
  return ProviderScope(
    overrides: [
      chatAttachmentExportActionFactoryProvider.overrideWithValue(
        (_) => exporter,
      ),
      chatAttachmentOpenActionFactoryProvider.overrideWithValue((_) => opener),
      ...overrides,
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
    ChatDownloadProgress? onProgress,
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
    ChatDownloadProgress? onProgress,
  }) async {
    sharedNames.add(fileName);
    return shareResult;
  }
}

/// No corrected address exists for this attachment, so a failed download stays
/// failed and the person is told.
final _noRepair = attachmentUriRepairProvider.overrideWithValue(({
  required account,
  required roomToken,
  required messageId,
  required index,
  required failedUri,
}) async => null);

final class _RecordingOpener implements ChatAttachmentOpenAction {
  _RecordingOpener({this.result = ChatAttachmentOpenResult.opened});

  /// Not final: a repair test lets the second attempt succeed where the first
  /// one failed, which is the whole point of repeating it.
  ChatAttachmentOpenResult result;
  final List<String> openedNames = [];
  final List<Uri> openedUris = [];

  /// When set, `open` reports this progress and then waits for [release].
  ({int received, int? total})? heldProgress;
  final Completer<void> _released = Completer<void>();

  void release() => _released.complete();

  @override
  Future<ChatAttachmentOpenResult> open({
    required StoredAccount account,
    required Uri uri,
    required String fileName,
    required String expectedContentType,
    ChatDownloadProgress? onProgress,
  }) async {
    openedNames.add(fileName);
    openedUris.add(uri);
    final held = heldProgress;
    if (held != null) {
      onProgress?.call(held.received, held.total);
      await _released.future;
    }
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

/// The same file with the size Talk sends alongside the share.
final ChatMessage _sizedFileMessage = ChatMessage.fromJson({
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
      'size': '4096',
    },
  },
  'markdown': false,
  'reactions': <String, Object?>{},
  'reactionsSelf': <Object?>[],
  'deleted': null,
});
