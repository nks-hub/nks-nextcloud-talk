// ignore_for_file: prefer_initializing_formals

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../data/account_repository.dart';
import '../../data/chat_media_cache.dart';
import '../../data/credential_vault.dart';
import '../../network/nextcloud_api.dart';
import '../../platform/media/durable_attachment_source_store.dart';
import '../chat/composer/emoji_usage_store.dart';
import '../chat/media/chat_attachment_opener.dart';

typedef AccountRemovalStarted = Future<void> Function(String accountId);
typedef AccountPushRevocation = Future<bool> Function(String accountId);
typedef AccountBackgroundCleanup = Future<void> Function(String accountId);

/// What a finished removal managed to do on the server.
///
/// The local wipe is unconditional, so there is no failure state for it: if
/// [AccountRemovalService.removeAccount] returns, nothing of the account is
/// left on the device.
@immutable
final class AccountRemovalOutcome {
  const AccountRemovalOutcome({
    required this.accountExisted,
    required this.pushRegistrationRevoked,
    required this.appPasswordRevoked,
  });

  /// False when the account was already gone, for example because a second
  /// tap arrived while the first removal was still running.
  final bool accountExisted;

  /// False when proxy push cleanup remains retryable or failed. The local
  /// wipe still completes, but the caller must not report a clean remote
  /// removal while the account-scoped cleanup state is unresolved.
  final bool pushRegistrationRevoked;

  /// False whenever the server did not confirm the app password is destroyed:
  /// offline, unreachable, already revoked from the web UI, or an older
  /// server without the endpoint. The user then has to revoke it themselves,
  /// and the UI must say so rather than claim a completed revocation.
  final bool appPasswordRevoked;
}

/// Removes one account and everything the device stored for it.
///
/// Ordering follows `docs/architecture/system-design.md` ("Odhlášení"): the
/// remote cleanup runs while the app password is still valid, and only then
/// are the secret and the local partition destroyed. Every remote step is
/// best effort — somebody removing an account is often offline, or is removing
/// it precisely because the password was already revoked elsewhere — so a
/// remote failure never blocks the local wipe.
final class AccountRemovalService {
  const AccountRemovalService({
    required AccountRepository accounts,
    required CredentialVault credentials,
    required HttpNextcloudApi api,
    required ChatMediaCache mediaCache,
    required ChatMediaDiskCache mediaDiskCache,
    required EmojiUsageStore emojiUsage,
    required AccountBackgroundCleanup clearChatBackgrounds,
    required Future<Directory> Function() voiceDirectory,
    required Future<Directory> Function() chatAttachmentDirectory,
    required Future<DurableAttachmentSourceStore> Function() attachmentSources,
    AccountRemovalStarted? onRemovalStarted,
    AccountPushRevocation? revokePush,
  }) : _accounts = accounts,
       _credentials = credentials,
       _api = api,
       _mediaCache = mediaCache,
       _mediaDiskCache = mediaDiskCache,
       _emojiUsage = emojiUsage,
       _clearChatBackgrounds = clearChatBackgrounds,
       _voiceDirectory = voiceDirectory,
       _chatAttachmentDirectory = chatAttachmentDirectory,
       _attachmentSources = attachmentSources,
       _onRemovalStarted = onRemovalStarted,
       _revokePush = revokePush;

  final AccountRepository _accounts;
  final CredentialVault _credentials;
  final HttpNextcloudApi _api;
  final ChatMediaCache _mediaCache;
  final ChatMediaDiskCache _mediaDiskCache;
  final EmojiUsageStore _emojiUsage;
  final AccountBackgroundCleanup _clearChatBackgrounds;
  final Future<Directory> Function() _voiceDirectory;
  final Future<Directory> Function() _chatAttachmentDirectory;
  final Future<DurableAttachmentSourceStore> Function() _attachmentSources;
  final AccountRemovalStarted? _onRemovalStarted;
  final AccountPushRevocation? _revokePush;

  Future<AccountRemovalOutcome> removeAccount(String accountId) async {
    final account = await _accounts.getAccount(accountId);
    if (account == null) {
      return const AccountRemovalOutcome(
        accountExisted: false,
        pushRegistrationRevoked: false,
        appPasswordRevoked: false,
      );
    }

    await _onRemovalStarted?.call(accountId);

    final pushRegistrationRevoked = _revokePush == null
        ? true
        : await _bestEffortResult(() => _revokePush(accountId));

    final appPassword = await _credentials.readAppPassword(accountId);
    var appPasswordRevoked = false;
    if (appPassword != null && appPassword.isNotEmpty) {
      final server = ServerBase.parse(account.serverUrl);
      // Push registration first: revoking the password takes away the only
      // credential that can address it.
      final webPushRevoked = await _bestEffort(
        () => _api.unregisterWebPush(
          server: server,
          loginName: account.loginName,
          appPassword: appPassword,
        ),
      );
      final passwordRevoked = await _bestEffort(
        () => _api.revokeAppPassword(
          server: server,
          loginName: account.loginName,
          appPassword: appPassword,
        ),
      );
      appPasswordRevoked =
          pushRegistrationRevoked && webPushRevoked && passwordRevoked;
    }

    // From here on nothing may be skipped, whatever the server did.
    _api.clearAccountSession(accountId);
    await _emojiUsage.delete(AccountId.parse(accountId));
    await _clearChatBackgrounds(accountId);
    final sourceHandles = await _accounts.purgeAccount(accountId);
    await _credentials.deleteAppPassword(accountId);
    _mediaCache.evictAccount(accountId);
    await _bestEffort(() => _mediaDiskCache.evictAccount(accountId));
    await _bestEffort(
      () async => evictAccountVoiceFiles(
        directory: await _voiceDirectory(),
        accountId: accountId,
      ),
    );
    await _bestEffort(
      () async => evictChatAttachmentFiles(
        rootDirectory: await _chatAttachmentDirectory(),
        accountId: accountId,
      ),
    );
    if (sourceHandles.isNotEmpty) {
      await _bestEffort(() async {
        final sources = await _attachmentSources();
        for (final handle in sourceHandles) {
          await _bestEffort(
            () => sources.discard(AttachmentSourceHandle.parse(handle)),
          );
        }
      });
    }

    return AccountRemovalOutcome(
      accountExisted: true,
      pushRegistrationRevoked: pushRegistrationRevoked,
      appPasswordRevoked: appPasswordRevoked,
    );
  }

  Future<bool> _bestEffortResult(Future<bool> Function() action) async {
    try {
      return await action();
    } on Object {
      return false;
    }
  }

  /// Runs [action] and reports whether it succeeded.
  ///
  /// Deliberately silent: these calls carry the app password, so nothing about
  /// them — not the error, not a stack trace — may reach a log.
  Future<bool> _bestEffort(Future<void> Function() action) async {
    try {
      await action();
      return true;
    } on Object {
      return false;
    }
  }
}
