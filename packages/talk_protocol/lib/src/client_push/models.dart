import 'dart:convert';

import '../identifiers.dart';
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

/// Frame name the OwnTalk Extensions server app pushes through `notify_push`
/// after every successful write of a conversation's shared settings.
const String ownTalkRoomSettingsFrameName = 'owntalk_room_settings';

/// `owntalk_room_settings {"token":"<roomToken>","revision":<int>}`: the
/// shared settings of [roomToken] reached [revision] on the server.
///
/// A hint only. It carries no settings, so a forged or stale one costs at most
/// one conditional re-read of a document the user may already read.
final class OwnTalkRoomSettingsSignal {
  const OwnTalkRoomSettingsSignal({
    required this.roomToken,
    required this.revision,
  });

  final ConversationToken roomToken;
  final int revision;

  @override
  String toString() => 'OwnTalkRoomSettingsSignal(revision: $revision)';
}

/// Parses an `owntalk_room_settings` frame, or null for any other frame and
/// for one whose body is oversized, not a JSON object, or lacks a valid room
/// token and a non-negative integer revision.
OwnTalkRoomSettingsSignal? parseOwnTalkRoomSettingsFrame(String frame) {
  final trimmed = frame.trim();
  if (trimmed.isEmpty || trimmed.length > 256) {
    return null;
  }
  final split = trimmed.indexOf(RegExp(r'\s'));
  if (split < 0 || trimmed.substring(0, split) != ownTalkRoomSettingsFrameName) {
    return null;
  }
  final Object? body;
  try {
    body = jsonDecode(trimmed.substring(split));
  } on FormatException {
    return null;
  }
  if (body is! Map<String, Object?>) {
    return null;
  }
  final revision = body['revision'];
  if (revision is! int || revision < 0) {
    return null;
  }
  try {
    return OwnTalkRoomSettingsSignal(
      roomToken: ConversationToken.parse(body['token'], path: r'$.token'),
      revision: revision,
    );
  } on TalkProtocolException {
    return null;
  }
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
