import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

import 'support/signaling_test_support.dart';

void main() {
  test(
    'internal signaling executes a real pull and batch POST',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = StreamIterator<HttpRequest>(server);
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await requests.cancel();
        await server.close(force: true);
      });

      final localServer = ServerBase.parse(
        'http://${InternetAddress.loopbackIPv4.address}:${server.port}/nextcloud',
        policy: ServerOriginPolicy.debug,
      );
      final authority = signalingAuthority(server: localServer);
      var snapshot = _configuredSnapshot(
        authority: authority,
        settingsData: signalingSettingsData(mode: 'internal'),
      );

      final pull = planInternalSignalingPull(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        requestId: signalingRequestId(800),
      );
      snapshot = commitSignaling(snapshot, pull);
      final pullRequest = pull.request! as InternalSignalingPullRequest;
      final pullResponseFuture = _executeHttp(client, pullRequest);

      expect(await requests.moveNext(), isTrue);
      final incomingPull = requests.current;
      _expectInternalRequest(incomingPull, method: 'GET');
      _writeOcsResponse(incomingPull.response, <Object?>[
        <String, Object?>{
          'type': 'message',
          'data': jsonEncode(<String, Object?>{
            'type': 'offer',
            'roomType': 'video',
            'sid': 'network-stream-a',
            'from': 'network-peer-a',
            'payload': <String, Object?>{'sdp': 'synthetic-network-sdp'},
          }),
        },
        <String, Object?>{
          'type': 'usersInRoom',
          'data': <Object?>[
            <String, Object?>{
              'sessionId': 'network-peer-a',
              'roomId': 42,
              'lastPing': 100,
              'userId': 'network-user-a',
              'inCall': 3,
              'participantPermissions': 7,
              'actorType': 'users',
              'actorId': 'network-user-a',
            },
          ],
        },
      ]);
      final pullWireResponse = await pullResponseFuture;
      final decodedPull = decodeInternalSignalingPullResponse(
        request: pullRequest,
        statusCode: pullWireResponse.statusCode,
        body: pullWireResponse.body,
      );
      final appliedPull = applyInternalSignalingPullResponse(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        response: decodedPull,
      );
      snapshot = commitSignaling(snapshot, appliedPull);

      expect(appliedPull.outcome, SignalingRuntimeOutcome.messagesReceived);
      expect(appliedPull.messages, hasLength(1));
      expect(
        snapshot.accounts[signalingAccountA]!.participants.keys.single.value,
        'network-peer-a',
      );

      final batch = planInternalSignalingBatch(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        requestId: signalingRequestId(801),
        messages: <SignalingPeerMessage>[signalingMessage()],
      );
      snapshot = commitSignaling(snapshot, batch);
      final batchRequest = batch.request! as InternalSignalingBatchRequest;
      final batchResponseFuture = _executeHttp(client, batchRequest);

      expect(await requests.moveNext(), isTrue);
      final incomingBatch = requests.current;
      _expectInternalRequest(incomingBatch, method: 'POST');
      final form = Uri.splitQueryString(
        await utf8.decoder.bind(incomingBatch).join(),
      );
      final messages = jsonDecode(form['messages']!) as List<Object?>;
      expect(messages, hasLength(1));
      final envelope = messages.single! as Map<String, Object?>;
      expect(envelope['ev'], 'message');
      expect(envelope['sessionId'], signalingSessionA.value);
      final frame =
          jsonDecode(envelope['fn']! as String) as Map<String, Object?>;
      expect(frame['type'], 'offer');
      expect(frame['to'], 'peer-b');
      _writeOcsResponse(incomingBatch.response, const <Object?>[]);

      final batchWireResponse = await batchResponseFuture;
      final decodedBatch = decodeInternalSignalingBatchResponse(
        request: batchRequest,
        statusCode: batchWireResponse.statusCode,
        body: batchWireResponse.body,
      );
      final appliedBatch = applyInternalSignalingBatchResponse(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        response: decodedBatch,
      );
      snapshot = commitSignaling(snapshot, appliedBatch);

      expect(
        appliedBatch.outcome,
        SignalingRuntimeOutcome.internalBatchAccepted,
      );
      expect(
        snapshot.accounts[signalingAccountA]!.pendingInternalBatch,
        isNull,
      );
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );

  test(
    'HPB executes welcome, V2 hello, room join, disconnect, and resume',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = StreamIterator<HttpRequest>(server);
      addTearDown(() async {
        await requests.cancel();
        await server.close(force: true);
      });
      final authority = signalingAuthority();
      var snapshot = _configuredSnapshot(
        authority: authority,
        settingsData: signalingSettingsData(
          endpoint:
              'http://${InternetAddress.loopbackIPv4.address}:${server.port}',
        ),
        endpointPolicy: SignalingEndpointPolicy.debug,
      );

      final initial = await _executeFullHpbHandshake(
        snapshot: snapshot,
        authority: authority,
        requests: requests,
        nowMicros: 1000,
        idBase: 900,
        sessionId: 'network-hpb-session-a',
        resumeId: 'network-hpb-resume-a',
      );
      snapshot = initial.snapshot;
      expect(initial.hello['auth'], <String, Object?>{
        'url':
            'https://cloud.example.invalid/nextcloud/ocs/v2.php/apps/spreed/api/v3/signaling/backend',
        'params': <String, Object?>{'token': 'synthetic-token-a'},
      });
      expect(initial.room['roomid'], signalingRoomA.value);

      await initial.pair.server.close(
        WebSocketStatus.goingAway,
        'synthetic network transition',
      );
      await _expectRemoteClose(initial.pair.clientEvents);
      await initial.pair.cancel();

      final disconnected = recordHpbDisconnect(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        connectionEpoch: 1,
        nowMicros: 2000,
        jitterUnit: 0,
        deadlineEffectId: signalingEffectId(904),
      );
      snapshot = commitSignaling(snapshot, disconnected);
      final reconnectDeadline =
          disconnected.effects.single as ScheduleSignalingDeadlineEffect;

      final resumed = await _executeHpbResume(
        snapshot: snapshot,
        authority: authority,
        requests: requests,
        nowMicros: reconnectDeadline.deadlineMicros,
        completedDeadline: reconnectDeadline,
        idBase: 910,
        sessionId: 'network-hpb-session-a',
      );
      snapshot = resumed.snapshot;

      expect(resumed.hello['resumeid'], 'network-hpb-resume-a');
      expect(resumed.hello.containsKey('auth'), isFalse);
      expect(
        snapshot.accounts[signalingAccountA]!.phase,
        SignalingAccountPhase.signalingReady,
      );
      expect(snapshot.accounts[signalingAccountA]!.roomConfirmed, isTrue);
      expect(snapshot.accounts[signalingAccountA]!.connectionEpoch, 2);

      await resumed.pair.server.close();
      await _expectRemoteClose(resumed.pair.clientEvents);
      await resumed.pair.cancel();
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );

  test(
    'HPB resume expiry performs a new full hello and room join',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = StreamIterator<HttpRequest>(server);
      addTearDown(() async {
        await requests.cancel();
        await server.close(force: true);
      });
      final authority = signalingAuthority();
      var snapshot = _configuredSnapshot(
        authority: authority,
        settingsData: signalingSettingsData(
          endpoint:
              'http://${InternetAddress.loopbackIPv4.address}:${server.port}',
        ),
        endpointPolicy: SignalingEndpointPolicy.debug,
      );

      final initial = await _executeFullHpbHandshake(
        snapshot: snapshot,
        authority: authority,
        requests: requests,
        nowMicros: 10000,
        idBase: 920,
        sessionId: 'network-hpb-session-old',
        resumeId: 'network-hpb-resume-old',
      );
      snapshot = initial.snapshot;
      await initial.pair.server.close();
      await _expectRemoteClose(initial.pair.clientEvents);
      await initial.pair.cancel();

      final disconnected = recordHpbDisconnect(
        snapshot,
        accountId: signalingAccountA,
        authority: authority,
        connectionEpoch: 1,
        nowMicros: 20000,
        jitterUnit: 0,
        deadlineEffectId: signalingEffectId(924),
      );
      snapshot = commitSignaling(snapshot, disconnected);
      final reconnectDeadline =
          disconnected.effects.single as ScheduleSignalingDeadlineEffect;
      final reconnectAfterExpiry =
          snapshot.accounts[signalingAccountA]!.resumeDeadlineMicros!;

      final renewed = await _executeFullHpbHandshake(
        snapshot: snapshot,
        authority: authority,
        requests: requests,
        nowMicros: reconnectAfterExpiry,
        completedDeadline: reconnectDeadline,
        idBase: 930,
        sessionId: 'network-hpb-session-new',
        resumeId: 'network-hpb-resume-new',
      );
      snapshot = renewed.snapshot;

      expect(renewed.hello.containsKey('resumeid'), isFalse);
      expect(
        (renewed.hello['auth']! as Map<String, Object?>)['params'],
        <String, Object?>{'token': 'synthetic-token-a'},
      );
      expect(renewed.room['roomid'], signalingRoomA.value);
      expect(
        snapshot.accounts[signalingAccountA]!.hpbSessionId!.value,
        'network-hpb-session-new',
      );
      expect(snapshot.accounts[signalingAccountA]!.connectionEpoch, 2);
      expect(snapshot.accounts[signalingAccountA]!.roomEpoch, 3);

      await renewed.pair.server.close();
      await _expectRemoteClose(renewed.pair.clientEvents);
      await renewed.pair.cancel();
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );
}

