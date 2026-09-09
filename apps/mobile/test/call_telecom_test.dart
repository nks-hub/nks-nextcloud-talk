import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/calls/call_telecom.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AndroidCallTelecom.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  group('AndroidCallTelecom', () {
    late AndroidCallTelecom telecom;
    late List<MethodCall> calls;

    setUp(() {
      calls = [];
      telecom = AndroidCallTelecom(newCallId: () => 'call-1');
    });

    tearDown(() {
      telecom.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    });

    void answerWith(Object? Function(MethodCall call) reply) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return reply(call);
      });
    }

    test('a device that takes the call carries its id back', () async {
      answerWith((_) => true);

      expect(await telecom.supported(), isTrue);
      final call = await telecom.startOutgoing(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );

      expect(call?.callId, 'call-1');
      expect(call?.roomToken, 'rooma123');
      expect(calls.map((call) => call.method), ['supported', 'startOutgoing']);
      expect(calls.last.arguments, {
        'callId': 'call-1',
        'accountId': 'account-a',
        'roomToken': 'rooma123',
      });
    });

    test('an unsupported device registers no call at all', () async {
      // No handler: an Android without the channel, and every other platform.
      expect(await telecom.supported(), isFalse);
      expect(
        await telecom.startOutgoing(
          accountId: 'account-a',
          roomToken: 'rooma123',
        ),
        isNull,
      );
      expect(
        await telecom.reportIncoming(
          accountId: 'account-a',
          roomToken: 'rooma123',
        ),
        isNull,
      );
      // Ending what was never registered must not throw: this runs from the
      // call teardown, which has to finish.
      await telecom.endCall('call-1');
    });

    test('a refused phone account leaves the call without Telecom', () async {
      // The device answers, and the answer is "no": an API below 26, a ROM
      // that refuses to register the self-managed account, a call the system
      // would not permit right now.
      answerWith((_) => false);

      expect(await telecom.supported(), isFalse);
      expect(
        await telecom.startOutgoing(
          accountId: 'account-a',
          roomToken: 'rooma123',
        ),
        isNull,
      );
      expect(calls.map((call) => call.method), ['supported', 'startOutgoing']);
    });

    test('a platform failure is not an exception in the call', () async {
      answerWith((_) => throw PlatformException(code: 'telecom_failed'));

      expect(await telecom.supported(), isFalse);
      expect(
        await telecom.startOutgoing(
          accountId: 'account-a',
          roomToken: 'rooma123',
        ),
        isNull,
      );
      await telecom.endCall('call-1');
    });

    test('an incoming call is reported and answered by the system', () async {
      answerWith((_) => true);
      final answered = telecom.answered.first;

      final call = await telecom.reportIncoming(
        accountId: 'account-a',
        roomToken: 'rooma123',
      );
      expect(call?.callId, 'call-1');
      expect(calls.single.method, 'reportIncoming');

      await _fromNative('telecomAnswered', 'call-1');
      expect((await answered).roomToken, 'rooma123');
    });

    test('the system hanging up the call reaches this side', () async {
      answerWith((_) => true);
      final ended = telecom.ended.first;

      await _fromNative('telecomEnded', 'call-1');

      expect((await ended)?.callId, 'call-1');
    });

    test('a ring this app cannot show is withdrawn, not left open', () async {
      answerWith((_) => true);

      await _fromNative('telecomShowIncomingUi', 'call-1');

      expect(calls.single.method, 'endCall');
      expect(calls.single.arguments, {'callId': 'call-1'});
    });

    test('an unnamed call is ignored rather than mistaken for one', () async {
      answerWith((_) => true);
      var ends = 0;
      telecom.ended.listen((_) => ends++);

      await messenger.handlePlatformMessage(
        AndroidCallTelecom.channelName,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('telecomEnded', {'callId': 'call-1'}),
        ),
        (_) {},
      );
      await pumpEventQueue();

      // A malformed report names no room, so nothing can be left because of
      // it — the stream still fires with null, which means "no single call".
      expect(ends, 1);
      expect(calls, isEmpty);
    });
  });
}

Future<void> _fromNative(String method, String callId) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        AndroidCallTelecom.channelName,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall(method, {
            'accountId': 'account-a',
            'roomToken': 'rooma123',
            'callId': callId,
          }),
        ),
        (_) {},
      );
  await pumpEventQueue();
}
