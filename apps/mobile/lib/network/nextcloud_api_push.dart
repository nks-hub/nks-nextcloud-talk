part of 'nextcloud_api.dart';

const Set<int> _pushRegistrationStatusCodes = <int>{
  200,
  201,
  202,
  400,
  401,
  403,
  404,
  405,
  408,
  409,
  422,
  429,
  500,
  501,
  502,
  503,
  504,
};

/// Registers and unregisters this device's push key with Nextcloud — step 1
/// of push v2 (`packages/talk_protocol/lib/src/push`). Nextcloud only
/// records the proxy URL and stamps a device identifier here; it never talks
/// to the proxy itself, so this just hands the raw status/body to the
/// protocol's own decoder rather than pre-filtering what counts as success.
mixin _NextcloudApiPush on _HttpNextcloudApiBase {
  Future<PushNextcloudRegistrationCompletion> registerPushWithNextcloud({
    required RegisterPushWithNextcloudEffect effect,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request =
        _authenticatedOcsRequest(
            'POST',
            effect.uri,
            loginName: loginName,
            appPassword: appPassword,
            abortTrigger: abortTrigger,
          )
          ..bodyFields = effect.formFields;
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _pushRegistrationStatusCodes,
      maximumBytes: PushWireLimits.maximumOcsBodyBytes,
    );
    final body = utf8.decode(payload.body, allowMalformed: true);
    // ignore: avoid_print
    print(
      'PUSHV2DIAG registerNextcloud status=${payload.statusCode} '
      'keyLen=${effect.formFields['devicePublicKey']?.length} body=$body',
    );
    return decodePushNextcloudRegistrationResponse(
      effect: effect,
      statusCode: payload.statusCode,
      body: body,
    );
  }

  Future<PushNextcloudUnregistrationCompletion> unregisterPushFromNextcloud({
    required UnregisterPushFromNextcloudEffect effect,
    required String loginName,
    required String appPassword,
    Future<void>? abortTrigger,
  }) async {
    final request = _authenticatedOcsRequest(
      'DELETE',
      effect.uri,
      loginName: loginName,
      appPassword: appPassword,
      abortTrigger: abortTrigger,
    );
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _pushRegistrationStatusCodes,
      maximumBytes: PushWireLimits.maximumOcsBodyBytes,
    );
    return decodePushNextcloudUnregistrationResponse(
      effect: effect,
      statusCode: payload.statusCode,
      body: utf8.decode(payload.body, allowMalformed: true),
    );
  }
}
