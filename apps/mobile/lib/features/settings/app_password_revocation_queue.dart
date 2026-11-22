// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

import 'package:talk_protocol/talk_protocol.dart';
import 'package:uuid/uuid.dart';

import '../../data/account_repository.dart';
import '../../data/credential_vault.dart';
import '../../network/account_http_client.dart';
import '../../network/nextcloud_api.dart';

part 'app_password_browser_recovery.dart';

/// App passwords the device still owes a `DELETE /core/apppassword` for.
///
/// Every entry is durable before its local owner disappears. A one-shot login
/// first stores a reservation, then atomically replaces it with either a held
/// credential or a pending revocation. Held credentials are ignored by
/// [drain] while onboarding commits their account. Entries leave the queue
/// only after a successful request, a `401`, a safe owner handoff, or once a
/// revocation failed [maximumAttempts] times and is older than [maximumAge].
final class AppPasswordRevocationQueue {
  AppPasswordRevocationQueue({
    required PendingRevocationStore store,
    required HttpNextcloudApi api,
    AccountRepository? accounts,
    CredentialVault? credentials,
    DateTime Function()? now,
    String Function()? reservationId,
  }) : _store = store,
       _api = api,
       _accounts = accounts,
       _credentials = credentials,
       _now = now ?? DateTime.now,
       _reservationId = reservationId ?? const Uuid().v4;

  static const maximumEntries = 5;

  /// A failing revocation is given up only once both limits are reached, so
  /// an outage keeps it while a server gone for good cannot fill the queue.
  static const maximumAttempts = 20;
  static const maximumAge = Duration(days: 14);
  static const _drainConcurrency = 3;
  static final _localClaims = Expando<Map<String, String>>();

  final PendingRevocationStore _store;
  final HttpNextcloudApi _api;
  final AccountRepository? _accounts;
  final CredentialVault? _credentials;
  final DateTime Function() _now;
  final String Function() _reservationId;
  Future<void> _recoveryTail = Future<void>.value();

  Future<void> record({
    required ServerBase server,
    required String loginName,
    required String appPassword,
  }) => _store.updatePendingRevocations((raw) {
    final entries = _decode(raw);
    final existingIndex = entries.indexWhere(
      (entry) => entry.hasSecret(server, loginName, appPassword),
    );
    if (existingIndex >= 0) {
      final existing = entries[existingIndex];
      if (existing is _HeldEntry) {
        entries[existingIndex] = existing.pending();
        return _encode(entries);
      }
      return raw;
    }
    _requireCapacity(entries);
    entries.add(
      _RevocationEntry(
        reservationId: null,
        server: server.uri.toString(),
        loginName: loginName,
        appPassword: appPassword,
        since: _now(),
        attempts: 0,
      ),
    );
    return _encode(entries);
  });

  /// Atomically reserves one durable slot before a one-shot request is sent.
  Future<AppPasswordRevocationReservation> reserve({
    PendingLogin? browser,
  }) async {
    final reservation = await _claimNewReservation();
    try {
      await _store.updatePendingRevocations((raw) {
        final entries = _decode(raw);
        if (entries.any((entry) => entry.reservationId == reservation.id)) {
          throw const AppPasswordRevocationQueueCorrupt();
        }
        _requireCapacity(entries);
        entries.add(
          _ReservationEntry(
            id: reservation.id,
            since: _now(),
            browser: browser == null ? null : _BrowserPoll.fromPending(browser),
          ),
        );
        return _encode(entries);
      });
    } on Object {
      await abandonHeldCredential(reservation);
      rethrow;
    }
    return reservation;
  }

  Future<void> holdCredential({
    required AppPasswordRevocationReservation reservation,
    required ServerBase server,
    required String loginName,
    required String appPassword,
  }) => _resolveReservation(
    reservation: reservation,
    server: server,
    loginName: loginName,
    appPassword: appPassword,
    pending: false,
  );

  Future<void> queueCredential({
    required AppPasswordRevocationReservation reservation,
    required ServerBase server,
    required String loginName,
    required String appPassword,
  }) async {
    await _resolveReservation(
      reservation: reservation,
      server: server,
      loginName: loginName,
      appPassword: appPassword,
      pending: true,
    );
    await _releaseClaim(reservation);
  }

