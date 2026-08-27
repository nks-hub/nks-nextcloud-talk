import '../protocol_exception.dart';

/// Where a server offers Nextcloud's Client Push service and what it carries.
///
/// This is Nextcloud's own delivery channel — the `notify_push` app — rather
/// than anything this project invents. A server advertises it through
/// capabilities, so a client that finds nothing here simply has no live
/// channel and falls back to polling.
final class ClientPushEndpoints {
  const ClientPushEndpoints({
    required this.websocket,
    required this.preAuth,
    required this.carriesNotifications,
  });

  final Uri websocket;
  final Uri preAuth;

  /// Whether the server said it forwards notifications, not only file changes.
  /// Older `notify_push` builds carry files alone, and connecting to one of
  /// those for chat would hold a socket open that can never deliver a message.
  final bool carriesNotifications;
}

/// Reads the `notify_push` capability block.
///
/// Returns null when the server does not offer the service, which is the
/// normal case on an instance that never installed the app.
ClientPushEndpoints? readClientPushEndpoints(Map<String, Object?> capabilities) {
  final raw = capabilities['notify_push'];
  if (raw is! Map<String, Object?>) {
    return null;
  }
  final endpoints = raw['endpoints'];
  if (endpoints is! Map<String, Object?>) {
    return null;
  }
  final websocket = _endpoint(endpoints['websocket'], const {'ws', 'wss'});
  final preAuth = _endpoint(endpoints['pre_auth'], const {'http', 'https'});
  if (websocket == null || preAuth == null) {
    return null;
  }
  final types = raw['type'];
  final carries =
      types is List && types.any((value) => value == 'notifications');
  return ClientPushEndpoints(
    websocket: websocket,
    preAuth: preAuth,
    carriesNotifications: carries,
  );
}

Uri? _endpoint(Object? value, Set<String> allowedSchemes) {
  if (value is! String || value.isEmpty || value.length > 2048) {
    return null;
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !allowedSchemes.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    // Credentials in the authority are how a forged host hides behind a
    // familiar looking one, so such an endpoint is refused rather than
    // trimmed.
    return null;
  }
  return uri;
}

/// What the server pushes down an authenticated Client Push socket.
enum ClientPushEvent {
  /// A notification was created, processed or dismissed for this user. For a
  /// chat client this is the wake-up: fetch what changed.
  notification,

  /// An activity item was created.
  activity,

  /// A file changed. Recorded so the socket can be shared, ignored here.
  file,

  /// The credentials were accepted.
  authenticated,
}

/// Parses one server frame, or null when it is something this client has no
/// use for. Unknown frames are ignored rather than treated as failures: the
/// service adds message types over time and an older client must survive them.
ClientPushEvent? parseClientPushFrame(String frame) {
  final trimmed = frame.trim();
  if (trimmed.isEmpty || trimmed.length > 256) {
    return null;
  }
  // Frames may carry a payload after the name, as `notify_file_id` does.
  final name = trimmed.split(RegExp(r'\s+')).first;
  return switch (name) {
    'authenticated' => ClientPushEvent.authenticated,
    'notify_notification' => ClientPushEvent.notification,
    'notify_activity' => ClientPushEvent.activity,
    'notify_file' || 'notify_file_id' => ClientPushEvent.file,
    _ => null,
  };
}

/// The two frames a client sends after connecting, in order.
///
/// Nextcloud accepts either real credentials or a pre-auth token; this client
/// only ever uses the token, so the app password never travels over the
/// socket. An empty username is what tells the server to expect one.
List<String> clientPushHandshake({required String preAuthToken}) {
  if (preAuthToken.isEmpty || preAuthToken.length > 256) {
    throw TalkProtocolException(
      TalkProtocolErrorCode.invalidPushState,
      path: r'$.clientPush.preAuthToken',
    );
  }
  return <String>['', preAuthToken];
}
