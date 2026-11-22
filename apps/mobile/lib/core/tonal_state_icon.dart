import 'package:flutter/material.dart';

/// Icon on a tonal disc, the mark of an empty or failed full-screen state.
final class TonalStateIcon extends StatelessWidget {
  const TonalStateIcon({super.key, required this.icon, this.error = false});

  final IconData icon;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: error ? scheme.errorContainer : scheme.primaryContainer,
      ),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Icon(
          icon,
          size: 40,
          color: error ? scheme.onErrorContainer : scheme.onPrimaryContainer,
        ),
      ),
    );
  }
}
