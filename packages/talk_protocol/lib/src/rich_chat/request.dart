import '../chat/identifiers.dart';
import '../identifiers.dart';
import '../json_value.dart';
import '../protocol_exception.dart';
import '../server_base.dart';
import 'identifiers.dart';
import 'profile.dart';

const String richChatContractUserAgent =
    'com.nkshub.nextcloudtalk rich-chat-contract/0.1';
const String _chatPath = '/ocs/v2.php/apps/spreed/api/v1/chat';
const String _reactionPath = '/ocs/v2.php/apps/spreed/api/v1/reaction';

enum RichChatHttpMethod { get, post, put, delete }

enum RichChatOperation {
  getMentionSuggestions,
  getRecentThreads,
  getSubscribedThreads,
  getThread,
  renameThread,
  setThreadNotificationLevel,
  getMessageReactions,
  addMessageReaction,
  deleteMessageReaction,
  editChatMessage,
  deleteChatMessage,
  pinChatMessage,
  unpinChatMessage,
  hidePinnedChatMessage,
  getChatReminder,
  setChatReminder,
  deleteChatReminder,
  getScheduledChatMessages,
  scheduleChatMessage,
  editScheduledChatMessage,
  deleteScheduledChatMessage,
}

extension RichChatOperationPolicy on RichChatOperation {
  String get operationId => name;

  bool get isMutation => switch (this) {
    RichChatOperation.renameThread ||
    RichChatOperation.setThreadNotificationLevel ||
    RichChatOperation.addMessageReaction ||
    RichChatOperation.deleteMessageReaction ||
    RichChatOperation.editChatMessage ||
    RichChatOperation.deleteChatMessage ||
    RichChatOperation.pinChatMessage ||
    RichChatOperation.unpinChatMessage ||
    RichChatOperation.hidePinnedChatMessage ||
    RichChatOperation.setChatReminder ||
    RichChatOperation.deleteChatReminder ||
    RichChatOperation.scheduleChatMessage ||
    RichChatOperation.editScheduledChatMessage ||
    RichChatOperation.deleteScheduledChatMessage => true,
    _ => false,
  };
}

/// Immutable, account-bound request for the rich-chat API slice.
final class RichChatRequest {
  RichChatRequest._({
    required this.accountId,
    required this.requestId,
    required this.server,
    required this.profile,
    required this.operation,
    required this.method,
    required this.requestPath,
    required Map<String, String> queryParameters,
    required Map<String, Object?>? formBody,
    required this.roomToken,
    required this.messageId,
    required this.threadId,
    required this.scheduleId,
    required this.actor,
    required String userAgent,
  }) : queryParameters = RedactedMapView(queryParameters),
       formBody = formBody == null ? null : RedactedMapView(formBody),
       headers = RedactedMapView(<String, String>{
         'OCS-APIRequest': 'true',
         'User-Agent': userAgent,
       }) {
    if (userAgent.isEmpty ||
        userAgent.length > 256 ||
        userAgent.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      _requestFailure(r'$.headers.User-Agent');
    }
  }

  factory RichChatRequest.mentions({
    required AccountId accountId,
    required ChatRequestId requestId,
    required ServerBase server,
    required ConversationToken roomToken,
    required RichChatCapabilityProfile profile,
    required String search,
    required int limit,
    required bool includeStatus,
    String userAgent = richChatContractUserAgent,
  }) {
    _requireCapability(profile.mentions, r'$.capabilities.mentions');
    if (search.length > 4096) {
      _requestFailure(r'$.query.search');
    }
    _requireRange(limit, 1, 100, r'$.query.limit');
    return RichChatRequest._wire(
      accountId: accountId,
      requestId: requestId,
      server: server,
      profile: profile,
      operation: RichChatOperation.getMentionSuggestions,
      method: RichChatHttpMethod.get,
      path: '$_chatPath/${roomToken.value}/mentions',
      query: <String, String>{
        'search': search,
        'limit': '$limit',
        'includeStatus': includeStatus ? '1' : '0',
      },
      roomToken: roomToken,
      userAgent: userAgent,
    );
  }

