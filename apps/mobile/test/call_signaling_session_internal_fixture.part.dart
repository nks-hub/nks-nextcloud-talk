part of 'call_signaling_session_test.dart';

final class _InternalSignalingClient extends http.BaseClient {
  _InternalSignalingClient({required this.failBatch, this.batchGate});

  final bool failBatch;
  final Future<void>? batchGate;
  int pullAttempts = 0;
  int batchAttempts = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path.endsWith('/settings')) {
      return _ocsResponse(200, _settingsData('internal'));
    }
    if (request.method == 'POST') {
      batchAttempts++;
      await batchGate;
      if (failBatch) {
        throw http.ClientException('synthetic ambiguous batch failure');
      }
      return _ocsResponse(200, const <Object?>[]);
    }
    pullAttempts++;
    if (pullAttempts == 1) {
      return _ocsResponse(200, <Object?>[
        <String, Object?>{
          'type': 'usersInRoom',
          'data': <Object?>[
            <String, Object?>{
              'sessionId': 'peer-session-a',
              'roomId': 42,
              'lastPing': 1,
              'userId': 'user-a',
              'inCall': 1,
              'participantPermissions': 7,
              'actorType': 'users',
              'actorId': 'user-a',
            },
          ],
        },
      ]);
    }
    final abortable = request as http.Abortable;
    await abortable.abortTrigger;
    throw http.RequestAbortedException(request.url);
  }
}
