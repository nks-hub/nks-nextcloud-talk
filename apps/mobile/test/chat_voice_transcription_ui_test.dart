import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_media_repository.dart';
import 'package:nextcloudtalk/features/chat/chat_message_content.dart';
import 'package:nextcloudtalk/platform/media/voice_transcription.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  testWidgets('iOS voice message exposes a 48dp transcription action', (
    tester,
  ) async {
    final transcriber = _ControlledTranscriber();
    await tester.pumpWidget(_voiceApp(transcriber: transcriber));

    final action = find.byKey(const Key('chat-voice-transcribe-44'));
    expect(action, findsOneWidget);
    expect(tester.getSize(action), const Size(48, 48));
    expect(find.text('Transcribe'), findsOneWidget);
  });

  testWidgets('unsupported platform hides voice transcription', (tester) async {
    await tester.pumpWidget(_voiceApp(transcriber: null));

    expect(find.byKey(const Key('chat-voice-transcribe-44')), findsNothing);
    expect(find.text('Transcribe'), findsNothing);
  });

  testWidgets('transcription uses app-owned audio and exposes copy', (
    tester,
  ) async {
    final transcriber = _ControlledTranscriber();
    MethodCall? clipboardCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardCall = call;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.pumpWidget(_voiceApp(transcriber: transcriber));

    await tester.tap(find.byKey(const Key('chat-voice-transcribe-44')));
    await tester.pump();

    expect(
      find.byKey(const Key('chat-voice-transcribing-44')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('chat-voice-transcription-cancel-44')),
      findsOneWidget,
    );
    expect(transcriber.paths, ['/app-owned/voice-message.m4a']);
    expect(transcriber.locales, ['en']);

    transcriber.complete('Recognized words');
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('chat-voice-transcript-44')),
      findsOneWidget,
    );
    expect(find.text('Recognized words'), findsOneWidget);
    final copy = find.byKey(const Key('chat-voice-transcript-copy-44'));
    expect(tester.getSize(copy), const Size(48, 48));
    await tester.tap(copy);
    await tester.pump();

    expect(clipboardCall?.arguments, <String, Object?>{
      'text': 'Recognized words',
    });
    expect(find.text('Transcription copied to clipboard'), findsOneWidget);
  });

  testWidgets('cancel discards a late transcription result', (tester) async {
    final transcriber = _ControlledTranscriber();
    await tester.pumpWidget(_voiceApp(transcriber: transcriber));
    await tester.tap(find.byKey(const Key('chat-voice-transcribe-44')));
    await tester.pump();

    await tester.tap(
      find.byKey(const Key('chat-voice-transcription-cancel-44')),
    );
    await tester.pump();
    expect(transcriber.cancelCalls, 1);
    expect(
      find.byKey(const Key('chat-voice-transcribing-44')),
      findsNothing,
    );

    transcriber.complete('Too late');
    await tester.pumpAndSettle();
    expect(find.text('Too late'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('account switch cancels and discards the old transcript', (
    tester,
  ) async {
    final transcriber = _ControlledTranscriber();
    late StateSetter setHarnessState;
    var account = _account;
    await tester.pumpWidget(
      ProviderScope(
        overrides: _voiceOverrides(transcriber),
        child: StatefulBuilder(
          builder: (context, setState) {
            setHarnessState = setState;
            return _voiceContent(account);
          },
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('chat-voice-transcribe-44')));
    await tester.pump();

    setHarnessState(() => account = _otherAccount);
    await tester.pump();
    expect(transcriber.cancelCalls, 1);

    transcriber.complete('Wrong account');
    await tester.pumpAndSettle();
    expect(find.text('Wrong account'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dispose cancels native transcription and ignores completion', (
    tester,
  ) async {
    final transcriber = _ControlledTranscriber();
    await tester.pumpWidget(_voiceApp(transcriber: transcriber));
    await tester.tap(find.byKey(const Key('chat-voice-transcribe-44')));
    await tester.pump();

    await tester.pumpWidget(const SizedBox.shrink());
    expect(transcriber.disposeCalls, 1);
    transcriber.complete('Disposed result');
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  for (final testCase in <(VoiceTranscriptionFailure, String)>[
    (
      VoiceTranscriptionFailure.denied,
      'Speech recognition permission was denied.',
    ),
    (
      VoiceTranscriptionFailure.restricted,
      'Speech recognition is restricted on this device.',
    ),
    (
      VoiceTranscriptionFailure.unavailable,
      'On-device speech recognition is unavailable.',
    ),
    (
      VoiceTranscriptionFailure.invalidFile,
      'This voice message cannot be transcribed.',
    ),
    (
      VoiceTranscriptionFailure.failed,
      'The voice message could not be transcribed.',
    ),
  ]) {
    testWidgets('${testCase.$1.name} has a localized transcription error', (
      tester,
    ) async {
      final transcriber = _ControlledTranscriber();
      await tester.pumpWidget(_voiceApp(transcriber: transcriber));
      await tester.tap(find.byKey(const Key('chat-voice-transcribe-44')));
      await tester.pump();
      transcriber.fail(testCase.$1);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('chat-voice-transcription-error-44')),
        findsOneWidget,
      );
      expect(find.text(testCase.$2), findsOneWidget);
      expect(find.byKey(const Key('chat-voice-transcribe-44')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

Widget _voiceApp({_ControlledTranscriber? transcriber}) {
  return ProviderScope(
    overrides: _voiceOverrides(transcriber),
    child: _voiceContent(_account),
  );
}

List<Override> _voiceOverrides(_ControlledTranscriber? transcriber) {
  return <Override>[
    chatVoiceTranscriberFactoryProvider.overrideWithValue(
      transcriber == null ? null : () => transcriber,
    ),
    chatVoiceFileProvider.overrideWith(
      (ref, key) async => const ChatVoiceFile(
        path: '/app-owned/voice-message.m4a',
        contentType: 'audio/mp4',
      ),
    ),
  ];
}

Widget _voiceContent(StoredAccount account) {
  return localizedTestApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 360,
          child: ChatMessageContent(
            key: const Key('message-content'),
            account: account,
            message: _voiceMessage,
            fallbackText: '',
            foregroundColor: Colors.black,
          ),
        ),
      ),
    ),
  );
}

final class _ControlledTranscriber implements VoiceTranscriber {
  Completer<String> _completion = Completer<String>();
  final List<String> paths = <String>[];
  final List<String?> locales = <String?>[];
  int cancelCalls = 0;
  int disposeCalls = 0;

  @override
  Future<String> transcribe({
    required String filePath,
    String? localeIdentifier,
    Duration timeout = const Duration(seconds: 60),
  }) {
    paths.add(filePath);
    locales.add(localeIdentifier);
    return _completion.future;
  }

  void complete(String text) => _completion.complete(text);

  void fail(VoiceTranscriptionFailure failure) {
    _completion.completeError(VoiceTranscriptionException(failure));
  }

  @override
  Future<void> cancel() async => cancelCalls++;

  @override
  Future<void> dispose() async => disposeCalls++;
}

const _account = StoredAccount(
  id: 'account-a',
  serverUrl: 'https://cloud.example.invalid',
  loginName: 'fixture-user',
  serverProductName: 'Nextcloud',
  talkFeaturesJson: '[]',
  selected: true,
  createdAtMillis: 1767225600000,
);

const _otherAccount = StoredAccount(
  id: 'account-b',
  serverUrl: 'https://other.example.invalid',
  loginName: 'other-user',
  serverProductName: 'Nextcloud',
  talkFeaturesJson: '[]',
  selected: false,
  createdAtMillis: 1767225601000,
);

final _voiceMessage = ChatMessage.fromJson(<String, Object?>{
  'id': 44,
  'token': 'rooma123',
  'actorType': 'users',
  'actorId': 'fixture-author',
  'actorDisplayName': 'Fixture author',
  'timestamp': 1767225720,
  'systemMessage': '',
  'messageType': 'voice-message',
  'isReplyable': true,
  'referenceId': 'reference-44',
  'message': '{file}',
  'messageParameters': <String, Object?>{
    'file': <String, Object?>{
      'type': 'file',
      'id': '12',
      'name': 'voice-message.m4a',
      'path': 'Talk/voice-message.m4a',
      'mimetype': 'audio/mp4',
      'link': 'https://cloud.example.invalid/index.php/f/12',
    },
  },
  'markdown': false,
  'reactions': <String, Object?>{},
  'reactionsSelf': <Object?>[],
  'deleted': null,
});