  factory RichChatRequest.recentThreads({
    required AccountId accountId,
    required ChatRequestId requestId,
    required ServerBase server,
    required ConversationToken roomToken,
    required RichChatCapabilityProfile profile,
    required int limit,
    String userAgent = richChatContractUserAgent,
  }) {
    _requireCapability(profile.threadMetadata, r'$.capabilities.threads');
    _requireRange(limit, 1, 50, r'$.query.limit');
    return RichChatRequest._wire(
      accountId: accountId,
      requestId: requestId,
      server: server,
      profile: profile,
      operation: RichChatOperation.getRecentThreads,
      method: RichChatHttpMethod.get,
      path: '$_chatPath/${roomToken.value}/threads/recent',
      query: <String, String>{'limit': '$limit'},
      roomToken: roomToken,
      userAgent: userAgent,
    );
  }

  factory RichChatRequest.subscribedThreads({
    required AccountId accountId,
    required ChatRequestId requestId,
    required ServerBase server,
    required RichChatCapabilityProfile profile,
    required int limit,
    required int offset,
    String userAgent = richChatContractUserAgent,
  }) {
    _requireCapability(profile.threadMetadata, r'$.capabilities.threads');
    _requireRange(limit, 1, 100, r'$.query.limit');
    if (offset < 0) {
      _requestFailure(r'$.query.offset');
    }
    return RichChatRequest._wire(
      accountId: accountId,
      requestId: requestId,
      server: server,
      profile: profile,
      operation: RichChatOperation.getSubscribedThreads,
      method: RichChatHttpMethod.get,
      path: '$_chatPath/subscribed-threads',
      query: <String, String>{'limit': '$limit', 'offset': '$offset'},
      userAgent: userAgent,
    );
  }

  factory RichChatRequest.getThread({
    required AccountId accountId,
    required ChatRequestId requestId,
    required ServerBase server,
    required ConversationToken roomToken,
    required RichChatCapabilityProfile profile,
    required int threadId,
    String userAgent = richChatContractUserAgent,
  }) {
    _requireCapability(
      profile.threadMessageFetch,
      r'$.capabilities.threadMessageFetch',
    );
    _requirePositive(threadId, r'$.threadId');
    return RichChatRequest._wire(
      accountId: accountId,
      requestId: requestId,
      server: server,
      profile: profile,
      operation: RichChatOperation.getThread,
      method: RichChatHttpMethod.get,
      path: '$_chatPath/${roomToken.value}/threads/$threadId',
      roomToken: roomToken,
      threadId: threadId,
      userAgent: userAgent,
    );
  }

  factory RichChatRequest.renameThread({
    required AccountId accountId,
    required ChatRequestId requestId,
    required ServerBase server,
    required ConversationToken roomToken,
    required RichChatCapabilityProfile profile,
    required int threadId,
    required String threadTitle,
    String userAgent = richChatContractUserAgent,
  }) {
    _requireCapability(profile.threadMetadata, r'$.capabilities.threads');
    _requirePositive(threadId, r'$.threadId');
    _requireText(threadTitle, r'$.body.threadTitle', maximum: 4096);
    return RichChatRequest._wire(
      accountId: accountId,
      requestId: requestId,
      server: server,
      profile: profile,
      operation: RichChatOperation.renameThread,
      method: RichChatHttpMethod.put,
      path: '$_chatPath/${roomToken.value}/threads/$threadId',
      body: <String, Object?>{'threadTitle': threadTitle},
      roomToken: roomToken,
      threadId: threadId,
      userAgent: userAgent,
    );
  }

  factory RichChatRequest.setThreadNotificationLevel({
    required AccountId accountId,
    required ChatRequestId requestId,
    required ServerBase server,
    required ConversationToken roomToken,
    required RichChatCapabilityProfile profile,
    required int messageId,
    required int level,
    String userAgent = richChatContractUserAgent,
  }) {
    _requireCapability(profile.threadMetadata, r'$.capabilities.threads');
    _requirePositive(messageId, r'$.messageId');
    _requireRange(level, 0, 3, r'$.body.level');
    return RichChatRequest._wire(
      accountId: accountId,
      requestId: requestId,
      server: server,
      profile: profile,
      operation: RichChatOperation.setThreadNotificationLevel,
      method: RichChatHttpMethod.post,
      path: '$_chatPath/${roomToken.value}/threads/$messageId/notify',
      body: <String, Object?>{'level': level},
      roomToken: roomToken,
      messageId: messageId,
      userAgent: userAgent,
    );
  }

