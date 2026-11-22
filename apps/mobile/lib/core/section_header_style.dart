import 'package:flutter/material.dart';

/// Heading that groups rows, shared by the settings screen and the
/// conversation details so the two read as one family. Marked as a header for
/// screen readers.
final class SectionHeaderText extends StatelessWidget {
  const SectionHeaderText(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      header: true,
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: scheme.tertiary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
