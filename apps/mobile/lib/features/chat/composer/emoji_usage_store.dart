import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:talk_protocol/talk_protocol.dart';

/// Account-scoped emoji choices exposed to the composer.
final class EmojiUsage {
  factory EmojiUsage({
    required Iterable<String> recent,
    required Iterable<String> favorites,
  }) => EmojiUsage._(
    List<String>.unmodifiable(recent),
    List<String>.unmodifiable(favorites),
  );

  const EmojiUsage._(this.recent, this.favorites);

  static const EmojiUsage empty = EmojiUsage._(<String>[], <String>[]);

  final List<String> recent;
  final List<String> favorites;
}

abstract interface class EmojiUsageStore {
  Future<EmojiUsage> read(AccountId accountId);

  Future<EmojiUsage> recordSelection(AccountId accountId, String emoji);

  Future<EmojiUsage> toggleFavorite(AccountId accountId, String emoji);

  Future<void> delete(AccountId accountId);
}

/// Persists emoji choices without exposing account identifiers in file names.
final class FileEmojiUsageStore implements EmojiUsageStore {
  factory FileEmojiUsageStore({Directory? directory, int recentLimit = 28}) =>
      FileEmojiUsageStore._(directory, recentLimit);

  FileEmojiUsageStore._(this._directory, this.recentLimit) {
    if (recentLimit < 1 || recentLimit > _maximumStoredItems) {
      throw RangeError.range(
        recentLimit,
        1,
        _maximumStoredItems,
        'recentLimit',
      );
    }
  }

  static const int _schemaVersion = 1;
  static const int _maximumFileBytes = 64 * 1024;
  static const int _maximumEmojiBytes = 128;
  static const int _maximumStoredItems = 512;

  final Directory? _directory;
  final int recentLimit;
  Future<void> _pending = Future<void>.value();

  @override
  Future<EmojiUsage> read(AccountId accountId) =>
      _serialize(() => _readFile(accountId));

  @override
  Future<EmojiUsage> recordSelection(AccountId accountId, String emoji) {
    final value = _requireEmoji(emoji);
    return _serialize(() async {
      final current = await _readFile(accountId);
      final recent = <String>[
        value,
        ...current.recent.where((candidate) => candidate != value),
      ].take(recentLimit);
      final next = EmojiUsage(recent: recent, favorites: current.favorites);
      await _writeFile(accountId, next);
      return next;
    });
  }

  @override
  Future<EmojiUsage> toggleFavorite(AccountId accountId, String emoji) {
    final value = _requireEmoji(emoji);
    return _serialize(() async {
      final current = await _readFile(accountId);
      final favorites = current.favorites.contains(value)
          ? current.favorites.where((candidate) => candidate != value)
          : <String>[value, ...current.favorites].take(_maximumStoredItems);
      final next = EmojiUsage(recent: current.recent, favorites: favorites);
      await _writeFile(accountId, next);
      return next;
    });
  }

  @override
  Future<void> delete(AccountId accountId) {
    return _serialize(() async {
      final file = await _file(accountId);
      for (final candidate in <File>[file, File('${file.path}.tmp')]) {
        if (await candidate.exists()) {
          await candidate.delete();
        }
      }
    });
  }

  Future<EmojiUsage> _readFile(AccountId accountId) async {
    try {
      final file = await _file(accountId);
      if (!await file.exists() || await file.length() > _maximumFileBytes) {
        return EmojiUsage.empty;
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?> ||
          decoded['version'] != _schemaVersion) {
        return EmojiUsage.empty;
      }
      final recent = _decodeList(decoded['recent']);
      final favorites = _decodeList(decoded['favorites']);
      if (recent == null || favorites == null) {
        return EmojiUsage.empty;
      }
      return EmojiUsage(recent: recent.take(recentLimit), favorites: favorites);
    } on Object {
      return EmojiUsage.empty;
    }
  }

  Future<void> _writeFile(AccountId accountId, EmojiUsage usage) async {
    final file = await _file(accountId);
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    try {
      await temporary.writeAsString(
        jsonEncode(<String, Object?>{
          'version': _schemaVersion,
          'recent': usage.recent,
          'favorites': usage.favorites,
        }),
        flush: true,
      );
      try {
        await temporary.rename(file.path);
      } on FileSystemException {
        if (!await file.exists()) {
          rethrow;
        }
        await file.delete();
        await temporary.rename(file.path);
      }
    } finally {
      if (await temporary.exists()) {
        await temporary.delete();
      }
    }
  }

  Future<File> _file(AccountId accountId) async {
    final support = _directory ?? await getApplicationSupportDirectory();
    final digest = sha256.convert(utf8.encode(accountId.value));
    return File(
      p.join(support.path, 'emoji-usage-v1', '${digest.toString()}.json'),
    );
  }

  List<String>? _decodeList(Object? value) {
    if (value is! List<Object?> || value.length > _maximumStoredItems) {
      return null;
    }
    final decoded = <String>[];
    final seen = <String>{};
    for (final item in value) {
      if (item is! String || !_isValidEmoji(item)) {
        return null;
      }
      if (seen.add(item)) {
        decoded.add(item);
      }
    }
    return decoded;
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _pending.then((_) => action());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  static String _requireEmoji(String emoji) {
    if (!_isValidEmoji(emoji)) {
      throw ArgumentError.value(emoji, 'emoji', 'must be a bounded value');
    }
    return emoji;
  }

  static bool _isValidEmoji(String value) {
    if (value.isEmpty ||
        value.trim() != value ||
        utf8.encode(value).length > _maximumEmojiBytes) {
      return false;
    }
    return !value.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f);
  }
}
