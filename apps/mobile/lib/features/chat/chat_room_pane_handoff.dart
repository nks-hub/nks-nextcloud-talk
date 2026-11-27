part of 'chat_room_pane.dart';

extension _ChatRoomHandoff on _ChatRoomPaneState {
  Future<void> _publishDraft(DraftRoom key, String text, int? reply) async {
    try {
      if (text.trim().isEmpty) {
        await _handoff.clearCurrent(key);
        return;
      }
      final version = await _handoff.stage(key, text, reply);
      if (version != null) await _handoff.sync(key);
    } on Exception {
      // The device keeps its draft and immutable pending writes for the next open.
    }
  }

  Future<void> _removeAdmittedDraft(
    DraftRoom key,
    Future<HandoffVersion?> shared,
    int generation,
  ) async {
    try {
      final version = await shared;
      if (version != null) {
        await _handoff.admitted(key, version, expectedGeneration: generation);
      }
    } on Exception {
      // Pending removals are retried together with edits in this room.
    }
  }

  Future<void> _restoreSharedDraft(DraftRoom key) async {
    final text = _composer.text;
    final reply = _replyTo;
    final generation = _handoff.generation(key.accountId);
    bool current() =>
        mounted &&
        key == _key &&
        _composer.text == text &&
        identical(_replyTo, reply);
    try {
      if (!await _handoff.enabled(key.accountId) || !current()) return;
      final local = text.trim().isEmpty
          ? null
          : await _handoff.stage(key, text, reply?.messageId);
      if (!current()) return;
      final versions = await _handoff.sync(key);
      if (!mounted ||
          !current() ||
          _handoff.generation(key.accountId) != generation) {
        return;
      }
      if (versions.isEmpty) {
        // Another device sent or cleared the exact revision on screen.
        if (local != null) {
          _update(() => _replyTo = null);
          _composer.clear();
        }
        return;
      }
      if (versions.length > 1) {
        final strings = AppLocalizations.of(context);
        _showLocationSnackBar(
          strings.draftHandoffVariants,
          action: SnackBarAction(
            label: strings.draftHandoffTitle,
            onPressed: () => unawaited(_showDraftHandoff()),
          ),
        );
      } else if (versions.single.id != local?.id) {
        await _adoptDraft(key, versions.single, automatic: true);
      }
    } on Exception {
      // The handoff sheet lets the user retry without interrupting local typing.
    }
  }

  Future<void> _showDraftHandoff() async {
    final key = _key;
    final text = _composer.text;
    final reply = _replyTo?.messageId;
    final version = await showDialog<HandoffVersion>(
      context: context,
      builder: (_) => _DraftHandoffDialog(
        scope: key,
        store: _handoff,
        localText: text,
        localReply: reply,
      ),
    );
    if (!mounted ||
        _key != key ||
        version == null ||
        _isReadOnlyNow() ||
        _composer.text != text ||
        _replyTo?.messageId != reply) {
      return;
    }
    try {
      await _adoptDraft(key, version, automatic: false);
    } on Exception {
      if (mounted && key == _key) {
        _showLocationSnackBar(
          AppLocalizations.of(context).draftHandoffUnavailable,
        );
      }
    }
  }