  Future<void> _resolveReservation({
    required AppPasswordRevocationReservation reservation,
    required ServerBase server,
    required String loginName,
    required String appPassword,
    required bool pending,
  }) => _store.updatePendingRevocations((raw) {
    final entries = _decode(raw);
    final index = entries.indexWhere(
      (entry) => entry.reservationId == reservation.id,
    );
    if (index < 0) {
      throw const AppPasswordRevocationReservationMissing();
    }
    final existing = entries[index];
    if (existing is _ReservationEntry) {
      final duplicate = entries.indexWhere(
        (entry) => entry.hasSecret(server, loginName, appPassword),
      );
      if (duplicate >= 0) {
        throw const AppPasswordRevocationQueueCorrupt();
      }
      entries[index] = pending
          ? _RevocationEntry(
              reservationId: reservation.id,
              server: server.uri.toString(),
              loginName: loginName,
              appPassword: appPassword,
              since: existing.since,
              attempts: 0,
            )
          : _HeldEntry(
              id: reservation.id,
              server: server.uri.toString(),
              loginName: loginName,
              appPassword: appPassword,
              since: existing.since,
              phase: AppPasswordCredentialPhase.received,
              accountId: null,
            );
      return _encode(entries);
    }
    if (!existing.hasSecret(server, loginName, appPassword)) {
      throw const AppPasswordRevocationQueueCorrupt();
    }
    if (pending && existing is _HeldEntry) {
      entries[index] = existing.pending();
      return _encode(entries);
    }
    return raw;
  });

  /// Atomically reserves a known credential before local account removal.
  Future<AppPasswordRevocationReservation> reserveCredentialForRemoval({
    required ServerBase server,
    required String loginName,
    required String appPassword,
    required String accountId,
    String? certificateFingerprint,
  }) async {
    if (accountId.isEmpty) {
      throw const AppPasswordRevocationQueueCorrupt();
    }
    final reservation = await _claimNewReservation();
    try {
      await _store.updatePendingRevocations((raw) {
        final entries = _decode(raw);
        if (entries.any((entry) => entry.reservationId == reservation.id) ||
            entries.any(
              (entry) => entry.hasSecret(server, loginName, appPassword),
            )) {
          throw const AppPasswordRevocationQueueCorrupt();
        }
        _requireCapacity(entries);
        entries.add(
          _HeldEntry(
            id: reservation.id,
            server: server.uri.toString(),
            loginName: loginName,
            appPassword: appPassword,
            since: _now(),
            phase: AppPasswordCredentialPhase.removalReserved,
            accountId: accountId,
            certificateFingerprint: certificateFingerprint,
          ),
        );
        return _encode(entries);
      });
    } on Object {
      await abandonHeldCredential(reservation);
      rethrow;
    }
    return reservation;
  }

  Future<void> updateHeldCredentialPhase({
    required AppPasswordRevocationReservation reservation,
    required AppPasswordCredentialPhase phase,
    required String accountId,
  }) => _store.updatePendingRevocations((raw) {
    if (accountId.isEmpty ||
        phase == AppPasswordCredentialPhase.received ||
        phase == AppPasswordCredentialPhase.removalReserved) {
      throw const AppPasswordRevocationQueueCorrupt();
    }
    final entries = _decode(raw);
    final index = entries.indexWhere(
      (entry) => entry.reservationId == reservation.id,
    );
    if (index < 0 || entries[index] is! _HeldEntry) {
      throw const AppPasswordRevocationReservationMissing();
    }
    final held = entries[index] as _HeldEntry;
    if (held.phase == AppPasswordCredentialPhase.removalReserved ||
        (held.accountId != null && held.accountId != accountId) ||
        phase.index < held.phase.index) {
      throw const AppPasswordRevocationQueueCorrupt();
    }
    entries[index] = held.withPhase(phase: phase, accountId: accountId);
    return _encode(entries);
  });

