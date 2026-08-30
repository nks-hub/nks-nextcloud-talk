// ignore_for_file: prefer_initializing_formals

import 'package:talk_protocol/talk_protocol.dart';
import 'package:uuid/uuid.dart';

import '../../data/account_repository.dart';
import '../../data/credential_vault.dart';
import '../../network/nextcloud_api.dart';

enum NewConversationError {
  accountMissing,
  credentialMissing,
  invalidSearchTerm,
  roomNameRequired,
  reauthenticationRequired,
  ocsFailure,
  rateLimited,
  serviceUnavailable,
  invalidResponse,
  network,
}

enum StandaloneConversationType { group, public }

final class NewConversationException implements Exception {
  const NewConversationException(this.code);

  final NewConversationError code;

  @override
  String toString() => 'NewConversationException(${code.name})';
}

/// Looks up recipients and creates conversations, scoped to one account.
abstract interface class NewConversationService {
  Future<List<ConversationRecipient>> searchRecipients({
    required String accountId,
    required String searchTerm,
  });

  /// Creates a conversation for [recipient]. [roomName] is required when
  /// [recipient] is a group and ignored otherwise.
  Future<ConversationToken> createConversation({
    required String accountId,
    required ConversationRecipient recipient,
    String? roomName,
  });

  Future<ConversationToken> createStandaloneConversation({
    required String accountId,
    required StandaloneConversationType type,
    required String roomName,
  });

  /// Returns the one-to-one conversation with [userId], creating it when it
  /// does not exist yet.
  ///
  /// Talk's create-room endpoint is get-or-create for one-to-one rooms: given
  /// the same invitee it answers with the existing room instead of a second
  /// one. Callers that only hold a user id — a private reply knows the author
  /// of a message, not a recipient search result — use this instead of
  /// [createConversation], whose [ConversationRecipient] cannot be built
  /// outside a search response.
  Future<ConversationToken> createOneToOneWithUser({
    required String accountId,
    required String userId,
  });
}

