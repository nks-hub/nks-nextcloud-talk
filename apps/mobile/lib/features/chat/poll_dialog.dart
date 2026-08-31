import 'package:flutter/material.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../l10n/generated/app_localizations.dart';
import 'poll_service.dart';

final class PollComposerDialog extends StatefulWidget {
  const PollComposerDialog({
    required this.sender,
    required this.roomKey,
    super.key,
  });

  final PollSender sender;
  final PollRoomKey roomKey;

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
  bool _hiddenResults = false;
  bool _submitting = false;
  TalkPoll? _poll;
  Set<int> _selected = const {};
  String? _error;

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
      title: Text(poll == null ? strings.pollCreateTitle : strings.pollCreated),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          child: poll == null
              ? _buildEditor(strings)
              : _buildConfirmedPoll(strings, poll),
        ),
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
                onPressed: _submitting ? null : _create,
                child: _submitting
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(strings.pollCreateAction),
              ),
            ]
          : [
              if (poll.status == PollStatus.open)
                FilledButton(
                  key: const Key('poll-vote-submit'),
                  onPressed: _submitting ? null : _vote,
                  child: _submitting
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
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            key: const Key('poll-question'),
            controller: _question,
            autofocus: true,
            maxLength: 500,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(labelText: strings.pollQuestion),
            validator: (value) => value == null || value.trim().isEmpty
                ? strings.pollQuestionRequired
                : null,
          ),
          for (var index = 0; index < _options.length; index++)
            Row(
              key: Key('poll-option-row-$index'),
              children: [
                Expanded(
                  child: TextFormField(
                    key: Key('poll-option-$index'),
                    controller: _options[index],
                    maxLength: 500,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      labelText: strings.pollOption(index + 1),
                    ),
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
            ),
          if (_options.length < 10)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const Key('poll-option-add'),
                onPressed: _submitting ? null : _addOption,
                icon: const Icon(Icons.add),
                label: Text(strings.pollAddOption),
              ),
            ),
          SwitchListTile.adaptive(
            key: const Key('poll-multiple-answers'),
            contentPadding: EdgeInsets.zero,
            value: _multipleAnswers,
            onChanged: _submitting
                ? null
                : (value) => setState(() => _multipleAnswers = value),
            title: Text(strings.pollMultipleAnswers),
          ),
          SwitchListTile.adaptive(
            key: const Key('poll-hidden-results'),
            contentPadding: EdgeInsets.zero,
            value: _hiddenResults,
            onChanged: _submitting
                ? null
                : (value) => setState(() => _hiddenResults = value),
            title: Text(strings.pollHiddenResults),
          ),
          if (_error != null)
            Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  key: const Key('poll-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildConfirmedPoll(AppLocalizations strings, TalkPoll poll) {
    final allowsMultiple = poll.maxVotes == 0 || poll.maxVotes > 1;
    final options = allowsMultiple
        ? <Widget>[
            for (var index = 0; index < poll.options.length; index++)
              CheckboxListTile(
                key: Key('poll-vote-option-$index'),
                contentPadding: EdgeInsets.zero,
                value: _selected.contains(index),
                onChanged: _submitting
                    ? null
                    : (value) => _select(index, value ?? false, true),
                title: Text(poll.options[index]),
                subtitle: _voteCount(poll, index),
              ),
          ]
        : <Widget>[
            RadioGroup<int>(
              groupValue: _selected.singleOrNull,
              onChanged: _submitting
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
                      enabled: !_submitting,
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

  void _addOption() => setState(() => _options.add(TextEditingController()));

  void _removeOption(int index) {
    final controller = _options.removeAt(index);
    controller.dispose();
    setState(() {});
  }

  void _select(int index, bool selected, bool multiple) {
    setState(() {
      final next = multiple ? {..._selected} : <int>{};
      selected ? next.add(index) : next.remove(index);
      _selected = next;
    });
  }

  Future<void> _create() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final poll = await widget.sender.create(
        key: widget.roomKey,
        question: _question.text,
        options: _options.map((option) => option.text).toList(growable: false),
        resultMode: _hiddenResults
            ? PollResultMode.hiddenUntilClosed
            : PollResultMode.public,
        maxVotes: _multipleAnswers ? 0 : 1,
      );
      if (!mounted) return;
      setState(() {
        _poll = poll;
        _selected = poll.votedSelf.toSet();
        _submitting = false;
      });
    } on PollServiceException catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = _errorLabel(AppLocalizations.of(context), error.code);
      });
    }
  }

  Future<void> _vote() async {
    final poll = _poll!;
    if (_selected.isEmpty) {
      setState(() => _error = AppLocalizations.of(context).pollSelectOption);
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final updated = await widget.sender.vote(
        key: widget.roomKey,
        poll: poll,
        optionIds: _selected.toList(growable: false)..sort(),
      );
      if (!mounted) return;
      setState(() {
        _poll = updated;
        _selected = updated.votedSelf.toSet();
        _submitting = false;
      });
    } on PollServiceException catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = _errorLabel(AppLocalizations.of(context), error.code);
      });
    }
  }

  String _errorLabel(AppLocalizations strings, PollServiceError error) =>
      switch (error) {
        PollServiceError.unsupported => strings.pollUnsupported,
        PollServiceError.permissionDenied => strings.pollPermissionDenied,
        PollServiceError.reauthenticationRequired => strings.pollSignInAgain,
        PollServiceError.rateLimited => strings.pollRateLimited,
        PollServiceError.ambiguous => strings.pollAmbiguous,
        _ => strings.pollFailed,
      };
}