  factory RichChatRequest.getReactions({
    required AccountId accountId,
    required ChatRequestId requestId,
    required ServerBase server,
    required ConversationToken roomToken,
    required RichChatCapabilityProfile profile,
    required int messageId,
    required String reaction,
    required RichChatActorIdentity actor,
    String userAgent = richChatContractUserAgent,
  }) => RichChatRequest._reaction(
    accountId: accountId,
    requestId: requestId,
    server: server,
    roomToken: roomToken,
    profile: profile,
    messageId: messageId,
    reaction: reaction,
    actor: actor,
    operation: RichChatOperation.getMessageReactions,
    method: RichChatHttpMethod.get,
    requireSendPermission: false,
    userAgent: userAgent,
  );

  factory RichChatRequest.addReaction({
    required AccountId accountId,
    required ChatRequestId requestId,
    required ServerBase server,
    required ConversationToken roomToken,
    required RichChatCapabilityProfile profile,
    required int messageId,
    required String reaction,
    required RichChatActorIdentity actor,
    String userAgent = richChatContractUserAgent,
  }) => RichChatRequest._reaction(
    accountId: accountId,
    requestId: requestId,
    server: server,
    roomToken: roomToken,
    profile: profile,
    messageId: messageId,
    reaction: reaction,
    actor: actor,
    operation: RichChatOperation.addMessageReaction,
    method: RichChatHttpMethod.post,
    requireSendPermission: true,
    userAgent: userAgent,
  );

  factory RichChatRequest.deleteReaction({
    required AccountId accountId,
    required ChatRequestId requestId,
    required ServerBase server,
    required ConversationToken roomToken,
    required RichChatCapabilityProfile profile,
    required int messageId,
    required String reaction,
    required RichChatActorIdentity actor,
    String userAgent = richChatContractUserAgent,
  }) => RichChatRequest._reaction(
    accountId: accountId,
    requestId: requestId,
    server: server,
    roomToken: roomToken,
    profile: profile,
    messageId: messageId,
    reaction: reaction,
    actor: actor,
    operation: RichChatOperation.deleteMessageReaction,
    method: RichChatHttpMethod.delete,
    requireSendPermission: false,
    userAgent: userAgent,
  );

  factory RichChatRequest.editMessage({
    required AccountId accountId,
    required ChatRequestId requestId,
    required ServerBase server,
    required ConversationToken roomToken,
    required RichChatCapabilityProfile profile,
    required int messageId,
    required String message,
    String userAgent = richChatContractUserAgent,
  }) {
    _requireCapability(profile.edit, r'$.capabilities.edit-messages');
    _requirePositive(messageId, r'$.messageId');
    _requireText(message, r'$.body.message');
    return RichChatRequest._messageMutation(
      accountId: accountId,
      requestId: requestId,
      server: server,
      roomToken: roomToken,
      profile: profile,
      messageId: messageId,
      operation: RichChatOperation.editChatMessage,
      method: RichChatHttpMethod.put,
      body: <String, Object?>{'message': message},
      userAgent: userAgent,
    );
  }

  factory RichChatRequest.deleteMessage({
    required AccountId accountId,
    required ChatRequestId requestId,
    required ServerBase server,
    required ConversationToken roomToken,
    required RichChatCapabilityProfile profile,
    required int messageId,
    String userAgent = richChatContractUserAgent,
  }) {
    _requireCapability(profile.delete, r'$.capabilities.delete-messages');
    _requirePositive(messageId, r'$.messageId');
    return RichChatRequest._messageMutation(
      accountId: accountId,
      requestId: requestId,
      server: server,
      roomToken: roomToken,
      profile: profile,
      messageId: messageId,
      operation: RichChatOperation.deleteChatMessage,
      method: RichChatHttpMethod.delete,
      userAgent: userAgent,
    );
  }

