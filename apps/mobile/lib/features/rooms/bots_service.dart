// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import '../../data/account_repository.dart';
import '../../data/app_database.dart';
import '../../data/credential_vault.dart';
import '../../network/nextcloud_api.dart';

const String _botsCapability = 'bots-v1';

enum BotsServiceError {
  accountMissing,
  credentialMissing,
  unsupported,
  reauthenticationRequired,
  forbidden,
  roomMissing,
  rejected,
  rateLimited,
  serviceUnavailable,
  invalidResponse,
  network,
}

final class BotsServiceException implements Exception {
  const BotsServiceException(this.code);

  final BotsServiceError code;

  @override
  String toString() => 'BotsServiceException(${code.name})';
}

/// Reads and changes conversation bots through direct, account-scoped calls.
/// A mutation is never queued or retried after an ambiguous transport error.
final class BotsService {
  BotsService({
    required AccountRepository accounts,
    required CredentialVault credentials,
    required HttpNextcloudApi api,
  }) : _accounts = accounts,
       _credentials = credentials,
       _api = api;

  final AccountRepository _accounts;
  final CredentialVault _credentials;
  final HttpNextcloudApi _api;

  Future<List<TalkBot>> fetchBots({
    required String accountId,
    required String roomToken,
  }) async {
    final context = await _authContext(accountId);
    final request = _listRequest(context.account, roomToken);
    final response = await _call(
      () => _api.getBots(
        botsRequest: request,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      ),
    );
    return switch (response) {
      BotListSuccess(:final bots) => bots,
      _ => throw BotsServiceException(_responseError(response)),
    };
  }

  Future<TalkBot> setEnabled({
    required String accountId,
    required String roomToken,
    required int botId,
    required bool enabled,
  }) async {
    final context = await _authContext(accountId);
    final request = _changeRequest(context.account, roomToken, botId, enabled);
    final response = await _call(
      () => _api.changeBotState(
        botsRequest: request,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      ),
    );
    return switch (response) {
      BotChangeSuccess(:final bot) => bot,
      _ => throw BotsServiceException(_responseError(response)),
    };
  }

  ListBotsRequest _listRequest(StoredAccount account, String roomToken) {
    try {
      return ListBotsRequest(
        accountId: AccountId.parse(account.id),
        server: ServerBase.parse(account.serverUrl),
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
      );
    } on TalkProtocolException {
      throw const BotsServiceException(BotsServiceError.invalidResponse);
    }
  }

  ChangeBotStateRequest _changeRequest(
    StoredAccount account,
    String roomToken,
    int botId,
    bool enabled,
  ) {
    try {
      return ChangeBotStateRequest(
        accountId: AccountId.parse(account.id),
        server: ServerBase.parse(account.serverUrl),
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
        botId: botId,
        enable: enabled,
      );
    } on TalkProtocolException {
      throw const BotsServiceException(BotsServiceError.invalidResponse);
    }
  }

  Future<_BotsAuthContext> _authContext(String accountId) async {
    final account = await _accounts.getAccount(accountId);
    if (account == null) {
      throw const BotsServiceException(BotsServiceError.accountMissing);
    }
    if (!_talkFeatures(account.talkFeaturesJson).contains(_botsCapability)) {
      throw const BotsServiceException(BotsServiceError.unsupported);
    }
    final appPassword = await _credentials.readAppPassword(accountId);
    if (appPassword == null) {
      throw const BotsServiceException(BotsServiceError.credentialMissing);
    }
    return _BotsAuthContext(account: account, appPassword: appPassword);
  }

  Future<BotManagementResponse> _call(
    Future<BotManagementResponse> Function() action,
  ) async {
    try {
      return await action();
    } on NextcloudApiException catch (error) {
      throw BotsServiceException(switch (error.code) {
        NextcloudApiError.network ||
        NextcloudApiError.timeout ||
        NextcloudApiError.cancelled => BotsServiceError.network,
        _ => BotsServiceError.invalidResponse,
      });
    } on TalkProtocolException {
      throw const BotsServiceException(BotsServiceError.invalidResponse);
    }
  }

  BotsServiceError _responseError(BotManagementResponse response) {
    return switch (response) {
      BotChangeRejected() => BotsServiceError.rejected,
      BotReauthenticationRequired() =>
        BotsServiceError.reauthenticationRequired,
      BotForbidden() => BotsServiceError.forbidden,
      BotRoomMissing() => BotsServiceError.roomMissing,
      BotHttpFailure(:final kind) =>
        kind == BotHttpFailureKind.rateLimited
            ? BotsServiceError.rateLimited
            : BotsServiceError.serviceUnavailable,
      BotListSuccess() ||
      BotChangeSuccess() => BotsServiceError.invalidResponse,
    };
  }
}

Set<String> _talkFeatures(String source) {
  try {
    final decoded = jsonDecode(source);
    if (decoded is List<Object?> && decoded.every((value) => value is String)) {
      return decoded.cast<String>().toSet();
    }
  } on FormatException {
    // A corrupt capability cache fails closed before an authenticated call.
  }
  return const <String>{};
}

final class _BotsAuthContext {
  const _BotsAuthContext({required this.account, required this.appPassword});

  final StoredAccount account;
  final String appPassword;
}

final botsServiceProvider = Provider<BotsService>((ref) {
  return BotsService(
    accounts: ref.watch(accountRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    api: ref.watch(nextcloudApiProvider),
  );
});
