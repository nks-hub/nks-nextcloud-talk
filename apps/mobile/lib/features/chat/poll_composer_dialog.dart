part of 'poll_dialog.dart';

final class PollComposerDialog extends StatefulWidget {
  const PollComposerDialog({
    required this.sender,
    required this.roomKey,
    this.draftToEdit,
    this.saveDraftOnly = false,
    this.isCurrent,
    this.exportSystem,
    super.key,
  });

  final PollSender sender;
  final PollRoomKey roomKey;
  final TalkPoll? draftToEdit;
  final bool saveDraftOnly;
  final bool Function()? isCurrent;
  final ChatAttachmentSystem? exportSystem;

  @override
  State<PollComposerDialog> createState() => _PollComposerDialogState();
}

final class _PollComposerDialogState extends State<PollComposerDialog> {
  final _formKey = GlobalKey<FormState>();
  final _question = TextEditingController();
  final _options = <TextEditingController>[
    TextEditingController(),
    TextEditingController(),
  ];
  bool _multipleAnswers = false;
  int _multipleVoteLimit = 0;
  bool _hiddenResults = false;
  bool _submitting = false;
  bool _voting = false;
  TalkPoll? _poll;
  Set<int> _selected = const {};
  String? _error;
  PollManagementAccess _access = const PollManagementAccess();
  bool _accessFailed = false;
  int _generation = 0;

  bool get _scopeCurrent => widget.isCurrent?.call() ?? true;
  bool _current(int generation) =>
      mounted && generation == _generation && _scopeCurrent;
  bool get _draftEditor => widget.saveDraftOnly || widget.draftToEdit != null;

  @override
  void initState() {
    super.initState();
    _initializeEditor();
    _loadAccess();
  }

  void _initializeEditor() {
    final draft = widget.draftToEdit;
    _question.text = draft?.question ?? '';
    for (final option in _options) {
      option.dispose();
    }
    _options
      ..clear()
      ..addAll(
        (draft?.options ?? const ['', '']).map(
          (text) => TextEditingController(text: text),
        ),
      );
    _multipleAnswers = draft != null && draft.maxVotes != 1;
    _multipleVoteLimit = _multipleAnswers ? draft!.maxVotes : 0;
    _hiddenResults = draft?.resultMode == PollResultMode.hiddenUntilClosed;
  }

