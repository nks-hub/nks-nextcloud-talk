import 'package:http/http.dart' as http;
import 'package:talk_protocol/talk_protocol.dart';

enum PushGatewayProvider { apns, fcm }

/// Talks to the self-hosted APNs proxy (`nks-talk-notify`) directly — a
/// different origin than the Nextcloud server, authenticated by an RSA
/// signature instead of the account's app password. See that project's
/// README for the wire contract this mirrors.
final class PushGatewayClient {
  PushGatewayClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// Registers (or refreshes) a device with the proxy. The pure protocol core
  /// carries only the token hash because Nextcloud never sees the raw APNs or
  /// FCM token; only this proxy needs it and its provider.
  Future<PushGatewayRegistrationCompletion> register(
    RegisterPushWithGatewayEffect effect, {
    required String rawPushToken,
    required PushGatewayProvider pushProvider,
    String? pushEnvironment,
    String? voipToken,
  }) async {
    final validEnvironment =
        pushEnvironment == 'development' || pushEnvironment == 'production';
    if (pushProvider == PushGatewayProvider.apns && !validEnvironment) {
      throw ArgumentError.value(
        pushEnvironment,
        'pushEnvironment',
        'APNs requires development or production',
      );
    }
    if (pushProvider == PushGatewayProvider.fcm && pushEnvironment != null) {
      throw ArgumentError.value(
        pushEnvironment,
        'pushEnvironment',
        'FCM does not use an APNs environment',
      );
    }
    // PushKit is Apple's, and its token is a second one — the proxy keeps it
    // beside the ordinary token and sends a call push to it, because APNs
    // refuses a VoIP push to anything else.
    if (pushProvider != PushGatewayProvider.apns && voipToken != null) {
      throw ArgumentError.value(
        voipToken,
        'voipToken',
        'PushKit applies to APNs only',
      );
    }
    final response = await _client.post(
      effect.uri,
      body: <String, String>{
        ...effect.identityFields,
        'pushToken': rawPushToken,
        'pushProvider': pushProvider.name,
        'pushEnvironment': ?pushEnvironment,
        'voipToken': ?voipToken,
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
