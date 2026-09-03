import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/chat_media_repository.dart';
import 'package:nextcloudtalk/platform/media/voice_platform_adapters.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/chat/chat_message_content.dart';
import 'package:nextcloudtalk/features/chat/poll_service.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  testWidgets('validated incoming poll opens the server-backed viewer', (
    tester,
  ) async {
    final sender = _ContentPollSender();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [pollServiceProvider.overrideWithValue(sender)],
        child: _app(TextScaler.noScaling, message: _pollMessage),
      ),
    );

    final action = find.byKey(const Key('open-poll-7'));
    expect(action, findsOneWidget);
    expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
    await tester.tap(action);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('poll-viewer-dialog')), findsOneWidget);
    expect(sender.loadedPollIds, [7]);
  });

  testWidgets('noncanonical poll rich object stays inert', (tester) async {
    await tester.pumpWidget(
      _app(TextScaler.noScaling, message: _invalidPollMessage),
    );

    expect(find.byKey(const Key('open-poll-7')), findsNothing);
    expect(find.text('Lunch?'), findsOneWidget);
  });

  testWidgets('a rich object with an https link opens as a link', (
    tester,
  ) async {
    // A Deck card shared into the room arrives as a generic object with the
    // card's own `link`; the pill has to be a link, not just a label.
    await tester.pumpWidget(_app(TextScaler.noScaling, message: _deckMessage));

    final pill = find.byKey(const Key('open-rich-object-object'));
    expect(pill, findsOneWidget);
    expect(find.text('Sprint board card'), findsOneWidget);
    expect(find.byIcon(Icons.open_in_new_rounded), findsOneWidget);
    expect(
      tester.getSemantics(pill),
      matchesSemantics(isLink: true, hasTapAction: true),
    );
  });

  testWidgets('a rich object whose link is not https stays a plain pill', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(TextScaler.noScaling, message: _plainObjectMessage),
    );

    expect(find.byKey(const Key('open-rich-object-object')), findsNothing);
    expect(find.text('Sprint board card'), findsOneWidget);
    expect(find.byIcon(Icons.attachment_rounded), findsOneWidget);
  });

  testWidgets('poll metadata detached from its placeholder stays inert', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(TextScaler.noScaling, message: _detachedPollMessage),
    );

    expect(find.byKey(const Key('open-poll-7')), findsNothing);
    expect(find.text('Lunch?'), findsOneWidget);
  });

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

  testWidgets('location preview stays local until explicit online opt-in', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final client = _RecordingTileClient.success();
    await tester.pumpWidget(
      _app(
        const TextScaler.linear(2),
        message: _locationMessage,
        tileClientFactory: (_) => client,
      ),
    );

    final location = find.byWidgetPredicate(
      (widget) =>
          widget is Semantics &&
          widget.properties.link == true &&
          widget.properties.label == 'Open location: Eiffel Tower',
    );
    expect(location, findsOneWidget);
    expect(find.byKey(const Key('chat-location-map-preview')), findsOneWidget);
    expect(find.byKey(const Key('chat-location-map-marker')), findsOneWidget);
    expect(
      find.bySemanticsLabel('Open location: Eiffel Tower'),
      findsOneWidget,
    );
    final size = tester.getSize(location);
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.width, lessThanOrEqualTo(240));
    expect(size.height, greaterThanOrEqualTo(120));
    expect(find.byType(CustomPaint), findsWidgets);
    expect(
      find.byKey(const Key('chat-location-online-opt-in')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Load online OpenStreetMap (shares coordinates)'),
      findsOneWidget,
    );
    expect(client.requests, isEmpty);
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('online location opt-in is trusted and bounded to four tiles', (
    tester,
  ) async {
    final client = _RecordingTileClient.success();
    await tester.pumpWidget(
      _app(
        TextScaler.noScaling,
        message: _locationMessage,
        tileClientFactory: (_) => client,
        mediaSize: const Size(400, 600),
        contentWidth: 320,
      ),
    );
    await tester.tap(find.byKey(const Key('chat-location-online-opt-in')));
    await tester.pump();
    await tester.runAsync(() async {
      for (var attempt = 0; attempt < 100 && !client.closed; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    });
    await tester.pump();

    expect(client.requests, isNotEmpty);
    expect(client.requests.length, lessThanOrEqualTo(4));
    expect(client.maximumActiveRequests, lessThanOrEqualTo(2));
    expect(
      client.closed,
      isTrue,
      reason:
          'requests=${client.requests.length}, active=${client.activeRequests}',
    );
    for (final request in client.requests) {
      expect(request.url.scheme, 'https');
      expect(request.url.host, 'tile.openstreetmap.org');
      expect(request.url.query, isEmpty);
      expect(request.followRedirects, isFalse);
      expect(request.maxRedirects, 0);
      expect(
        request.headers['User-Agent'],
        contains('com.nkshub.nextcloudtalk'),
      );
    }

    final tileImages = tester.widgetList<Image>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Image &&
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'chat-location-tile-',
            ),
      ),
    );
    expect(tileImages, isNotEmpty);
    expect(tileImages.length, lessThanOrEqualTo(4));
    for (final image in tileImages) {
      final resized = image.image as ResizeImage;
      expect(resized.width, 256);
      expect(resized.height, 256);
      expect(resized.imageProvider, isA<MemoryImage>());
    }

    final attribution = find.bySemanticsLabel('© OpenStreetMap contributors');
    expect(attribution, findsOneWidget);
    expect(
      tester
          .getSize(find.byKey(const Key('chat-location-map-attribution')))
          .height,
      greaterThanOrEqualTo(48),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('account switch closes loader and discards late tile results', (
    tester,
  ) async {
    final oldClient = _RecordingTileClient.delayed();
    final newClient = _RecordingTileClient.success();
    final clients = <String, _RecordingTileClient>{
      _account.id: oldClient,
      _otherAccount.id: newClient,
    };
    await tester.pumpWidget(
      _app(
        TextScaler.noScaling,
        message: _locationMessage,
        tileClientFactory: (accountId) => clients[accountId]!,
      ),
    );
    await tester.tap(find.byKey(const Key('chat-location-online-opt-in')));
    await tester.pump();
    expect(oldClient.requests, isNotEmpty);
    expect(oldClient.requests.length, lessThanOrEqualTo(2));

    await tester.pumpWidget(
      _app(
        TextScaler.noScaling,
        account: _otherAccount,
        message: _locationMessage,
        tileClientFactory: (accountId) => clients[accountId]!,
      ),
    );
    expect(oldClient.closed, isTrue);
    oldClient.completePendingSuccessfully();
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsNothing);
    expect(
      find.byKey(const Key('chat-location-online-opt-in')),
      findsOneWidget,
    );
    expect(newClient.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposing location preview closes and invalidates its loader', (
    tester,
  ) async {
    final client = _RecordingTileClient.delayed();
    await tester.pumpWidget(
      _app(
        TextScaler.noScaling,
        message: _locationMessage,
        tileClientFactory: (_) => client,
      ),
    );
    await tester.tap(find.byKey(const Key('chat-location-online-opt-in')));
    await tester.pump();
    expect(client.requests, isNotEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(client.closed, isTrue);
    client.completePendingSuccessfully();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  for (final failure in <_TileFailure>[
    _TileFailure.oversized,
    _TileFailure.redirect,
    _TileFailure.serverError,
  ]) {
    testWidgets('location ${failure.name} response keeps local fallback', (
      tester,
    ) async {
      final client = _RecordingTileClient.failure(failure);
      await tester.pumpWidget(
        _app(
          TextScaler.noScaling,
          message: _locationMessage,
          tileClientFactory: (_) => client,
        ),
      );
      await tester.tap(find.byKey(const Key('chat-location-online-opt-in')));
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsNothing);
      expect(find.byKey(const Key('chat-location-map-marker')), findsOneWidget);
      expect(find.text('The image could not be loaded.'), findsOneWidget);
      expect(
        find.byKey(const Key('chat-location-online-opt-in')),
        findsOneWidget,
      );
      expect(client.requests.length, lessThanOrEqualTo(4));
      expect(client.closed, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('an invalid location remains inert', (tester) async {
    await tester.pumpWidget(
      _app(TextScaler.noScaling, message: _invalidLocationMessage),
    );

    expect(find.bySemanticsLabel('Open location: Invalid place'), findsNothing);
    expect(find.byIcon(Icons.attachment_rounded), findsOneWidget);
    expect(find.byType(InkWell), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a vCard attachment is a scalable contact action', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(const TextScaler.linear(2), message: _contactMessage),
    );

    final contact = find.byKey(const Key('chat-open-contact-47-0'));
    expect(contact, findsOneWidget);
    expect(find.byIcon(Icons.contact_page_outlined), findsOneWidget);
    expect(find.text('Contact'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Open contact: Alice Example.vcf'),
      findsOneWidget,
    );
    final semanticContact = find.byWidgetPredicate(
      (widget) =>
          widget is Semantics &&
          widget.properties.label == 'Open contact: Alice Example.vcf',
    );
    expect(
      tester.getSemantics(semanticContact),
      matchesSemantics(
        label: 'Open contact: Alice Example.vcf',
        isButton: true,
        hasTapAction: true,
      ),
    );
    final size = tester.getSize(contact);
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('a .vcf with a generic MIME type still renders as a contact', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(TextScaler.noScaling, message: _genericMimeContactMessage),
    );

    expect(find.byIcon(Icons.contact_page_outlined), findsOneWidget);
    expect(find.byKey(const Key('chat-open-contact-48-0')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a display name cannot forge a generic vCard attachment', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(TextScaler.noScaling, message: _forgedNameContactMessage),
    );

    expect(find.byIcon(Icons.contact_page_outlined), findsNothing);
    expect(find.byIcon(Icons.insert_drive_file_rounded), findsOneWidget);
    expect(find.byKey(const Key('chat-open-contact-49-0')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a .vcf path with an unrelated MIME remains a file', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(TextScaler.noScaling, message: _wrongMimeContactMessage),
    );

    expect(find.byIcon(Icons.contact_page_outlined), findsNothing);
    expect(find.byIcon(Icons.insert_drive_file_rounded), findsOneWidget);
    expect(find.byKey(const Key('chat-open-contact-50-0')), findsNothing);
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

enum _TileFailure { oversized, redirect, serverError }

final class _RecordingTileClient extends http.BaseClient {
  _RecordingTileClient._(this._responseFactory, {required this.delayed});

  factory _RecordingTileClient.success() =>
      _RecordingTileClient._((_) => _tileResponse(), delayed: false);

  factory _RecordingTileClient.delayed() =>
      _RecordingTileClient._((_) => _tileResponse(), delayed: true);

  factory _RecordingTileClient.failure(_TileFailure failure) =>
      _RecordingTileClient._(
        (_) => switch (failure) {
          _TileFailure.oversized => _tileResponse(
            contentLength: 256 * 1024 + 1,
          ),
          _TileFailure.redirect => _tileResponse(
            statusCode: 302,
            headers: const <String, String>{
              'content-type': 'image/png',
              'location': 'https://attacker.example.invalid/tile.png',
            },
          ),
          _TileFailure.serverError => _tileResponse(statusCode: 503),
        },
        delayed: false,
      );

  final http.StreamedResponse Function(http.Request request) _responseFactory;
  final bool delayed;
  final List<http.Request> requests = <http.Request>[];
  final List<Completer<http.StreamedResponse>> _pending =
      <Completer<http.StreamedResponse>>[];
  var activeRequests = 0;
  var maximumActiveRequests = 0;
  var closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (closed) {
      throw StateError('Client is closed');
    }
    final recorded = request as http.Request;
    requests.add(recorded);
    activeRequests++;
    if (activeRequests > maximumActiveRequests) {
      maximumActiveRequests = activeRequests;
    }
    try {
      if (!delayed) {
        await Future<void>.value();
        return _responseFactory(recorded);
      }
      final completion = Completer<http.StreamedResponse>();
      _pending.add(completion);
      return await completion.future;
    } finally {
      activeRequests--;
    }
  }

  void completePendingSuccessfully() {
    for (final completion in List.of(_pending)) {
      if (!completion.isCompleted) {
        completion.complete(_tileResponse());
      }
    }
    _pending.clear();
  }

  @override
  void close() {
    closed = true;
  }
}

http.StreamedResponse _tileResponse({
  int statusCode = 200,
  int? contentLength,
  Map<String, String> headers = const <String, String>{
    'content-type': 'image/png',
  },
}) {
  final bytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+'
    'A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );
  return http.StreamedResponse(
    Stream<List<int>>.value(bytes),
    statusCode,
    headers: headers,
    contentLength: contentLength ?? bytes.length,
  );
}

Widget _app(
  TextScaler textScaler, {
  StoredAccount account = _account,
  ChatMessage? message,
  bool showReplyPreview = true,
  LocationTileClientFactory tileClientFactory = _defaultTileClientFactory,
  Size mediaSize = const Size(200, 400),
  double contentWidth = 160,
}) {
  return localizedTestApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: MediaQuery(
          data: MediaQueryData(size: mediaSize, textScaler: textScaler),
          child: SizedBox(
            width: contentWidth,
            child: ChatMessageContent(
              key: const Key('message-content'),
              account: account,
              message: message ?? _message,
              fallbackText: '',
              foregroundColor: Colors.black,
              showReplyPreview: showReplyPreview,
              locationTileClientFactory: tileClientFactory,
            ),
          ),
        ),
      ),
    ),
  );
}

http.Client _defaultTileClientFactory(String accountId) =>
    _RecordingTileClient.failure(_TileFailure.serverError);

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
      'link': 'https://attacker.example.invalid/forged-map.png',
    },
  },
});

final _deckMessage = ChatMessage.fromJson(<String, Object?>{
  ..._message.wire,
  'id': 46,
  'referenceId': 'reference-46',
  'message': '{object}',
  'messageParameters': <String, Object?>{
    'object': <String, Object?>{
      'type': 'deck-card',
      'id': '4242',
      'name': 'Sprint board card',
      'boardname': 'Sprint',
      'stackname': 'To do',
      'link': 'https://cloud.example.invalid/apps/deck/board/1/card/4242',
    },
  },
});

final _plainObjectMessage = ChatMessage.fromJson(<String, Object?>{
  ..._message.wire,
  'id': 47,
  'referenceId': 'reference-47',
  'message': '{object}',
  'messageParameters': <String, Object?>{
    'object': <String, Object?>{
      'type': 'deck-card',
      'id': '4242',
      'name': 'Sprint board card',
      'boardname': 'Sprint',
      'stackname': 'To do',
      'link': 'http://cloud.example.invalid/apps/deck/board/1/card/4242',
    },
  },
});

final _pollMessage = ChatMessage.fromJson(<String, Object?>{
  ..._message.wire,
  'id': 50,
  'referenceId': 'reference-50',
  'systemMessage': '',
  'message': '{object}',
  'messageParameters': <String, Object?>{
    'object': <String, Object?>{
      'type': 'talk-poll',
      'id': '7',
      'name': 'Lunch?',
    },
  },
});

final _detachedPollMessage = ChatMessage.fromJson(<String, Object?>{
  ..._pollMessage.wire,
  'id': 52,
  'referenceId': 'reference-52',
  'message': 'Lunch?',
});

final _invalidPollMessage = ChatMessage.fromJson(<String, Object?>{
  ..._pollMessage.wire,
  'id': 51,
  'referenceId': 'reference-51',
  'messageParameters': <String, Object?>{
    'object': <String, Object?>{
      'type': 'talk-poll',
      'id': '07',
      'name': 'Lunch?',
    },
  },
});

final class _ContentPollSender implements PollSender {
  final List<int> loadedPollIds = [];

  @override
  Future<bool> isAvailable(PollRoomKey key) async => true;

  @override
  Future<TalkPoll> create({
    required PollRoomKey key,
    required String question,
    required List<String> options,
    required PollResultMode resultMode,
    required int maxVotes,
  }) => throw UnimplementedError();

  @override
  Future<TalkPoll> load({required PollRoomKey key, required int pollId}) async {
    loadedPollIds.add(pollId);
    return TalkPoll.fromJson({
      'id': pollId,
      'question': 'Lunch?',
      'options': ['Pizza', 'Salad'],
      'actorType': 'users',
      'actorId': 'user-a',
      'actorDisplayName': 'User A',
      'status': 0,
      'resultMode': 0,
      'maxVotes': 1,
      'votedSelf': <int>[],
      'votes': <Object?>[],
      'numVoters': 0,
    });
  }

  @override
  Future<TalkPoll> vote({
    required PollRoomKey key,
    required TalkPoll poll,
    required List<int> optionIds,
  }) => throw UnimplementedError();
}

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

final _contactMessage = ChatMessage.fromJson(<String, Object?>{
  ..._message.wire,
  'id': 47,
  'referenceId': 'reference-47',
  'message': '{file}',
  'messageParameters': <String, Object?>{
    'file': <String, Object?>{
      'type': 'file',
      'id': '47',
      'name': 'Alice Example.vcf',
      'path': 'Talk/contact-data.bin',
      'mimetype': 'text/vcard',
    },
  },
});

final _genericMimeContactMessage = ChatMessage.fromJson(<String, Object?>{
  ..._contactMessage.wire,
  'id': 48,
  'referenceId': 'reference-48',
  'messageParameters': <String, Object?>{
    'file': <String, Object?>{
      'id': '48',
      'type': 'file',
      'name': 'Alice Example',
      'path': 'Talk/Alice Example.vcf',
      'mimetype': 'application/octet-stream',
    },
  },
});

final _forgedNameContactMessage = ChatMessage.fromJson(<String, Object?>{
  ..._contactMessage.wire,
  'id': 49,
  'referenceId': 'reference-49',
  'messageParameters': <String, Object?>{
    'file': <String, Object?>{
      'id': '49',
      'type': 'file',
      'name': 'Forged.vcf',
      'path': 'Talk/payload.bin',
      'mimetype': 'application/octet-stream',
    },
  },
});

final _wrongMimeContactMessage = ChatMessage.fromJson(<String, Object?>{
  ..._contactMessage.wire,
  'id': 50,
  'referenceId': 'reference-50',
  'messageParameters': <String, Object?>{
    'file': <String, Object?>{
      'id': '50',
      'type': 'file',
      'name': 'Document.pdf',
      'path': 'Talk/Document.vcf',
      'mimetype': 'application/pdf',
    },
  },
});