  /// `POST /ocs/v2.php/apps/spreed/api/v1/chat/{token}/{messageId}/pin`.
  ///
  /// Evidence: spreed `f2958bb` `lib/Controller/ChatController.php:2158-2208`
  /// (`#[ApiRoute]` at :2177, `pinMessage()` at :2182), exposed as
  /// `openapi-full.json` operation `chat-pin-message`. Not covered by
  /// `docs/chat.md`, which has no pin section in `f2958bb` or in upstream
  /// `main`; the OpenAPI document is generated from the same controller
  /// PHPDoc that declares the route, and both official clients ship against
  /// it - Talk Android `ApiUtils.kt` `getUrlForChatMessagePinning`, Talk iOS
  /// `NCAPIController.swift` `pinMessage`.
  ///
  /// `pinUntil` is optional server-side with default `0`, meaning "pinned
  /// until someone unpins it"; a non-zero value must be in the future or the
  /// server answers `400 {"error": "until"}`. The route carries
  /// `#[RequireModeratorParticipant]`, which is why [profile] must report
  /// [RichChatCapabilityProfile.pin] - capability `pinned-messages`
  /// (`docs/capabilities.md:206`) *and* moderator.
  ///
  /// The `200` body is the system message about the pinning, carrying the
  /// pinned message itself as its parent.
  factory RichChatRequest.pinMessage({
    required AccountId accountId,
    required ChatRequestId requestId,
    required ServerBase server,
    required ConversationToken roomToken,
    required RichChatCapabilityProfile profile,
    required int messageId,
    required int pinUntil,
    required int now,
    String userAgent = richChatContractUserAgent,
  }) {
    _requireCapability(profile.pin, r'$.capabilities.pin');
    _requirePositive(messageId, r'$.messageId');
    if (pinUntil < 0 || now < 0 || (pinUntil != 0 && pinUntil <= now)) {
      _requestFailure(r'$.body.pinUntil');
    }
    return RichChatRequest._messageMutation(
      accountId: accountId,
      requestId: requestId,
      server: server,
      roomToken: roomToken,
      profile: profile,
      messageId: messageId,
      operation: RichChatOperation.pinChatMessage,
      method: RichChatHttpMethod.post,
      pathSuffix: '/pin',
      body: <String, Object?>{'pinUntil': pinUntil},
      userAgent: userAgent,
    );
  }

  /// `DELETE /ocs/v2.php/apps/spreed/api/v1/chat/{token}/{messageId}/pin`.
  ///
  /// Evidence: spreed `f2958bb` `lib/Controller/ChatController.php:2210-2249`
  /// (`#[ApiRoute]` at :2227, `unpinMessage()` at :2232), OpenAPI operation
  /// `chat-unpin-message`. Moderator-only like the pin itself, and the `200`
  /// body has the same system-message-with-parent shape.
  factory RichChatRequest.unpinMessage({
    required AccountId accountId,
    required ChatRequestId requestId,
    required ServerBase server,
    required ConversationToken roomToken,
    required RichChatCapabilityProfile profile,
    required int messageId,
    String userAgent = richChatContractUserAgent,
  }) {
    _requireCapability(profile.pin, r'$.capabilities.pin');
    _requirePositive(messageId, r'$.messageId');
    return RichChatRequest._messageMutation(
      accountId: accountId,
      requestId: requestId,
      server: server,
      roomToken: roomToken,
      profile: profile,
      messageId: messageId,
      operation: RichChatOperation.unpinChatMessage,
      method: RichChatHttpMethod.delete,
      pathSuffix: '/pin',
      userAgent: userAgent,
    );
  }

  /// `DELETE /ocs/v2.php/apps/spreed/api/v1/chat/{token}/{messageId}/pin/self`.
  ///
  /// Evidence: spreed `f2958bb` `lib/Controller/ChatController.php:2251-2275`
  /// (`#[ApiRoute]` at :2267, `hidePinnedMessage()` at :2272), OpenAPI
  /// operation `chat-hide-pinned-message`.
  ///
  /// This one is `#[RequireParticipant]`, not moderator, because it only
  /// records the hide against the calling attendee - hence the weaker
  /// [RichChatCapabilityProfile.hidePinned] gate. It answers with
  /// `data: null`. The hidden ID surfaces as the room's `hiddenPinnedId`, and
  /// a later pin resets it (`lib/Service/RoomService.php:1007-1020` calls
  /// `resetHiddenPinnedId`), so a fresh pin reappears for everyone.
  factory RichChatRequest.hidePinnedMessage({
    required AccountId accountId,
    required ChatRequestId requestId,
    required ServerBase server,
    required ConversationToken roomToken,
    required RichChatCapabilityProfile profile,
    required int messageId,
    String userAgent = richChatContractUserAgent,
  }) {
    _requireCapability(profile.hidePinned, r'$.capabilities.pinned-messages');
    _requirePositive(messageId, r'$.messageId');
    return RichChatRequest._messageMutation(
      accountId: accountId,
      requestId: requestId,
      server: server,
      roomToken: roomToken,
      profile: profile,
      messageId: messageId,
      operation: RichChatOperation.hidePinnedChatMessage,
      method: RichChatHttpMethod.delete,
      pathSuffix: '/pin/self',
      userAgent: userAgent,
    );
  }

