part of 'polls.dart';

const int pollMaximumDrafts = 1000;

final class PollDraftListResponse {
  PollDraftListResponse({
    required this.classification,
    required List<TalkPoll> drafts,
  }) : drafts = List.unmodifiable(drafts);

  final PollResponseClassification classification;
  final List<TalkPoll> drafts;
}

final class PollDraftDeleteResponse {
  const PollDraftDeleteResponse({required this.classification});
  final PollResponseClassification classification;
}

PollDraftListResponse decodePollDraftListResponse({
  required PollDraftListRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  final failure = _pollFailureClassification(statusCode);
  if (failure != null) {
    return PollDraftListResponse(classification: failure, drafts: const []);
  }
  _requirePollStatus(statusCode, 200);
  final raw = requireList(
    _decodePollData(body, 200),
    path: r'$.ocs.data',
    code: TalkProtocolErrorCode.invalidPollResponse,
  );
  if (raw.length > pollMaximumDrafts) _responseFailure(r'$.ocs.data');
  final drafts = <TalkPoll>[];
  final ids = <int>{};
  for (final value in raw) {
    final poll = TalkPoll.fromJson(value);
    if (poll.status != PollStatus.draft || !ids.add(poll.id)) {
      _responseFailure(r'$.ocs.data');
    }
    drafts.add(poll);
  }
  return PollDraftListResponse(
    classification: PollResponseClassification.confirmed,
    drafts: drafts,
  );
}

PollDraftDeleteResponse decodePollDraftDeleteResponse({
  required PollDraftDeleteRequest request,
  required int statusCode,
  required Uint8List body,
}) {
  final failure = _pollFailureClassification(statusCode);
  if (failure != null) return PollDraftDeleteResponse(classification: failure);
  _requirePollStatus(statusCode, 202);
  if (_decodePollData(body, 202) != null) _responseFailure(r'$.ocs.data');
  return const PollDraftDeleteResponse(
    classification: PollResponseClassification.confirmed,
  );
}

PollResponseClassification? _pollFailureClassification(int statusCode) =>
    switch (statusCode) {
      400 => PollResponseClassification.invalidInput,
      401 => PollResponseClassification.reauthenticationRequired,
      403 => PollResponseClassification.permissionDenied,
      404 => PollResponseClassification.notFound,
      429 => PollResponseClassification.rateLimited,
      500 || 502 || 503 || 504 => PollResponseClassification.serviceUnavailable,
      _ => null,
    };

void _requirePollStatus(int actual, int expected) {
  if (actual != expected) {
    throw const TalkProtocolException(
      TalkProtocolErrorCode.unsupportedHttpStatus,
      path: r'$.statusCode',
    );
  }
}

Object? _decodePollData(Uint8List body, int confirmedStatusCode) {
  if (body.isEmpty || body.length > pollMaximumResponseBytes) {
    _responseFailure(r'$.body');
  }
  final Object? decoded;
  try {
    decoded = decodeJsonRejectingDuplicateMembers(
      utf8.decode(body),
      code: TalkProtocolErrorCode.invalidPollResponse,
      path: r'$.body',
    );
  } on FormatException {
    _responseFailure(r'$.body');
  }
  final root = requireObject(
    decoded,
    path: r'$',
    code: TalkProtocolErrorCode.invalidPollResponse,
  );
  final ocs = requireObject(
    root['ocs'],
    path: r'$.ocs',
    code: TalkProtocolErrorCode.invalidPollResponse,
  );
  final meta = requireObject(
    ocs['meta'],
    path: r'$.ocs.meta',
    code: TalkProtocolErrorCode.invalidPollResponse,
  );
  if (meta['status'] != 'ok' || meta['statuscode'] != confirmedStatusCode) {
    _responseFailure(r'$.ocs.meta');
  }
  if (!ocs.containsKey('data')) _responseFailure(r'$.ocs.data');
  return ocs['data'];
}
