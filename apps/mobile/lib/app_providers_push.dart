part of 'app_providers.dart';

final androidPushTransportStoreProvider = Provider<AndroidPushTransportStore>((
  ref,
) {
  return FileAndroidPushTransportStore();
});

/// Which of the two Android push paths is live. Switchable at runtime, no new
/// build needed: the native path is our own proxy, Web Push over UnifiedPush
/// stays as the fallback.
final androidPushTransportProvider =
    NotifierProvider<AndroidPushTransportController, AndroidPushTransport>(
      AndroidPushTransportController.new,
    );

final class AndroidPushTransportController
    extends Notifier<AndroidPushTransport> {
  @override
  AndroidPushTransport build() {
    unawaited(_load());
    return androidPushTransportDefault;
  }

  Future<void> _load() async {
    final stored = await ref.read(androidPushTransportStoreProvider).read();
    if (state != stored) {
      state = stored;
    }
  }

  /// Hands the device over to [transport]. The old path is revoked first, so
  /// the two never hold a registration for this device at the same time; a
  /// failed revocation leaves the old path in force and rethrows.
  ///
  /// [revoke] is supplied by the caller rather than read here on purpose: both
  /// coordinator providers watch this notifier, so reading them back from
  /// inside it is a dependency cycle and Riverpod refuses it at the first
  /// switch. [revokeAndroidPushTransport] is the implementation to pass.
  Future<void> select(
    AndroidPushTransport transport, {
    required Future<void> Function(AndroidPushTransport live) revoke,
  }) async {
    state = await AndroidPushTransportSwitch(
      store: ref.read(androidPushTransportStoreProvider),
      revoke: revoke,
    ).select(transport, current: state);
  }
}

/// Unregisters this device from [live] — at Nextcloud and at whichever gateway
/// that transport uses. Call it from outside the provider graph (a widget) and
/// hand it to [AndroidPushTransportController.select].
Future<void> revokeAndroidPushTransport(
  WidgetRef ref,
  AndroidPushTransport live,
) async {
  switch (live) {
    case AndroidPushTransport.webPush:
      await ref.read(androidPushCoordinatorProvider)?.revokeAllRegistrations();
    case AndroidPushTransport.proxy:
      await ref.read(androidPushRegistrationCoordinatorProvider)?.unfollowAll();
  }
}

/// Runs on both transports, but only subscribes to Web Push on its own.
///
/// The notification a user taps and the reply they type come back through the
/// native layer whichever transport delivered them, so this coordinator has to
/// be alive either way; `subscribes` is what tells it whether the Web Push
/// registration is also its job.
final androidPushCoordinatorProvider = Provider<AndroidPushCoordinator?>((ref) {
  final platform = ref.watch(androidWebPushPlatformProvider);
  if (platform == null) {
    return null;
  }
  // Read, never watch: this coordinator must outlive a transport switch.
  final coordinator = _buildAndroidPushCoordinator(ref, platform);
  ref.listen<AndroidPushTransport>(androidPushTransportProvider, (_, next) {
    coordinator.subscribes = next == AndroidPushTransport.webPush;
  }, fireImmediately: true);
  return coordinator;
});

