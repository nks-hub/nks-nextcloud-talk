import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import '../../core/brand_mark.dart';
import '../../data/app_database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../network/account_http_client.dart';
import '../../network/nextcloud_api.dart';
import 'onboarding_coordinator.dart';

enum _OnboardingPhase { entry, checking, openingLogin, waitingForLogin }

final class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({
    super.key,
    this.onAccountAdded,
    this.reauthenticateAccount,
  });

  final ValueChanged<StoredAccount>? onAccountAdded;
  final StoredAccount? reauthenticateAccount;

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

final class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  late final TextEditingController _serverController;
  final FocusNode _serverFocus = FocusNode();
  _OnboardingPhase _phase = _OnboardingPhase.entry;
  Object? _error;
  PendingLogin? _pending;
  CancellationSignal? _cancellation;

  bool get _busy => _phase != _OnboardingPhase.entry;

  @override
  void initState() {
    super.initState();
    // Starting the field at the scheme shows the expected shape and lets a
    // pasted address land after it without the user deleting anything.
    final initial = widget.reauthenticateAccount?.serverUrl ?? 'https://';
    _serverController = TextEditingController(text: initial);
    _serverController.selection = TextSelection.collapsed(
      offset: initial.length,
    );
  }

  @override
  void dispose() {
    _cancellation?.cancel();
    _serverFocus.dispose();
    _serverController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (_busy) {
      return;
    }
    _serverFocus.unfocus();
    setState(() {
      _error = null;
      _phase = _OnboardingPhase.checking;
    });
    try {
      final coordinator = ref.read(onboardingCoordinatorProvider);
      final pending = await coordinator.start(_serverController.text);
      if (!mounted) {
        return;
      }
      setState(() {
        _pending = pending;
        _phase = _OnboardingPhase.openingLogin;
      });
      await coordinator.openLoginPage(pending);
      if (!mounted) {
        return;
      }
      final cancellation = CancellationSignal();
      _cancellation = cancellation;
      setState(() => _phase = _OnboardingPhase.waitingForLogin);
      final account = await coordinator.waitForAccount(
        pending,
        cancellation,
        expectedAccountId: widget.reauthenticateAccount?.id,
      );
      if (!mounted) {
        return;
      }
      widget.onAccountAdded?.call(account);
    } on OnboardingCancelled {
      if (mounted) {
        setState(() {
          _phase = _OnboardingPhase.entry;
          _pending = null;
          _cancellation = null;
        });
      }
    } on OnboardingFailure catch (failure) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = null;
        _phase = _OnboardingPhase.entry;
        _pending = null;
        _cancellation = null;
      });
      final certificate = failure.certificate;
      if (failure.code == OnboardingFailureCode.untrustedCertificate &&
          certificate != null) {
        if (await _confirmCertificate(certificate)) {
          // The user answered for exactly this fingerprint, so the same
          // address is worth one more attempt.
          await _connect();
        }
        return;
      }
      setState(() => _error = failure);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _error = error;
          _phase = _OnboardingPhase.entry;
          _pending = null;
          _cancellation = null;
        });
      }
    }
  }

  Future<bool> _confirmCertificate(CertificateEncounter encounter) async {
    final strings = AppLocalizations.of(context);
    final changed =
        encounter.outcome.refusal ==
        CertificateRefusal.pinnedFingerprintMismatch;
    final trusted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('certificate-trust-dialog'),
        title: Text(
          changed
              ? strings.certificateChangedTitle
              : strings.certificateUnverifiedTitle,
        ),
        // Large text can make the body taller than the screen; without this
        // the actions are pushed off the bottom and the dialog cannot be
        // answered at all.
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              changed
                  ? strings.certificateChangedBody(encounter.host)
                  : strings.certificateUnverifiedBody(encounter.host),
            ),
            const SizedBox(height: 16),
            Text(
              strings.certificateFingerprintLabel,
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 4),
            SelectableText(
              _groupFingerprint(encounter.fingerprint),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(changed ? strings.close : strings.cancel),
          ),
          // A changed fingerprint is never resolved by tapping through it:
          // the account that trusts the old one has to be removed first.
          if (!changed)
            FilledButton(
              key: const Key('certificate-trust-confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(strings.certificateTrustAction),
            ),
        ],
      ),
    );
    if (trusted != true || !mounted) {
      return false;
    }
    ref.read(onboardingCoordinatorProvider).trustCertificate(encounter);
    return true;
  }

  void _cancel() {
    _cancellation?.cancel();
    if (_phase == _OnboardingPhase.checking ||
        _phase == _OnboardingPhase.openingLogin) {
      setState(() {
        _phase = _OnboardingPhase.entry;
        _pending = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return PopScope(
      canPop: _phase != _OnboardingPhase.waitingForLogin,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _cancel();
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: _phase == _OnboardingPhase.waitingForLogin
                ? _WaitingForLogin(
                    key: const ValueKey('waiting'),
                    pending: _pending!,
                    onCancel: _cancel,
                  )
                : _OnboardingContent(
                    key: const ValueKey('entry'),
                    serverController: _serverController,
                    serverFocus: _serverFocus,
                    busy: _busy,
                    phase: _phase,
                    reauthentication: widget.reauthenticateAccount != null,
                    errorMessage: _errorMessage(strings, _error),
                    onConnect: _connect,
                  ),
          ),
        ),
      ),
    );
  }
}