  Future<void> releaseReservation(
    AppPasswordRevocationReservation reservation,
  ) async {
    await _store.updatePendingRevocations((raw) {
      final entries = _decode(raw);
      final index = entries.indexWhere(
        (entry) => entry.reservationId == reservation.id,
      );
      if (index < 0 || entries[index] is! _ReservationEntry) {
        return raw;
      }
      entries.removeAt(index);
      return _encode(entries);
    });
    await _releaseClaim(reservation);
  }

  Future<void> releaseHeldCredential(
    AppPasswordRevocationReservation reservation,
  ) async {
    await _store.updatePendingRevocations((raw) {
      final entries = _decode(raw);
      final index = entries.indexWhere(
        (entry) => entry.reservationId == reservation.id,
      );
      if (index < 0) {
        return raw;
      }
      if (entries[index] is! _HeldEntry) {
        throw const AppPasswordRevocationQueueCorrupt();
      }
      entries.removeAt(index);
      return _encode(entries);
    });
    await _releaseClaim(reservation);
  }

  Future<void> releaseRevokedCredential(
    AppPasswordRevocationReservation reservation,
  ) async {
    await _store.updatePendingRevocations((raw) {
      final entries = _decode(raw);
      entries.removeWhere((entry) => entry.reservationId == reservation.id);
      return _encode(entries);
    });
    await _releaseClaim(reservation);
  }

  /// Allows recovery after a failed operation without changing durable state.
  Future<void> abandonHeldCredential(
    AppPasswordRevocationReservation reservation,
  ) async {
    try {
      await _releaseClaim(reservation);
    } on Object {
      // Engine shutdown releases the claim if the channel is already gone.
    }
  }

  Future<AppPasswordRevocationReservation> _claimNewReservation() async {
    final id = _reservationId();
    if (id.isEmpty) throw const AppPasswordRevocationQueueCorrupt();
    final reservation = await _tryClaim(id);
    if (reservation == null) throw const AppPasswordRevocationQueueCorrupt();
    return reservation;
  }

  Future<AppPasswordRevocationReservation?> _tryClaim(String id) async {
    final token = const Uuid().v4();
    final store = _store;
    if (store is PendingRevocationClaims) {
      if (!await (store as PendingRevocationClaims).tryClaimRevocation(
        id,
        token,
      )) {
        return null;
      }
    } else {
      final claims = _localClaims[store] ??= <String, String>{};
      if (claims.containsKey(id)) return null;
      claims[id] = token;
    }
    return AppPasswordRevocationReservation._(id, token);
  }

  Future<void> _releaseClaim(
    AppPasswordRevocationReservation reservation,
  ) async {
    final store = _store;
    if (store is PendingRevocationClaims) {
      await (store as PendingRevocationClaims).releaseRevocationClaim(
        reservation.id,
        reservation._token,
      );
    } else {
      final claims = _localClaims[store];
      if (claims?[reservation.id] == reservation._token) {
        claims!.remove(reservation.id);
      }
    }
  }

  Future<int> pendingCount() async => (await _load()).length;

  Future<int> unresolvedReservationCount() async =>
      (await _load()).whereType<_ReservationEntry>().length;

  Future<int> pendingRevocationCount() async =>
      (await _load()).whereType<_RevocationEntry>().length;

  Future<void> drain() => _store.withPendingRevocationDrain(_drain);

