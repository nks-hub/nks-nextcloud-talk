import '../server_base.dart';
import 'login_flow.dart';

const String _loginPrefix = 'nc://login/';
const String _oneTimeLoginPrefix = 'nc://onetime-login/';
const String _userKey = 'user:';
const String _serverKey = 'server:';
const String _passwordKey = 'password:';
const int _maximumElements = 3;

// A QR code cannot carry more than 2953 bytes of binary data, so anything
// longer never came out of a scanner and is not worth decoding.
const int _maximumPayloadLength = 4096;
const int _maximumLoginNameLength = 1024;
const int _maximumSecretLength = 4096;

/// A `nc://login/` payload that a camera read off a QR code.
///
/// The wire format is Nextcloud's, not ours: `talk-android`'s `LoginRepository`
/// defines the two prefixes, the three `key:value` elements separated by `&`,
/// the URL-decoded values and the cap of three elements.
sealed class QrLoginPayload {
  const QrLoginPayload({required this.server});

  /// The canonical server the payload names.
  final ServerBase server;
}

/// A payload that named only a server, with no identity and no secret.
///
/// Upstream Android rejects this outright. We keep it as a distinct result so
/// the caller can start a normal Login Flow v2 against that server instead of
/// telling the user the code was unreadable — nothing secret is involved and
/// the server still authenticates the user itself.
final class QrLoginServerOnly extends QrLoginPayload {
  const QrLoginServerOnly({required super.server});

  @override
  String toString() => 'QrLoginServerOnly($server)';
}

/// A payload carrying an identity and a secret for that identity.
final class QrLoginCredentials extends QrLoginPayload {
  const QrLoginCredentials({
    required super.server,
    required this.loginName,
    required this.secret,
    required this.isOneTime,
  });

  final String loginName;

  /// The app password, or — when [isOneTime] — the single-use token that has
  /// to be exchanged for one at `ocs/v2.php/core/getapppassword-onetime`.
  final String secret;

  final bool isOneTime;

  /// Reuses the Login Flow v2 commit path for an already-issued app password.
  LoginFlowCredentials toLoginFlowCredentials() {
    return LoginFlowCredentials.scanned(
      server: server,
      loginName: loginName,
      appPassword: secret,
    );
  }

  @override
  String toString() => 'QrLoginCredentials(<redacted>)';
}

/// Parses an untrusted scanned string, returning null for anything that is not
/// a well-formed Nextcloud login payload.
///
/// Deliberately stricter than upstream on two points, neither of which can
/// accept a payload upstream would reject: an unrecognised key and a repeated
/// key both fail here, where upstream silently ignores the first and lets the
/// last of the second win.
QrLoginPayload? parseQrLoginPayload(
  String raw, {
  ServerOriginPolicy policy = ServerOriginPolicy.production,
}) {
  if (raw.length > _maximumPayloadLength) {
    return null;
  }
  final bool isOneTime;
  final String body;
  if (raw.startsWith(_oneTimeLoginPrefix)) {
    isOneTime = true;
    body = raw.substring(_oneTimeLoginPrefix.length);
  } else if (raw.startsWith(_loginPrefix)) {
    isOneTime = false;
    body = raw.substring(_loginPrefix.length);
  } else {
    return null;
  }

  final elements = body.split('&');
  if (elements.length > _maximumElements) {
    return null;
  }

  String? rawServer;
  String? loginName;
  String? secret;
  for (final element in elements) {
    final String key;
    if (element.startsWith(_userKey)) {
      key = _userKey;
    } else if (element.startsWith(_passwordKey)) {
      key = _passwordKey;
    } else if (element.startsWith(_serverKey)) {
      key = _serverKey;
    } else {
      return null;
    }
    final String value;
    try {
      // `java.net.URLDecoder.decode(value, "UTF-8")` is what upstream applies,
      // and it turns `+` into a space; `Uri.decodeComponent` would not.
      value = Uri.decodeQueryComponent(element.substring(key.length));
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
    if (value.isEmpty) {
      return null;
    }
    switch (key) {
      case _userKey:
        if (loginName != null || value.length > _maximumLoginNameLength) {
          return null;
        }
        loginName = value;
      case _passwordKey:
        if (secret != null || value.length > _maximumSecretLength) {
          return null;
        }
        secret = value;
      case _serverKey:
        if (rawServer != null) {
          return null;
        }
        rawServer = value;
    }
  }

  if (rawServer == null) {
    return null;
  }
  final ServerBase server;
  try {
    server = ServerBase.parse(rawServer, policy: policy);
  } on Object {
    return null;
  }

  if (loginName == null && secret == null) {
    // A one-time prefix without a token has nothing to exchange, so it is not
    // the same harmless "just a server address" case.
    return isOneTime ? null : QrLoginServerOnly(server: server);
  }
  if (loginName == null || secret == null) {
    return null;
  }
  return QrLoginCredentials(
    server: server,
    loginName: loginName,
    secret: secret,
    isOneTime: isOneTime,
  );
}
