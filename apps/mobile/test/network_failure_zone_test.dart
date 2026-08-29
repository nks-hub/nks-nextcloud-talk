import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

/// Never answers, so every request runs into the client timeout.
final class _SilentClient extends http.BaseClient {
  final _pending = <Completer<http.StreamedResponse>>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final completer = Completer<http.StreamedResponse>();
    _pending.add(completer);
    return completer.future;
  }

  /// Fails every request still in flight, the way a dropped socket does once
  /// the radio comes back.
  void failAll() {
    for (final completer in _pending) {
      if (!completer.isCompleted) {
        completer.completeError(http.ClientException('socket gone'));
      }
    }
    _pending.clear();
  }
}

void main() {
  final server = ServerBase.parse('https://cloud.example.invalid');

  test('a timed-out capability read leaves no unhandled zone error', () async {
    // Written while chasing NKS-TALK-8, a fatal report from a shipped build
    // whose stack ends in this read. `Future.timeout` walks away from its
    // source, and a source that fails afterwards with nobody listening is
    // filed as a crash. Measured here: it does not happen, because `timeout`
    // keeps listening to the future it wrapped. The hypothesis is therefore
    // ruled out, and this stays as the guard that keeps it ruled out.
    final unhandled = <Object>[];
    final client = _SilentClient();
    await runZonedGuarded(() async {
      final api = HttpNextcloudApi(
        client: client,
        requestTimeout: const Duration(milliseconds: 120),
      );
      try {
        await api.getAuthenticatedCapabilities(
          server: server,
          loginName: 'user-a',
          appPassword: 'secret',
        );
        fail('the read must time out');
      } on NextcloudApiException catch (error) {
        expect(error.code, NextcloudApiError.timeout);
      }
      client.failAll();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      api.close();
    }, (error, stack) => unhandled.add(error));
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(unhandled, isEmpty, reason: 'nothing may reach the zone handler');
  });
}
