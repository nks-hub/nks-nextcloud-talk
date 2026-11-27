import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import 'owntalk_extensions_service.dart';
import 'owntalk_room_extras.dart';

const checklistPrefix = '☑ ';

List<String>? checklistLines(String message) {
  if (!message.startsWith(checklistPrefix)) return null;
  final lines = message.replaceAll('\r\n', '\n').split('\n');
  final title = lines.first.substring(checklistPrefix.length);
  if (title.trim().isEmpty ||
      title.runes.length > 120 ||
      lines.length < 2 ||
      lines.length > 51) {
    return null;
  }
  final items = <String>[title];
  for (final line in lines.skip(1)) {
    if (!line.startsWith('- [ ] ')) return null;
    final item = line.substring(6);
    if (item.trim().isEmpty || item.runes.length > 200) return null;
    items.add(item);
  }
  return items;
}

class SharedChecklistPreview extends ConsumerWidget {
  const SharedChecklistPreview({
    required this.accountId,
    required this.token,
    required this.id,
    required this.lines,
    required this.source,
    required this.fallback,
    super.key,
  });
  final String accountId, token;
  final int id;
  final List<String> lines;
  final Widget fallback;
  final String source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final supported = ref.watch(
      ownTalkRoomExtrasProvider((
        accountId: accountId,
        roomToken: token,
      )).select(
        (s) =>
            s.capability?.supportsFeature(RoomMessageTool.checklist.feature) ==
            true,
      ),
    );
    if (!supported) return fallback;
    return TextButton.icon(
      icon: const Icon(Icons.checklist_rounded),
      label: Text(lines.first),
      onPressed: () => showDialog<void>(
        context: context,
        builder: (_) => _ChecklistDialog(
          accountId: accountId,
          token: token,
          id: id,
          lines: lines,
          expectedRevision: sha256.convert(utf8.encode(source)).toString(),
        ),
      ),
    );
  }
}

class _ChecklistDialog extends ConsumerStatefulWidget {
  const _ChecklistDialog({
    required this.accountId,
    required this.token,
    required this.id,
    required this.lines,
    required this.expectedRevision,
  });
  final String accountId, token, expectedRevision;
  final int id;
  final List<String> lines;
  @override
  ConsumerState<_ChecklistDialog> createState() => _ChecklistDialogState();
}

class _ChecklistDialogState extends ConsumerState<_ChecklistDialog>
    with WidgetsBindingObserver {
  Set<int> _checked = {};
  String? _revision;
  bool _canEdit = false, _busy = false, _error = false;
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_update());
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!_error &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        unawaited(_update());
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_update());
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _update({int? item, bool? checked}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final values = await ref
          .read(ownTalkExtensionsServiceProvider)
          .roomMessageTool(
            accountId: widget.accountId,
            roomToken: widget.token,
            messageId: widget.id,
            tool: RoomMessageTool.checklist,
            method: item == null ? 'GET' : 'PUT',
            values: item == null
                ? null
                : {'revision': _revision, 'item': item, 'checked': checked},
          );
      final revision = values['revision'],
          edit = values['canEdit'],
          checks = values['checked'];
      if (revision is! String ||
          revision != widget.expectedRevision ||
          edit is! bool ||
          checks is! List ||
          !checks.every(
            (i) => i is int && i >= 0 && i < widget.lines.length - 1,
          )) {
        throw const FormatException();
      }
      if (!mounted) return;
      setState(() {
        _revision = revision;
        _canEdit = edit;
        _checked = checks.cast<int>().toSet();
        _error = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = true;
          _canEdit = false;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(widget.lines.first),
      content: SizedBox(
        width: 380,
        child: ListView(
          shrinkWrap: true,
          children: [
            if (_busy && _revision == null) const LinearProgressIndicator(),
            if (_error) Text(strings.roomToolLoadFailure),
            for (var i = 1; i < widget.lines.length; i++)
              CheckboxListTile(
                value: _checked.contains(i - 1),
                title: Text(widget.lines[i]),
                controlAffinity: ListTileControlAffinity.leading,
                onChanged: _canEdit && !_busy
                    ? (value) => _update(item: i - 1, checked: value)
                    : null,
              ),
          ],
        ),
      ),
      actions: [
        IconButton(
          tooltip: MaterialLocalizations.of(
            context,
          ).refreshIndicatorSemanticLabel,
          icon: const Icon(Icons.refresh),
          onPressed: _busy ? null : _update,
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(MaterialLocalizations.of(context).closeButtonLabel),
        ),
      ],
    );
  }
}

Future<String?> composeSharedChecklist(BuildContext context) =>
    showDialog<String>(
      context: context,
      builder: (_) => const _ComposeChecklist(),
    );

class _ComposeChecklist extends StatefulWidget {
  const _ComposeChecklist();
  @override
  State<_ComposeChecklist> createState() => _ComposeChecklistState();
}

class _ComposeChecklistState extends State<_ComposeChecklist> {
  String title = '', rows = '';
  @override
  Widget build(BuildContext context) {
    final s = AppLocalizations.of(context);
    final items = rows
        .split('\n')
        .map((i) => i.trim())
        .where((i) => i.isNotEmpty);
    final source = ([
      checklistPrefix + title.trim(),
      ...items.map((i) => '- [ ] $i'),
    ]).join('\n');
    return AlertDialog(
      title: Text(s.sharedChecklist),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              autofocus: true,
              maxLength: 120,
              decoration: InputDecoration(labelText: s.sharedChecklistTitle),
              onChanged: (v) => setState(() => title = v),
            ),
            TextField(
              minLines: 3,
              maxLines: 8,
              decoration: InputDecoration(labelText: s.sharedChecklistItems),
              onChanged: (v) => setState(() => rows = v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(s.cancel),
        ),
        FilledButton(
          onPressed: checklistLines(source) == null
              ? null
              : () => Navigator.pop(context, source),
          child: Text(s.sharedChecklistInsert),
        ),
      ],
    );
  }
}
