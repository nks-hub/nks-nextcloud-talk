import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_providers.dart';
import 'core/app_theme.dart';
import 'core/brand_mark.dart';
import 'features/conversations/conversation_shell.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/settings/app_lock/app_lock_gate.dart';
import 'features/share/incoming_share_host.dart';
import 'l10n/generated/app_localizations.dart';

final class NextcloudTalkApp extends ConsumerStatefulWidget {
  const NextcloudTalkApp({super.key});

  @override
  ConsumerState<NextcloudTalkApp> createState() => _NextcloudTalkAppState();
}

/// Swallows the route the platform pushes when a link opens the app.
///
/// A link arrives twice: once through our own `deep_link` channel, which
/// resolves it against the signed-in accounts, and once through Flutter's
/// `pushRouteInformation`, which turns the link's path into a route name and
/// hands it to `Navigator.pushNamed`. This app has no named routes, so that
/// second delivery reached `WidgetsApp._onUnknownRoute`, whose `onUnknownRoute!`
/// is null here - a fatal `Null check operator used on a null value` on every
/// link, reported by a real device (Sentry NKS-TALK-6).
///
/// Reporting the push as handled stops it before the navigator ever sees it.
/// It must be registered before `WidgetsApp` registers itself, which is why it
/// lives in the state above the `MaterialApp` rather than inside it: the
/// binding asks observers in registration order and stops at the first that
/// says yes.
final class _PlatformRouteSink with WidgetsBindingObserver {
  @override
  Future<bool> didPushRouteInformation(
    RouteInformation routeInformation,
  ) async => true;
}

final class _NextcloudTalkAppState extends ConsumerState<NextcloudTalkApp> {
  final _PlatformRouteSink _routeSink = _PlatformRouteSink();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(_routeSink);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(_routeSink);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final serverSeed = AppTheme.seedFromServerHex(
      ref.watch(selectedAccountThemeColorProvider).valueOrNull,
    );
    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      debugShowCheckedModeBanner: false,
      restorationScopeId: 'nks_nextcloud_talk',
      theme: AppTheme.light(seedColor: serverSeed),
      darkTheme: AppTheme.dark(seedColor: serverSeed),
      themeMode: ref.watch(themeModeProvider),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      navigatorObservers: ref.watch(telemetryNavigatorObserversProvider),
      home: const AppLockGate(child: IncomingShareHost(child: _AppHome())),
    );
  }
}

final class _AppHome extends ConsumerWidget {
  const _AppHome();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(androidPushCoordinatorProvider);
    ref.watch(androidPushRegistrationCoordinatorProvider);
    ref.watch(windowsNotificationServiceProvider);
    // Nextcloud's live channel, on every platform the app runs on.
    ref.watch(clientPushCoordinatorProvider);
    ref.watch(applePushCoordinatorProvider);
    ref.watch(deepLinkCoordinatorProvider);
    final accounts = ref.watch(accountsProvider);
    return accounts.when(
      data: (items) =>
          items.isEmpty ? const OnboardingScreen() : const ConversationShell(),
      loading: () => const _StartupScreen(),
      error: (_, _) =>
          _StartupFailure(onRetry: () => ref.invalidate(accountsProvider)),
    );
  }
}

final class _StartupScreen extends StatelessWidget {
  const _StartupScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              BrandMark(size: 64),
              SizedBox(height: 24),
              CircularProgressIndicator(),
            ],
          ),
        ),
      ),
    );
  }
}

final class _StartupFailure extends StatelessWidget {
  const _StartupFailure({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.storage_rounded,
                    size: 52,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(height: 18),
                  Text(
                    strings.localPersistenceFailed,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(strings.retry),
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
