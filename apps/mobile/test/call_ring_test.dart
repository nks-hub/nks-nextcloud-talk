import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/calls/call_media_session.dart';
import 'package:nextcloudtalk/features/calls/call_participants_sheet.dart';
import 'package:nextcloudtalk/features/calls/call_ring_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  group('who is worth ringing', () {
    Participant participant({
      required int attendeeId,
      required String actorId,
      int inCall = 0,
      String actorType = 'users',
    }) => parseParticipant(<String, Object?>{
      'attendeeId': attendeeId,
      'actorType': actorType,
      'actorId': actorId,
      'displayName': actorId,
      'participantType': 3,
      'lastPing': 0,
      'sessionId': '0',
      'sessionIds': <String>[],
      'inCall': inCall,
      'permissions': 254,
      'attendeePermissions': 0,
      'attendeePin': '',
      'status': null,
      'statusIcon': null,
      'statusMessage': null,
      'statusClearAt': null,
      'roomToken': 'rooma123',
      'phoneNumber': null,
      'callId': null,
      'invitedActorId': null,
      'displayNameUnique': actorId,
    }, path: r'$.participant');

    CallPeerState peer(String actorId) => CallPeerState(
      peerId: 'peer-$actorId',
      actorType: 'users',
      actorId: actorId,
      connected: true,
      handRaised: false,
      audioMuted: false,
      since: DateTime.utc(2026),
    );

    test('offers the people in the room who are not in the call', () {
      final candidates = callRingCandidates(
        participants: <Participant>[
          participant(attendeeId: 1, actorId: 'alice'),
          participant(attendeeId: 2, actorId: 'bob'),
        ],
        peers: const <CallPeerState>[],
        selfActorId: 'alice',
      );

      // Alice is this device; ringing yourself is accepted by the server and
      // is never what anybody means.
      expect(candidates.map((c) => c.actorId), <String>['bob']);
    });

    test('somebody already in the call is not offered', () {
      final candidates = callRingCandidates(
        participants: <Participant>[
          participant(attendeeId: 2, actorId: 'bob'),
          participant(attendeeId: 3, actorId: 'carol'),
        ],
        peers: <CallPeerState>[peer('bob')],
        selfActorId: 'alice',
      );

      expect(candidates.map((c) => c.actorId), <String>['carol']);
    });

    test('the server flag counts as well as the media peers', () {
      // A participant can be in the call without this device having media
      // with them yet.
      final candidates = callRingCandidates(
        participants: <Participant>[
          participant(attendeeId: 2, actorId: 'bob', inCall: 7),
        ],
        peers: const <CallPeerState>[],
        selfActorId: 'alice',
      );

      expect(candidates, isEmpty);
    });

    test('only real accounts are offered, not guests or bridges', () {
      final candidates = callRingCandidates(
        participants: <Participant>[
          participant(attendeeId: 4, actorId: 'guest', actorType: 'guests'),
          participant(attendeeId: 5, actorId: 'phone', actorType: 'phones'),
          participant(attendeeId: 6, actorId: 'dave'),
        ],
        peers: const <CallPeerState>[],
        selfActorId: 'alice',
      );

      expect(candidates.map((c) => c.actorId), <String>['dave']);
    });
  });

  group('CallRingService', () {
    late AppDatabase database;
    late AccountRepository accounts;
    late MemoryCredentialVault vault;

    setUp(() async {
      database = openTestDatabase();
      accounts = AccountRepository(database);
      vault = MemoryCredentialVault()..values['account-a'] = 'password-a';
      await accounts.upsertAccount(
        accountId: 'account-a',
        serverUrl: 'https://a.example.invalid',
        loginName: 'user-a',
        serverProductName: 'Nextcloud',
        createdAt: DateTime.utc(2026),
        talkFeatures: const <String>{},
      );
    });

    tearDown(() => database.close());

    CallRingService serviceWith(MockClient client) {
      final api = HttpNextcloudApi(client: client);
      addTearDown(api.close);
      return CallRingService(accounts: accounts, credentials: vault, api: api);
    }

    MockClient answering(int statusCode, {List<String>? calls}) =>
        MockClient((request) async {
          calls?.add('${request.method} ${request.url.path}');
          return http.Response(
            jsonEncode(<String, Object?>{
              'ocs': <String, Object?>{
                'meta': <String, Object?>{
                  'status': statusCode == 200 ? 'ok' : 'failure',
                  'statuscode': statusCode,
                  'message': statusCode == 200 ? 'OK' : '',
                },
                'data': statusCode == 200 ? <String, Object?>{} : null,
              },
            }),
            statusCode,
          );
        });

    test('rings exactly that attendee of that room', () async {
      final calls = <String>[];
      await serviceWith(
        answering(200, calls: calls),
      ).ring(accountId: 'account-a', roomToken: 'rooma123', attendeeId: 108);

      expect(
        calls.single,
        'POST /ocs/v2.php/apps/spreed/api/v4/call/rooma123/ring/108',
      );
    });

    test('a call that has ended is reported as itself', () async {
      // Measured: the only 400 this endpoint gives is `in-call`, and it means
      // no call is running.
      await expectLater(
        () => serviceWith(
          answering(400),
        ).ring(accountId: 'account-a', roomToken: 'rooma123', attendeeId: 108),
        throwsA(
          isA<CallRingException>().having(
            (error) => error.code,
            'code',
            CallRingError.noCallRunning,
          ),
        ),
      );
    });

    test(
      'an attendee the room does not have is reported, not retried',
      () async {
        var attempts = 0;
        final service = serviceWith(
          MockClient((request) async {
            attempts++;
            return http.Response(
              jsonEncode(<String, Object?>{
                'ocs': <String, Object?>{
                  'meta': <String, Object?>{
                    'status': 'failure',
                    'statuscode': 404,
                    'message': '',
                  },
                  'data': null,
                },
              }),
              404,
            );
          }),
        );

        await expectLater(
          () => service.ring(
            accountId: 'account-a',
            roomToken: 'rooma123',
            attendeeId: 99999,
          ),
          throwsA(
            isA<CallRingException>().having(
              (error) => error.code,
              'code',
              CallRingError.attendeeMissing,
            ),
          ),
        );
        expect(attempts, 1);
      },
    );

    test('an impossible attendee never leaves this side', () async {
      var reached = false;
      final service = serviceWith(
        MockClient((request) async {
          reached = true;
          return http.Response('', 200);
        }),
      );

      await expectLater(
        () => service.ring(
          accountId: 'account-a',
          roomToken: 'rooma123',
          attendeeId: 0,
        ),
        throwsA(isA<CallRingException>()),
      );
      expect(reached, isFalse);
    });

    test('an account that is gone is reported before any request', () async {
      var reached = false;
      final service = serviceWith(
        MockClient((request) async {
          reached = true;
          return http.Response('', 200);
        }),
      );

      await expectLater(
        () => service.ring(
          accountId: 'no-such-account',
          roomToken: 'rooma123',
          attendeeId: 108,
        ),
        throwsA(
          isA<CallRingException>().having(
            (error) => error.code,
            'code',
            CallRingError.accountMissing,
          ),
        ),
      );
      expect(reached, isFalse);
    });
  });
}
