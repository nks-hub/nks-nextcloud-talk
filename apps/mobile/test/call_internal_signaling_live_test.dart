import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/calls/call_transport_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

/// Drives the real network code — [CallTransportService], [HttpNextcloudApi]
/// and the internal-signalling wire codecs in `package:talk_protocol` —
/// against a REAL server: `tool/store_screenshot_server.py`, extended with
/// the internal signalling endpoints for exactly this purpose. Real TCP, real
/// TLS, real JSON on the wire and a real concurrent server process, unlike
/// every other signalling test in this suite, which answers a `MockClient`
/// synchronously in the same isolate and so never exercises the actual
/// socket/timing path.
///
/// What this does NOT cover, and why: it does not go through
/// `CallJoinController` or `CallLifecycleService`. Joining a call for real
/// needs a locally cached conversation whose session id was refreshed by a
/// full `ConversationSyncService` sync, plus the call-REST mutation
/// sequencing `CallLifecycleService` enforces — a bootstrap already
/// exhaustively covered with `MockClient` in call_lifecycle_service_test.dart
/// and call_lifecycle_room_session_test.part.dart. Reproducing that bootstrap
/// against a spawned process would mostly duplicate that coverage while
/// adding process-lifecycle fragility for little new signal. Media is not
/// real either way — WebRTC needs a platform channel no test host provides —
/// so "video on" and "screen share on/off" below are exactly what the brief
/// says can honestly be asserted here: the signalling messages the app would
/// send for them, round-tripped over the real wire, not the pixels.
///
/// Needs `python3` (or `python`) on PATH with the `cryptography` package
/// installed; skips, rather than fails, where neither is found.
void main() {
  final python = _pythonExecutable();

  group('a whole call over the real internal signalling wire', () {
    late Process server;
    late int port;
    late http.Client client;
    late HttpNextcloudApi api;
    late AppDatabase database;
    late AccountRepository accounts;

    Uri testUri(String path) => Uri.parse('https://127.0.0.1:$port$path');

    setUp(() async {
      final ready = Completer<int>();
      server = await Process.start(python!, [
        '../../tool/store_screenshot_server.py',
        '--port',
        '0',
        '--certificate-dir',
        Directory.systemTemp.createTempSync('nks-call-cert-').path,
      ]);
      server.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            final match = RegExp(r'^PORT (\d+)$').firstMatch(line);
            if (match != null && !ready.isCompleted) {
              ready.complete(int.parse(match.group(1)!));
            }
          });
      server.stderr.transform(utf8.decoder).listen((_) {});
      port = await ready.future.timeout(const Duration(seconds: 10));

      final ioClient = HttpClient()
        ..badCertificateCallback = (cert, host, certPort) => true;
      client = IOClient(ioClient);
      api = HttpNextcloudApi(client: client);

      database = openTestDatabase();
      accounts = AccountRepository(database);
      await accounts.upsertAccount(
        accountId: 'account-a',
        serverUrl: 'https://127.0.0.1:$port',
        loginName: 'alex',
        serverProductName: 'Nextcloud',
        talkFeatures: const {},
        createdAt: DateTime.utc(2026, 1, 1),
      );
    });

    tearDown(() async {
      api.close();
      await database.close();
      server.kill();
      await server.exitCode;
    });

    test(
      'start, a peer appears, video on, screen share on and off, leave',
      () async {
        final server = ServerBase.parse('https://127.0.0.1:$port');
        final roomToken = ConversationToken.parse(
          'callroom1',
          path: r'$.roomToken',
        );

        // Start: the banner's first REST step, resolving how the room would
        // be signalled — before anything joins.
        final transport = await CallTransportService(
          accounts: accounts,
          credentials: MemoryCredentialVault()
            ..values['account-a'] = 'fixture-password',
          api: api,
        ).resolve(accountId: 'account-a', roomToken: 'callroom1');
        expect(transport, CallTransport.internal);

        // Joining activates a real Talk room session; the fake server hands
        // back a fresh, non-zero session id exactly as Talk does.
        final activation = await api.activateRoomSession(
          activeRequest: ActiveRoomSessionRequest(
            accountId: AccountId.parse('account-a'),
            server: server,
            roomToken: roomToken,
          ),
          loginName: 'alex',
          appPassword: 'fixture-password',
        );
        final joined = activation.response;
        expect(joined, isA<ActiveRoomSessionSuccess>());
        final nextcloudSessionId =
            (joined as ActiveRoomSessionSuccess).room.sessionId;
        expect(nextcloudSessionId.value, isNot('0'));

        SignalingRequestContext context(String requestId) =>
            SignalingRequestContext(
              accountId: AccountId.parse('account-a'),
              requestId: SignalingRequestId.parse(requestId),
              server: server,
              roomToken: roomToken,
              credentialGeneration: 1,
              capabilityGeneration: 1,
              settingsRevision: 'revision-a',
              connectionEpoch: 1,
              roomEpoch: 1,
            );

        // The signalling settings a joined call negotiates over.
        final settings = await api.getSignalingSettings(
          settingsRequest: SignalingSettingsRequest(
            context: context('settings'),
          ),
          loginName: 'alex',
          appPassword: 'fixture-password',
        );
        expect(settings.settings, isA<InternalSignalingSettings>());

        // Before anyone else joins, the pull sees only this side.
        final firstPull = await api.pullInternalSignaling(
          pullRequest: InternalSignalingPullRequest(
            context: context('pull-1'),
            nextcloudSessionId: nextcloudSessionId,
          ),
          loginName: 'alex',
          appPassword: 'fixture-password',
        );
        expect(firstPull.participants, hasLength(1));
        expect(firstPull.messages, isEmpty);

        // A second participant appears.
        await client.post(testUri('/_test/peer-joined'));
        final secondPull = await api.pullInternalSignaling(
          pullRequest: InternalSignalingPullRequest(
            context: context('pull-2'),
            nextcloudSessionId: nextcloudSessionId,
          ),
          loginName: 'alex',
          appPassword: 'fixture-password',
        );
        expect(secondPull.participants, hasLength(2));
        final peer = secondPull.participants.singleWhere(
          (participant) => participant.userId == 'peer',
        );
        expect(peer.peerId.value, 'peer-session-1');
        final peerId = peer.peerId;

        // Video on: this side offers, the peer answers. Only the wire
        // messages are real; no camera opens and no SDP is negotiated for
        // real, which is exactly what a test host cannot do.
        await api.sendInternalSignalingBatch(
          batchRequest: InternalSignalingBatchRequest(
            context: context('offer-video'),
            nextcloudSessionId: nextcloudSessionId,
            messages: [
              SignalingPeerMessage(
                type: 'offer',
                roomType: 'video',
                sid: 'stream-video',
                recipient: SignalingPeerId.parse(peerId.value),
                sender: null,
                payload: SignalingOpaquePayload.fromJson(<String, Object?>{
                  'sdp': 'synthetic-offer-sdp',
                }),
              ),
            ],
          ),
          loginName: 'alex',
          appPassword: 'fixture-password',
        );
        final pushedAfterOffer = await _pushed(client, testUri);
        expect(pushedAfterOffer.single, containsPair('type', 'offer'));
        expect(pushedAfterOffer.single, containsPair('roomType', 'video'));
        expect(pushedAfterOffer.single['to'], peerId.value);

        await client.post(
          testUri('/_test/inject'),
          body: jsonEncode(<String, Object?>{
            'type': 'answer',
            'roomType': 'video',
            'sid': 'stream-video',
            'from': peerId.value,
            'payload': <String, Object?>{'sdp': 'synthetic-answer-sdp'},
          }),
        );
        final answerPull = await api.pullInternalSignaling(
          pullRequest: InternalSignalingPullRequest(
            context: context('pull-3'),
            nextcloudSessionId: nextcloudSessionId,
          ),
          loginName: 'alex',
          appPassword: 'fixture-password',
        );
        expect(answerPull.messages, hasLength(1));
        final answer = answerPull.messages.single;
        expect(answer.type, 'answer');
        expect(answer.sender?.value, peerId.value);
        expect(answer.payload?.wire['sdp'], 'synthetic-answer-sdp');

        // Screen share on: a second, independent connection per Talk's own
        // `roomType: screen` convention.
        await api.sendInternalSignalingBatch(
          batchRequest: InternalSignalingBatchRequest(
            context: context('offer-screen'),
            nextcloudSessionId: nextcloudSessionId,
            messages: [
              SignalingPeerMessage(
                type: 'offer',
                roomType: 'screen',
                sid: 'stream-screen',
                recipient: SignalingPeerId.parse(peerId.value),
                sender: null,
                payload: SignalingOpaquePayload.fromJson(<String, Object?>{
                  'sdp': 'synthetic-screen-offer-sdp',
                }),
              ),
            ],
          ),
          loginName: 'alex',
          appPassword: 'fixture-password',
        );
        final pushedAfterScreenOn = await _pushed(client, testUri);
        expect(pushedAfterScreenOn.last['roomType'], 'screen');
        expect(pushedAfterScreenOn.last['type'], 'offer');

        // Screen share off: Talk's `unshareScreen`, sent without a payload —
        // the exact defect fixed on 5 September 2026 was this message
        // dropped from the batch when it carried no payload at all.
        await api.sendInternalSignalingBatch(
          batchRequest: InternalSignalingBatchRequest(
            context: context('unshare-screen'),
            nextcloudSessionId: nextcloudSessionId,
            messages: [
              SignalingPeerMessage(
                type: 'unshareScreen',
                roomType: 'screen',
                sid: 'stream-screen',
                recipient: SignalingPeerId.parse(peerId.value),
                sender: null,
                payload: null,
              ),
            ],
          ),
          loginName: 'alex',
          appPassword: 'fixture-password',
        );
        final pushedAfterScreenOff = await _pushed(client, testUri);
        expect(pushedAfterScreenOff.last['type'], 'unshareScreen');
        expect(pushedAfterScreenOff.last.containsKey('payload'), isFalse);

        // Leave: the room session this whole call rode on is given back.
        await api.deactivateRoomSession(
          lease: activation.lease!,
          loginName: 'alex',
          appPassword: 'fixture-password',
        );
      },
      skip: python == null
          ? 'needs a local python3 with the cryptography package'
          : false,
    );
  });
}

Future<List<Map<String, Object?>>> _pushed(
  http.Client client,
  Uri Function(String path) uri,
) async {
  final response = await client.get(uri('/_test/pushed'));
  final decoded = jsonDecode(response.body) as List<Object?>;
  return decoded.cast<Map<String, Object?>>();
}

/// `python3` if it runs and has `cryptography` installed (the certificate the
/// fake server needs), else `python`, else null — this test then skips rather
/// than failing on a machine without either.
String? _pythonExecutable() {
  for (final candidate in ['python3', 'python']) {
    try {
      final result = Process.runSync(candidate, [
        '-c',
        'import cryptography',
      ]);
      if (result.exitCode == 0) {
        return candidate;
      }
    } on Object {
      continue;
    }
  }
  return null;
}