AndroidPushCoordinator _buildAndroidPushCoordinator(
  Ref ref,
  AndroidWebPushPlatform platform,
) {
  final coordinator = AndroidPushCoordinator(
    accounts: ref.watch(accountRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    api: ref.watch(nextcloudApiProvider),
    platform: platform,
    subscribes:
        ref.read(androidPushTransportProvider) == AndroidPushTransport.webPush,
    onWakeUp: (accountId) =>
        ref.read(conversationSyncServiceProvider).sync(accountId),
    onNotificationAction: (action) => _runNotificationAction(ref, action),
    reconciliationWakeEvents: <Stream<void>>[
      ref.watch(connectivityWakeEventsProvider),
      ref.watch(appLifecycleResumeEventsProvider),
    ],
    retryableError: (error) =>
        error is ConversationSyncException &&
        switch (error.code) {
          ConversationSyncError.network ||
          ConversationSyncError.rateLimited ||
          ConversationSyncError.serviceUnavailable => true,
          _ => false,
        },
  );
  ref.onDispose(() => unawaited(coordinator.close()));
  unawaited(coordinator.start());
  return coordinator;
}

/// Registers this Android device for push v2 against our own proxy — the same
/// wire contract iOS uses, which keeps the public UnifiedPush rewrite gateway
/// out of the path entirely.
///
/// Null off Android and while the Web Push fallback is selected.
///
/// NOT YET DELIVERING: nothing calls `installToken`, because the app has no
/// FCM integration to get a token from. Without a provider token the state
/// machine plans no effect at all, so this registers nowhere until the
/// Firebase project is wired in. Kept honest by a test.
final androidPushRegistrationCoordinatorProvider =
    Provider<PushRegistrationCoordinator?>((ref) {
      if (!Platform.isAndroid ||
          ref.watch(androidPushTransportProvider) !=
              AndroidPushTransport.proxy) {
        return null;
      }
      final coordinator = PushRegistrationCoordinator(
        accounts: ref.watch(accountRepositoryProvider),
        credentials: ref.watch(credentialVaultProvider),
        api: ref.watch(nextcloudApiProvider),
        keyStore: AndroidPushDeviceKeyChannel(),
        gateway: PushGatewayOrigin.parse('https://push.example.invalid'),
        tokenHandlePrefix: 'fcm-token',
      );
      final fcm = AndroidFcmChannel(onToken: coordinator.installToken);
      final platform = ref.watch(androidWebPushPlatformProvider);
      ref.onDispose(() {
        fcm.dispose();
        unawaited(coordinator.dispose());
      });

      // Same account-following shape as the Apple and Client Push
      // coordinators: track whoever the UI currently shows.
      ref.listen<AsyncValue<List<StoredAccount>>>(accountsProvider, (
        previous,
        next,
      ) {
        final signedIn = next.valueOrNull;
        if (signedIn == null) {
          return;
        }
        final live = signedIn.map((account) => account.id).toSet();
        for (final accountId in live) {
          unawaited(coordinator.follow(accountId));
        }
        for (final accountId
            in previous?.valueOrNull
                    ?.map((account) => account.id)
                    .where((id) => !live.contains(id)) ??
                const <String>[]) {
          unawaited(coordinator.unfollow(accountId));
        }
        // Always, including when the last account goes: a delivery resolves
        // its account by trying each key, so a stale list would keep trying a
        // key that no longer exists.
        unawaited(fcm.setAccounts(live));
        if (live.isEmpty) {
          return;
        }
        // Only once somebody is signed in: a token, and the permission to
        // show what arrives with it, are both pointless before that. The
        // permission call is the same one the Web Push path uses — it is an
        // activity-level Android 13 prompt, not a Web Push detail.
        unawaited(_ensureAndroidNotificationPermission(platform));
        unawaited(fcm.start());
      }, fireImmediately: true);
      return coordinator;
    });

Future<void> _ensureAndroidNotificationPermission(
  AndroidWebPushPlatform? platform,
) async {
  if (platform == null) {
    return;
  }
  if (await platform.getNotificationPermission() ==
      AndroidNotificationPermission.notDetermined) {
    await platform.requestNotificationPermission();
  }
}

/// Shows Talk messages as Windows notifications while the app runs. Null
/// elsewhere: every other platform already has one.
final windowsNotificationServiceProvider =
    Provider<WindowsNotificationService?>((ref) {
      // Same gate as `clientPushEnabledProvider`: a widget test on a Windows
      // host would otherwise open a live Drift query and leave its timer
      // pending after the tree is gone.
      if (!Platform.isWindows || !ref.watch(clientPushEnabledProvider)) {
        return null;
      }
      final service = WindowsNotificationService(
        accounts: ref.watch(accountRepositoryProvider),
        channel: WindowsNotificationChannel(
          onNotificationAction:
              ({
                required kind,
                required accountId,
                required roomToken,
                replyText,
              }) => _runOneShotNotificationAction(
                ref,
                kind: kind,
                accountId: accountId,
                roomToken: roomToken,
                replyText: replyText,
              ),
        ),
      );
      ref.onDispose(() => unawaited(service.dispose()));
      ref.listen<AsyncValue<List<StoredAccount>>>(accountsProvider, (
        previous,
        next,
      ) {
        final signedIn = next.valueOrNull;
        if (signedIn == null) {
          return;
        }
        final live = signedIn.map((account) => account.id).toSet();
        for (final account in signedIn) {
          service.follow(account.id);
        }
        for (final accountId
            in previous?.valueOrNull
                    ?.map((account) => account.id)
                    .where((id) => !live.contains(id)) ??
                const <String>[]) {
          unawaited(service.unfollow(accountId));
        }
      }, fireImmediately: true);
      return service;
    });

/// Asks Apple platforms for notification permission, keeps the APNs device
/// token, and
/// hands every token to [applePushRegistrationCoordinatorProvider] so it can
/// register (or refresh) push v2.
final applePushCoordinatorProvider = Provider<ApplePushCoordinator?>((ref) {
  if (!Platform.isIOS && !Platform.isMacOS) {
    return null;
  }
  final registration = ref.watch(applePushRegistrationCoordinatorProvider);
  final coordinator = ApplePushCoordinator(
    onToken: registration?.installToken,
    onNotificationAction:
        ({required kind, required accountId, required roomToken, replyText}) =>
            _runOneShotNotificationAction(
              ref,
              kind: kind,
              accountId: accountId,
              roomToken: roomToken,
              replyText: replyText,
            ),
  );
  ref.onDispose(coordinator.dispose);
  unawaited(coordinator.checkLaunchNotificationOpen());

  // Asking only makes sense once someone is signed in, and only needs to
  // happen once per session — the coordinator itself guards against asking
  // twice, this just avoids firing before there is any account at all.
  ref.listen<AsyncValue<List<StoredAccount>>>(accountsProvider, (
    previous,
    next,
  ) {
    final signedIn = next.valueOrNull;
    if (signedIn == null || signedIn.isEmpty) {
      return;
    }
    unawaited(coordinator.requestPermissionAndLogToken());
  }, fireImmediately: true);

  return coordinator;
});

/// Registers this device for Nextcloud push v2 and the `nks-talk-notify`
/// APNs proxy — see that project's README for the wire contract each effect
/// executes. `null` outside Apple platforms: there is no APNs token or
/// Keychain device-key channel to register without it.
final applePushRegistrationCoordinatorProvider =
    Provider<ApplePushRegistrationCoordinator?>((ref) {
      if (!Platform.isIOS && !Platform.isMacOS) {
        return null;
      }
      final deviceKeyChannel = ApplePushDeviceKeyChannel();
      final coordinator = ApplePushRegistrationCoordinator(
        accounts: ref.watch(accountRepositoryProvider),
        credentials: ref.watch(credentialVaultProvider),
        api: ref.watch(nextcloudApiProvider),
        keyStore: deviceKeyChannel,
        gateway: PushGatewayOrigin.parse('https://push.example.invalid'),
        pushEnvironment: kDebugMode ? 'development' : 'production',
        recordDeviceKeyAccount: deviceKeyChannel.recordAccount,
      );
      ref.onDispose(() => unawaited(coordinator.dispose()));

      // Same account-following shape as clientPushCoordinatorProvider: track
      // whoever the UI currently shows, without a second place having to
      // remember the account list itself.
      ref.listen<AsyncValue<List<StoredAccount>>>(accountsProvider, (
        previous,
        next,
      ) {
        final signedIn = next.valueOrNull;
        if (signedIn == null) {
          return;
        }
        final live = signedIn.map((account) => account.id).toSet();
        for (final accountId in live) {
          unawaited(coordinator.follow(accountId));
        }
        for (final accountId
            in previous?.valueOrNull
                    ?.map((account) => account.id)
                    .where((id) => !live.contains(id)) ??
                const <String>[]) {
          unawaited(coordinator.unfollow(accountId));
        }
      }, fireImmediately: true);
      return coordinator;
    });

/// Sends a notification-shade reply through [ChatService.sendText] and
/// therefore through the durable text-send outbox: the same `referenceId`
/// correlation, the same ambiguous-send rules and the same visible retry
/// entry in the room as a reply typed in the composer. Sending straight from
/// the notification would be a second, uncorrelated POST and the documented
/// duplicate risk of `docs/architecture/chat-messages-api.md` would apply.
///
/// Shared by Android's and iOS's notification-action handlers below, so the
/// two platforms cannot diverge on what "reply from a notification" means.
Future<void> _sendNotificationReply(
  Ref ref, {
  required String accountId,
  required String roomToken,
  required String text,
}) {
  return ref
      .read(chatServiceProvider)
      .sendText(accountId: accountId, roomToken: roomToken, message: text);
}

/// Marks a conversation read from a notification-shade action. The read
/// marker is an explicit message id, so the cached room has to know the
/// newest message before the marker can move — hence syncing both before and
/// after. Shared with iOS for the same reason as [_sendNotificationReply].
Future<void> _markNotificationRead(
  Ref ref, {
  required String accountId,
  required String roomToken,
}) async {
  await ref.read(conversationSyncServiceProvider).sync(accountId);
  await ref
      .read(roomSettingsServiceProvider)
      .markConversationRead(accountId: accountId, roomToken: roomToken);
  await ref.read(conversationSyncServiceProvider).sync(accountId);
}

/// Executes a notification-shade action for exactly `action.accountId`.
Future<AndroidPushActionOutcome> _runNotificationAction(
  Ref ref,
  AndroidNotificationAction action,
) async {
  try {
    switch (action.kind) {
      case AndroidNotificationActionKind.reply:
        await _sendNotificationReply(
          ref,
          accountId: action.accountId,
          roomToken: action.roomToken,
          text: action.replyText ?? '',
        );
      case AndroidNotificationActionKind.markRead:
        await _markNotificationRead(
          ref,
          accountId: action.accountId,
          roomToken: action.roomToken,
        );
    }
    return AndroidPushActionOutcome.completed;
  } on ChatServiceException catch (error) {
    return switch (error.code) {
      ChatServiceError.network ||
      ChatServiceError.rateLimited ||
      ChatServiceError.serviceUnavailable ||
      ChatServiceError.talkUnavailable => AndroidPushActionOutcome.retry,
      _ => AndroidPushActionOutcome.failed,
    };
  } on RoomSettingsException catch (error) {
    return switch (error.code) {
      RoomSettingsError.network ||
      RoomSettingsError.rateLimited ||
      RoomSettingsError.serviceUnavailable => AndroidPushActionOutcome.retry,
      _ => AndroidPushActionOutcome.failed,
    };
  } on NextcloudApiException catch (error) {
    return switch (error.code) {
      NextcloudApiError.network ||
      NextcloudApiError.timeout => AndroidPushActionOutcome.retry,
      _ => AndroidPushActionOutcome.failed,
    };
  }
}

/// Executes a tapped Reply/Mark-as-read action from an iOS notification.
///
/// [accountId] comes straight from `AppDelegate.swift`'s `didReceive`
/// override, which got it from `PushNotificationRouteStore` — the account
/// whose key actually decrypted the push, recorded at decrypt time. It is
/// never re-derived from a server host, which would be ambiguous with two
/// signed-in accounts on the same server. A reply with empty text is a no-op.
///
/// iOS has no durable action queue like Android's to retry from — its window
/// to call the OS completion handler is short and one-shot — so a failure
/// here simply doesn't send/mark-read, the same outcome as a reply typed in
/// the composer while offline. That's why this has no return value or retry
/// classification, unlike [_runNotificationAction].
Future<void> _runOneShotNotificationAction(
  Ref ref, {
  required String kind,
  required String accountId,
  required String roomToken,
  String? replyText,
}) async {
  switch (kind) {
    case 'reply':
      final text = replyText?.trim();
      if (text == null || text.isEmpty) {
        return;
      }
      await _sendNotificationReply(
        ref,
        accountId: accountId,
        roomToken: roomToken,
        text: text,
      );
    case 'markRead':
      await _markNotificationRead(
        ref,
        accountId: accountId,
        roomToken: roomToken,
      );
  }
}

final deepLinkPlatformProvider = Provider<DeepLinkPlatform?>((ref) {
  if (!Platform.isAndroid && !Platform.isIOS && !Platform.isMacOS) {
    return null;
  }
  final bridge = DeepLinkBridge();
  ref.onDispose(() => unawaited(bridge.dispose()));
  return bridge;
});

final deepLinkResolverProvider = Provider<DeepLinkResolver>((ref) {
  return DeepLinkResolver(ref.watch(accountRepositoryProvider));
});

final deepLinkCoordinatorProvider = Provider<DeepLinkCoordinator?>((ref) {
  final platform = ref.watch(deepLinkPlatformProvider);
  if (platform == null) {
    return null;
  }
  final coordinator = DeepLinkCoordinator(
    platform: platform,
    resolver: () => ref.read(deepLinkResolverProvider),
  );
  ref.onDispose(() => unawaited(coordinator.close()));
  unawaited(coordinator.start());
  return coordinator;
});