final class _OnboardingContent extends StatelessWidget {
  const _OnboardingContent({
    super.key,
    required this.serverController,
    required this.serverFocus,
    required this.busy,
    required this.phase,
    required this.reauthentication,
    required this.errorMessage,
    required this.onConnect,
  });

  final TextEditingController serverController;
  final FocusNode serverFocus;
  final bool busy;
  final _OnboardingPhase phase;
  final bool reauthentication;
  final String? errorMessage;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final desktop = constraints.maxWidth >= 900;
        final content = desktop
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: _Introduction(
                      key: const Key('onboarding-introduction'),
                      strings: strings,
                    ),
                  ),
                  const SizedBox(width: 48),
                  SizedBox(
                    width: 420,
                    child: _ServerCard(
                      key: const Key('onboarding-server-card'),
                      controller: serverController,
                      focusNode: serverFocus,
                      busy: busy,
                      phase: phase,
                      reauthentication: reauthentication,
                      errorMessage: errorMessage,
                      onConnect: onConnect,
                    ),
                  ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Introduction(
                    key: const Key('onboarding-introduction'),
                    strings: strings,
                  ),
                  const SizedBox(height: 24),
                  _ServerCard(
                    key: const Key('onboarding-server-card'),
                    controller: serverController,
                    focusNode: serverFocus,
                    busy: busy,
                    phase: phase,
                    reauthentication: reauthentication,
                    errorMessage: errorMessage,
                    onConnect: onConnect,
                  ),
                ],
              );
        return SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal: desktop ? 48 : 20,
            vertical: desktop ? 40 : 24,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1120),
              child: content,
            ),
          ),
        );
      },
    );
  }
}

final class _Introduction extends StatelessWidget {
  const _Introduction({super.key, required this.strings});

  final AppLocalizations strings;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const BrandMark(),
        const SizedBox(height: 24),
        Text(strings.onboardingTitle, style: textTheme.headlineLarge),
        const SizedBox(height: 12),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Text(
            strings.onboardingBody,
            style: textTheme.bodyLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 28),
        _FeatureLine(
          icon: Icons.hub_outlined,
          title: strings.multiServerTitle,
          body: strings.multiServerBody,
        ),
        const SizedBox(height: 18),
        _FeatureLine(
          icon: Icons.shield_outlined,
          title: strings.secureTitle,
          body: strings.secureBody,
        ),
      ],
    );
  }
}

