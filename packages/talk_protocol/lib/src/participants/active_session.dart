import 'dart:convert';
import 'dart:typed_data';

import '../conversations/models.dart';
import '../identifiers.dart';
import '../json_value.dart';
import '../protocol_exception.dart';
import '../server_base.dart';

final class ActiveRoomSessionRequest {
  ActiveRoomSessionRequest({
    required this.accountId,
    required this.server,
    required this.roomToken,
  });

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;

  Uri get uri => server.uri.replace(
    path:
        '${server.basePath}/ocs/v2.php/apps/spreed/api/v4/room/'
        '${roomToken.value}/participants/active',
    queryParameters: const <String, String>{'format': 'json'},
  );

  Map<String, String> get headers => const <String, String>{
    'Accept': 'application/json',
    'OCS-APIRequest': 'true',
  };
}

sealed class ActiveRoomSessionResponse {
  const ActiveRoomSessionResponse();
}

final class ActiveRoomSessionSuccess extends ActiveRoomSessionResponse {
  const ActiveRoomSessionSuccess(this.room);

  final ConversationRoom room;
}

final class ActiveRoomSessionReauthenticationRequired
    extends ActiveRoomSessionResponse {
  const ActiveRoomSessionReauthenticationRequired();
}

final class ActiveRoomSessionForbidden extends ActiveRoomSessionResponse {
  const ActiveRoomSessionForbidden();
}

final class ActiveRoomSessionMissing extends ActiveRoomSessionResponse {
  const ActiveRoomSessionMissing();
}

final class ActiveRoomSessionConflict extends ActiveRoomSessionResponse {
  const ActiveRoomSessionConflict();
}

final class ActiveRoomSessionHttpFailure extends ActiveRoomSessionResponse {
  const ActiveRoomSessionHttpFailure();
}

ActiveRoomSessionResponse decodeActiveRoomSessionResponse({
  required int statusCode,
  required Uint8List body,
}) {
  if (statusCode == 401) {
    return const ActiveRoomSessionReauthenticationRequired();
  }
  if (statusCode == 403) {
    return const ActiveRoomSessionForbidden();
  }
  if (statusCode == 404) {
    return const ActiveRoomSessionMissing();
  }
  if (statusCode == 409) {
    return const ActiveRoomSessionConflict();
  }
  if (statusCode != 200) {
    return const ActiveRoomSessionHttpFailure();
  }
  final Object? json;
  try {
    json = jsonDecode(utf8.decode(body));
  } on FormatException {
    protocolFailure(TalkProtocolErrorCode.invalidConversationResponse, r'$');
  }
  final root = requireObject(
    json,
    path: r'$',
    code: TalkProtocolErrorCode.invalidConversationResponse,
  );
  final ocs = requireObject(
    root['ocs'],
    path: r'$.ocs',
    code: TalkProtocolErrorCode.invalidConversationResponse,
  );
  final meta = requireObject(
    ocs['meta'],
    path: r'$.ocs.meta',
    code: TalkProtocolErrorCode.invalidConversationResponse,
  );
  if (meta['status'] != 'ok' || meta['statuscode'] != 200) {
    protocolFailure(TalkProtocolErrorCode.ocsFailure, r'$.ocs.meta');
  }
  return ActiveRoomSessionSuccess(ConversationRoom.fromJson(ocs['data']));
}
