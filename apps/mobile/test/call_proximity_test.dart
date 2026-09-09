import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/calls/call_proximity.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('what a call wants from the proximity sensor', () {
    bool wants({
      bool joined = true,
      bool onEarpiece = true,
      bool cameraOn = false,
      bool screenSharing = false,
      bool receivingVideo = false,
    }) => callWantsProximityBlanking(
      joined: joined,
      onEarpiece: onEarpiece,
      cameraOn: cameraOn,
      screenSharing: screenSharing,
      receivingVideo: receivingVideo,
    );

    test('an audio call on the earpiece blanks at the ear', () {
      expect(wants(), isTrue);
    });

    test('no call means no blanking', () {
      expect(wants(joined: false), isFalse);
    });

    test('any output other than the earpiece keeps the screen', () {
      expect(wants(onEarpiece: false), isFalse);
    });

    test('a picture in the call keeps the screen, even on the earpiece', () {
      expect(wants(cameraOn: true), isFalse);
      expect(wants(screenSharing: true), isFalse);
      expect(wants(receivingVideo: true), isFalse);
    });
  });

  group('CallProximityHold', () {
    test('takes the screen once and gives it back once', () async {
      final screen = _RecordingScreen();
      final hold = CallProximityHold(screen);

      await hold.apply(wanted: true);
      await hold.apply(wanted: true);
      expect(hold.held, isTrue);
      expect(screen.acquires, 1);

      await hold.apply(wanted: false);
      await hold.apply(wanted: false);
      expect(hold.held, isFalse);
      expect(screen.releases, 1);
    });

    test('a device that refuses is not asked again', () async {
      final screen = _RecordingScreen(grant: false);
      final hold = CallProximityHold(screen);

      await hold.apply(wanted: true);
      await hold.apply(wanted: false);
      await hold.apply(wanted: true);

      expect(hold.held, isFalse);
      expect(screen.acquires, 1);
      // Nothing was held, so nothing is given back: a release for a lock that
      // was refused would be a platform call for no reason.
      expect(screen.releases, 0);
    });

    test('release gives the screen back and leaves nothing held', () async {
      final screen = _RecordingScreen();
      final hold = CallProximityHold(screen);

      await hold.apply(wanted: true);
      await hold.release();
      await hold.release();

      expect(hold.held, isFalse);
      expect(screen.releases, 1);
    });
  });

  group('AndroidCallProximityScreen', () {
    const channel = MethodChannel(AndroidCallProximityScreen.channelName);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('carries the platform answers through', () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return call.method == 'release' ? null : true;
      });

      const screen = AndroidCallProximityScreen();
      expect(await screen.supported(), isTrue);
      expect(await screen.acquire(), isTrue);
      await screen.release();

      expect(calls, ['supported', 'acquire', 'release']);
    });

    test('a device without the channel simply cannot blank', () async {
      const screen = AndroidCallProximityScreen();

      expect(await screen.supported(), isFalse);
      expect(await screen.acquire(), isFalse);
      // The release must not throw where the channel is absent: it runs from
      // the call teardown, which must finish.
      await screen.release();
    });

    test('a platform failure is not an exception in the call', () async {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => throw PlatformException(code: 'wake_lock_failed'),
      );

      const screen = AndroidCallProximityScreen();
      expect(await screen.supported(), isFalse);
      expect(await screen.acquire(), isFalse);
      await screen.release();
    });
  });
}

final class _RecordingScreen implements CallProximityScreen {
  _RecordingScreen({this.grant = true});

  final bool grant;
  int acquires = 0;
  int releases = 0;

  @override
  Future<bool> supported() async => grant;

  @override
  Future<bool> acquire() async {
    acquires++;
    return grant;
  }

  @override
  Future<void> release() async {
    releases++;
  }
}
