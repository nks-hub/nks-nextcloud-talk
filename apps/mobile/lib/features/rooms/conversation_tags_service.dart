import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import '../../data/account_repository.dart';
import '../../data/app_database.dart';
import '../../data/credential_vault.dart';
import '../../network/nextcloud_api.dart';

enum ConversationTagsError {
  accountMissing,
  credentialMissing,
  unsupported,
  reauthenticationRequired,
  forbidden,
  roomMissing,
  rateLimited,
  serviceUnavailable,
  invalidResponse,
  network,
}

final class ConversationTagsException implements Exception {
  const ConversationTagsException(this.code);

  final ConversationTagsError code;

  @override
  String toString() => 'ConversationTagsException(${code.name})';
}

final class ConversationTagsService {
  const ConversationTagsService({
    required AccountRepository accounts,
    required CredentialVault credentials,
    required HttpNextcloudApi api,
  }) : this._(accounts, credentials, api);

  const ConversationTagsService._(this._accounts, this._credentials, this._api);

  final AccountRepository _accounts;
  final CredentialVault _credentials;
  final HttpNextcloudApi _api;

  Future<List<ConversationTagDefinition>> fetchDefinitions({
    required String accountId,
  }) async {
    final context = await _context(accountId);
    final profile = await _freshProfile(context, loggedInParticipant: false);
    final FetchConversationTagsRequest request;
    try {
      request = FetchConversationTagsRequest(
        accountId: AccountId.parse(accountId),
        server: ServerBase.parse(context.account.serverUrl),
        profile: profile,
      );
    } on TalkProtocolException {
      throw const ConversationTagsException(ConversationTagsError.unsupported);
    }

    final response = await _call(
      () => _api.getConversationTags(
        tagsRequest: request,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      ),
    );
    return switch (response) {
      FetchConversationTagsSuccess(:final definitions) => definitions,
      FetchConversationTagsReauthenticationRequired() =>
        throw const ConversationTagsException(
          ConversationTagsError.reauthenticationRequired,
        ),
      FetchConversationTagsHttpFailure(:final kind) =>
        throw ConversationTagsException(_mapHttpFailure(kind)),
    };
  }

  Future<ConversationRoom> assign({
    required String accountId,
    required String roomToken,
    required Iterable<String> tagIds,
  }) async {
    final context = await _context(accountId);
    final profile = await _freshProfile(context, loggedInParticipant: true);
    final AssignConversationTagsRequest request;
    try {
      request = AssignConversationTagsRequest(
        accountId: AccountId.parse(accountId),
        server: ServerBase.parse(context.account.serverUrl),
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
        profile: profile,
        tagIds: tagIds,
      );
    } on TalkProtocolException {
      throw const ConversationTagsException(
        ConversationTagsError.invalidResponse,
      );
    }

    final response = await _call(
      () => _api.assignConversationTags(
        tagsRequest: request,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      ),
    );
    final room = switch (response) {
      AssignConversationTagsSuccess(:final room) => room,
      AssignConversationTagsReauthenticationRequired() =>
        throw const ConversationTagsException(
          ConversationTagsError.reauthenticationRequired,
        ),
      AssignConversationTagsForbidden() =>
        throw const ConversationTagsException(ConversationTagsError.forbidden),
      AssignConversationTagsRoomMissing() =>
        throw const ConversationTagsException(
          ConversationTagsError.roomMissing,
        ),
      AssignConversationTagsHttpFailure(:final kind) =>
        throw ConversationTagsException(_mapHttpFailure(kind)),
    };
    try {
      await _accounts.applyAuthoritativeConversation(accountId, room);
    } on Exception {
      throw const ConversationTagsException(
        ConversationTagsError.invalidResponse,
      );
    }
    return room;
  }

  Future<_ConversationTagsContext> _context(String accountId) async {
    final account = await _accounts.getAccount(accountId);
    if (account == null) {
      throw const ConversationTagsException(
        ConversationTagsError.accountMissing,
      );
    }
    final appPassword = await _credentials.readAppPassword(accountId);
    if (appPassword == null) {
      throw const ConversationTagsException(
        ConversationTagsError.credentialMissing,
      );
    }
    return _ConversationTagsContext(account: account, appPassword: appPassword);
  }

  Future<ConversationTagsProfile> _freshProfile(
    _ConversationTagsContext context, {
    required bool loggedInParticipant,
  }) async {
    final read = await _call(
      () => _api.getAuthenticatedCapabilitiesWithSource(
        server: ServerBase.parse(context.account.serverUrl),
        loginName: context.account.loginName,
        appPassword: context.appPassword,
        forceRefresh: true,
      ),
    );
    final profile = ConversationTagsProfile.fromCapabilities(
      capabilities: read.snapshot,
      loggedInParticipant: loggedInParticipant,
    );
    if (!profile.canLoadDefinitions ||
        (loggedInParticipant && !profile.canAssign)) {
      throw const ConversationTagsException(ConversationTagsError.unsupported);
    }
    return profile;
  }

  Future<T> _call<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on NextcloudApiException catch (error) {
      throw ConversationTagsException(_mapApiError(error));
    } on TalkProtocolException {
      throw const ConversationTagsException(
        ConversationTagsError.invalidResponse,
      );
    }
  }
}

final class _ConversationTagsContext {
  const _ConversationTagsContext({
    required this.account,
    required this.appPassword,
  });

  final StoredAccount account;
  final String appPassword;
}

ConversationTagsError _mapApiError(NextcloudApiException error) {
  return switch (error.code) {
    NextcloudApiError.unexpectedStatus when error.statusCode == 401 =>
      ConversationTagsError.reauthenticationRequired,
    NextcloudApiError.network ||
    NextcloudApiError.timeout ||
    NextcloudApiError.cancelled => ConversationTagsError.network,
    _ => ConversationTagsError.invalidResponse,
  };
}

ConversationTagsError _mapHttpFailure(ConversationTagsHttpFailureKind kind) {
  return switch (kind) {
    ConversationTagsHttpFailureKind.rateLimited =>
      ConversationTagsError.rateLimited,
    ConversationTagsHttpFailureKind.serviceUnavailable =>
      ConversationTagsError.serviceUnavailable,
  };
}

final conversationTagsServiceProvider = Provider<ConversationTagsService>((
  ref,
) {
  return ConversationTagsService(
    accounts: ref.watch(accountRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    api: ref.watch(nextcloudApiProvider),
  );
});
