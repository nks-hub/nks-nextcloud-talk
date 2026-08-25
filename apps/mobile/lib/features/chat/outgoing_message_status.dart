import 'package:talk_protocol/talk_protocol.dart';

import '../../data/app_database.dart';
import '../../data/chat_repository.dart';

enum OutgoingMessageDeliveryState { sending, failed, sent, read }

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
        .map((message) {
          final messageCursor = ChatCursor.parse(message.messageId.toString());
          final commonRead = projection.lastCommonRead;
          final state =
              commonRead != null && commonRead.compareTo(messageCursor) >= 0
              ? OutgoingMessageDeliveryState.read
              : OutgoingMessageDeliveryState.sent;
          return OutgoingMessageStatus(
            operation: operation,
            messageId: message.messageId,
            state: state,
            confirmationAmbiguous: false,
          );
        })
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
