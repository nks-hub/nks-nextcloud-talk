// ignore_for_file: prefer_initializing_formals

/// The administrator's view of the bots installed on one account's server.
///
/// Read-only on purpose. Talk's write routes for bots are per conversation and
/// belong to a moderator (see the bot section of the conversation details);
/// this exists to answer "which bot on this server is broken", which nothing
/// else in the app can answer at all.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import '../../data/account_repository.dart';
import '../../data/app_database.dart';
import '../../data/credential_vault.dart';
import '../../network/nextcloud_api.dart';

enum BotAdminError {
  accountMissing,
  credentialMissing,
  reauthenticationRequired,

  /// This account is not an administrator of its server. Not a malfunction:
  /// upstream answers `403` to every ordinary account by design.
  notAdministrator,

  /// The server does not publish the administrator bot list at all.
  unsupported,
  rateLimited,
  serviceUnavailable,
  invalidResponse,
  network,
}

final class BotAdminException implements Exception {
  const BotAdminException(this.code);

  final BotAdminError code;

  @override
  String toString() => 'BotAdminException(${code.name})';
}

/// One reading of the list: the bots, and whether the server held more than a
/// phone screen carries.
typedef BotAdminListing = ({List<AdminBot> bots, bool truncated});

/// Reads the server-wide bot list for a single account.
final class BotAdminService {
  BotAdminService({
    required AccountRepository accounts,
    required CredentialVault credentials,
    required HttpNextcloudApi api,
  }) : _accounts = accounts,
       _credentials = credentials,
       _api = api;

  final AccountRepository _accounts;
  final CredentialVault _credentials;
  final HttpNextcloudApi _api;

  /// Whether this account's server publishes the administrator bot list.
  ///
  /// Only the capability is asked, never the list itself: the capability is
  /// server-wide while the `403` is per account, so this says whether the
  /// entry point is worth offering, not whether this account may read it.
  /// Anything unknown counts as no, because an entry that can only ever answer
  /// "could not be read" is worse than no entry.
  Future<bool> supportsBotAdmin({required String accountId}) async {
    try {
      final context = await _authContext(accountId);
      final capabilities = await _api.getAuthenticatedCapabilities(
        server: context.server,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      );
      return capabilities.supportsTalk('bots-v1');
    } on Exception {
      return false;
    }
  }

  Future<BotAdminListing> listBots({
    required String accountId,
    Future<void>? abortTrigger,
  }) async {
    final context = await _authContext(accountId);
    final CapabilitySnapshot capabilities;
    try {
      capabilities = await _api.getAuthenticatedCapabilities(
        server: context.server,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
        abortTrigger: abortTrigger,
      );
    } on NextcloudApiException catch (error) {
      throw BotAdminException(_mapApiError(error));
    }
    final BotAdminListRequest request;
    try {
      request = BotAdminListRequest(
        accountId: AccountId.parse(accountId),
        server: context.server,
        capabilities: capabilities,
      );
    } on TalkProtocolException {
      // The only thing the builder validates beyond the fixed user agent is
      // the capability, so this is a server that does not offer the list.
      throw const BotAdminException(BotAdminError.unsupported);
    }
    final BotAdminListResponse response;
    try {
      response = await _api.listAdminBots(
        listRequest: request,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
        abortTrigger: abortTrigger,
      );
    } on NextcloudApiException catch (error) {
      throw BotAdminException(_mapApiError(error));
    } on TalkProtocolException {
      throw const BotAdminException(BotAdminError.invalidResponse);
    }
    return switch (response.outcome) {
      BotAdminOutcome.listed => (
        bots: response.bots,
        truncated: response.truncated,
      ),
      BotAdminOutcome.reauthenticationRequired => throw const BotAdminException(
        BotAdminError.reauthenticationRequired,
      ),
      BotAdminOutcome.forbidden => throw const BotAdminException(
        BotAdminError.notAdministrator,
      ),
      BotAdminOutcome.unsupported => throw const BotAdminException(
        BotAdminError.unsupported,
      ),
      BotAdminOutcome.rateLimited => throw const BotAdminException(
        BotAdminError.rateLimited,
      ),
      BotAdminOutcome.serverFailure => throw const BotAdminException(
        BotAdminError.serviceUnavailable,
      ),
    };
  }

  Future<_AuthContext> _authContext(String accountId) async {
    final account = await _accounts.getAccount(accountId);
    if (account == null) {
      throw const BotAdminException(BotAdminError.accountMissing);
    }
    final appPassword = await _credentials.readAppPassword(accountId);
    if (appPassword == null) {
      throw const BotAdminException(BotAdminError.credentialMissing);
    }
    final ServerBase server;
    try {
      server = ServerBase.parse(account.serverUrl);
    } on TalkProtocolException {
      throw const BotAdminException(BotAdminError.accountMissing);
    }
    return _AuthContext(
      account: account,
      appPassword: appPassword,
      server: server,
    );
  }

  BotAdminError _mapApiError(NextcloudApiException error) {
    return switch (error.code) {
      NextcloudApiError.unexpectedStatus when error.statusCode == 401 =>
        BotAdminError.reauthenticationRequired,
      NextcloudApiError.unexpectedStatus when error.statusCode == 429 =>
        BotAdminError.rateLimited,
      NextcloudApiError.network ||
      NextcloudApiError.timeout ||
      NextcloudApiError.cancelled => BotAdminError.network,
      _ => BotAdminError.invalidResponse,
    };
  }
}

final class _AuthContext {
  const _AuthContext({
    required this.account,
    required this.appPassword,
    required this.server,
  });

  final StoredAccount account;
  final String appPassword;
  final ServerBase server;
}

final botAdminServiceProvider = Provider<BotAdminService>((ref) {
  return BotAdminService(
    accounts: ref.watch(accountRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    api: ref.watch(nextcloudApiProvider),
  );
});

/// Whether the bot-health entry point belongs on the settings screen for this
/// account. Kept `autoDispose` so closing settings stops holding the answer.
final botAdminSupportedProvider = FutureProvider.autoDispose
    .family<bool, String>((ref, accountId) {
      return ref
          .watch(botAdminServiceProvider)
          .supportsBotAdmin(accountId: accountId);
    });

final botAdminListingProvider = FutureProvider.autoDispose
    .family<BotAdminListing, String>((ref, accountId) {
      return ref.watch(botAdminServiceProvider).listBots(accountId: accountId);
    });