  /// `GET /ocs/v2.php/apps/spreed/api/v1/chat/{token}/{messageId}/reminder`.
  ///
  /// Evidence: spreed `f2958bb` `docs/chat.md:382-405` ("Get a reminder"),
  /// `lib/Controller/ChatController.php:1656`, OpenAPI operation
  /// `chat-get-reminder`. `404` is documented as covering "the user has no
  /// reminder for this message", so it is a state, not a transport failure.
  factory RichChatRequest.getReminder({
    required AccountId accountId,
    required ChatRequestId requestId,
    required ServerBase server,
    required ConversationToken roomToken,
    required RichChatCapabilityProfile profile,
    required int messageId,
    String userAgent = richChatContractUserAgent,
  }) => RichChatRequest._reminder(
    accountId: accountId,
    requestId: requestId,
    server: server,
    roomToken: roomToken,
    profile: profile,
    messageId: messageId,
    operation: RichChatOperation.getChatReminder,
    method: RichChatHttpMethod.get,
    userAgent: userAgent,
  );

  /// `POST /ocs/v2.php/apps/spreed/api/v1/chat/{token}/{messageId}/reminder`.
  ///
  /// Evidence: spreed `f2958bb` `docs/chat.md:353-380` ("Set a reminder"),
  /// `lib/Controller/ChatController.php:1617`, OpenAPI operation
  /// `chat-set-reminder`. `timestamp` is the required Unix timestamp at which
  /// the reminder fires; success is `201`, not `200`. Capability
  /// `remind-me-later` (`docs/capabilities.md:126`).
  factory RichChatRequest.setReminder({
    required AccountId accountId,
    required ChatRequestId requestId,
    required ServerBase server,
    required ConversationToken roomToken,
    required RichChatCapabilityProfile profile,
    required int messageId,
    required int timestamp,
    String userAgent = richChatContractUserAgent,
  }) {
    if (timestamp < 1) {
      _requestFailure(r'$.body.timestamp');
    }
    return RichChatRequest._reminder(
      accountId: accountId,
      requestId: requestId,
      server: server,
      roomToken: roomToken,
      profile: profile,
      messageId: messageId,
      operation: RichChatOperation.setChatReminder,
      method: RichChatHttpMethod.post,
      body: <String, Object?>{'timestamp': timestamp},
      userAgent: userAgent,
    );
  }

  /// `DELETE /ocs/v2.php/apps/spreed/api/v1/chat/{token}/{messageId}/reminder`.
  ///
  /// Evidence: spreed `f2958bb` `docs/chat.md:407-420` ("Delete a reminder"),
  /// `lib/Controller/ChatController.php:1695`, OpenAPI operation
  /// `chat-delete-reminder`. Answers `200` with an empty payload.
  factory RichChatRequest.deleteReminder({
    required AccountId accountId,
    required ChatRequestId requestId,
    required ServerBase server,
    required ConversationToken roomToken,
    required RichChatCapabilityProfile profile,
    required int messageId,
    String userAgent = richChatContractUserAgent,
  }) => RichChatRequest._reminder(
    accountId: accountId,
    requestId: requestId,
    server: server,
    roomToken: roomToken,
    profile: profile,
    messageId: messageId,
    operation: RichChatOperation.deleteChatReminder,
    method: RichChatHttpMethod.delete,
    userAgent: userAgent,
  );

