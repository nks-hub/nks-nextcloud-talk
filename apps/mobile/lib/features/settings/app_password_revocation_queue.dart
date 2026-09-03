// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import 'package:talk_protocol/talk_protocol.dart';

import '../../data/credential_vault.dart';
import '../../network/nextcloud_api.dart';

/// App passwords the device still owes a `DELETE /core/apppassword` for.
///
/// An account removed while offline leaves its password valid on the server.
/// The removal service records it here and every drain (start, connectivity,
/// resume) retries the revocation. The queue is bounded twice over: at most
/// [maximumEntries] passwords are kept (the oldest goes first), and each one
/// is given up after [maximumAttempts] tries or [maximumAge], whichever comes
/// first — a server that is gone for good must not keep a secret alive on the
/// device forever. A `401` means the password is already dead and counts as
/// done.
final class AppPasswordRevocationQueue {
  AppPasswordRevocationQueue({
    required PendingRevocationStore store,
    required HttpNextcloudApi api,
    DateTime Function()? now,
  }) : _store = store,
       _api = api,
       _now = now ?? DateTime.now;

  static const maximumEntries = 5;
  static const maximumAttempts = 20;
  static const maximumAge = Duration(days: 14);

  final PendingRevocationStore _store;
  final HttpNextcloudApi _api;
  final DateTime Function() _now;

  Future<void> record({
    required ServerBase server,
    required String loginName,
    required String appPassword,
  }) async {
    final entries = await _load();
    entries.removeWhere(
      (entry) =>
          entry.server == server.uri.toString() &&
          entry.loginName == loginName &&
          entry.appPassword == appPassword,
    );
    entries.add(
      _Entry(
        server: server.uri.toString(),
        loginName: loginName,
        appPassword: appPassword,
        since: _now(),
        attempts: 0,
      ),
    );
    while (entries.length > maximumEntries) {
      entries.removeAt(0);
    }
    await _save(entries);
  }

  /// Number of revocations still owed; for diagnostics and tests.
  Future<int> pendingCount() async => (await _load()).length;

  Future<void> drain() async {
    final entries = await _load();
    if (entries.isEmpty) {
      return;
    }
    final remaining = <_Entry>[];
    final now = _now();
    for (final entry in entries) {
      if (await _revoked(entry)) {
        continue;
      }
      final next = entry.afterAttempt();
      if (next.attempts >= maximumAttempts ||
          now.difference(next.since) >= maximumAge) {
        continue;
      }
      remaining.add(next);
    }
    await _save(remaining);
  }

  Future<bool> _revoked(_Entry entry) async {
    final ServerBase server;
    try {
      server = ServerBase.parse(entry.server);
    } on TalkProtocolException {
      return true;
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

  Future<List<_Entry>> _load() async {
    final raw = await _store.readPendingRevocations();
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

  Future<void> _save(List<_Entry> entries) => _store.writePendingRevocations(
    entries.isEmpty
        ? null
        : jsonEncode([for (final entry in entries) entry.toJson()]),
  );
}

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
