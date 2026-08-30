import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/chat_media_repository.dart';
import 'package:nextcloudtalk/platform/media/voice_platform_adapters.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/chat/chat_message_content.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  testWidgets(
    'inline link has one semantic node, 48dp target, and 200% wrapping',
    (tester) async {
      final semantics = tester.ensureSemantics();

      await tester.pumpWidget(_app(TextScaler.noScaling));

      final link = find.descendant(
        of: find.byKey(const Key('message-content')),
        matching: find.byType(InkWell),
      );
      expect(link, findsOneWidget);
      final linkSize = tester.getSize(link);
      expect(linkSize.width, greaterThanOrEqualTo(48));
      expect(linkSize.height, greaterThanOrEqualTo(48));

      final linkSemantics = find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.link == true &&
            widget.properties.label == 'Open docs',
      );
      expect(linkSemantics, findsOneWidget);
      final semanticNode = tester.getSemantics(linkSemantics);
      expect(semanticNode.childrenCount, 0);
      expect(
        semanticNode,
        matchesSemantics(label: 'Open docs', isLink: true, hasTapAction: true),
      );

      await tester.pumpWidget(_app(const TextScaler.linear(2)));
      final contentSize = tester.getSize(
        find.byKey(const Key('message-content')),
      );
      expect(contentSize.width, lessThanOrEqualTo(160));
      expect(contentSize.height, greaterThan(linkSize.height));
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets('reply preview can be hidden without hiding the reply body', (
    tester,
  ) async {
    await tester.pumpWidget(_app(TextScaler.noScaling, message: _replyMessage));

    expect(find.byKey(const Key('chat-reply-preview-43')), findsOneWidget);
    expect(find.text('Reply body'), findsOneWidget);

    await tester.pumpWidget(
      _app(
        TextScaler.noScaling,
        message: _replyMessage,
        showReplyPreview: false,
      ),
    );

    expect(find.byKey(const Key('chat-reply-preview-43')), findsNothing);
    expect(find.text('Reply body'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a valid location is a scalable 48dp map link', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(const TextScaler.linear(2), message: _locationMessage),
    );

    final location = find.byWidgetPredicate(
      (widget) =>
          widget is Semantics &&
          widget.properties.link == true &&
          widget.properties.label == 'Open location: Eiffel Tower',
    );
    expect(location, findsOneWidget);
    expect(find.byIcon(Icons.location_on_outlined), findsOneWidget);
    expect(
      find.bySemanticsLabel('Open location: Eiffel Tower'),
      findsOneWidget,
    );
    final size = tester.getSize(location);
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('an invalid location remains inert', (tester) async {
    await tester.pumpWidget(
      _app(TextScaler.noScaling, message: _invalidLocationMessage),
    );

    expect(find.bySemanticsLabel('Open location: Invalid place'), findsNothing);
    expect(find.byIcon(Icons.attachment_rounded), findsOneWidget);
    expect(find.byType(InkWell), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a fully shaped deleted parent uses the deleted preview', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      _app(TextScaler.noScaling, message: _deletedParentReplyMessage),
    );

    expect(find.text('Message deleted'), findsOneWidget);
    expect(find.text('Fixture author'), findsNothing);
    expect(find.bySemanticsLabel('Message deleted'), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('a voice message exposes its length, position and seeking', (
    tester,
  ) async {
    final backend = _FakePlaybackBackend();
    addTearDown(backend.dispose);

    await tester.pumpWidget(
      _voiceApp(
        backend,
        const ChatVoiceFile(path: 'a.m4a', contentType: 'audio/mp4'),
      ),
    );

    expect(find.byKey(const Key('chat-voice-44')), findsOneWidget);
    expect(find.byKey(const Key('chat-voice-position-44')), findsNothing);

    await tester.tap(find.byKey(const Key('chat-voice-toggle-44')));
    await tester.pump();
    await tester.pump();
    expect(backend.playedPaths, hasLength(1));

    backend
      ..emitDuration(const Duration(seconds: 72))
      ..emitPosition(const Duration(seconds: 9));
    await tester.pump();

    expect(find.text('0:09 of 1:12'), findsOneWidget);
    final slider = tester.widget<Slider>(
      find.byKey(const Key('chat-voice-position-44')),
    );
    expect(slider.value, 9000);
    expect(slider.max, 72000);

    slider.onChanged!(30000);
    await tester.pump();
    expect(find.text('0:30 of 1:12'), findsOneWidget);
    slider.onChangeEnd!(30000);
    await tester.pump();
    expect(backend.seeks, <Duration>[const Duration(seconds: 30)]);

    await tester.tap(find.byKey(const Key('chat-voice-toggle-44')));
    await tester.pump();
    expect(backend.pauses, 1);

    await tester.tap(find.byKey(const Key('chat-voice-toggle-44')));
    await tester.pump();
    expect(backend.resumes, 1);
    expect(backend.playedPaths, hasLength(1));
  });
}

Widget _voiceApp(VoicePlaybackBackend backend, ChatVoiceFile file) {
  return ProviderScope(
    overrides: [
      chatVoicePlaybackBackendProvider.overrideWithValue(() => backend),
      chatVoiceFileProvider.overrideWith((ref, key) async => file),
    ],
    child: localizedTestApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 320,
            child: ChatMessageContent(
              key: const Key('message-content'),
              account: _account,
              message: _voiceMessage,
              fallbackText: '',
              foregroundColor: Colors.black,
            ),
          ),
        ),
      ),
    ),
  );
}

final class _FakePlaybackBackend implements VoicePlaybackBackend {
  final StreamController<void> _completed = StreamController<void>.broadcast();
  final StreamController<Duration> _position =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> _duration =
      StreamController<Duration>.broadcast();
  final List<String> playedPaths = <String>[];
  final List<Duration> seeks = <Duration>[];
  int pauses = 0;
  int resumes = 0;
  int stops = 0;
  bool _closed = false;

  @override
  Stream<void> get completed => _completed.stream;

  @override
  Stream<Duration> get positionChanged => _position.stream;

  @override
  Stream<Duration> get durationChanged => _duration.stream;

  void emitPosition(Duration value) => _position.add(value);

  void emitDuration(Duration value) => _duration.add(value);

  @override
  Future<void> playFile(String path, {required String mimeType}) async {
    playedPaths.add(path);
  }

  @override
  Future<void> pause() async => pauses++;

  @override
  Future<void> resume() async => resumes++;

  @override
  Future<void> seek(Duration position) async => seeks.add(position);

  @override
  Future<void> stop() async => stops++;

  @override
  Future<void> dispose() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _completed.close();
    await _position.close();
    await _duration.close();
  }
}

