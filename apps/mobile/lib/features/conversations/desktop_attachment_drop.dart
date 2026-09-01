import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';

typedef SubmitDesktopAttachment = Future<bool> Function(DropItem item);

enum DesktopAttachmentDropOutcome { accepted, invalidSelection, unavailable }

final class DesktopAttachmentDropController {
  final List<({Object owner, SubmitDesktopAttachment submit})> _bindings = [];

  void bind(Object owner, SubmitDesktopAttachment submit) {
    _bindings.removeWhere((binding) => identical(binding.owner, owner));
    _bindings.add((owner: owner, submit: submit));
  }

  void unbind(Object owner) {
    _bindings.removeWhere((binding) => identical(binding.owner, owner));
  }

  Future<DesktopAttachmentDropOutcome> accept(List<DropItem> items) async {
    if (items.length != 1 || items.single is DropItemDirectory) {
      return DesktopAttachmentDropOutcome.invalidSelection;
    }
    if (_bindings.isEmpty) {
      return DesktopAttachmentDropOutcome.unavailable;
    }
    final accepted = await _bindings.last.submit(items.single);
    return accepted
        ? DesktopAttachmentDropOutcome.accepted
        : DesktopAttachmentDropOutcome.unavailable;
  }
}

final class DesktopAttachmentDrop extends StatefulWidget {
  const DesktopAttachmentDrop({super.key, required this.child});

  final Widget child;

  static DesktopAttachmentDropController controllerOf(BuildContext context) =>
      _DesktopAttachmentDropScope.of(context).controller;

  static DesktopAttachmentDropController? maybeControllerOf(
    BuildContext context,
  ) => _DesktopAttachmentDropScope.maybeOf(context)?.controller;

  @override
  State<DesktopAttachmentDrop> createState() => _DesktopAttachmentDropState();
}

final class _DesktopAttachmentDropState extends State<DesktopAttachmentDrop> {
  final _controller = DesktopAttachmentDropController();

  @override
  Widget build(BuildContext context) {
    Widget child = widget.child;
    if (_supportsDesktopDrop(Theme.of(context).platform, kIsWeb)) {
      child = DropTarget(
        onDragDone: (details) => unawaited(_accept(details.files)),
        child: child,
      );
    }
    return _DesktopAttachmentDropScope(controller: _controller, child: child);
  }

  Future<void> _accept(List<DropItem> items) async {
    final DesktopAttachmentDropOutcome outcome;
    try {
      outcome = await _controller.accept(items);
    } on Object {
      _showFailure();
      return;
    }
    if (outcome != DesktopAttachmentDropOutcome.accepted) {
      _showFailure(
        invalidSelection:
            outcome == DesktopAttachmentDropOutcome.invalidSelection,
      );
    }
  }

  void _showFailure({bool invalidSelection = false}) {
    if (!mounted) {
      return;
    }
    final strings = AppLocalizations.of(context);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          invalidSelection
              ? strings.attachmentTypeUnsupported
              : strings.imageUploadFailed,
        ),
      ),
    );
  }
}

bool _supportsDesktopDrop(TargetPlatform platform, bool isWeb) =>
    !isWeb &&
    (platform == TargetPlatform.windows ||
        platform == TargetPlatform.macOS ||
        platform == TargetPlatform.linux);

final class _DesktopAttachmentDropScope extends InheritedWidget {
  const _DesktopAttachmentDropScope({
    required this.controller,
    required super.child,
  });

  final DesktopAttachmentDropController controller;

  static _DesktopAttachmentDropScope of(BuildContext context) {
    final scope = maybeOf(context);
    if (scope == null) {
      throw StateError('No desktop attachment drop scope in this context');
    }
    return scope;
  }

  static _DesktopAttachmentDropScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_DesktopAttachmentDropScope>();

  @override
  bool updateShouldNotify(_DesktopAttachmentDropScope oldWidget) =>
      !identical(controller, oldWidget.controller);
}
