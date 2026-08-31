// ignore_for_file: prefer_initializing_formals

import 'dart:collection';
import 'dart:convert';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:uuid/uuid.dart';

import '../../data/account_repository.dart';
import '../../data/app_database.dart';
import '../../data/chat_repository.dart';
import '../../data/credential_vault.dart';
import '../../data/thread_repository.dart';
import '../../network/nextcloud_api.dart';

const int _chatPermission = 128;
const int _ignoreLobbyPermission = 8;
const int _recentLimit = 50;
const int _subscribedPageSize = 100;
const int _maximumSubscribedThreads = 10000;

enum ThreadManagementError {
  accountMissing,
  conversationMissing,
  credentialMissing,
  talkUnavailable,
  unsupported,
  invalidInput,
  permissionDenied,
  notFound,
  reauthenticationRequired,
  rateLimited,
  serviceUnavailable,
  invalidResponse,
  network,
  ambiguous,
}

final class ThreadManagementException implements Exception {
  const ThreadManagementException(this.code);

  final ThreadManagementError code;

  @override
  String toString() => 'ThreadManagementException(${code.name})';
}

final class ThreadDetailAccess {
  const ThreadDetailAccess({
    required this.thread,
    required this.canRename,
    required this.canChangeNotifications,
  });

  final RichChatThread thread;
  final bool canRename;
  final bool canChangeNotifications;
}

/// Cache-first orchestration for Talk's thread metadata endpoints.
///
/// List replacements happen only after the complete response (including all
/// subscribed pages) is known to be valid. Rename and notification mutations
/// are online-only and are never admitted to an outbox or automatically
/// replayed after an ambiguous result.
final class ThreadManagementService {
  ThreadManagementService({
    required AccountRepository accounts,
    required ChatRepository chat,
    required ThreadRepository threads,
    required CredentialVault credentials,
    required HttpNextcloudApi api,
    Uuid? uuid,
  }) : _accounts = accounts,
       _chat = chat,
       _threads = threads,
       _credentials = credentials,
       _api = api,
       _uuid = uuid ?? const Uuid();

  final AccountRepository _accounts;
  final ChatRepository _chat;
  final ThreadRepository _threads;
  final CredentialVault _credentials;
  final HttpNextcloudApi _api;
  final Uuid _uuid;

  Future<List<RichChatThread>> refreshRecent({
    required String accountId,
    required String roomToken,
  }) async {
    final context = await _resolveRoom(
      accountId: accountId,
      roomToken: roomToken,
    );
    final request = _build(
      () => RichChatRequest.recentThreads(
        accountId: AccountId.parse(accountId),
        requestId: _requestId(),
        server: context.account.server,
        roomToken: context.room.token,
        profile: context.profile,
        limit: _recentLimit,
      ),
    );
    final response = await _send(context.account, request);
    final values = List<RichChatThread>.unmodifiable(response.threads);
    await _threads.replaceRecent(
      accountId: accountId,
      roomToken: roomToken,
      server: context.account.server,
      values: values,
    );
    return values;
  }

  Future<List<RichChatThread>> refreshSubscribed({
    required String accountId,
  }) async {
    final account = await _resolveAccount(accountId);
    final profile = _profile(account, federated: false, moderator: false);
    final values = <RichChatThread>[];
    final identities = <(String, int)>{};
    var offset = 0;
    while (true) {
      final request = _build(
        () => RichChatRequest.subscribedThreads(
          accountId: AccountId.parse(accountId),
          requestId: _requestId(),
          server: account.server,
          profile: profile,
          limit: _subscribedPageSize,
          offset: offset,
        ),
      );
      final response = await _send(account, request);
      for (final thread in response.threads) {
        if (!identities.add((thread.roomToken.value, thread.threadId))) {
          throw const ThreadManagementException(
            ThreadManagementError.invalidResponse,
          );
        }
        values.add(thread);
      }
      if (response.threads.length < _subscribedPageSize) {
        break;
      }
      if (values.length >= _maximumSubscribedThreads) {
        throw const ThreadManagementException(
          ThreadManagementError.invalidResponse,
        );
      }
      offset += _subscribedPageSize;
    }
    final result = List<RichChatThread>.unmodifiable(values);
    await _threads.replaceSubscribed(
      accountId: accountId,
      server: account.server,
      values: result,
    );
    return result;
  }

