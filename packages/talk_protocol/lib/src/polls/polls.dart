import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import '../chat/identifiers.dart';
import '../chat/request.dart';
import '../identifiers.dart';
import '../json_value.dart';
import '../protocol_exception.dart';
import '../server_base.dart';

const int pollMaximumResponseBytes = 2 * 1024 * 1024;

enum PollResultMode {
  public(0),
  hiddenUntilClosed(1);

  const PollResultMode(this.wireValue);
  final int wireValue;
}

/// Upstream `Poll::STATUS_*`: open=0, closed=1, draft=2.
enum PollStatus { open, closed, draft }

enum PollResponseClassification {
  confirmed,
  invalidInput,
  reauthenticationRequired,
  permissionDenied,
  notFound,
  rateLimited,
  serviceUnavailable,
}

final class TalkPoll {
  const TalkPoll._({
    required this.id,
    required this.question,
    required this.options,
    required this.actorType,
    required this.actorId,
    required this.actorDisplayName,
    required this.status,
    required this.resultMode,
    required this.maxVotes,
    required this.votedSelf,
    required this.votes,
    required this.numVoters,
  });

  factory TalkPoll.fromJson(Object? value) {
    final data = requireObject(
      value,
      path: r'$.ocs.data',
      code: TalkProtocolErrorCode.invalidPollResponse,
    );
    final id = _positiveInt(data['id'], r'$.ocs.data.id');
    final question = _boundedText(
      data['question'],
      32000,
      r'$.ocs.data.question',
    );
    final rawOptions = requireList(
      data['options'],
      path: r'$.ocs.data.options',
      code: TalkProtocolErrorCode.invalidPollResponse,
    );
    if (rawOptions.length < 2 || rawOptions.length > 1000) {
      _responseFailure(r'$.ocs.data.options');
    }
    final options = <String>[];
    for (var index = 0; index < rawOptions.length; index++) {
      options.add(
        _boundedText(rawOptions[index], 32000, r'$.ocs.data.options[$index]'),
      );
    }
    final statusValue = data['status'];
    final resultValue = data['resultMode'];
    if (statusValue is! int ||
        statusValue < 0 ||
        statusValue > 2 ||
        resultValue is! int ||
        resultValue < 0 ||
        resultValue > 1) {
      _responseFailure(r'$.ocs.data');
    }
    final maxVotes = data['maxVotes'];
    if (maxVotes is! int ||
        maxVotes < 0 ||
        (maxVotes > options.length && maxVotes != 0)) {
      _responseFailure(r'$.ocs.data.maxVotes');
    }
    final votedSelf = _optionalIntList(
      data['votedSelf'],
      options.length,
      r'$.ocs.data.votedSelf',
    );
    final votes = <int, int>{};
    final rawVotes = data['votes'];
    if (rawVotes != null) {
      final map = requireObject(
        rawVotes,
        path: r'$.ocs.data.votes',
        code: TalkProtocolErrorCode.invalidPollResponse,
      );
      if (map.length > options.length) _responseFailure(r'$.ocs.data.votes');
      for (final entry in map.entries) {
        final match = RegExp(r'^option-(\d+)$').firstMatch(entry.key);
        final option = match == null ? -1 : int.parse(match.group(1)!);
        if (option < 0 ||
            option >= options.length ||
            entry.value is! int ||
            (entry.value as int) < 0) {
          _responseFailure(r'$.ocs.data.votes');
        }
        votes[option] = entry.value as int;
      }
    }
    final numVoters = data['numVoters'];
    if (numVoters != null && (numVoters is! int || numVoters < 0)) {
      _responseFailure(r'$.ocs.data.numVoters');
    }
    return TalkPoll._(
      id: id,
      question: question,
      options: List.unmodifiable(options),
      actorType: _boundedText(data['actorType'], 256, r'$.ocs.data.actorType'),
      actorId: _boundedText(data['actorId'], 4096, r'$.ocs.data.actorId'),
      actorDisplayName: _boundedText(
        data['actorDisplayName'],
        4096,
        r'$.ocs.data.actorDisplayName',
        allowEmpty: true,
      ),
      status: PollStatus.values[statusValue],
      resultMode: PollResultMode.values[resultValue],
      maxVotes: maxVotes,
      votedSelf: List.unmodifiable(votedSelf),
      votes: UnmodifiableMapView(votes),
      numVoters: numVoters as int?,
    );
  }

  final int id;
  final String question;
  final List<String> options;
  final String actorType;
  final String actorId;
  final String actorDisplayName;
  final PollStatus status;
  final PollResultMode resultMode;
  final int maxVotes;
  final List<int> votedSelf;
  final Map<int, int> votes;
  final int? numVoters;
}

sealed class PollRequest {
  PollRequest({
    required this.accountId,
    required this.requestId,
    required this.server,
    required this.roomToken,
    required bool pollsAvailable,
    this.userAgent = chatContractUserAgent,
  }) {
    if (!pollsAvailable) _requestFailure(r'$.capabilities.talk-polls');
    if (userAgent.isEmpty ||
        userAgent.length > 256 ||
        userAgent.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
      _requestFailure(r'$.headers.userAgent');
    }
  }
  final AccountId accountId;
  final ChatRequestId requestId;
  final ServerBase server;
  final ConversationToken roomToken;
  final String userAgent;
  Uri get uri;
  String get method;
  Map<String, String> get headers => UnmodifiableMapView({
    'OCS-APIRequest': 'true',
    'User-Agent': userAgent,
    'Content-Type': 'application/json',
  });
  Map<String, Object?>? get jsonBody;
}

