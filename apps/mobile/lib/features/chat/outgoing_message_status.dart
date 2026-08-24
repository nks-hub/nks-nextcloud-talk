import 'package:flutter/material.dart';

import '../../data/app_database.dart';
import '../../data/chat_repository.dart';

enum OutgoingMessageDeliveryState { sending, failed, sent }

final class OutgoingMessageStatus {
  const OutgoingMessageStatus({
    required this.operation,
    required this.messageId,
    required this.state,
    required this.confirmationAmbiguous,
  });

  final StoredTextSendOperation operation;
  final int? messageId;
  final OutgoingMessageDeliveryState state;
  final bool confirmationAmbiguous;

  bool get isServerConfirmed => messageId != null;
}

List<OutgoingMessageStatus> resolveOutgoingMessageStatuses(
  StoredOutgoingTextMessage projection,
) {
  final operation = projection.operation;
  if (operation.outboxState == 'completed' &&
      projection.confirmedMessages.isNotEmpty) {
    return projection.confirmedMessages
        .map(
          (message) => OutgoingMessageStatus(
            operation: operation,
            messageId: message.messageId,
            state: OutgoingMessageDeliveryState.sent,
            confirmationAmbiguous: false,
          ),
        )
        .toList(growable: false);
  }

  final state = switch (operation.outboxState) {
    'retryable' || 'failed' => OutgoingMessageDeliveryState.failed,
    _ => OutgoingMessageDeliveryState.sending,
  };
  return <OutgoingMessageStatus>[
    OutgoingMessageStatus(
      operation: operation,
      messageId: null,
      state: state,
      confirmationAmbiguous: operation.outboxState == 'awaitingConfirmation',
    ),
  ];
}

final class OutgoingMessageStatusIndicator extends StatelessWidget {
  const OutgoingMessageStatusIndicator({
    super.key,
    required this.status,
    required this.label,
    this.iconSize = 16,
    this.style,
  });

  final OutgoingMessageStatus status;
  final String label;
  final double iconSize;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final icon = switch (status.state) {
      OutgoingMessageDeliveryState.sending => Icons.schedule_send_rounded,
      OutgoingMessageDeliveryState.failed => Icons.error_outline_rounded,
      OutgoingMessageDeliveryState.sent => Icons.done_rounded,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: iconSize),
        const SizedBox(width: 4),
        Flexible(child: Text(label, style: style)),
      ],
    );
  }
}
