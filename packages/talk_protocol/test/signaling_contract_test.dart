import 'dart:convert';
import 'dart:io';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

import 'support/signaling_test_support.dart';

void main() {
  group('executable signaling fixtures', () {
    test('settings fixtures stay aligned with the Dart decoder', () {
      final cases = _readJsonList(
        'contracts/signaling/fixtures/settings.cases.json',
      );
      for (final fixture in cases) {
        final request = SignalingSettingsRequest(
          context: signalingRequestContext(50),
        );
        SignalingSettingsResponse decode() => decodeSignalingSettingsResponse(
          request: request,
          statusCode: 200,
          body: signalingOcsBody(statusCode: 200, data: fixture['data']),
        );

        if (fixture['valid'] != true) {
          expect(decode, throwsA(isA<TalkProtocolException>()));
          continue;
        }

        final response = decode();
        final expected = fixture['expected']! as Map<String, Object?>;
        expect(
          response.classification,
          SignalingSettingsClassification.confirmed,
        );
        if (expected['mode'] == 'internal') {
          expect(response.settings, isA<InternalSignalingSettings>());
          continue;
        }
        final settings = response.settings! as ExternalSignalingSettings;
        expect(settings.endpoint.socketUri.toString(), expected['socket']);
        expect(settings.federation != null, expected['federated']);
        final versions = expected['helloVersions']! as List<Object?>;
        expect(settings.v1Authentication != null, versions.contains('1.0'));
        expect(settings.v2Authentication != null, versions.contains('2.0'));
      }
    });

    test('server HPB fixtures stay aligned with the Dart decoder', () {
      final cases = _readJsonList(
        'contracts/signaling/fixtures/hpb.cases.json',
      ).where((fixture) => fixture['direction'] == 'server');
      for (final fixture in cases) {
        HpbServerFrame decode() =>
            HpbServerFrame.decode(jsonEncode(fixture['frame']));
        if (fixture['valid'] != true) {
          expect(decode, throwsA(isA<TalkProtocolException>()));
          continue;
        }
        final frame = decode();
        if (fixture['expectedType'] == 'unsupported') {
          expect(frame, isA<HpbUnsupportedServerFrame>());
        } else {
          expect(frame.type, fixture['expectedType']);
        }
      }
    });
  });

  group('signaling settings contract', () {
    test('parses internal and external authenticated settings', () {
      for (final mode in <String>['internal', 'external']) {
        final request = SignalingSettingsRequest(
          context: signalingRequestContext(mode == 'internal' ? 1 : 2),
        );
        final response = decodeSignalingSettingsResponse(
          request: request,
          statusCode: 200,
          body: signalingOcsBody(
            statusCode: 200,
            data: {
              ...signalingSettingsData(mode: mode),
              'sipDialinInfo': 'Call the synthetic test number',
            },
          ),
        );

        expect(
          response.classification,
          SignalingSettingsClassification.confirmed,
        );
        expect(
          response.settings?.transport,
          mode == 'internal'
              ? SignalingTransportKind.internal
              : SignalingTransportKind.externalHpb,
        );
        expect(
          response.settings?.sipDialinInfo,
          'Call the synthetic test number',
        );
        expect(
          response.settings.toString(),
          isNot(contains('synthetic test number')),
        );
      }
    });

    test('external settings use a canonical TLS WebSocket endpoint', () {
      final request = SignalingSettingsRequest(
        context: signalingRequestContext(3),
      );
      final response = decodeSignalingSettingsResponse(
        request: request,
        statusCode: 200,
        body: signalingOcsBody(
          statusCode: 200,
          data: signalingSettingsData(
            endpoint: 'https://hpb.example.invalid/signaling/',
          ),
        ),
      );
      final settings = response.settings! as ExternalSignalingSettings;

      expect(
        settings.endpoint.socketUri.toString(),
        'wss://hpb.example.invalid/signaling/spreed',
      );
      expect(settings.endpoint.baseUri.query, isEmpty);
      expect(settings.endpoint.baseUri.userInfo, isEmpty);
    });
  });

  group('signaling peer wire', () {
    test(
      'participant updates preserve upstream camel-case identity fields',
      () {
        final frame =
            decodeHpbFrame(<String, Object?>{
                  'type': 'event',
                  'event': <String, Object?>{
                    'target': 'participants',
                    'type': 'update',
                    'update': <String, Object?>{
                      'roomid': 'rooma123',
                      'users': <Object?>[
                        <String, Object?>{
                          'sessionId': 'peer-update-a',
                          'nextcloudSessionId': 'nextcloud-update-a',
                          'userId': 'user-update-a',
                          'inCall': 3,
                          'participantPermissions': 7,
                          'actorType': 'users',
                          'actorId': 'user-update-a',
                        },
                      ],
                    },
                  },
                })
                as HpbEventServerFrame;

        expect(frame.participants.single.userId, 'user-update-a');
        expect(
          frame.participants.single.nextcloudSessionId,
          ConversationSessionId.parse(
            'nextcloud-update-a',
            code: TalkProtocolErrorCode.invalidSignalingFrame,
          ),
        );
      },
    );

    test('all-participant update requires a literal true all flag', () {
      expect(
        () => decodeHpbFrame(<String, Object?>{
          'type': 'event',
          'event': <String, Object?>{
            'target': 'participants',
            'type': 'update',
            'update': <String, Object?>{
              'roomid': 'rooma123',
              'all': false,
              'incall': 0,
            },
          },
        }),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.path,
            'path',
            r'$.event.update.all',
          ),
        ),
      );
    });

    test('roomType is optional and may be empty on the wire', () {
      for (final raw in <Map<String, Object?>>[
        <String, Object?>{
          'type': 'startedTyping',
          'payload': <String, Object?>{},
        },
        <String, Object?>{
          'type': 'startedTyping',
          'roomType': '',
          'payload': <String, Object?>{},
        },
      ]) {
        final message = SignalingPeerMessage.fromJson(raw);
        expect(message.roomType, isEmpty);
        expect(message.type, 'startedTyping');
      }
    });

    test('typing messages preserve the upstream payload-free wire shape', () {
      for (final type in <String>['startedTyping', 'stoppedTyping']) {
        final inbound = SignalingPeerMessage.fromJson(<String, Object?>{
          'type': type,
          'from': 'peer-a',
        });

        expect(inbound.type, type);
        expect(inbound.roomType, isEmpty);
        expect(inbound.payload, isNull);
        expect(inbound.toWire(includeSender: true), <String, Object?>{
          'type': type,
          'from': 'peer-a',
        });

        final outbound = SignalingPeerMessage(
          type: type,
          roomType: '',
          sid: null,
          recipient: SignalingPeerId.parse('peer-b'),
          sender: null,
          payload: null,
        );
        expect(outbound.toWire(), <String, Object?>{
          'type': type,
          'to': 'peer-b',
        });
      }
    });

    test('unshareScreen travels without a payload, as the web sends it', () {
      final inbound = SignalingPeerMessage.fromJson(<String, Object?>{
        'type': 'unshareScreen',
        'from': 'peer-a',
        'to': 'peer-b',
        'roomType': 'screen',
        'sid': 'screen-1',
      });
      expect(inbound.type, 'unshareScreen');
      expect(inbound.roomType, 'screen');
      expect(inbound.payload, isNull);
    });

    test('non-typing messages still require an explicit payload', () {
      expect(
        () => SignalingPeerMessage.fromJson(<String, Object?>{
          'type': 'offer',
          'to': 'peer-b',
        }),
        throwsA(
          isA<TalkProtocolException>().having(
            (error) => error.path,
            'path',
            r'$.message.data.payload',
          ),
        ),
      );
    });

    test('internal batch consumes a one-shot iterable exactly once', () {
      var iterations = 0;
      Iterable<SignalingPeerMessage> oneShot() sync* {
        if (iterations++ != 0) {
          throw StateError('iterated more than once');
        }
        yield signalingMessage();
      }

      final request = InternalSignalingBatchRequest(
        context: signalingRequestContext(4, connectionEpoch: 1),
        nextcloudSessionId: signalingSessionA,
        messages: oneShot(),
      );

      expect(iterations, 1);
      expect(request.messages, hasLength(1));
      final encoded = jsonDecode(request.formFields['messages']!);
      expect(encoded, isA<List<Object?>>());
      expect(encoded, hasLength(1));
    });

    test('HPB control uses its own top-level control envelope', () {
      final control = HpbControlMessage(
        recipient: SignalingPeerId.parse('peer-b'),
        sender: null,
        data: SignalingOpaquePayload.fromJson(<String, Object?>{
          'type': 'mute',
          'audio': 1,
        }),
      );
      final outbound = HpbControlClientFrame(
        requestId: signalingRequestId(5),
        control: control,
      );

      expect(jsonDecode(outbound.encode()), <String, Object?>{
        'id': 'signaling-request-5',
        'type': 'control',
        'control': <String, Object?>{
          'recipient': <String, Object?>{
            'type': 'session',
            'sessionid': 'peer-b',
          },
          'data': <String, Object?>{'type': 'mute', 'audio': 1},
        },
      });

      final inbound = decodeHpbFrame(<String, Object?>{
        'type': 'control',
        'control': <String, Object?>{
          'sender': <String, Object?>{'type': 'session', 'sessionid': 'peer-a'},
          'data': <String, Object?>{'type': 'hangup'},
        },
      });
      expect(inbound, isA<HpbControlServerFrame>());
      final parsed = (inbound as HpbControlServerFrame).control;
      expect(parsed.sender, SignalingPeerId.parse('peer-a'));
      expect(parsed.data.wire, <String, Object?>{'type': 'hangup'});
    });
  });
}

List<Map<String, Object?>> _readJsonList(String relativePath) {
  final decoded =
      jsonDecode(File('${_repoRoot().path}/$relativePath').readAsStringSync())
          as List<Object?>;
  return decoded.cast<Map<String, Object?>>();
}

Directory _repoRoot() {
  var directory = Directory.current.absolute;
  while (directory.parent.path != directory.path) {
    if (File(
      '${directory.path}/contracts/signaling/openapi.json',
    ).existsSync()) {
      return directory;
    }
    directory = directory.parent;
  }
  throw StateError('Repository root not found');
}
