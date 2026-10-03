import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';

typedef SubmitDesktopAttachment = Future<bool> Function(DropItem item);

enum DesktopAttachmentDropOutcome { accepted, invalidSelection, unavailable }

final class DesktopAttachmentDropController {
  final List<({Object owner, SubmitDesktopAttachment submit})> _bindings = [];

  bool get canAccept => _bindings.isNotEmpty;

  void bind(Object owner, SubmitDesktopAttachment submit) {
    _bindings.removeWhere((binding) => identical(binding.owner, owner));
    _bindings.add((owner: owner, submit: submit));
  }

  void unbind(Object owner) {
    _bindings.removeWhere((binding) => identical(binding.owner, owner));
  }

  Future<DesktopAttachmentDropOutcome> accept(List<DropItem> items) async {
    if (items.isEmpty || items.any((item) => item is DropItemDirectory)) {
      return DesktopAttachmentDropOutcome.invalidSelection;
    }
    if (_bindings.isEmpty) {
      return DesktopAttachmentDropOutcome.unavailable;
    }
    final binding = _bindings.last;
    for (final item in items) {
      if (_bindings.isEmpty ||
          !identical(_bindings.last.owner, binding.owner) ||
          !await binding.submit(item)) {
        return DesktopAttachmentDropOutcome.unavailable;
      }
    }
    return DesktopAttachmentDropOutcome.accepted;
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
  bool _dragging = false;
  int _preparingFiles = 0;

  @override
  Widget build(BuildContext context) {
    Widget child = widget.child;
    if (_supportsDesktopDrop(Theme.of(context).platform, kIsWeb)) {
      child = DropTarget(
        onDragEntered: (_) => _setDragging(true),
        onDragUpdated: (_) => _setDragging(true),
        onDragExited: (_) => _setDragging(false),
        onDragDone: (details) => unawaited(_accept(details.files)),
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            child,
            if (_dragging || _preparingFiles > 0)
              Positioned.fill(
                child: IgnorePointer(child: _dropPlaceholder(context)),
              ),
          ],
        ),
      );
    }
    return _DesktopAttachmentDropScope(controller: _controller, child: child);
  }

  void _setDragging(bool dragging) {
    final next = dragging && _controller.canAccept;
    if (mounted && _dragging != next) setState(() => _dragging = next);
  }

  Widget _dropPlaceholder(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final preparing = _preparingFiles > 0;
    return Semantics(
      liveRegion: true,
      child: Container(
        key: const Key('desktop-attachment-drop-placeholder'),
        margin: const EdgeInsets.all(8),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: scheme.surface.withValues(alpha: 0.94),
          border: Border.all(color: scheme.primary, width: 2),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (preparing)
                const SizedBox.square(
                  dimension: 32,
                  child: CircularProgressIndicator(),
                )
              else
                Icon(
                  Icons.file_upload_outlined,
                  size: 40,
                  color: scheme.primary,
                ),
              const SizedBox(height: 12),
              Text(
                preparing
                    ? strings.preparingAttachments(_preparingFiles)
                    : strings.dropAttachmentsHere,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _accept(List<DropItem> items) async {
    if (!mounted) return;
    final DesktopAttachmentDropOutcome outcome;
    setState(() {
      _dragging = false;
      _preparingFiles += items.length;
    });
    try {
      outcome = await _controller.accept(items);
    } on Object {
      _showFailure();
      return;
    } finally {
      if (mounted) setState(() => _preparingFiles -= items.length);
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
