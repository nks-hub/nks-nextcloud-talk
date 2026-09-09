part of 'request.dart';

/// Rings one attendee of the call that is running now.
///
/// `POST /ocs/v2.php/apps/spreed/api/v4/call/{token}/ring/{attendeeId}`.
/// Measured against the reference instance on 9 September 2026:
///
/// - **`400 {"error": "in-call"}` when no call is running.** The endpoint
///   exists only for a live call, which is why this is offered from the call
///   itself and nowhere else.
/// - `200` during a call for a real attendee of the room.
/// - `404` for an attendee id the room does not have, and `404` for an unknown
///   room.
/// - The server does NOT police who is worth ringing: ringing an attendee who
///   is already in the call answers `200`, and so does ringing from an account
///   that has not joined it. Deciding that is this side's job.
///
/// The attendee id is the room's own, from the participant list — not a user
/// id, and not comparable across rooms.
final class RingAttendeeRequest extends CallRestRequest {
  RingAttendeeRequest({
    required super.context,
    required this.attendeeId,
    super.userAgent = callRestContractUserAgent,
  }) {
    if (attendeeId < 1) {
      protocolFailure(
        TalkProtocolErrorCode.invalidCallRequest,
        r'$.attendeeId',
      );
    }
  }

  final int attendeeId;

  @override
  CallRestMethod get method => CallRestMethod.post;

  @override
  Map<String, List<String>>? get formFields => null;

  @override
  Uri get uri => authority.server.uri.replace(
    path:
        '${authority.server.basePath}$callRestV4Path/'
        '${roomToken.value}/ring/$attendeeId',
    queryParameters: queryParameters,
  );

  @override
  String toString() => 'RingAttendeeRequest(sensitive: <redacted>)';
}