SignalingRuntimeSnapshot _configuredSnapshot({
  required SignalingAuthority authority,
  required Map<String, Object?> settingsData,
  SignalingEndpointPolicy endpointPolicy = SignalingEndpointPolicy.production,
}) {
  var snapshot = emptySignalingSnapshot();
  snapshot = commitSignaling(
    snapshot,
    addSignalingAccount(snapshot, authority: authority),
  );
  final fetch = planSignalingSettingsFetch(
    snapshot,
    accountId: signalingAccountA,
    authority: authority,
    requestId: signalingRequestId(799),
  );
  snapshot = commitSignaling(snapshot, fetch);
  final response = decodeSignalingSettingsResponse(
    request: fetch.request! as SignalingSettingsRequest,
    statusCode: 200,
    body: signalingOcsBody(statusCode: 200, data: settingsData),
    endpointPolicy: endpointPolicy,
  );
  return commitSignaling(
    snapshot,
    applySignalingSettingsResponse(
      snapshot,
      accountId: signalingAccountA,
      authority: authority,
      response: response,
    ),
  );
}

Future<
  ({
    SignalingRuntimeSnapshot snapshot,
    _SocketPair pair,
    Map<String, Object?> hello,
    Map<String, Object?> room,
  })
>
_executeFullHpbHandshake({
  required SignalingRuntimeSnapshot snapshot,
  required SignalingAuthority authority,
  required StreamIterator<HttpRequest> requests,
  required int nowMicros,
  required int idBase,
  required String sessionId,
  required String resumeId,
  ScheduleSignalingDeadlineEffect? completedDeadline,
}) async {
  final connect = planSignalingConnect(
    snapshot,
    accountId: signalingAccountA,
    authority: authority,
    nowMicros: nowMicros,
    effectId: signalingEffectId(idBase),
    completedDeadline: completedDeadline,
  );
  snapshot = commitSignaling(snapshot, connect);
  final openEffect = connect.effects.single as OpenHpbSocketEffect;
  final pair = await _openSocket(requests, openEffect.endpoint.socketUri);
  final opened = completeHpbSocketOpen(
    snapshot,
    accountId: signalingAccountA,
    authority: authority,
    effect: openEffect,
    deadlineEffectId: signalingEffectId(idBase + 1),
    nowMicros: nowMicros + 100,
  );
  snapshot = commitSignaling(snapshot, opened);

  _sendJson(pair.server, <String, Object?>{
    'type': 'welcome',
    'welcome': <String, Object?>{
      'features': <Object?>['hello-v2', 'mcu', 'federation'],
    },
  });
  final welcomed = applyHpbServerFrame(
    snapshot,
    accountId: signalingAccountA,
    authority: authority,
    connectionEpoch: openEffect.context.connectionEpoch,
    roomEpoch: snapshot.accounts[signalingAccountA]!.roomEpoch,
    frame: HpbServerFrame.decode(await _nextText(pair.clientEvents)),
    nowMicros: nowMicros + 200,
    nextRequestId: signalingRequestId(idBase + 2),
    sendEffectId: signalingEffectId(idBase + 2),
  );
  snapshot = commitSignaling(snapshot, welcomed);
  final helloEffect = welcomed.effects.single as SendHpbFrameEffect;
  _sendText(pair.client, helloEffect.frame.encode());
  snapshot = commitSignaling(
    snapshot,
    completeHpbFrameSend(
      snapshot,
      accountId: signalingAccountA,
      authority: authority,
      effect: helloEffect,
    ),
  );
  final helloWire = await _nextJson(pair.serverEvents);
  final hello = helloWire['hello']! as Map<String, Object?>;
  expect(hello['version'], '2.0');
  expect(hello.containsKey('resumeid'), isFalse);

  _sendJson(pair.server, <String, Object?>{
    'id': helloWire['id'],
    'type': 'hello',
    'hello': <String, Object?>{
      'version': '2.0',
      'sessionid': sessionId,
      'resumeid': resumeId,
    },
  });
  final helloResponse = applyHpbServerFrame(
    snapshot,
    accountId: signalingAccountA,
    authority: authority,
    connectionEpoch: openEffect.context.connectionEpoch,
    roomEpoch: snapshot.accounts[signalingAccountA]!.roomEpoch,
    frame: HpbServerFrame.decode(await _nextText(pair.clientEvents)),
    nowMicros: nowMicros + 300,
    nextRequestId: signalingRequestId(idBase + 3),
    sendEffectId: signalingEffectId(idBase + 3),
  );
  snapshot = commitSignaling(snapshot, helloResponse);
  final roomEffect = helloResponse.effects.single as SendHpbFrameEffect;
  _sendText(pair.client, roomEffect.frame.encode());
  snapshot = commitSignaling(
    snapshot,
    completeHpbFrameSend(
      snapshot,
      accountId: signalingAccountA,
      authority: authority,
      effect: roomEffect,
    ),
  );
  final roomWire = await _nextJson(pair.serverEvents);
  final room = roomWire['room']! as Map<String, Object?>;

  _sendJson(pair.server, <String, Object?>{
    'id': roomWire['id'],
    'type': 'room',
    'room': <String, Object?>{'roomid': room['roomid']},
  });
  final roomResponse = applyHpbServerFrame(
    snapshot,
    accountId: signalingAccountA,
    authority: authority,
    connectionEpoch: openEffect.context.connectionEpoch,
    roomEpoch: snapshot.accounts[signalingAccountA]!.roomEpoch,
    frame: HpbServerFrame.decode(await _nextText(pair.clientEvents)),
    nowMicros: nowMicros + 400,
  );
  snapshot = commitSignaling(snapshot, roomResponse);

  expect(roomResponse.outcome, SignalingRuntimeOutcome.signalingReady);
  return (snapshot: snapshot, pair: pair, hello: hello, room: room);
}

