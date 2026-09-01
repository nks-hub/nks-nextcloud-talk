import 'package:talk_protocol/talk_protocol.dart';

import '../../data/account_repository.dart';
import '../../data/app_database.dart';
import '../../data/credential_vault.dart';
import '../../network/nextcloud_api.dart';

enum RemoteFileError {
  accountMissing,
  credentialMissing,
  reauthenticationRequired,

  /// The directory or file is gone, or this account may not read it.
  unavailable,

  /// The account may not share this file into this conversation.
  forbidden,

  serviceUnavailable,
  invalidInput,
  invalidResponse,
  network,
  cancelled,
}

final class RemoteFileException implements Exception {
  const RemoteFileException(this.code);

  final RemoteFileError code;

  @override
  String toString() => 'RemoteFileException(${code.name})';
}

/// Browses the account's own Nextcloud files and shares one into a room.
///
/// Sharing is deliberately not an upload: the file stays on the server and the
/// participants get the one that is already there, so nothing is copied and no
/// second version can drift from the original.
abstract interface class RemoteFileShareService {
  Future<RemoteDirectoryListing> listDirectory({
    required String accountId,
    required String path,
    Future<void>? abortTrigger,
  });

  Future<void> shareIntoRoom({
    required String accountId,
    required String roomToken,
    required String path,
    Future<void>? abortTrigger,
  });
}

final class HttpRemoteFileShareService implements RemoteFileShareService {
  factory HttpRemoteFileShareService({
    required AccountRepository accounts,
    required CredentialVault credentials,
    required HttpNextcloudApi api,
  }) => HttpRemoteFileShareService._(accounts, credentials, api);

  const HttpRemoteFileShareService._(
    this._accounts,
    this._credentials,
    this._api,
  );

  final AccountRepository _accounts;
  final CredentialVault _credentials;
  final HttpNextcloudApi _api;

  @override
  Future<RemoteDirectoryListing> listDirectory({
    required String accountId,
    required String path,
    Future<void>? abortTrigger,
  }) async {
    final context = await _context(accountId);
    final RemoteDirectoryRequest request;
    try {
      request = RemoteDirectoryRequest(
        accountId: AccountId.parse(accountId),
        server: context.server,
        loginName: context.account.loginName,
        path: path,
      );
    } on TalkProtocolException {
      throw const RemoteFileException(RemoteFileError.invalidInput);
    }
    final response = await _call(
      () => _api.listRemoteDirectory(
        directoryRequest: request,
        appPassword: context.appPassword,
        abortTrigger: abortTrigger,
      ),
    );
    return switch (response.outcome) {
      RemoteDirectoryOutcome.listed => response.listing!,
      RemoteDirectoryOutcome.reauthenticationRequired =>
        throw const RemoteFileException(
          RemoteFileError.reauthenticationRequired,
        ),
      RemoteDirectoryOutcome.unavailable => throw const RemoteFileException(
        RemoteFileError.unavailable,
      ),
      RemoteDirectoryOutcome.transientError => throw const RemoteFileException(
        RemoteFileError.serviceUnavailable,
      ),
    };
  }

  @override
  Future<void> shareIntoRoom({
    required String accountId,
    required String roomToken,
    required String path,
    Future<void>? abortTrigger,
  }) async {
    final context = await _context(accountId);
    final RemoteFileShareRequest request;
    try {
      request = RemoteFileShareRequest(
        accountId: AccountId.parse(accountId),
        server: context.server,
        roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
        path: path,
      );
    } on TalkProtocolException {
      throw const RemoteFileException(RemoteFileError.invalidInput);
    }
    final response = await _call(
      () => _api.shareRemoteFile(
        shareRequest: request,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
        abortTrigger: abortTrigger,
      ),
    );
    switch (response.outcome) {
      case RemoteFileShareOutcome.shared:
        return;
      case RemoteFileShareOutcome.reauthenticationRequired:
        throw const RemoteFileException(
          RemoteFileError.reauthenticationRequired,
        );
      case RemoteFileShareOutcome.forbidden:
        throw const RemoteFileException(RemoteFileError.forbidden);
      case RemoteFileShareOutcome.notFound:
        throw const RemoteFileException(RemoteFileError.unavailable);
      case RemoteFileShareOutcome.transientError:
        throw const RemoteFileException(RemoteFileError.serviceUnavailable);
    }
  }

  Future<_RemoteFileContext> _context(String accountId) async {
    final account = await _accounts.getAccount(accountId);
    if (account == null) {
      throw const RemoteFileException(RemoteFileError.accountMissing);
    }
    final password = await _credentials.readAppPassword(accountId);
    if (password == null || password.isEmpty) {
      throw const RemoteFileException(RemoteFileError.credentialMissing);
    }
    try {
      return _RemoteFileContext(
        account: account,
        appPassword: password,
        server: ServerBase.parse(account.serverUrl),
      );
    } on TalkProtocolException {
      throw const RemoteFileException(RemoteFileError.invalidResponse);
    }
  }

  Future<T> _call<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on NextcloudApiException catch (error) {
      throw RemoteFileException(switch (error.code) {
        NextcloudApiError.cancelled => RemoteFileError.cancelled,
        NextcloudApiError.timeout ||
        NextcloudApiError.network => RemoteFileError.network,
        _ => RemoteFileError.invalidResponse,
      });
    } on TalkProtocolException {
      throw const RemoteFileException(RemoteFileError.invalidResponse);
    }
  }
}

final class _RemoteFileContext {
  const _RemoteFileContext({
    required this.account,
    required this.appPassword,
    required this.server,
  });

  final StoredAccount account;
  final String appPassword;
  final ServerBase server;
}
