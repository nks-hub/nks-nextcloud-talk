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

  final int Function(T value) byteSizeOf;
  final int maximumCacheBytes;
  final Map<String, _AccountLoadQueue> _accountQueues = {};
  final Map<_GiphyReferenceKey, Future<T>> _inFlight = {};
  final LinkedHashMap<_GiphyReferenceKey, _CachedReference<T>> _cache =
      LinkedHashMap();

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

    final existing = _inFlight[key];
    if (existing != null) {
      return existing;
    }

    final completer = Completer<T>();
    _inFlight[key] = completer.future;
    final queue = _accountQueues.putIfAbsent(accountId, _AccountLoadQueue.new);
    queue.pending.add(() async {
      try {
        final value = await loader();
        _cacheValue(key, value);
        completer.complete(value);
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      } finally {
        _inFlight.remove(key);
      }
    });
    _pump(accountId, queue);
    return completer.future;
  }

  void _pump(String accountId, _AccountLoadQueue queue) {
    while (queue.active < maximumConcurrentLoadsPerAccount &&
        queue.pending.isNotEmpty) {
      final task = queue.pending.removeFirst();
      queue.active++;
      unawaited(
        task().whenComplete(() {
          queue.active--;
          if (queue.active == 0 && queue.pending.isEmpty) {
            if (identical(_accountQueues[accountId], queue)) {
              _accountQueues.remove(accountId);
            }
            return;
          }
          _pump(accountId, queue);
        }),
      );
    }
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
    }
    while (_cachedBytes + byteLength > maximumCacheBytes && _cache.isNotEmpty) {
      final oldestKey = _cache.keys.first;
      final oldest = _cache.remove(oldestKey)!;
      _cachedBytes -= oldest.byteLength;
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
  const _CachedReference(this.value, this.byteLength);

  final T value;
  final int byteLength;
}
