import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/giphy_reference_load_coordinator.dart';

void main() {
  test('runs at most two reference loads for one account', () async {
    final coordinator = _coordinator();
    final gates = List.generate(3, (_) => Completer<Uint8List>());
    var active = 0;
    var maximumActive = 0;
    var started = 0;

    Future<Uint8List> load(int index) async {
      started++;
      active++;
      maximumActive = active > maximumActive ? active : maximumActive;
      try {
        return await gates[index].future;
      } finally {
        active--;
      }
    }

    final loads = [
      for (var index = 0; index < gates.length; index++)
        coordinator.load(
          accountId: 'account-a',
          resourceUrl: _resource(index),
          loader: () => load(index),
        ),
    ];
    await _flushAsyncWork();

    expect(started, 2);
    expect(maximumActive, 2);

    gates[0].complete(_bytes(2, 0));
    await _flushAsyncWork();

    expect(started, 3);
    expect(maximumActive, 2);

    gates[1].complete(_bytes(2, 1));
    gates[2].complete(_bytes(2, 2));
    await Future.wait(loads);
  });

  test('does not share concurrency slots between accounts', () async {
    final coordinator = _coordinator();
    final accountAGates = List.generate(3, (_) => Completer<Uint8List>());
    final accountBGate = Completer<Uint8List>();
    var accountAStarted = 0;
    var accountBStarted = 0;

    final accountALoads = [
      for (var index = 0; index < accountAGates.length; index++)
        coordinator.load(
          accountId: 'account-a',
          resourceUrl: _resource(index),
          loader: () {
            accountAStarted++;
            return accountAGates[index].future;
          },
        ),
    ];
    final accountBLoad = coordinator.load(
      accountId: 'account-b',
      resourceUrl: _resource(0),
      loader: () {
        accountBStarted++;
        return accountBGate.future;
      },
    );
    await _flushAsyncWork();

    expect(accountAStarted, 2);
    expect(accountBStarted, 1);

    accountBGate.complete(_bytes(2, 9));
    await accountBLoad;
    accountAGates[0].complete(_bytes(2, 0));
    await _flushAsyncWork();

    expect(accountAStarted, 3);

    accountAGates[1].complete(_bytes(2, 1));
    accountAGates[2].complete(_bytes(2, 2));
    await Future.wait(accountALoads);
  });

  test('enforces the global cap fairly across three accounts', () async {
    final coordinator = _coordinator(maximumCacheBytes: 1024);
    final gates = <String, Completer<Uint8List>>{};
    final started = <String>[];
    final completed = <String>{};
    final activeByAccount = <String, int>{};
    final maximumByAccount = <String, int>{};
    var active = 0;
    var maximumActive = 0;

    Future<Uint8List> controlledLoad(String accountId, int index) async {
      final key = '$accountId-$index';
      final gate = gates.putIfAbsent(key, Completer<Uint8List>.new);
      started.add(key);
      active++;
      maximumActive = active > maximumActive ? active : maximumActive;
      final accountActive = (activeByAccount[accountId] ?? 0) + 1;
      activeByAccount[accountId] = accountActive;
      final accountMaximum = maximumByAccount[accountId] ?? 0;
      if (accountActive > accountMaximum) {
        maximumByAccount[accountId] = accountActive;
      }
      try {
        return await gate.future;
      } finally {
        active--;
        activeByAccount[accountId] = activeByAccount[accountId]! - 1;
      }
    }

    final loads = <Future<Uint8List>>[];
    for (final entry in const {'a': 3, 'b': 3, 'c': 2}.entries) {
      for (var index = 0; index < entry.value; index++) {
        loads.add(
          coordinator.load(
            accountId: 'account-${entry.key}',
            resourceUrl: _resource(index),
            loader: () => controlledLoad(entry.key, index),
          ),
        );
      }
    }
    await _flushAsyncWork();

    expect(started, ['a-0', 'a-1', 'b-0', 'b-1']);
    expect(active, 4);

    gates['a-0']!.complete(_bytes(1, 0));
    completed.add('a-0');
    await _flushAsyncWork();

    expect(started[4], 'c-0');

    while (completed.length < loads.length) {
      await _flushAsyncWork();
      final batch = started
          .where((key) => !completed.contains(key))
          .toList(growable: false);
      expect(batch, isNotEmpty);
      for (final key in batch) {
        gates[key]!.complete(_bytes(1, completed.length));
        completed.add(key);
      }
    }
    await Future.wait(loads);

    expect(maximumActive, 4);
    expect(maximumByAccount.values, everyElement(lessThanOrEqualTo(2)));
    expect(started.toSet(), hasLength(loads.length));
  });

  test('keeps the same resource isolated between accounts', () async {
    final coordinator = _coordinator();
    final resource = _resource(0);
    var accountALoads = 0;
    var accountBLoads = 0;

    final accountA = await coordinator.load(
      accountId: 'account-a',
      resourceUrl: resource,
      loader: () async {
        accountALoads++;
        return _bytes(2, 1);
      },
    );
    final accountB = await coordinator.load(
      accountId: 'account-b',
      resourceUrl: resource,
      loader: () async {
        accountBLoads++;
        return _bytes(2, 2);
      },
    );

    final cachedA = await coordinator.load(
      accountId: 'account-a',
      resourceUrl: resource,
      loader: () => throw StateError('account A cache miss'),
    );
    final cachedB = await coordinator.load(
      accountId: 'account-b',
      resourceUrl: resource,
      loader: () => throw StateError('account B cache miss'),
    );

    expect(accountA, [1, 1]);
    expect(accountB, [2, 2]);
    expect(cachedA, [1, 1]);
    expect(cachedB, [2, 2]);
    expect(accountALoads, 1);
    expect(accountBLoads, 1);
  });

  test('returns a cached value without invoking the loader again', () async {
    final coordinator = _coordinator();
    var loads = 0;

    Future<Uint8List> loader() async {
      loads++;
      return _bytes(3, 7);
    }

    final first = await coordinator.load(
      accountId: 'account-a',
      resourceUrl: _resource(0),
      loader: loader,
    );
    final second = await coordinator.load(
      accountId: 'account-a',
      resourceUrl: _resource(0),
      loader: loader,
    );

    expect(second, same(first));
    expect(loads, 1);
  });

  test('evicts the least recently used value by byte budget', () async {
    final coordinator = _coordinator(maximumCacheBytes: 4);
    final loads = <int, int>{};

    Future<Uint8List> load(int index) async {
      loads.update(index, (count) => count + 1, ifAbsent: () => 1);
      return _bytes(2, index);
    }

    await coordinator.load(
      accountId: 'account-a',
      resourceUrl: _resource(0),
      loader: () => load(0),
    );
    await coordinator.load(
      accountId: 'account-a',
      resourceUrl: _resource(1),
      loader: () => load(1),
    );
    await coordinator.load(
      accountId: 'account-a',
      resourceUrl: _resource(0),
      loader: () => load(0),
    );
    await coordinator.load(
      accountId: 'account-a',
      resourceUrl: _resource(2),
      loader: () => load(2),
    );
    await coordinator.load(
      accountId: 'account-a',
      resourceUrl: _resource(1),
      loader: () => load(1),
    );

    expect(loads, {0: 1, 1: 2, 2: 1});
  });

  test('evicts least recently used tiny values above 64 entries', () async {
    final coordinator = _coordinator(maximumCacheBytes: 1024);

    for (var index = 0; index < 64; index++) {
      await coordinator.load(
        accountId: 'account-a',
        resourceUrl: _resource(index),
        loader: () async => _bytes(1, index),
      );
    }
    await coordinator.load(
      accountId: 'account-a',
      resourceUrl: _resource(0),
      loader: () => throw StateError('recent entry was evicted'),
    );
    await coordinator.load(
      accountId: 'account-a',
      resourceUrl: _resource(64),
      loader: () async => _bytes(1, 64),
    );

    var evictedReloads = 0;
    await coordinator.load(
      accountId: 'account-a',
      resourceUrl: _resource(0),
      loader: () => throw StateError('recent entry was evicted'),
    );
    await coordinator.load(
      accountId: 'account-a',
      resourceUrl: _resource(1),
      loader: () async {
        evictedReloads++;
        return _bytes(1, 1);
      },
    );

    expect(evictedReloads, 1);
  });

  test('a failed load releases its account slot', () async {
    final coordinator = _coordinator();
    final failedGate = Completer<Uint8List>();
    final secondGate = Completer<Uint8List>();
    final thirdGate = Completer<Uint8List>();
    var started = 0;

    Future<Uint8List> load(Completer<Uint8List> gate) async {
      started++;
      return gate.future;
    }

    final failed = coordinator.load(
      accountId: 'account-a',
      resourceUrl: _resource(0),
      loader: () => load(failedGate),
    );
    final failureExpectation = expectLater(failed, throwsA(isA<StateError>()));
    final second = coordinator.load(
      accountId: 'account-a',
      resourceUrl: _resource(1),
      loader: () => load(secondGate),
    );
    final third = coordinator.load(
      accountId: 'account-a',
      resourceUrl: _resource(2),
      loader: () => load(thirdGate),
    );
    await _flushAsyncWork();

    expect(started, 2);

    failedGate.completeError(StateError('synthetic failure'));
    await failureExpectation;
    await _flushAsyncWork();

    expect(started, 3);

    secondGate.complete(_bytes(2, 1));
    thirdGate.complete(_bytes(2, 2));
    await Future.wait([second, third]);
  });

  test('retainWhileCached releases immediately when key is not cached', () async {
    final coordinator = _coordinator();
    var released = 0;

    coordinator.retainWhileCached(
      accountId: 'account-a',
      resourceUrl: _resource(0),
      release: () => released++,
    );

    expect(released, 1);
  });

  test('retainWhileCached release runs when the LRU evicts the entry', () async {
    final coordinator = _coordinator(maximumCacheBytes: 4);
    var released = 0;

    await coordinator.load(
      accountId: 'account-a',
      resourceUrl: _resource(0),
      loader: () async => _bytes(2, 0),
    );
    coordinator.retainWhileCached(
      accountId: 'account-a',
      resourceUrl: _resource(0),
      release: () => released++,
    );
    expect(released, 0);

    await coordinator.load(
      accountId: 'account-a',
      resourceUrl: _resource(1),
      loader: () async => _bytes(2, 1),
    );
    await coordinator.load(
      accountId: 'account-a',
      resourceUrl: _resource(2),
      loader: () async => _bytes(2, 2),
    );

    expect(released, 1);
  });

  test(
    'retainWhileCached release runs when the key is re-cached with a new value',
    () async {
      // Two concurrent loads for the same key can both miss the cache before
      // either finishes; the second one's _cacheValue call then replaces the
      // first entry, which must release any retained keep-alive for it.
      final coordinator = _coordinator();
      final gate1 = Completer<Uint8List>();
      final gate2 = Completer<Uint8List>();
      var released = 0;

      final future1 = coordinator.load(
        accountId: 'account-a',
        resourceUrl: _resource(0),
        loader: () => gate1.future,
      );
      final future2 = coordinator.load(
        accountId: 'account-a',
        resourceUrl: _resource(0),
        loader: () => gate2.future,
      );
      await _flushAsyncWork();

      gate1.complete(_bytes(2, 1));
      await future1;
      coordinator.retainWhileCached(
        accountId: 'account-a',
        resourceUrl: _resource(0),
        release: () => released++,
      );
      expect(released, 0);

      gate2.complete(_bytes(2, 2));
      await future2;
      expect(released, 1);
    },
  );

  test('a cancelled queued load does not poison the same key', () async {
    final coordinator = _coordinator();
    final blockers = List.generate(2, (_) => Completer<Uint8List>());
    final blockingLoads = [
      for (var index = 0; index < blockers.length; index++)
        coordinator.load(
          accountId: 'account-a',
          resourceUrl: _resource(index),
          loader: () => blockers[index].future,
        ),
    ];
    await _flushAsyncWork();

    var cancelledStarted = 0;
    var succeedingStarted = 0;
    final resource = _resource(99);
    final cancelled = coordinator.load(
      accountId: 'account-a',
      resourceUrl: resource,
      loader: () async {
        cancelledStarted++;
        throw StateError('synthetic cancellation');
      },
    );
    final cancellationExpectation = expectLater(
      cancelled,
      throwsA(isA<StateError>()),
    );
    final succeeding = coordinator.load(
      accountId: 'account-a',
      resourceUrl: resource,
      loader: () async {
        succeedingStarted++;
        return _bytes(2, 4);
      },
    );
    await _flushAsyncWork();

    expect(cancelledStarted, 0);
    expect(succeedingStarted, 0);

    blockers[0].complete(_bytes(2, 0));
    await cancellationExpectation;
    await _flushAsyncWork();

    expect(cancelledStarted, 1);
    expect(succeedingStarted, 1);
    expect(await succeeding, [4, 4]);

    blockers[1].complete(_bytes(2, 1));
    await Future.wait(blockingLoads);
  });
}

GiphyReferenceLoadCoordinator<Uint8List> _coordinator({
  int maximumCacheBytes = 64,
}) {
  return GiphyReferenceLoadCoordinator<Uint8List>(
    maximumCacheBytes: maximumCacheBytes,
    byteSizeOf: (value) => value.lengthInBytes,
  );
}

Uri _resource(int index) => Uri.parse('https://giphy.com/gifs/fixture-$index');

Uint8List _bytes(int length, int value) =>
    Uint8List(length)..fillRange(0, length, value);

Future<void> _flushAsyncWork() => Future<void>.delayed(Duration.zero);
