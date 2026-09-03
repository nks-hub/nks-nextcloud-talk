// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:talk_protocol/talk_protocol.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../data/account_repository.dart';
import '../../data/app_database.dart';
import '../../data/credential_vault.dart';
import '../../network/account_http_client.dart';
import '../../network/nextcloud_api.dart';
import 'server_address_input.dart';

enum OnboardingFailureCode {
  invalidServer,
  serverNotReady,
  browserUnavailable,
  loginTimedOut,
  talkUnavailable,
  accountIdentityMismatch,
  localPersistence,

  /// A scanned payload named a server but the credentials in it could not be
  /// turned into a usable app password.
  scannedLoginRejected,

  /// The server presented a certificate the device does not trust. The user
  /// has to see its fingerprint and confirm it before anything is sent there.
  untrustedCertificate,
}

final class OnboardingFailure implements Exception {
  const OnboardingFailure(
    this.code, {
    this.serverBlockers = const {},
    this.certificate,
  });

  final OnboardingFailureCode code;
  final Set<ServerStatusBlocker> serverBlockers;

  /// Set for [OnboardingFailureCode.untrustedCertificate]: what the server
  /// presented, so the confirmation can name the exact fingerprint.
  final CertificateEncounter? certificate;

  @override
  String toString() => 'OnboardingFailure(${code.name})';
}

final class OnboardingCancelled implements Exception {
  const OnboardingCancelled();
}

final class CancellationSignal {
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;

  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) {
      _cancelled.complete();
    }
  }

  void throwIfCancelled() {
    if (isCancelled) {
      throw const OnboardingCancelled();
    }
  }
}

abstract interface class LoginPageLauncher {
  Future<bool> open(Uri uri);
}

final class ExternalLoginPageLauncher implements LoginPageLauncher {
  ExternalLoginPageLauncher({Future<bool> Function(Uri)? opener})
    : _opener = opener ?? _openExternalApplication;

  final Future<bool> Function(Uri) _opener;

  @override
  Future<bool> open(Uri uri) async {
    if (!_waitsForMobileReturn) {
      return _opener(uri);
    }

    final returnSignal = _MobileAppReturnSignal();
    try {
      final opened = await _opener(uri);
      if (!opened) {
        return false;
      }
      await returnSignal.returned;
      return true;
    } finally {
      returnSignal.dispose();
    }
  }

  static Future<bool> _openExternalApplication(Uri uri) {
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  static bool get _waitsForMobileReturn =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
}

final class _MobileAppReturnSignal {
  _MobileAppReturnSignal() {
    _listener = AppLifecycleListener(
      onHide: () => _leftForeground = true,
      onResume: () {
        if (_leftForeground && !_returned.isCompleted) {
          _returned.complete();
        }
      },
    );
  }

  final Completer<void> _returned = Completer<void>();
  late final AppLifecycleListener _listener;
  bool _leftForeground = false;

  Future<void> get returned => _returned.future;

  void dispose() => _listener.dispose();
}

final class OnboardingCoordinator {
  OnboardingCoordinator({
    required HttpNextcloudApi api,
    required AccountRepository accounts,
    required CredentialVault credentials,
    required LoginPageLauncher launcher,
    CertificateTrustGate? trust,
    Uuid? uuid,
    this.pollInterval = const Duration(seconds: 2),
    this.loginTimeout = const Duration(minutes: 15),
  }) : _api = api,
       _accounts = accounts,
       _credentials = credentials,
       _launcher = launcher,
       _trust = trust,
       _uuid = uuid ?? const Uuid();

  final HttpNextcloudApi _api;
  final AccountRepository _accounts;
  final CredentialVault _credentials;
  final LoginPageLauncher _launcher;
  final CertificateTrustGate? _trust;
  final Uuid _uuid;
  final Duration pollInterval;
  final Duration loginTimeout;

