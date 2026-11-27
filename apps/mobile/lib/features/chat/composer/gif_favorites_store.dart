import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:talk_protocol/talk_protocol.dart';
import 'package:uuid/uuid.dart';

import '../../../core/giphy_reference.dart';
import 'account_collection_store.dart';
import 'giphy.dart';

String _gifId(GiphyEntry entry) {
  final resource = entry.resourceUrl;
  if (!isSupportedGiphyResource(resource)) {
    throw const FormatException('Unsupported GIF reference');
  }
  return resource.host == 'media.giphy.com'
      ? resource.pathSegments[1]
      : resource.pathSegments.last.split('-').last;
}

final _syncableGifId = RegExp(r'^[a-zA-Z0-9]{1,100}$');

bool isSyncableGifId(String id) => _syncableGifId.hasMatch(id);

bool sameFavoriteGif(GiphyEntry first, GiphyEntry second) =>
    _gifId(first) == _gifId(second);

typedef GifFavoriteChange = ({
  String id,
  String operationId,
  GiphyEntry? entry,
});

final class GifFavoritesStore extends ChangeNotifier {
  GifFavoritesStore({Directory? directory})
    : _records = _GifRecords(directory) {
    _records.addListener(notifyListeners);
  }

  final _GifRecords _records;
  final _generations = <AccountId, int>{};

  @override
  void dispose() {
    _records.removeListener(notifyListeners);
    super.dispose();
  }

  int generation(AccountId account) => _generations[account] ?? 0;

  Future<void> delete(AccountId account) {
    _generations[account] = generation(account) + 1;
    return _records.delete(account);
  }

  Future<List<GiphyEntry>> read(AccountId account) async =>
      (await _records.read(
        account,
      )).map((record) => record.entry).nonNulls.toList(growable: false);

  Future<void> setFavorite(
    AccountId account,
    GiphyEntry entry, {
    required bool saved,
  }) => _records.edit(account, (records) {
    final id = _gifId(entry);
    final syncable = isSyncableGifId(id);
    records.removeWhere((other) => other.id == id);
    if (saved || syncable) {
      records.insert(
        0,
        _FavoriteRecord(
          id: id,
          entry: saved ? entry : null,
          operationId: syncable ? const Uuid().v4() : null,
        ),
      );
    }
  });

  Future<List<GifFavoriteChange>> pendingChanges(
    AccountId account,
    int atGeneration,
  ) async {
    var records = await _records.read(account);
    if (generation(account) != atGeneration) return const [];
    if (records.any((record) => record.legacy)) {
      // Give each legacy favourite a durable operation ID on the first sync.
      await _editCurrent(account, atGeneration, (records) {
        for (var index = 0; index < records.length; index++) {
          final record = records[index];
          if (record.legacy) {
            records[index] = _FavoriteRecord(
              id: record.id,
              entry: record.entry,
              operationId: const Uuid().v4(),
            );
          }
        }
      });
      records = await _records.read(account);
    }
    if (generation(account) != atGeneration) return const [];
    return [
      for (final record in records.reversed)
        if (record.operationId case final operationId?)
          (id: record.id, operationId: operationId, entry: record.entry),
    ];
  }

  Future<void> acknowledge(
    AccountId account,
    int atGeneration,
    GifFavoriteChange change, {
    required bool saved,
  }) => _editCurrent(account, atGeneration, (records) {
    final index = records.indexWhere(
      (record) =>
          record.id == change.id && record.operationId == change.operationId,
    );
    if (index < 0) return;
    final entry = records[index].entry;
    if (saved && entry != null) {
      records[index] = _FavoriteRecord(id: change.id, entry: entry);
    } else {
      records.removeAt(index);
    }
  });

  Future<void> replaceSynced(
    AccountId account,
    int atGeneration,
    List<GiphyEntry> entries,
  ) => _editCurrent(account, atGeneration, (records) {
    final remaining = records
        .where(
          (record) => record.operationId != null || !isSyncableGifId(record.id),
        )
        .toList();
    final localIds = remaining.map((record) => record.id).toSet();
    records
      ..clear()
      ..addAll(remaining)
      ..addAll([
        for (final entry in entries)
          if (localIds.add(_gifId(entry)))
            _FavoriteRecord(id: _gifId(entry), entry: entry),
      ]);
  });

  Future<void> _editCurrent(
    AccountId account,
    int atGeneration,
    void Function(List<_FavoriteRecord>) edit,
  ) async {
    if (generation(account) != atGeneration) return;
    try {
      await _records.edit(account, (records) {
        if (generation(account) != atGeneration) {
          throw const _DeletedGifAccount();
        }
        edit(records);
      });
    } on _DeletedGifAccount {
      // The account was removed while this update waited for the local file.
    }
  }
}

final class _DeletedGifAccount implements Exception {
  const _DeletedGifAccount();
}

final class _FavoriteRecord {
  const _FavoriteRecord({
    required this.id,
    this.entry,
    this.operationId,
    this.legacy = false,
  });

  final String id;
  final GiphyEntry? entry;
  final String? operationId;
  final bool legacy;
}

final class _GifRecords extends AccountCollectionStore<_FavoriteRecord> {
  _GifRecords(Directory? directory) : super('gif-favorites-v1', directory);

  Future<void> edit(
    AccountId account,
    void Function(List<_FavoriteRecord>) change,
  ) => update(account, change);

  @override
  Map<String, Object?> encode(_FavoriteRecord record) {
    final entry = record.entry;
    return {
      'id': record.id,
      if (!record.legacy) 'operationId': record.operationId,
      if (entry != null) ...{
        'resource': entry.resourceUrl.toString(),
        'thumbnail': _thumbnail(entry.thumbnailUrl).toString(),
        'title': entry.title,
        'subline': entry.subline,
      },
    };
  }

  @override
  _FavoriteRecord decode(Map<String, Object?> json) {
    final operationId = json['operationId'] as String?;
    final rawResource = json['resource'] as String?;
    if (rawResource == null) {
      final id = json['id'] as String?;
      if (id == null || !isSyncableGifId(id) || operationId == null) {
        throw const FormatException('Invalid GIF removal');
      }
      return _FavoriteRecord(id: id, operationId: operationId);
    }
    final resource = exactGiphyResource(rawResource);
    if (resource == null) throw const FormatException('Invalid saved GIF');
    final entry = GiphyEntry(
      resourceUrl: resource,
      thumbnailUrl: _thumbnail(Uri.parse(json['thumbnail'] as String)),
      title: json['title'] as String,
      subline: json['subline'] as String,
    );
    final id = _gifId(entry);
    return _FavoriteRecord(
      id: id,
      entry: entry,
      operationId: operationId,
      legacy: !json.containsKey('operationId') && isSyncableGifId(id),
    );
  }

  // Only rendition parameters from the Nextcloud proxy belong on disk.
  // The repository checks the current account's origin again before loading.
  Uri _thumbnail(Uri uri) {
    if ((uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw const FormatException('Invalid GIF thumbnail');
    }
    if (!uri.hasQuery) return uri;
    const rendition = {'gifId', 'domainPrefix', 'fileName', 'cid', 'rid', 'ct'};
    final query = Map.of(uri.queryParameters)
      ..removeWhere(
        (key, value) =>
            !rendition.contains(key) &&
            !(key == 'preferredVersion' && value == 'fixed_width'),
      );
    return uri.replace(queryParameters: query);
  }
}
