part of 'request.dart';

/// The largest CSV this client will read into memory and upload.
///
/// The server publishes no row or size limit — a 2000-row file was accepted
/// in one request during the live measurement — so this is a client-side
/// bound, not the server's rule. An address list large enough to exceed it is
/// an operator task, not something a phone should push through a single
/// multipart POST.
const int emailInvitationCsvMaximumBytes = 512 * 1024;

/// Uploads a CSV of e-mail addresses as conversation invitations.
///
/// `POST /ocs/v2.php/apps/spreed/api/v4/room/{token}/import-emails` as
/// `multipart/form-data` with a `file` part and a `testRun` field, behind the
/// server's `email-csv-import` capability. Moderator-only: a plain
/// participant is refused with `403`, a non-participant with `404`.
///
/// The first CSV line has to be a header containing an `email` column and the
/// separator has to be a comma: measured, a header-less file and a
/// semicolon-separated one are both refused with `400` and
/// `Missing "email" field in header line`. That is deliberately left to the
/// server rather than pre-checked here — the preview is already the cheap way
/// to find out, and a second parser would only diverge from it.
///
/// [testRun] is the whole point of the endpoint. With it set the server parses
/// and validates the file and reports what it *would* do without sending a
/// single message; without it the same call really sends the invitations. The
/// two are the same URL, so this contract keeps them apart explicitly and the
/// response decoder cross-checks the server's own answer against the flag.
final class ImportEmailInvitationsRequest extends RoomAdministrationRequest {
  ImportEmailInvitationsRequest({
    required super.accountId,
    required super.server,
    required super.roomToken,
    required this.csvBytes,
    required this.fileName,
    required this.testRun,
    required CapabilitySnapshot capabilities,
    super.userAgent = roomSettingsContractUserAgent,
  }) {
    if (capabilities.context != CapabilityContext.authenticated ||
        !capabilities.supportsTalk('email-csv-import')) {
      protocolFailure(_requestCode, r'$.capabilities.email-csv-import');
    }
    if (csvBytes.isEmpty || csvBytes.length > emailInvitationCsvMaximumBytes) {
      protocolFailure(_requestCode, r'$.body.file');
    }
    if (fileName.isEmpty ||
        fileName.length > 255 ||
        _hasControlCharacter(fileName) ||
        fileName.contains('/') ||
        fileName.contains(r'\') ||
        fileName.contains('"')) {
      protocolFailure(_requestCode, r'$.body.file.fileName');
    }
    _validateUserAgent(userAgent, r'$.headers.userAgent');
  }

  final List<int> csvBytes;

  /// The multipart part's file name. Never a path: the constructor refuses
  /// separators and quotes so it cannot break out of the part header.
  final String fileName;

  /// `true` previews without sending anything; `false` really invites.
  final bool testRun;

  static const String fileField = 'file';
  static const String testRunField = 'testRun';
  static const String csvContentType = 'text/csv';

  /// A per-request boundary from a cryptographic source, so a crafted file
  /// cannot contain a boundary an attacker predicted and split the body.
  late final String _boundary = _randomBoundary();

  String get multipartContentType => 'multipart/form-data; boundary=$_boundary';

  /// The encoded `multipart/form-data` body: the CSV as the `file` part and
  /// `testRun` as a plain field.
  ///
  /// Hand-encoded rather than delegated, so the wire format this contract
  /// promises is the one that is actually sent and can be asserted on.
  Uint8List get multipartBody {
    final head = utf8.encode(
      '--$_boundary\r\n'
      'Content-Disposition: form-data; name="$fileField"; '
      'filename="$fileName"\r\n'
      'Content-Type: $csvContentType\r\n'
      '\r\n',
    );
    final tail = utf8.encode(
      '\r\n--$_boundary\r\n'
      'Content-Disposition: form-data; name="$testRunField"\r\n'
      '\r\n'
      '${testRun ? '1' : '0'}\r\n'
      '--$_boundary--\r\n',
    );
    final body = Uint8List(head.length + csvBytes.length + tail.length);
    body.setAll(0, head);
    body.setAll(head.length, csvBytes);
    body.setAll(head.length + csvBytes.length, tail);
    return body;
  }

  @override
  String get httpMethod => 'POST';

  /// The payload is multipart, not form fields; the transport sends
  /// [multipartBody] instead.
  @override
  Map<String, String>? get formBody => null;

  @override
  Map<String, String> get headers => UnmodifiableMapView({
    ...super.headers,
    'Content-Type': multipartContentType,
  });

  @override
  Uri get uri => _roomUri(server, roomToken, 'import-emails');

  /// Renders neither the addresses nor the file name, which both name real
  /// people.
  @override
  String toString() =>
      'ImportEmailInvitationsRequest(testRun: $testRun, '
      'bytes: ${csvBytes.length})';
}

/// Sends the invitation e-mail again to the conversation's e-mail attendees.
///
/// `POST /ocs/v2.php/apps/spreed/api/v4/room/{token}/participants/`
/// `resend-invitations`. With [attendeeId] the server mails that one
/// attendee; without it, every e-mail attendee of the room. Moderator-only:
/// a plain participant is refused with `403`, an unknown attendee with `404`.
///
/// The result is a message leaving the server, so this request is never
/// replayed automatically. A failure that does not say whether the mail went
/// out has to reach the user as a report, not as a second attempt.
final class ResendEmailInvitationsRequest extends RoomAdministrationRequest {
  ResendEmailInvitationsRequest({
    required super.accountId,
    required super.server,
    required super.roomToken,
    this.attendeeId,
    super.userAgent = roomSettingsContractUserAgent,
  }) {
    final id = attendeeId;
    if (id != null && (id <= 0 || id > 0x7fffffff)) {
      protocolFailure(_requestCode, r'$.body.attendeeId');
    }
    _validateUserAgent(userAgent, r'$.headers.userAgent');
  }

  /// One attendee, or `null` for every e-mail attendee in the room.
  final int? attendeeId;

  bool get isAllAttendees => attendeeId == null;

  @override
  String get httpMethod => 'POST';

  @override
  Map<String, String>? get formBody => attendeeId == null
      ? null
      : UnmodifiableMapView({'attendeeId': '$attendeeId'});

  @override
  Map<String, String> get headers => UnmodifiableMapView({
    ...super.headers,
    'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
  });

  @override
  Uri get uri => _roomUri(server, roomToken, 'participants/resend-invitations');

  @override
  String toString() =>
      'ResendEmailInvitationsRequest(allAttendees: $isAllAttendees)';
}
