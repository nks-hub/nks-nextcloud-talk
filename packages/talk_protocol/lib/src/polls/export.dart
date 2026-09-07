part of 'polls.dart';

const int pollMaximumExportBytes = 10 * 1024 * 1024;

enum PollExportFormat {
  csv('text/csv'),
  ods('application/vnd.oasis.opendocument.spreadsheet');

  const PollExportFormat(this.mimeType);
  final String mimeType;
}

/// Stable Talk allows the author or a moderator to export an open or closed poll.
final class PollExportRequest extends PollRequest {
  PollExportRequest({
    required super.accountId,
    required super.requestId,
    required super.server,
    required super.roomToken,
    required super.pollsAvailable,
    required this.pollId,
    required this.format,
    required bool canExport,
  }) {
    _requirePollId(pollId);
    if (!canExport) _requestFailure(r'$.permissions.export');
  }

  final int pollId;
  final PollExportFormat format;
  @override
  String get method => 'GET';
  @override
  Uri get uri => _pollUri(server, roomToken, '$pollId/export/${format.name}');
  @override
  Map<String, Object?>? get jsonBody => null;
}

final class PollExportResponse {
  PollExportResponse._({
    required this.classification,
    Uint8List? bytes,
    this.fileName,
    this.mimeType,
  }) : bytes = bytes == null
           ? null
           : Uint8List.fromList(bytes).asUnmodifiableView();

  final PollResponseClassification classification;
  final Uint8List? bytes;
  final String? fileName;
  final String? mimeType;
}

/// Bounds the download without trusting Content-Disposition as a local path.
PollExportResponse decodePollExportResponse({
  required PollExportRequest request,
  required int statusCode,
  required Uint8List body,
  required String? contentType,
}) {
  final failure = _pollFailureClassification(statusCode);
  if (failure != null) return PollExportResponse._(classification: failure);
  _requirePollStatus(statusCode, 200);
  if (body.isEmpty || body.length > pollMaximumExportBytes) {
    _responseFailure(r'$.body');
  }
  final mime = contentType?.split(';').first.trim().toLowerCase();
  if (mime != request.format.mimeType) {
    _responseFailure(r'$.headers.contentType');
  }
  switch (request.format) {
    case PollExportFormat.csv:
      try {
        utf8.decode(body);
      } on FormatException {
        _responseFailure(r'$.body');
      }
    case PollExportFormat.ods:
      // ODS is a ZIP download. This checks its header, not archive contents.
      if (body.length < 4 ||
          body[0] != 0x50 ||
          body[1] != 0x4b ||
          body[2] != 3 ||
          body[3] != 4) {
        _responseFailure(r'$.body');
      }
  }
  return PollExportResponse._(
    classification: PollResponseClassification.confirmed,
    bytes: body,
    fileName: 'poll-${request.pollId}.${request.format.name}',
    mimeType: request.format.mimeType,
  );
}
