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

/// Searches Talk messages, scoped to one account.
///
/// Passing [roomToken] searches that one conversation instead of all of them.
/// Both scopes are verified against a live Talk 24.0.2 server; the wire
/// details and why the two must not be mixed are on
/// `MessageSearchRequest._fromRoute`.
abstract interface class MessageSearchService {
  Future<List<MessageSearchResult>> search({
    required String accountId,
    required String term,
    String? roomToken,
    int limit = messageSearchDefaultLimit,
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
  Future<List<MessageSearchResult>> search({
    required String accountId,
    required String term,
    String? roomToken,
    int limit = messageSearchDefaultLimit,
  }) async {
    final trimmed = term.trim();
    if (trimmed.isEmpty) {
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
        limit: limit,
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
      );
    } on NextcloudApiException {
      throw const MessageSearchException(MessageSearchError.network);
    } on TalkProtocolException {
      throw const MessageSearchException(MessageSearchError.invalidResponse);
    }

    return switch (response.classification) {
      MessageSearchClassification.results ||
      MessageSearchClassification.empty => response.results,
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
    final appPassword = await _credentials.readAppPassword(accountId);
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