  /// `GET /ocs/v2.php/apps/spreed/api/v1/chat/{token}/schedule`.
  ///
  /// Evidence: spreed `f2958bb` `lib/Controller/ChatController.php:466-497`
  /// (capability line at :466-471, `#[ApiRoute]` at :482,
  /// `getScheduledMessages()` at :486), OpenAPI operation
  /// `chat-get-scheduled-messages`; Talk Android `ApiUtils.kt`
  /// `getUrlForScheduledMessages`. Not covered by `docs/chat.md`, which has
  /// no schedule section.
  ///
  /// The result is scoped to this room *and* this participant, so it is also
  /// the way to settle an ambiguous [createScheduled].
  factory RichChatRequest.getScheduled({
    required AccountId accountId,
    required ChatRequestId requestId,
    required ServerBase server,
    required ConversationToken roomToken,
    required RichChatCapabilityProfile profile,
    String userAgent = richChatContractUserAgent,
  }) {
    _requireCapability(profile.scheduled, r'$.capabilities.scheduled-messages');
    return RichChatRequest._wire(
      accountId: accountId,
      requestId: requestId,
      server: server,
      profile: profile,
      operation: RichChatOperation.getScheduledChatMessages,
      method: RichChatHttpMethod.get,
      path: '$_chatPath/${roomToken.value}/schedule',
      roomToken: roomToken,
      userAgent: userAgent,
    );
  }

  /// `POST /ocs/v2.php/apps/spreed/api/v1/chat/{token}/schedule`.
  ///
  /// Evidence: spreed `f2958bb` `lib/Controller/ChatController.php:500-596`
  /// (capability line at :506, `#[ApiRoute]` at :528, `scheduleMessage()` at
  /// :532), OpenAPI operation `chat-schedule-message`; Talk Android
  /// `NcApiCoroutines.kt` `sendScheduleChatMessage` sends exactly `message`,
  /// `sendAt`, `silent`, `threadTitle`, `threadId` and `replyTo`.
  ///
  /// `message` and `sendAt` are required; `threadTitle` and `threadId` need
  /// the `threads` capability. Success is `201`. The capability is
  /// `scheduled-messages` and is announced only under `features-local`
  /// (`docs/capabilities.md:209`), so a federated conversation must never
  /// offer it - which is what [RichChatCapabilityProfile.scheduled] encodes.
  ///
  /// `replyTo` is deliberately not exposed here: scheduling a reply needs the
  /// same cross-room and thread admission rules as an immediate reply, and
  /// those live in the chat send contract, not this one.
  factory RichChatRequest.createScheduled({
    required AccountId accountId,
    required ChatRequestId requestId,
    required ServerBase server,
    required ConversationToken roomToken,
    required RichChatCapabilityProfile profile,
    required String message,
    required int sendAt,
    required bool silent,
    required int threadId,
    required String threadTitle,
    required int now,
    String userAgent = richChatContractUserAgent,
  }) {
    _requireScheduledInput(
      profile: profile,
      message: message,
      sendAt: sendAt,
      threadTitle: threadTitle,
      now: now,
    );
    if (threadId < 0 ||
        ((threadId > 0 || threadTitle.isNotEmpty) && !profile.threadMetadata)) {
      _requestFailure(r'$.body.threadId');
    }
    return RichChatRequest._wire(
      accountId: accountId,
      requestId: requestId,
      server: server,
      profile: profile,
      operation: RichChatOperation.scheduleChatMessage,
      method: RichChatHttpMethod.post,
      path: '$_chatPath/${roomToken.value}/schedule',
      body: <String, Object?>{
        'message': message,
        'sendAt': sendAt,
        'silent': silent,
        'threadTitle': threadTitle,
        'threadId': threadId,
      },
      roomToken: roomToken,
      userAgent: userAgent,
    );
  }