  Future<PendingLogin> start(String serverAddress) async {
    final ServerBase server;
    try {
      server = ServerBase.parse(normalizeServerAddressInput(serverAddress));
    } on TalkProtocolException {
      throw const OnboardingFailure(OnboardingFailureCode.invalidServer);
    }
    final status = await _requireReadyServer(server);
    final initialization = await _api.initializeLogin(server);
    return PendingLogin(
      server: server,
      serverStatus: status,
      initialization: initialization,
    );
  }

  Future<ServerStatus> _requireReadyServer(ServerBase server) async {
    final ServerStatus status;
    try {
      status = await _api.getServerStatus(server);
    } on Object {
      // A refused certificate reaches here as a plain transport failure, so
      // the gate is what says whether the server is unreachable or merely
      // unconfirmed.
      final encounter = _pendingCertificate(server);
      if (encounter == null) {
        rethrow;
      }
      throw OnboardingFailure(
        OnboardingFailureCode.untrustedCertificate,
        certificate: encounter,
      );
    }
    if (!status.isReady) {
      throw OnboardingFailure(
        OnboardingFailureCode.serverNotReady,
        serverBlockers: status.blockers,
      );
    }
    return status;
  }

  /// Commits an account straight from a scanned `nc://login/` payload.
  ///
  /// The secret was minted by the server before the QR code was drawn, so
  /// there is no Login Flow v2 token to poll for: the server is still checked
  /// for readiness and the credentials still have to authenticate against it,
  /// but [waitForAccount]'s polling loop is skipped entirely.
  Future<StoredAccount> commitScannedLogin(
    QrLoginCredentials payload,
    CancellationSignal cancellation, {
    String? expectedAccountId,
  }) async {
    final server = payload.server;
    final status = await _requireReadyServer(server);
    cancellation.throwIfCancelled();

    var credentials = payload.toLoginFlowCredentials();
    if (payload.isOneTime) {
      final String appPassword;
      try {
        appPassword = await _api.exchangeOneTimeAppPassword(
          server: server,
          loginName: payload.loginName,
          oneTimeToken: payload.secret,
        );
      } on OnboardingFailure {
        rethrow;
      } on Object {
        // A single-use token is spent on first use and expires on its own, so
        // a failure here is nothing the user can retry with the same code.
        throw const OnboardingFailure(
          OnboardingFailureCode.scannedLoginRejected,
        );
      }
      credentials = LoginFlowCredentials.scanned(
        server: server,
        loginName: payload.loginName,
        appPassword: appPassword,
      );
    }
    cancellation.throwIfCancelled();

    try {
      return await _commitAccount(
        server: server,
        serverStatus: status,
        loginCredentials: credentials,
        cancellation: cancellation,
        expectedAccountId: expectedAccountId,
      );
    } on NextcloudApiException catch (error) {
      // A scanned password is the only credential the app does not obtain from
      // the server itself, so the server refusing it means the code was stale
      // or already revoked. Saying that beats the generic transport message.
      if (error.statusCode == 401 || error.statusCode == 403) {
        throw const OnboardingFailure(
          OnboardingFailureCode.scannedLoginRejected,
        );
      }
      rethrow;
    }
  }

  CertificateEncounter? _pendingCertificate(ServerBase server) {
    final encounter = _trust?.lastEncounter;
    if (encounter == null) {
      return null;
    }
    return encounter.host.toLowerCase() ==
            Uri.parse(server.value).host.toLowerCase()
        ? encounter
        : null;
  }

  /// Accepts the certificate the user just confirmed. It only lasts for this
  /// session until the account that owns it is created.
  void trustCertificate(CertificateEncounter encounter) {
    _trust?.confirm(host: encounter.host, fingerprint: encounter.fingerprint);
  }

  Future<void> openLoginPage(PendingLogin pending) async {
    final opened = await _launcher.open(pending.initialization.loginUri);
    if (!opened) {
      throw const OnboardingFailure(OnboardingFailureCode.browserUnavailable);
    }
  }

