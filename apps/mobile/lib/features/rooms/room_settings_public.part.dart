part of 'room_settings_service.dart';

final class RoomPublicAccess {
  const RoomPublicAccess._({
    required this.accountId,
    required this.room,
    required this.supportsPassword,
    required this.forcePasswords,
  });

  final String accountId;
  final ConversationRoom room;
  final bool supportsPassword;
  final bool forcePasswords;
}

extension RoomSettingsPublicAccess on RoomSettingsService {
  Future<RoomPublicAccess> preparePublicChange({
    required String accountId,
    required String roomToken,
    Future<void>? abortTrigger,
    bool Function()? isCurrent,
  }) async {
    var aborted = false;
    abortTrigger?.then((_) => aborted = true);
    void check() {
      if (aborted || !(isCurrent?.call() ?? true)) {
        throw const RoomSettingsException(RoomSettingsError.accountMissing);
      }
    }

    check();
    final context = await _authContext(accountId);
    await _validatePublicIdentity(context);
    check();
    final server = ServerBase.parse(context.account.serverUrl);
    final read = await _call(
      () => _api.getAuthenticatedCapabilitiesWithSource(
        server: server,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
        forceRefresh: true,
        abortTrigger: abortTrigger,
      ),
    );
    check();
    final raw = read.snapshot.capabilities['spreed'];
    final config = raw is Map ? raw['config'] : null;
    final conversations = config is Map ? config['conversations'] : null;
    if (raw is! Map || (conversations != null && conversations is! Map)) {
      throw const RoomSettingsException(RoomSettingsError.invalidResponse);
    }
    final forced = conversations is Map
        ? conversations['force-passwords']
        : null;
    if (conversations is Map &&
        conversations.containsKey('force-passwords') &&
        forced is! bool) {
      throw const RoomSettingsException(RoomSettingsError.invalidResponse);
    }
    final room = await _publicRoom(context, roomToken, abortTrigger);
    check();
    await _validatePublicIdentity(context);
    check();
    _requirePublicModerator(room);
    final access = RoomPublicAccess._(
      accountId: accountId,
      room: room,
      supportsPassword: read.snapshot.supportsTalk(
        'conversation-creation-password',
      ),
      forcePasswords: forced == true,
    );
    _publicOrigins[access] = context;
    return access;
  }

