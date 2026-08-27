import 'dart:async';
import 'dart:collection';

final class GiphyReferenceLoadCoordinator<T extends Object> {
  GiphyReferenceLoadCoordinator({
    required this.byteSizeOf,
    this.maximumCacheBytes = 32 * 1024 * 1024,
  }) {
    if (maximumCacheBytes < 1) {
      throw ArgumentError.value(
        maximumCacheBytes,
        'maximumCacheBytes',
        'must be positive',
      );
    }
  }

  static const int maximumConcurrentLoadsPerAccount = 2;
  static const int maximumConcurrentLoads = 4;
  static const int maximumCacheEntries = 64;

  final int Function(T value) byteSizeOf;
  final int maximumCacheBytes;

  final Map<String, _AccountLoadQueue> _accountQueues = {};
  final ListQueue<String> _readyAccounts = ListQueue();
  final Set<String> _readyAccountIds = {};
  final LinkedHashMap<_GiphyReferenceKey, _CachedReference<T>> _cache =
      LinkedHashMap();

  int _activeLoads = 0;
  int _cachedBytes = 0;

  Future<T> load({
    required String accountId,
    required Uri resourceUrl,
    required Future<T> Function() loader,
  }) {
    if (accountId.isEmpty) {
      throw ArgumentError.value(accountId, 'accountId', 'must not be empty');
    }

    final key = _GiphyReferenceKey(accountId, resourceUrl);
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return Future<T>.value(cached.value);
    }

    final completer = Completer<T>();
    final queue = _accountQueues.putIfAbsent(accountId, _AccountLoadQueue.new);
    queue.pending.add(() async {
      try {
        final value = await loader();
        _cacheValue(key, value);
        completer.complete(value);
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    _markReady(accountId, queue);
    _pump();
    return completer.future;
  }

  void _markReady(String accountId, _AccountLoadQueue queue) {
    if (queue.pending.isNotEmpty &&
        queue.active < maximumConcurrentLoadsPerAccount &&
        _readyAccountIds.add(accountId)) {
      _readyAccounts.addLast(accountId);
    }
  }

  void _pump() {
    while (_activeLoads < maximumConcurrentLoads && _readyAccounts.isNotEmpty) {
      final accountId = _readyAccounts.removeFirst();
      _readyAccountIds.remove(accountId);
      final queue = _accountQueues[accountId];
      if (queue == null ||
          queue.pending.isEmpty ||
          queue.active >= maximumConcurrentLoadsPerAccount) {
        continue;
      }
      final task = queue.pending.removeFirst();
      queue.active++;
      _activeLoads++;
      _markReady(accountId, queue);
      unawaited(
        task().whenComplete(() {
          queue.active--;
          _activeLoads--;
          if (queue.active == 0 && queue.pending.isEmpty) {
            if (identical(_accountQueues[accountId], queue)) {
              _accountQueues.remove(accountId);
            }
          } else {
            _markReady(accountId, queue);
          }
          _pump();
        }),
      );
    }
  }

  /// Keeps [release] until the entry for [resourceUrl] leaves the cache.
  ///
  /// A reference that is still cached costs nothing to hand out again, so the
  /// caller may hold on to whatever it built from it. Once the LRU drops the
  /// bytes, the retention has to go with them.
  void retainWhileCached({
    required String accountId,
    required Uri resourceUrl,
    required void Function() release,
  }) {
    final entry = _cache[_GiphyReferenceKey(accountId, resourceUrl)];
    if (entry == null) {
      release();
      return;
    }
    entry.release?.call();
    entry.release = release;
  }

  void _cacheValue(_GiphyReferenceKey key, T value) {
    final byteLength = byteSizeOf(value);
    if (byteLength < 0) {
      throw StateError('Giphy reference byte length must not be negative');
    }
    if (byteLength > maximumCacheBytes) {
      return;
    }

    final previous = _cache.remove(key);
    if (previous != null) {
      _cachedBytes -= previous.byteLength;
      previous.release?.call();
    }
    while ((_cachedBytes + byteLength > maximumCacheBytes ||
            _cache.length >= maximumCacheEntries) &&
        _cache.isNotEmpty) {
      final oldestKey = _cache.keys.first;
      final oldest = _cache.remove(oldestKey)!;
      _cachedBytes -= oldest.byteLength;
      oldest.release?.call();
    }
    _cache[key] = _CachedReference(value, byteLength);
    _cachedBytes += byteLength;
  }
}

final class _AccountLoadQueue {
  final ListQueue<Future<void> Function()> pending = ListQueue();
  int active = 0;
}

final class _GiphyReferenceKey {
  const _GiphyReferenceKey(this.accountId, this.resourceUrl);

  final String accountId;
  final Uri resourceUrl;

  @override
  bool operator ==(Object other) =>
      other is _GiphyReferenceKey &&
      other.accountId == accountId &&
      other.resourceUrl == resourceUrl;

  @override
  int get hashCode => Object.hash(accountId, resourceUrl);
}

final class _CachedReference<T extends Object> {
  _CachedReference(this.value, this.byteLength);

  final T value;
  final int byteLength;

  /// Released when this entry leaves the cache; see [retainWhileCached].
  void Function()? release;
}
