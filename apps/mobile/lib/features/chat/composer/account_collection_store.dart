import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:talk_protocol/talk_protocol.dart';

/// A local list per account. A failed replacement leaves the previous list intact.
abstract class AccountCollectionStore<T> extends ChangeNotifier {
  AccountCollectionStore(this._folder, this._directory);

  final String _folder;
  final Directory? _directory;
  final _pending = <AccountId, Future<void>>{};

  @protected
  T decode(Map<String, Object?> json);
  @protected
  Map<String, Object?> encode(T entry);

  Future<File> _file(AccountId account) async {
    final root = _directory ?? await getApplicationSupportDirectory();
    final digest = sha256.convert(utf8.encode(account.value));
    return File(p.join(root.path, _folder, '$digest.json'));
  }

  Future<List<T>> read(AccountId account) =>
      _inOrder(account, () async => _readFile(await _file(account)));

  Future<List<T>> _readFile(File file) async {
    if (!await file.exists()) return <T>[];
    final data = jsonDecode(await file.readAsString());
    if (data is! Map<String, Object?> || data['version'] != 1) {
      throw const FormatException('Unknown collection format');
    }
    final rows = data['entries'] as List<Object?>;
    return [for (final row in rows) decode(row as Map<String, Object?>)];
  }

  @protected
  Future<void> update(
    AccountId account,
    void Function(List<T> entries) change,
  ) => _inOrder(account, () async {
    final file = await _file(account);
    final entries = await _readFile(file);
    change(entries);
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    try {
      await temporary.writeAsString(
        jsonEncode({'version': 1, 'entries': entries.map(encode).toList()}),
        flush: true,
      );
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
    notifyListeners();
  });

  Future<void> delete(AccountId account) => _inOrder(account, () async {
    final file = await _file(account);
    for (final path in [file, File('${file.path}.tmp')]) {
      if (await path.exists()) await path.delete();
    }
    notifyListeners();
  });

  Future<R> _inOrder<R>(AccountId account, Future<R> Function() action) {
    final previous = _pending[account] ?? Future<void>.value();
    final result = previous.then((_) => action());
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _pending[account] = tail;
    return result.whenComplete(() {
      if (identical(_pending[account], tail)) _pending.remove(account);
    });
  }
}