  Future<StoredAccount> waitForAccount(
    PendingLogin pending,
    CancellationSignal cancellation, {
    String? expectedAccountId,
  }) async {
    final deadline = DateTime.now().toUtc().add(loginTimeout);
    while (DateTime.now().toUtc().isBefore(deadline)) {
      cancellation.throwIfCancelled();
      final result = await _api.pollLogin(pending);
      cancellation.throwIfCancelled();
      if (result case LoginPollSucceeded(:final credentials)) {
        return _commitAccount(
          server: pending.server,
          serverStatus: pending.serverStatus,
          loginCredentials: credentials,
          cancellation: cancellation,
          expectedAccountId: expectedAccountId,
        );
      }
      await Future.any<void>([
        Future<void>.delayed(pollInterval),
        cancellation.whenCancelled,
      ]);
    }
    cancellation.throwIfCancelled();
    throw const OnboardingFailure(OnboardingFailureCode.loginTimedOut);
  }

  Future<StoredAccount> _commitAccount({
    required ServerBase server,
    required ServerStatus serverStatus,
    required LoginFlowCredentials loginCredentials,
    required CancellationSignal cancellation,
    required String? expectedAccountId,
  }) async {
    final expected = expectedAccountId == null
        ? null
        : await _accounts.getAccount(expectedAccountId);
    if (expectedAccountId != null &&
        (expected == null ||
            expected.serverUrl != server.value ||
            expected.loginName != loginCredentials.loginName)) {
      try {
        await _api.revokeAppPassword(
          server: server,
          loginName: loginCredentials.loginName,
          appPassword: loginCredentials.appPassword,
        );
      } on Object {
        // The identity mismatch remains authoritative and no credential is
        // persisted even when the server cannot confirm cleanup.
      }
      throw const OnboardingFailure(
        OnboardingFailureCode.accountIdentityMismatch,
      );
    }

    final capabilities = await _api.getAuthenticatedCapabilities(
      server: server,
      loginName: loginCredentials.loginName,
      appPassword: loginCredentials.appPassword,
    );
    cancellation.throwIfCancelled();
    if (!capabilities.hasTalk) {
      throw const OnboardingFailure(OnboardingFailureCode.talkUnavailable);
    }

    final existing =
        expected ??
        await _accounts.findByIdentity(
          serverUrl: server.value,
          loginName: loginCredentials.loginName,
        );
    final accountId = existing?.id ?? _uuid.v4();
    final String? previousPassword;
    try {
      previousPassword = await _credentials.readAppPassword(accountId);
    } on Object {
      throw const OnboardingFailure(OnboardingFailureCode.localPersistence);
    }
    cancellation.throwIfCancelled();

    var credentialWritten = false;
    try {
      await _credentials.writeAppPassword(
        accountId,
        loginCredentials.appPassword,
      );
      credentialWritten = true;
      return await _accounts.upsertAccount(
        accountId: accountId,
        serverUrl: server.value,
        loginName: loginCredentials.loginName,
        serverProductName: serverStatus.productName,
        talkFeatures: capabilities.talkFeatures,
        serverThemeColor: capabilities.serverThemeColor,
        certificateFingerprint: _trust?.confirmedFor(
          Uri.parse(server.value).host,
        ),
        createdAt: existing == null
            ? DateTime.now().toUtc()
            : DateTime.fromMillisecondsSinceEpoch(
                existing.createdAtMillis,
                isUtc: true,
              ),
      );
    } on Object {
      if (credentialWritten) {
        try {
          if (previousPassword == null) {
            await _credentials.deleteAppPassword(accountId);
          } else {
            await _credentials.writeAppPassword(accountId, previousPassword);
          }
        } on Object {
          // The original persistence failure remains authoritative. No secret
          // is exposed to the UI or logs.
        }
      }
      throw const OnboardingFailure(OnboardingFailureCode.localPersistence);
    }
  }
}
