import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/features/chat/media/chat_attachment_exporter.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';
import 'package:nextcloudtalk/features/calls/call_join_controller.dart';
import 'package:nextcloudtalk/features/calls/call_media_engine.dart';
import 'package:nextcloudtalk/features/calls/call_media_session.dart';
import 'package:nextcloudtalk/features/calls/call_participants_sheet.dart';
import 'package:nextcloudtalk/features/calls/call_transport_service.dart';

import 'test_support.dart';

const CallRoomKey _key = (accountId: 'account-a', roomToken: 'rooma123');

final class _FrozenJoinController extends CallJoinController {
  _FrozenJoinController(this.frozen);

  final CallJoinState frozen;

  @override
  CallJoinState build(CallRoomKey arg) => frozen;
}

final class _FakeLocalVideo implements CallLocalVideo {
  @override
  Widget buildPreview(BuildContext context, {bool contain = false}) =>
      const ColoredBox(key: Key('fake-local-video'), color: Colors.blue);

  @override
  Future<void> dispose() async {}
}

final class _FakeRemoteVideo implements CallRemoteVideo {
  @override
  String? get videoTrackId => null;

  @override
  Widget build(BuildContext context, {bool contain = false}) =>
      const ColoredBox(key: Key('fake-remote-video'), color: Colors.green);

  @override
  Future<void> dispose() async {}
}

CallPeerState _peer({
  required String peerId,
  required String actorId,
  bool connected = true,
  bool handRaised = false,
  bool audioMuted = false,
  DateTime? since,
  CallRemoteVideo? video,
}) => CallPeerState(
  peerId: peerId,
  actorType: 'users',
  actorId: actorId,
  connected: connected,
  handRaised: handRaised,
  audioMuted: audioMuted,
  since: since ?? DateTime.now(),
  video: video,
);

CallJoinState _joined({
  required List<CallPeerState> participants,
  bool muted = false,
  CallLocalVideo? localVideo,
}) => CallJoinState(
  phase: CallJoinPhase.joined,
  media: CallMediaState(
    phase: CallMediaPhase.connected,
    connectedPeers: participants.where((p) => p.connected).length,
    peers: participants.length,
    muted: muted,
    localVideo: localVideo,
    participants: participants,
  ),
);

Future<void> _pumpSheet(
  WidgetTester tester, {
  required CallJoinState state,
  Map<String, String> names = const {},
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        callJoinControllerProvider.overrideWith(
          () => _FrozenJoinController(state),
        ),
        callParticipantNamesProvider.overrideWith((ref, key) async => names),
      ],
      child: localizedTestApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showCallParticipantsSheet(context, _key),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  _attendanceTests();

  testWidgets('every participant appears with the caller counted in', (
    tester,
  ) async {
    await _pumpSheet(
      tester,
      state: _joined(
        muted: true,
        participants: [
          _peer(peerId: 'peer-a', actorId: 'alice', audioMuted: true),
          _peer(
            peerId: 'peer-b',
            actorId: 'bob',
            connected: false,
            handRaised: true,
          ),
        ],
      ),
      names: {'actor:users:alice': 'Alice Example'},
    );

    expect(find.text('In the call (3)'), findsOneWidget);
    expect(find.byKey(const Key('call-participant-self')), findsOneWidget);
    expect(find.text('You'), findsOneWidget);
    expect(find.text('Muted'), findsAtLeastNWidgets(1));
    // Alice has a display name from the room; Bob falls back to the actor id.
    expect(find.text('Alice Example'), findsOneWidget);
    expect(find.text('bob'), findsOneWidget);
    expect(find.text('Audio connected'), findsOneWidget);
    expect(find.text('Connecting…'), findsOneWidget);
    expect(find.byIcon(Icons.front_hand_rounded), findsOneWidget);
    expect(find.byIcon(Icons.mic_off_rounded), findsOneWidget);
  });

  testWidgets(
    'a peer stuck connecting past the timeout reads as not responding',
    (tester) async {
      await _pumpSheet(
        tester,
        state: _joined(
          participants: [
            _peer(
              peerId: 'peer-a',
              actorId: 'alice',
              connected: false,
              since: DateTime.now().subtract(const Duration(seconds: 30)),
            ),
          ],
        ),
      );

      expect(find.text('Not responding'), findsOneWidget);
      expect(find.text('Connecting…'), findsNothing);
    },
  );

  testWidgets('this side\'s own camera preview shows above the peer list', (
    tester,
  ) async {
    await _pumpSheet(
      tester,
      state: _joined(participants: const [], localVideo: _FakeLocalVideo()),
    );

    expect(
      find.byKey(const Key('call-participant-self-video')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('fake-local-video')), findsOneWidget);
  });

  testWidgets('a peer sharing video or a screen shows it under their tile', (
    tester,
  ) async {
    await _pumpSheet(
      tester,
      state: _joined(
        participants: [
          _peer(peerId: 'peer-a', actorId: 'alice', video: _FakeRemoteVideo()),
        ],
      ),
    );

    expect(
      find.byKey(const Key('call-participant-video-peer-a')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('fake-remote-video')), findsOneWidget);
  });
}