final class HttpNewConversationService implements NewConversationService {
  HttpNewConversationService({
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
  Future<List<ConversationRecipient>> searchRecipients({
    required String accountId,
    required String searchTerm,
  }) async {
    if (searchTerm.trim().isEmpty) {
      throw const NewConversationException(
        NewConversationError.invalidSearchTerm,
      );
    }
    final credentials = await _resolveCredentials(accountId);

    final RecipientSearchRequest request;
    try {
      request = RecipientSearchRequest(
        accountId: AccountId.parse(accountId),
        server: credentials.server,
        searchTerm: searchTerm.trim(),
      );
    } on TalkProtocolException {
      throw const NewConversationException(
        NewConversationError.invalidSearchTerm,
      );
    }

    final RecipientSearchResponse response;
    try {
      response = await _api.searchRecipients(
        searchRequest: request,
        loginName: credentials.loginName,
        appPassword: credentials.appPassword,
      );
    } on NextcloudApiException {
      throw const NewConversationException(NewConversationError.network);
    } on TalkProtocolException {
      throw const NewConversationException(
        NewConversationError.invalidResponse,
      );
    }

    return switch (response) {
      RecipientSearchSuccess(:final recipients) => recipients,
      RecipientSearchReauthenticationRequired() =>
        throw const NewConversationException(
          NewConversationError.reauthenticationRequired,
        ),
      RecipientSearchOcsFailure() => throw const NewConversationException(
        NewConversationError.ocsFailure,
      ),
    };
  }

  @override
  Future<ConversationToken> createConversation({
    required String accountId,
    required ConversationRecipient recipient,
    String? roomName,
  }) async {
    if (recipient.shareType == RecipientShareType.group &&
        (roomName == null || roomName.trim().isEmpty)) {
      throw const NewConversationException(
        NewConversationError.roomNameRequired,
      );
    }
    final credentials = await _resolveCredentials(accountId);

    final CreateConversationRequest request;
    try {
      request = CreateConversationRequest(
        accountId: AccountId.parse(accountId),
        requestId: ConversationRequestId.parse(_uuid.v4()),
        server: credentials.server,
        roomType: switch (recipient.shareType) {
          RecipientShareType.user => CreateConversationRoomType.oneToOne,
          RecipientShareType.group => CreateConversationRoomType.group,
        },
        inviteId: recipient.id,
        inviteSource: switch (recipient.shareType) {
          RecipientShareType.user => 'users',
          RecipientShareType.group => 'groups',
        },
        roomName: recipient.shareType == RecipientShareType.group
            ? roomName!.trim()
            : null,
      );
    } on TalkProtocolException {
      throw const NewConversationException(
        NewConversationError.roomNameRequired,
      );
    }

    return _createRoom(request, credentials);
  }

  @override
  Future<ConversationToken> createStandaloneConversation({
    required String accountId,
    required StandaloneConversationType type,
    required String roomName,
  }) async {
    final name = roomName.trim();
    if (name.isEmpty) {
      throw const NewConversationException(
        NewConversationError.roomNameRequired,
      );
    }
    final credentials = await _resolveCredentials(accountId);
    final CreateConversationRequest request;
    try {
      request = CreateConversationRequest(
        accountId: AccountId.parse(accountId),
        requestId: ConversationRequestId.parse(_uuid.v4()),
        server: credentials.server,
        roomType: switch (type) {
          StandaloneConversationType.group => CreateConversationRoomType.group,
          StandaloneConversationType.public =>
            CreateConversationRoomType.public,
        },
        roomName: name,
      );
    } on TalkProtocolException {
      throw const NewConversationException(
        NewConversationError.roomNameRequired,
      );
    }
    return _createRoom(request, credentials);
  }

  @override
  Future<ConversationToken> createOneToOneWithUser({
    required String accountId,
    required String userId,
  }) async {
    if (userId.trim().isEmpty) {
      throw const NewConversationException(
        NewConversationError.invalidResponse,
      );
    }
    final credentials = await _resolveCredentials(accountId);
    final CreateConversationRequest request;
    try {
      request = CreateConversationRequest(
        accountId: AccountId.parse(accountId),
        requestId: ConversationRequestId.parse(_uuid.v4()),
        server: credentials.server,
        roomType: CreateConversationRoomType.oneToOne,
        inviteId: userId,
        inviteSource: 'users',
        roomName: null,
      );
    } on TalkProtocolException {
      throw const NewConversationException(
        NewConversationError.invalidResponse,
      );
    }
    return _createRoom(request, credentials);
  }

  Future<ConversationToken> _createRoom(
    CreateConversationRequest request,
    _AccountCredentials credentials,
  ) async {
    final CreateConversationResponse response;
    try {
      response = await _api.createConversation(
        createRequest: request,
        loginName: credentials.loginName,
        appPassword: credentials.appPassword,
      );
    } on NextcloudApiException {
      throw const NewConversationException(NewConversationError.network);
    } on TalkProtocolException {
      throw const NewConversationException(
        NewConversationError.invalidResponse,
      );
    }

    return switch (response) {
      CreateConversationSuccess(:final room) => room.token,
      CreateConversationReauthenticationRequired() =>
        throw const NewConversationException(
          NewConversationError.reauthenticationRequired,
        ),
      CreateConversationOcsFailure() => throw const NewConversationException(
        NewConversationError.ocsFailure,
      ),
      CreateConversationHttpFailure(:final kind) =>
        throw NewConversationException(switch (kind) {
          CreateConversationHttpFailureKind.rateLimited =>
            NewConversationError.rateLimited,
          CreateConversationHttpFailureKind.serviceUnavailable =>
            NewConversationError.serviceUnavailable,
        }),
    };
  }

  Future<_AccountCredentials> _resolveCredentials(String accountId) async {
    final account = await _accounts.getAccount(accountId);
    if (account == null) {
      throw const NewConversationException(NewConversationError.accountMissing);
    }
    final appPassword = await _credentials.readAppPassword(accountId);
    if (appPassword == null) {
      throw const NewConversationException(
        NewConversationError.credentialMissing,
      );
    }
    final ServerBase server;
    try {
      server = ServerBase.parse(account.serverUrl);
    } on TalkProtocolException {
      throw const NewConversationException(NewConversationError.accountMissing);
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
