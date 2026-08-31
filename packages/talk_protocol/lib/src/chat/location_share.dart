import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import '../identifiers.dart';
import '../json_value.dart';
import '../protocol_exception.dart';
import '../server_base.dart';
import 'identifiers.dart';
import 'models.dart';
import 'request.dart';

const int locationShareMaximumResponseBytes = 2 * 1024 * 1024;

enum LocationShareClassification {
  confirmed,
  invalidInput,
  reauthenticationRequired,
  permissionDenied,
  notFound,
  rateLimited,
  serviceUnavailable,
}

final class LocationShareRequest {
  LocationShareRequest({
    required this.accountId,
    required this.requestId,
    required this.server,
    required this.roomToken,
    required this.latitude,
    required this.longitude,
    required this.name,
    required bool locationSharingAvailable,
    this.threadId,
    this.userAgent = chatContractUserAgent,
  }) {
    if (userAgent.isEmpty ||
        userAgent.length > 256 ||
        userAgent.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
      _failure(r'$.headers.userAgent');
    }
    if (!locationSharingAvailable) {
      _failure(r'$.capabilities.geo-location-sharing');
    }
    if (!latitude.isFinite || latitude < -90 || latitude > 90) {
      _failure(r'$.latitude');
    }
    if (!longitude.isFinite || longitude < -180 || longitude > 180) {
      _failure(r'$.longitude');
    }
    if (name.trim().isEmpty ||
        name != name.trim() ||
        name.length > 256 ||
        name.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      _failure(r'$.name');
    }
    if (threadId != null && threadId! < 1) {
      _failure(r'$.threadId');
    }
  }

  final AccountId accountId;
  final ChatRequestId requestId;
  final ServerBase server;
  final ConversationToken roomToken;
  final double latitude;
  final double longitude;
  final String name;
  final int? threadId;
  final String userAgent;

  String get latitudeText => _coordinate(latitude);
  String get longitudeText => _coordinate(longitude);
  String get objectId => 'geo:$latitudeText,$longitudeText';
  Uri get uri => server.uri.replace(
    path: '${server.basePath}$chatV1Path/${roomToken.value}/share',
  );
  Map<String, String> get headers =>
      UnmodifiableMapView({'OCS-APIRequest': 'true', 'User-Agent': userAgent});
  Map<String, Object> get formBody => UnmodifiableMapView({
    'objectType': 'geo-location',
    'objectId': objectId,
    'metaData': jsonEncode({
      'type': 'geo-location',
      'id': objectId,
      'latitude': latitudeText,
      'longitude': longitudeText,
      'name': name,
    }),
    'referenceId': requestId.value,
    'threadId': ?threadId,
  });

  @override
  String toString() => 'LocationShareRequest(<redacted>)';
}

final class LocationShareResponse {
  const LocationShareResponse({
    required this.request,
    required this.classification,
    required this.message,
  });

  final LocationShareRequest request;
  final LocationShareClassification classification;
  final ChatMessage? message;
}

LocationShareResponse decodeLocationShareResponse({
  required LocationShareRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  final failure = switch (statusCode) {
    400 || 413 => LocationShareClassification.invalidInput,
    401 => LocationShareClassification.reauthenticationRequired,
    403 => LocationShareClassification.permissionDenied,
    404 => LocationShareClassification.notFound,
    429 => LocationShareClassification.rateLimited,
    500 || 502 || 503 || 504 => LocationShareClassification.serviceUnavailable,
    _ => null,
  };
  if (failure != null) {
    return LocationShareResponse(
      request: request,
      classification: failure,
      message: null,
    );
  }
  if (statusCode != 201) {
    throw const TalkProtocolException(
      TalkProtocolErrorCode.unsupportedHttpStatus,
      path: r'$.statusCode',
    );
  }
  if (body.isEmpty || body.length > locationShareMaximumResponseBytes) {
    _responseFailure(r'$.body');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(body));
  } on FormatException {
    _responseFailure(r'$.body');
  }
  final root = requireObject(
    decoded,
    path: r'$',
    code: TalkProtocolErrorCode.invalidLocationShareResponse,
  );
  final ocs = requireObject(
    root['ocs'],
    path: r'$.ocs',
    code: TalkProtocolErrorCode.invalidLocationShareResponse,
  );
  final meta = requireObject(
    ocs['meta'],
    path: r'$.ocs.meta',
    code: TalkProtocolErrorCode.invalidLocationShareResponse,
  );
  if (meta['status'] != 'ok' || meta['statuscode'] != 201) {
    _responseFailure(r'$.ocs.meta');
  }
  final message = ChatMessage.fromJson(ocs['data']);
  final matchingLocation = message.messageParameters.values.any((parameter) {
    final location = ChatGeoLocation.fromParameter(parameter);
    return parameter.id == request.objectId &&
        location != null &&
        location.latitude == request.latitude &&
        location.longitude == request.longitude &&
        location.name == request.name;
  });
  final matchingThread = request.threadId == null
      ? message.threadId == message.messageId
      : message.threadId == request.threadId;
  if (message.roomToken != request.roomToken ||
      message.referenceId != request.requestId.value ||
      !matchingLocation ||
      !matchingThread) {
    _responseFailure(r'$.ocs.data');
  }
  return LocationShareResponse(
    request: request,
    classification: LocationShareClassification.confirmed,
    message: message,
  );
}

String _coordinate(double value) => (value == 0 ? 0.0 : value).toString();

Never _failure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidLocationShareRequest, path);
Never _responseFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidLocationShareResponse, path);
