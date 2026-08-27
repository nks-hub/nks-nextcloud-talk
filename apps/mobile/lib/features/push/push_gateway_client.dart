import 'package:http/http.dart' as http;
import 'package:talk_protocol/talk_protocol.dart';

/// Talks to the self-hosted APNs proxy (`nks-talk-notify`) directly — a
/// different origin than the Nextcloud server, authenticated by an RSA
/// signature instead of the account's app password. See that project's
/// README for the wire contract this mirrors.
final class PushGatewayClient {
  PushGatewayClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// Registers (or refreshes) a device with the proxy. [rawPushToken] is the
  /// hex APNs token — the one field of the wire contract the pure protocol
  /// core deliberately never carries, since Nextcloud itself never sees it
  /// either; only this proxy needs the real token.
  Future<PushGatewayRegistrationCompletion> register(
    RegisterPushWithGatewayEffect effect, {
    required String rawPushToken,
  }) async {
    final response = await _client.post(
      effect.uri,
      body: <String, String>{
        ...effect.identityFields,
        'pushToken': rawPushToken,
      },
    );
    // ignore: avoid_print
    print(
      'PUSHV2DIAG registerGateway status=${response.statusCode} '
      'body=${response.body} tokenLen=${rawPushToken.length}',
    );
    return decodePushGatewayRegistrationResponse(
      effect: effect,
      statusCode: response.statusCode,
      body: response.body,
    );
  }

  Future<PushGatewayUnregistrationCompletion> unregister(
    UnregisterPushFromGatewayEffect effect,
  ) async {
    final response = await _client.delete(effect.uri);
    return decodePushGatewayUnregistrationResponse(
      effect: effect,
      statusCode: response.statusCode,
      body: response.body,
    );
  }

  void close() => _client.close();
}