Future<
  ({
    SignalingRuntimeSnapshot snapshot,
    _SocketPair pair,
    Map<String, Object?> hello,
  })
>
_executeHpbResume({
  required SignalingRuntimeSnapshot snapshot,
  required SignalingAuthority authority,
  required StreamIterator<HttpRequest> requests,
  required int nowMicros,
  required ScheduleSignalingDeadlineEffect completedDeadline,
  required int idBase,
  required String sessionId,
}) async {
  final connect = planSignalingConnect(
    snapshot,
    accountId: signalingAccountA,
    authority: authority,
    nowMicros: nowMicros,
    effectId: signalingEffectId(idBase),
    completedDeadline: completedDeadline,
  );
  snapshot = commitSignaling(snapshot, connect);
  final openEffect = connect.effects.single as OpenHpbSocketEffect;
  final pair = await _openSocket(requests, openEffect.endpoint.socketUri);
  final opened = completeHpbSocketOpen(
    snapshot,
    accountId: signalingAccountA,
    authority: authority,
    effect: openEffect,
    deadlineEffectId: signalingEffectId(idBase + 1),
    nowMicros: nowMicros + 100,
  );
  snapshot = commitSignaling(snapshot, opened);

  _sendJson(pair.server, <String, Object?>{
    'type': 'welcome',
    'welcome': <String, Object?>{
      'features': <Object?>['hello-v2', 'mcu', 'federation'],
    },
  });
  final welcomed = applyHpbServerFrame(
    snapshot,
    accountId: signalingAccountA,
    authority: authority,
    connectionEpoch: openEffect.context.connectionEpoch,
    roomEpoch: snapshot.accounts[signalingAccountA]!.roomEpoch,
    frame: HpbServerFrame.decode(await _nextText(pair.clientEvents)),
    nowMicros: nowMicros + 200,
    nextRequestId: signalingRequestId(idBase + 2),
    sendEffectId: signalingEffectId(idBase + 2),
  );
  snapshot = commitSignaling(snapshot, welcomed);
  final helloEffect = welcomed.effects.single as SendHpbFrameEffect;
  _sendText(pair.client, helloEffect.frame.encode());
  snapshot = commitSignaling(
    snapshot,
    completeHpbFrameSend(
      snapshot,
      accountId: signalingAccountA,
      authority: authority,
      effect: helloEffect,
    ),
  );
  final helloWire = await _nextJson(pair.serverEvents);
  final hello = helloWire['hello']! as Map<String, Object?>;

  _sendJson(pair.server, <String, Object?>{
    'id': helloWire['id'],
    'type': 'hello',
    'hello': <String, Object?>{'version': '2.0', 'sessionid': sessionId},
  });
  final resumed = applyHpbServerFrame(
    snapshot,
    accountId: signalingAccountA,
    authority: authority,
    connectionEpoch: openEffect.context.connectionEpoch,
    roomEpoch: snapshot.accounts[signalingAccountA]!.roomEpoch,
    frame: HpbServerFrame.decode(await _nextText(pair.clientEvents)),
    nowMicros: nowMicros + 300,
  );
  snapshot = commitSignaling(snapshot, resumed);

  expect(resumed.outcome, SignalingRuntimeOutcome.resumed);
  return (snapshot: snapshot, pair: pair, hello: hello);
}