  Future<ThreadDetailAccess> loadDetail({
    required String accountId,
    required String roomToken,
    required int threadId,
  }) async {
    _requireThreadId(threadId);
    final context = await _resolveRoom(
      accountId: accountId,
      roomToken: roomToken,
    );
    final thread = await _fetchDetail(context, threadId);
    await _persistDetail(context, thread);
    return _access(context, thread);
  }

  Future<ThreadDetailAccess> rename({
    required String accountId,
    required String roomToken,
    required int threadId,
    required String title,
  }) async {
    _requireThreadId(threadId);
    final normalized = title.trim();
    if (normalized.isEmpty || normalized.length > 4096) {
      throw const ThreadManagementException(ThreadManagementError.invalidInput);
    }
    final context = await _resolveRoom(
      accountId: accountId,
      roomToken: roomToken,
    );
    final current = await _fetchDetail(context, threadId);
    if (!_canRename(context, current.firstMessage)) {
      throw const ThreadManagementException(
        ThreadManagementError.permissionDenied,
      );
    }
    final request = _build(
      () => RichChatRequest.renameThread(
        accountId: AccountId.parse(accountId),
        requestId: _requestId(),
        server: context.account.server,
        roomToken: context.room.token,
        profile: context.profile,
        threadId: threadId,
        threadTitle: normalized,
      ),
    );
    final response = await _send(context.account, request);
    final updated = _singleThread(response);
    await _persistDetail(context, updated);
    return _access(context, updated, authorizationRoot: current.firstMessage);
  }

  Future<ThreadDetailAccess> setNotificationLevel({
    required String accountId,
    required String roomToken,
    required int threadId,
    required int level,
  }) async {
    _requireThreadId(threadId);
    if (level < 0 || level > 3) {
      throw const ThreadManagementException(ThreadManagementError.invalidInput);
    }
    final context = await _resolveRoom(
      accountId: accountId,
      roomToken: roomToken,
    );
    if (!_canChangeNotifications(context)) {
      throw const ThreadManagementException(
        ThreadManagementError.permissionDenied,
      );
    }
    final authorizationRoot = await _cachedRoot(
      accountId: accountId,
      roomToken: roomToken,
      threadId: threadId,
    );
    final request = _build(
      () => RichChatRequest.setThreadNotificationLevel(
        accountId: AccountId.parse(accountId),
        requestId: _requestId(),
        server: context.account.server,
        roomToken: context.room.token,
        profile: context.profile,
        threadId: threadId,
        level: level,
      ),
    );
    final response = await _send(context.account, request);
    final updated = _singleThread(response);
    await _persistDetail(context, updated);
    return _access(context, updated, authorizationRoot: authorizationRoot);
  }

  Future<_ThreadRoomContext> _resolveRoom({
    required String accountId,
    required String roomToken,
  }) async {
    final account = await _resolveAccount(accountId);
    final conversation = await _chat.getConversation(
      accountId: accountId,
      roomToken: roomToken,
    );
    if (conversation == null) {
      throw const ThreadManagementException(
        ThreadManagementError.conversationMissing,
      );
    }
    final ConversationRoom room;
    try {
      room = ConversationRoom.fromJson(jsonDecode(conversation.rawJson));
    } on FormatException {
      throw const ThreadManagementException(
        ThreadManagementError.invalidResponse,
      );
    } on TalkProtocolException {
      throw const ThreadManagementException(
        ThreadManagementError.invalidResponse,
      );
    }
    if (conversation.accountId != accountId || room.token.value != roomToken) {
      throw const ThreadManagementException(
        ThreadManagementError.invalidResponse,
      );
    }
    final role = participantRoleFor(room.participantType);
    final moderator =
        role == ParticipantRole.owner ||
        role == ParticipantRole.moderator ||
        role == ParticipantRole.guestModerator;
    return _ThreadRoomContext(
      account: account,
      room: room,
      profile: _profile(
        account,
        federated: room.isFederated,
        moderator: moderator,
        participantPermissions: room.permissions,
      ),
      moderator: moderator,
    );
  }

