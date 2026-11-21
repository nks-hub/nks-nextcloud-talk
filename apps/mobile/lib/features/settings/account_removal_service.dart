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
import 'app_password_revocation_queue.dart';

typedef AccountRemovalStarted = Future<void> Function(String accountId);
typedef AccountRemovalAborted = Future<void> Function(String accountId);
typedef AccountPurged = Future<void> Function(String accountId);
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
/// push cleanup runs while the app password is still valid. Server revocation
/// is reserved durably, the local password is deleted, and only then is the
/// server password revoked. If the server is unreachable, the reservation is
/// turned into a pending revocation. A full, corrupt or unavailable queue
/// stops removal so no live password loses its local owner.
///
/// Deleting the local password is the one blocking local step. The account
/// row stays in place until that succeeds, so a temporarily unavailable vault
/// cannot leave a secret with no account through which removal can be retried.
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
    AccountRemovalAborted? onRemovalAborted,
    AccountPurged? onAccountPurged,
    AccountPushRevocation? revokePush,
    AppPasswordRevocationQueue? pendingRevocations,
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
       _onRemovalAborted = onRemovalAborted,
       _onAccountPurged = onAccountPurged,
       _revokePush = revokePush,
       _pendingRevocations = pendingRevocations;

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
  final AccountRemovalAborted? _onRemovalAborted;
  final AccountPurged? _onAccountPurged;
  final AccountPushRevocation? _revokePush;
  final AppPasswordRevocationQueue? _pendingRevocations;

  Future<AccountRemovalOutcome> removeAccount(String accountId) async {
    final account = await _accounts.getAccount(accountId);
    if (account == null) {
      return const AccountRemovalOutcome(
        accountExisted: false,
        pushRegistrationRevoked: false,
        appPasswordRevoked: false,
      );
    }

    final appPassword = await _credentials.readAppPassword(accountId);
    await _onRemovalStarted?.call(accountId);
    if (appPassword != null && appPassword.isNotEmpty) {
      await _bestEffort(
        () => _api.shutdownAccountSession(
          accountId: accountId,
          loginName: account.loginName,
          appPassword: appPassword,
        ),
      );
    } else {
      await _api.clearAccountSession(accountId);
    }

    final pushRegistrationRevoked = _revokePush == null
        ? true
        : await _bestEffortResult(() => _revokePush(accountId));

    var appPasswordRevoked = false;
    var webPushLeftBehind = false;
    ServerBase? server;
    if (appPassword != null && appPassword.isNotEmpty) {
      final parsedServer = ServerBase.parse(account.serverUrl);
      server = parsedServer;
      // Push registration first: revoking the password takes away the only
      // credential that can address it.
      final webPushRevoked = await _bestEffort(
        () => _api.unregisterWebPush(
          server: parsedServer,
          loginName: account.loginName,
          appPassword: appPassword,
        ),
      );
      if (!webPushRevoked) {
        webPushLeftBehind = true;
      }
    }

    AppPasswordRevocationReservation? removalReservation;
    try {
      if (server != null) {
        final queue = _pendingRevocations;
        if (queue == null) {
          throw StateError('Pending revocation store is unavailable');
        }
        removalReservation = await queue.reserveCredentialForRemoval(
          server: server,
          loginName: account.loginName,
          appPassword: appPassword!,
          accountId: accountId,
        );
      }
      await _credentials.deleteAppPassword(accountId);
    } on Object catch (error, stackTrace) {
      if (removalReservation != null) {
        final queue = _pendingRevocations!;
        try {
          final retainedPassword = await _credentials.readAppPassword(
            accountId,
          );
          if (retainedPassword == appPassword) {
            await queue.releaseHeldCredential(removalReservation);
          } else {
            await queue.queueCredential(
              reservation: removalReservation,
              server: server!,
              loginName: account.loginName,
              appPassword: appPassword!,
            );
          }
        } on Object {
          // The durable held entry remains. Recovery will inspect the vault
          // before deciding whether it is safe to revoke or release it.
          queue.abandonHeldCredential(removalReservation);
        }
      }
      try {
        await _onRemovalAborted?.call(accountId);
      } on Object {
        // The credential failure is why removal stopped. A rollback failure
        // must not replace it with a less useful error.
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
    if (server != null && removalReservation != null) {
      try {
        appPasswordRevoked = await _revokeReservedCredential(
          reservation: removalReservation,
          server: server,
          loginName: account.loginName,
          appPassword: appPassword!,
        );
      } on Object catch (error, stackTrace) {
        _pendingRevocations!.abandonHeldCredential(removalReservation);
        try {
          await _onRemovalAborted?.call(accountId);
        } on Object {
          // Preserve the queue failure that stopped account removal.
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
    }
    // Only caches: none may keep the account row around after the secret is
    // gone. A locked cache file can be retried by normal cache maintenance.
    await _bestEffort(() => _emojiUsage.delete(AccountId.parse(accountId)));
    // Only caches: a locked file must not keep the credentials on the device.
    await _bestEffort(() => _clearChatBackgrounds(accountId));
    final sourceHandles = await _accounts.purgeAccount(accountId);
    final onAccountPurged = _onAccountPurged;
    if (onAccountPurged != null) {
      await _bestEffort(() => onAccountPurged(accountId));
    }
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
        final handles = <AttachmentSourceHandle>[];
        for (final handle in sourceHandles) {
          try {
            handles.add(AttachmentSourceHandle.parse(handle));
          } on Object {
            // A corrupt row must not keep later valid sources on the device.
          }
        }
        await sources.discardAll(handles);
      });
    }

    return AccountRemovalOutcome(
      accountExisted: true,
      pushRegistrationRevoked: pushRegistrationRevoked && !webPushLeftBehind,
      appPasswordRevoked: appPasswordRevoked,
    );
  }

  /// Revokes a locally deleted password or makes its durable reservation
  /// retryable. A `401` proves the password is already dead.
  Future<bool> _revokeReservedCredential({
    required AppPasswordRevocationReservation reservation,
    required ServerBase server,
    required String loginName,
    required String appPassword,
  }) async {
    final queue = _pendingRevocations!;
    try {
      await _api.revokeAppPassword(
        server: server,
        loginName: loginName,
        appPassword: appPassword,
      );
      await queue.releaseRevokedCredential(reservation);
      return true;
    } on NextcloudApiException catch (error) {
      if (error.statusCode == 401) {
        await queue.releaseRevokedCredential(reservation);
        return false;
      }
      await queue.queueCredential(
        reservation: reservation,
        server: server,
        loginName: loginName,
        appPassword: appPassword,
      );
      return false;
    } on Object {
      await queue.queueCredential(
        reservation: reservation,
        server: server,
        loginName: loginName,
        appPassword: appPassword,
      );
      return false;
    }
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
