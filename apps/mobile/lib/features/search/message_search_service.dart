// ignore_for_file: prefer_initializing_formals

import 'package:talk_protocol/talk_protocol.dart';
import 'package:uuid/uuid.dart';

import '../../data/account_repository.dart';
import '../../data/credential_vault.dart';
import '../../network/nextcloud_api.dart';

enum MessageSearchError {
  accountMissing,
  credentialMissing,
  invalidSearchTerm,
  reauthenticationRequired,
  providerNotFound,
  transientError,
  ocsFailure,
  invalidResponse,
  network,
}

final class MessageSearchException implements Exception {
  const MessageSearchException(this.code);

  final MessageSearchError code;

  @override
  String toString() => 'MessageSearchException(${code.name})';
}

const int messageSearchDefaultLimit = 20;

typedef MessageSearchPage = ({
  List<MessageSearchResult> results,
  int? nextCursor,
});

/// Searches Talk messages, scoped to one account.
///
/// Passing [roomToken] searches that one conversation instead of all of them.
/// The request contract handles the two server scopes separately.
abstract interface class MessageSearchService {
  Future<Set<MessageSearchFilter>> supportedFilters({
    required String accountId,
    String? roomToken,
    Future<void>? abortTrigger,
  });

  Future<MessageSearchPage> search({
    required String accountId,
    required String term,
    String? roomToken,
    MessageSearchFilters filters = const MessageSearchFilters(),
    int limit = messageSearchDefaultLimit,
    int? cursor,
    Future<void>? abortTrigger,
  });
}

final class HttpMessageSearchService implements MessageSearchService {
  HttpMessageSearchService({
    required AccountRepository accounts,
    required CredentialVault credentials,
    required HttpNextcloudApi api,
    Uuid? uuid,
  }) : _accounts = accounts,
       _credentials = credentials,
       _api = api,
       _uuid = uuid ?? const Uuid();

  final AccountRepository _accounts;
  final CredentialVault _credentials;
  final HttpNextcloudApi _api;
  final Uuid _uuid;

  @override
  Future<Set<MessageSearchFilter>> supportedFilters({
    required String accountId,
    String? roomToken,
    Future<void>? abortTrigger,
  }) async {
    try {
      final credentials = await _resolveCredentials(accountId);
      return await _api.getMessageSearchFilterSupport(
        server: credentials.server,
        loginName: credentials.loginName,
        appPassword: credentials.appPassword,
        roomToken: roomToken == null
            ? null
            : ConversationToken.parse(roomToken, path: r'$.roomToken'),
        abortTrigger: abortTrigger,
      );
    } on NextcloudApiException {
      return const {};
    } on TalkProtocolException {
      return const {};
    } on MessageSearchException {
      return const {};
    }
  }

  @override
  Future<MessageSearchPage> search({
    required String accountId,
    required String term,
    String? roomToken,
    MessageSearchFilters filters = const MessageSearchFilters(),
    int limit = messageSearchDefaultLimit,
    int? cursor,
    Future<void>? abortTrigger,
  }) async {
    final trimmed = term.trim();
    if (trimmed.isEmpty && filters.isEmpty) {
      throw const MessageSearchException(MessageSearchError.invalidSearchTerm);
    }
    final credentials = await _resolveCredentials(accountId);

    final MessageSearchRequest request;
    try {
      request = MessageSearchRequest(
        accountId: AccountId.parse(accountId),
        requestId: SearchRequestId.parse(_uuid.v4()),
        server: credentials.server,
        scope: roomToken == null
            ? MessageSearchScope.global
            : MessageSearchScope.currentRoom,
        roomToken: roomToken == null
            ? null
            : ConversationToken.parse(roomToken, path: r'$.roomToken'),
        term: trimmed,
        filters: filters,
        limit: limit,
        cursor: cursor,
      );
    } on TalkProtocolException {
      throw const MessageSearchException(MessageSearchError.invalidSearchTerm);
    }

    final MessageSearchResponse response;
    try {
      response = await _api.searchMessages(
        searchRequest: request,
        loginName: credentials.loginName,
        appPassword: credentials.appPassword,
        abortTrigger: abortTrigger,
      );
    } on NextcloudApiException {
      throw const MessageSearchException(MessageSearchError.network);
    } on TalkProtocolException {
      throw const MessageSearchException(MessageSearchError.invalidResponse);
    }

    return switch (response.classification) {
      MessageSearchClassification.results ||
      MessageSearchClassification.empty => (
        results: response.results,
        nextCursor: response.nextCursor,
      ),
      MessageSearchClassification.reauthenticationRequired =>
        throw const MessageSearchException(
          MessageSearchError.reauthenticationRequired,
        ),
      MessageSearchClassification.providerNotFound =>
        throw const MessageSearchException(MessageSearchError.providerNotFound),
      MessageSearchClassification.transientError =>
        throw const MessageSearchException(MessageSearchError.transientError),
      MessageSearchClassification.ocsError =>
        throw const MessageSearchException(MessageSearchError.ocsFailure),
    };
  }

  Future<_AccountCredentials> _resolveCredentials(String accountId) async {
    final account = await _accounts.getAccount(accountId);
    if (account == null) {
      throw const MessageSearchException(MessageSearchError.accountMissing);
    }
    final String? appPassword;
    try {
      appPassword = await _credentials.readAppPassword(accountId);
    } on CredentialVaultTemporarilyUnavailable {
      throw const MessageSearchException(MessageSearchError.transientError);
    }
    if (appPassword == null) {
      throw const MessageSearchException(MessageSearchError.credentialMissing);
    }
    final ServerBase server;
    try {
      server = ServerBase.parse(account.serverUrl);
    } on TalkProtocolException {
      throw const MessageSearchException(MessageSearchError.accountMissing);
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
