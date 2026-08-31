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
import '../../network/nextcloud_api.dart';

enum OnboardingFailureCode {
  invalidServer,
  serverNotReady,
  browserUnavailable,
  loginTimedOut,
  talkUnavailable,
  accountIdentityMismatch,
  localPersistence,
}

final class OnboardingFailure implements Exception {
  const OnboardingFailure(this.code, {this.serverBlockers = const {}});

  final OnboardingFailureCode code;
  final Set<ServerStatusBlocker> serverBlockers;

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
    Uuid? uuid,
    this.pollInterval = const Duration(seconds: 2),
    this.loginTimeout = const Duration(minutes: 15),
  }) : _api = api,
       _accounts = accounts,
       _credentials = credentials,
       _launcher = launcher,
       _uuid = uuid ?? const Uuid();

  final HttpNextcloudApi _api;
  final AccountRepository _accounts;
  final CredentialVault _credentials;
  final LoginPageLauncher _launcher;
  final Uuid _uuid;
  final Duration pollInterval;
  final Duration loginTimeout;

  Future<PendingLogin> start(String serverAddress) async {
    final ServerBase server;
    try {
      server = ServerBase.parse(serverAddress);
    } on TalkProtocolException {
      throw const OnboardingFailure(OnboardingFailureCode.invalidServer);
    }
    final status = await _api.getServerStatus(server);
    if (!status.isReady) {
      throw OnboardingFailure(
        OnboardingFailureCode.serverNotReady,
        serverBlockers: status.blockers,
      );
    }
    final initialization = await _api.initializeLogin(server);
    return PendingLogin(
      server: server,
      serverStatus: status,
      initialization: initialization,
    );
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
          pending: pending,
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
    required PendingLogin pending,
    required LoginFlowCredentials loginCredentials,
    required CancellationSignal cancellation,
    required String? expectedAccountId,
  }) async {
    final expected = expectedAccountId == null
        ? null
        : await _accounts.getAccount(expectedAccountId);
    if (expectedAccountId != null &&
        (expected == null ||
            expected.serverUrl != pending.server.value ||
            expected.loginName != loginCredentials.loginName)) {
      try {
        await _api.revokeAppPassword(
          server: pending.server,
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
      server: pending.server,
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
          serverUrl: pending.server.value,
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
        serverUrl: pending.server.value,
        loginName: loginCredentials.loginName,
        serverProductName: pending.serverStatus.productName,
        talkFeatures: capabilities.talkFeatures,
        serverThemeColor: capabilities.serverThemeColor,
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