void _expectInternalRequest(HttpRequest request, {required String method}) {
  expect(request.method, method);
  expect(
    request.uri.path,
    '/nextcloud/ocs/v2.php/apps/spreed/api/v3/signaling/rooma123',
  );
  expect(request.uri.queryParameters, <String, String>{'format': 'json'});
  expect(request.headers.value('ocs-apirequest'), 'true');
  expect(
    request.headers.value(HttpHeaders.userAgentHeader),
    signalingContractUserAgent,
  );
}

void _writeOcsResponse(HttpResponse response, Object? data) {
  response.statusCode = HttpStatus.ok;
  response.headers.contentType = ContentType.json;
  response.write(
    jsonEncode(<String, Object?>{
      'ocs': <String, Object?>{
        'meta': <String, Object?>{
          'status': 'ok',
          'statuscode': 200,
          'message': 'OK',
        },
        'data': data,
      },
    }),
  );
  unawaited(response.close());
}

Future<_HttpWireResponse> _executeHttp(
  HttpClient client,
  SignalingHttpRequest request,
) async {
  final outgoing = await client.openUrl(
    request.method.name.toUpperCase(),
    request.uri,
  );
  request.headers.forEach(outgoing.headers.set);
  final fields = request.formFields;
  if (fields != null) {
    outgoing.write(Uri(queryParameters: fields).query);
  }
  final response = await outgoing.close();
  final body = await response.fold<List<int>>(<int>[], (bytes, chunk) {
    bytes.addAll(chunk);
    return bytes;
  });
  return _HttpWireResponse(
    statusCode: response.statusCode,
    body: Uint8List.fromList(body),
  );
}

