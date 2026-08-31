import 'dart:collection';

import '../identifiers.dart';
import '../protocol_exception.dart';
import '../server_base.dart';
import 'identifiers.dart';
import 'profile.dart';

const String chatV1Path = '/ocs/v2.php/apps/spreed/api/v1/chat';
const String chatContractUserAgent =
    'com.nkshub.nextcloudtalk chat-messages-contract/0.1';

enum ChatFetchDirection { history, future }

enum ChatHttpMethod { get, post, delete }

enum SharedItemType {
  audio('audio'),
  deckCard('deckcard'),
  file('file'),
  location('location'),
  media('media'),
  other('other'),
  pinned('pinned'),
  poll('poll'),
  recording('recording'),
  voice('voice');

  const SharedItemType(this.wireName);

  final String wireName;

  static SharedItemType? fromWireName(String value) =>
      values.where((candidate) => candidate.wireName == value).firstOrNull;
}

sealed class ChatRequest {
  ChatRequest({
    required this.accountId,
    required this.requestId,
    required this.server,
    required this.roomToken,
    this.userAgent = chatContractUserAgent,
  }) {
    if (userAgent.isEmpty ||
        userAgent.length > 256 ||
        userAgent.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
      protocolFailure(
        TalkProtocolErrorCode.invalidChatRequest,
        r'$.headers.userAgent',
      );
    }
  }

  final AccountId accountId;
  final ChatRequestId requestId;
  final ServerBase server;
  final ConversationToken roomToken;
  final String userAgent;

  ChatHttpMethod get method;

  String get requestPath;

  Map<String, String> get queryParameters;

  Object? get formBody;

  Map<String, String> get headers =>
      UnmodifiableMapView({'OCS-APIRequest': 'true', 'User-Agent': userAgent});

  Uri get uri => server.uri.replace(
    path: '${server.basePath}$requestPath',
    queryParameters: queryParameters,
  );
}

final class ChatFetchRequest extends ChatRequest {
  ChatFetchRequest({
    required super.accountId,
    required super.requestId,
    required super.server,
    required super.roomToken,
    required this.profile,
    required this.direction,
    required this.cursor,
    required this.lastCommonRead,
    required this.limit,
    required this.includeLastKnown,
    required this.timeoutSeconds,
    required this.interactive,
    this.threadId,
    this.futureConverged = false,
    super.userAgent,
  }) {
    if (!profile.read) {
      _requestFailure(r'$.capabilities.chat-v2');
    }
    if (limit < 1 || limit > 200) {
      _requestFailure(r'$.query.limit');
    }
    if (direction == ChatFetchDirection.history && timeoutSeconds != 0) {
      _requestFailure(r'$.query.timeout');
    }
    if (direction == ChatFetchDirection.future &&
        timeoutSeconds != 0 &&
        timeoutSeconds != 30) {
      _requestFailure(r'$.query.timeout');
    }
    if (timeoutSeconds == 30 && !futureConverged) {
      _requestFailure(r'$.state.futureConverged');
    }
    if (direction == ChatFetchDirection.future && includeLastKnown) {
      _requestFailure(r'$.query.includeLastKnown');
    }
    if (!interactive && !profile.backgroundCatchUp) {
      _requestFailure(r'$.capabilities.chat-keep-notifications');
    }
    if (threadId != null && (threadId! < 1 || !profile.threadFetch)) {
      _requestFailure(r'$.query.threadId');
    }
  }

  final ChatCapabilityProfile profile;
  final ChatFetchDirection direction;
  final ChatCursor cursor;
  final ChatCursor lastCommonRead;
  final int limit;
  final bool includeLastKnown;
  final int timeoutSeconds;
  final bool interactive;
  final int? threadId;
  final bool futureConverged;

  @override
  Object? get formBody => null;

  @override
  ChatHttpMethod get method => ChatHttpMethod.get;

  @override
  Map<String, String> get queryParameters => UnmodifiableMapView({
    'format': 'json',
    'lookIntoFuture': direction == ChatFetchDirection.future ? '1' : '0',
    'limit': limit.toString(),
    'lastKnownMessageId': cursor.value,
    'lastCommonReadId': lastCommonRead.value,
    'timeout': timeoutSeconds.toString(),
    'setReadMarker': '0',
    'includeLastKnown': includeLastKnown ? '1' : '0',
    'noStatusUpdate': interactive ? '0' : '1',
    'markNotificationsAsRead': interactive ? '1' : '0',
    if (threadId != null) 'threadId': threadId.toString(),
  });

  @override
  String get requestPath => '$chatV1Path/${roomToken.value}';

