import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';
import 'package:uuid/uuid.dart';

import '../../owntalk_extensions/owntalk_extensions_service.dart';
import 'account_collection_store.dart';

typedef DraftRoom = ({String accountId, String roomToken, int? threadId});
const draftHandoffFeature = 'personal.draftHandoff';

final class HandoffVersion {
  const HandoffVersion(this.id, this.baseId, this.text, this.replyTo);
  final String id;
  final String? baseId;
  final String text;
  final int? replyTo;

  Map<String, Object?> toJson() => {
    'id': id,
    'baseId': baseId,
    'text': text,
    'replyTo': replyTo,
  };

  factory HandoffVersion.read(Map<String, Object?> json) {
    final id = json['id'];
    final base = json['baseId'];
    final text = json['text'];
    final reply = json['replyTo'];
    if (id is! String ||
        !Uuid.isValidUUID(fromString: id) ||
        (base != null &&
            (base is! String || !Uuid.isValidUUID(fromString: base))) ||
        text is! String ||
        text.isEmpty ||
        text.runes.length > 32000 ||
        (reply != null && (reply is! int || reply <= 0))) {
      throw const FormatException('Invalid draft version');
    }
    return HandoffVersion(id, base as String?, text, reply as int?);
  }
}

typedef DraftHandoffRequest =
    Future<Map<String, dynamic>> Function({
      required String accountId,
      required String feature,
      required List<String> path,
      String method,
      Map<String, String>? query,
      Map<String, Object?>? values,
    });

final draftHandoffSupportProvider = FutureProvider.autoDispose
    .family<bool, String>(
      (ref, account) => ref
          .watch(ownTalkExtensionsServiceProvider)
          .supports(account, draftHandoffFeature),
    );

final draftHandoffProvider = Provider<DraftHandoffStore>((ref) {
  final store = DraftHandoffStore(
    ref.watch(ownTalkExtensionsServiceProvider).featureRequest,
  );
  ref.onDispose(store.dispose);
  return store;
});

