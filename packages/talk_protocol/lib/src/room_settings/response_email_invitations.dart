part of 'response.dart';

/// The largest number of invalid line numbers this contract keeps. The server
/// reports one entry per bad row and a pathological file could name tens of
/// thousands; a client only ever shows the first handful.
const int emailInvitationInvalidLineLimit = 100;

sealed class ImportEmailInvitationsResponse {
  const ImportEmailInvitationsResponse(this.request);

  final ImportEmailInvitationsRequest request;
  int get statusCode;
}

/// HTTP 200. The file parsed cleanly and the server reported its counts.
///
/// Measured against Nextcloud Talk on 9 September 2026: a preview answers
/// `{"invites":2,"duplicates":0}` and a real import answers
/// `{"invites":2,"duplicates":0,"type":3}`. The extra `type` — the room type
/// after the import — is the only thing on the wire that separates the two,
/// so it is what [invitationsSent] reads, and a payload that disagrees with
/// the request's `testRun` is a protocol failure rather than a guess. That
/// keeps the fail-closed direction right: a preview can never be reported as
/// "nothing sent" when the server actually sent.
final class ImportEmailInvitationsSuccess
    extends ImportEmailInvitationsResponse {
  const ImportEmailInvitationsSuccess._({
    required ImportEmailInvitationsRequest request,
    required this.invites,
    required this.duplicates,
    required this.roomType,
  }) : super(request);

  @override
  int get statusCode => 200;

  /// Addresses the server accepted. On a preview, what it would invite.
  final int invites;

  /// Addresses skipped because they are already an attendee of this room, or
  /// repeated inside the file.
  final int duplicates;

  /// The room type the server reported, present only on a real import.
  final int? roomType;

  /// `true` only when invitations really left the server.
  bool get invitationsSent => roomType != null;

  @override
  String toString() =>
      'ImportEmailInvitationsSuccess(invites: $invites, '
      'duplicates: $duplicates, sent: $invitationsSent)';
}

/// HTTP 400 with per-line detail: the file parsed, but some rows are not
/// addresses. Nothing is imported — the server refuses the whole file.
///
/// Measured: `{"error":"Following lines are invalid: 2, 5","message":...,
/// "invites":2,"duplicates":1,"invalid":2,"invalidLines":[2,5]}`. The line
/// numbers are 1-based and count the header, so line 1 is the header row.
final class ImportEmailInvitationsInvalidRows
    extends ImportEmailInvitationsResponse {
  const ImportEmailInvitationsInvalidRows._({
    required ImportEmailInvitationsRequest request,
    required this.invites,
    required this.duplicates,
    required this.invalid,
    required this.invalidLines,
  }) : super(request);

  @override
  int get statusCode => 400;

  final int invites;
  final int duplicates;
  final int invalid;

  /// 1-based line numbers, header included, capped at
  /// [emailInvitationInvalidLineLimit].
  final List<int> invalidLines;

  @override
  String toString() =>
      'ImportEmailInvitationsInvalidRows(invalid: $invalid, '
      'invites: $invites, duplicates: $duplicates)';
}

/// HTTP 400 without per-line detail: the file itself was unusable.
///
/// Measured: a missing upload answers `{"error":"file","message":"Uploading
/// the file failed"}` and a header-less CSV answers
/// `Missing "email" field in header line`. The server's own translated
/// `message` is carried through and shown verbatim rather than second-guessed.
final class ImportEmailInvitationsRejected
    extends ImportEmailInvitationsResponse {
  const ImportEmailInvitationsRejected._({
    required ImportEmailInvitationsRequest request,
    required this.message,
  }) : super(request);

  @override
  int get statusCode => 400;

  final String? message;

  @override
  String toString() => 'ImportEmailInvitationsRejected()';
}

final class ImportEmailInvitationsReauthenticationRequired
    extends ImportEmailInvitationsResponse {
  const ImportEmailInvitationsReauthenticationRequired._({
    required ImportEmailInvitationsRequest request,
  }) : super(request);

  @override
  int get statusCode => 401;
}

/// HTTP 403. The caller is in the room but is not a moderator.
final class ImportEmailInvitationsForbidden
    extends ImportEmailInvitationsResponse {
  const ImportEmailInvitationsForbidden._({
    required ImportEmailInvitationsRequest request,
  }) : super(request);

  @override
  int get statusCode => 403;
}

/// HTTP 404. Unknown room, or a room the caller is not a participant of.
final class ImportEmailInvitationsRoomMissing
    extends ImportEmailInvitationsResponse {
  const ImportEmailInvitationsRoomMissing._({
    required ImportEmailInvitationsRequest request,
  }) : super(request);

  @override
  int get statusCode => 404;
}

final class ImportEmailInvitationsHttpFailure
    extends ImportEmailInvitationsResponse {
  const ImportEmailInvitationsHttpFailure._({
    required ImportEmailInvitationsRequest request,
    required this.statusCode,
    required this.kind,
  }) : super(request);

  @override
  final int statusCode;
  final RoomSettingsHttpFailureKind kind;
}

