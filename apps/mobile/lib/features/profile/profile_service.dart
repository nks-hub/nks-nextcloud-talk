import 'package:talk_protocol/talk_protocol.dart';

import '../../data/account_repository.dart';
import '../../data/app_database.dart';
import '../../data/credential_vault.dart';
import '../../network/nextcloud_api.dart';
import 'profile_models.dart';

final class ProfileService {
  const ProfileService(this._accounts, this._credentials, this._api);

  final AccountRepository _accounts;
  final CredentialVault _credentials;
  final HttpNextcloudApi _api;

  Future<OwnProfileSnapshot> load(String accountId) async {
    final context = await _context(accountId);
    final capability = await _statusCapability(context);
    final profile = await _call(
      () => _api.getOwnProfile(
        server: context.server,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
      ),
    );
    _requireIdentity(context, profile.userId);

    OwnUserStatusResponse? status;
    if (capability.enabled) {
      final loadedStatus = await _call(
        () => _api.getOwnUserStatus(
          server: context.server,
          loginName: context.account.loginName,
          appPassword: context.appPassword,
        ),
      );
      _requireIdentity(context, loadedStatus.userId);
      status = loadedStatus;
    }

    return OwnProfileSnapshot(
      accountId: accountId,
      serverUrl: context.account.serverUrl,
      loginName: context.account.loginName,
      profile: profile,
      statusCapability: capability,
      status: status,
    );
  }

  Future<OwnUserStatusResponse> setStatusType({
    required String accountId,
    required OwnUserStatusType status,
  }) async {
    final context = await _statusContext(accountId);
    if (!context.capability.permits(status)) {
      throw const OwnProfileException(OwnProfileError.unsupported);
    }
    final response = await _call(
      () => _api.setOwnUserStatusType(
        server: context.base.server,
        loginName: context.base.account.loginName,
        appPassword: context.base.appPassword,
        status: status,
      ),
    );
    _requireIdentity(context.base, response.userId);
    return response;
  }

  Future<OwnUserStatusResponse> setCustomMessage({
    required String accountId,
    required String message,
    String? statusIcon,
    StatusExpiry expiry = StatusExpiry.never,
    DateTime? now,
  }) async {
    final normalizedMessage = message.trim();
    final normalizedIcon = statusIcon?.trim();
    if (normalizedMessage.runes.length > 80 ||
        (normalizedIcon != null && normalizedIcon.runes.length > 16)) {
      throw const OwnProfileException(OwnProfileError.invalidInput);
    }
    if (normalizedMessage.isEmpty &&
        (normalizedIcon == null || normalizedIcon.isEmpty)) {
      return clearMessage(accountId);
    }

    final context = await _statusContext(accountId);
    final response = await _call(
      () => _api.setOwnCustomStatusMessage(
        server: context.base.server,
        loginName: context.base.account.loginName,
        appPassword: context.base.appPassword,
        message: normalizedMessage,
        statusIcon: normalizedIcon?.isEmpty == true ? null : normalizedIcon,
        clearAt: expiry.clearAt(now ?? DateTime.now()),
      ),
    );
    _requireIdentity(context.base, response.userId);
    return response;
  }

  Future<OwnUserStatusResponse> clearMessage(String accountId) async {
    final context = await _statusContext(accountId);
    await _call(
      () => _api.clearOwnUserStatusMessage(
        server: context.base.server,
        loginName: context.base.account.loginName,
        appPassword: context.base.appPassword,
      ),
    );
    final status = await _call(
      () => _api.getOwnUserStatus(
        server: context.base.server,
        loginName: context.base.account.loginName,
        appPassword: context.base.appPassword,
      ),
    );
    _requireIdentity(context.base, status.userId);
    return status;
  }

  Future<_ProfileContext> _context(String accountId) async {
    final account = await _accounts.getAccount(accountId);
    if (account == null) {
      throw const OwnProfileException(OwnProfileError.accountMissing);
    }
    final appPassword = await _credentials.readAppPassword(accountId);
    if (appPassword == null) {
      throw const OwnProfileException(OwnProfileError.credentialMissing);
    }
    try {
      return _ProfileContext(
        account: account,
        appPassword: appPassword,
        server: ServerBase.parse(account.serverUrl),
      );
    } on TalkProtocolException {
      throw const OwnProfileException(OwnProfileError.invalidResponse);
    }
  }

  Future<ProfileStatusCapability> _statusCapability(
    _ProfileContext context,
  ) async {
    final read = await _call(
      () => _api.getAuthenticatedCapabilitiesWithSource(
        server: context.server,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
        forceRefresh: true,
      ),
    );
    return ProfileStatusCapability.fromSnapshot(read.snapshot);
  }

  Future<_ProfileStatusContext> _statusContext(String accountId) async {
    final context = await _context(accountId);
    final capability = await _statusCapability(context);
    if (!capability.enabled) {
      throw const OwnProfileException(OwnProfileError.unsupported);
    }
    return _ProfileStatusContext(base: context, capability: capability);
  }

  void _requireIdentity(_ProfileContext context, String userId) {
    if (userId != context.account.loginName) {
      throw const OwnProfileException(OwnProfileError.invalidResponse);
    }
  }

  Future<T> _call<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on NextcloudApiException catch (error) {
      throw OwnProfileException(_mapApiError(error));
    } on TalkProtocolException {
      throw const OwnProfileException(OwnProfileError.invalidResponse);
    }
  }
}

final class _ProfileContext {
  const _ProfileContext({
    required this.account,
    required this.appPassword,
    required this.server,
  });

  final StoredAccount account;
  final String appPassword;
  final ServerBase server;
}

final class _ProfileStatusContext {
  const _ProfileStatusContext({required this.base, required this.capability});

  final _ProfileContext base;
  final ProfileStatusCapability capability;
}

OwnProfileError _mapApiError(NextcloudApiException error) {
  return switch (error.code) {
    NextcloudApiError.unexpectedStatus when error.statusCode == 400 =>
      OwnProfileError.invalidInput,
    NextcloudApiError.unexpectedStatus when error.statusCode == 401 =>
      OwnProfileError.reauthenticationRequired,
    NextcloudApiError.unexpectedStatus when error.statusCode == 403 =>
      OwnProfileError.forbidden,
    NextcloudApiError.unexpectedStatus when error.statusCode == 429 =>
      OwnProfileError.rateLimited,
    NextcloudApiError.unexpectedStatus
        when error.statusCode == 500 || error.statusCode == 503 =>
      OwnProfileError.serviceUnavailable,
    NextcloudApiError.network ||
    NextcloudApiError.timeout ||
    NextcloudApiError.cancelled => OwnProfileError.network,
    _ => OwnProfileError.invalidResponse,
  };
}
