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

part 'onboarding_browser_login.dart';

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

enum _CredentialSource { generated, browser, sharedQr }

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
       _pendingRevocations =
           pendingRevocations ??
           _queueFromCredentials(api, accounts, credentials),
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

  static AppPasswordRevocationQueue? _queueFromCredentials(
    HttpNextcloudApi api,
    AccountRepository accounts,
    CredentialVault credentials,
  ) => credentials is PendingRevocationStore
      ? AppPasswordRevocationQueue(
          store: credentials as PendingRevocationStore,
          api: api,
          accounts: accounts,
          credentials: credentials,
        )
      : null;

  Future<void> _recoverHeldCredentials() async {
    final queue = _pendingRevocations;
    if (queue == null) {
      return;
    }
    try {
      await queue.recoverHeldCredentials(
        accounts: _accounts,
        credentials: _credentials,
      );
      await queue.recoverBrowserLogins();
    } on Object {
      throw const OnboardingFailure(
        OnboardingFailureCode.localPersistence,
        cleanupIncomplete: true,
      );
    }
  }

  Future<PendingLogin> start(
    String serverAddress, {
    CancellationSignal? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    await _recoverHeldCredentials();
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
    await _recoverHeldCredentials();
    cancellation.throwIfCancelled();
    final server = payload.server;
    final status = await _requireReadyServer(
      server,
      cancellation: cancellation,
    );
    cancellation.throwIfCancelled();

    var credentials = payload.toLoginFlowCredentials();
    AppPasswordRevocationReservation? cleanupReservation;
    if (payload.isOneTime) {
      final _ReservedOneShot<String> exchange;
      try {
        exchange = await _awaitReservedOneShot(
          operation: () => _api.exchangeOneTimeAppPassword(
            server: server,
            loginName: payload.loginName,
            oneTimeToken: payload.secret,
          ),
          cancellation: cancellation,
          server: server,
          credentialFrom: (appPassword) =>
              (loginName: payload.loginName, appPassword: appPassword),
          provesNoCredential: (error) =>
              error is NextcloudApiException && error.statusCode == 401,
        );
      } on OnboardingFailure {
        rethrow;
      } on NextcloudApiException catch (error) {
        cancellation.throwIfCancelled();
        throw OnboardingFailure(
          OnboardingFailureCode.scannedLoginRejected,
          cleanupIncomplete: error.statusCode != 401,
        );
      } on Object {
        cancellation.throwIfCancelled();
        // The request may have spent the token before its response was lost.
        // Its durable reservation stays behind and blocks unsafe reuse.
        throw const OnboardingFailure(
          OnboardingFailureCode.scannedLoginRejected,
          cleanupIncomplete: true,
        );
      }
      cleanupReservation = exchange.reservation;
      credentials = LoginFlowCredentials.scanned(
        server: server,
        loginName: payload.loginName,
        appPassword: exchange.value,
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
        cleanupReservation: cleanupReservation,
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
  }) => _completeBrowserLogin(
    pending,
    cancellation,
    expectedAccountId: expectedAccountId,
    onLoginPageOpened: onLoginPageOpened,
  );

  Future<StoredAccount> _commitAccount({
    required ServerBase server,
    required ServerStatus serverStatus,
    required LoginFlowCredentials loginCredentials,
    required _CredentialSource credentialSource,
    required CancellationSignal cancellation,
    required String? expectedAccountId,
    AppPasswordRevocationReservation? cleanupReservation,
  }) async {
    Future<StoredAccount> commit(AppPasswordRevocationReservation? adopted) =>
        _commitClaimedAccount(
          server: server,
          serverStatus: serverStatus,
          loginCredentials: loginCredentials,
          credentialSource: credentialSource,
          cancellation: cancellation,
          expectedAccountId: expectedAccountId,
          cleanupReservation: cleanupReservation ?? adopted,
        );
    final queue = _pendingRevocations;
    try {
      return queue == null
          ? await commit(null)
          : await queue.admitCredential(
              loginCredentials,
              commit,
              accounts: _accounts,
              credentials: _credentials,
              currentReservation: cleanupReservation,
            );
    } on BrowserCredentialAdmissionUnavailable {
      if (cleanupReservation != null) {
        await queue!.abandonHeldCredential(cleanupReservation);
      }
      cancellation.throwIfCancelled();
      throw const OnboardingFailure(OnboardingFailureCode.localPersistence);
    } on Object catch (error, stackTrace) {
      if (error is! OnboardingCancelled &&
          credentialSource == _CredentialSource.browser &&
          cleanupReservation != null) {
        try {
          await queue!.revokeRetiredBrowserCredential(
            cleanupReservation,
            accounts: _accounts,
            credentials: _credentials,
          );
        } on Object {
          // The held or pending entry remains recoverable.
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<StoredAccount> _commitClaimedAccount({
    required ServerBase server,
    required ServerStatus serverStatus,
    required LoginFlowCredentials loginCredentials,
    required _CredentialSource credentialSource,
    required CancellationSignal cancellation,
    required String? expectedAccountId,
    required AppPasswordRevocationReservation? cleanupReservation,
  }) async {
    late final StoredAccount stored;
    try {
      stored = await _commitAccountWithoutCredentialCleanup(
        server: server,
        serverStatus: serverStatus,
        loginCredentials: loginCredentials,
        cancellation: cancellation,
        expectedAccountId: expectedAccountId,
        cleanupReservation: cleanupReservation,
      );
    } on Object catch (error, stackTrace) {
      if (credentialSource == _CredentialSource.sharedQr) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      if (credentialSource == _CredentialSource.browser &&
          cleanupReservation != null) {
        await _retireFailedBrowserCredential(
          cleanupReservation,
          loginCredentials,
        );
        Error.throwWithStackTrace(error, stackTrace);
      }
      final cleanedUp = cleanupReservation == null
          ? await _revokeOrRememberGeneratedCredential(
              server: server,
              loginName: loginCredentials.loginName,
              appPassword: loginCredentials.appPassword,
              preferQueue: error is OnboardingCancelled,
            )
          : await _retireReservedCredential(
              reservation: cleanupReservation,
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
    if (cleanupReservation != null) {
      try {
        await _releaseHeldCredential(cleanupReservation);
      } on Object {
        // The account and vault now own the credential. A durable held entry
        // lets the next coordinator confirm that before releasing it.
        await _pendingRevocations!.abandonHeldCredential(cleanupReservation);
      }
    }
    return stored;
  }

  Future<StoredAccount> _commitAccountWithoutCredentialCleanup({
    required ServerBase server,
    required ServerStatus serverStatus,
    required LoginFlowCredentials loginCredentials,
    required CancellationSignal cancellation,
    required String? expectedAccountId,
    required AppPasswordRevocationReservation? cleanupReservation,
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
    final existing =
        expected ??
        await _accounts.findByIdentity(
          serverUrl: server.value,
          loginName: loginCredentials.loginName,
        );
    final accountId = existing?.id ?? _uuid.v4();
    if (cleanupReservation != null) {
      await _pendingRevocations!.updateHeldCredentialPhase(
        reservation: cleanupReservation,
        phase: AppPasswordCredentialPhase.prepared,
        accountId: accountId,
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

    final String? previousPassword;
    try {
      previousPassword = await _credentials.readAppPassword(accountId);
    } on Object {
      throw const OnboardingFailure(OnboardingFailureCode.localPersistence);
    }
    cancellation.throwIfCancelled();

    var credentialWritten = false;
    late final StoredAccount stored;
    try {
      await _credentials.writeAppPassword(
        accountId,
        loginCredentials.appPassword,
      );
      credentialWritten = true;
      if (cleanupReservation != null) {
        await _pendingRevocations!.updateHeldCredentialPhase(
          reservation: cleanupReservation,
          phase: AppPasswordCredentialPhase.vaultWritten,
          accountId: accountId,
        );
      }
      cancellation.throwIfCancelled();
      stored = await _accounts.upsertAccount(
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
    } on Object catch (error, stackTrace) {
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
      if (!cleanupIncomplete && error is OnboardingCancelled) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      throw OnboardingFailure(
        OnboardingFailureCode.localPersistence,
        cleanupIncomplete: cleanupIncomplete,
      );
    }
    if (cleanupReservation != null) {
      try {
        await _pendingRevocations!.updateHeldCredentialPhase(
          reservation: cleanupReservation,
          phase: AppPasswordCredentialPhase.accountCommitted,
          accountId: accountId,
        );
      } on Object {
        // A crash-safe phase from before the database write is enough: startup
        // confirms the matching row and vault value before releasing it.
      }
    }
    return stored;
  }

  Future<AppPasswordRevocationReservation> _reserveGeneratedCredential({
    PendingLogin? browser,
  }) async {
    final queue = _pendingRevocations;
    if (queue == null) {
      throw const OnboardingFailure(
        OnboardingFailureCode.localPersistence,
        cleanupIncomplete: true,
      );
    }
    try {
      return await queue.reserve(browser: browser);
    } on Object {
      throw const OnboardingFailure(
        OnboardingFailureCode.localPersistence,
        cleanupIncomplete: true,
      );
    }
  }

  Future<_ReservedOneShot<T>> _awaitReservedOneShot<T>({
    required Future<T> Function() operation,
    required CancellationSignal cancellation,
    required ServerBase server,
    required _GeneratedCredential? Function(T value) credentialFrom,
    required bool Function(Object error) provesNoCredential,
    AppPasswordRevocationReservation? reservation,
    bool releaseWhenEmpty = true,
  }) async {
    final queue = _pendingRevocations;
    if (queue == null) {
      throw const OnboardingFailure(
        OnboardingFailureCode.localPersistence,
        cleanupIncomplete: true,
      );
    }
    final activeReservation =
        reservation ?? await _reserveGeneratedCredential();
    if (cancellation.isCancelled) {
      if (releaseWhenEmpty) {
        try {
          await queue.releaseReservation(activeReservation);
        } on Object {
          // No request was sent, so the empty reservation is safe to retain.
        }
      }
      throw const OnboardingCancelled();
    }
    final outcome = Future<T>.sync(operation).then<_OneShotOutcome<T>>(
      _OneShotValue<T>.new,
      onError: (Object error, StackTrace stackTrace) =>
          _OneShotError<T>(error, stackTrace),
    );
    final first = await Future.any<_OneShotOutcome<T>>([
      outcome,
      cancellation.whenCancelled.then((_) => _OneShotCancelled<T>()),
    ]);
    if (first case _OneShotValue<T>(:final value)) {
      final credential = credentialFrom(value);
      if (credential == null) {
        if (releaseWhenEmpty) {
          await _releaseEmptyReservation(queue, activeReservation);
        }
        return _ReservedOneShot<T>(value: value, reservation: null);
      }
      final held = await _holdKnownCredential(
        queue: queue,
        reservation: activeReservation,
        server: server,
        credential: credential,
      );
      if (!held) {
        throw const OnboardingFailure(OnboardingFailureCode.localPersistence);
      }
      return _ReservedOneShot<T>(value: value, reservation: activeReservation);
    }
    if (first case _OneShotError<T>(:final error, :final stackTrace)) {
      if (releaseWhenEmpty && provesNoCredential(error)) {
        await _releaseEmptyReservation(queue, activeReservation);
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
    unawaited(
      _handleLateReservedOneShot(
        outcome: outcome,
        queue: queue,
        reservation: activeReservation,
        server: server,
        credentialFrom: credentialFrom,
        provesNoCredential: provesNoCredential,
        releaseWhenEmpty: releaseWhenEmpty,
      ),
    );
    throw const OnboardingCancelled();
  }

  Future<void> _handleLateReservedOneShot<T>({
    required Future<_OneShotOutcome<T>> outcome,
    required AppPasswordRevocationQueue queue,
    required AppPasswordRevocationReservation reservation,
    required ServerBase server,
    required _GeneratedCredential? Function(T value) credentialFrom,
    required bool Function(Object error) provesNoCredential,
    required bool releaseWhenEmpty,
  }) async {
    final late = await outcome;
    if (late case _OneShotValue<T>(:final value)) {
      final credential = credentialFrom(value);
      if (credential == null) {
        if (releaseWhenEmpty) {
          await _releaseEmptyReservation(queue, reservation);
        }
        return;
      }
      await _persistLateCredential(
        queue: queue,
        reservation: reservation,
        server: server,
        credential: credential,
      );
      return;
    }
    if (late case _OneShotError<T>(:final error)) {
      if (releaseWhenEmpty && provesNoCredential(error)) {
        await _releaseEmptyReservation(queue, reservation);
      }
    }
  }

  Future<bool> _holdKnownCredential({
    required AppPasswordRevocationQueue queue,
    required AppPasswordRevocationReservation reservation,
    required ServerBase server,
    required _GeneratedCredential credential,
  }) async {
    while (true) {
      try {
        await queue.holdCredential(
          reservation: reservation,
          server: server,
          loginName: credential.loginName,
          appPassword: credential.appPassword,
        );
        return true;
      } on Object {
        if (await _tryRevokeGeneratedCredential(
          server: server,
          credential: credential,
        )) {
          await _releaseRevokedReservation(queue, reservation);
          return false;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
  }

  Future<void> _persistLateCredential({
    required AppPasswordRevocationQueue queue,
    required AppPasswordRevocationReservation reservation,
    required ServerBase server,
    required _GeneratedCredential credential,
  }) async {
    while (true) {
      try {
        await queue.queueCredential(
          reservation: reservation,
          server: server,
          loginName: credential.loginName,
          appPassword: credential.appPassword,
        );
        return;
      } on Object {
        if (await _tryRevokeGeneratedCredential(
          server: server,
          credential: credential,
        )) {
          await _releaseRevokedReservation(queue, reservation);
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
  }

  Future<bool> _tryRevokeGeneratedCredential({
    required ServerBase server,
    required _GeneratedCredential credential,
  }) async {
    try {
      await _api.revokeAppPassword(
        server: server,
        loginName: credential.loginName,
        appPassword: credential.appPassword,
      );
      return true;
    } on NextcloudApiException catch (error) {
      return error.statusCode == 401;
    } on Object {
      return false;
    }
  }

  Future<void> _releaseEmptyReservation(
    AppPasswordRevocationQueue queue,
    AppPasswordRevocationReservation reservation,
  ) async {
    while (true) {
      try {
        await queue.releaseReservation(reservation);
        return;
      } on Object {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
  }

  Future<void> _releaseHeldCredential(
    AppPasswordRevocationReservation reservation,
  ) => _pendingRevocations!.releaseHeldCredential(reservation);

  Future<void> _releaseRevokedReservation(
    AppPasswordRevocationQueue queue,
    AppPasswordRevocationReservation reservation,
  ) async {
    while (true) {
      try {
        await queue.releaseRevokedCredential(reservation);
        return;
      } on Object {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
  }

  Future<bool> _retireReservedCredential({
    required AppPasswordRevocationReservation reservation,
    required ServerBase server,
    required String loginName,
    required String appPassword,
    required bool preferQueue,
  }) async {
    final queue = _pendingRevocations!;
    final credential = (loginName: loginName, appPassword: appPassword);
    if (!preferQueue &&
        await _tryRevokeGeneratedCredential(
          server: server,
          credential: credential,
        )) {
      await _releaseRevokedReservation(queue, reservation);
      return true;
    }
    await _persistLateCredential(
      queue: queue,
      reservation: reservation,
      server: server,
      credential: credential,
    );
    return true;
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

typedef _GeneratedCredential = ({String loginName, String appPassword});

final class _ReservedOneShot<T> {
  const _ReservedOneShot({required this.value, required this.reservation});

  final T value;
  final AppPasswordRevocationReservation? reservation;
}

sealed class _OneShotOutcome<T> {
  const _OneShotOutcome();
}

final class _OneShotValue<T> extends _OneShotOutcome<T> {
  const _OneShotValue(this.value);

  final T value;
}

final class _OneShotError<T> extends _OneShotOutcome<T> {
  const _OneShotError(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}

final class _OneShotCancelled<T> extends _OneShotOutcome<T> {
  const _OneShotCancelled();
}