final class PollViewerDialog extends StatefulWidget {
  const PollViewerDialog({
    required this.sender,
    required this.roomKey,
    required this.pollId,
    super.key,
  });

  final PollSender sender;
  final PollRoomKey roomKey;
  final int pollId;

  @override
  State<PollViewerDialog> createState() => _PollViewerDialogState();
}

final class _PollViewerDialogState extends State<PollViewerDialog> {
  TalkPoll? _poll;
  Set<int> _selected = const {};
  bool _loading = true;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
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
        if (!_loading && poll == null)
          TextButton(
            key: const Key('poll-viewer-retry'),
            onPressed: _load,
            child: Text(strings.pollReloadAction),
          ),
        if (poll?.status == PollStatus.open)
          FilledButton(
            key: const Key('poll-viewer-vote'),
            onPressed: _submitting ? null : _vote,
            child: _submitting
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
                onChanged: _submitting
                    ? null
                    : (selected) => _select(index, selected ?? false, true),
                title: Text(poll.options[index]),
                subtitle: subtitle,
              )
            : RadioListTile<int>(
                key: Key('poll-viewer-option-$index'),
                contentPadding: EdgeInsets.zero,
                value: index,
                enabled: !_submitting,
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
              if (!_submitting && value != null) {
                setState(() => _selected = {value});
              }
            },
            child: Column(mainAxisSize: MainAxisSize.min, children: children),
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
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final poll = await widget.sender.load(
        key: widget.roomKey,
        pollId: widget.pollId,
      );
      if (!mounted) return;
      setState(() {
        _poll = poll;
        _selected = poll.votedSelf.toSet();
        _loading = false;
      });
    } on PollServiceException catch (error) {
      if (!mounted) return;
      setState(() {
        _poll = null;
        _loading = false;
        _error = _pollError(AppLocalizations.of(context), error.code);
      });
    }
  }

  Future<void> _vote() async {
    final poll = _poll!;
    if (_selected.isEmpty) {
      setState(() => _error = AppLocalizations.of(context).pollSelectOption);
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final updated = await widget.sender.vote(
        key: widget.roomKey,
        poll: poll,
        optionIds: _selected.toList(growable: false)..sort(),
      );
      if (!mounted) return;
      setState(() {
        _poll = updated;
        _selected = updated.votedSelf.toSet();
        _submitting = false;
      });
    } on PollServiceException catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = _pollError(AppLocalizations.of(context), error.code);
      });
    }
  }
}

String _pollError(AppLocalizations strings, PollServiceError error) =>
    switch (error) {
      PollServiceError.unsupported => strings.pollUnsupported,
      PollServiceError.permissionDenied => strings.pollPermissionDenied,
      PollServiceError.reauthenticationRequired => strings.pollSignInAgain,
      PollServiceError.rateLimited => strings.pollRateLimited,
      PollServiceError.ambiguous => strings.pollAmbiguous,
      _ => strings.pollFailed,
    };
