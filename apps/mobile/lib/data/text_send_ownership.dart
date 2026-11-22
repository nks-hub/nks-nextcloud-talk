import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:talk_protocol/talk_protocol.dart';
import 'package:uuid/uuid.dart';

/// Live ownership is held outside SQLite so a dead engine leaves nothing
/// behind that can block restart recovery.
abstract interface class TextSendOwnership {
  Future<TextSendReservation?> acquire(String accountId, ChatOperationId id);

  Future<Set<ChatOperationId>> active(String accountId);
}

final class TextSendReservation {
  const TextSendReservation(this.release);

  final Future<void> Function() release;
}

final _localOwnership = LocalTextSendOwnership();

TextSendOwnership textSendOwnership() => !kIsWeb && Platform.isAndroid
    ? const _AndroidTextSendOwnership()
    : _localOwnership;

final class LocalTextSendOwnership implements TextSendOwnership {
  final _owners = <(String, ChatOperationId), Object>{};

  @override
  Future<TextSendReservation?> acquire(
    String accountId,
    ChatOperationId id,
  ) async {
    final key = (accountId, id);
    if (_owners.containsKey(key)) return null;
    final owner = Object();
    _owners[key] = owner;
    return TextSendReservation(() async {
      if (identical(_owners[key], owner)) _owners.remove(key);
    });
  }

  @override
  Future<Set<ChatOperationId>> active(String accountId) async => {
    for (final (account, id) in _owners.keys)
      if (account == accountId) id,
  };
}

final class _AndroidTextSendOwnership implements TextSendOwnership {
  const _AndroidTextSendOwnership();

  static const _channel = MethodChannel('com.nkshub.nextcloudtalk/text_sends');

  @override
  Future<TextSendReservation?> acquire(
    String accountId,
    ChatOperationId id,
  ) async {
    final arguments = <String, String>{
      'accountId': accountId,
      'operationId': id.value,
      'token': const Uuid().v4(),
    };
    if (await _channel.invokeMethod<bool>('acquire', arguments) != true) {
      return null;
    }
    return TextSendReservation(
      () => _channel.invokeMethod<void>('release', arguments),
    );
  }

  @override
  Future<Set<ChatOperationId>> active(String accountId) async {
    final operations = await _channel.invokeListMethod<String>(
      'active',
      <String, String>{'accountId': accountId},
    );
    if (operations == null) throw StateError('Missing text send ownership');
    return operations.map(ChatOperationId.parse).toSet();
  }
}