  Future<void> _drain() async {
    await recoverHeldCredentials();
    final entries = await _load();
    final revocations = entries.whereType<_RevocationEntry>().toList();
    if (revocations.isEmpty) {
      return;
    }
    final outcomes = <_QueueIdentity, _RevocationEntry?>{};
    var nextEntry = 0;

    Future<void> revokeNext() async {
      while (nextEntry < revocations.length) {
        final entry = revocations[nextEntry++];
        if (entry.fromBrowserLogin) {
          await _attemptBrowserRevocation(entry);
        } else if (await _revoked(entry)) {
          outcomes[entry.identity] = null;
        } else {
          final next = entry.afterAttempt();
          outcomes[entry.identity] = _givenUp(next) ? null : next;
        }
      }
    }

    final workerCount = revocations.length < _drainConcurrency
        ? revocations.length
        : _drainConcurrency;
    await Future.wait(List.generate(workerCount, (_) => revokeNext()));
    final originalByIdentity = <_QueueIdentity, _QueueEntry>{
      for (final entry in entries) entry.identity: entry,
    };
    await _store.updatePendingRevocations((raw) {
      final latest = _decode(raw);
      final reconciled = <_QueueEntry>[];
      for (final current in latest) {
        final original = originalByIdentity[current.identity];
        if (original == null || !current.hasSameStateAs(original)) {
          reconciled.add(current);
          continue;
        }
        if (current is! _RevocationEntry || current.fromBrowserLogin) {
          reconciled.add(current);
          continue;
        }
        final outcome = outcomes[current.identity];
        if (outcome != null) {
          reconciled.add(outcome);
        }
      }
      return _encode(reconciled);
    });
  }

  /// Reconciles known credentials left in a held state by a process exit.
  ///
  /// A matching account and vault value own an onboarding credential. A
  /// removal reservation is released only while both still exist, proving
  /// local deletion never completed. Every other known credential becomes a
  /// retryable server revocation, after an orphaned vault value is removed.
  Future<void> recoverHeldCredentials({
    AccountRepository? accounts,
    CredentialVault? credentials,
  }) {
    final recoveryAccounts = accounts ?? _accounts;
    final recoveryCredentials = credentials ?? _credentials;
    if (recoveryAccounts == null || recoveryCredentials == null) {
      return Future<void>.value();
    }
    final recovery = _recoveryTail.then((_) async {
      for (final held in (await _load()).whereType<_HeldEntry>()) {
        final reservation = await _tryClaim(held.id);
        if (reservation == null) continue;
        try {
          if (!(await _load()).any(held.hasSameStateAs)) continue;
          if (held.fromBrowserLogin) {
            await _recoverBrowserHeldCredential(
              held,
              recoveryAccounts,
              recoveryCredentials,
            );
          } else {
            await _recoverHeldCredential(
              held,
              recoveryAccounts,
              recoveryCredentials,
            );
          }
        } finally {
          await abandonHeldCredential(reservation);
        }
      }
    });
    _recoveryTail = recovery.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return recovery;
  }

  Future<void> _recoverHeldCredential(
    _HeldEntry held,
    AccountRepository accounts,
    CredentialVault credentials,
  ) async {
    final accountId = held.accountId;
    final account = accountId == null
        ? await accounts.findByIdentity(
            serverUrl: held.server,
            loginName: held.loginName,
          )
        : await accounts.getAccount(accountId);
    final vaultAccountId = accountId ?? account?.id;
    final storedPassword = vaultAccountId == null
        ? null
        : await credentials.readCurrentAppPassword(vaultAccountId);
    final matchingPassword = storedPassword == held.appPassword;
    final keepAccount = account != null && matchingPassword;
    if (keepAccount &&
        (account.serverUrl != held.server ||
            account.loginName != held.loginName)) {
      throw const AppPasswordRevocationQueueCorrupt();
    }
    if (account == null && accountId != null && matchingPassword) {
      await credentials.deleteAppPassword(accountId);
    }
    await _store.updatePendingRevocations((raw) {
      final entries = _decode(raw);
      final index = entries.indexWhere(held.hasSameStateAs);
      if (index < 0) return raw;
      if (keepAccount) {
        entries.removeAt(index);
      } else {
        entries[index] = held.pending();
      }
      return _encode(entries);
    });
  }

  Future<bool> _revoked(_RevocationEntry entry) async {
    final ServerBase server;
    try {
      server = ServerBase.parse(entry.server);
    } on TalkProtocolException {
      return false;
    }
    final abort = Completer<void>();
    HttpNextcloudApi? pinnedApi;
    try {
      final fingerprint = entry.certificateFingerprint;
      if (fingerprint != null) {
        pinnedApi = HttpNextcloudApi(
          client: createPinnedRevocationClient(
            server: server,
            fingerprint: fingerprint,
          ),
          requestTimeout: _api.requestTimeout,
        );
      }
      await (pinnedApi ?? _api).revokeAppPassword(
        server: server,
        loginName: entry.loginName,
        appPassword: entry.appPassword,
        abortTrigger: abort.future,
      );
      return true;
    } on NextcloudApiException catch (error) {
      if (error.code == NextcloudApiError.timeout) {
        abort.complete();
      }
      return error.statusCode == 401;
    } on Object {
      return false;
    } finally {
      pinnedApi?.close();
    }
  }

