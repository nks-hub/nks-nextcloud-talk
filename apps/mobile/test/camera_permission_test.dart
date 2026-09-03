import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/platform/camera_permission.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <String>[];
  var statuses = <String, Object?>{};

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(cameraPermissionChannel, (call) async {
          calls.add(call.method);
          final response = statuses[call.method];
          if (response is PlatformException) {
            throw response;
          }
          return <String, String>{'status': response! as String};
        });
  }

  setUp(() {
    calls.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    install();
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(cameraPermissionChannel, null);
  });

  test('an already granted camera is not asked for again', () async {
    statuses = {'status': 'granted'};
    expect(await ensureCameraPermission(), isTrue);
    expect(calls, <String>['status']);
  });

  test('a never-asked camera is requested once', () async {
    statuses = {'status': 'notDetermined', 'request': 'granted'};
    expect(await ensureCameraPermission(), isTrue);
    expect(calls, <String>['status', 'request']);
  });

  test('a refused request is reported as refused', () async {
    statuses = {'status': 'notDetermined', 'request': 'denied'};
    expect(await ensureCameraPermission(), isFalse);
    expect(calls, <String>['status', 'request']);
  });

  test('an already refused camera is never asked for again', () async {
    statuses = {'status': 'denied'};
    expect(await ensureCameraPermission(), isFalse);
    expect(calls, <String>['status']);
  });

  test('a failing channel is treated as refused, never as granted', () async {
    statuses = {'status': PlatformException(code: 'boom')};
    expect(await ensureCameraPermission(), isFalse);
  });

  test('platforms other than Android keep using the plugin error', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    statuses = {'status': 'denied'};
    expect(await ensureCameraPermission(), isTrue);
    expect(calls, isEmpty);
  });
}
