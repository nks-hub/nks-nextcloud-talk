import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_providers.dart';
import 'core/app_theme.dart';
import 'core/brand_mark.dart';
import 'features/conversations/conversation_shell.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'l10n/generated/app_localizations.dart';

final class NextcloudTalkApp extends ConsumerWidget {
  const NextcloudTalkApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      debugShowCheckedModeBanner: false,
      restorationScopeId: 'nks_nextcloud_talk',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ref.watch(themeModeProvider),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      navigatorObservers: ref.watch(telemetryNavigatorObserversProvider),
      home: const _AppHome(),
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
