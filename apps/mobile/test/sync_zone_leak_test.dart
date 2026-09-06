import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nextcloudtalk/core/foreground_sync_loop.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

/// Never answers on its own: the test decides when — and how — the send ends.
final class _StalledClient extends http.BaseClient {
  final pending = Completer<http.StreamedResponse>();
  final entered = Completer<void>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (!entered.isCompleted) {
      entered.complete();
    }
    return pending.future;
  }
}

void main() {
  test('a throwing error callback stays out of the zone', () async {
    // Same shape as NKS-TALK-8, one loop further out: the conversation sync
    // runs in a `ForegroundSyncLoop` that nothing awaits while the app is up,
    // and `unawaited` attaches no error handler. Anything escaping the loop —
    // here the report callback itself — therefore had no listener at all and
    // reached the platform handler as a FATAL crash.
    final unhandled = <Object>[];
    var attempts = 0;
    await runZonedGuarded(() async {
      final loop = ForegroundSyncLoop(
        task: (cancellation) async {
          attempts++;
          throw const NextcloudApiException(NextcloudApiError.timeout);
        },
        successInterval: const Duration(milliseconds: 5),
        retryBaseDelay: const Duration(milliseconds: 5),
        retryMaximumDelay: const Duration(milliseconds: 5),
        onError: (_) => throw StateError('reporting the failure failed'),
      );
      loop.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await loop.stop().timeout(
        const Duration(seconds: 2),
        onTimeout: () => fail('the loop must finish, not hang'),
      );
    }, (error, stack) => unhandled.add(error));
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(attempts, greaterThan(0), reason: 'the loop really ran the task');
    expect(unhandled, isEmpty);
  });

  test('an ordinary task failure still only retries', () async {
    final unhandled = <Object>[];
    final reported = <Object>[];
    await runZonedGuarded(() async {
      final loop = ForegroundSyncLoop(
        task: (cancellation) async =>
            throw const NextcloudApiException(NextcloudApiError.network),
        successInterval: const Duration(milliseconds: 5),
        retryBaseDelay: const Duration(milliseconds: 5),
        retryMaximumDelay: const Duration(milliseconds: 5),
        onError: reported.add,
      );
      loop.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await loop.stop();
    }, (error, stack) => unhandled.add(error));

    expect(reported, isNotEmpty);
    expect(unhandled, isEmpty);
  });

  test('a request that fails after its timeout stays out of the zone', () async {
    // `Future.timeout` stops waiting; it does not cancel the request. Once
    // this side has given up, the send is a future nobody listens to any
    // more, so a late failure on it — a dropped connection, a socket reset —
    // went straight to the platform handler, as a crash for a request the app
    // had already reported as a timeout and moved on from.
    final client = _StalledClient();
    final api = HttpNextcloudApi(
      client: client,
      requestTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(api.close);

    final read = api.getAuthenticatedCapabilities(
      server: ServerBase.parse('https://cloud.example.invalid'),
      loginName: 'tester',
      appPassword: 'app-password',
    );
    await client.entered.future;
    Object? seen;
    try {
      await read;
    } on Object catch (error) {
      seen = error;
    }
    expect(
      seen,
      isA<NextcloudApiException>().having(
        (e) => e.code,
        'error',
        NextcloudApiError.timeout,
      ),
      reason: 'the caller is told it timed out and moves on',
    );

    // Only now does the abandoned request fail. Nothing is waiting for it any
    // more, which is exactly the case that used to end the application.
    final unhandled = <Object>[];
    await runZonedGuarded(() async {
      client.pending.completeError(
        http.ClientException('Connection closed while receiving data'),
        StackTrace.current,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }, (error, stack) => unhandled.add(error));

    expect(unhandled, isEmpty);
  });

  test('a response that arrives after the timeout is drained, not leaked',
      () async {
    // The same abandoned send, succeeding late: its body must be consumed or
    // the socket stays held for as long as the client lives.
    final client = _StalledClient();
    final api = HttpNextcloudApi(
      client: client,
      requestTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(api.close);

    final read = api.getAuthenticatedCapabilities(
      server: ServerBase.parse('https://cloud.example.invalid'),
      loginName: 'tester',
      appPassword: 'app-password',
    );
    await client.entered.future;
    await expectLater(read, throwsA(isA<NextcloudApiException>()));

    var listened = false;
    final body = StreamController<List<int>>();
    body.onListen = () {
      listened = true;
      body.add(const [1, 2, 3]);
      unawaited(body.close());
    };
    client.pending.complete(http.StreamedResponse(body.stream, 200));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Nobody else has any reason to read this body: if the transport had not
    // drained it, the stream would never be listened to at all.
    expect(listened, isTrue);
  });
}