  Future<void> _adoptDraft(
    DraftRoom key,
    HandoffVersion version, {
    required bool automatic,
  }) async {
    final original = _composer.text;
    final originalReply = _replyTo;
    bool current() =>
        mounted &&
        _key == key &&
        _composer.text == original &&
        identical(originalReply, _replyTo) &&
        !_isReadOnlyNow();
    final store = ref.read(chatRepositoryProvider);
    final service = ref.read(chatServiceProvider);
    CachedChatMessage? quote;
    final reply = version.replyTo;
    if (reply != null) {
      Future<CachedChatMessage?> read() => store.getMessage(
        accountId: key.accountId,
        roomToken: key.roomToken,
        messageId: reply,
      );
      quote = await read();
      if (quote == null && current()) {
        try {
          final contextResult = await service.loadMessageContext(
            accountId: key.accountId,
            roomToken: key.roomToken,
            threadId: key.threadId,
            messageId: reply,
            readerIsActive: current,
          );
          if (!mounted || !current()) return;
          if (contextResult.outcome != ChatFetchOutcome.done) {
            _showLocationSnackBar(
              AppLocalizations.of(context).draftHandoffUnavailable,
            );
            return;
          }
          quote = await read();
        } on ChatServiceException {
          if (mounted && current()) {
            _showLocationSnackBar(
              AppLocalizations.of(context).draftHandoffUnavailable,
            );
          }
          return;
        }
      }
      if (!mounted || !current()) return;
      if (quote == null || !quote.canQuoteIn(key.threadId)) {
        final strings = AppLocalizations.of(context);
        if (automatic) {
          _showLocationSnackBar(strings.draftHandoffMissingQuote);
          return;
        }
        final remove = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            content: Text(strings.draftHandoffMissingQuote),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(strings.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(strings.cancelReply),
              ),
            ],
          ),
        );
        if (remove != true || !current()) return;
        quote = null;
      }
    }
    if (!current()) return;
    await _handoff.adopt(key, version, stillCurrent: current);
    if (!current()) return;
    _restoredQuote = quote;
    _update(() => _replyTo = quote);
    _composer.value = TextEditingValue(
      text: version.text,
      selection: TextSelection.collapsed(offset: version.text.length),
    );
    if (!automatic) _composerFocusNode.requestFocus();
  }
}

final class _DraftHandoffDialog extends StatefulWidget {
  const _DraftHandoffDialog({
    required this.scope,
    required this.store,
    required this.localText,
    required this.localReply,
  });
  final DraftRoom scope;
  final DraftHandoffStore store;
  final String localText;
  final int? localReply;
  @override
  State<_DraftHandoffDialog> createState() => _DraftHandoffDialogState();
}

final class _DraftHandoffDialogState extends State<_DraftHandoffDialog> {
  bool _enabled = false;
  bool _loading = true;
  bool _error = false;
  List<HandoffVersion> _versions = [];
  String? _localId;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool? enable}) async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final store = widget.store;
      final key = widget.scope;
      if (enable != null) await store.setEnabled(key.accountId, enable);
      final enabled = await store.enabled(key.accountId);
      if (!mounted) return;
      setState(() => _enabled = enabled);
      if (enabled) {
        if (widget.localText.trim().isNotEmpty) {
          _localId = (await store.stage(
            key,
            widget.localText,
            widget.localReply,
          ))?.id;
        }
        final versions = await store.sync(key);
        if (mounted) setState(() => _versions = versions);
      } else if (mounted) {
        setState(() => _versions = []);
      }
    } on Exception {
      if (mounted) setState(() => _error = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(strings.draftHandoffTitle),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                key: const Key('enable-draft-handoff'),
                title: Text(strings.draftHandoffEnable),
                subtitle: Text(strings.draftHandoffPrivacy),
                value: _enabled,
                onChanged: _loading ? null : (v) => unawaited(_load(enable: v)),
              ),
              if (_loading)
                const LinearProgressIndicator()
              else if (_error) ...[
                Text(strings.draftHandoffUnavailable),
                TextButton(
                  onPressed: () => unawaited(_load()),
                  child: Text(strings.retry),
                ),
              ] else if (_enabled) ...[
                Text(
                  _versions.isEmpty
                      ? strings.draftHandoffEmpty
                      : strings.draftHandoffVariants,
                ),
                for (final v in _versions)
                  ListTile(
                    key: ValueKey('handoff-${v.id}'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      v.text,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: v.id == _localId
                        ? Text(strings.draftHandoffThisDevice)
                        : v.replyTo == null
                        ? null
                        : Text('${strings.messageActionReply} #${v.replyTo}'),
                    leading: Icon(
                      v.replyTo == null ? Icons.edit_outlined : Icons.reply,
                    ),
                    onTap: () => Navigator.pop(context, v),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(strings.close),
        ),
      ],
    );
  }
}
