import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:talk_protocol/talk_protocol.dart';

typedef ChatBackgroundKey = ({String accountId, String roomToken});

final class ChatBackgroundStore {
  ChatBackgroundStore._(this._directory, {this._beforeWatchSnapshot});

  static const int _version = 1;
  static const int _maximumFileBytes = 512 * 1024;
  static const int _maximumRooms = 1024;
  static final RegExp _colorPattern = RegExp(r'^#[0-9A-Fa-f]{6}$');

  static Future<ChatBackgroundStore> openApplicationSupport() async {
    final support = await getApplicationSupportDirectory();
    return ChatBackgroundStore._(
      Directory('${support.path}${Platform.pathSeparator}chat-backgrounds'),
    );
  }

  static ChatBackgroundStore forTesting(
    Directory directory, {
    Future<void> Function()? beforeWatchSnapshot,
  }) => ChatBackgroundStore._(
    directory,
    beforeWatchSnapshot: beforeWatchSnapshot,
  );

  final Directory _directory;
  final Future<void> Function()? _beforeWatchSnapshot;
  final _SerialExecutor _writes = _SerialExecutor();
  final Map<ChatBackgroundKey, Set<StreamController<String?>>> _watchers = {};

  @visibleForTesting
  int get activeWatcherCount => _watchers.values.fold<int>(
    0,
    (count, watchers) => count + watchers.length,
  );

  Future<String?> read(ChatBackgroundKey key) async {
    _validateKey(key);
    return _writes.run(() async {
      final rooms = await _readAccount(key.accountId);
      return rooms[_roomHash(key.roomToken)];
    });
  }

  Stream<String?> watch(ChatBackgroundKey key) {
    _validateKey(key);
    late final StreamController<String?> output;
    var cancelled = false;
    var registered = false;

    Future<void> register() async {
      try {
        await _writes.run(() async {
          if (cancelled) {
            return;
          }
          _watchers
              .putIfAbsent(key, () => <StreamController<String?>>{})
              .add(output);
          registered = true;
          final rooms = await _readAccount(key.accountId);
          await _beforeWatchSnapshot?.call();
          if (!cancelled) {
            output.add(rooms[_roomHash(key.roomToken)]);
          }
        });
      } on Object catch (error, stackTrace) {
        if (!cancelled) {
          output.addError(error, stackTrace);
        }
      }
    }

    void unregister() {
      cancelled = true;
      if (!registered) {
        return;
      }
      final watchers = _watchers[key];
      watchers?.remove(output);
      if (watchers?.isEmpty ?? false) {
        _watchers.remove(key);
      }
    }

    output = StreamController<String?>(
      onListen: () => unawaited(register()),
      onCancel: unregister,
    );
    return output.stream;
  }

  Future<void> write(ChatBackgroundKey key, String color) {
    _validateKey(key);
    final normalized = _normalizeColor(color);
    return _writes.run(() async {
      final rooms = await _readAccount(key.accountId);
      rooms[_roomHash(key.roomToken)] = normalized;
      if (rooms.length > _maximumRooms) {
        throw StateError('Chat background room limit exceeded');
      }
      await _writeAccount(key.accountId, rooms);
      _emit(key, normalized);
    });
  }

  Future<void> remove(ChatBackgroundKey key) {
    _validateKey(key);
    return _writes.run(() async {
      final rooms = await _readAccount(key.accountId);
      if (rooms.remove(_roomHash(key.roomToken)) == null) {
        return;
      }
      if (rooms.isEmpty) {
        await _deleteAccountFiles(key.accountId);
      } else {
        await _writeAccount(key.accountId, rooms);
      }
      _emit(key, null);
    });
  }

  Future<void> removeAccount(String accountId) {
    AccountId.parse(accountId);
    return _writes.run(() async {
      await _deleteAccountFiles(accountId);
      for (final entry in _watchers.entries.toList(growable: false)) {
        if (entry.key.accountId == accountId) {
          _emit(entry.key, null);
        }
      }
    });
  }

