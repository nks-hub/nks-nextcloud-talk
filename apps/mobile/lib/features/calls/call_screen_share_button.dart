import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../l10n/generated/app_localizations.dart';
import 'call_join_controller.dart';
import 'call_media_engine.dart';
import 'call_screen_source_picker.dart';
import 'call_transport_service.dart';

final class CallScreenShareButton extends ConsumerStatefulWidget {
  const CallScreenShareButton({
    super.key,
    required this.roomKey,
    required this.join,
    required this.color,
    required this.buttonKey,
  });

  final CallRoomKey roomKey;
  final CallJoinState join;
  final Color color;
  final Key buttonKey;

  @override
  ConsumerState<CallScreenShareButton> createState() =>
      _CallScreenShareButtonState();
}

final class _CallScreenShareButtonState
    extends ConsumerState<CallScreenShareButton> {
  bool _busy = false;
  bool _choosingSource = false;

  Future<void> _toggle() async {
    if (_busy) return;
    setState(() => _busy = true);
    final roomKey = widget.roomKey;
    final controller = ref.read(callJoinControllerProvider(roomKey).notifier);
    final engine = ref.read(callMediaEngineProvider);
    try {
      final error = await controller.setScreenSharing(
        !widget.join.media.screenSharing,
        chooseSource: () async {
          if (!mounted) return null;
          setState(() => _choosingSource = true);
          try {
            return await showDialog<CallScreenSource>(
              context: context,
              builder: (dialogContext) => Consumer(
                builder: (context, dialogRef, _) {
                  dialogRef.listen(callJoinControllerProvider(roomKey), (
                    _,
                    next,
                  ) {
                    if (next.phase != CallJoinPhase.joined &&
                        dialogContext.mounted &&
                        (ModalRoute.of(dialogContext)?.isCurrent ?? false)) {
                      Navigator.pop(dialogContext);
                    }
                  });
                  return CallScreenSourcePicker(
                    loadSources: engine.screenSources,
                  );
                },
              ),
            );
          } finally {
            if (mounted) setState(() => _choosingSource = false);
          }
        },
      );
      if (error != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context).conversationActionErrorGeneric,
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return IconButton(
      key: widget.buttonKey,
      tooltip: widget.join.media.screenSharing
          ? strings.callBannerStopSharing
          : strings.callBannerShareScreen,
      color: widget.color,
      isSelected: widget.join.media.screenSharing,
      onPressed: widget.join.isBusy || _busy ? null : _toggle,
      icon: _busy && !_choosingSource
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.screen_share_outlined),
      selectedIcon: const Icon(Icons.stop_screen_share_rounded),
    );
  }
}
