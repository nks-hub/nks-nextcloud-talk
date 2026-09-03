import '../json_value.dart';
import '../protocol_exception.dart';
import '../server_base.dart';

final RegExp _tokenPattern = RegExp(r'^[A-Za-z0-9._~-]{32,4096}$');

/// A bounded opaque Login Flow v2 token.
final class OpaqueLoginToken {
  OpaqueLoginToken._parse(Object? value, {required String path})
    : value = _validate(value, path);

  /// Parses a token received outside an initialization response.
  factory OpaqueLoginToken.parse(Object? value) =>
      OpaqueLoginToken._parse(value, path: r'$.token');

  final String value;

  static String _validate(Object? value, String path) {
    final token = requireString(
      value,
      path: path,
      code: TalkProtocolErrorCode.invalidLoginInitialization,
      minLength: 32,
      maxLength: 4096,
    );
    if (!_tokenPattern.hasMatch(token)) {
      protocolFailure(TalkProtocolErrorCode.invalidLoginInitialization, path);
    }
    return token;
  }

  @override
  String toString() => 'OpaqueLoginToken(<redacted>)';
}

/// Validated browser and poll coordinates returned by Login Flow v2.
final class LoginFlowInitialization {
  const LoginFlowInitialization._({
    required this.loginUri,
    required this.pollEndpoint,
    required this.pollToken,
  });

  factory LoginFlowInitialization.fromJson(
    Object? json, {
    required ServerBase verifiedServer,
    ServerOriginPolicy policy = ServerOriginPolicy.production,
  }) {
    const code = TalkProtocolErrorCode.invalidLoginInitialization;
    final value = requireObject(json, path: r'$', code: code);
    final poll = requireObject(value['poll'], path: r'$.poll', code: code);
    final rawLogin = requireString(
      value['login'],
      path: r'$.login',
      code: code,
      minLength: 12,
      maxLength: 4096,
    );
    final rawPollEndpoint = requireString(
      poll['endpoint'],
      path: r'$.poll.endpoint',
      code: code,
      minLength: 12,
      maxLength: 4096,
    );
    final pollToken = OpaqueLoginToken._parse(
      poll['token'],
      path: r'$.poll.token',
    );

    final Uri loginUri;
    final Uri pollEndpoint;
    try {
      loginUri = ServerBase.parse(rawLogin, policy: policy).uri;
      pollEndpoint = ServerBase.parse(rawPollEndpoint, policy: policy).uri;
    } on TalkProtocolException {
      protocolFailure(code, r'$.login');
    }
    if (!verifiedServer.hasSameOrigin(loginUri) ||
        !verifiedServer.hasSameOrigin(pollEndpoint)) {
      protocolFailure(TalkProtocolErrorCode.untrustedLoginEndpoint, r'$.login');
    }

    // Nextcloud advertises the endpoints with `index.php` unless the server
    // is configured for pretty URLs (`htaccess.RewriteBase`, the default of
    // the official Docker image), in which case the same routes come without
    // it. Both are the server's own routes; anything else is not.
    final basePath = verifiedServer.basePath;
    const routePrefixes = <String>['/index.php', ''];
    String? loginPrefix;
    for (final route in routePrefixes) {
      if (pollEndpoint.path == '$basePath$route/login/v2/poll' &&
          loginUri.path.startsWith('$basePath$route/login/v2/flow/')) {
        loginPrefix = '$basePath$route/login/v2/flow/';
        break;
      }
    }
    if (loginPrefix == null) {
      protocolFailure(
        TalkProtocolErrorCode.untrustedLoginEndpoint,
        r'$.poll.endpoint',
      );
    }
    final loginToken = loginUri.path.substring(loginPrefix.length);
    if (!_tokenPattern.hasMatch(loginToken) || loginToken == pollToken.value) {
      protocolFailure(code, r'$.login');
    }

    return LoginFlowInitialization._(
      loginUri: loginUri,
      pollEndpoint: pollEndpoint,
      pollToken: pollToken,
    );
  }

  final Uri loginUri;
  final Uri pollEndpoint;
  final OpaqueLoginToken pollToken;

  Map<String, String> get pollFormFields => {'token': pollToken.value};

  String get pollFormBody => Uri(queryParameters: pollFormFields).query;

  @override
  String toString() => 'LoginFlowInitialization(<redacted>)';
}

/// Single-use account credentials returned by a successful Login Flow poll.
final class LoginFlowCredentials {
  const LoginFlowCredentials._({
    required this.server,
    required this.loginName,
    required this.appPassword,
  });

  factory LoginFlowCredentials.fromJson(
    Object? json, {
    required ServerBase verifiedServer,
    ServerOriginPolicy policy = ServerOriginPolicy.production,
  }) {
    const code = TalkProtocolErrorCode.invalidLoginCredentials;
    final value = requireObject(json, path: r'$', code: code);
    final rawServer = requireString(
      value['server'],
      path: r'$.server',
      code: code,
      minLength: 12,
      maxLength: 4096,
    );
    final loginName = requireString(
      value['loginName'],
      path: r'$.loginName',
      code: code,
      minLength: 1,
      maxLength: 1024,
    );
    final appPassword = requireString(
      value['appPassword'],
      path: r'$.appPassword',
      code: code,
      minLength: 1,
      maxLength: 4096,
    );

    final ServerBase server;
    try {
      server = ServerBase.parse(rawServer, policy: policy);
    } on TalkProtocolException {
      protocolFailure(code, r'$.server');
    }
    if (server != verifiedServer) {
      protocolFailure(
        TalkProtocolErrorCode.untrustedCredentialServer,
        r'$.server',
      );
    }
    return LoginFlowCredentials._(
      server: server,
      loginName: loginName,
      appPassword: appPassword,
    );
  }

  final ServerBase server;
  final String loginName;
  final String appPassword;

  @override
  String toString() => 'LoginFlowCredentials(<redacted>)';
}

/// Result of a Login Flow v2 poll without over-interpreting HTTP 404.
sealed class LoginPollResult {
  const LoginPollResult();
}

/// The token is pending or otherwise unavailable; HTTP 404 is intentionally
/// not classified more precisely.
final class LoginPollPending extends LoginPollResult {
  const LoginPollPending();
}

/// A successful poll carrying credentials that must be committed securely.
final class LoginPollSucceeded extends LoginPollResult {
  const LoginPollSucceeded(this.credentials);

  final LoginFlowCredentials credentials;
}

/// Classifies a Login Flow poll response using only supported HTTP semantics.
LoginPollResult parseLoginPollResponse({
  required int statusCode,
  required Object? json,
  required ServerBase verifiedServer,
  ServerOriginPolicy policy = ServerOriginPolicy.production,
}) {
  if (statusCode == 404) {
    return const LoginPollPending();
  }
  if (statusCode == 200) {
    return LoginPollSucceeded(
      LoginFlowCredentials.fromJson(
        json,
        verifiedServer: verifiedServer,
        policy: policy,
      ),
    );
  }
  protocolFailure(
    TalkProtocolErrorCode.unsupportedHttpStatus,
    r'$.http.status',
  );
}

/// Form fields for the empty Login Flow v2 initialization request.
const Map<String, String> loginFlowInitializationFormFields = {};
