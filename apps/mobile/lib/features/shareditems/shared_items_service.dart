import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';
import 'package:uuid/uuid.dart';

import '../../app_providers.dart';
import '../../data/account_repository.dart';
import '../../data/app_database.dart';
import '../../data/credential_vault.dart';
import '../../network/nextcloud_api.dart';

const int sharedItemsOverviewLimit = 7;
const int sharedItemsPageLimit = 28;

enum SharedItemsError {
  accountMissing,
  conversationMissing,
  credentialMissing,
  unsupported,
  reauthenticationRequired,
  roomNotFound,
  lobbyRestricted,
  rateLimited,
  serviceUnavailable,
  invalidResponse,
  network,
  cancelled,
}

final class SharedItemsException implements Exception {
  const SharedItemsException(this.code);

  final SharedItemsError code;

  @override
  String toString() => 'SharedItemsException(${code.name})';
}

abstract interface class SharedItemsService {
  Future<SharedItemsOverviewResponse> overview({
    required String accountId,
    required String roomToken,
    Future<void>? abortTrigger,
  });

  Future<SharedItemsPageResponse> page({
    required String accountId,
    required String roomToken,
    required SharedItemType type,
    required int lastKnownMessageId,
    Future<void>? abortTrigger,
  });
}

final class HttpSharedItemsService implements SharedItemsService {
  factory HttpSharedItemsService({
    required AccountRepository accounts,
    required CredentialVault credentials,
    required HttpNextcloudApi api,
    Uuid? uuid,
  }) => HttpSharedItemsService._(
    accounts,
    credentials,
    api,
    uuid ?? const Uuid(),
  );

  HttpSharedItemsService._(
    this._accounts,
    this._credentials,
    this._api,
    this._uuid,
  );

  final AccountRepository _accounts;
  final CredentialVault _credentials;
  final HttpNextcloudApi _api;
  final Uuid _uuid;

  @override
  Future<SharedItemsOverviewResponse> overview({
    required String accountId,
    required String roomToken,
    Future<void>? abortTrigger,
  }) async {
    final context = await _context(accountId, roomToken, abortTrigger);
    final request = SharedItemsOverviewRequest(
      accountId: AccountId.parse(accountId),
      requestId: ChatRequestId.parse(_uuid.v4()),
      server: context.server,
      roomToken: context.room.token,
      sharedItemsAvailable: true,
      limit: sharedItemsOverviewLimit,
    );
    final response = await _call(
      () => _api.getSharedItemsOverview(
        overviewRequest: request,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
        abortTrigger: abortTrigger,
      ),
    );
    _requireSuccess(response.classification);
    return response;
  }

  @override
  Future<SharedItemsPageResponse> page({
    required String accountId,
    required String roomToken,
    required SharedItemType type,
    required int lastKnownMessageId,
    Future<void>? abortTrigger,
  }) async {
    final context = await _context(accountId, roomToken, abortTrigger);
    final request = SharedItemsPageRequest(
      accountId: AccountId.parse(accountId),
      requestId: ChatRequestId.parse(_uuid.v4()),
      server: context.server,
      roomToken: context.room.token,
      sharedItemsAvailable: true,
      type: type,
      lastKnownMessageId: lastKnownMessageId,
      limit: sharedItemsPageLimit,
    );
    final response = await _call(
      () => _api.getSharedItemsPage(
        pageRequest: request,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
        abortTrigger: abortTrigger,
      ),
    );
    _requireSuccess(response.classification);
    return response;
  }

