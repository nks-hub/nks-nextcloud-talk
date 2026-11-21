import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:talk_protocol/talk_protocol.dart' show AccountId;
import 'package:uuid/uuid.dart';

import 'attachment_service.dart';

const _androidChannel = MethodChannel(
  'com.nkshub.nextcloudtalk/attachment_runtime',
);

final _localQueue = AttachmentRuntimeQueue();

AttachmentRuntimeReservation reserveAttachmentRuntime() {
  if (!kIsWeb && Platform.isAndroid) {
    final id = const Uuid().v4();
    return AttachmentRuntimeReservation(
      _androidChannel
          .invokeMethod<bool>('acquire', id)
          .then((ok) => ok == true),
      () => _androidChannel.invokeMethod<void>('release', id),
    );
  }
  return _localQueue.reserve();
}

final class AttachmentRuntimeReservation {
  const AttachmentRuntimeReservation(this.granted, this.release);

  final Future<bool> granted;
  final Future<void> Function() release;
}

final class AttachmentRuntimeQueue {
  final _slots = <Completer<bool>>[];

  AttachmentRuntimeReservation reserve() {
    final slot = Completer<bool>();
    _slots.add(slot);
    if (_slots.length == 1) slot.complete(true);
    return AttachmentRuntimeReservation(slot.future, () async {
      final wasOwner = identical(_slots.firstOrNull, slot);
      if (!_slots.remove(slot)) return;
      if (!slot.isCompleted) slot.complete(false);
      if (wasOwner) _slots.firstOrNull?.complete(true);
    });
  }
}

/// Keeps the reservation through the final database and transport cleanup.
final class AttachmentRuntimeOwner {
  AttachmentRuntimeOwner(this._reservation);

  final AttachmentRuntimeReservation _reservation;
  AttachmentService? _service;
  Future<void>? _closing;

  Future<AttachmentService> open(AttachmentService Function() create) async {
    if (!await _reservation.granted || _closing != null) {
      throw AttachmentServiceClosed();
    }
    return _service = create();
  }

  Future<void> close({Future<void>? maintenance}) =>
      _closing ??= _close(maintenance);

  Future<void> _close(Future<void>? maintenance) async {
    try {
      try {
        await _service?.close();
      } finally {
        await maintenance;
      }
    } finally {
      await _reservation.release();
    }
  }
}

Future<void> suspendAttachmentRuntime(
  AccountId accountId,
  Future<AttachmentService> Function() readRuntime,
) async {
  var current = readRuntime();
  while (true) {
    try {
      await (await current).suspendAccount(accountId);
      return;
    } on AttachmentServiceClosed {
      final replacement = readRuntime();
      if (identical(replacement, current)) rethrow;
      current = replacement;
    }
  }
}