final class _FeatureLine extends StatelessWidget {
  const _FeatureLine({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(15),
          ),
          child: Icon(icon, color: scheme.onPrimaryContainer),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 3),
              Text(
                body,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

final class _ServerCard extends StatelessWidget {
  const _ServerCard({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.busy,
    required this.phase,
    required this.reauthentication,
    required this.errorMessage,
    required this.onConnect,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool busy;
  final _OnboardingPhase phase;
  final bool reauthentication;
  final String? errorMessage;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              reauthentication
                  ? strings.reauthenticateAccountTitle
                  : strings.addServerTitle,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 20),
            TextField(
              controller: controller,
              focusNode: focusNode,
              enabled: !busy && !reauthentication,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.url],
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: strings.serverAddressLabel,
                hintText: strings.serverAddressHint,
                prefixIcon: const Icon(Icons.language_rounded),
              ),
              onSubmitted: (_) => onConnect(),
            ),
            if (errorMessage != null) ...[
              const SizedBox(height: 14),
              Semantics(
                liveRegion: true,
                child: _InlineError(message: errorMessage!),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: busy ? null : onConnect,
              icon: busy
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    )
                  : const Icon(Icons.arrow_forward_rounded),
              label: Text(_buttonLabel(strings)),
            ),
          ],
        ),
      ),
    );
  }

  String _buttonLabel(AppLocalizations strings) => switch (phase) {
    _OnboardingPhase.entry =>
      reauthentication ? strings.reauthenticateAccountAction : strings.connect,
    _OnboardingPhase.checking => strings.checkingServer,
    _OnboardingPhase.openingLogin => strings.openingLogin,
    _OnboardingPhase.waitingForLogin => strings.waitingForLogin,
  };
}

final class _InlineError extends StatelessWidget {
  const _InlineError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, color: scheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

final class _WaitingForLogin extends StatelessWidget {
  const _WaitingForLogin({
    super.key,
    required this.pending,
    required this.onCancel,
  });

  final PendingLogin pending;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                children: [
                  const BrandMark(size: 64),
                  const SizedBox(height: 28),
                  const CircularProgressIndicator(),
                  const SizedBox(height: 24),
                  Text(
                    strings.waitingForLogin,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    strings.waitingForLoginBody,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    pending.server.uri.host,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 24),
                  OutlinedButton.icon(
                    onPressed: onCancel,
                    icon: const Icon(Icons.close_rounded),
                    label: Text(strings.cancel),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String? _errorMessage(AppLocalizations strings, Object? error) {
  return switch (error) {
    null => null,
    OnboardingFailure(:final code, :final serverBlockers) => switch (code) {
      OnboardingFailureCode.invalidServer => strings.invalidServer,
      OnboardingFailureCode.serverNotReady => _serverBlockerMessage(
        strings,
        serverBlockers,
      ),
      OnboardingFailureCode.browserUnavailable => strings.browserUnavailable,
      OnboardingFailureCode.loginTimedOut => strings.loginTimedOut,
      OnboardingFailureCode.talkUnavailable => strings.talkUnavailable,
      OnboardingFailureCode.accountIdentityMismatch =>
        strings.reauthenticateAccountMismatch,
      OnboardingFailureCode.localPersistence => strings.localPersistenceFailed,
      OnboardingFailureCode.untrustedCertificate =>
        strings.certificateUnverifiedTitle,
    },
    NextcloudApiException(:final code) => switch (code) {
      NextcloudApiError.cancelled => null,
      NextcloudApiError.network ||
      NextcloudApiError.timeout => strings.serverUnavailable,
      NextcloudApiError.responseTooLarge ||
      NextcloudApiError.invalidJson ||
      NextcloudApiError.invalidAvatarUri ||
      NextcloudApiError.invalidAvatarResponse ||
      NextcloudApiError.invalidWebPushResponse ||
      NextcloudApiError.unexpectedStatus => strings.invalidResponse,
    },
    TalkProtocolException() => strings.invalidResponse,
    _ => strings.unexpectedError,
  };
}

String _serverBlockerMessage(
  AppLocalizations strings,
  Set<ServerStatusBlocker> blockers,
) {
  if (blockers.contains(ServerStatusBlocker.maintenance)) {
    return strings.serverMaintenance;
  }
  if (blockers.contains(ServerStatusBlocker.databaseUpgradeRequired)) {
    return strings.serverUpgrade;
  }
  return strings.serverNotInstalled;
}

/// Splits a fingerprint into byte pairs so a person can compare it with what
/// their server prints without losing their place.
String _groupFingerprint(String fingerprint) {
  final groups = <String>[];
  for (var index = 0; index < fingerprint.length; index += 2) {
    groups.add(
      fingerprint.substring(index, (index + 2).clamp(0, fingerprint.length)),
    );
  }
  return groups.join(':').toUpperCase();
}
