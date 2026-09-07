import 'dart:async';
import 'dart:typed_data';

import 'package:nextcloudtalk/features/chat/poll_service.dart';
import 'package:talk_protocol/talk_protocol.dart';

class FakePollSender implements PollSender {
  FakePollSender({
    this.failCreate = false,
    this.access = const PollManagementAccess(),
  });

  final bool failCreate;
  PollManagementAccess access;
  TalkPoll? loadedPoll;
  int createCalls = 0;
  String? createdQuestion;
  List<int>? votedOptions;
  int loadCalls = 0;
  int closeCalls = 0;
  int createDraftCalls = 0;
  int editDraftCalls = 0;
  int? editedMaxVotes;
  List<String>? editedOptions;
  int deleteDraftCalls = 0;
  int publishCalls = 0;
  PollServiceError? managementError;
  Completer<TalkPoll>? voteCompleter;
  Completer<TalkPoll>? closeCompleter;
  Completer<PollExportFile>? exportCompleter;
  List<TalkPoll> drafts = [];
  final List<PollExportFormat> exports = [];
  final List<PollRoomKey> mutationKeys = [];

  @override
  Future<bool> isAvailable(PollRoomKey key) async => true;

  @override
  Future<PollManagementAccess> managementAccess({
    required PollRoomKey key,
    TalkPoll? poll,
  }) async => access;

  @override
  Future<TalkPoll> load({required PollRoomKey key, required int pollId}) async {
    loadCalls++;
    return loadedPoll ?? pollFixture(id: pollId);
  }

  @override
  Future<TalkPoll> create({
    required PollRoomKey key,
    required String question,
    required List<String> options,
    required PollResultMode resultMode,
    required int maxVotes,
  }) async {
    createCalls++;
    mutationKeys.add(key);
    createdQuestion = question;
    if (failCreate) {
      throw const PollServiceException(PollServiceError.ambiguous);
    }
    return pollFixture(question: question);
  }

  @override
  Future<TalkPoll> vote({
    required PollRoomKey key,
    required TalkPoll poll,
    required List<int> optionIds,
  }) async {
    votedOptions = optionIds;
    mutationKeys.add(key);
    return voteCompleter?.future ?? pollFixture(votedSelf: optionIds);
  }

  @override
  Future<TalkPoll> close({
    required PollRoomKey key,
    required TalkPoll poll,
  }) async {
    closeCalls++;
    mutationKeys.add(key);
    _checkError();
    return closeCompleter?.future ?? pollFixture(status: PollStatus.closed);
  }

  @override
  Future<List<TalkPoll>> listDrafts({required PollRoomKey key}) async =>
      List.of(drafts);

  @override
  Future<TalkPoll> createDraft({
    required PollRoomKey key,
    required String question,
    required List<String> options,
    required PollResultMode resultMode,
    required int maxVotes,
  }) async {
    createDraftCalls++;
    mutationKeys.add(key);
    _checkError();
    final draft = pollFixture(
      id: 17,
      question: question,
      status: PollStatus.draft,
    );
    drafts.add(draft);
    return draft;
  }

  @override
  Future<TalkPoll> editDraft({
    required PollRoomKey key,
    required TalkPoll draft,
    required String question,
    required List<String> options,
    required PollResultMode resultMode,
    required int maxVotes,
  }) async {
    editDraftCalls++;
    editedMaxVotes = maxVotes;
    editedOptions = options;
    mutationKeys.add(key);
    _checkError();
    final updated = pollFixture(
      id: draft.id,
      question: question,
      status: PollStatus.draft,
      options: options,
      maxVotes: maxVotes,
    );
    drafts = [
      for (final value in drafts) value.id == draft.id ? updated : value,
    ];
    return updated;
  }

  @override
  Future<void> deleteDraft({
    required PollRoomKey key,
    required TalkPoll draft,
  }) async {
    deleteDraftCalls++;
    mutationKeys.add(key);
    _checkError();
    drafts.removeWhere((value) => value.id == draft.id);
  }

  @override
  Future<TalkPoll> publishDraft({
    required PollRoomKey key,
    required TalkPoll draft,
  }) async {
    publishCalls++;
    mutationKeys.add(key);
    _checkError();
    return pollFixture(id: 27, question: draft.question);
  }

  @override
  Future<PollExportFile> export({
    required PollRoomKey key,
    required TalkPoll poll,
    required PollExportFormat format,
  }) async {
    exports.add(format);
    _checkError();
    return exportCompleter?.future ??
        PollExportFile(
          bytes: Uint8List.fromList([1, 2, 3]),
          fileName: 'poll-${poll.id}.${format.name}',
          mimeType: format == PollExportFormat.csv
              ? 'text/csv'
              : 'application/vnd.oasis.opendocument.spreadsheet',
        );
  }

  void _checkError() {
    if (managementError != null) throw PollServiceException(managementError!);
  }
}

TalkPoll pollFixture({
  int id = 7,
  String question = 'Lunch?',
  PollStatus status = PollStatus.open,
  List<int> votedSelf = const [],
  List<String> options = const ['Pizza', 'Salad'],
  int maxVotes = 1,
}) => TalkPoll.fromJson({
  'id': id,
  'question': question,
  'options': options,
  'actorType': 'users',
  'actorId': 'fixture-user',
  'actorDisplayName': 'Fixture User',
  'status': status.index,
  'resultMode': 0,
  'maxVotes': maxVotes,
  if (status != PollStatus.draft) ...{
    'votedSelf': votedSelf,
    'votes': votedSelf.isEmpty ? <Object?>[] : {'option-1': 1},
    'numVoters': votedSelf.isEmpty ? 0 : 1,
  },
});