  bool _givenUp(_RevocationEntry entry) =>
      entry.attempts >= maximumAttempts &&
      _now().difference(entry.since) >= maximumAge;

  Future<List<_QueueEntry>> _load() async =>
      _decode(await _store.readPendingRevocations());

  void _requireCapacity(List<_QueueEntry> entries) {
    if (entries.length >= maximumEntries) {
      throw const AppPasswordRevocationQueueFull();
    }
  }

  List<_QueueEntry> _decode(String? raw) {
    if (raw == null || raw.isEmpty) {
      return <_QueueEntry>[];
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const AppPasswordRevocationQueueCorrupt();
    }
    if (decoded is! List<Object?>) {
      throw const AppPasswordRevocationQueueCorrupt();
    }
    final entries = <_QueueEntry>[];
    for (final item in decoded) {
      if (item is! Map<String, Object?>) {
        throw const AppPasswordRevocationQueueCorrupt();
      }
      final entry = _QueueEntry.fromJson(item);
      if (entry == null) {
        throw const AppPasswordRevocationQueueCorrupt();
      }
      entries.add(entry);
    }
    if (entries.length > maximumEntries) {
      throw const AppPasswordRevocationQueueCorrupt();
    }
    final identities = <_QueueIdentity>{};
    final secrets = <_Secret>{};
    for (final entry in entries) {
      if (!identities.add(entry.identity)) {
        throw const AppPasswordRevocationQueueCorrupt();
      }
      final secret = entry.secret;
      if (secret != null && !secrets.add(secret)) {
        throw const AppPasswordRevocationQueueCorrupt();
      }
    }
    return entries;
  }

  String? _encode(List<_QueueEntry> entries) => entries.isEmpty
      ? null
      : jsonEncode([for (final entry in entries) entry.toJson()]);
}

final class AppPasswordRevocationReservation {
  const AppPasswordRevocationReservation._(this.id, this._token);

  final String id;
  final String _token;
}

enum AppPasswordCredentialPhase {
  received,
  prepared,
  vaultWritten,
  accountCommitted,
  removalReserved,
}

final class AppPasswordRevocationQueueFull implements Exception {
  const AppPasswordRevocationQueueFull();
}

final class AppPasswordRevocationQueueCorrupt implements Exception {
  const AppPasswordRevocationQueueCorrupt();
}

final class AppPasswordRevocationReservationMissing implements Exception {
  const AppPasswordRevocationReservationMissing();
}

typedef _Secret = ({String server, String loginName, String appPassword});
typedef _QueueIdentity = ({String kind, String value});

sealed class _QueueEntry {
  const _QueueEntry();

  String? get reservationId;
  _QueueIdentity get identity;
  _Secret? get secret;

  bool hasSecret(ServerBase server, String loginName, String appPassword) =>
      secret ==
      (
        server: server.uri.toString(),
        loginName: loginName,
        appPassword: appPassword,
      );

  bool hasSameStateAs(_QueueEntry other);
  Map<String, Object?> toJson();

  static _QueueEntry? fromJson(Map<String, Object?> json) {
    return switch (json['kind']) {
      'reservation' => _ReservationEntry.fromJson(json),
      'held' => _HeldEntry.fromJson(json),
      'revocation' || null => _RevocationEntry.fromJson(json),
      _ => null,
    };
  }
}

final class _ReservationEntry extends _QueueEntry {
  const _ReservationEntry({
    required this.id,
    required this.since,
    this.browser,
  });

  final String id;
  final DateTime since;
  final _BrowserPoll? browser;

  @override
  String get reservationId => id;

  @override
  _QueueIdentity get identity => (kind: 'reservation', value: id);

  @override
  _Secret? get secret => null;