  @override
  String toString() =>
      'ChatFetchRequest(direction: ${direction.name}, limit: $limit, '
      'timeoutSeconds: $timeoutSeconds, interactive: $interactive, '
      'threadScoped: ${threadId != null})';
}

final class SharedItemsOverviewRequest extends ChatRequest {
  SharedItemsOverviewRequest({
    required super.accountId,
    required super.requestId,
    required super.server,
    required super.roomToken,
    required bool sharedItemsAvailable,
    required this.limit,
    super.userAgent,
  }) {
    if (!sharedItemsAvailable) {
      _sharedItemsRequestFailure(r'$.capabilities.rich-object-list-media');
    }
    if (limit < 1 || limit > 20) {
      _sharedItemsRequestFailure(r'$.query.limit');
    }
  }

  final int limit;

  @override
  Object? get formBody => null;

  @override
  ChatHttpMethod get method => ChatHttpMethod.get;

  @override
  Map<String, String> get queryParameters =>
      UnmodifiableMapView({'format': 'json', 'limit': limit.toString()});

  @override
  String get requestPath => '$chatV1Path/${roomToken.value}/share/overview';

  @override
  String toString() => 'SharedItemsOverviewRequest(limit: $limit)';
}

final class SharedItemsPageRequest extends ChatRequest {
  SharedItemsPageRequest({
    required super.accountId,
    required super.requestId,
    required super.server,
    required super.roomToken,
    required bool sharedItemsAvailable,
    required this.type,
    required this.lastKnownMessageId,
    required this.limit,
    super.userAgent,
  }) {
    if (!sharedItemsAvailable) {
      _sharedItemsRequestFailure(r'$.capabilities.rich-object-list-media');
    }
    if (!RegExp(
      r'^(0|[1-9][0-9]{0,19})$',
    ).hasMatch(lastKnownMessageId.toString())) {
      _sharedItemsRequestFailure(r'$.query.lastKnownMessageId');
    }
    if (limit < 1 || limit > 200) {
      _sharedItemsRequestFailure(r'$.query.limit');
    }
  }

  final SharedItemType type;
  final int lastKnownMessageId;
  final int limit;

  @override
  Object? get formBody => null;

  @override
  ChatHttpMethod get method => ChatHttpMethod.get;

  @override
  Map<String, String> get queryParameters => UnmodifiableMapView({
    'format': 'json',
    'objectType': type.wireName,
    'lastKnownMessageId': lastKnownMessageId.toString(),
    'limit': limit.toString(),
  });

  @override
  String get requestPath => '$chatV1Path/${roomToken.value}/share';

  @override
  String toString() =>
      'SharedItemsPageRequest(type: ${type.name}, limit: $limit)';
}

final class ChatMarkUnreadRequest extends ChatRequest {
  ChatMarkUnreadRequest({
    required super.accountId,
    required super.requestId,
    required super.server,
    required super.roomToken,
    required ChatCapabilityProfile profile,
    super.userAgent,
  }) {
    if (!profile.markUnread) {
      _requestFailure(r'$.capabilities.chat-unread');
    }
  }

  @override
  Object? get formBody => null;

  @override
  ChatHttpMethod get method => ChatHttpMethod.delete;

  @override
  Map<String, String> get queryParameters =>
      UnmodifiableMapView({'format': 'json'});

  @override
  String get requestPath => '$chatV1Path/${roomToken.value}/read';

  @override
  String toString() => 'ChatMarkUnreadRequest()';
}

final class ChatSendRequest extends ChatRequest {
  factory ChatSendRequest({
    required AccountId accountId,
    required ChatRequestId requestId,
    required ServerBase server,
    required ConversationToken roomToken,
    required ChatOperationId operationId,
    required ChatCapabilityProfile profile,
    required String message,
    required ChatReferenceId referenceId,
    int? replyTo,
    int? threadId,
    ConversationToken? parentRoomToken,
    ConversationToken? replyToToken,
    bool silent = false,
    String userAgent = chatContractUserAgent,
  }) => ChatSendRequest._(
    accountId: accountId,
    requestId: requestId,
    server: server,
    roomToken: roomToken,
    operationId: operationId,
    profile: profile,
    message: message,
    referenceId: referenceId,
    replyTo: replyTo,
    threadId: threadId,
    parentRoomToken: parentRoomToken,
    replyToToken: replyToToken,
    silent: silent,
    userAgent: userAgent,
    restored: false,
  );

