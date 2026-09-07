part of 'poll_dialog.dart';

Future<bool> _confirmPollAction(
  BuildContext context,
  String title,
  String message,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(AppLocalizations.of(context).cancel),
          ),
          FilledButton(
            key: const Key('poll-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(title),
          ),
        ],
      ),
    ) ==
    true;

final class _PollManagementActions extends StatefulWidget {
  const _PollManagementActions({
    required this.sender,
    required this.roomKey,
    required this.poll,
    required this.busy,
    required this.isCurrent,
    required this.onBusy,
    required this.onChanged,
    required this.onError,
    this.exportSystem,
  });

  final PollSender sender;
  final PollRoomKey roomKey;
  final TalkPoll poll;
  final bool busy;
  final bool Function() isCurrent;
  final ValueChanged<bool> onBusy;
  final ValueChanged<TalkPoll> onChanged;
  final ValueChanged<String?> onError;
  final ChatAttachmentSystem? exportSystem;

  @override
  State<_PollManagementActions> createState() => _PollManagementActionsState();
}

final class _PollManagementActionsState extends State<_PollManagementActions> {
  PollManagementAccess? _access;
  bool _accessFailed = false;
  bool _running = false;
  bool _showProgress = false;
  int _generation = 0;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _loadAccess();
  }

  @override
  void didUpdateWidget(covariant _PollManagementActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.roomKey != widget.roomKey ||
        oldWidget.sender != widget.sender ||
        oldWidget.poll != widget.poll) {
      _access = null;
      _notice = null;
      _running = false;
      _loadAccess();
    }
  }

  bool _current(int generation) =>
      mounted && generation == _generation && widget.isCurrent();

  Future<void> _loadAccess() async {
    final generation = ++_generation;
    try {
      final access = await widget.sender.managementAccess(
        key: widget.roomKey,
        poll: widget.poll,
      );
      if (_current(generation)) {
        setState(() {
          _access = access;
          _accessFailed = false;
        });
      }
    } on PollServiceException {
      if (_current(generation)) setState(() => _accessFailed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final disabled = widget.busy || _running || !widget.isCurrent();
    final access = _access;
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (_running && _showProgress)
          SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              semanticsLabel: strings.pollLoading,
            ),
          ),
        if (widget.poll.status == PollStatus.closed) Text(strings.pollClosed),
        if (access?.canClose == true && widget.poll.status == PollStatus.open)
          TextButton(
            key: const Key('poll-end'),
            onPressed: disabled ? null : _close,
            child: Text(strings.pollEndAction),
          ),
        if (access?.canExport == true && widget.poll.status != PollStatus.draft)
          PopupMenuButton<PollExportFormat>(
            key: const Key('poll-export'),
            tooltip: strings.pollExportAction,
            enabled: !disabled,
            onSelected: _export,
            itemBuilder: (_) => [
              PopupMenuItem(
                value: PollExportFormat.csv,
                child: Text(strings.pollExportCsv),
              ),
              PopupMenuItem(
                value: PollExportFormat.ods,
                child: Text(strings.pollExportOds),
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(strings.pollExportAction),
            ),
          ),
        if (_accessFailed)
          TextButton(
            onPressed: disabled ? null : _loadAccess,
            child: Text(strings.retry),
          ),
        if (_notice != null) Semantics(liveRegion: true, child: Text(_notice!)),
      ],
    );
  }

  Future<void> _run(
    Future<void> Function(int generation) operation, {
    bool showProgress = false,
  }) async {
    if (_running || widget.busy || !widget.isCurrent()) return;
    final generation = _generation;
    setState(() {
      _running = true;
      _showProgress = showProgress;
      _notice = null;
    });
    widget.onError(null);
    widget.onBusy(true);
    try {
      await operation(generation);
    } on PollServiceException catch (error) {
      if (mounted && _current(generation)) {
        widget.onError(_pollError(AppLocalizations.of(context), error.code));
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _running = false);
        widget.onBusy(false);
      }
    }
  }

  Future<void> _close() => _run((generation) async {
    final strings = AppLocalizations.of(context);
    if (!await _confirmPollAction(
          context,
          strings.pollEndAction,
          strings.pollEndConfirm,
        ) ||
        !_current(generation)) {
      return;
    }
    final poll = await widget.sender.close(
      key: widget.roomKey,
      poll: widget.poll,
    );
    if (_current(generation)) widget.onChanged(poll);
  });

  Future<void> _export(PollExportFormat format) => _run((generation) async {
    final file = await widget.sender.export(
      key: widget.roomKey,
      poll: widget.poll,
      format: format,
    );
    if (!mounted || !_current(generation)) return;
    final system = widget.exportSystem ?? PlatformChatAttachmentSystem();
    final result = await system.save(
      bytes: file.bytes,
      fileName: file.fileName,
      contentType: file.mimeType,
    );
    if (!mounted || !_current(generation)) return;
    if (result == ChatAttachmentSystemResult.completed) {
      setState(() => _notice = AppLocalizations.of(context).pollExportSaved);
    } else if (result != ChatAttachmentSystemResult.cancelled) {
      widget.onError(AppLocalizations.of(context).pollExportFailed);
    }
  }, showProgress: true);
}
