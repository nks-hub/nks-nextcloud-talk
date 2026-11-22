import 'package:flutter/material.dart';

/// Style of a heading that groups rows, shared by the settings screen and the
/// conversation details so the two read as one family.
TextStyle? sectionHeaderStyle(BuildContext context) =>
    Theme.of(context).textTheme.titleSmall?.copyWith(
      color: Theme.of(context).colorScheme.tertiary,
      fontWeight: FontWeight.w600,
    );