  /// Rebuilds a previously admitted durable request without re-admitting it.
  factory ChatSendRequest.restored({
    required AccountId accountId,
    required ChatRequestId requestId,
    required ServerBase server,
    required ConversationToken roomToken,
    required ChatOperationId operationId,
    required ChatCapabilityProfile profile,
    required String message,
    required ChatReferenceId referenceId,
    int? replyTo,
    int? threadId,
    ConversationToken? parentRoomToken,
    ConversationToken? replyToToken,
    bool silent = false,
    String userAgent = chatContractUserAgent,
  }) => ChatSendRequest._(
    accountId: accountId,
    requestId: requestId,
    server: server,
    roomToken: roomToken,
    operationId: operationId,
    profile: profile,
    message: message,
    referenceId: referenceId,
    replyTo: replyTo,
    threadId: threadId,
    parentRoomToken: parentRoomToken,
    replyToToken: replyToToken,
    silent: silent,
    userAgent: userAgent,
    restored: true,
  );

  ChatSendRequest._({
    required super.accountId,
    required super.requestId,
    required super.server,
    required super.roomToken,
    required this.operationId,
    required this.profile,
    required this.message,
    required this.referenceId,
    required this.replyTo,
    required this.threadId,
    required this.parentRoomToken,
    required this.replyToToken,
    required this.silent,
    required bool restored,
    super.userAgent,
  }) {
    if (!profile.sendText) {
      _requestFailure(r'$.capabilities.chat-reference-id');
    }
    if (message.trim().isEmpty) {
      _requestFailure(r'$.body.message');
    }
    // Fail closed: a server without `silent-send` treats the flag as noise
    // and notifies anyway, so a caller who asked for silence would get the
    // opposite of what the switch promised.
    if (silent && !profile.silentSend) {
      _requestFailure(r'$.capabilities.silent-send');
    }
    if (threadId != null &&
        (threadId! < 1 || !profile.threadFetch || replyTo != null)) {
      _requestFailure(r'$.body.threadId');
    }
    if (replyTo == null) {
      if (parentRoomToken != null || replyToToken != null) {
        _requestFailure(r'$.body.replyTo');
      }
      return;
    }
    if (replyTo! < 1 || !profile.reply || parentRoomToken == null) {
      _requestFailure(r'$.body.replyTo');
    }
    final crossRoom = parentRoomToken != roomToken;
    if (!restored && (replyToToken != null || crossRoom)) {
      protocolFailure(
        TalkProtocolErrorCode.unsupportedChatOperation,
        r'$.body.replyToToken',
      );
    }
    if (restored && crossRoom) {
      if (!profile.privateReply || replyToToken != parentRoomToken) {
        _requestFailure(r'$.body.replyToToken');
      }
    } else if (replyToToken != null) {
      _requestFailure(r'$.body.replyToToken');
    }
  }

  final ChatOperationId operationId;
  final ChatCapabilityProfile profile;
  final String message;
  final ChatReferenceId referenceId;
  final int? replyTo;
  final int? threadId;
  final ConversationToken? parentRoomToken;
  final ConversationToken? replyToToken;
  final bool silent;

  @override
  Object get formBody => UnmodifiableMapView(<String, Object>{
    'message': message,
    'referenceId': referenceId.value,
    'replyTo': ?replyTo,
    'threadId': ?threadId,
    'replyToToken': ?replyToToken?.value,
    if (silent) 'silent': 'true',
  });

  @override
  ChatHttpMethod get method => ChatHttpMethod.post;

  @override
  Map<String, String> get queryParameters =>
      UnmodifiableMapView({'format': 'json'});

  @override
  String get requestPath => '$chatV1Path/${roomToken.value}';

  @override
  String toString() =>
      'ChatSendRequest(reply: ${replyTo != null}, '
      'namedThread: ${threadId != null}, message: <redacted>, '
      'referenceId: <redacted>)';
}

final class ChatSetReadMarkerRequest extends ChatRequest {
  ChatSetReadMarkerRequest({
    required super.accountId,
    required super.requestId,
    required super.server,
    required super.roomToken,
    required ChatCapabilityProfile profile,
    required this.lastReadMessage,
    super.userAgent,
  }) {
    if (!profile.setReadMarker) {
      _requestFailure(r'$.capabilities.chat-read-last');
    }
    if (lastReadMessage < 1) {
      _requestFailure(r'$.body.lastReadMessage');
    }
  }

  final int lastReadMessage;

  @override
  Object get formBody =>
      UnmodifiableMapView(<String, Object>{'lastReadMessage': lastReadMessage});

  @override
  ChatHttpMethod get method => ChatHttpMethod.post;

  @override
  Map<String, String> get queryParameters =>
      UnmodifiableMapView({'format': 'json'});

  @override
  String get requestPath => '$chatV1Path/${roomToken.value}/read';

  @override
  String toString() => 'ChatSetReadMarkerRequest()';
}

Never _requestFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidChatRequest, path);

Never _sharedItemsRequestFailure(String path) =>
    protocolFailure(TalkProtocolErrorCode.invalidSharedItemsRequest, path);
