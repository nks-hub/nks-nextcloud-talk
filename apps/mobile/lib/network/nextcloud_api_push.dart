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
  /// Message a chat notification is about, or null when the server no longer
  /// has the notification (read, dismissed, or the message was deleted).
  ///
  /// The push payload names only the room. The Notifications API gives the
  /// prepared notification, whose `object_id` Talk widens to
  /// `token/messageId[/threadId]` so a reply can quote the right message.
  /// Anything that is not that shape counts as "unknown" rather than a
  /// guess: the reply then goes out as a plain message.
  Future<int?> getNotificationChatMessageId({
    required ServerBase server,
    required String loginName,
    required String appPassword,
    required int notificationId,
    required String roomToken,
    Future<void>? abortTrigger,
  }) async {
    final request = _authenticatedOcsRequest(
      'GET',
      server.uri.replace(
        path:
            '${server.basePath}/ocs/v2.php/apps/notifications/api/v2/'
            'notifications/$notificationId',
        queryParameters: const {'format': 'json'},
      ),
      loginName: loginName,
      appPassword: appPassword,
      abortTrigger: abortTrigger,
    );
    final payload = await _sendJson(
      request,
      allowedStatusCodes: const {200, 404},
      maximumBytes: PushWireLimits.maximumOcsBodyBytes,
      parseBodyForStatusCodes: const {200},
    );
    if (payload.statusCode == 404) {
      return null;
    }
    final root = payload.json;
    final ocs = root is Map<String, Object?> ? root['ocs'] : null;
    final data = ocs is Map<String, Object?> ? ocs['data'] : null;
    if (data is! Map<String, Object?> || data['object_type'] != 'chat') {
      return null;
    }
    final objectId = data['object_id'];
    if (objectId is! String) {
      return null;
    }
    final parts = objectId.split('/');
    if (parts.length < 2 || parts.first != roomToken) {
      return null;
    }
    final messageId = int.tryParse(parts[1]);
    return messageId != null && messageId > 0 ? messageId : null;
  }

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
          ..headers['User-Agent'] = pushRegistrationUserAgent
          ..bodyFields = effect.formFields;
    final payload = await _sendBody(
      request,
      allowedStatusCodes: _pushRegistrationStatusCodes,
      maximumBytes: PushWireLimits.maximumOcsBodyBytes,
    );
    return decodePushNextcloudRegistrationResponse(
      effect: effect,
      statusCode: payload.statusCode,
      body: utf8.decode(payload.body, allowMalformed: true),
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
    )..headers['User-Agent'] = pushRegistrationUserAgent;
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