  Future<_ThreadAccountContext> _resolveAccount(String accountId) async {
    final stored = await _accounts.getAccount(accountId);
    if (stored == null) {
      throw const ThreadManagementException(
        ThreadManagementError.accountMissing,
      );
    }
    final appPassword = await _credentials.readAppPassword(accountId);
    if (appPassword == null || appPassword.isEmpty) {
      throw const ThreadManagementException(
        ThreadManagementError.credentialMissing,
      );
    }
    final ServerBase server;
    try {
      server = ServerBase.parse(stored.serverUrl);
    } on TalkProtocolException {
      throw const ThreadManagementException(
        ThreadManagementError.invalidResponse,
      );
    }
    final CapabilitySnapshot capabilities;
    try {
      capabilities = await _api.getAuthenticatedCapabilities(
        server: server,
        loginName: stored.loginName,
        appPassword: appPassword,
      );
    } on NextcloudApiException catch (error) {
      if (error.statusCode == 401) {
        await _chat.markReauthenticationRequired(accountId);
      }
      throw ThreadManagementException(_mapApiError(error, mutation: false));
    }
    if (!capabilities.hasTalk) {
      throw const ThreadManagementException(
        ThreadManagementError.talkUnavailable,
      );
    }
    await _accounts.updateCapabilities(
      accountId,
      capabilities.talkFeatures,
      serverThemeColor: capabilities.serverThemeColor,
    );
    await _chat.recordCapabilities(
      accountId: accountId,
      talkFeatures: capabilities.talkFeatures,
      observedAt: DateTime.now().toUtc(),
    );
    final rawSpreed = capabilities.capabilities['spreed'];
    final spreed = rawSpreed is Map<String, Object?>
        ? rawSpreed
        : const <String, Object?>{};
    return _ThreadAccountContext(
      stored: stored,
      server: server,
      appPassword: appPassword,
      talkFeatures: capabilities.talkFeatures,
      localFeatures: spreed['features-local'] ?? const <Object?>[],
    );
  }

  RichChatCapabilityProfile _profile(
    _ThreadAccountContext context, {
    required bool federated,
    required bool moderator,
    int participantPermissions = 0,
  }) {
    try {
      return RichChatCapabilityProfile.fromTalkFeatures(
        talkFeatures: context.talkFeatures.toList(),
        talkLocalFeatures: context.localFeatures,
        federated: federated,
        moderator: moderator,
        participantPermissions: participantPermissions,
      );
    } on TalkProtocolException {
      throw const ThreadManagementException(
        ThreadManagementError.invalidResponse,
      );
    }
  }

  Future<RichChatThread> _fetchDetail(
    _ThreadRoomContext context,
    int threadId,
  ) async {
    final request = _build(
      () => RichChatRequest.getThread(
        accountId: AccountId.parse(context.account.stored.id),
        requestId: _requestId(),
        server: context.account.server,
        roomToken: context.room.token,
        profile: context.profile,
        threadId: threadId,
      ),
    );
    return _singleThread(await _send(context.account, request));
  }

  Future<void> _persistDetail(
    _ThreadRoomContext context,
    RichChatThread thread,
  ) {
    return _threads.upsertDetail(
      accountId: context.account.stored.id,
      server: context.account.server,
      value: thread,
    );
  }

  Future<ChatMessage?> _cachedRoot({
    required String accountId,
    required String roomToken,
    required int threadId,
  }) async {
    final cached = await _chat.getMessage(
      accountId: accountId,
      roomToken: roomToken,
      messageId: threadId,
    );
    if (cached == null) {
      return null;
    }
    try {
      final root = ChatMessage.fromJson(jsonDecode(cached.rawJson));
      if (root.messageId != threadId || root.roomToken.value != roomToken) {
        return null;
      }
      return root;
    } on FormatException {
      return null;
    } on TalkProtocolException {
      return null;
    }
  }

  ThreadDetailAccess _access(
    _ThreadRoomContext context,
    RichChatThread thread, {
    ChatMessage? authorizationRoot,
  }) {
    return ThreadDetailAccess(
      thread: thread,
      canRename: _canRename(context, thread.firstMessage ?? authorizationRoot),
      canChangeNotifications: _canChangeNotifications(context),
    );
  }

  bool _canRename(_ThreadRoomContext context, ChatMessage? root) {
    if (context.moderator) {
      return true;
    }
    return root != null &&
        root.actorType == 'users' &&
        root.actorId == context.account.stored.loginName;
  }

  bool _canChangeNotifications(_ThreadRoomContext context) {
    final permissions = context.room.permissions;
    return context.profile.threadMetadata &&
        context.room.readOnly == 0 &&
        permissions & _chatPermission == _chatPermission &&
        (context.room.lobbyState == 0 ||
            permissions & _ignoreLobbyPermission == _ignoreLobbyPermission);
  }

