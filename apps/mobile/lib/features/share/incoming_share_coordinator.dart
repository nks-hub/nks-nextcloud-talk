import 'dart:async';
import 'dart:collection';

import 'package:flutter/services.dart';

import 'incoming_share_bridge.dart';

final class IncomingShareCoordinator {
  IncomingShareCoordinator(this._platform) {
    _subscription = _platform.shareOpened.listen(_accept);
  }

  final IncomingSharePlatform _platform;
  final ListQueue<IncomingShare> _pending = ListQueue<IncomingShare>();
  final Set<String> _knownIds = <String>{};
  final StreamController<void> _availableController =
      StreamController<void>.broadcast();
  StreamSubscription<IncomingShare>? _subscription;
  Future<void>? _startFuture;

  Stream<void> get shareAvailable => _availableController.stream;

  IncomingShare? takeNext() => _pending.isEmpty ? null : _pending.removeFirst();

  Future<void> start() => _startFuture ??= _start();

  Future<void> _start() async {
    try {
      final share = await _platform.getLaunchShare();
      if (share != null) _accept(share);
    } on MissingPluginException {
      return;
    }
  }

  void _accept(IncomingShare share) {
    if (!_knownIds.add(share.id)) return;
    _pending.addLast(share);
    _availableController.add(null);
  }

  Future<void> complete(IncomingShare share) async {
    await _platform.complete(share.id);
  }

  Future<void> close() async {
    await _subscription?.cancel();
    await _platform.dispose();
    await _availableController.close();
  }
}
