part of 'poll_dialog.dart';

enum _PollDraftAction { edit, publish, delete }

final class PollDraftsDialog extends StatefulWidget {
  const PollDraftsDialog({
    super.key,
    required this.sender,
    required this.roomKey,
    this.isCurrent,
    this.exportSystem,
  });

  final PollSender sender;
  final PollRoomKey roomKey;
  final bool Function()? isCurrent;
  final ChatAttachmentSystem? exportSystem;

  @override
  State<PollDraftsDialog> createState() => _PollDraftsDialogState();
}

final class _PollDraftsDialogState extends State<PollDraftsDialog> {
  List<TalkPoll> _drafts = [];
  PollManagementAccess _access = const PollManagementAccess();
  bool _loading = true;
  bool _busy = false;
  String? _error;
  int _epoch = 0;
  int _loadRequest = 0;

  bool get _scopeCurrent => widget.isCurrent?.call() ?? true;
  bool _current(int epoch) => mounted && epoch == _epoch && _scopeCurrent;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant PollDraftsDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.roomKey != widget.roomKey ||
        oldWidget.sender != widget.sender) {
      _epoch++;
      _busy = false;
      _drafts = [];
      _access = const PollManagementAccess();
      _load();
    }
  }

  Future<void> _load() async {
    if (!_scopeCurrent) return;
    final epoch = _epoch;
    final request = ++_loadRequest;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final access = await widget.sender.managementAccess(key: widget.roomKey);
      if (!_current(epoch) || request != _loadRequest) return;
      if (!access.canListDrafts) {
        throw const PollServiceException(PollServiceError.permissionDenied);
      }
      final drafts = await widget.sender.listDrafts(key: widget.roomKey);
      if (!_current(epoch) || request != _loadRequest) return;
      setState(() {
        _access = access;
        _drafts = drafts;
      });
    } on PollServiceException catch (error) {
      if (_current(epoch) && request == _loadRequest) {
        setState(
          () => _error = _pollError(AppLocalizations.of(context), error.code),
        );
      }
    } finally {
      if (mounted && epoch == _epoch && request == _loadRequest) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final disabled = _busy || _loading || !_scopeCurrent;
    return AlertDialog(
      key: const Key('poll-drafts-dialog'),
      scrollable: true,
      title: Text(strings.pollDraftsTitle),
      content: SizedBox(
        width: 480,
        height: 320,
        child: Column(
          children: [
            if (_error != null)
              Semantics(
                liveRegion: true,
                child: Text(_error!, key: const Key('poll-drafts-error')),
              ),
            Expanded(
              child: _loading
                  ? Center(
                      child: CircularProgressIndicator(
                        semanticsLabel: strings.pollLoading,
                      ),
                    )
                  : _drafts.isEmpty
                  ? Center(
                      child: Text(
                        _error == null
                            ? strings.pollDraftsEmpty
                            : strings.pollFailed,
                      ),
                    )
                  : ListView.builder(
                      itemCount: _drafts.length,
                      itemBuilder: (context, index) {
                        final draft = _drafts[index];
                        return ListTile(
                          key: ValueKey('poll-draft-${draft.id}'),
                          title: Text(draft.question),
                          onTap: disabled
                              ? null
                              : () => _run((epoch) => _view(draft, epoch)),
                          trailing:
                              !_access.canEditDraft &&
                                  !_access.canPublish &&
                                  !_access.canDeleteDraft
                              ? null
                              : PopupMenuButton<_PollDraftAction>(
                                  key: ValueKey(
                                    'poll-draft-actions-${draft.id}',
                                  ),
                                  enabled: !disabled,
                                  onSelected: (action) => _act(draft, action),
                                  itemBuilder: (_) => [
                                    if (_access.canEditDraft)
                                      PopupMenuItem(
                                        value: _PollDraftAction.edit,
                                        child: Text(strings.pollEditDraft),
                                      ),
                                    if (_access.canPublish)
                                      PopupMenuItem(
                                        value: _PollDraftAction.publish,
                                        child: Text(strings.pollPublishDraft),
                                      ),
                                    if (_access.canDeleteDraft)
                                      PopupMenuItem(
                                        value: _PollDraftAction.delete,
                                        child: Text(strings.pollDeleteDraft),
                                      ),
                                  ],
                                ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        if (_error != null)
          TextButton(
            onPressed: disabled ? null : _load,
            child: Text(strings.retry),
          ),
        if (_access.canCreateDraft)
          FilledButton(
            key: const Key('poll-drafts-create'),
            onPressed: disabled ? null : () => _edit(null),
            child: Text(strings.pollNewDraft),
          ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(strings.close),
        ),
      ],
    );
  }

  Future<void> _run(Future<void> Function(int epoch) action) async {
    if (_busy || _loading || !_scopeCurrent) return;
    final epoch = _epoch;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action(epoch);
    } on PollServiceException catch (error) {
      if (_current(epoch)) {
        setState(
          () => _error = _pollError(AppLocalizations.of(context), error.code),
        );
      }
    } finally {
      if (mounted && epoch == _epoch) setState(() => _busy = false);
    }
  }

  Future<void> _edit(TalkPoll? draft) => _run((epoch) async {
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PollComposerDialog(
        sender: widget.sender,
        roomKey: widget.roomKey,
        draftToEdit: draft,
        saveDraftOnly: true,
        isCurrent: () => _current(epoch),
        exportSystem: widget.exportSystem,
      ),
    );
    if (changed == true && _current(epoch)) await _load();
  });

  Future<void> _act(TalkPoll draft, _PollDraftAction action) async {
    if (action == _PollDraftAction.edit) {
      await _edit(draft);
      return;
    }
    await _run((epoch) async {
      final strings = AppLocalizations.of(context);
      final publish = action == _PollDraftAction.publish;
      if (!await _confirmPollAction(
            context,
            publish ? strings.pollPublishDraft : strings.pollDeleteDraft,
            publish
                ? strings.pollPublishDraftConfirm
                : strings.pollDeleteDraftConfirm,
          ) ||
          !_current(epoch)) {
        return;
      }
      if (publish) {
        final poll = await widget.sender.publishDraft(
          key: widget.roomKey,
          draft: draft,
        );
        if (!_current(epoch)) return;
        await _view(poll, epoch);
      } else {
        await widget.sender.deleteDraft(key: widget.roomKey, draft: draft);
      }
      if (_current(epoch)) await _load();
    });
  }

  Future<void> _view(TalkPoll poll, int epoch) => showDialog<void>(
    context: context,
    builder: (_) => PollViewerDialog(
      sender: widget.sender,
      roomKey: widget.roomKey,
      pollId: poll.id,
      initialPoll: poll,
      isCurrent: () => _current(epoch),
      exportSystem: widget.exportSystem,
    ),
  );
}
