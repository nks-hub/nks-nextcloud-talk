// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import 'package:talk_protocol/talk_protocol.dart';

import '../../data/credential_vault.dart';
import '../../network/nextcloud_api.dart';

/// App passwords the device still owes a `DELETE /core/apppassword` for.
///
/// An account removed while offline leaves its password valid on the server.
/// The removal service records it here and every drain (start, connectivity,
/// resume) retries the revocation. At most [maximumEntries] passwords are kept.
/// A full queue refuses another password instead of forgetting an unverified
/// revocation. Entries leave the queue only after a successful request or a
/// `401`, which means the password is already dead.
final class AppPasswordRevocationQueue {
  AppPasswordRevocationQueue({
    required PendingRevocationStore store,
    required HttpNextcloudApi api,
    DateTime Function()? now,
  }) : _store = store,
       _api = api,
       _now = now ?? DateTime.now;

  static const maximumEntries = 5;
  static const _drainConcurrency = 3;

  final PendingRevocationStore _store;
  final HttpNextcloudApi _api;
  final DateTime Function() _now;

  Future<void> record({
    required ServerBase server,
    required String loginName,
    required String appPassword,
  }) => _store.updatePendingRevocations((raw) {
    final entries = _decode(raw);
    final added = _Entry(
      server: server.uri.toString(),
      loginName: loginName,
      appPassword: appPassword,
      since: _now(),
      attempts: 0,
    );
    final existingIndex = entries.indexWhere(
      (entry) => entry.sameSecretAs(added),
    );
    if (existingIndex >= 0) {
      entries.removeAt(existingIndex);
    } else if (entries.length >= maximumEntries) {
      throw const AppPasswordRevocationQueueFull();
    }
    entries.add(added);
    return _encode(entries);
  });

  /// Refuses work that could mint another password when cleanup has no slot.
  Future<void> ensureCapacity() async {
    if ((await _load()).length >= maximumEntries) {
      throw const AppPasswordRevocationQueueFull();
    }
  }

  /// Number of revocations still owed; for diagnostics and tests.
  Future<int> pendingCount() async => (await _load()).length;

  Future<void> drain() async {
    final entries = await _load();
    if (entries.isEmpty) {
      return;
    }
    final outcomes = List<_Entry?>.filled(entries.length, null);
    var nextEntry = 0;

    Future<void> revokeNext() async {
      while (nextEntry < entries.length) {
        final index = nextEntry++;
        final entry = entries[index];
        if (await _revoked(entry)) {
          continue;
        }
        outcomes[index] = entry.afterAttempt();
      }
    }

    final workerCount = entries.length < _drainConcurrency
        ? entries.length
        : _drainConcurrency;
    await Future.wait(List.generate(workerCount, (_) => revokeNext()));
    final originalBySecret = <_Secret, int>{
      for (var index = 0; index < entries.length; index++)
        entries[index].secret: index,
    };
    await _store.updatePendingRevocations((raw) {
      final latest = _decode(raw);
      final reconciled = <_Entry>[];
      for (final current in latest) {
        final originalIndex = originalBySecret[current.secret];
        if (originalIndex == null ||
            !current.hasSameStateAs(entries[originalIndex])) {
          // Added, retried or re-recorded by another isolate while the network
          // calls were running. Its newer state belongs to the next drain.
          reconciled.add(current);
          continue;
        }
        final outcome = outcomes[originalIndex];
        if (outcome != null) {
          reconciled.add(outcome);
        }
      }
      return _encode(reconciled);
    });
  }

  Future<bool> _revoked(_Entry entry) async {
    final ServerBase server;
    try {
      server = ServerBase.parse(entry.server);
    } on TalkProtocolException {
      return false;
    }
    try {
      await _api.revokeAppPassword(
        server: server,
        loginName: entry.loginName,
        appPassword: entry.appPassword,
      );
      return true;
    } on NextcloudApiException catch (error) {
      // Already revoked elsewhere: nothing left to destroy.
      return error.statusCode == 401;
    } on Object {
      return false;
    }
  }

  Future<List<_Entry>> _load() async =>
      _decode(await _store.readPendingRevocations());

  List<_Entry> _decode(String? raw) {
    if (raw == null || raw.isEmpty) {
      return <_Entry>[];
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return <_Entry>[];
    }
    if (decoded is! List) {
      return <_Entry>[];
    }
    return <_Entry>[
      for (final item in decoded)
        if (item is Map<String, Object?>) ?_Entry.fromJson(item),
    ];
  }

  String? _encode(List<_Entry> entries) => entries.isEmpty
      ? null
      : jsonEncode([for (final entry in entries) entry.toJson()]);
}

final class AppPasswordRevocationQueueFull implements Exception {
  const AppPasswordRevocationQueueFull();

  @override
  String toString() => 'AppPasswordRevocationQueueFull';
}

typedef _Secret = ({String server, String loginName, String appPassword});

final class _Entry {
  const _Entry({
    required this.server,
    required this.loginName,
    required this.appPassword,
    required this.since,
    required this.attempts,
  });

  final String server;
  final String loginName;
  final String appPassword;
  final DateTime since;
  final int attempts;

  _Secret get secret =>
      (server: server, loginName: loginName, appPassword: appPassword);

  bool sameSecretAs(_Entry other) => secret == other.secret;

  bool hasSameStateAs(_Entry other) =>
      sameSecretAs(other) && since == other.since && attempts == other.attempts;

  static _Entry? fromJson(Map<String, Object?> json) {
    final server = json['server'];
    final loginName = json['loginName'];
    final appPassword = json['appPassword'];
    final since = json['since'];
    final attempts = json['attempts'];
    if (server is! String ||
        loginName is! String ||
        appPassword is! String ||
        since is! String ||
        attempts is! int) {
      return null;
    }
    final parsedSince = DateTime.tryParse(since);
    if (parsedSince == null) {
      return null;
    }
    return _Entry(
      server: server,
      loginName: loginName,
      appPassword: appPassword,
      since: parsedSince,
      attempts: attempts,
    );
  }

  Map<String, Object?> toJson() => {
    'server': server,
    'loginName': loginName,
    'appPassword': appPassword,
    'since': since.toUtc().toIso8601String(),
    'attempts': attempts,
  };

  _Entry afterAttempt() => _Entry(
    server: server,
    loginName: loginName,
    appPassword: appPassword,
    since: since,
    attempts: attempts + 1,
  );
}
