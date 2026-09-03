// ignore_for_file: prefer_initializing_formals

import 'package:talk_protocol/talk_protocol.dart';

import '../../data/account_repository.dart';
import '../../data/credential_vault.dart';
import '../../network/nextcloud_api.dart';

enum FederationInvitationError {
  accountMissing,
  credentialMissing,
  reauthenticationRequired,

  /// The server has no federation, or the invitation is gone.
  unavailable,
  network,
  serviceUnavailable,
  invalidResponse,
}

final class FederationInvitationException implements Exception {
  const FederationInvitationException(this.code);

  final FederationInvitationError code;

  @override
  String toString() => 'FederationInvitationException(${code.name})';
}

/// Lists and decides invitations into conversations hosted elsewhere.
///
/// Everything goes to the account's own server: it is the one that received
/// the invitation, holds the credentials and — on accept — creates the local
/// proxy room. The remote server named in an invitation is displayed, never
/// contacted.
final class FederationInvitationService {
  FederationInvitationService({
    required AccountRepository accounts,
    required CredentialVault credentials,
    required HttpNextcloudApi api,
  }) : _accounts = accounts,
       _credentials = credentials,
       _api = api;

  final AccountRepository _accounts;
  final CredentialVault _credentials;
  final HttpNextcloudApi _api;

  Future<List<FederationInvitation>> listPending(String accountId) async {
    final credentials = await _resolveCredentials(accountId);
    final FederationInvitationListResponse response;
    try {
      response = await _api.listFederationInvitations(
        listRequest: FederationInvitationListRequest(
          accountId: AccountId.parse(accountId),
          server: credentials.server,
        ),
        loginName: credentials.loginName,
        appPassword: credentials.appPassword,
      );
    } on NextcloudApiException {
      throw const FederationInvitationException(
        FederationInvitationError.network,
      );
    } on TalkProtocolException {
      throw const FederationInvitationException(
        FederationInvitationError.invalidResponse,
      );
    }
    return switch (response.outcome) {
      FederationInvitationOutcome.listed =>
        response.invitations
            .where((invitation) => invitation.isPending)
            .toList(growable: false),
      FederationInvitationOutcome.reauthenticationRequired =>
        throw const FederationInvitationException(
          FederationInvitationError.reauthenticationRequired,
        ),
      FederationInvitationOutcome.unavailable => const <FederationInvitation>[],
      FederationInvitationOutcome.transientError =>
        throw const FederationInvitationException(
          FederationInvitationError.serviceUnavailable,
        ),
    };
  }

  /// Accepts the invitation and returns the token of the local room the
  /// server created for it.
  Future<ConversationToken> accept({
    required String accountId,
    required int invitationId,
  }) async {
    final response = await _decide(
      accountId: accountId,
      invitationId: invitationId,
      accept: true,
    );
    final token = response.roomToken;
    if (token == null) {
      throw const FederationInvitationException(
        FederationInvitationError.invalidResponse,
      );
    }
    return token;
  }

  Future<void> reject({
    required String accountId,
    required int invitationId,
  }) async {
    await _decide(
      accountId: accountId,
      invitationId: invitationId,
      accept: false,
    );
  }

  Future<FederationInvitationDecisionResponse> _decide({
    required String accountId,
    required int invitationId,
    required bool accept,
  }) async {
    final credentials = await _resolveCredentials(accountId);
    final FederationInvitationDecisionResponse response;
    try {
      response = await _api.decideFederationInvitation(
        decisionRequest: FederationInvitationDecisionRequest(
          accountId: AccountId.parse(accountId),
          server: credentials.server,
          invitationId: invitationId,
          accept: accept,
        ),
        loginName: credentials.loginName,
        appPassword: credentials.appPassword,
      );
    } on NextcloudApiException {
      throw const FederationInvitationException(
        FederationInvitationError.network,
      );
    } on TalkProtocolException {
      throw const FederationInvitationException(
        FederationInvitationError.invalidResponse,
      );
    }
    return switch (response.outcome) {
      FederationInvitationDecisionOutcome.applied => response,
      FederationInvitationDecisionOutcome.notFound ||
      FederationInvitationDecisionOutcome.remoteGone ||
      FederationInvitationDecisionOutcome.rejected =>
        throw const FederationInvitationException(
          FederationInvitationError.unavailable,
        ),
      FederationInvitationDecisionOutcome.reauthenticationRequired =>
        throw const FederationInvitationException(
          FederationInvitationError.reauthenticationRequired,
        ),
      FederationInvitationDecisionOutcome.transientError =>
        throw const FederationInvitationException(
          FederationInvitationError.serviceUnavailable,
        ),
    };
  }

  Future<_AccountCredentials> _resolveCredentials(String accountId) async {
    final account = await _accounts.getAccount(accountId);
    if (account == null) {
      throw const FederationInvitationException(
        FederationInvitationError.accountMissing,
      );
    }
    final appPassword = await _credentials.readAppPassword(accountId);
    if (appPassword == null) {
      throw const FederationInvitationException(
        FederationInvitationError.credentialMissing,
      );
    }
    final ServerBase server;
    try {
      server = ServerBase.parse(account.serverUrl);
    } on TalkProtocolException {
      throw const FederationInvitationException(
        FederationInvitationError.accountMissing,
      );
    }
    return _AccountCredentials(
      server: server,
      loginName: account.loginName,
      appPassword: appPassword,
    );
  }
}

final class _AccountCredentials {
  const _AccountCredentials({
    required this.server,
    required this.loginName,
    required this.appPassword,
  });

  final ServerBase server;
  final String loginName;
  final String appPassword;
}
