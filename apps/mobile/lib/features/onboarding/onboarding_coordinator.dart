// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:talk_protocol/talk_protocol.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../data/account_repository.dart';
import '../../data/app_database.dart';
import '../../data/credential_vault.dart';
import '../../network/account_http_client.dart';
import '../../network/nextcloud_api.dart';
import '../settings/app_password_revocation_queue.dart';
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
    this.cleanupIncomplete = false,
  });

  final OnboardingFailureCode code;
  final Set<ServerStatusBlocker> serverBlockers;

  /// Set for [OnboardingFailureCode.untrustedCertificate]: what the server
  /// presented, so the confirmation can name the exact fingerprint.
  final CertificateEncounter? certificate;

  /// True when onboarding could not prove that every local and remote secret
  /// created by the failed operation was cleaned up or durably queued.
  final bool cleanupIncomplete;

  @override
  String toString() =>
      'OnboardingFailure(${code.name}, '
      'cleanupIncomplete: $cleanupIncomplete)';
}

final class OnboardingCancelled implements Exception {
  const OnboardingCancelled();
}

enum _CredentialSource { generated, sharedQr }

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

  /// Dismisses the login page if it is shown inside the app.
  Future<void> close();
}

final class ExternalLoginPageLauncher implements LoginPageLauncher {
  ExternalLoginPageLauncher({
    Future<bool> Function(Uri)? opener,
    Future<void> Function()? closer,
  }) : _opener = opener ?? _openExternalApplication,
       _closer = closer ?? _closeInAppBrowser;

  final Future<bool> Function(Uri) _opener;
  final Future<void> Function() _closer;

  /// App Review requires sign-in to stay inside the app on iOS, where the
  /// page is shown in an SFSafariViewController sheet over the app.
  static bool get _inApp =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// Returns as soon as the browser is launched. It does not wait for this app
  /// to be hidden and resumed: a browser that opens in its own window (iPadOS
  /// windowed apps, split screen, a custom tab drawn over the app) never
  /// produces that pair, and onboarding sat on a spinner without ever polling.
  @override
  Future<bool> open(Uri uri) => _opener(uri);

  @override
  Future<void> close() => _closer();

  static Future<bool> _openExternalApplication(Uri uri) {
    return launchUrl(
      uri,
      mode: _inApp
          ? LaunchMode.inAppBrowserView
          : LaunchMode.externalApplication,
    );
  }

  static Future<void> _closeInAppBrowser() async {
    if (_inApp) {
      await closeInAppWebView();
    }
  }
}

final class OnboardingCoordinator {
  OnboardingCoordinator({
    required HttpNextcloudApi api,
    required AccountRepository accounts,
    required CredentialVault credentials,
    required LoginPageLauncher launcher,
    AppPasswordRevocationQueue? pendingRevocations,
    CertificateTrustGate? trust,
    Uuid? uuid,
    this.pollInterval = const Duration(seconds: 2),
    this.loginTimeout = const Duration(minutes: 15),
    bool Function()? inBackground,
  }) : _api = api,
       _inBackground = inBackground ?? _never,
       _accounts = accounts,
       _credentials = credentials,
       _launcher = launcher,
       _pendingRevocations = pendingRevocations,
       _trust = trust,
       _uuid = uuid ?? const Uuid();

  final HttpNextcloudApi _api;
  final AccountRepository _accounts;
  final CredentialVault _credentials;
  final LoginPageLauncher _launcher;
  final AppPasswordRevocationQueue? _pendingRevocations;
  final CertificateTrustGate? _trust;
  final Uuid _uuid;
  final Duration pollInterval;
  final Duration loginTimeout;

  /// True while the app is off the screen. The server hands the credentials
  /// out exactly once, and a phone that cuts background apps off the network
  /// (battery saver) loses that answer: MEASURED on a handset, the poll was
  /// answered 200 while the browser was in front and every poll after it was
  /// a 404, so the sign-in spun until it was cancelled.
  final bool Function() _inBackground;

  static bool _never() => false;

