import 'package:flutter/material.dart';

final class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 56});

  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'NKS Talk',
      image: true,
      child: ExcludeSemantics(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: scheme.primary,
            borderRadius: BorderRadius.circular(size * 0.31),
          ),
          child: Icon(
            Icons.forum_rounded,
            color: scheme.onPrimary,
            size: size * 0.52,
          ),
        ),
      ),
    );
  }
}
