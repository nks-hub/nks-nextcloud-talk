import 'dart:async';

import 'package:flutter/material.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../l10n/generated/app_localizations.dart';
import 'qr_scan_session.dart';

/// Full-screen camera view that reads a Nextcloud `nc://login/` QR code.
///
/// The scanned string carries an app password in the clear, so it never leaves
/// this screen: it is parsed in place and only the parsed payload is handed
/// back. Nothing derived from it reaches a log, an error message or telemetry.
final class QrLoginScannerScreen extends StatefulWidget {
  const QrLoginScannerScreen({
    super.key,
    this.openSession = openCameraQrScanSession,
    this.onOpenSettings,
  });

  final QrScanSessionOpener openSession;

  /// Offered on the permission screen; null hides the action.
  final Future<bool> Function()? onOpenSettings;

  static Future<QrLoginPayload?> push(
    BuildContext context, {
    Future<bool> Function()? onOpenSettings,
  }) {
    return Navigator.of(context).push<QrLoginPayload>(
      MaterialPageRoute<QrLoginPayload>(
        settings: const RouteSettings(name: '/onboarding/qr'),
        builder: (context) =>
            QrLoginScannerScreen(onOpenSettings: onOpenSettings),
      ),
    );
  }

  @override
  State<QrLoginScannerScreen> createState() => _QrLoginScannerScreenState();
}

final class _QrLoginScannerScreenState extends State<QrLoginScannerScreen> {
  QrScanSession? _session;
  StreamSubscription<String>? _subscription;
  QrScanFailure? _failure;
  bool _unreadable = false;
  bool _handled = false;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    unawaited(_session?.close());
    super.dispose();
  }

  Future<void> _open() async {
    try {
      final session = await widget.openSession();
      if (!mounted) {
        await session.close();
        return;
      }
      _subscription = session.payloads.listen(_onPayload);
      setState(() => _session = session);
    } on QrScanException catch (error) {
      if (mounted) {
        setState(() => _failure = error.failure);
      }
    } on Object {
      if (mounted) {
        setState(() => _failure = QrScanFailure.unavailable);
      }
    }
  }

  void _onPayload(String raw) {
    if (_handled) {
      return;
    }
    final payload = parseQrLoginPayload(raw);
    if (payload == null) {
      // Whatever this code held is not ours. The value itself is never shown,
      // stored or reported: a foreign QR code can hold anything.
      if (!_unreadable) {
        setState(() => _unreadable = true);
      }
      return;
    }
    _handled = true;
    Navigator.of(context).pop(payload);
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final failure = _failure;
    final session = _session;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: Text(strings.scanLoginCode)),
      body: switch ((failure, session)) {
        (final QrScanFailure failure, _) => _ScannerMessage(
          key: const Key('qr-login-scanner-failure'),
          message: failure == QrScanFailure.permissionDenied
              ? strings.scanLoginCodeCameraDenied
              : strings.scanLoginCodeCameraUnavailable,
          onOpenSettings: failure == QrScanFailure.permissionDenied
              ? widget.onOpenSettings
              : null,
          openSettingsLabel: strings.openAppSettings,
        ),
        (_, null) => const Center(
          key: Key('qr-login-scanner-starting'),
          child: CircularProgressIndicator(),
        ),
        (_, final QrScanSession session) => Stack(
          fit: StackFit.expand,
          children: [
            session.buildPreview(),
            Positioned(
              left: 16,
              right: 16,
              bottom: 24,
              child: _ScannerBanner(
                key: _unreadable
                    ? const Key('qr-login-scanner-unreadable')
                    : const Key('qr-login-scanner-hint'),
                text: _unreadable
                    ? strings.scanLoginCodeUnreadable
                    : strings.scanLoginCodeHint,
              ),
            ),
          ],
        ),
      },
    );
  }
}

final class _ScannerMessage extends StatelessWidget {
  const _ScannerMessage({
    super.key,
    required this.message,
    required this.onOpenSettings,
    required this.openSettingsLabel,
  });

  final String message;
  final Future<bool> Function()? onOpenSettings;
  final String openSettingsLabel;

  @override
  Widget build(BuildContext context) {
    final openSettings = onOpenSettings;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography_outlined, color: Colors.white70),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
            if (openSettings != null) ...[
              const SizedBox(height: 16),
              OutlinedButton(
                key: const Key('qr-login-scanner-open-settings'),
                onPressed: () => unawaited(openSettings()),
                child: Text(openSettingsLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

final class _ScannerBanner extends StatelessWidget {
  const _ScannerBanner({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white),
        ),
      ),
    );
  }
}
