// ignore_for_file: prefer_initializing_formals

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import '../../data/account_repository.dart';
import '../../data/app_database.dart';
import '../../data/credential_vault.dart';
import '../../network/nextcloud_api.dart';

enum RoomSettingsError {
  accountMissing,
  credentialMissing,
  reauthenticationRequired,
  forbidden,
  roomMissing,

  /// The server refused the change, e.g. leaving as the last moderator.
  rejected,
  rateLimited,
  serviceUnavailable,
  invalidResponse,
  network,
}

final class RoomSettingsException implements Exception {
  const RoomSettingsException(this.code);

  final RoomSettingsError code;

  @override
  String toString() => 'RoomSettingsException(${code.name})';
}

/// Applies conversation-settings changes (rename, description, notification
/// level, favorite, leave) scoped to a single account. Every action is a
/// direct, single request; none of them retry or queue.
final class RoomSettingsService {
  RoomSettingsService({
    required AccountRepository accounts,
    required CredentialVault credentials,
    required HttpNextcloudApi api,
  }) : _accounts = accounts,
       _credentials = credentials,
       _api = api;

  final AccountRepository _accounts;
  final CredentialVault _credentials;
  final HttpNextcloudApi _api;

  Future<ConversationRoom> renameRoom({
    required String accountId,
    required String roomToken,
    required String name,
  }) async {
    final context = await _authContext(accountId);
    final UpdateRoomNameRequest request;
    try {
      request = UpdateRoomNameRequest(
        accountId: AccountId.parse(accountId),
        server: ServerBase.parse(context.account.serverUrl),
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
        name: name,
      );
    } on TalkProtocolException {
      throw const RoomSettingsException(RoomSettingsError.invalidResponse);
    }

    final response = await _call(
      () => _api.updateRoomName(
        updateRequest: request,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      ),
    );

    return switch (response) {
      UpdateRoomNameSuccess(:final room) => room,
      UpdateRoomNameReauthenticationRequired() =>
        throw const RoomSettingsException(
          RoomSettingsError.reauthenticationRequired,
        ),
      UpdateRoomNameForbidden() => throw const RoomSettingsException(
        RoomSettingsError.forbidden,
      ),
      UpdateRoomNameRoomMissing() => throw const RoomSettingsException(
        RoomSettingsError.roomMissing,
      ),
      UpdateRoomNameHttpFailure(:final kind) => throw RoomSettingsException(
        _mapHttpFailure(kind),
      ),
    };
  }

  Future<ConversationRoom> updateDescription({
    required String accountId,
    required String roomToken,
    required String description,
  }) async {
    final context = await _authContext(accountId);
    final UpdateRoomDescriptionRequest request;
    try {
      request = UpdateRoomDescriptionRequest(
        accountId: AccountId.parse(accountId),
        server: ServerBase.parse(context.account.serverUrl),
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
        description: description,
      );
    } on TalkProtocolException {
      throw const RoomSettingsException(RoomSettingsError.invalidResponse);
    }

    final response = await _call(
      () => _api.updateRoomDescription(
        updateRequest: request,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      ),
    );

    return switch (response) {
      UpdateRoomDescriptionSuccess(:final room) => room,
      UpdateRoomDescriptionReauthenticationRequired() =>
        throw const RoomSettingsException(
          RoomSettingsError.reauthenticationRequired,
        ),
      UpdateRoomDescriptionForbidden() => throw const RoomSettingsException(
        RoomSettingsError.forbidden,
      ),
      UpdateRoomDescriptionRoomMissing() => throw const RoomSettingsException(
        RoomSettingsError.roomMissing,
      ),
      UpdateRoomDescriptionHttpFailure(:final kind) =>
        throw RoomSettingsException(_mapHttpFailure(kind)),
    };
  }

  Future<void> setNotificationLevel({
    required String accountId,
    required String roomToken,
    required RoomNotificationLevel level,
  }) async {
    final context = await _authContext(accountId);
    final UpdateNotificationLevelRequest request;
    try {
      request = UpdateNotificationLevelRequest(
        accountId: AccountId.parse(accountId),
        server: ServerBase.parse(context.account.serverUrl),
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
        level: level,
      );
    } on TalkProtocolException {
      throw const RoomSettingsException(RoomSettingsError.invalidResponse);
    }

    final response = await _call(
      () => _api.updateNotificationLevel(
        updateRequest: request,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      ),
    );

    switch (response) {
      case UpdateNotificationLevelSuccess():
        return;
      case UpdateNotificationLevelReauthenticationRequired():
        throw const RoomSettingsException(
          RoomSettingsError.reauthenticationRequired,
        );
      case UpdateNotificationLevelRoomMissing():
        throw const RoomSettingsException(RoomSettingsError.roomMissing);
      case UpdateNotificationLevelHttpFailure(:final kind):
        throw RoomSettingsException(_mapHttpFailure(kind));
    }
  }

