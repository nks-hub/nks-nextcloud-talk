// ignore_for_file: prefer_initializing_formals

import 'package:talk_protocol/talk_protocol.dart';

import '../../data/account_repository.dart';
import '../../data/credential_vault.dart';
import '../../network/nextcloud_api.dart';

/// Removes one account and everything the device stored for it, and answers
/// whether there was anything to remove.
///
/// A function rather than the removal service itself: removing an account
/// reaches the call and sync services, and a sync is what asks for the check,
/// so holding that service here would close the loop at startup.
typedef AccountWipe = Future<bool> Function(String accountId);

/// What one wipe check did.
enum RemoteWipeResult {
  /// The server had nothing to wipe, or could not be asked right now. The
  /// account stays exactly as it was.
  kept,

  /// The account and everything the device stored for it are gone.
  wiped,
}

/// Carries out a wipe the server asked for.
///
/// Runs off the back of an authentication failure, because that is the moment
/// a wiped token first shows itself: the password stops working, and the
/// question "was it revoked, or was this device wiped?" has exactly one
/// answer, from `core/wipe/check`. Without it a wiped device would sit on a
/// full local copy of the account showing a sign-in prompt.
final class RemoteWipeService {
  const RemoteWipeService({
    required AccountRepository accounts,
    required CredentialVault credentials,
    required HttpNextcloudApi api,
    required AccountWipe removeAccount,
  }) : _accounts = accounts,
       _credentials = credentials,
       _api = api,
       _removeAccount = removeAccount;

  final AccountRepository _accounts;
  final CredentialVault _credentials;
  final HttpNextcloudApi _api;
  final AccountWipe _removeAccount;

  /// Wipes [accountId] if — and only if — the server says so.
  ///
  /// Anything else, including an unreachable server, a malformed answer or a
  /// missing credential, keeps the account: local data is never destroyed on
  /// an uncertain answer.
  Future<RemoteWipeResult> wipeIfRequested(String accountId) async {
    final account = await _accounts.getAccount(accountId);
    if (account == null) {
      return RemoteWipeResult.kept;
    }
    final String? appPassword;
    try {
      appPassword = await _credentials.readAppPassword(accountId);
    } on Object {
      return RemoteWipeResult.kept;
    }
    if (appPassword == null || appPassword.isEmpty) {
      return RemoteWipeResult.kept;
    }

    final RemoteWipeRequest check;
    try {
      check = RemoteWipeRequest(
        server: ServerBase.parse(account.serverUrl),
        step: RemoteWipeStep.check,
        appPassword: appPassword,
      );
    } on TalkProtocolException {
      return RemoteWipeResult.kept;
    }
    final RemoteWipeResponse answer;
    try {
      answer = await _api.remoteWipe(wipeRequest: check);
    } on Object {
      return RemoteWipeResult.kept;
    }
    if (answer.outcome != RemoteWipeOutcome.wipeRequested) {
      return RemoteWipeResult.kept;
    }

    if (!await _removeAccount(accountId)) {
      return RemoteWipeResult.kept;
    }
    // Reported only after the device really has nothing left, and best effort:
    // the wipe stands whether or not the server hears about it.
    try {
      await _api.remoteWipe(
        wipeRequest: RemoteWipeRequest(
          server: ServerBase.parse(account.serverUrl),
          step: RemoteWipeStep.success,
          appPassword: appPassword,
        ),
      );
    } on Object {
      // Nothing to recover: the local copy is already gone.
    }
    return RemoteWipeResult.wiped;
  }
}
