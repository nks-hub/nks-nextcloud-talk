// ignore_for_file: prefer_initializing_formals

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import '../../data/account_repository.dart';
import '../../data/credential_vault.dart';
import '../../network/nextcloud_api.dart';

enum OwnTalkExtensionsError {
  accountMissing,
  credentialMissing,
  reauthenticationRequired,

  /// The server does not (or no longer) offer the extension.
  unavailable,
  network,
  invalidResponse,
}

final class OwnTalkExtensionsException implements Exception {
  const OwnTalkExtensionsException(this.code);

  final OwnTalkExtensionsError code;

  @override
  String toString() => 'OwnTalkExtensionsException(${code.name})';
}

/// What one extension call needs: the account's credentials and the verified
/// capability.
final class _Session {
  const _Session({
    required this.loginName,
    required this.appPassword,
    required this.server,
    required this.snapshot,
  });

  final String loginName;
  final String appPassword;
  final ServerBase server;
  final CapabilitySnapshot snapshot;
}

/// Talks to the optional OwnTalk Extensions server app for one account.
///
/// Every call first reads the authenticated capabilities (cached by the API
/// client), so an endpoint is never requested from a server that did not
/// announce the extension.
final class OwnTalkExtensionsService {
  OwnTalkExtensionsService({
    required AccountRepository accounts,
    required CredentialVault credentials,
    required HttpNextcloudApi api,
  }) : _accounts = accounts,
       _credentials = credentials,
       _api = api;

  final AccountRepository _accounts;
  final CredentialVault _credentials;
  final HttpNextcloudApi _api;

  /// The extension capability of the account's server, or `null` when the
  /// server does not offer it. Throws only when the capabilities could not be
  /// read at all.
  Future<OwnTalkExtensionsCapability?> capability(String accountId) async {
    final session = await _session(accountId);
    return session.snapshot.ownTalkExtensions;
  }

  /// Fetches the settings document, sending `If-None-Match` when
  /// [knownRevision] is set.
  Future<OwnTalkSettingsFetchResult> fetch({
    required String accountId,
    required String roomToken,
    int? knownRevision,
  }) async {
    final session = await _availableSession(accountId);
    final FetchOwnTalkRoomSettingsRequest request;
    try {
      request = FetchOwnTalkRoomSettingsRequest(
        accountId: AccountId.parse(accountId),
        server: session.server,
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
        capabilities: session.snapshot,
        knownRevision: knownRevision,
      );
    } on TalkProtocolException {
      throw const OwnTalkExtensionsException(
        OwnTalkExtensionsError.invalidResponse,
      );
    }
    return _call(
      () => _api.fetchOwnTalkRoomSettings(
        settingsRequest: request,
        loginName: session.loginName,
        appPassword: session.appPassword,
      ),
    );
  }

  /// Applies a merge patch on top of [baseRevision].
  Future<OwnTalkSettingsUpdateResult> update({
    required String accountId,
    required String roomToken,
    required Map<OwnTalkSettingField, String?> changes,
    required int baseRevision,
  }) async {
    final session = await _availableSession(accountId);
    final UpdateOwnTalkRoomSettingsRequest request;
    try {
      request = UpdateOwnTalkRoomSettingsRequest(
        accountId: AccountId.parse(accountId),
        server: session.server,
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
        capabilities: session.snapshot,
        changes: changes,
        baseRevision: baseRevision,
      );
    } on TalkProtocolException {
      throw const OwnTalkExtensionsException(
        OwnTalkExtensionsError.invalidResponse,
      );
    }
    return _call(
      () => _api.updateOwnTalkRoomSettings(
        settingsRequest: request,
        loginName: session.loginName,
        appPassword: session.appPassword,
      ),
    );
  }

  Future<_Session> _availableSession(String accountId) async {
    final session = await _session(accountId);
    if (session.snapshot.ownTalkExtensions == null) {
      throw const OwnTalkExtensionsException(
        OwnTalkExtensionsError.unavailable,
      );
    }
    return session;
  }

  Future<_Session> _session(String accountId) async {
    final account = await _accounts.getAccount(accountId);
    if (account == null) {
      throw const OwnTalkExtensionsException(
        OwnTalkExtensionsError.accountMissing,
      );
    }
    final appPassword = await _credentials.readAppPassword(accountId);
    if (appPassword == null) {
      throw const OwnTalkExtensionsException(
        OwnTalkExtensionsError.credentialMissing,
      );
    }
    final ServerBase server;
    try {
      server = ServerBase.parse(account.serverUrl);
    } on TalkProtocolException {
      throw const OwnTalkExtensionsException(
        OwnTalkExtensionsError.invalidResponse,
      );
    }
    final snapshot = await _call(
      () => _api.getAuthenticatedCapabilities(
        server: server,
        loginName: account.loginName,
        appPassword: appPassword,
      ),
    );
    return _Session(
      loginName: account.loginName,
      appPassword: appPassword,
      server: server,
      snapshot: snapshot,
    );
  }

  Future<T> _call<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on NextcloudApiException catch (error) {
      throw OwnTalkExtensionsException(switch (error.code) {
        NextcloudApiError.unexpectedStatus when error.statusCode == 401 =>
          OwnTalkExtensionsError.reauthenticationRequired,
        NextcloudApiError.network ||
        NextcloudApiError.timeout ||
        NextcloudApiError.cancelled => OwnTalkExtensionsError.network,
        _ => OwnTalkExtensionsError.invalidResponse,
      });
    } on TalkProtocolException {
      throw const OwnTalkExtensionsException(
        OwnTalkExtensionsError.invalidResponse,
      );
    }
  }
}

final ownTalkExtensionsServiceProvider = Provider<OwnTalkExtensionsService>((
  ref,
) {
  return OwnTalkExtensionsService(
    accounts: ref.watch(accountRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    api: ref.watch(nextcloudApiProvider),
  );
});
