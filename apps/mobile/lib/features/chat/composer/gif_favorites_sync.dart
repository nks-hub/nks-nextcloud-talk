import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../../app_providers.dart';
import '../../owntalk_extensions/owntalk_extensions_service.dart';
import 'gif_favorites.dart';
import 'giphy.dart';

const _gifFavoritesFeature = 'personal.gifFavorites';
const _gifFavoritesPath = ['personal', 'gifs'];
const _maximumRemoteFavorites = 500;
const _maximumLabelLength = 200;

final gifFavoritesSyncProvider = Provider<GifFavoritesSync>((ref) {
  final sync = GifFavoritesSync(
    ref.watch(gifFavoritesStoreProvider),
    ref.watch(ownTalkExtensionsServiceProvider),
  );
  final wake = ref
      .watch(connectivityWakeEventsProvider)
      .listen((_) => sync.wake());
  ref.listen(windowActiveProvider, (previous, active) {
    if (active && previous == false) sync.wake();
  });
  ref.onDispose(() {
    sync.dispose();
    unawaited(wake.cancel());
  });
  return sync;
});

final class GifFavoritesSync {
  GifFavoritesSync(this._store, this._extensions);

  final GifFavoritesStore _store;
  final OwnTalkExtensionsService _extensions;
  final _targets = <AccountId, ServerBase>{};
  final _running = <AccountId, Future<void>>{};
  final _rerun = <AccountId>{};
  bool _disposed = false;

  Future<void> refresh(AccountId account, ServerBase server) {
    if (_disposed) return Future<void>.value();
    _targets[account] = server;
    final existing = _running[account];
    if (existing != null) {
      _rerun.add(account);
      return existing;
    }
    return _running[account] = _sync(account).whenComplete(() {
      _running.remove(account);
      final next = _targets[account];
      if (_rerun.remove(account) && next != null) return refresh(account, next);
    });
  }

  void wake() {
    for (final entry in _targets.entries.toList()) {
      unawaited(refresh(entry.key, entry.value));
    }
  }

  void dispose() {
    _disposed = true;
    _targets.clear();
    _rerun.clear();
  }

  Future<void> _sync(AccountId account) async {
    do {
      _rerun.remove(account);
      final server = _targets[account];
      if (_disposed || server == null) return;
      final generation = _store.generation(account);
      bool isCurrent() =>
          !_disposed &&
          _targets[account]?.uri == server.uri &&
          _store.generation(account) == generation;
      try {
        await _syncOnce(account, server, generation, isCurrent);
      } on OwnTalkExtensionsException catch (error) {
        if (error.code == OwnTalkExtensionsError.accountMissing) {
          _targets.remove(account);
        }
      } on FileSystemException {
        // Keep the existing file and retry on the next trigger.
      } on FormatException {
        // An invalid snapshot cannot replace the last confirmed one.
      }
    } while (_rerun.contains(account));
  }

  Future<void> _syncOnce(
    AccountId account,
    ServerBase server,
    int generation,
    bool Function() isCurrent,
  ) async {
    if (!await _extensions.supports(account.value, _gifFavoritesFeature) ||
        !isCurrent()) {
      return;
    }

    final changes = await _store.pendingChanges(account, generation);
    for (final change in changes) {
      if (!isCurrent()) return;
      try {
        final saved = await _sendChange(account, change);
        if (!isCurrent()) return;
        await _store.acknowledge(account, generation, change, saved: saved);
      } on OwnTalkExtensionsException catch (error) {
        // A full collection can still process subsequent removals.
        if (error.statusCode != 409) rethrow;
      }
    }

    if (!isCurrent()) return;
    final response = await _extensions.featureRequest(
      accountId: account.value,
      feature: _gifFavoritesFeature,
      path: _gifFavoritesPath,
    );
    if (!isCurrent()) return;
    await _store.replaceSynced(
      account,
      generation,
      _decodeFavorites(server, response),
    );
  }

  Future<bool> _sendChange(AccountId account, GifFavoriteChange change) async {
    final entry = change.entry;
    final response = await _extensions.featureRequest(
      accountId: account.value,
      feature: _gifFavoritesFeature,
      path: [..._gifFavoritesPath, 'giphy', change.id],
      method: entry == null ? 'DELETE' : 'PUT',
      query: entry == null ? {'operationId': change.operationId} : null,
      values: entry == null
          ? null
          : {
              'operationId': change.operationId,
              'title': _truncateLabel(entry.title),
              'subline': _truncateLabel(entry.subline),
            },
    );
    final saved = response['saved'];
    if (saved is! bool) throw const FormatException('Invalid GIF write result');
    return saved;
  }
}

String _truncateLabel(String text) =>
    String.fromCharCodes(text.runes.take(_maximumLabelLength));

List<GiphyEntry> _decodeFavorites(
  ServerBase server,
  Map<String, dynamic> data,
) {
  final items = data['items'];
  if (items is! List<Object?> || items.length > _maximumRemoteFavorites) {
    throw const FormatException('Invalid GIF favorites list');
  }
  final seen = <String>{};
  final entries = <GiphyEntry>[];
  for (final item in items) {
    if (item case {
      'provider': 'giphy',
      'id': final String id,
    } when isSyncableGifId(id) && seen.add(id)) {
      entries.add(
        GiphyEntry(
          resourceUrl: Uri.https('giphy.com', '/gifs/$id'),
          thumbnailUrl: server.uri.replace(
            path: '${server.basePath}/index.php/apps/integration_giphy/gif/$id',
            queryParameters: const {'preferredVersion': 'fixed_width'},
          ),
          title: _readLabel(item['title']),
          subline: _readLabel(item['subline']),
        ),
      );
    } else {
      throw const FormatException('Invalid synced GIF');
    }
  }
  return entries;
}

String _readLabel(Object? value) {
  if (value == null) return '';
  if (value is String && value.runes.length <= _maximumLabelLength) {
    return value;
  }
  throw const FormatException('Invalid synced GIF label');
}
