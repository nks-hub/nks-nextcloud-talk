part of 'app_providers.dart';

final accountRemovalServiceProvider = Provider<AccountRemovalService>((ref) {
  return AccountRemovalService(
    accounts: ref.watch(accountRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    api: ref.watch(nextcloudApiProvider),
    mediaCache: ref.watch(chatMediaCacheProvider),
    mediaDiskCache: ref.watch(chatMediaDiskCacheProvider),
    emojiUsage: ref.watch(emojiUsageStoreProvider),
    clearChatBackgrounds: (accountId) async {
      final backgrounds = await ref.read(chatBackgroundStoreProvider.future);
      await backgrounds.removeAccount(accountId);
    },
    voiceDirectory: ref.watch(chatVoiceCacheDirectoryProvider),
    chatAttachmentDirectory: getApplicationCacheDirectory,
    attachmentSources: () => ref.read(attachmentSourceProvider.future),
    onRemovalStarted: (accountId) async {
      final attachment = ref.read(attachmentServiceProvider.future);
      await Future.wait<void>(<Future<void>>[
        ref.read(chatServiceProvider).suspendAccount(accountId),
        attachment.then(
          (service) => service.suspendAccount(AccountId.parse(accountId)),
        ),
        if (ref.read(androidPushCoordinatorProvider) case final coordinator?)
          coordinator.suspendAccount(accountId),
      ]);
    },
    revokePush: (accountId) async {
      final coordinator = ref.read(androidPushRegistrationCoordinatorProvider);
      return coordinator == null || await coordinator.revokeAccount(accountId);
    },
  );
});

/// Navigator observers contributed by telemetry, empty in every build that
/// has no telemetry configured. Overridden once at startup so the widget tree
/// never has to know whether an SDK is present.
final telemetryNavigatorObserversProvider = Provider<List<NavigatorObserver>>(
  (ref) => const [],
);

final themePreferenceStoreProvider = Provider<ThemePreferenceStore>((ref) {
  return FileThemePreferenceStore();
});

final themeModeProvider = NotifierProvider<ThemeModeController, ThemeMode>(
  ThemeModeController.new,
);

final class ThemeModeController extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    unawaited(_load());
    return ThemeMode.system;
  }

  Future<void> _load() async {
    final stored = await ref.read(themePreferenceStoreProvider).read();
    if (state != stored) {
      state = stored;
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = mode;
    await ref.read(themePreferenceStoreProvider).write(mode);
  }
}
