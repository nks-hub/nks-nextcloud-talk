import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:talk_protocol/talk_protocol.dart';

typedef OwnTalkRoomKey = ({String accountId, String roomToken});

/// A cached document with the `ETag` it arrived with, `null` when the server
/// sent none or the entry predates storing it.
typedef OwnTalkCachedSettings = ({OwnTalkRoomSettings document, String? etag});

typedef _Entry = ({int savedAt, OwnTalkRoomSettings document, String? etag});

/// Last shared-settings document per conversation, one JSON file per account.
///
/// A file store rather than a Drift table: the cached value is a small
/// derived appearance document, the neighbouring chat background store works
/// the same way, and it needs no schema bump that an older build would have to
/// reject. A corrupt or foreign file reads as empty and is overwritten.
final class OwnTalkSettingsStore {
  OwnTalkSettingsStore._(this._directory);

  static const int _version = 1;
  static const int _maximumFileBytes = 1024 * 1024;
  static const int _maximumRooms = 512;
  static final RegExp _hashPattern = RegExp(r'^[0-9a-f]{64}$');

  static Future<OwnTalkSettingsStore> openApplicationSupport() async {
    final support = await getApplicationSupportDirectory();
    return OwnTalkSettingsStore._(
      Directory('${support.path}${Platform.pathSeparator}owntalk-settings'),
    );
  }

  static OwnTalkSettingsStore forTesting(Directory directory) =>
      OwnTalkSettingsStore._(directory);

  final Directory _directory;
  Future<void> _tail = Future<void>.value();

  Future<OwnTalkRoomSettings?> read(OwnTalkRoomKey key) async =>
      (await readEntry(key))?.document;

  Future<OwnTalkCachedSettings?> readEntry(OwnTalkRoomKey key) {
    _validateKey(key);
    return _serialize(() async {
      final entry = (await _readAccount(key.accountId))[_hash(key.roomToken)];
      return entry == null
          ? null
          : (document: entry.document, etag: entry.etag);
    });
  }

  Future<void> write(
    OwnTalkRoomKey key,
    OwnTalkRoomSettings document, {
    String? etag,
  }) {
    _validateKey(key);
    return _serialize(() async {
      final rooms = await _readAccount(key.accountId);
      rooms[_hash(key.roomToken)] = (
        savedAt: DateTime.now().millisecondsSinceEpoch,
        document: document,
        etag: etag,
      );
      if (rooms.length > _maximumRooms) {
        final oldest = rooms.entries.reduce(
          (a, b) => a.value.savedAt <= b.value.savedAt ? a : b,
        );
        rooms.remove(oldest.key);
      }
      await _writeAccount(key.accountId, rooms);
    });
  }

  Future<void> remove(OwnTalkRoomKey key) {
    _validateKey(key);
    return _serialize(() async {
      final rooms = await _readAccount(key.accountId);
      if (rooms.remove(_hash(key.roomToken)) == null) {
        return;
      }
      if (rooms.isEmpty) {
        await _deleteAccountFiles(key.accountId);
      } else {
        await _writeAccount(key.accountId, rooms);
      }
    });
  }

  /// Drops every cached document of an account, for example when the server
  /// stopped offering the extension or the account is removed.
  Future<void> removeAccount(String accountId) {
    AccountId.parse(accountId);
    return _serialize(() => _deleteAccountFiles(accountId));
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await operation());
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<Map<String, _Entry>> _readAccount(String accountId) async {
    final file = _accountFile(accountId);
    try {
      if (!await file.exists() || await file.length() > _maximumFileBytes) {
        return {};
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?> || decoded['version'] != _version) {
        return {};
      }
      final rawRooms = decoded['rooms'];
      if (rawRooms is! Map<String, Object?> ||
          rawRooms.length > _maximumRooms) {
        return {};
      }
      final rooms = <String, _Entry>{};
      for (final entry in rawRooms.entries) {
        final value = entry.value;
        if (!_hashPattern.hasMatch(entry.key) ||
            value is! Map<String, Object?> ||
            value['savedAt'] is! int) {
          return {};
        }
        final etag = value['etag'];
        rooms[entry.key] = (
          savedAt: value['savedAt']! as int,
          document: OwnTalkRoomSettings.fromJson(value['document']),
          etag: etag is String && isOwnTalkEntityTag(etag) ? etag : null,
        );
      }
      return rooms;
    } on FormatException {
      return {};
    } on TalkProtocolException {
      return {};
    } on FileSystemException {
      return {};
    }
  }

  Future<void> _writeAccount(
    String accountId,
    Map<String, _Entry> rooms,
  ) async {
    await _directory.create(recursive: true);
    final target = _accountFile(accountId);
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'version': _version,
        'rooms': {
          for (final entry in rooms.entries)
            entry.key: {
              'savedAt': entry.value.savedAt,
              'document': entry.value.document.toJson(),
              if (entry.value.etag != null) 'etag': entry.value.etag,
            },
        },
      }),
      flush: true,
    );
    await temporary.rename(target.path);
  }

  Future<void> _deleteAccountFiles(String accountId) async {
    final target = _accountFile(accountId);
    for (final file in <File>[target, File('${target.path}.tmp')]) {
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  File _accountFile(String accountId) => File(
    '${_directory.path}${Platform.pathSeparator}${_hash(accountId)}.json',
  );

  static void _validateKey(OwnTalkRoomKey key) {
    AccountId.parse(key.accountId);
    ConversationToken.parse(key.roomToken, path: r'$.roomToken');
  }

  static String _hash(String value) =>
      sha256.convert(utf8.encode(value)).toString();
}