Future<_SocketPair> _openSocket(
  StreamIterator<HttpRequest> requests,
  Uri uri,
) async {
  final accepted = _acceptSocket(requests);
  final client = await WebSocket.connect(uri.toString());
  final server = await accepted;
  return _SocketPair(client: client, server: server);
}

Future<WebSocket> _acceptSocket(StreamIterator<HttpRequest> requests) async {
  if (!await requests.moveNext()) {
    throw StateError(
      'The local HPB server stopped before the upgrade request.',
    );
  }
  final request = requests.current;
  expect(request.uri.path, '/spreed');
  expect(WebSocketTransformer.isUpgradeRequest(request), isTrue);
  return WebSocketTransformer.upgrade(request);
}

void _sendJson(WebSocket socket, Map<String, Object?> value) =>
    _sendText(socket, jsonEncode(value));

void _sendText(WebSocket socket, String value) => socket.add(value);

Future<Map<String, Object?>> _nextJson(StreamIterator<Object?> events) async =>
    jsonDecode(await _nextText(events)) as Map<String, Object?>;

Future<String> _nextText(StreamIterator<Object?> events) async {
  final available = await events.moveNext().timeout(const Duration(seconds: 5));
  if (!available || events.current is! String) {
    throw StateError('Expected a WebSocket text frame.');
  }
  return events.current! as String;
}

Future<void> _expectRemoteClose(StreamIterator<Object?> events) async {
  final hasFrame = await events.moveNext().timeout(const Duration(seconds: 5));
  if (hasFrame) {
    throw StateError('Expected the WebSocket peer to close.');
  }
}

final class _SocketPair {
  _SocketPair({required this.client, required this.server})
    : clientEvents = StreamIterator<Object?>(client),
      serverEvents = StreamIterator<Object?>(server);

  final WebSocket client;
  final WebSocket server;
  final StreamIterator<Object?> clientEvents;
  final StreamIterator<Object?> serverEvents;

  Future<void> cancel() async {
    await clientEvents.cancel();
    await serverEvents.cancel();
  }
}

final class _HttpWireResponse {
  const _HttpWireResponse({required this.statusCode, required this.body});

  final int statusCode;
  final Uint8List body;
}
