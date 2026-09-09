part of 'request.dart';

/// The object bindings this client offers to take off a conversation.
///
/// Measured against the reference instance on 9 September 2026 by creating one
/// room of each kind and unbinding it:
///
/// - `event` and `instant_meeting` answer `200` and come back with an empty
///   `objectType`: an ordinary conversation that outlives what made it.
/// - `phone_temporary` answers `200` and comes back as **`phone_persist`**,
///   not as an ordinary room. The operation keeps a temporary phone room
///   rather than untyping it, which is the point of the endpoint and not
///   something a caller should assume away.
/// - `phone_persist` answers `400 {"error": "object-type"}`: already kept.
/// - Every other binding, including an ordinary room, `note_to_self` and the
///   sample room, answers `400 {"error": "object-type"}`.
const Set<String> unbindableObjectTypes = <String>{
  'event',
  'instant_meeting',
  'phone_temporary',
};

/// Takes the object binding off a conversation so it survives that object.
///
/// `DELETE /ocs/v2.php/apps/spreed/api/v4/room/{token}/object`, behind the
/// server's `unbind-conversation` capability and moderator authority — a plain
/// participant is refused with `403`, an unknown room with `404`.
///
/// This is the stable operation, not the prerelease preserve/unpreserve pair.
final class UnbindConversationRequest extends RoomAdministrationRequest {
  UnbindConversationRequest({
    required super.accountId,
    required super.server,
    required super.roomToken,
    required String objectType,
    required CapabilitySnapshot capabilities,
    super.userAgent = roomSettingsContractUserAgent,
  }) {
    if (capabilities.context != CapabilityContext.authenticated ||
        !capabilities.supportsTalk('unbind-conversation')) {
      protocolFailure(
        TalkProtocolErrorCode.invalidRoomSettingsRequest,
        r'$.capabilities.unbind-conversation',
      );
    }
    // Asking for a binding the server will refuse costs a round trip and
    // teaches the user nothing; the caller should not have offered it.
    if (!unbindableObjectTypes.contains(objectType)) {
      protocolFailure(
        TalkProtocolErrorCode.invalidRoomSettingsRequest,
        r'$.objectType',
      );
    }
  }

  @override
  String get httpMethod => 'DELETE';

  @override
  Uri get uri => _roomUri(server, roomToken, 'object');

  @override
  Map<String, String>? get formBody => null;

  @override
  String toString() => 'UnbindConversationRequest(sensitive: <redacted>)';
}