final class PollCreateRequest extends PollRequest {
  PollCreateRequest({
    required super.accountId,
    required super.requestId,
    required super.server,
    required super.roomToken,
    required super.pollsAvailable,
    required String question,
    required List<String> options,
    required this.resultMode,
    required this.maxVotes,
    this.threadId,
  }) : question = question.trim(),
       options = List.unmodifiable(options.map((value) => value.trim())) {
    if (this.question.isEmpty || utf8.encode(this.question).length > 32000) {
      _requestFailure(r'$.question');
    }
    if (this.options.length < 2 ||
        this.options.any((value) => value.isEmpty) ||
        utf8.encode(jsonEncode(this.options)).length > 60000) {
      _requestFailure(r'$.options');
    }
    if (maxVotes < 0 || (maxVotes > this.options.length && maxVotes != 0)) {
      _requestFailure(r'$.maxVotes');
    }
    if (threadId != null && threadId! < 1) _requestFailure(r'$.threadId');
  }
  final String question;
  final List<String> options;
  final PollResultMode resultMode;
  final int maxVotes;
  final int? threadId;
  @override
  String get method => 'POST';
  @override
  Uri get uri => server.uri.replace(
    path:
        '${server.basePath}/ocs/v2.php/apps/spreed/api/v1/poll/${roomToken.value}',
    queryParameters: const {'format': 'json'},
  );
  @override
  Map<String, Object?> get jsonBody => UnmodifiableMapView({
    'question': question,
    'options': options,
    'resultMode': resultMode.wireValue,
    'maxVotes': maxVotes,
    'draft': false,
    'threadId': ?threadId,
  });
}

final class PollVoteRequest extends PollRequest {
  PollVoteRequest({
    required super.accountId,
    required super.requestId,
    required super.server,
    required super.roomToken,
    required super.pollsAvailable,
    required this.pollId,
    required List<int> optionIds,
  }) : optionIds = List.unmodifiable(optionIds) {
    if (pollId < 1 ||
        this.optionIds.toSet().length != this.optionIds.length ||
        this.optionIds.any((id) => id < 0)) {
      _requestFailure(r'$.optionIds');
    }
  }
  final int pollId;
  final List<int> optionIds;
  @override
  String get method => 'POST';
  @override
  Uri get uri => server.uri.replace(
    path:
        '${server.basePath}/ocs/v2.php/apps/spreed/api/v1/poll/${roomToken.value}/$pollId',
    queryParameters: const {'format': 'json'},
  );
  @override
  Map<String, Object?> get jsonBody =>
      UnmodifiableMapView({'optionIds': optionIds});
}

final class PollResponse {
  const PollResponse({required this.classification, required this.poll});
  final PollResponseClassification classification;
  final TalkPoll? poll;
}

PollResponse decodePollResponse({
  required PollRequest request,
  required int statusCode,
  required Uint8List body,
  required int confirmedStatusCode,
}) {
  final failure = switch (statusCode) {
    400 => PollResponseClassification.invalidInput,
    401 => PollResponseClassification.reauthenticationRequired,
    403 => PollResponseClassification.permissionDenied,
    404 => PollResponseClassification.notFound,
    429 => PollResponseClassification.rateLimited,
    500 || 502 || 503 || 504 => PollResponseClassification.serviceUnavailable,
    _ => null,
  };
  if (failure != null) return PollResponse(classification: failure, poll: null);
  if (statusCode != confirmedStatusCode) {
    throw const TalkProtocolException(
      TalkProtocolErrorCode.unsupportedHttpStatus,
      path: r'$.statusCode',
    );
  }
  if (body.isEmpty || body.length > pollMaximumResponseBytes) {
    _responseFailure(r'$.body');
  }
  Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(body));
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
  final poll = TalkPoll.fromJson(ocs['data']);
  if (request is PollVoteRequest && poll.id != request.pollId) {
    _responseFailure(r'$.ocs.data.id');
  }
  return PollResponse(
    classification: PollResponseClassification.confirmed,
    poll: poll,
  );
}

List<int> _optionalIntList(Object? value, int optionCount, String path) {
  if (value == null) return const [];
  final list = requireList(
    value,
    path: path,
    code: TalkProtocolErrorCode.invalidPollResponse,
  );
  final result = <int>[];
  for (final item in list) {
    if (item is! int ||
        item < 0 ||
        item >= optionCount ||
        result.contains(item)) {
      _responseFailure(path);
    }
    result.add(item);
  }
  return result;
}

int _positiveInt(Object? value, String path) {
  if (value is! int || value < 1) _responseFailure(path);
  return value;
}

String _boundedText(
  Object? value,
  int maximum,
  String path, {
  bool allowEmpty = false,
}) {
  if (value is! String ||
      (!allowEmpty && value.trim().isEmpty) ||
      utf8.encode(value).length > maximum) {
    _responseFailure(path);
  }
  return value;
}

Never _requestFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidPollRequest, path);
Never _responseFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidPollResponse, path);
