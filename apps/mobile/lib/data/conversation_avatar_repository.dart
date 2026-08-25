// ignore_for_file: prefer_initializing_formals

import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../network/nextcloud_api.dart';
import 'app_database.dart';
import 'credential_vault.dart';

enum ConversationAvatarRepositoryError {
  credentialMissing,
  invalidNotModifiedResponse,
}

final class ConversationAvatarRepositoryException implements Exception {
  const ConversationAvatarRepositoryException(this.code);

  final ConversationAvatarRepositoryError code;

  @override
  String toString() => 'ConversationAvatarRepositoryException(${code.name})';
}

final class ConversationAvatarImage {
  ConversationAvatarImage({
    required Uint8List body,
    required this.contentType,
    this.isCustomAvatar,
  }) : body = Uint8List.fromList(body);

  final Uint8List body;
  final String contentType;
  final bool? isCustomAvatar;
}

final class ConversationAvatarRepository {
  ConversationAvatarRepository({
    required AppDatabase database,
    required CredentialVault credentials,
    required HttpNextcloudApi api,
    DateTime Function()? clock,
  }) : _database = database,
       _credentials = credentials,
       _api = api,
       _clock = clock ?? DateTime.now;

  static const int _maximumMutableCacheSeconds = 31 * 24 * 60 * 60;

  final AppDatabase _database;
  final CredentialVault _credentials;
  final HttpNextcloudApi _api;
  final DateTime Function() _clock;

  Future<ConversationAvatarImage?> load({
    required StoredAccount account,
    required Uri uri,
    required bool versioned,
  }) async {
    final cacheKey = uri.toString();
    final cached = await _getCached(account.id, cacheKey);
    final now = _clock().toUtc();
    if (cached != null &&
        (versioned || cached.expiresAtMillis > now.millisecondsSinceEpoch)) {
      return _image(cached);
    }

    final appPassword = await _credentials.readAppPassword(account.id);
    if (appPassword == null) {
      if (cached != null) {
        return _image(cached);
      }
      throw const ConversationAvatarRepositoryException(
        ConversationAvatarRepositoryError.credentialMissing,
      );
    }

    final AvatarResponse response;
    try {
      response = await _api.getAvatar(
        server: ServerBase.parse(account.serverUrl),
        avatarUri: uri,
        loginName: account.loginName,
        appPassword: appPassword,
        ifNoneMatch: cached?.etag,
        ifModifiedSince: cached?.lastModified,
      );
    } on NextcloudApiException {
      if (cached != null) {
        return _image(cached);
      }
      rethrow;
    }

    return switch (response.status) {
      AvatarResponseStatus.image => _storeImage(
        accountId: account.id,
        cacheKey: cacheKey,
        response: response,
        now: now,
      ),
      AvatarResponseStatus.notModified => _refreshCached(
        accountId: account.id,
        cacheKey: cacheKey,
        cached: cached,
        response: response,
        now: now,
      ),
      AvatarResponseStatus.notFound => _removeMissing(
        accountId: account.id,
        cacheKey: cacheKey,
      ),
    };
  }

  Future<StoredConversationAvatar?> _getCached(
    String accountId,
    String cacheKey,
  ) {
    return (_database.select(_database.conversationAvatars)..where(
          (row) =>
              row.accountId.equals(accountId) & row.cacheKey.equals(cacheKey),
        ))
        .getSingleOrNull();
  }

  Future<ConversationAvatarImage> _storeImage({
    required String accountId,
    required String cacheKey,
    required AvatarResponse response,
    required DateTime now,
  }) async {
    final contentType = response.contentType!;
    final image = ConversationAvatarImage(
      body: response.body,
      contentType: contentType,
      isCustomAvatar: response.isCustomAvatar,
    );
    if (_hasCacheDirective(response.cacheControl, 'no-store')) {
      await _delete(accountId, cacheKey);
      return image;
    }
    final nowMillis = now.millisecondsSinceEpoch;
    await _database
        .into(_database.conversationAvatars)
        .insertOnConflictUpdate(
          ConversationAvatarsCompanion.insert(
            accountId: accountId,
            cacheKey: cacheKey,
            body: response.body,
            contentType: contentType,
            isCustomAvatar: Value(response.isCustomAvatar),
            etag: Value(response.etag),
            lastModified: Value(response.lastModified),
            expiresAtMillis: _expiresAt(response.cacheControl, now),
            updatedAtMillis: nowMillis,
          ),
        );
    return image;
  }

  Future<ConversationAvatarImage> _refreshCached({
    required String accountId,
    required String cacheKey,
    required StoredConversationAvatar? cached,
    required AvatarResponse response,
    required DateTime now,
  }) async {
    if (cached == null) {
      throw const ConversationAvatarRepositoryException(
        ConversationAvatarRepositoryError.invalidNotModifiedResponse,
      );
    }
    if (_hasCacheDirective(response.cacheControl, 'no-store')) {
      await _delete(accountId, cacheKey);
      return _image(cached);
    }
    await (_database.update(_database.conversationAvatars)..where(
          (row) =>
              row.accountId.equals(accountId) & row.cacheKey.equals(cacheKey),
        ))
        .write(
          ConversationAvatarsCompanion(
            isCustomAvatar: Value(
              response.isCustomAvatar ?? cached.isCustomAvatar,
            ),
            etag: Value(response.etag ?? cached.etag),
            lastModified: Value(response.lastModified ?? cached.lastModified),
            expiresAtMillis: Value(_expiresAt(response.cacheControl, now)),
            updatedAtMillis: Value(now.millisecondsSinceEpoch),
          ),
        );
    return _image(cached);
  }

  Future<ConversationAvatarImage?> _removeMissing({
    required String accountId,
    required String cacheKey,
  }) async {
    await _delete(accountId, cacheKey);
    return null;
  }

  Future<void> _delete(String accountId, String cacheKey) async {
    await (_database.delete(_database.conversationAvatars)..where(
          (row) =>
              row.accountId.equals(accountId) & row.cacheKey.equals(cacheKey),
        ))
        .go();
  }

  ConversationAvatarImage _image(StoredConversationAvatar cached) {
    return ConversationAvatarImage(
      body: cached.body,
      contentType: cached.contentType,
      isCustomAvatar: cached.isCustomAvatar,
    );
  }

  int _expiresAt(String? cacheControl, DateTime now) {
    final match = RegExp(
      r'(?:^|,)\s*max-age\s*=\s*([0-9]+)',
      caseSensitive: false,
    ).firstMatch(cacheControl ?? '');
    final parsed = match == null ? 0 : int.tryParse(match.group(1)!);
    final seconds = math.min(parsed ?? 0, _maximumMutableCacheSeconds);
    return now.add(Duration(seconds: seconds)).millisecondsSinceEpoch;
  }

  bool _hasCacheDirective(String? cacheControl, String directive) {
    return (cacheControl ?? '')
        .split(',')
        .map((part) => part.trim().toLowerCase())
        .contains(directive);
  }
}
