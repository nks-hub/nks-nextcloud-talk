// ignore_for_file: prefer_initializing_formals

import 'package:talk_protocol/talk_protocol.dart';
import 'package:uuid/uuid.dart';

import '../../data/account_repository.dart';
import '../../data/credential_vault.dart';
import '../../network/nextcloud_api.dart';

typedef CallRoomKey = ({String accountId, String roomToken});

/// What the server says about how a room's call would be signalled, or why
/// that could not be established.
enum CallTransport {
  /// Signalling runs through the Nextcloud server itself.
  internal,

  /// Signalling runs through an external High Performance Backend.
  externalHpb,

  /// The stored credentials no longer authenticate against the server.
  reauthenticationRequired,

  /// The room is gone or no longer readable for this account.
  roomUnavailable,

  /// The server did not answer usefully; a later retry may.
  unavailable,
}

/// Resolves the signalling transport of a room's call.
///
/// This is the first REST step of any call and stays deliberately separate
/// from media handling: it answers "how would this call be signalled", not
/// "join it". Media (WebRTC) is not implemented yet, so the only consumer is
/// the ongoing-call banner, which uses the answer to decide whether joining
/// can be offered at all.
final class CallTransportService {
  CallTransportService({
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

  Future<CallTransport> resolve({
    required String accountId,
    required String roomToken,
  }) async {
    final account = await _accounts.getAccount(accountId);
    if (account == null) {
      return CallTransport.unavailable;
    }
    final appPassword = await _credentials.readAppPassword(accountId);
    if (appPassword == null) {
      return CallTransport.reauthenticationRequired;
    }

    final SignalingSettingsRequest request;
    try {
      request = SignalingSettingsRequest(
        context: SignalingRequestContext(
          accountId: AccountId.parse(accountId),
          requestId: SignalingRequestId.parse(_uuid.v4()),
          server: ServerBase.parse(account.serverUrl),
          roomToken: ConversationToken.parse(roomToken, path: r'$.roomToken'),
          // No signalling connection is opened here, so both epochs stay at
          // their pre-connection value and the revision is a constant.
          credentialGeneration: 1,
          capabilityGeneration: 1,
          settingsRevision: 'banner',
          connectionEpoch: 0,
          roomEpoch: 0,
        ),
      );
    } on TalkProtocolException {
      return CallTransport.unavailable;
    }

    final SignalingSettingsResponse response;
    try {
      response = await _api.getSignalingSettings(
        settingsRequest: request,
        loginName: account.loginName,
        appPassword: appPassword,
      );
    } on NextcloudApiException {
      return CallTransport.unavailable;
    } on TalkProtocolException {
      return CallTransport.unavailable;
    }

    return switch (response.classification) {
      SignalingSettingsClassification.confirmed => switch (response
          .settings
          ?.transport) {
        SignalingTransportKind.internal => CallTransport.internal,
        SignalingTransportKind.externalHpb => CallTransport.externalHpb,
        null => CallTransport.unavailable,
      },
      SignalingSettingsClassification.reauthenticationRequired =>
        CallTransport.reauthenticationRequired,
      SignalingSettingsClassification.roomRefreshRequired =>
        CallTransport.roomUnavailable,
      SignalingSettingsClassification.serverError => CallTransport.unavailable,
    };
  }
}
