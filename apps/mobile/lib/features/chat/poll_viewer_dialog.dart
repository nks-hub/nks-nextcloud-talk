part of 'poll_dialog.dart';

final class PollViewerDialog extends StatefulWidget {
  const PollViewerDialog({
    required this.sender,
    required this.roomKey,
    required this.pollId,
    this.initialPoll,
    this.isCurrent,
    this.exportSystem,
    super.key,
  });

  final PollSender sender;
  final PollRoomKey roomKey;
  final int pollId;
  final TalkPoll? initialPoll;
  final bool Function()? isCurrent;
  final ChatAttachmentSystem? exportSystem;

  @override
  State<PollViewerDialog> createState() => _PollViewerDialogState();
}

final class _PollViewerDialogState extends State<PollViewerDialog> {
  TalkPoll? _poll;
  Set<int> _selected = const {};
  bool _loading = true;
  bool _submitting = false;
  bool _voting = false;
  String? _error;
  int _generation = 0;

  bool get _scopeCurrent => widget.isCurrent?.call() ?? true;
  bool _current(int generation) =>
      mounted && _generation == generation && _scopeCurrent;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialPoll;
    if (initial != null && initial.id == widget.pollId) {
      _poll = initial;
      _selected = initial.votedSelf.toSet();
      _loading = false;
    } else {
      _load();
    }
  }

  @override
  void didUpdateWidget(covariant PollViewerDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.roomKey != widget.roomKey ||
        oldWidget.pollId != widget.pollId ||
        oldWidget.sender != widget.sender) {
      _poll = null;
      _selected = {};
      _submitting = false;
      _voting = false;
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final poll = _poll;
    return AlertDialog(
      key: const Key('poll-viewer-dialog'),
      title: Text(poll?.question ?? strings.pollMenuAction),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: _loading
            ? Semantics(
                label: strings.pollLoading,
                child: const Center(child: CircularProgressIndicator()),
              )
            : poll == null
            ? Semantics(
                liveRegion: true,
                child: Text(
                  _error ?? strings.pollFailed,
                  key: const Key('poll-viewer-error'),
                ),
              )
            : SingleChildScrollView(child: _buildPoll(strings, poll)),
      ),
      actions: [
        if (!_loading && (poll == null || _error != null))
          TextButton(
            key: const Key('poll-viewer-retry'),
            onPressed: _submitting || !_scopeCurrent ? null : _load,
            child: Text(strings.pollReloadAction),
          ),
        if (poll?.status == PollStatus.open)
          FilledButton(
            key: const Key('poll-viewer-vote'),
            onPressed: _submitting || !_scopeCurrent ? null : _vote,
            child: _voting
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(strings.pollVoteAction),
          ),
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: Text(strings.close),
        ),
      ],
    );
  }

  Widget _buildPoll(AppLocalizations strings, TalkPoll poll) {
    final multiple = poll.maxVotes == 0 || poll.maxVotes > 1;
    final children = <Widget>[];
    for (var index = 0; index < poll.options.length; index++) {
      final subtitle = poll.votes[index] == null
          ? null
          : Text('${poll.votes[index]}');
      children.add(
        multiple
            ? CheckboxListTile(
                key: Key('poll-viewer-option-$index'),
                contentPadding: EdgeInsets.zero,
                value: _selected.contains(index),
                onChanged:
                    _submitting ||
                        poll.status != PollStatus.open ||
                        !_scopeCurrent
                    ? null
                    : (selected) => _select(index, selected ?? false, true),
                title: Text(poll.options[index]),
                subtitle: subtitle,
              )
            : RadioListTile<int>(
                key: Key('poll-viewer-option-$index'),
                contentPadding: EdgeInsets.zero,
                value: index,
                enabled:
                    !_submitting &&
                    poll.status == PollStatus.open &&
                    _scopeCurrent,
                title: Text(poll.options[index]),
                subtitle: subtitle,
              ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (multiple)
          ...children
        else
          RadioGroup<int>(
            groupValue: _selected.singleOrNull,
            onChanged: (value) {
              if (!_submitting &&
                  poll.status == PollStatus.open &&
                  _scopeCurrent &&
                  value != null) {
                setState(() => _selected = {value});
              }
            },
            child: Column(mainAxisSize: MainAxisSize.min, children: children),
          ),
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
              key: const Key('poll-viewer-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }

  void _select(int index, bool selected, bool multiple) {
    setState(() {
      final next = multiple ? {..._selected} : <int>{};
      selected ? next.add(index) : next.remove(index);
      _selected = next;
    });
  }

  Future<void> _load() async {
    if (!_scopeCurrent) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final poll = await widget.sender.load(
        key: widget.roomKey,
        pollId: widget.pollId,
      );
      if (!_current(generation)) return;
      setState(() {
        _poll = poll;
        _selected = poll.votedSelf.toSet();
        _loading = false;
      });
    } on PollServiceException catch (error) {
      if (!_current(generation)) return;
      setState(() {
        _poll = null;
        _loading = false;
        _error = _pollError(AppLocalizations.of(context), error.code);
      });
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
}