  /// `POST /ocs/v2.php/apps/spreed/api/v1/chat/{token}/schedule/{messageId}`.
  ///
  /// Evidence: spreed `f2958bb` `lib/Controller/ChatController.php:601-679`
  /// (capability line at :603, `#[ApiRoute]` at :622, `editScheduledMessage()`
  /// at :627, the `202` return at :679), OpenAPI operation
  /// `chat-edit-scheduled-message`.
  ///
  /// `POST`, not `PUT`, and success is `202`. Only `message`, `sendAt`,
  /// `silent` and `threadTitle` are editable - `replyTo` and `threadId` are
  /// not. The schedule identifier is a Snowflake **string**, unlike the
  /// integer `messageId` used everywhere else in the chat API.
  factory RichChatRequest.editScheduled({
    required AccountId accountId,
    required ChatRequestId requestId,
    required ServerBase server,
    required ConversationToken roomToken,
    required RichChatCapabilityProfile profile,
    required RichChatScheduleId scheduleId,
    required String message,
    required int sendAt,
    required bool silent,
    required String threadTitle,
    required int now,
    String userAgent = richChatContractUserAgent,
  }) {
    _requireScheduledInput(
      profile: profile,
      message: message,
      sendAt: sendAt,
      threadTitle: threadTitle,
      now: now,
    );
    return RichChatRequest._wire(
      accountId: accountId,
      requestId: requestId,
      server: server,
      profile: profile,
      operation: RichChatOperation.editScheduledChatMessage,
      method: RichChatHttpMethod.post,
      path: '$_chatPath/${roomToken.value}/schedule/${scheduleId.value}',
      body: <String, Object?>{
        'message': message,
        'sendAt': sendAt,
        'silent': silent,
        'threadTitle': threadTitle,
      },
      roomToken: roomToken,
      scheduleId: scheduleId,
      userAgent: userAgent,
    );
  }

  /// `DELETE /ocs/v2.php/apps/spreed/api/v1/chat/{token}/schedule/{messageId}`.
  ///
  /// Evidence: spreed `f2958bb` `lib/Controller/ChatController.php:682-701`
  /// (PHP method `deleteScheduleMessage`), OpenAPI operation
  /// `chat-delete-schedule-message`; Talk Android `NcApiCoroutines.kt`
  /// `deleteScheduleMessage`. Answers `200` with an empty object.
  factory RichChatRequest.deleteScheduled({
    required AccountId accountId,
    required ChatRequestId requestId,
    required ServerBase server,
    required ConversationToken roomToken,
    required RichChatCapabilityProfile profile,
    required RichChatScheduleId scheduleId,
    String userAgent = richChatContractUserAgent,
  }) {
    _requireCapability(profile.scheduled, r'$.capabilities.scheduled-messages');
    return RichChatRequest._wire(
      accountId: accountId,
      requestId: requestId,
      server: server,
      profile: profile,
      operation: RichChatOperation.deleteScheduledChatMessage,
      method: RichChatHttpMethod.delete,
      path: '$_chatPath/${roomToken.value}/schedule/${scheduleId.value}',
      roomToken: roomToken,
      scheduleId: scheduleId,
      userAgent: userAgent,
    );
  }

  factory RichChatRequest._reaction({
    required AccountId accountId,
    required ChatRequestId requestId,
    required ServerBase server,
    required ConversationToken roomToken,
    required RichChatCapabilityProfile profile,
    required int messageId,
    required String reaction,
    required RichChatActorIdentity actor,
    required RichChatOperation operation,
    required RichChatHttpMethod method,
    required bool requireSendPermission,
    required String userAgent,
  }) {
    _requireCapability(
      requireSendPermission ? profile.canReact : profile.reactions,
      requireSendPermission
          ? r'$.capabilities.canReact'
          : r'$.capabilities.reactions',
    );
    _requirePositive(messageId, r'$.messageId');
    if (reaction.isEmpty || reaction.length > 32) {
      _requestFailure(r'$.reaction');
    }
    return RichChatRequest._wire(
      accountId: accountId,
      requestId: requestId,
      server: server,
      profile: profile,
      operation: operation,
      method: method,
      path: '$_reactionPath/${roomToken.value}/$messageId',
      query: method == RichChatHttpMethod.get
          ? <String, String>{'reaction': reaction}
          : null,
      body: method == RichChatHttpMethod.get
          ? null
          : <String, Object?>{'reaction': reaction},
      roomToken: roomToken,
      messageId: messageId,
      actor: actor,
      userAgent: userAgent,
    );
  }

  factory RichChatRequest._messageMutation({
    required AccountId accountId,
    required ChatRequestId requestId,
    required ServerBase server,
    required ConversationToken roomToken,
    required RichChatCapabilityProfile profile,
    required int messageId,
    required RichChatOperation operation,
    required RichChatHttpMethod method,
    String pathSuffix = '',
    Map<String, Object?>? body,
    required String userAgent,
  }) => RichChatRequest._wire(
    accountId: accountId,
    requestId: requestId,
    server: server,
    profile: profile,
    operation: operation,
    method: method,
    path: '$_chatPath/${roomToken.value}/$messageId$pathSuffix',
    body: body,
    roomToken: roomToken,
    messageId: messageId,
    userAgent: userAgent,
  );

