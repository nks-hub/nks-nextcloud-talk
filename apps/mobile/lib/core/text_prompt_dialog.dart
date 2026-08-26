import 'package:flutter/material.dart';

/// Shows a modal single field text prompt and returns the confirmed raw text.
///
/// Returns `null` when the prompt is dismissed without confirmation.
///
/// The dialog owns its [TextEditingController] on purpose. [showDialog]
/// completes as soon as the route is popped, while the field stays mounted for
/// the exit transition and still reacts to focus changes. A caller that
/// disposes its own controller right after awaiting [showDialog] therefore
/// tears down a controller that the field is still using.
Future<String?> showTextPromptDialog({
  required BuildContext context,
  required String title,
  required String initialValue,
  required String fieldLabel,
  required String cancelLabel,
  required String confirmLabel,
  Key? dialogKey,
  Key? fieldKey,
  Key? confirmKey,
  int? maxLength,
  int? minLines,
  int maxLines = 1,
  String? emptyErrorText,
}) {
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => _TextPromptDialog(
      key: dialogKey,
      title: title,
      initialValue: initialValue,
      fieldLabel: fieldLabel,
      cancelLabel: cancelLabel,
      confirmLabel: confirmLabel,
      fieldKey: fieldKey,
      confirmKey: confirmKey,
      maxLength: maxLength,
      minLines: minLines,
      maxLines: maxLines,
      emptyErrorText: emptyErrorText,
    ),
  );
}

final class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({
    super.key,
    required this.title,
    required this.initialValue,
    required this.fieldLabel,
    required this.cancelLabel,
    required this.confirmLabel,
    required this.fieldKey,
    required this.confirmKey,
    required this.maxLength,
    required this.minLines,
    required this.maxLines,
    required this.emptyErrorText,
  });

  final String title;
  final String initialValue;
  final String fieldLabel;
  final String cancelLabel;
  final String confirmLabel;
  final Key? fieldKey;
  final Key? confirmKey;
  final int? maxLength;
  final int? minLines;
  final int maxLines;
  final String? emptyErrorText;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

final class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _confirm() {
    if (_formKey.currentState?.validate() ?? false) {
      Navigator.of(context).pop(_controller.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final emptyErrorText = widget.emptyErrorText;
    return AlertDialog(
      title: Text(widget.title),
      content: Form(
        key: _formKey,
        child: TextFormField(
          key: widget.fieldKey,
          controller: _controller,
          autofocus: true,
          maxLength: widget.maxLength,
          minLines: widget.minLines,
          maxLines: widget.maxLines,
          decoration: InputDecoration(labelText: widget.fieldLabel),
          validator: emptyErrorText == null
              ? null
              : (value) =>
                    value == null || value.trim().isEmpty ? emptyErrorText : null,
          onFieldSubmitted: (_) => _confirm(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.cancelLabel),
        ),
        FilledButton(
          key: widget.confirmKey,
          onPressed: _confirm,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