  @override
  bool hasSameStateAs(_QueueEntry other) =>
      other is _ReservationEntry &&
      id == other.id &&
      since == other.since &&
      browser?.coordinates == other.browser?.coordinates;

  static _ReservationEntry? fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final since = json['since'];
    if (id is! String || id.isEmpty || since is! String) {
      return null;
    }
    final parsedSince = DateTime.tryParse(since);
    final rawBrowser = json['browser'];
    final browser = _BrowserPoll.fromJson(rawBrowser);
    return parsedSince == null || (rawBrowser != null && browser == null)
        ? null
        : _ReservationEntry(id: id, since: parsedSince, browser: browser);
  }

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'reservation',
    'id': id,
    'since': since.toUtc().toIso8601String(),
    if (browser case final poll?) 'browser': poll.toJson(),
  };
}

final class _HeldEntry extends _QueueEntry {
  const _HeldEntry({
    required this.id,
    required this.server,
    required this.loginName,
    required this.appPassword,
    required this.since,
    required this.phase,
    required this.accountId,
    this.certificateFingerprint,
    this.fromBrowserLogin = false,
  });

  final String id;
  final String server;
  final String loginName;
  final String appPassword;
  final DateTime since;
  final AppPasswordCredentialPhase phase;
  final String? accountId;
  final String? certificateFingerprint;
  final bool fromBrowserLogin;

  @override
  String get reservationId => id;

  @override
  _QueueIdentity get identity => (kind: 'reservation', value: id);

  @override
  _Secret get secret =>
      (server: server, loginName: loginName, appPassword: appPassword);

  _RevocationEntry pending() => _RevocationEntry(
    reservationId: id,
    server: server,
    loginName: loginName,
    appPassword: appPassword,
    since: since,
    attempts: 0,
    certificateFingerprint: certificateFingerprint,
    fromBrowserLogin: fromBrowserLogin,
  );

  _HeldEntry withPhase({
    required AppPasswordCredentialPhase phase,
    required String accountId,
  }) => _HeldEntry(
    id: id,
    server: server,
    loginName: loginName,
    appPassword: appPassword,
    since: since,
    phase: phase,
    accountId: accountId,
    certificateFingerprint: certificateFingerprint,
    fromBrowserLogin: fromBrowserLogin,
  );

  @override
  bool hasSameStateAs(_QueueEntry other) =>
      other is _HeldEntry &&
      id == other.id &&
      secret == other.secret &&
      since == other.since &&
      phase == other.phase &&
      accountId == other.accountId &&
      certificateFingerprint == other.certificateFingerprint &&
      fromBrowserLogin == other.fromBrowserLogin;

  static _HeldEntry? fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final server = json['server'];
    final loginName = json['loginName'];
    final appPassword = json['appPassword'];
    final since = json['since'];
    final phaseName = json['phase'];
    final accountId = json['accountId'];
    final certificateFingerprint = json['certificateFingerprint'];
    final fromBrowserLogin = json['fromBrowserLogin'];
    if (fromBrowserLogin != null && fromBrowserLogin is! bool) return null;
    if (id is! String ||
        id.isEmpty ||
        server is! String ||
        loginName is! String ||
        appPassword is! String ||
        appPassword.isEmpty ||
        since is! String ||
        (phaseName != null && phaseName is! String) ||
        (certificateFingerprint != null && certificateFingerprint is! String) ||
        (accountId != null && (accountId is! String || accountId.isEmpty))) {
      return null;
    }
    final parsedSince = DateTime.tryParse(since);
    final phase = phaseName == null
        ? AppPasswordCredentialPhase.received
        : switch (phaseName) {
            'received' => AppPasswordCredentialPhase.received,
            'prepared' => AppPasswordCredentialPhase.prepared,
            'vaultWritten' => AppPasswordCredentialPhase.vaultWritten,
            'accountCommitted' => AppPasswordCredentialPhase.accountCommitted,
            'removalReserved' => AppPasswordCredentialPhase.removalReserved,
            _ => null,
          };
    if (parsedSince == null ||
        phase == null ||
        (certificateFingerprint != null &&
            phase != AppPasswordCredentialPhase.removalReserved)) {
      return null;
    }
    if (phase != AppPasswordCredentialPhase.received && accountId == null) {
      return null;
    }
    try {
      ServerBase.parse(server);
    } on TalkProtocolException {
      return null;
    }
    return _HeldEntry(
      id: id,
      server: server,
      loginName: loginName,
      appPassword: appPassword,
      since: parsedSince,
      phase: phase,
      accountId: accountId as String?,
      certificateFingerprint: certificateFingerprint as String?,
      fromBrowserLogin: fromBrowserLogin == true,
    );
  }

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'held',
    'id': id,
    'server': server,
    'loginName': loginName,
    'appPassword': appPassword,
    'since': since.toUtc().toIso8601String(),
    'phase': phase.name,
    'accountId': ?accountId,
    'certificateFingerprint': ?certificateFingerprint,
    if (fromBrowserLogin) 'fromBrowserLogin': true,
  };
}

