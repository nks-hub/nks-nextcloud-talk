import 'dart:convert';

import '../json_value.dart';
import '../protocol_exception.dart';
import 'crypto_material.dart';
import 'effects.dart';
import 'identifiers.dart';
import 'models.dart';

PushNextcloudRegistrationCompletion decodePushNextcloudRegistrationResponse({
  required RegisterPushWithNextcloudEffect effect,
  required int statusCode,
  required String body,
}) {
  _requireHttpStatus(statusCode);
  _requireBoundedBody(body, r'$.response.body');
  if (statusCode == 401 || statusCode == 403) {
    return PushNextcloudRegistrationCompletion.reauthenticationRequired(
      effect: effect,
    );
  }
  if (statusCode == 408 || statusCode == 429 || statusCode >= 500) {
    return PushNextcloudRegistrationCompletion.transientFailure(effect: effect);
  }
  if (statusCode != 200 && statusCode != 201) {
    return PushNextcloudRegistrationCompletion.rejected(effect: effect);
  }
  final root = requireObject(
    decodeJsonRejectingDuplicateMembers(
      body,
      code: TalkProtocolErrorCode.invalidPushRegistration,
      path: r'$.response.body',
    ),
    path: r'$.response',
    code: TalkProtocolErrorCode.invalidPushRegistration,
  );
  final ocs = requireObject(
    root['ocs'],
    path: r'$.response.ocs',
    code: TalkProtocolErrorCode.invalidPushRegistration,
  );
  final meta = requireObject(
    ocs['meta'],
    path: r'$.response.ocs.meta',
    code: TalkProtocolErrorCode.invalidPushRegistration,
  );
  if (requireString(
        meta['status'],
        path: r'$.response.ocs.meta.status',
        code: TalkProtocolErrorCode.invalidPushRegistration,
        minLength: 1,
        maxLength: 32,
      ) !=
      'ok') {
    protocolFailure(
      TalkProtocolErrorCode.invalidPushRegistration,
      r'$.response.ocs.meta.status',
    );
  }
  if (requireInt(
        meta['statuscode'],
        path: r'$.response.ocs.meta.statuscode',
        code: TalkProtocolErrorCode.invalidPushRegistration,
      ) !=
      200) {
    protocolFailure(
      TalkProtocolErrorCode.invalidPushRegistration,
      r'$.response.ocs.meta.statuscode',
    );
  }
  final data = requireObject(
    ocs['data'],
    path: r'$.response.ocs.data',
    code: TalkProtocolErrorCode.invalidPushRegistration,
  );
  return PushNextcloudRegistrationCompletion.success(
    effect: effect,
    registration: PushServerRegistration(
      userPublicKey: PushRsaPublicKey.parse(
        requireString(
          data['publicKey'],
          path: r'$.response.ocs.data.publicKey',
          code: TalkProtocolErrorCode.invalidPushRegistration,
          minLength: 1,
          maxLength: 4096,
        ),
      ),
      deviceIdentifier: PushDeviceIdentifier.parse(data['deviceIdentifier']),
      deviceIdentifierSignature: PushDeviceSignature.parse(data['signature']),
    ),
  );
}

PushGatewayRegistrationCompletion decodePushGatewayRegistrationResponse({
  required RegisterPushWithGatewayEffect effect,
  required int statusCode,
  required String body,
}) {
  _requireHttpStatus(statusCode);
  _requireBoundedBody(body, r'$.gatewayResponse.body');
  if (statusCode == 200) {
    if (body.isNotEmpty) {
      protocolFailure(
        TalkProtocolErrorCode.invalidPushRegistration,
        r'$.gatewayResponse.body',
      );
    }
    return PushGatewayRegistrationCompletion.success(effect: effect);
  }
  if (statusCode == 409) {
    return PushGatewayRegistrationCompletion.conflict(effect: effect);
  }
  if (statusCode == 408 || statusCode == 429 || statusCode >= 500) {
    return PushGatewayRegistrationCompletion.transientFailure(effect: effect);
  }
  return PushGatewayRegistrationCompletion.rejected(effect: effect);
}

PushNextcloudUnregistrationCompletion
decodePushNextcloudUnregistrationResponse({
  required UnregisterPushFromNextcloudEffect effect,
  required int statusCode,
  required String body,
}) {
  _requireHttpStatus(statusCode);
  _requireBoundedBody(body, r'$.unregistrationResponse.body');
  if (statusCode == 200 || statusCode == 202) {
    return PushNextcloudUnregistrationCompletion.success(effect: effect);
  }
  if (statusCode == 401 || statusCode == 403) {
    return PushNextcloudUnregistrationCompletion.reauthenticationRequired(
      effect: effect,
    );
  }
  if (statusCode == 408 || statusCode == 429 || statusCode >= 500) {
    return PushNextcloudUnregistrationCompletion.transientFailure(
      effect: effect,
    );
  }
  return PushNextcloudUnregistrationCompletion.rejected(effect: effect);
}

PushGatewayUnregistrationCompletion decodePushGatewayUnregistrationResponse({
  required UnregisterPushFromGatewayEffect effect,
  required int statusCode,
  required String body,
}) {
  _requireHttpStatus(statusCode);
  _requireBoundedBody(body, r'$.gatewayUnregistrationResponse.body');
  if (statusCode == 200) {
    if (body.isNotEmpty) {
      protocolFailure(
        TalkProtocolErrorCode.invalidPushRegistration,
        r'$.gatewayUnregistrationResponse.body',
      );
    }
    return PushGatewayUnregistrationCompletion.success(effect: effect);
  }
  if (statusCode == 408 || statusCode == 429 || statusCode >= 500) {
    return PushGatewayUnregistrationCompletion.transientFailure(effect: effect);
  }
  return PushGatewayUnregistrationCompletion.rejected(effect: effect);
}

void _requireBoundedBody(String body, String path) {
  if (utf8.encode(body).length > PushWireLimits.maximumOcsBodyBytes) {
    protocolFailure(TalkProtocolErrorCode.invalidPushRegistration, path);
  }
}

void _requireHttpStatus(int statusCode) {
  if (statusCode < 100 || statusCode > 599) {
    protocolFailure(
      TalkProtocolErrorCode.unsupportedHttpStatus,
      r'$.statusCode',
    );
  }
}
