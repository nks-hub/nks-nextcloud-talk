import 'dart:collection';

import '../protocol_exception.dart';
import '../server_base.dart';
import 'identifiers.dart';
import 'request.dart' show conversationV4Path;

const String createConversationContractUserAgent =
    'com.nkshub.nextcloudtalk create-conversation-contract/0.1';

/// The Talk v4 `roomType` values this contract is willing to create.
enum CreateConversationRoomType {
  oneToOne(1),
  group(2),
  public(3);

  const CreateConversationRoomType(this.wireValue);

  final int wireValue;
}

/// A request to create a recipient conversation or a standalone group/public
/// room. Posts to the same `apps/spreed/api/v4/room` endpoint that the
/// conversation list reads from.
final class CreateConversationRequest {
  CreateConversationRequest({
    required this.accountId,
    required this.requestId,
    required this.server,
    required this.roomType,
    this.inviteId,
    this.inviteSource,
    this.roomName,
    this.userAgent = createConversationContractUserAgent,
  }) {
    final invite = inviteId;
    final source = inviteSource;
    if ((invite == null) != (source == null)) {
      protocolFailure(
        TalkProtocolErrorCode.invalidCreateConversationRequest,
        r'$.body.invite',
      );
    }
    if (invite != null &&
        (invite.isEmpty ||
            invite.length > 256 ||
            _hasControlCharacter(invite))) {
      protocolFailure(
        TalkProtocolErrorCode.invalidCreateConversationRequest,
        r'$.body.invite',
      );
    }
    if (source != null && source != 'users' && source != 'groups') {
      protocolFailure(
        TalkProtocolErrorCode.invalidCreateConversationRequest,
        r'$.body.source',
      );
    }
    final name = roomName;
    if (roomType == CreateConversationRoomType.oneToOne) {
      if (invite == null || source != 'users') {
        protocolFailure(
          TalkProtocolErrorCode.invalidCreateConversationRequest,
          r'$.body.invite',
        );
      }
      if (name != null) {
        protocolFailure(
          TalkProtocolErrorCode.invalidCreateConversationRequest,
          r'$.body.roomName',
        );
      }
    } else {
      if (name == null ||
          name.trim().isEmpty ||
          name.length > 200 ||
          _hasControlCharacter(name)) {
        protocolFailure(
          TalkProtocolErrorCode.invalidCreateConversationRequest,
          r'$.body.roomName',
        );
      }
      if (roomType == CreateConversationRoomType.public && invite != null) {
        protocolFailure(
          TalkProtocolErrorCode.invalidCreateConversationRequest,
          r'$.body.invite',
        );
      }
    }
    if (userAgent.isEmpty ||
        userAgent.length > 256 ||
        userAgent.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
      protocolFailure(
        TalkProtocolErrorCode.invalidCreateConversationRequest,
        r'$.headers.userAgent',
      );
    }
  }

  final AccountId accountId;
  final ConversationRequestId requestId;
  final ServerBase server;
  final CreateConversationRoomType roomType;

  /// The user id or group id to invite, matching a recipient's `id`.
  /// Empty group and public rooms omit it together with [inviteSource].
  final String? inviteId;

  /// Either `users` or `groups`, matching a recipient's share type.
  final String? inviteSource;
  final String? roomName;
  final String userAgent;

  Map<String, String> get formBody => UnmodifiableMapView({
    'roomType': roomType.wireValue.toString(),
    'invite': ?inviteId,
    'source': ?inviteSource,
    'roomName': ?roomName,
  });

  Map<String, String> get headers =>
      UnmodifiableMapView({'OCS-APIRequest': 'true', 'User-Agent': userAgent});

  Uri get uri => server.uri.replace(
    path: '${server.basePath}$conversationV4Path',
    queryParameters: const {'format': 'json'},
  );

  @override
  String toString() => 'CreateConversationRequest(roomType: ${roomType.name})';
}

bool _hasControlCharacter(String value) =>
    value.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f);