const String _attendanceCsv =
    'name,email,type,identifier\r\n'
    '"NCloudTalk Test",,users,nctalk-test\r\n'
    '"=2+3",,users,nctalk-test2\r\n';

final class _RecordingExportSystem implements ChatAttachmentSystem {
  ChatAttachmentSystemResult outcome = ChatAttachmentSystemResult.completed;
  Uint8List? savedBytes;
  String? savedName;
  String? savedContentType;

  @override
  Future<ChatAttachmentSystemResult> save({
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  }) async {
    savedBytes = bytes;
    savedName = fileName;
    savedContentType = contentType;
    return outcome;
  }

  @override
  Future<ChatAttachmentSystemResult> share({
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  }) async => throw UnimplementedError();
}

/// Drives the shipped sheet against a real [RoomSettingsService] whose only
/// substitute is the HTTP client, so the request the server would receive is
/// the one asserted here.
Future<_RecordingExportSystem> _pumpAttendanceSheet(
  WidgetTester tester, {
  required CallJoinState state,
  required Future<http.Response> Function(http.Request request) respond,
  List<String>? requests,
}) async {
  final database = openTestDatabase();
  addTearDown(database.close);
  final accounts = AccountRepository(database);
  await accounts.upsertAccount(
    accountId: _key.accountId,
    serverUrl: 'https://a.example.invalid',
    loginName: 'user-a',
    serverProductName: 'Nextcloud',
    createdAt: DateTime.utc(2026),
    talkFeatures: const <String>{'download-call-participants'},
  );
  final vault = MemoryCredentialVault()..values[_key.accountId] = 'password-a';
  final api = HttpNextcloudApi(
    client: MockClient((request) {
      requests?.add('${request.method} ${request.url}');
      return respond(request);
    }),
  );
  addTearDown(api.close);
  final system = _RecordingExportSystem();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        credentialVaultProvider.overrideWithValue(vault),
        nextcloudApiProvider.overrideWithValue(api),
        callJoinControllerProvider.overrideWith(
          () => _FrozenJoinController(state),
        ),
        callParticipantNamesProvider.overrideWith((ref, key) async => const {}),
        // The room listing has its own tests; leaving the real one in would
        // put a second request, and its timeout timer, into a test about the
        // export.
        callRingCandidatesProvider.overrideWith(
          (ref, key) async => const <Participant>[],
        ),
      ],
      child: localizedTestApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showCallParticipantsSheet(
                context,
                _key,
                exportSystem: system,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return system;
}

/// The export talks to a real HTTP client and a real database, neither of
/// which runs on the test's fake clock, so the tap is driven on the real one
/// and the result is rendered afterwards.
Future<void> _tapExport(WidgetTester tester) async {
  // The export talks to a real HTTP client and a real database, neither of
  // which runs on the test's fake clock. The wait is until the row stops
  // showing progress rather than a fixed delay: a request still in flight
  // when the tree goes away leaves its timeout timer behind, and the test
  // then fails for a reason that has nothing to do with the export.
  await tester.runAsync(() async {
    await tester.tap(find.byKey(const Key('call-attendance-export')));
    for (var attempt = 0; attempt < 100; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) {
        return;
      }
    }
  });
  await tester.pumpAndSettle();
}

