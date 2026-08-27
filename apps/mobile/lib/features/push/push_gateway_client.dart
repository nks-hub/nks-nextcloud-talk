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
    String? pushEnvironment,
  }) async {
    if (pushEnvironment != null &&
        pushEnvironment != 'development' &&
        pushEnvironment != 'production') {
      throw ArgumentError.value(
        pushEnvironment,
        'pushEnvironment',
        'must be development or production',
      );
    }
    final response = await _client.post(
      effect.uri,
      body: <String, String>{
        ...effect.identityFields,
        'pushToken': rawPushToken,
        'pushEnvironment': ?pushEnvironment,
      },
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
    // DELETE with a body, so the device identity stays out of the request
    // line. `http` has no `delete(body:)`, hence the explicit Request.
    final request = http.Request('DELETE', effect.uri)
      ..bodyFields = effect.identityFields;
    final response = await http.Response.fromStream(
      await _client.send(request),
    );
    return decodePushGatewayUnregistrationResponse(
      effect: effect,
      statusCode: response.statusCode,
      body: response.body,
    );
  }

  void close() => _client.close();
}
