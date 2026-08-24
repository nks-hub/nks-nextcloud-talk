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

  test('coalesces simultaneous loads of one account resource', () async {
    final coordinator = _coordinator();
    final gate = Completer<Uint8List>();
    var loads = 0;

    Future<Uint8List> loader() async {
      loads++;
      return gate.future;
    }

    final first = coordinator.load(
      accountId: 'account-a',
      resourceUrl: _resource(0),
      loader: loader,
    );
    final second = coordinator.load(
      accountId: 'account-a',
      resourceUrl: _resource(0),
      loader: loader,
    );
    await _flushAsyncWork();

    expect(loads, 1);

    gate.complete(_bytes(2, 4));
    expect(await second, same(await first));
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
