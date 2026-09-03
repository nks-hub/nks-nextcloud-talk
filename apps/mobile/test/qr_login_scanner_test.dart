import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/onboarding/qr_login_scanner_screen.dart';
import 'package:nextcloudtalk/features/onboarding/qr_scan_session.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

final class _FakeSession implements QrScanSession {
  final StreamController<String> _payloads = StreamController<String>();
  bool closed = false;

  @override
  Stream<String> get payloads => _payloads.stream;

  @override
  Widget buildPreview() =>
      const SizedBox.expand(key: Key('fake-camera-preview'));

  @override
  Future<void> close() async {
    closed = true;
    await _payloads.close();
  }

  void emit(String raw) => _payloads.add(raw);
}

Future<Completer<QrLoginPayload?>> _pumpScanner(
  WidgetTester tester, {
  required QrScanSessionOpener openSession,
  Future<bool> Function()? onOpenSettings,
}) async {
  final result = Completer<QrLoginPayload?>();
  await tester.pumpWidget(
    localizedTestApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            final payload = await Navigator.of(context).push<QrLoginPayload>(
              MaterialPageRoute<QrLoginPayload>(
                builder: (context) => QrLoginScannerScreen(
                  openSession: openSession,
                  onOpenSettings: onOpenSettings,
                ),
              ),
            );
            result.complete(payload);
          },
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('a refused camera says so instead of showing an empty screen', (
    tester,
  ) async {
    var settingsOpened = 0;
    final result = await _pumpScanner(
      tester,
      openSession: () async =>
          throw const QrScanException(QrScanFailure.permissionDenied),
      onOpenSettings: () async {
        settingsOpened++;
        return true;
      },
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('qr-login-scanner-failure')), findsOneWidget);
    expect(
      find.text(
        'Camera access is turned off. Allow it in system settings to scan a '
        'login code.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('qr-login-scanner-open-settings')));
    await tester.pumpAndSettle();
    expect(settingsOpened, 1);

    Navigator.of(tester.element(find.byType(Scaffold).last)).pop();
    await tester.pumpAndSettle();
    expect(await result.future, isNull);
  });

  testWidgets('a device without a camera gets its own message and no action', (
    tester,
  ) async {
    await _pumpScanner(
      tester,
      openSession: () async =>
          throw const QrScanException(QrScanFailure.unavailable),
      onOpenSettings: () async => true,
    );

    expect(
      find.text('This device has no camera that can read a login code.'),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('qr-login-scanner-open-settings')),
      findsNothing,
    );
  });

  testWidgets('a foreign code is rejected without showing what it held', (
    tester,
  ) async {
    final session = _FakeSession();
    await _pumpScanner(tester, openSession: () async => session);

    expect(find.byKey(const Key('qr-login-scanner-hint')), findsOneWidget);

    session.emit('https://example.com/not-a-login?token=supersecret');
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('qr-login-scanner-unreadable')), findsOneWidget);
    expect(
      find.text('This is not a Nextcloud login code.'),
      findsOneWidget,
    );
    expect(find.textContaining('supersecret'), findsNothing);
    expect(find.byKey(const Key('fake-camera-preview')), findsOneWidget);
  });

  testWidgets('a valid payload closes the scanner and returns it', (
    tester,
  ) async {
    final session = _FakeSession();
    final result = await _pumpScanner(tester, openSession: () async => session);

    session.emit(
      'nc://login/user:alice&server:https%3A//cloud.example&password:s3cr3t',
    );
    await tester.pumpAndSettle();

    final payload = await result.future;
    expect(payload, isA<QrLoginCredentials>());
    final credentials = payload! as QrLoginCredentials;
    expect(credentials.server.value, 'https://cloud.example');
    expect(credentials.loginName, 'alice');
    expect(credentials.secret, 's3cr3t');
    expect(session.closed, isTrue);
  });

  testWidgets('a server-only payload comes back as a server, not a failure', (
    tester,
  ) async {
    final session = _FakeSession();
    final result = await _pumpScanner(tester, openSession: () async => session);

    session.emit('nc://login/server:https%3A//cloud.example');
    await tester.pumpAndSettle();

    final payload = await result.future;
    expect(payload, isA<QrLoginServerOnly>());
    expect(payload!.server.value, 'https://cloud.example');
  });
}