Widget _app(
  TextScaler textScaler, {
  ChatMessage? message,
  bool showReplyPreview = true,
}) {
  return localizedTestApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: MediaQuery(
          data: MediaQueryData(
            size: const Size(200, 400),
            textScaler: textScaler,
          ),
          child: SizedBox(
            width: 160,
            child: ChatMessageContent(
              key: const Key('message-content'),
              account: _account,
              message: message ?? _message,
              fallbackText: '',
              foregroundColor: Colors.black,
              showReplyPreview: showReplyPreview,
            ),
          ),
        ),
      ),
    ),
  );
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

final _message = ChatMessage.fromJson(<String, Object?>{
  'id': 42,
  'token': 'rooma123',
  'actorType': 'users',
  'actorId': 'fixture-author',
  'actorDisplayName': 'Fixture author',
  'timestamp': 1767225600,
  'systemMessage': '',
  'messageType': 'comment',
  'isReplyable': true,
  'referenceId': 'reference-42',
  'message': 'Before [Open docs](https://docs.example.invalid/guide) after',
  'messageParameters': <String, Object?>{},
  'markdown': true,
  'reactions': <String, Object?>{},
  'reactionsSelf': <Object?>[],
  'deleted': null,
});

final _replyMessage = ChatMessage.fromJson(<String, Object?>{
  'id': 43,
  'token': 'rooma123',
  'actorType': 'users',
  'actorId': 'fixture-replier',
  'actorDisplayName': 'Fixture replier',
  'timestamp': 1767225660,
  'systemMessage': '',
  'messageType': 'comment',
  'isReplyable': true,
  'referenceId': 'reference-43',
  'message': 'Reply body',
  'messageParameters': <String, Object?>{},
  'markdown': false,
  'reactions': <String, Object?>{},
  'reactionsSelf': <Object?>[],
  'deleted': null,
  'threadId': 42,
  'parent': _message.wire,
});

final _deletedParentReplyMessage = ChatMessage.fromJson(<String, Object?>{
  ..._replyMessage.wire,
  'parent': <String, Object?>{
    ..._message.wire,
    'message': '',
    'systemMessage': 'message_deleted',
    'deleted': true,
  },
});

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

final _locationMessage = ChatMessage.fromJson(<String, Object?>{
  ..._message.wire,
  'id': 45,
  'referenceId': 'reference-45',
  'message': '{object}',
  'messageParameters': <String, Object?>{
    'object': <String, Object?>{
      'type': 'geo-location',
      'id': 'geo:48.85837,2.29448',
      'name': 'Eiffel Tower',
      'latitude': '48.85837',
      'longitude': '2.29448',
    },
  },
});

final _invalidLocationMessage = ChatMessage.fromJson(<String, Object?>{
  ..._locationMessage.wire,
  'id': 46,
  'referenceId': 'reference-46',
  'messageParameters': <String, Object?>{
    'object': <String, Object?>{
      'type': 'geo-location',
      'id': 'geo:invalid',
      'name': 'Invalid place',
      'latitude': '91',
      'longitude': '2.29448',
    },
  },
});