void _attendanceTests() {
  testWidgets('an ordinary participant is not offered the export', (
    tester,
  ) async {
    await _pumpSheet(tester, state: _joined(participants: const []));

    expect(find.byKey(const Key('call-attendance-export')), findsNothing);
  });

  testWidgets('a moderator exports what the server recorded', (tester) async {
    final requests = <String>[];
    final system = await _pumpAttendanceSheet(
      tester,
      state: _attendanceModerator(),
      requests: requests,
      respond: (request) async => http.Response.bytes(
        utf8.encode(_attendanceCsv),
        200,
        headers: const {'content-type': 'text/csv'},
      ),
    );

    await _tapExport(tester);

    // The sheet also lists the room's participants, for the names and for who
    // is not in the call; the export is the one that matters here.
    final download = requests
        .where((request) => request.contains('/call/rooma123/download'))
        .toList();
    expect(download, hasLength(1));
    expect(download.single, contains('format=csv'));
    expect(find.text('Attendance saved'), findsOneWidget);
    expect(system.savedContentType, 'text/csv');
    expect(system.savedName, startsWith('call-attendance-rooma123-'));
    expect(system.savedName, endsWith('.csv'));
    final saved = system.savedBytes!;
    // The byte-order mark keeps accented names readable in a spreadsheet.
    expect(saved.sublist(0, 3), [0xef, 0xbb, 0xbf]);
    final text = utf8.decode(saved.sublist(3));
    expect(text, contains('NCloudTalk Test'));
    // The attendee-supplied cell is exported as text, not as a formula.
    expect(text, contains("'=2+3"));
  });

  testWidgets('outside a call the export says so instead of failing', (
    tester,
  ) async {
    await _pumpAttendanceSheet(
      tester,
      state: _attendanceModerator(),
      respond: (request) async => http.Response('', 400),
    );

    await _tapExport(tester);

    expect(
      find.text('No call is running in this conversation.'),
      findsOneWidget,
    );
  });

  testWidgets('a server refusal is reported, and nothing is written', (
    tester,
  ) async {
    final system = await _pumpAttendanceSheet(
      tester,
      state: _attendanceModerator(),
      respond: (request) async => http.Response('', 403),
    );

    await _tapExport(tester);

    expect(
      find.text('Only a moderator can export attendance.'),
      findsOneWidget,
    );
    expect(system.savedBytes, isNull);
  });

  testWidgets('a 200 that is not an attendance document is not exported', (
    tester,
  ) async {
    final system = await _pumpAttendanceSheet(
      tester,
      state: _attendanceModerator(),
      respond: (request) async => http.Response(
        '<!DOCTYPE html><html><body>Error</body></html>',
        200,
        headers: const {'content-type': 'text/html'},
      ),
    );

    await _tapExport(tester);

    expect(find.text('The attendance could not be exported.'), findsOneWidget);
    expect(system.savedBytes, isNull);
  });

  testWidgets('a cancelled save leaves the action ready to retry', (
    tester,
  ) async {
    final system = await _pumpAttendanceSheet(
      tester,
      state: _attendanceModerator(),
      respond: (request) async => http.Response.bytes(
        utf8.encode(_attendanceCsv),
        200,
        headers: const {'content-type': 'text/csv'},
      ),
    );
    system.outcome = ChatAttachmentSystemResult.cancelled;

    await _tapExport(tester);

    expect(find.text('Attendance saved'), findsNothing);
    expect(
      find.text(
        'Everyone the server recorded in this call, including those who '
        'already left.',
      ),
      findsOneWidget,
    );
  });
}

CallJoinState _attendanceModerator() => CallJoinState(
  phase: CallJoinPhase.joined,
  media: const CallMediaState(phase: CallMediaPhase.connected),
  canDownloadAttendance: true,
);