  Future<_SharedItemsContext> _context(
    String accountId,
    String roomToken,
    Future<void>? abortTrigger,
  ) async {
    final account = await _accounts.getAccount(accountId);
    if (account == null) {
      throw const SharedItemsException(SharedItemsError.accountMissing);
    }
    final conversation = await _accounts.getConversation(
      accountId: accountId,
      token: roomToken,
    );
    if (conversation == null) {
      throw const SharedItemsException(SharedItemsError.conversationMissing);
    }
    final appPassword = await _credentials.readAppPassword(accountId);
    if (appPassword == null) {
      throw const SharedItemsException(SharedItemsError.credentialMissing);
    }

    try {
      final server = ServerBase.parse(account.serverUrl);
      final room = ConversationRoom.fromJson(jsonDecode(conversation.rawJson));
      if (room.token.value != roomToken) {
        throw const SharedItemsException(SharedItemsError.invalidResponse);
      }
      final capabilityRead = await _call(
        () => _api.getAuthenticatedCapabilitiesWithSource(
          server: server,
          loginName: account.loginName,
          appPassword: appPassword,
          abortTrigger: abortTrigger,
        ),
      );
      final capabilities = capabilityRead.snapshot;
      await _accounts.updateCapabilities(
        accountId,
        capabilities.talkFeatures,
        serverThemeColor: capabilities.serverThemeColor,
      );
      if (!capabilities.supportsTalk('rich-object-list-media')) {
        throw const SharedItemsException(SharedItemsError.unsupported);
      }
      if (room.remoteServer?.isNotEmpty == true &&
          !capabilities.supportsTalk('federated-shared-items')) {
        throw const SharedItemsException(SharedItemsError.unsupported);
      }
      return _SharedItemsContext(
        account: account,
        appPassword: appPassword,
        server: server,
        room: room,
      );
    } on FormatException {
      throw const SharedItemsException(SharedItemsError.invalidResponse);
    } on TalkProtocolException {
      throw const SharedItemsException(SharedItemsError.invalidResponse);
    }
  }

  Future<T> _call<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on NextcloudApiException catch (error) {
      throw SharedItemsException(_apiError(error));
    } on TalkProtocolException {
      throw const SharedItemsException(SharedItemsError.invalidResponse);
    }
  }

  void _requireSuccess(SharedItemsClassification classification) {
    if (classification == SharedItemsClassification.success) {
      return;
    }
    throw SharedItemsException(switch (classification) {
      SharedItemsClassification.success => SharedItemsError.invalidResponse,
      SharedItemsClassification.reauthenticationRequired =>
        SharedItemsError.reauthenticationRequired,
      SharedItemsClassification.roomNotFound => SharedItemsError.roomNotFound,
      SharedItemsClassification.lobbyRestricted =>
        SharedItemsError.lobbyRestricted,
      SharedItemsClassification.rateLimited => SharedItemsError.rateLimited,
      SharedItemsClassification.serviceUnavailable =>
        SharedItemsError.serviceUnavailable,
      SharedItemsClassification.ocsError => SharedItemsError.invalidResponse,
    });
  }
}

final class _SharedItemsContext {
  const _SharedItemsContext({
    required this.account,
    required this.appPassword,
    required this.server,
    required this.room,
  });

  final StoredAccount account;
  final String appPassword;
  final ServerBase server;
  final ConversationRoom room;
}

SharedItemsError _apiError(NextcloudApiException error) => switch (error.code) {
  NextcloudApiError.cancelled => SharedItemsError.cancelled,
  NextcloudApiError.network ||
  NextcloudApiError.timeout => SharedItemsError.network,
  NextcloudApiError.unexpectedStatus when error.statusCode == 401 =>
    SharedItemsError.reauthenticationRequired,
  NextcloudApiError.unexpectedStatus when error.statusCode == 429 =>
    SharedItemsError.rateLimited,
  NextcloudApiError.unexpectedStatus when error.statusCode == 503 =>
    SharedItemsError.serviceUnavailable,
  _ => SharedItemsError.invalidResponse,
};

final sharedItemsServiceProvider = Provider<SharedItemsService>((ref) {
  return HttpSharedItemsService(
    accounts: ref.watch(accountRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    api: ref.watch(nextcloudApiProvider),
  );
});
