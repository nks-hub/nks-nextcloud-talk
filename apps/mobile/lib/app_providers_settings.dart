part of 'app_providers.dart';

final Provider<RemoteWipeService> remoteWipeServiceProvider =
    Provider<RemoteWipeService>((ref) {
      return RemoteWipeService(
        accounts: ref.watch(accountRepositoryProvider),
        credentials: ref.watch(credentialVaultProvider),
        api: ref.watch(nextcloudApiProvider),
        removeAccount: (accountId) async {
          final outcome = await ref
              .read(accountRemovalServiceProvider)
              .removeAccount(accountId);
          return outcome.accountExisted;
        },
      );
    });

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
        ref.read(callSignalingCoordinatorProvider).shutdownAccount(accountId),
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

final listPanePreferenceStoreProvider = Provider<ListPanePreferenceStore>((
  ref,
) {
  return FileListPanePreferenceStore();
});

final conversationListWidthProvider =
    NotifierProvider<ConversationListWidthController, double?>(
      ConversationListWidthController.new,
    );

/// Width the person dragged the conversation list to, or null for the
/// platform default. Null rather than a number, so the default can change with
/// the window without overriding a deliberate drag.
final class ConversationListWidthController extends Notifier<double?> {
  @override
  double? build() {
    unawaited(_load());
    return null;
  }

  Future<void> _load() async {
    final stored = await ref.read(listPanePreferenceStoreProvider).readWidth();
    if (stored != null && state != stored) {
      state = stored;
    }
  }

  /// Called while the splitter is dragged, so the pane follows the pointer;
  /// only [commit] touches the disk.
  void preview(double width) {
    state = width.clamp(kMinListPaneWidth, kMaxListPaneWidth);
  }

  Future<void> commit() async {
    final width = state;
    if (width == null) {
      return;
    }
    await ref.read(listPanePreferenceStoreProvider).writeWidth(width);
  }
}

final conversationListCollapsedProvider =
    NotifierProvider<ConversationListCollapsedController, bool>(
      ConversationListCollapsedController.new,
    );

/// Whether the conversation list is folded away on a wide window.
///
/// Starts shown and corrects itself once the stored value is read: a list that
/// flickers into view is a smaller problem than a window that opens with the
/// conversations apparently gone.
final class ConversationListCollapsedController extends Notifier<bool> {
  @override
  bool build() {
    unawaited(_load());
    return false;
  }

  Future<void> _load() async {
    final stored = await ref
        .read(listPanePreferenceStoreProvider)
        .readCollapsed();
    if (state != stored) {
      state = stored;
    }
  }

  Future<void> toggle() async {
    final collapsed = !state;
    state = collapsed;
    await ref
        .read(listPanePreferenceStoreProvider)
        .writeCollapsed(collapsed: collapsed);
  }
}

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