  @override
  void didUpdateWidget(covariant PollComposerDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.roomKey != widget.roomKey ||
        oldWidget.sender != widget.sender ||
        oldWidget.draftToEdit != widget.draftToEdit) {
      _generation++;
      _poll = null;
      _error = null;
      _submitting = false;
      _voting = false;
      _access = const PollManagementAccess();
      _accessFailed = false;
      _initializeEditor();
      _loadAccess();
    }
  }

  Future<void> _loadAccess() async {
    final generation = _generation;
    try {
      final access = await widget.sender.managementAccess(
        key: widget.roomKey,
        poll: widget.draftToEdit,
      );
      if (_current(generation)) {
        setState(() {
          _access = access;
          if (_accessFailed) _error = null;
          _accessFailed = false;
        });
      }
    } on PollServiceException catch (error) {
      if (_current(generation) && _draftEditor) {
        setState(() {
          _accessFailed = true;
          _error = _pollError(AppLocalizations.of(context), error.code);
        });
      }
    }
  }

  @override
  void dispose() {
    _question.dispose();
    for (final option in _options) {
      option.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final poll = _poll;
    return AlertDialog(
      key: const Key('poll-composer-dialog'),
      title: Text(
        poll == null
            ? (widget.draftToEdit != null
                  ? strings.pollEditDraft
                  : _draftEditor
                  ? strings.pollNewDraft
                  : strings.pollCreateTitle)
            : poll.status == PollStatus.draft
            ? strings.pollDraftSaved
            : strings.pollCreated,
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: poll == null
            ? _buildEditor(strings)
            : SingleChildScrollView(child: _buildConfirmedPoll(strings, poll)),
      ),
      actions: poll == null
          ? [
              TextButton(
                onPressed: _submitting
                    ? null
                    : () => Navigator.of(context).pop(false),
                child: Text(strings.cancel),
              ),
              FilledButton(
                key: const Key('poll-create-submit'),
                onPressed:
                    _submitting ||
                        !_scopeCurrent ||
                        (_draftEditor &&
                            !(widget.draftToEdit != null
                                ? _access.canEditDraft
                                : _access.canCreateDraft))
                    ? null
                    : () => _create(saveDraft: _draftEditor),
                child: _submitting
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        _draftEditor
                            ? strings.pollSaveDraft
                            : strings.pollCreateAction,
                      ),
              ),
              if (!_draftEditor && _access.canCreateDraft)
                TextButton(
                  key: const Key('poll-save-draft'),
                  onPressed: _submitting || !_scopeCurrent
                      ? null
                      : () => _create(saveDraft: true),
                  child: Text(strings.pollSaveDraft),
                ),
              if (!_draftEditor && _access.canListDrafts)
                TextButton(
                  key: const Key('poll-open-drafts'),
                  onPressed: _submitting || !_scopeCurrent ? null : _openDrafts,
                  child: Text(strings.pollDraftsTitle),
                ),
              if (_accessFailed)
                TextButton(
                  onPressed: _submitting || !_scopeCurrent ? null : _loadAccess,
                  child: Text(strings.retry),
                ),
            ]
          : [
              if (poll.status == PollStatus.open)
                FilledButton(
                  key: const Key('poll-vote-submit'),
                  onPressed: _submitting || !_scopeCurrent ? null : _vote,
                  child: _voting
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(strings.pollVoteAction),
                ),
              TextButton(
                key: const Key('poll-close'),
                onPressed: _submitting
                    ? null
                    : () => Navigator.of(context).pop(true),
                child: Text(strings.close),
              ),
            ],
    );
  }

  Widget _buildEditor(AppLocalizations strings) {
    return SizedBox(
      width: 480,
      height: 380,
      child: Form(
        key: _formKey,
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                itemCount: _options.length + 5,
                itemBuilder: (context, item) {
                  if (item == 0) {
                    return TextFormField(
                      key: const Key('poll-question'),
                      controller: _question,
                      enabled: !_submitting,
                      autofocus: true,
                      maxLength: 32000,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        labelText: strings.pollQuestion,
                      ),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                          ? strings.pollQuestionRequired
                          : utf8.encode(value.trim()).length > 32000
                          ? strings.pollTextTooLong
                          : null,
                    );
                  }
                  if (item <= _options.length) {
                    return _buildOption(strings, item - 1);
                  }
                  return switch (item - _options.length) {
                    1 => Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton.icon(
                        key: const Key('poll-option-add'),
                        onPressed: _submitting || _options.length >= 1000
                            ? null
                            : _addOption,
                        icon: const Icon(Icons.add),
                        label: Text(strings.pollAddOption),
                      ),
                    ),
                    2 => SwitchListTile.adaptive(
                      key: const Key('poll-multiple-answers'),
                      contentPadding: EdgeInsets.zero,
                      value: _multipleAnswers,
                      onChanged: _submitting
                          ? null
                          : (value) => setState(() => _multipleAnswers = value),
                      title: Text(strings.pollMultipleAnswers),
                    ),
                    3 =>
                      !_multipleAnswers
                          ? const SizedBox.shrink()
                          : DropdownButtonFormField<int>(
                              key: ValueKey(
                                'poll-max-votes-$_multipleVoteLimit-${_options.length}',
                              ),
                              initialValue: _multipleVoteLimit,
                              decoration: InputDecoration(
                                labelText: strings.pollMaxVotes,
                              ),
                              items: [
                                DropdownMenuItem(
                                  value: 0,
                                  child: Text(strings.pollUnlimitedVotes),
                                ),
                                for (
                                  var count = 2;
                                  count <= _options.length;
                                  count++
                                )
                                  DropdownMenuItem(
                                    value: count,
                                    child: Text('$count'),
                                  ),
                              ],
                              onChanged: _submitting
                                  ? null
                                  : (value) {
                                      if (value != null) {
                                        setState(
                                          () => _multipleVoteLimit = value,
                                        );
                                      }
                                    },
                            ),
                    _ => SwitchListTile.adaptive(
                      key: const Key('poll-hidden-results'),
                      contentPadding: EdgeInsets.zero,
                      value: _hiddenResults,
                      onChanged: _submitting
                          ? null
                          : (value) => setState(() => _hiddenResults = value),
                      title: Text(strings.pollHiddenResults),
                    ),
                  };
                },
              ),
            ),
            if (_error != null)
              Semantics(
                liveRegion: true,
                child: Text(
                  _error!,
                  key: const Key('poll-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildOption(AppLocalizations strings, int index) => Row(
    key: Key('poll-option-row-$index'),
    children: [
      Expanded(
        child: TextFormField(
          key: Key('poll-option-$index'),
          controller: _options[index],
          enabled: !_submitting,
          maxLength: 32000,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(labelText: strings.pollOption(index + 1)),
          validator: (value) => value == null || value.trim().isEmpty
              ? strings.pollOptionRequired
              : null,
        ),
      ),
      if (_options.length > 2)
        IconButton(
          key: Key('poll-option-remove-$index'),
          tooltip: strings.pollRemoveOption,
          onPressed: _submitting ? null : () => _removeOption(index),
          icon: const Icon(Icons.remove_circle_outline),
        ),
    ],
  );

  Widget _buildConfirmedPoll(AppLocalizations strings, TalkPoll poll) {
    final allowsMultiple = poll.maxVotes == 0 || poll.maxVotes > 1;
    final options = allowsMultiple
        ? <Widget>[
            for (var index = 0; index < poll.options.length; index++)
              CheckboxListTile(
                key: Key('poll-vote-option-$index'),
                contentPadding: EdgeInsets.zero,
                value: _selected.contains(index),
                onChanged:
                    _submitting ||
                        poll.status != PollStatus.open ||
                        !_scopeCurrent
                    ? null
                    : (value) => _select(index, value ?? false, true),
                title: Text(poll.options[index]),
                subtitle: _voteCount(poll, index),
              ),
          ]
        : <Widget>[
            RadioGroup<int>(
              groupValue: _selected.singleOrNull,
              onChanged:
                  _submitting ||
                      poll.status != PollStatus.open ||
                      !_scopeCurrent
                  ? (_) {}
                  : (value) {
                      if (value != null) {
                        setState(() => _selected = {value});
                      }
                    },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var index = 0; index < poll.options.length; index++)
                    RadioListTile<int>(
                      key: Key('poll-vote-option-$index'),
                      contentPadding: EdgeInsets.zero,
                      value: index,
                      enabled:
                          !_submitting &&
                          poll.status == PollStatus.open &&
                          _scopeCurrent,
                      title: Text(poll.options[index]),
                      subtitle: _voteCount(poll, index),
                    ),
                ],
              ),
            ),
          ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(poll.question, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        ...options,
        _PollManagementActions(
          sender: widget.sender,
          roomKey: widget.roomKey,
          poll: poll,
          busy: _submitting,
          isCurrent: () => _scopeCurrent,
          exportSystem: widget.exportSystem,
          onBusy: (busy) {
            if (mounted) setState(() => _submitting = busy);
          },
          onChanged: (updated) => setState(() {
            _poll = updated;
            _selected = updated.votedSelf.toSet();
          }),
          onError: (error) => setState(() => _error = error),
        ),
        if (_error != null)
          Semantics(
            liveRegion: true,
            child: Text(
              _error!,
              key: const Key('poll-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }

  Widget? _voteCount(TalkPoll poll, int index) {
    final count = poll.votes[index];
    return count == null ? null : Text('$count');
  }

  void _addOption() {
    if (_submitting || _options.length >= 1000) return;
    setState(() => _options.add(TextEditingController()));
  }

  void _removeOption(int index) {
    if (_submitting ||
        _options.length <= 2 ||
        index < 0 ||
        index >= _options.length) {
      return;
    }
    final controller = _options.removeAt(index);
    controller.dispose();
    if (_multipleVoteLimit > _options.length) {
      _multipleVoteLimit = _options.length;
    }
    setState(() {});
  }

  void _select(int index, bool selected, bool multiple) {
    setState(() {
      final next = multiple ? {..._selected} : <int>{};
      selected ? next.add(index) : next.remove(index);
      _selected = next;
    });
  }

  Future<void> _create({bool saveDraft = false}) async {
    if (_submitting || !_scopeCurrent) return;
    final strings = AppLocalizations.of(context);
    final formError = _question.text.trim().isEmpty
        ? strings.pollQuestionRequired
        : _options.any((option) => option.text.trim().isEmpty)
        ? strings.pollOptionRequired
        : utf8.encode(_question.text.trim()).length > 32000
        ? strings.pollTextTooLong
        : null;
    if (formError != null) {
      setState(() => _error = formError);
      return;
    }
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final options = _options
        .map((option) => option.text.trim())
        .toList(growable: false);
    if (utf8.encode(jsonEncode(options)).length > 60000) {
      setState(() => _error = AppLocalizations.of(context).pollTextTooLong);
      return;
    }
    final generation = ++_generation;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final mode = _hiddenResults
          ? PollResultMode.hiddenUntilClosed
          : PollResultMode.public;
      final maxVotes = _multipleAnswers ? _multipleVoteLimit : 1;
      final draft = widget.draftToEdit;
      final TalkPoll poll;
      if (draft != null) {
        poll = await widget.sender.editDraft(
          key: widget.roomKey,
          draft: draft,
          question: _question.text,
          options: options,
          resultMode: mode,
          maxVotes: maxVotes,
        );
      } else if (saveDraft) {
        poll = await widget.sender.createDraft(
          key: widget.roomKey,
          question: _question.text,
          options: options,
          resultMode: mode,
          maxVotes: maxVotes,
        );
      } else {
        poll = await widget.sender.create(
          key: widget.roomKey,
          question: _question.text,
          options: options,
          resultMode: mode,
          maxVotes: maxVotes,
        );
      }
      if (!_current(generation)) return;
      setState(() {
        _poll = poll;
        _selected = poll.votedSelf.toSet();
        _submitting = false;
      });
    } on PollServiceException catch (error) {
      if (!_current(generation)) return;
      setState(() {
        _submitting = false;
        _error = _pollError(AppLocalizations.of(context), error.code);
      });
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _submitting = false);
      }
    }
  }

  Future<void> _vote() async {
    if (_submitting || !_scopeCurrent || _poll?.status != PollStatus.open) {
      return;
    }
    final generation = ++_generation;
    final poll = _poll!;
    if (_selected.isEmpty) {
      setState(() => _error = AppLocalizations.of(context).pollSelectOption);
      return;
    }
    setState(() {
      _submitting = true;
      _voting = true;
      _error = null;
    });
    try {
      final updated = await widget.sender.vote(
        key: widget.roomKey,
        poll: poll,
        optionIds: _selected.toList(growable: false)..sort(),
      );
      if (!_current(generation)) return;
      setState(() {
        _poll = updated;
        _selected = updated.votedSelf.toSet();
        _submitting = false;
      });
    } on PollServiceException catch (error) {
      if (!_current(generation)) return;
      setState(() {
        _submitting = false;
        _error = _pollError(AppLocalizations.of(context), error.code);
      });
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _submitting = false;
          _voting = false;
        });
      }
    }
  }

  Future<void> _openDrafts() async {
    if (_submitting || !_scopeCurrent) return;
    final generation = _generation;
    await showDialog<void>(
      context: context,
      builder: (_) => PollDraftsDialog(
        sender: widget.sender,
        roomKey: widget.roomKey,
        isCurrent: () => _current(generation),
        exportSystem: widget.exportSystem,
      ),
    );
  }
}
