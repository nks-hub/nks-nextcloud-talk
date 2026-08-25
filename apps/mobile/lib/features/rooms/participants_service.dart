// ignore_for_file: prefer_initializing_formals

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import '../../data/account_repository.dart';
import '../../data/app_database.dart';
import '../../data/credential_vault.dart';
import '../../network/nextcloud_api.dart';

enum ParticipantsServiceError {
  accountMissing,
  credentialMissing,
  reauthenticationRequired,
  forbidden,
  roomMissing,

  /// The server refused the moderation change for this attendee, e.g.
  /// removing the last remaining moderator.
  rejected,
  rateLimited,
  serviceUnavailable,
  invalidResponse,
  network,
}

final class ParticipantsServiceException implements Exception {
  const ParticipantsServiceException(this.code);

  final ParticipantsServiceError code;

  @override
  String toString() => 'ParticipantsServiceException(${code.name})';
}

/// Reads a room's participant list and applies moderation changes to single
/// attendees, all scoped to one account. Every call is a direct, single
/// request; none of them retry or queue.
final class ParticipantsService {
  ParticipantsService({
    required AccountRepository accounts,
    required CredentialVault credentials,
    required HttpNextcloudApi api,
  }) : _accounts = accounts,
       _credentials = credentials,
       _api = api;

  final AccountRepository _accounts;
  final CredentialVault _credentials;
  final HttpNextcloudApi _api;

  Future<List<Participant>> fetchParticipants({
    required String accountId,
    required String roomToken,
  }) async {
    final (account, appPassword) = await _authContext(accountId);

    final ParticipantsRequest request;
    try {
      request = ParticipantsRequest(
        accountId: AccountId.parse(accountId),
        server: ServerBase.parse(account.serverUrl),
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
      );
    } on TalkProtocolException {
      throw const ParticipantsServiceException(
        ParticipantsServiceError.invalidResponse,
      );
    }

    final ParticipantsResponse response;
    try {
      response = await _api.getParticipants(
        participantsRequest: request,
        loginName: account.loginName,
        appPassword: appPassword,
      );
    } on NextcloudApiException catch (error) {
      throw ParticipantsServiceException(_mapApiError(error));
    } on TalkProtocolException {
      throw const ParticipantsServiceException(
        ParticipantsServiceError.invalidResponse,
      );
    }

    return switch (response) {
      ParticipantsSuccess(:final participants) => participants,
      ParticipantsReauthenticationRequired() =>
        throw const ParticipantsServiceException(
          ParticipantsServiceError.reauthenticationRequired,
        ),
      ParticipantsForbidden() => throw const ParticipantsServiceException(
        ParticipantsServiceError.forbidden,
      ),
      ParticipantsRoomMissing() => throw const ParticipantsServiceException(
        ParticipantsServiceError.roomMissing,
      ),
      ParticipantsHttpFailure(:final kind) =>
        throw ParticipantsServiceException(
          kind == ParticipantsHttpFailureKind.rateLimited
              ? ParticipantsServiceError.rateLimited
              : ParticipantsServiceError.serviceUnavailable,
        ),
    };
  }

  /// Promotes, demotes or removes one attendee. Moderator-only on the server;
  /// the caller is responsible for not offering the action to anyone else.
  Future<void> moderateParticipant({
    required String accountId,
    required String roomToken,
    required int attendeeId,
    required ParticipantModerationAction action,
  }) async {
    final (account, appPassword) = await _authContext(accountId);

    final ParticipantModerationRequest request;
    try {
      request = ParticipantModerationRequest(
        accountId: AccountId.parse(accountId),
        server: ServerBase.parse(account.serverUrl),
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
        attendeeId: attendeeId,
        action: action,
      );
    } on TalkProtocolException {
      throw const ParticipantsServiceException(
        ParticipantsServiceError.invalidResponse,
      );
    }

    final ParticipantModerationResponse response;
    try {
      response = await _api.moderateParticipant(
        moderationRequest: request,
        loginName: account.loginName,
        appPassword: appPassword,
      );
    } on NextcloudApiException catch (error) {
      throw ParticipantsServiceException(_mapApiError(error));
    } on TalkProtocolException {
      throw const ParticipantsServiceException(
        ParticipantsServiceError.invalidResponse,
      );
    }

    switch (response) {
      case ParticipantModerationSuccess():
        return;
      case ParticipantModerationRejected():
        throw const ParticipantsServiceException(
          ParticipantsServiceError.rejected,
        );
      case ParticipantModerationReauthenticationRequired():
        throw const ParticipantsServiceException(
          ParticipantsServiceError.reauthenticationRequired,
        );
      case ParticipantModerationForbidden():
        throw const ParticipantsServiceException(
          ParticipantsServiceError.forbidden,
        );
      case ParticipantModerationTargetMissing():
        throw const ParticipantsServiceException(
          ParticipantsServiceError.roomMissing,
        );
      case ParticipantModerationHttpFailure(:final kind):
        throw ParticipantsServiceException(
          kind == ParticipantsHttpFailureKind.rateLimited
              ? ParticipantsServiceError.rateLimited
              : ParticipantsServiceError.serviceUnavailable,
        );
    }
  }

  Future<(StoredAccount, String)> _authContext(String accountId) async {
    final account = await _accounts.getAccount(accountId);
    if (account == null) {
      throw const ParticipantsServiceException(
        ParticipantsServiceError.accountMissing,
      );
    }
    final appPassword = await _credentials.readAppPassword(accountId);
    if (appPassword == null) {
      throw const ParticipantsServiceException(
        ParticipantsServiceError.credentialMissing,
      );
    }
    return (account, appPassword);
  }

  ParticipantsServiceError _mapApiError(NextcloudApiException error) {
    return switch (error.code) {
      NextcloudApiError.network ||
      NextcloudApiError.timeout ||
      NextcloudApiError.cancelled => ParticipantsServiceError.network,
      _ => ParticipantsServiceError.invalidResponse,
    };
  }
}

final participantsServiceProvider = Provider<ParticipantsService>((ref) {
  return ParticipantsService(
    accounts: ref.watch(accountRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    api: ref.watch(nextcloudApiProvider),
  );
});
