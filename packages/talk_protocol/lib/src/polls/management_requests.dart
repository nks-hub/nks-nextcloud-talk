part of 'polls.dart';

/// Author or moderator closes an open poll with DELETE; a draft uses another response.
final class PollCloseRequest extends PollRequest {
  PollCloseRequest({
    required super.accountId,
    required super.requestId,
    required super.server,
    required super.roomToken,
    required super.pollsAvailable,
    required this.pollId,
    required bool canClose,
  }) {
    _requirePollId(pollId);
    if (!canClose) _requestFailure(r'$.permissions.close');
  }

  final int pollId;
  @override
  String get method => 'DELETE';
  @override
  Uri get uri => _pollUri(server, roomToken, '$pollId');
  @override
  Map<String, Object?>? get jsonBody => null;
}

sealed class _PollDraftFormRequest extends PollRequest {
  _PollDraftFormRequest({
    required super.accountId,
    required super.requestId,
    required super.server,
    required super.roomToken,
    required super.pollsAvailable,
    required bool draftsAvailable,
    required String question,
    required List<String> options,
    required this.resultMode,
    required this.maxVotes,
  }) : question = question.trim(),
       options = List.unmodifiable(options.map((value) => value.trim())) {
    if (!draftsAvailable) _requestFailure(r'$.capabilities.talk-polls-drafts');
    _validatePollForm(this.question, this.options, maxVotes);
  }

  final String question;
  final List<String> options;
  final PollResultMode resultMode;
  final int maxVotes;
  @override
  String get method => 'POST';
  Map<String, Object?> get _formFields => {
    'question': question,
    'options': options,
    'resultMode': resultMode.wireValue,
    'maxVotes': maxVotes,
  };
}

/// Drafts are room-level templates; the server does not retain a draft thread id.
final class PollDraftCreateRequest extends _PollDraftFormRequest {
  PollDraftCreateRequest({
    required super.accountId,
    required super.requestId,
    required super.server,
    required super.roomToken,
    required super.pollsAvailable,
    required super.draftsAvailable,
    required super.question,
    required super.options,
    required super.resultMode,
    required super.maxVotes,
    required bool isModerator,
  }) {
    if (!isModerator) _requestFailure(r'$.permissions.moderator');
  }

  @override
  Uri get uri => _pollUri(server, roomToken);
  @override
  Map<String, Object?> get jsonBody =>
      UnmodifiableMapView({..._formFields, 'draft': true});
}

/// The caller supplies fresh author/moderator and write permission authority.
final class PollDraftEditRequest extends _PollDraftFormRequest {
  PollDraftEditRequest({
    required super.accountId,
    required super.requestId,
    required super.server,
    required super.roomToken,
    required super.pollsAvailable,
    required super.draftsAvailable,
    required super.question,
    required super.options,
    required super.resultMode,
    required super.maxVotes,
    required this.pollId,
    required bool editDraftAvailable,
    required bool canEditDraft,
  }) {
    _requirePollId(pollId);
    if (!editDraftAvailable) _requestFailure(r'$.capabilities.edit-draft-poll');
    if (!canEditDraft) _requestFailure(r'$.permissions.editDraft');
  }

  final int pollId;
  @override
  Uri get uri => _pollUri(server, roomToken, 'draft/$pollId');
  @override
  Map<String, Object?> get jsonBody => UnmodifiableMapView(_formFields);
}

final class PollDraftListRequest extends PollRequest {
  PollDraftListRequest({
    required super.accountId,
    required super.requestId,
    required super.server,
    required super.roomToken,
    required super.pollsAvailable,
    required bool draftsAvailable,
    required bool isModerator,
  }) {
    _requireDraftAccess(draftsAvailable, isModerator);
  }

  @override
  String get method => 'GET';
  @override
  Uri get uri => _pollUri(server, roomToken, 'drafts');
  @override
  Map<String, Object?>? get jsonBody => null;
}

/// The same route as close, but only an OCS 202 with null data deletes a draft.
final class PollDraftDeleteRequest extends PollRequest {
  PollDraftDeleteRequest({
    required super.accountId,
    required super.requestId,
    required super.server,
    required super.roomToken,
    required super.pollsAvailable,
    required bool draftsAvailable,
    required bool isModerator,
    required this.pollId,
  }) {
    _requireDraftAccess(draftsAvailable, isModerator);
    _requirePollId(pollId);
  }

  final int pollId;
  @override
  String get method => 'DELETE';
  @override
  Uri get uri => _pollUri(server, roomToken, '$pollId');
  @override
  Map<String, Object?>? get jsonBody => null;
}

Uri _pollUri(ServerBase server, ConversationToken roomToken, [String? suffix]) {
  final tail = suffix == null ? '' : '/$suffix';
  return server.uri.replace(
    path:
        '${server.basePath}/ocs/v2.php/apps/spreed/api/v1/poll/'
        '${roomToken.value}$tail',
    queryParameters: const {'format': 'json'},
  );
}

void _requireDraftAccess(bool draftsAvailable, bool isModerator) {
  if (!draftsAvailable) _requestFailure(r'$.capabilities.talk-polls-drafts');
  if (!isModerator) _requestFailure(r'$.permissions.moderator');
}

void _requirePollId(int pollId) {
  if (pollId < 1) _requestFailure(r'$.pollId');
}

void _validatePollForm(String question, List<String> options, int maxVotes) {
  if (question.isEmpty || utf8.encode(question).length > 32000) {
    _requestFailure(r'$.question');
  }
  if (options.length < 2 ||
      options.length > 1000 ||
      options.any((value) => value.isEmpty) ||
      utf8.encode(jsonEncode(options)).length > 60000) {
    _requestFailure(r'$.options');
  }
  if (maxVotes < 0 || (maxVotes > options.length && maxVotes != 0)) {
    _requestFailure(r'$.maxVotes');
  }
}
