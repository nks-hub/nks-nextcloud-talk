import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import '../identifiers.dart';
import '../protocol_exception.dart';
import '../server_base.dart';
import 'profile.dart';

const String conversationTagsContractUserAgent =
    'com.nkshub.nextcloudtalk conversation-tags-contract/0.1';
const int maximumAssignedConversationTags = 20;

const TalkProtocolErrorCode _requestCode =
    TalkProtocolErrorCode.invalidRoomSettingsRequest;

/// Reads every built-in and custom tag owned by one authenticated account.
final class FetchConversationTagsRequest {
  FetchConversationTagsRequest({
    required this.accountId,
    required this.server,
    required ConversationTagsProfile profile,
    this.userAgent = conversationTagsContractUserAgent,
  }) {
    if (!profile.canLoadDefinitions) {
      protocolFailure(_requestCode, r'$.profile.canLoadDefinitions');
    }
    _validateUserAgent(userAgent);
  }

  final AccountId accountId;
  final ServerBase server;
  final String userAgent;

  String get httpMethod => 'GET';

  Uri get uri => server.uri.replace(
    path: '${server.basePath}/ocs/v2.php/apps/spreed/api/v4/tags',
    queryParameters: const {'format': 'json'},
  );

  Map<String, String> get headers =>
      UnmodifiableMapView({'OCS-APIRequest': 'true', 'User-Agent': userAgent});

  @override
  String toString() => 'FetchConversationTagsRequest(<redacted>)';
}

/// Replaces this participant's complete tag assignment for one room.
final class AssignConversationTagsRequest {
  AssignConversationTagsRequest({
    required this.accountId,
    required this.server,
    required this.roomToken,
    required ConversationTagsProfile profile,
    required Iterable<String> tagIds,
    this.userAgent = conversationTagsContractUserAgent,
  }) : tagIds = _validateTagIds(tagIds) {
    if (!profile.canAssign) {
      protocolFailure(_requestCode, r'$.profile.canAssign');
    }
    _validateUserAgent(userAgent);
  }

  final AccountId accountId;
  final ServerBase server;
  final ConversationToken roomToken;
  final Set<String> tagIds;
  final String userAgent;

  String get httpMethod => 'POST';

  Uri get uri => server.uri.replace(
    path:
        '${server.basePath}/ocs/v2.php/apps/spreed/api/v4/room/'
        '${roomToken.value}/tags',
    queryParameters: const {'format': 'json'},
  );

  Map<String, String> get headers => UnmodifiableMapView({
    'OCS-APIRequest': 'true',
    'User-Agent': userAgent,
    'Content-Type': 'application/json; charset=utf-8',
  });

  Uint8List get bodyBytes => Uint8List.fromList(
    utf8.encode(jsonEncode({'tagIds': tagIds.toList(growable: false)})),
  );

  @override
  String toString() =>
      'AssignConversationTagsRequest(tagCount: ${tagIds.length})';
}

Set<String> _validateTagIds(Iterable<String> values) {
  final result = <String>{};
  for (final value in values) {
    if (result.length >= maximumAssignedConversationTags ||
        value.isEmpty ||
        value.length > 32 ||
        !_numericId.hasMatch(value) ||
        !result.add(value)) {
      protocolFailure(_requestCode, r'$.body.tagIds');
    }
  }
  return UnmodifiableSetView(result);
}

void _validateUserAgent(String value) {
  if (value.isEmpty ||
      value.length > 256 ||
      value.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
    protocolFailure(_requestCode, r'$.headers.userAgent');
  }
}

final RegExp _numericId = RegExp(r'^\d+$');