  Future<ConversationRoom> setPublic({
    required String accountId,
    required String roomToken,
    required bool public,
    String? password,
    RoomPublicAccess? prepared,
    Future<void>? abortTrigger,
    bool Function()? isCurrent,
  }) async {
    final key = (accountId: accountId, roomToken: roomToken);
    if (!_publicPending.add(key)) {
      throw const RoomSettingsException(RoomSettingsError.rejected);
    }
    var dispatched = false;
    var rejected = false;
    var aborted = false;
    abortTrigger?.then((_) => aborted = true);
    void check() {
      if (aborted || !(isCurrent?.call() ?? true)) {
        throw RoomSettingsException(
          dispatched
              ? RoomSettingsError.ambiguous
              : RoomSettingsError.accountMissing,
        );
      }
    }

    RoomPublicAccess? used;
    try {
      check();
      if (prepared != null &&
          (prepared.accountId != accountId ||
              prepared.room.token.value != roomToken ||
              _publicOrigins[prepared] == null ||
              _publicUsed[prepared] == true)) {
        throw const RoomSettingsException(RoomSettingsError.rejected);
      }
      if (prepared != null) {
        await _validatePublicIdentity(_publicOrigins[prepared]!);
      }
      final fresh = await preparePublicChange(
        accountId: accountId,
        roomToken: roomToken,
        abortTrigger: abortTrigger,
        isCurrent: isCurrent,
      );
      check();
      if (prepared != null &&
          (prepared.forcePasswords != fresh.forcePasswords ||
              prepared.supportsPassword != fresh.supportsPassword ||
              prepared.room.type != fresh.room.type)) {
        throw const RoomSettingsException(RoomSettingsError.preconditionFailed);
      }
      used = prepared ?? fresh;
      final context = _publicOrigins[fresh]!;
      if ((fresh.room.type == 3) == public) {
        if (public && password?.isNotEmpty == true) {
          throw const RoomSettingsException(
            RoomSettingsError.preconditionFailed,
          );
        }
        return fresh.room;
      }
      final SetRoomPublicRequest request;
      try {
        request = SetRoomPublicRequest(
          accountId: AccountId.parse(accountId),
          server: ServerBase.parse(context.account.serverUrl),
          roomToken: fresh.room.token,
          public: public,
          password: password,
          creationPasswordAvailable: fresh.supportsPassword,
          forcePasswords: fresh.forcePasswords,
        );
      } on TalkProtocolException {
        throw const RoomSettingsException(RoomSettingsError.preconditionFailed);
      }
      await _validatePublicIdentity(context);
      check();
      _publicUsed[used] = true;
      dispatched = true;
      final response = await _call(
        () => _api.administerRoom(
          administrationRequest: request,
          loginName: context.account.loginName,
          appPassword: context.appPassword,
          abortTrigger: abortTrigger,
        ),
      );
      check();
      if (response is RoomAdministrationRejected) {
        rejected = true;
        final hint = response.message;
        final safeHint =
            hint != null &&
                (password == null ||
                    password.isEmpty ||
                    !hint.contains(password))
            ? hint.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim()
            : null;
        throw RoomSettingsException(
          RoomSettingsError.rejected,
          message: safeHint?.isEmpty == true ? null : safeHint,
        );
      }
      if (response is! RoomAdministrationSuccess) {
        // A 5xx cannot prove that the requested change was not applied.
        rejected = response.statusCode >= 400 && response.statusCode < 500;
        _classifyAdministration(response);
      }
      await _validatePublicIdentity(context);
      check();
      // Spreed's atomic public transition updates the stored hash before its
      // in-memory Room object; the mutation response can retain hasPassword=false.
      final room = await _publicRoom(context, roomToken, abortTrigger);
      await _validatePublicIdentity(context);
      check();
      if (room.token.value != roomToken ||
          room.type != (public ? 3 : 2) ||
          (public && password?.isNotEmpty == true && !room.hasPassword)) {
        throw const RoomSettingsException(RoomSettingsError.ambiguous);
      }
      return room;
    } on RoomSettingsException {
      if (dispatched && !rejected) {
        throw const RoomSettingsException(RoomSettingsError.ambiguous);
      }
      rethrow;
    } finally {
      if (used != null && rejected) _publicUsed[used] = false;
      _publicPending.remove(key);
    }
  }

  Future<ConversationRoom> _publicRoom(
    _AuthContext context,
    String token,
    Future<void>? abort,
  ) async {
    final response = await _call(
      () => _api.getConversations(
        conversationRequest: ConversationListRequest(
          accountId: AccountId.parse(context.account.id),
          requestId: ConversationRequestId.parse(_uuid.v4()),
          server: ServerBase.parse(context.account.serverUrl),
          mode: ConversationFetchMode.full,
          includeLastMessage: false,
        ),
        loginName: context.account.loginName,
        appPassword: context.appPassword,
        abortTrigger: abort,
      ),
    );
    if (response is! ConversationListSuccess) {
      throw RoomSettingsException(
        response.statusCode == 401
            ? RoomSettingsError.reauthenticationRequired
            : RoomSettingsError.roomMissing,
      );
    }
    final matches = response.rooms.where((room) => room.token.value == token);
    if (matches.length != 1) {
      throw const RoomSettingsException(RoomSettingsError.roomMissing);
    }
    return matches.single;
  }

  Future<void> _validatePublicIdentity(_AuthContext expected) async {
    final current = await _authContext(expected.account.id);
    if (!current.account.selected ||
        current.account.loginName != expected.account.loginName ||
        current.account.serverUrl != expected.account.serverUrl ||
        current.appPassword != expected.appPassword) {
      throw const RoomSettingsException(RoomSettingsError.accountMissing);
    }
  }
}

void _requirePublicModerator(ConversationRoom room) {
  final remote = room.wire['remoteServer'];
  if (!const {1, 2}.contains(room.participantType) ||
      !const {2, 3}.contains(room.type) ||
      room.attributes & 4 != 0 ||
      (remote is String && remote.isNotEmpty)) {
    throw const RoomSettingsException(RoomSettingsError.forbidden);
  }
}