ImportEmailInvitationsResponse decodeImportEmailInvitationsResponse({
  required ImportEmailInvitationsRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  switch (statusCode) {
    case 200:
      final data = requireObject(
        _decodeOcsEnvelope(body),
        path: r'$.ocs.data',
        code: _responseCode,
      );
      final roomType = data.containsKey('type')
          ? requireInt(
              data['type'],
              path: r'$.ocs.data.type',
              code: _responseCode,
              minimum: 1,
              maximum: 6,
            )
          : null;
      // A preview that reports a room type means the server did more than it
      // was asked to. Refusing here is the only way the UI can promise that
      // nothing was sent.
      if ((roomType != null) == request.testRun) {
        protocolFailure(_responseCode, r'$.ocs.data.type');
      }
      return ImportEmailInvitationsSuccess._(
        request: request,
        invites: _invitationCount(data, 'invites'),
        duplicates: _invitationCount(data, 'duplicates'),
        roomType: roomType,
      );
    case 400:
      final data = _decodeOcsEnvelope(body);
      if (data is Map<String, Object?> && data.containsKey('invalidLines')) {
        final lines = requireList(
          data['invalidLines'],
          path: r'$.ocs.data.invalidLines',
          code: _responseCode,
        );
        return ImportEmailInvitationsInvalidRows._(
          request: request,
          invites: _invitationCount(data, 'invites'),
          duplicates: _invitationCount(data, 'duplicates'),
          invalid: _invitationCount(data, 'invalid'),
          invalidLines: List<int>.unmodifiable(
            lines
                .take(emailInvitationInvalidLineLimit)
                .map(
                  (line) => requireInt(
                    line,
                    path: r'$.ocs.data.invalidLines[]',
                    code: _responseCode,
                    minimum: 1,
                    maximum: 1 << 31,
                  ),
                ),
          ),
        );
      }
      return ImportEmailInvitationsRejected._(
        request: request,
        message: _optionalRejectionMessage(data),
      );
    case 401:
      _decodeOcsEnvelope(body);
      return ImportEmailInvitationsReauthenticationRequired._(request: request);
    case 403:
      _decodeOcsEnvelope(body);
      return ImportEmailInvitationsForbidden._(request: request);
    case 404:
      _decodeOcsEnvelope(body);
      return ImportEmailInvitationsRoomMissing._(request: request);
    case 429:
      return ImportEmailInvitationsHttpFailure._(
        request: request,
        statusCode: 429,
        kind: RoomSettingsHttpFailureKind.rateLimited,
      );
    case 503:
      return ImportEmailInvitationsHttpFailure._(
        request: request,
        statusCode: 503,
        kind: RoomSettingsHttpFailureKind.serviceUnavailable,
      );
    default:
      protocolFailure(
        TalkProtocolErrorCode.unsupportedHttpStatus,
        r'$.statusCode',
      );
  }
}

/// A missing counter reads as zero: the server omits `invalid` from a clean
/// preview, and a count is never worth failing a whole response over.
int _invitationCount(Map<String, Object?> data, String field) {
  if (data[field] == null) {
    return 0;
  }
  return requireInt(
    data[field],
    path:
        r'$.ocs.data.'
        '$field',
    code: _responseCode,
    minimum: 0,
    maximum: 1 << 31,
  );
}

sealed class ResendEmailInvitationsResponse {
  const ResendEmailInvitationsResponse(this.request);

  final ResendEmailInvitationsRequest request;
  int get statusCode;
}

/// HTTP 200. The server accepted the request and mailed whoever it applied
/// to; the payload is `null` and carries no per-recipient detail.
final class ResendEmailInvitationsSuccess
    extends ResendEmailInvitationsResponse {
  const ResendEmailInvitationsSuccess._({
    required ResendEmailInvitationsRequest request,
  }) : super(request);

  @override
  int get statusCode => 200;
}

final class ResendEmailInvitationsReauthenticationRequired
    extends ResendEmailInvitationsResponse {
  const ResendEmailInvitationsReauthenticationRequired._({
    required ResendEmailInvitationsRequest request,
  }) : super(request);

  @override
  int get statusCode => 401;
}

final class ResendEmailInvitationsForbidden
    extends ResendEmailInvitationsResponse {
  const ResendEmailInvitationsForbidden._({
    required ResendEmailInvitationsRequest request,
  }) : super(request);

  @override
  int get statusCode => 403;
}

/// HTTP 404. Unknown room, or an attendee id this room does not have.
final class ResendEmailInvitationsTargetMissing
    extends ResendEmailInvitationsResponse {
  const ResendEmailInvitationsTargetMissing._({
    required ResendEmailInvitationsRequest request,
  }) : super(request);

  @override
  int get statusCode => 404;
}

final class ResendEmailInvitationsHttpFailure
    extends ResendEmailInvitationsResponse {
  const ResendEmailInvitationsHttpFailure._({
    required ResendEmailInvitationsRequest request,
    required this.statusCode,
    required this.kind,
  }) : super(request);

  @override
  final int statusCode;
  final RoomSettingsHttpFailureKind kind;
}

ResendEmailInvitationsResponse decodeResendEmailInvitationsResponse({
  required ResendEmailInvitationsRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  switch (statusCode) {
    case 200:
      _decodeOcsEnvelope(body);
      return ResendEmailInvitationsSuccess._(request: request);
    case 401:
      _decodeOcsEnvelope(body);
      return ResendEmailInvitationsReauthenticationRequired._(request: request);
    case 403:
      _decodeOcsEnvelope(body);
      return ResendEmailInvitationsForbidden._(request: request);
    case 404:
      _decodeOcsEnvelope(body);
      return ResendEmailInvitationsTargetMissing._(request: request);
    case 429:
      return ResendEmailInvitationsHttpFailure._(
        request: request,
        statusCode: 429,
        kind: RoomSettingsHttpFailureKind.rateLimited,
      );
    case 503:
      return ResendEmailInvitationsHttpFailure._(
        request: request,
        statusCode: 503,
        kind: RoomSettingsHttpFailureKind.serviceUnavailable,
      );
    default:
      protocolFailure(
        TalkProtocolErrorCode.unsupportedHttpStatus,
        r'$.statusCode',
      );
  }
}