  Future<PendingLogin> start(
    String serverAddress, {
    CancellationSignal? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final ServerBase server;
    try {
      server = ServerBase.parse(normalizeServerAddressInput(serverAddress));
    } on TalkProtocolException {
      throw const OnboardingFailure(OnboardingFailureCode.invalidServer);
    }
    final status = await _requireReadyServer(
      server,
      cancellation: cancellation,
    );
    cancellation?.throwIfCancelled();
    final LoginFlowInitialization initialization;
    try {
      initialization = await _api.initializeLogin(
        server,
        abortTrigger: cancellation?.whenCancelled,
      );
    } on Object {
      cancellation?.throwIfCancelled();
      rethrow;
    }
    cancellation?.throwIfCancelled();
    return PendingLogin(
      server: server,
      serverStatus: status,
      initialization: initialization,
    );
  }

  Future<ServerStatus> _requireReadyServer(
    ServerBase server, {
    CancellationSignal? cancellation,
  }) async {
    final ServerStatus status;
    try {
      status = await _api.getServerStatus(
        server,
        abortTrigger: cancellation?.whenCancelled,
      );
    } on Object {
      cancellation?.throwIfCancelled();
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
    cancellation?.throwIfCancelled();
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
  /// but [completeLogin]'s polling loop is skipped entirely.
  Future<StoredAccount> commitScannedLogin(
    QrLoginCredentials payload,
    CancellationSignal cancellation, {
    String? expectedAccountId,
  }) async {
    final server = payload.server;
    final status = await _requireReadyServer(
      server,
      cancellation: cancellation,
    );
    cancellation.throwIfCancelled();

    var credentials = payload.toLoginFlowCredentials();
    if (payload.isOneTime) {
      final String appPassword;
      try {
        appPassword = await _api.exchangeOneTimeAppPassword(
          server: server,
          loginName: payload.loginName,
          oneTimeToken: payload.secret,
          abortTrigger: cancellation.whenCancelled,
        );
      } on OnboardingFailure {
        rethrow;
      } on Object {
        cancellation.throwIfCancelled();
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
    try {
      return await _commitAccount(
        server: server,
        serverStatus: status,
        loginCredentials: credentials,
        credentialSource: payload.isOneTime
            ? _CredentialSource.generated
            : _CredentialSource.sharedQr,
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

  /// Opens the login page, polls for its one-time result and closes the page.
  ///
  /// Owning all three steps here keeps a screen disappearing while [open]
  /// waits from escaping the matching [close].
  Future<StoredAccount> completeLogin(
    PendingLogin pending,
    CancellationSignal cancellation, {
    String? expectedAccountId,
    VoidCallback? onLoginPageOpened,
  }) async {
    try {
      cancellation.throwIfCancelled();
      final opened = await _launcher.open(pending.initialization.loginUri);
      cancellation.throwIfCancelled();
      if (!opened) {
        throw const OnboardingFailure(OnboardingFailureCode.browserUnavailable);
      }
      onLoginPageOpened?.call();
      return await _pollForAccount(
        pending,
        cancellation,
        expectedAccountId: expectedAccountId,
      );
    } finally {
      await _closeLoginPage();
    }
  }

  Future<void> _closeLoginPage() async {
    try {
      await _launcher.close();
    } on Object {
      // The sheet may already be gone; that must not mask the login outcome.
    }
  }

  Future<StoredAccount> _pollForAccount(
    PendingLogin pending,
    CancellationSignal cancellation, {
    String? expectedAccountId,
  }) async {
    final deadline = DateTime.now().toUtc().add(loginTimeout);
    while (DateTime.now().toUtc().isBefore(deadline)) {
      cancellation.throwIfCancelled();
      if (_inBackground()) {
        await Future.any<void>([
          Future<void>.delayed(pollInterval),
          cancellation.whenCancelled,
        ]);
        continue;
      }
      final LoginPollResult? result;
      try {
        result = await _api.pollLogin(
          pending,
          abortTrigger: cancellation.whenCancelled,
        );
      } on NextcloudApiException catch (error) {
        cancellation.throwIfCancelled();
        // iOS suspends the app's sockets while the browser is in front, so the
        // first polls after returning can fail on a connection that is fine.
        if (error.code != NextcloudApiError.network &&
            error.code != NextcloudApiError.timeout) {
          rethrow;
        }
        cancellation.throwIfCancelled();
        await Future.any<void>([
          Future<void>.delayed(pollInterval),
          cancellation.whenCancelled,
        ]);
        continue;
      }
      if (result case LoginPollSucceeded(:final credentials)) {
        return _commitAccount(
          server: pending.server,
          serverStatus: pending.serverStatus,
          loginCredentials: credentials,
          credentialSource: _CredentialSource.generated,
          cancellation: cancellation,
          expectedAccountId: expectedAccountId,
        );
      }
      cancellation.throwIfCancelled();
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
    required _CredentialSource credentialSource,
    required CancellationSignal cancellation,
    required String? expectedAccountId,
  }) async {
    try {
      return await _commitAccountWithoutCredentialCleanup(
        server: server,
        serverStatus: serverStatus,
        loginCredentials: loginCredentials,
        cancellation: cancellation,
        expectedAccountId: expectedAccountId,
      );
    } on Object catch (error, stackTrace) {
      if (credentialSource == _CredentialSource.sharedQr) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      final cleanedUp = await _revokeOrRememberGeneratedCredential(
        server: server,
        loginName: loginCredentials.loginName,
        appPassword: loginCredentials.appPassword,
        preferQueue: error is OnboardingCancelled,
      );
      if (!cleanedUp) {
        throw const OnboardingFailure(
          OnboardingFailureCode.localPersistence,
          cleanupIncomplete: true,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<StoredAccount> _commitAccountWithoutCredentialCleanup({
    required ServerBase server,
    required ServerStatus serverStatus,
    required LoginFlowCredentials loginCredentials,
    required CancellationSignal cancellation,
    required String? expectedAccountId,
  }) async {
    cancellation.throwIfCancelled();
    final expected = expectedAccountId == null
        ? null
        : await _accounts.getAccount(expectedAccountId);
    if (expectedAccountId != null &&
        (expected == null ||
            expected.serverUrl != server.value ||
            expected.loginName != loginCredentials.loginName)) {
      throw const OnboardingFailure(
        OnboardingFailureCode.accountIdentityMismatch,
      );
    }

    final CapabilitySnapshot capabilities;
    try {
      capabilities = await _api.getAuthenticatedCapabilities(
        server: server,
        loginName: loginCredentials.loginName,
        appPassword: loginCredentials.appPassword,
        abortTrigger: cancellation.whenCancelled,
      );
    } on Object {
      cancellation.throwIfCancelled();
      rethrow;
    }
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
      final stored = await _accounts.upsertAccount(
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
      // The account now owns the certificate accepted during login. Refresh
      // the shared gate before returning so that one-shot confirmation cannot
      // outlive a later account removal in this process.
      try {
        await _trust?.refresh();
      } on Object {
        // Account and credential persistence already succeeded. Trust refresh
        // is fail-closed and must not roll either durable write back.
      }
      return stored;
    } on Object {
      var cleanupIncomplete = false;
      if (credentialWritten) {
        try {
          if (previousPassword == null) {
            await _credentials.deleteAppPassword(accountId);
          } else {
            await _credentials.writeAppPassword(accountId, previousPassword);
          }
        } on Object {
          cleanupIncomplete = true;
        }
      }
      throw OnboardingFailure(
        OnboardingFailureCode.localPersistence,
        cleanupIncomplete: cleanupIncomplete,
      );
    }
  }

  Future<bool> _revokeOrRememberGeneratedCredential({
    required ServerBase server,
    required String loginName,
    required String appPassword,
    bool preferQueue = false,
  }) async {
    final queue = _pendingRevocations;
    if (preferQueue &&
        await _rememberGeneratedCredential(
          queue,
          server,
          loginName,
          appPassword,
        )) {
      return true;
    }
    try {
      await _api.revokeAppPassword(
        server: server,
        loginName: loginName,
        appPassword: appPassword,
      );
      return true;
    } on NextcloudApiException catch (error) {
      if (error.statusCode == 401) {
        return true;
      }
    } on Object {
      // The bounded durable queue below owns the retry.
    }
    return _rememberGeneratedCredential(queue, server, loginName, appPassword);
  }

  Future<bool> _rememberGeneratedCredential(
    AppPasswordRevocationQueue? queue,
    ServerBase server,
    String loginName,
    String appPassword,
  ) async {
    if (queue == null) return false;
    try {
      await queue.record(
        server: server,
        loginName: loginName,
        appPassword: appPassword,
      );
      return true;
    } on Object {
      return false;
    }
  }
}