final class _RevocationEntry extends _QueueEntry {
  const _RevocationEntry({
    required this.reservationId,
    required this.server,
    required this.loginName,
    required this.appPassword,
    required this.since,
    required this.attempts,
    this.certificateFingerprint,
    this.fromBrowserLogin = false,
  });

  @override
  final String? reservationId;
  final String server;
  final String loginName;
  final String appPassword;
  final DateTime since;
  final int attempts;
  final String? certificateFingerprint;
  final bool fromBrowserLogin;

  @override
  _QueueIdentity get identity => reservationId == null
      ? (
          kind: 'secret',
          value: jsonEncode(<String>[server, loginName, appPassword]),
        )
      : (kind: 'reservation', value: reservationId!);

  @override
  _Secret get secret =>
      (server: server, loginName: loginName, appPassword: appPassword);

  @override
  bool hasSameStateAs(_QueueEntry other) =>
      other is _RevocationEntry &&
      reservationId == other.reservationId &&
      secret == other.secret &&
      since == other.since &&
      attempts == other.attempts &&
      certificateFingerprint == other.certificateFingerprint &&
      fromBrowserLogin == other.fromBrowserLogin;

  static _RevocationEntry? fromJson(Map<String, Object?> json) {
    final reservationId = json['reservationId'];
    final server = json['server'];
    final loginName = json['loginName'];
    final appPassword = json['appPassword'];
    final since = json['since'];
    final attempts = json['attempts'];
    final certificateFingerprint = json['certificateFingerprint'];
    final fromBrowserLogin = json['fromBrowserLogin'];
    if (fromBrowserLogin != null && fromBrowserLogin is! bool) return null;
    if ((reservationId != null &&
            (reservationId is! String || reservationId.isEmpty)) ||
        server is! String ||
        loginName is! String ||
        appPassword is! String ||
        appPassword.isEmpty ||
        since is! String ||
        (certificateFingerprint != null &&
            (certificateFingerprint is! String || reservationId == null)) ||
        attempts is! int ||
        attempts < 0) {
      return null;
    }
    final parsedSince = DateTime.tryParse(since);
    return parsedSince == null
        ? null
        : _RevocationEntry(
            reservationId: reservationId as String?,
            server: server,
            loginName: loginName,
            appPassword: appPassword,
            since: parsedSince,
            attempts: attempts,
            certificateFingerprint: certificateFingerprint as String?,
            fromBrowserLogin: fromBrowserLogin == true,
          );
  }

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'revocation',
    'reservationId': ?reservationId,
    'server': server,
    'loginName': loginName,
    'appPassword': appPassword,
    'since': since.toUtc().toIso8601String(),
    'attempts': attempts,
    'certificateFingerprint': ?certificateFingerprint,
    if (fromBrowserLogin) 'fromBrowserLogin': true,
  };

  _RevocationEntry afterAttempt() => _RevocationEntry(
    reservationId: reservationId,
    server: server,
    loginName: loginName,
    appPassword: appPassword,
    since: since,
    attempts: attempts + 1,
    certificateFingerprint: certificateFingerprint,
    fromBrowserLogin: fromBrowserLogin,
  );
}