  RichChatRequest _build(RichChatRequest Function() build) {
    try {
      return build();
    } on TalkProtocolException {
      throw const ThreadManagementException(ThreadManagementError.unsupported);
    }
  }

  Future<RichChatResponse> _send(
    _ThreadAccountContext account,
    RichChatRequest request,
  ) async {
    final mutation = request.operation.isMutation;
    final RichChatResponse response;
    try {
      response = await _api.sendRichChat(
        richChatRequest: request,
        loginName: account.stored.loginName,
        appPassword: account.appPassword,
      );
    } on NextcloudApiException catch (error) {
      if (error.statusCode == 401) {
        await _chat.markReauthenticationRequired(account.stored.id);
      }
      throw ThreadManagementException(_mapApiError(error, mutation: mutation));
    } on TalkProtocolException {
      throw ThreadManagementException(
        mutation
            ? ThreadManagementError.ambiguous
            : ThreadManagementError.invalidResponse,
      );
    }
    switch (response.classification) {
      case RichChatResponseClassification.success:
        return response;
      case RichChatResponseClassification.reauthenticationRequired:
        await _chat.markReauthenticationRequired(account.stored.id);
        throw const ThreadManagementException(
          ThreadManagementError.reauthenticationRequired,
        );
      case RichChatResponseClassification.deterministicFailure:
        throw ThreadManagementException(_mapStatus(response.statusCode));
      case RichChatResponseClassification.ambiguous:
        throw const ThreadManagementException(ThreadManagementError.ambiguous);
      case RichChatResponseClassification.serverError:
        throw const ThreadManagementException(
          ThreadManagementError.serviceUnavailable,
        );
    }
  }

  RichChatThread _singleThread(RichChatResponse response) {
    if (response.threads.length != 1) {
      throw const ThreadManagementException(
        ThreadManagementError.invalidResponse,
      );
    }
    return response.threads.single;
  }

  ChatRequestId _requestId() => ChatRequestId.parse(_uuid.v4());
}

final class _ThreadAccountContext {
  _ThreadAccountContext({
    required this.stored,
    required this.server,
    required this.appPassword,
    required Set<String> talkFeatures,
    required this.localFeatures,
  }) : talkFeatures = UnmodifiableSetView(talkFeatures);

  final StoredAccount stored;
  final ServerBase server;
  final String appPassword;
  final Set<String> talkFeatures;
  final Object? localFeatures;
}

final class _ThreadRoomContext {
  const _ThreadRoomContext({
    required this.account,
    required this.room,
    required this.profile,
    required this.moderator,
  });

  final _ThreadAccountContext account;
  final ConversationRoom room;
  final RichChatCapabilityProfile profile;
  final bool moderator;
}

void _requireThreadId(int threadId) {
  if (threadId < 1) {
    throw const ThreadManagementException(ThreadManagementError.invalidInput);
  }
}

ThreadManagementError _mapStatus(int statusCode) {
  return switch (statusCode) {
    400 || 405 || 409 || 422 => ThreadManagementError.invalidInput,
    401 => ThreadManagementError.reauthenticationRequired,
    403 => ThreadManagementError.permissionDenied,
    404 => ThreadManagementError.notFound,
    408 => ThreadManagementError.network,
    429 => ThreadManagementError.rateLimited,
    500 || 502 || 503 || 504 => ThreadManagementError.serviceUnavailable,
    _ => ThreadManagementError.invalidResponse,
  };
}

ThreadManagementError _mapApiError(
  NextcloudApiException error, {
  required bool mutation,
}) {
  if (error.statusCode case final status?) {
    return _mapStatus(status);
  }
  return switch (error.code) {
    NextcloudApiError.network || NextcloudApiError.timeout =>
      mutation
          ? ThreadManagementError.ambiguous
          : ThreadManagementError.network,
    NextcloudApiError.cancelled => ThreadManagementError.network,
    NextcloudApiError.responseTooLarge ||
    NextcloudApiError.invalidJson ||
    NextcloudApiError.unexpectedStatus =>
      mutation
          ? ThreadManagementError.ambiguous
          : ThreadManagementError.invalidResponse,
    NextcloudApiError.invalidAvatarUri ||
    NextcloudApiError.invalidAvatarResponse ||
    NextcloudApiError.invalidWebPushResponse =>
      ThreadManagementError.invalidResponse,
  };
}