  Future<void> setFavorite({
    required String accountId,
    required String roomToken,
    required bool favorite,
  }) async {
    final context = await _authContext(accountId);
    final SetFavoriteRequest request;
    try {
      request = SetFavoriteRequest(
        accountId: AccountId.parse(accountId),
        server: ServerBase.parse(context.account.serverUrl),
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
        favorite: favorite,
      );
    } on TalkProtocolException {
      throw const RoomSettingsException(RoomSettingsError.invalidResponse);
    }

    final response = await _call(
      () => _api.setFavorite(
        favoriteRequest: request,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      ),
    );

    switch (response) {
      case SetFavoriteSuccess():
        return;
      case SetFavoriteReauthenticationRequired():
        throw const RoomSettingsException(
          RoomSettingsError.reauthenticationRequired,
        );
      case SetFavoriteRoomMissing():
        throw const RoomSettingsException(RoomSettingsError.roomMissing);
      case SetFavoriteHttpFailure(:final kind):
        throw RoomSettingsException(_mapHttpFailure(kind));
    }
  }

  Future<void> leaveRoom({
    required String accountId,
    required String roomToken,
  }) async {
    final context = await _authContext(accountId);
    final LeaveRoomRequest request;
    try {
      request = LeaveRoomRequest(
        accountId: AccountId.parse(accountId),
        server: ServerBase.parse(context.account.serverUrl),
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
      );
    } on TalkProtocolException {
      throw const RoomSettingsException(RoomSettingsError.invalidResponse);
    }

    final response = await _call(
      () => _api.leaveRoom(
        leaveRequest: request,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      ),
    );

    switch (response) {
      case LeaveRoomSuccess():
        return;
      case LeaveRoomRejected():
        throw const RoomSettingsException(RoomSettingsError.rejected);
      case LeaveRoomReauthenticationRequired():
        throw const RoomSettingsException(
          RoomSettingsError.reauthenticationRequired,
        );
      case LeaveRoomForbidden():
        throw const RoomSettingsException(RoomSettingsError.forbidden);
      case LeaveRoomRoomMissing():
        throw const RoomSettingsException(RoomSettingsError.roomMissing);
      case LeaveRoomHttpFailure(:final kind):
        throw RoomSettingsException(_mapHttpFailure(kind));
    }
  }

  Future<_AuthContext> _authContext(String accountId) async {
    final account = await _accounts.getAccount(accountId);
    if (account == null) {
      throw const RoomSettingsException(RoomSettingsError.accountMissing);
    }
    final appPassword = await _credentials.readAppPassword(accountId);
    if (appPassword == null) {
      throw const RoomSettingsException(RoomSettingsError.credentialMissing);
    }
    return _AuthContext(account: account, appPassword: appPassword);
  }

  Future<T> _call<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on NextcloudApiException catch (error) {
      throw RoomSettingsException(_mapApiError(error));
    } on TalkProtocolException {
      throw const RoomSettingsException(RoomSettingsError.invalidResponse);
    }
  }

  RoomSettingsError _mapApiError(NextcloudApiException error) {
    return switch (error.code) {
      NextcloudApiError.network ||
      NextcloudApiError.timeout ||
      NextcloudApiError.cancelled => RoomSettingsError.network,
      _ => RoomSettingsError.invalidResponse,
    };
  }

  RoomSettingsError _mapHttpFailure(RoomSettingsHttpFailureKind kind) {
    return switch (kind) {
      RoomSettingsHttpFailureKind.rateLimited => RoomSettingsError.rateLimited,
      RoomSettingsHttpFailureKind.serviceUnavailable =>
        RoomSettingsError.serviceUnavailable,
    };
  }
}

final class _AuthContext {
  const _AuthContext({required this.account, required this.appPassword});

  final StoredAccount account;
  final String appPassword;
}

final roomSettingsServiceProvider = Provider<RoomSettingsService>((ref) {
  return RoomSettingsService(
    accounts: ref.watch(accountRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    api: ref.watch(nextcloudApiProvider),
  );
});