  factory RichChatRequest._reminder({
    required AccountId accountId,
    required ChatRequestId requestId,
    required ServerBase server,
    required ConversationToken roomToken,
    required RichChatCapabilityProfile profile,
    required int messageId,
    required RichChatOperation operation,
    required RichChatHttpMethod method,
    Map<String, Object?>? body,
    required String userAgent,
  }) {
    _requireCapability(profile.reminders, r'$.capabilities.remind-me-later');
    _requirePositive(messageId, r'$.messageId');
    return RichChatRequest._wire(
      accountId: accountId,
      requestId: requestId,
      server: server,
      profile: profile,
      operation: operation,
      method: method,
      path: '$_chatPath/${roomToken.value}/$messageId/reminder',
      body: body,
      roomToken: roomToken,
      messageId: messageId,
      userAgent: userAgent,
    );
  }

  factory RichChatRequest._wire({
    required AccountId accountId,
    required ChatRequestId requestId,
    required ServerBase server,
    required RichChatCapabilityProfile profile,
    required RichChatOperation operation,
    required RichChatHttpMethod method,
    required String path,
    Map<String, String>? query,
    Map<String, Object?>? body,
    ConversationToken? roomToken,
    int? messageId,
    int? threadId,
    RichChatScheduleId? scheduleId,
    RichChatActorIdentity? actor,
    required String userAgent,
  }) => RichChatRequest._(
    accountId: accountId,
    requestId: requestId,
    server: server,
    profile: profile,
    operation: operation,
    method: method,
    requestPath: path,
    queryParameters: <String, String>{'format': 'json', ...?query},
    formBody: body,
    roomToken: roomToken,
    messageId: messageId,
    threadId: threadId,
    scheduleId: scheduleId,
    actor: actor,
    userAgent: userAgent,
  );

  final AccountId accountId;
  final ChatRequestId requestId;
  final ServerBase server;
  final RichChatCapabilityProfile profile;
  final RichChatOperation operation;
  final RichChatHttpMethod method;
  final String requestPath;
  final Map<String, String> queryParameters;
  final Map<String, String> headers;
  final Map<String, Object?>? formBody;
  final ConversationToken? roomToken;
  final int? messageId;
  final int? threadId;
  final RichChatScheduleId? scheduleId;
  final RichChatActorIdentity? actor;

  Uri get uri {
    final prefix = server.basePath.isEmpty ? '' : server.basePath;
    return server.uri.replace(
      path: '$prefix$requestPath',
      queryParameters: queryParameters,
    );
  }

  @override
  String toString() =>
      'RichChatRequest(operation: ${operation.operationId}, '
      'account: <redacted>, roomScoped: ${roomToken != null}, '
      'body: <redacted>, query: <redacted>)';
}

void _requireScheduledInput({
  required RichChatCapabilityProfile profile,
  required String message,
  required int sendAt,
  required String threadTitle,
  required int now,
}) {
  _requireCapability(profile.scheduled, r'$.capabilities.scheduled-messages');
  _requireText(message, r'$.body.message');
  if (now < 0 || sendAt < 1 || sendAt <= now) {
    _requestFailure(r'$.body.sendAt');
  }
  if (threadTitle.length > 4096) {
    _requestFailure(r'$.body.threadTitle');
  }
}

void _requireText(String value, String path, {int? maximum}) {
  if (value.trim().isEmpty || (maximum != null && value.length > maximum)) {
    _requestFailure(path);
  }
}

void _requirePositive(int value, String path) {
  if (value < 1) {
    _requestFailure(path);
  }
}

void _requireRange(int value, int minimum, int maximum, String path) {
  if (value < minimum || value > maximum) {
    _requestFailure(path);
  }
}

void _requireCapability(bool allowed, String path) {
  if (!allowed) {
    protocolFailure(TalkProtocolErrorCode.unsupportedChatOperation, path);
  }
}

Never _requestFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidRichChatRequest, path);
