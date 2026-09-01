import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import '../json_value.dart';
import '../protocol_exception.dart';
import '../server_base.dart';

const String remoteWipeContractUserAgent =
    'com.nkshub.nextcloudtalk remote-wipe-contract/0.1';

const int remoteWipeMaximumResponseBytes = 64 * 1024;

const TalkProtocolErrorCode _requestCode =
    TalkProtocolErrorCode.invalidRemoteWipeRequest;
const TalkProtocolErrorCode _responseCode =
    TalkProtocolErrorCode.invalidRemoteWipeResponse;

/// Which of the two wipe routes a request addresses.
enum RemoteWipeStep {
  /// `POST /index.php/core/wipe/check` — does this token have to wipe?
  check,

  /// `POST /index.php/core/wipe/success` — the device has wiped.
  ///
  /// Reported after the local data is gone, so the server stops listing the
  /// device as pending. Losing this report costs nothing on the device.
  success;

  String get path => switch (this) {
    RemoteWipeStep.check => '/index.php/core/wipe/check',
    RemoteWipeStep.success => '/index.php/core/wipe/success',
  };
}

/// Asks the server whether this app password was marked for remote wipe.
///
/// The app password is the only identifier the route takes; it is sent in the
/// body rather than as a header because that is what the core route reads, and
/// it never appears in a URL, a log line or this object's `toString`.
final class RemoteWipeRequest {
  RemoteWipeRequest({
    required this.server,
    required this.step,
    required String appPassword,
    this.userAgent = remoteWipeContractUserAgent,
  }) : _appPassword = appPassword {
    if (appPassword.isEmpty || appPassword.length > 512) {
      protocolFailure(_requestCode, r'$.appPassword');
    }
    if (userAgent.isEmpty ||
        userAgent.length > 256 ||
        userAgent.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
      protocolFailure(_requestCode, r'$.headers.userAgent');
    }
  }

  final ServerBase server;
  final RemoteWipeStep step;
  final String userAgent;
  final String _appPassword;

  String get httpMethod => 'POST';

  Uri get uri => server.uri.replace(path: '${server.basePath}${step.path}');

  Map<String, String> get headers => UnmodifiableMapView({
    'User-Agent': userAgent,
    'Accept': 'application/json',
    'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
  });

  Uint8List get bodyBytes => Uint8List.fromList(
    utf8.encode('token=${Uri.encodeQueryComponent(_appPassword)}'),
  );

  @override
  String toString() => 'RemoteWipeRequest(step: ${step.name})';
}

/// What the server said about this app password.
enum RemoteWipeOutcome {
  /// The server asked for this device's copy of the account to be wiped.
  wipeRequested,

  /// Nothing to wipe. The token may be unknown, already wiped, or simply not
  /// marked — the route answers 404 for all three and the client must treat
  /// them the same: keep the account.
  notRequested,

  /// The report was accepted.
  acknowledged,

  /// The server could not answer right now. Nothing is wiped on a maybe.
  transientError,
}

final class RemoteWipeResponse {
  const RemoteWipeResponse._({required this.request, required this.outcome});

  final RemoteWipeRequest request;
  final RemoteWipeOutcome outcome;

  @override
  String toString() => 'RemoteWipeResponse(outcome: ${outcome.name})';
}

RemoteWipeResponse decodeRemoteWipeResponse({
  required RemoteWipeRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  if (body.length > remoteWipeMaximumResponseBytes) {
    protocolFailure(_responseCode, r'$.body.length');
  }
  RemoteWipeResponse result(RemoteWipeOutcome outcome) =>
      RemoteWipeResponse._(request: request, outcome: outcome);

  switch (statusCode) {
    case 200:
      if (request.step == RemoteWipeStep.success) {
        return result(RemoteWipeOutcome.acknowledged);
      }
      // Only an explicit `wipe: true` wipes an account. A 200 whose body says
      // anything else — or nothing — leaves the account alone.
      return result(
        _wipeFlag(body)
            ? RemoteWipeOutcome.wipeRequested
            : RemoteWipeOutcome.notRequested,
      );
    case 404:
      return result(RemoteWipeOutcome.notRequested);
    case 429:
    case 500:
    case 502:
    case 503:
      return result(RemoteWipeOutcome.transientError);
    default:
      protocolFailure(_responseCode, r'$.statusCode');
  }
}

bool _wipeFlag(Uint8List body) {
  if (body.isEmpty) {
    return false;
  }
  final String source;
  try {
    source = utf8.decode(body);
  } on FormatException {
    protocolFailure(_responseCode, r'$.body');
  }
  final decoded = decodeJsonRejectingDuplicateMembers(
    source,
    code: _responseCode,
    path: r'$.body',
  );
  final root = requireObject(decoded, path: r'$', code: _responseCode);
  return root['wipe'] == true;
}
