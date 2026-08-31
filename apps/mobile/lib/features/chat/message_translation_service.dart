import 'dart:convert';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:uuid/uuid.dart';

import '../../data/account_repository.dart';
import '../../data/app_database.dart';
import '../../data/credential_vault.dart';
import '../../network/nextcloud_api.dart';

enum MessageTranslationError {
  accountMissing,
  conversationMissing,
  credentialMissing,
  unsupported,
  invalidInput,
  reauthenticationRequired,
  rateLimited,
  serviceUnavailable,
  invalidResponse,
  network,
  cancelled,
}

final class MessageTranslationException implements Exception {
  const MessageTranslationException(this.code);

  final MessageTranslationError code;

  @override
  String toString() => 'MessageTranslationException(${code.name})';
}

abstract interface class MessageTranslationService {
  Future<TranslationLanguagesResponse> languages({
    required String accountId,
    required String roomToken,
    Future<void>? abortTrigger,
  });

  Future<TranslateTextResponse> translate({
    required String accountId,
    required String roomToken,
    required String text,
    required String? fromLanguage,
    required String toLanguage,
    Future<void>? abortTrigger,
  });
}

final class HttpMessageTranslationService implements MessageTranslationService {
  factory HttpMessageTranslationService({
    required AccountRepository accounts,
    required CredentialVault credentials,
    required HttpNextcloudApi api,
    Uuid? uuid,
  }) => HttpMessageTranslationService._(
    accounts,
    credentials,
    api,
    uuid ?? const Uuid(),
  );

  HttpMessageTranslationService._(
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
  Future<TranslationLanguagesResponse> languages({
    required String accountId,
    required String roomToken,
    Future<void>? abortTrigger,
  }) async {
    final context = await _context(accountId, roomToken, abortTrigger);
    final request = TranslationLanguagesRequest(
      accountId: AccountId.parse(accountId),
      requestId: ChatRequestId.parse(_uuid.v4()),
      server: context.server,
      translationAvailable: true,
    );
    final response = await _call(
      () => _api.getTranslationLanguages(
        languagesRequest: request,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
        abortTrigger: abortTrigger,
      ),
    );
    _requireSuccess(response.classification);
    return response;
  }

  @override
  Future<TranslateTextResponse> translate({
    required String accountId,
    required String roomToken,
    required String text,
    required String? fromLanguage,
    required String toLanguage,
    Future<void>? abortTrigger,
  }) async {
    final context = await _context(accountId, roomToken, abortTrigger);
    final TranslateTextRequest request;
    try {
      request = TranslateTextRequest(
        accountId: AccountId.parse(accountId),
        requestId: ChatRequestId.parse(_uuid.v4()),
        server: context.server,
        translationAvailable: true,
        text: text,
        fromLanguage: fromLanguage,
        toLanguage: toLanguage,
      );
    } on TalkProtocolException {
      throw const MessageTranslationException(
        MessageTranslationError.invalidInput,
      );
    }
    final response = await _call(
      () => _api.translateText(
        translateRequest: request,
        loginName: context.account.loginName,
        appPassword: context.appPassword,
        abortTrigger: abortTrigger,
      ),
    );
    _requireSuccess(response.classification);
    return response;
  }

  Future<_MessageTranslationContext> _context(
    String accountId,
    String roomToken,
    Future<void>? abortTrigger,
  ) async {
    final account = await _accounts.getAccount(accountId);
    if (account == null) {
      throw const MessageTranslationException(
        MessageTranslationError.accountMissing,
      );
    }
    final conversation = await _accounts.getConversation(
      accountId: accountId,
      token: roomToken,
    );
    if (conversation == null) {
      throw const MessageTranslationException(
        MessageTranslationError.conversationMissing,
      );
    }
    final password = await _credentials.readAppPassword(accountId);
    if (password == null || password.isEmpty) {
      throw const MessageTranslationException(
        MessageTranslationError.credentialMissing,
      );
    }
    try {
      final server = ServerBase.parse(account.serverUrl);
      final room = ConversationRoom.fromJson(jsonDecode(conversation.rawJson));
      if (room.token.value != roomToken) {
        throw const MessageTranslationException(
          MessageTranslationError.invalidResponse,
        );
      }
      final capabilities = await _call(
        () => _api.getAuthenticatedCapabilities(
          server: server,
          loginName: account.loginName,
          appPassword: password,
          abortTrigger: abortTrigger,
        ),
      );
      if (!capabilities.chatTranslationAvailable) {
        throw const MessageTranslationException(
          MessageTranslationError.unsupported,
        );
      }
      return _MessageTranslationContext(
        account: account,
        appPassword: password,
        server: server,
      );
    } on FormatException {
      throw const MessageTranslationException(
        MessageTranslationError.invalidResponse,
      );
    } on TalkProtocolException {
      throw const MessageTranslationException(
        MessageTranslationError.invalidResponse,
      );
    }
  }

  Future<T> _call<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on NextcloudApiException catch (error) {
      throw MessageTranslationException(_apiError(error));
    } on TalkProtocolException {
      throw const MessageTranslationException(
        MessageTranslationError.invalidResponse,
      );
    }
  }

  void _requireSuccess(TranslationClassification classification) {
    if (classification == TranslationClassification.success) {
      return;
    }
    throw MessageTranslationException(switch (classification) {
      TranslationClassification.success =>
        MessageTranslationError.invalidResponse,
      TranslationClassification.invalidInput =>
        MessageTranslationError.invalidInput,
      TranslationClassification.reauthenticationRequired =>
        MessageTranslationError.reauthenticationRequired,
      TranslationClassification.unavailable =>
        MessageTranslationError.unsupported,
      TranslationClassification.rateLimited =>
        MessageTranslationError.rateLimited,
      TranslationClassification.serviceUnavailable =>
        MessageTranslationError.serviceUnavailable,
    });
  }
}

final class _MessageTranslationContext {
  const _MessageTranslationContext({
    required this.account,
    required this.appPassword,
    required this.server,
  });

  final StoredAccount account;
  final String appPassword;
  final ServerBase server;
}

MessageTranslationError _apiError(NextcloudApiException error) =>
    switch (error.code) {
      NextcloudApiError.cancelled => MessageTranslationError.cancelled,
      NextcloudApiError.network ||
      NextcloudApiError.timeout => MessageTranslationError.network,
      NextcloudApiError.unexpectedStatus when error.statusCode == 401 =>
        MessageTranslationError.reauthenticationRequired,
      NextcloudApiError.unexpectedStatus when error.statusCode == 429 =>
        MessageTranslationError.rateLimited,
      NextcloudApiError.unexpectedStatus
          when error.statusCode == 500 || error.statusCode == 503 =>
        MessageTranslationError.serviceUnavailable,
      _ => MessageTranslationError.invalidResponse,
    };