  Future<void> close() async {
    await _writes.run(() async {
      final controllers = <StreamController<String?>>[
        for (final watchers in _watchers.values) ...watchers,
      ];
      _watchers.clear();
      for (final controller in controllers) {
        unawaited(controller.close());
      }
    });
  }

  void _emit(ChatBackgroundKey key, String? value) {
    for (final watcher
        in _watchers[key]?.toList(growable: false) ??
            const <StreamController<String?>>[]) {
      if (!watcher.isClosed) {
        watcher.add(value);
      }
    }
  }

  Future<Map<String, String>> _readAccount(String accountId) async {
    final file = _accountFile(accountId);
    final backup = File('${file.path}.bak');
    try {
      if (!await file.exists() && await backup.exists()) {
        await _directory.create(recursive: true);
        await backup.rename(file.path);
      }
      if (!await file.exists()) {
        return <String, String>{};
      }
      if (await file.length() > _maximumFileBytes) {
        return <String, String>{};
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?> || decoded['version'] != _version) {
        return <String, String>{};
      }
      final rawRooms = decoded['rooms'];
      if (rawRooms is! Map<String, Object?> ||
          rawRooms.length > _maximumRooms) {
        return <String, String>{};
      }
      final rooms = <String, String>{};
      for (final entry in rawRooms.entries) {
        if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(entry.key) ||
            entry.value is! String ||
            !_colorPattern.hasMatch(entry.value! as String)) {
          return <String, String>{};
        }
        rooms[entry.key] = (entry.value! as String).toUpperCase();
      }
      return rooms;
    } on FormatException {
      return <String, String>{};
    } on FileSystemException {
      return <String, String>{};
    }
  }

  Future<void> _writeAccount(
    String accountId,
    Map<String, String> rooms,
  ) async {
    await _directory.create(recursive: true);
    final target = _accountFile(accountId);
    final temporary = File('${target.path}.tmp');
    final backup = File('${target.path}.bak');
    if (await temporary.exists()) {
      await temporary.delete();
    }
    final body = jsonEncode(<String, Object?>{
      'version': _version,
      'rooms': rooms,
    });
    if (utf8.encode(body).length > _maximumFileBytes) {
      throw StateError('Chat background state is too large');
    }
    await temporary.writeAsString(body, flush: true);
    if (await backup.exists()) {
      await backup.delete();
    }
    if (await target.exists()) {
      await target.rename(backup.path);
    }
    try {
      await temporary.rename(target.path);
      if (await backup.exists()) {
        await backup.delete();
      }
    } on Object {
      if (!await target.exists() && await backup.exists()) {
        await backup.rename(target.path);
      }
      rethrow;
    }
  }

  Future<void> _deleteAccountFiles(String accountId) async {
    final target = _accountFile(accountId);
    for (final file in <File>[
      target,
      File('${target.path}.tmp'),
      File('${target.path}.bak'),
    ]) {
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  File _accountFile(String accountId) => File(
    '${_directory.path}${Platform.pathSeparator}${_hash(accountId)}.json',
  );

  static void _validateKey(ChatBackgroundKey key) {
    AccountId.parse(key.accountId);
    ConversationToken.parse(key.roomToken, path: r'$.roomToken');
  }

  static String _normalizeColor(String value) {
    if (!_colorPattern.hasMatch(value)) {
      throw ArgumentError.value(value, 'color', 'must be #RRGGBB');
    }
    return value.toUpperCase();
  }

  static String _roomHash(String roomToken) => _hash(roomToken);

  static String _hash(String value) =>
      sha256.convert(utf8.encode(value)).toString();
}

final class _SerialExecutor {
  Future<void> _tail = Future<void>.value();

  Future<void> get idle => _tail;

  Future<T> run<T>(Future<T> Function() operation) {
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
}
