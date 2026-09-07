import 'dart:convert';
import 'dart:typed_data';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('export is authenticated GET with a fixed format and filename', () {
    for (final format in PollExportFormat.values) {
      final request = _request(format);
      expect(request.method, 'GET');
      expect(request.jsonBody, isNull);
      expect(
        request.uri.path,
        endsWith('/poll/roomtoken/7/export/${format.name}'),
      );
      expect(request.headers['OCS-APIRequest'], 'true');
      final bytes = format == PollExportFormat.csv
          ? Uint8List.fromList(utf8.encode('Question,Lunch?\r\n'))
          : Uint8List.fromList([0x50, 0x4b, 3, 4, 0, 0]);
      final response = decodePollExportResponse(
        request: request,
        statusCode: 200,
        body: bytes,
        contentType: '${format.mimeType}; charset=utf-8',
      );
      expect(response.classification, PollResponseClassification.confirmed);
      expect(response.bytes, bytes);
      expect(response.fileName, 'poll-7.${format.name}');
      expect(response.mimeType, format.mimeType);
      bytes[0] = 0;
      expect(response.bytes![0], isNot(0));
      expect(() => response.bytes![0] = 0, throwsUnsupportedError);
    }
  });

  test('export refuses missing authority and invalid poll id', () {
    expect(
      () => _request(PollExportFormat.csv, allowed: false),
      throwsA(isA<TalkProtocolException>()),
    );
    expect(
      () => _request(PollExportFormat.csv, id: 0),
      throwsA(isA<TalkProtocolException>()),
    );
  });

  test(
    'successful export refuses HTML, wrong MIME, empty and oversized files',
    () {
      final request = _request(PollExportFormat.csv);
      for (final contentType in <String?>[
        null,
        'text/html',
        'application/json',
        'application/octet-stream',
      ]) {
        expect(
          () => decodePollExportResponse(
            request: request,
            statusCode: 200,
            body: Uint8List.fromList(utf8.encode('<html>login</html>')),
            contentType: contentType,
          ),
          throwsA(isA<TalkProtocolException>()),
        );
      }
      for (final body in [
        Uint8List(0),
        Uint8List(pollMaximumExportBytes + 1),
        Uint8List.fromList([0xff]),
      ]) {
        expect(
          () => decodePollExportResponse(
            request: request,
            statusCode: 200,
            body: body,
            contentType: 'text/csv',
          ),
          throwsA(isA<TalkProtocolException>()),
        );
      }
      expect(
        () => decodePollExportResponse(
          request: _request(PollExportFormat.ods),
          statusCode: 200,
          body: Uint8List.fromList(utf8.encode('not a spreadsheet')),
          contentType: PollExportFormat.ods.mimeType,
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    },
  );

  test(
    'export status errors stay typed and never offer downloaded error data',
    () {
      for (final entry in {
        400: PollResponseClassification.invalidInput,
        401: PollResponseClassification.reauthenticationRequired,
        403: PollResponseClassification.permissionDenied,
        404: PollResponseClassification.notFound,
        429: PollResponseClassification.rateLimited,
        503: PollResponseClassification.serviceUnavailable,
      }.entries) {
        final response = decodePollExportResponse(
          request: _request(PollExportFormat.csv),
          statusCode: entry.key,
          body: Uint8List(0),
          contentType: null,
        );
        expect(response.classification, entry.value);
        expect(response.bytes, isNull);
        expect(response.fileName, isNull);
      }
      expect(
        () => decodePollExportResponse(
          request: _request(PollExportFormat.csv),
          statusCode: 302,
          body: Uint8List(0),
          contentType: null,
        ),
        throwsA(isA<TalkProtocolException>()),
      );
    },
  );
}

PollExportRequest _request(
  PollExportFormat format, {
  bool allowed = true,
  int id = 7,
}) => PollExportRequest(
  accountId: AccountId.parse('poll-account'),
  requestId: ChatRequestId.parse('poll-export'),
  server: ServerBase.parse('https://cloud.example.invalid'),
  roomToken: ConversationToken.parse('roomtoken', path: r'$.token'),
  pollsAvailable: true,
  pollId: id,
  format: format,
  canExport: allowed,
);
