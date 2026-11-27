import 'package:flutter/material.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../../l10n/generated/app_localizations.dart';
import 'account_collection_store.dart';
import 'composer_text_editing.dart';

class AccountCollectionDialog<T> extends StatefulWidget {
  const AccountCollectionDialog({
    required this.account,
    required this.store,
    required this.title,
    required this.content,
    this.action,
    super.key,
  });

  final AccountId account;
  final AccountCollectionStore<T> store;
  final String title;
  final Widget Function(BuildContext, List<T>) content;
  final Widget? action;

  @override
  State<AccountCollectionDialog<T>> createState() =>
      _AccountCollectionDialogState<T>();
}

class _AccountCollectionDialogState<T>
    extends State<AccountCollectionDialog<T>> {
  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final content = ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) => FutureBuilder<List<T>>(
        future: widget.store.read(widget.account),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(strings.personalCollectionLoadError),
                    TextButton(
                      onPressed: () => setState(() {}),
                      child: Text(strings.retry),
                    ),
                  ],
                ),
              ),
            );
          }
          final entries = snapshot.data;
          return entries == null
              ? const Center(child: CircularProgressIndicator())
              : widget.content(context, entries);
        },
      ),
    );
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 480),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxHeight < 192;
            final header = Padding(
              padding: EdgeInsets.fromLTRB(20, compact ? 2 : 8, 4, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      maxLines: compact ? 2 : null,
                      overflow: compact ? TextOverflow.ellipsis : null,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  if (compact && widget.action != null)
                    Flexible(child: widget.action!),
                  IconButton(
                    tooltip: strings.close,
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            );
            return Column(
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: constraints.maxHeight / 2,
                  ),
                  child: SingleChildScrollView(child: header),
                ),
                Expanded(child: content),
                if (!compact && widget.action != null)
                  Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                      child: widget.action,
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

Future<({String name, String text})?> editAccountCollectionItem(
  BuildContext context, {
  required String title,
  required String nameLabel,
  String name = '',
  String? textLabel,
  String text = '',
}) => showDialog<({String name, String text})>(
  context: context,
  builder: (context) {
    final strings = AppLocalizations.of(context);
    return StatefulBuilder(
      builder: (context, update) {
        return AlertDialog(
          title: Text(title),
          scrollable: true,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                initialValue: name,
                autofocus: true,
                maxLength: 80,
                decoration: InputDecoration(labelText: nameLabel),
                onChanged: (value) => update(() => name = value),
              ),
              if (textLabel != null)
                TextFormField(
                  initialValue: text,
                  minLines: 2,
                  maxLines: 6,
                  maxLength: composerMaximumCharacters,
                  decoration: InputDecoration(labelText: textLabel),
                  onChanged: (value) => update(() => text = value),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(strings.cancel),
            ),
            FilledButton(
              onPressed:
                  name.trim().isEmpty ||
                      (textLabel != null && text.trim().isEmpty)
                  ? null
                  : () =>
                        Navigator.pop(context, (name: name.trim(), text: text)),
              child: Text(strings.editMessageSave),
            ),
          ],
        );
      },
    );
  },
);

Future<bool> saveAccountCollectionChange(
  BuildContext context,
  Future<void> Function() change,
) async {
  try {
    await change();
    return true;
  } on Object {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).personalCollectionError),
        ),
      );
    }
    return false;
  }
}