/// Serializes local changes per account and network delivery per conversation.
/// A queued write keeps its immutable ID and body across failed responses.
final class DraftHandoffStore
    extends AccountCollectionStore<Map<String, Object?>> {
  DraftHandoffStore(this._request, {Directory? directory})
    : super('draft-handoff-v1', directory);
  final DraftHandoffRequest _request;
  final _enabled = <String, Future<bool>>{};
  final _generation = <String, int>{};
  final _syncing = <DraftRoom, Future<List<HandoffVersion>>>{};

  @override
  Map<String, Object?> decode(Map<String, Object?> json) => json;
  @override
  Map<String, Object?> encode(Map<String, Object?> entry) => entry;

  int generation(String id) => _generation[id] ?? 0;

  Future<bool> enabled(String id) => _enabled.putIfAbsent(id, () async {
    try {
      return (await read(AccountId.parse(id))).any(_setting);
    } on MissingPluginException {
      return false;
    }
  });
  static bool _setting(Map<String, Object?> row) => row['kind'] == 'enabled';

  Future<void> setEnabled(String id, bool value) async {
    _generation[id] = (_generation[id] ?? 0) + 1;
    final result = update(AccountId.parse(id), (rows) {
      if (!value) {
        rows.clear();
      } else if (!rows.any(_setting)) {
        rows.add({'kind': 'enabled'});
      }
    });
    _enabled[id] = result.then((_) => value)..ignore();
    try {
      await result;
    } catch (_) {
      _enabled.remove(id);
      rethrow;
    }
  }

  @override
  Future<void> delete(AccountId account) async {
    _generation[account.value] = (_generation[account.value] ?? 0) + 1;
    _enabled[account.value] = Future.value(false);
    await super.delete(account);
  }

  static bool _inRoom(Map<String, Object?> row, DraftRoom scope) =>
      row['room'] == scope.roomToken && row['thread'] == scope.threadId;
  static Map<String, Object?> _row(
    String kind,
    DraftRoom scope,
    HandoffVersion version,
  ) => {
    'kind': kind,
    'room': scope.roomToken,
    'thread': scope.threadId,
    ...version.toJson(),
  };

  Future<HandoffVersion?> stage(
    DraftRoom scope,
    String text,
    int? replyTo, {
    String? sendingDraftId,
  }) async {
    final start = generation(scope.accountId);
    if (text.trim().isEmpty ||
        !await enabled(scope.accountId) ||
        generation(scope.accountId) != start) {
      return null;
    }
    if (text.runes.length > 32000) {
      throw const FormatException('Draft too long');
    }
    final account = AccountId.parse(scope.accountId);
    HandoffVersion? result;
    await update(account, (rows) {
      if (generation(scope.accountId) != start || !rows.any(_setting)) return;
      final active = rows
          .where((r) => _inRoom(r, scope) && r['kind'] == 'current')
          .firstOrNull;
      if (active != null &&
          active['text'] == text &&
          active['replyTo'] == replyTo) {
        result = HandoffVersion.read(active);
        if (sendingDraftId != null) {
          active['kind'] = 'sending';
          active['draftId'] = sendingDraftId;
        }
        return;
      }
      var parent = active?['id'] as String?;
      final queued = rows
          .where(
            (r) =>
                _inRoom(r, scope) &&
                r['kind'] == 'put' &&
                r['id'] == parent &&
                r['started'] != true,
          )
          .firstOrNull;
      if (queued != null) {
        parent = queued['baseId'] as String?;
        rows.remove(queued);
      }
      final version = HandoffVersion(const Uuid().v4(), parent, text, replyTo);
      result = version;
      if (active != null) rows.remove(active);
      rows.add(_row('put', scope, version));
      rows.add({
        ..._row(sendingDraftId == null ? 'current' : 'sending', scope, version),
        'draftId': ?sendingDraftId,
      });
    });
    return result;
  }

  Future<HandoffVersion?> current(DraftRoom scope) async {
    final rows = await read(AccountId.parse(scope.accountId));
    final row = rows
        .where((r) => _inRoom(r, scope) && r['kind'] == 'current')
        .firstOrNull;
    return row == null ? null : HandoffVersion.read(row);
  }

  Future<HandoffVersion?> reserved(DraftRoom scope, String draftId) async {
    if (!await enabled(scope.accountId)) return null;
    final rows = await read(AccountId.parse(scope.accountId));
    final row = rows
        .where(
          (r) =>
              _inRoom(r, scope) &&
              r['kind'] == 'sending' &&
              r['draftId'] == draftId,
        )
        .firstOrNull;
    return row == null ? null : HandoffVersion.read(row);
  }

  Future<void> returnToComposer(DraftRoom scope, String draftId) async {
    if (!await enabled(scope.accountId)) return;
    await update(AccountId.parse(scope.accountId), (rows) {
      final reserved = rows
          .where(
            (r) =>
                _inRoom(r, scope) &&
                r['kind'] == 'sending' &&
                r['draftId'] == draftId,
          )
          .firstOrNull;
      if (reserved == null ||
          rows.any((r) => _inRoom(r, scope) && r['kind'] == 'current')) {
        return;
      }
      reserved['kind'] = 'current';
      reserved.remove('draftId');
    });
  }

  Future<void> clearCurrent(DraftRoom scope) async {
    final start = generation(scope.accountId);
    if (!await enabled(scope.accountId)) return;
    var changed = false;
    await update(AccountId.parse(scope.accountId), (rows) {
      if (generation(scope.accountId) != start || !rows.any(_setting)) return;
      final current = rows
          .where((r) => _inRoom(r, scope) && r['kind'] == 'current')
          .firstOrNull;
      if (current == null) return;
      current['kind'] = 'delete';
      changed = true;
    });
    if (changed) await sync(scope);
  }

  Future<void> admitted(
    DraftRoom scope,
    HandoffVersion version, {
    int? expectedGeneration,
  }) async {
    final start = expectedGeneration ?? generation(scope.accountId);
    if (!await enabled(scope.accountId)) return;
    await update(AccountId.parse(scope.accountId), (rows) {
      if (generation(scope.accountId) != start || !rows.any(_setting)) return;
      rows.removeWhere(
        (r) =>
            _inRoom(r, scope) &&
            r['kind'] == 'sending' &&
            r['id'] == version.id,
      );
      rows.add(_row('delete', scope, version));
    });
    await sync(scope);
  }

  Future<void> adopt(
    DraftRoom scope,
    HandoffVersion version, {
    bool Function()? stillCurrent,
  }) async {
    await update(AccountId.parse(scope.accountId), (rows) {
      if (!rows.any(_setting) || stillCurrent?.call() == false) return;
      rows.removeWhere((r) => _inRoom(r, scope) && r['kind'] == 'current');
      rows.add(_row('current', scope, version));
    });
  }

  Future<List<HandoffVersion>> sync(DraftRoom scope) {
    final previous = _syncing[scope];
    final next = (previous ?? Future.value(<HandoffVersion>[])).then(
      (_) => _sync(scope),
      onError: (Object _, StackTrace _) => _sync(scope),
    );
    _syncing[scope] = next;
    return next.whenComplete(() {
      if (identical(next, _syncing[scope])) _syncing.remove(scope);
    });
  }

  Future<List<HandoffVersion>> _sync(DraftRoom scope) async {
    final id = scope.accountId;
    if (!await enabled(id)) return [];
    final account = AccountId.parse(id);
    final generation = _generation[id] ?? 0;
    bool current() => (_generation[id] ?? 0) == generation;
    final path = ['room', scope.roomToken, 'drafts', '${scope.threadId ?? 0}'];
    final changes = (await read(account))
        .where(
          (row) =>
              _inRoom(row, scope) &&
              (row['kind'] == 'put' || row['kind'] == 'delete'),
        )
        .toList();
    Map<String, dynamic>? response;
    for (final change in changes) {
      if (!current()) return [];
      final version = HandoffVersion.read(change);
      final put = change['kind'] == 'put';
      if (put) {
        var claimed = false;
        await update(account, (rows) {
          final row = rows
              .where(
                (r) =>
                    _inRoom(r, scope) &&
                    r['kind'] == 'put' &&
                    r['id'] == version.id,
              )
              .firstOrNull;
          if (row != null && current() && rows.any(_setting)) {
            row['started'] = true;
            claimed = true;
          }
        });
        if (!claimed || !current()) continue;
      }
      response = await _request(
        accountId: id,
        feature: draftHandoffFeature,
        path: [...path, version.id],
        method: put ? 'PUT' : 'DELETE',
        values: put
            ? {
                'baseId': version.baseId,
                'text': version.text,
                'replyTo': version.replyTo,
              }
            : null,
      );
      if (!current()) return [];
      await update(
        account,
        (rows) => rows.removeWhere(
          (r) =>
              _inRoom(r, scope) &&
              r['kind'] == change['kind'] &&
              r['id'] == version.id,
        ),
      );
    }
    if (!current()) return [];
    response ??= await _request(
      accountId: id,
      feature: draftHandoffFeature,
      path: path,
      method: 'GET',
    );
    if (!current()) return [];
    final variants = response['variants'];
    if (variants is! List) throw const FormatException('Invalid draft list');
    return [
      for (final row in variants)
        if (row is Map<String, Object?>)
          HandoffVersion.read(row)
        else
          throw const FormatException('Invalid draft entry'),
    ];
  }
}
