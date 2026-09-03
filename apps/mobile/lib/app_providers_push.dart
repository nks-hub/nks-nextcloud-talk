part of 'app_providers.dart';

final androidPushTransportStoreProvider = Provider<AndroidPushTransportStore>((
  ref,
) {
  return FileAndroidPushTransportStore();
});

final androidPushTransportHydrationProvider = FutureProvider(
  (ref) => ref.watch(androidPushTransportStoreProvider).read(),
);

final androidPushTransportSwitchingProvider =
    NotifierProvider<AndroidPushTransportSwitchingController, bool>(
      AndroidPushTransportSwitchingController.new,
    );

final class AndroidPushTransportSwitchingController extends Notifier<bool> {
  @override
  bool build() => false;

  void setSwitching(bool value) => state = value;
}

/// Which of the two Android push paths is live. Switchable at runtime, no new
/// build needed: the native path is our own proxy, Web Push over UnifiedPush
/// stays as the fallback.
final androidPushTransportProvider =
    NotifierProvider<AndroidPushTransportController, AndroidPushTransport>(
      AndroidPushTransportController.new,
    );

final class AndroidPushTransportController
    extends Notifier<AndroidPushTransport> {
  var _displayed = androidPushTransportDefault;
  var _userSelected = false;
  var _pendingSelections = 0;
  Future<void> _selectionTail = Future<void>.value();

  @override
  AndroidPushTransport build() {
    final stored = ref.watch(androidPushTransportHydrationProvider).valueOrNull;
    if (!_userSelected && stored != null) {
      _displayed = stored;
    }
    return _displayed;
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
    required Future<void> Function(AndroidPushTransport live) restore,
  }) {
    _userSelected = true;
    _pendingSelections++;
    final store = ref.read(androidPushTransportStoreProvider);
    final switching = ref.read(androidPushTransportSwitchingProvider.notifier);
    switching.setSwitching(true);
    final completion = Completer<void>();
    final previous = _selectionTail;
    _selectionTail = () async {
      await previous;
      try {
        final selected = await AndroidPushTransportSwitch(
          store: store,
          revoke: revoke,
          restore: restore,
        ).select(transport, current: _displayed);
        _displayed = selected;
        state = selected;
        completion.complete();
      } on Object catch (error, stackTrace) {
        completion.completeError(error, stackTrace);
      } finally {
        _pendingSelections--;
        if (_pendingSelections == 0) {
          switching.setSwitching(false);
        }
      }
    }();
    return completion.future;
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
      await ref.read(androidPushRegistrationCoordinatorProvider)?.revokeAll();
  }
}

Future<void> restoreAndroidPushTransport(
  WidgetRef ref,
  AndroidPushTransport live,
) async {
  switch (live) {
    case AndroidPushTransport.webPush:
      final coordinator = ref.read(androidPushCoordinatorProvider);
      if (coordinator != null) {
        coordinator.subscribes = true;
        await coordinator.reconcileAllAfterCurrent();
      }
    case AndroidPushTransport.proxy:
      await ref.read(androidPushRegistrationCoordinatorProvider)?.followAll();
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
    final wasSubscribing = coordinator.subscribes;
    final subscribes = next == AndroidPushTransport.webPush;
    coordinator.subscribes = subscribes;
    if (!wasSubscribing && subscribes) {
      unawaited(
        coordinator.reconcileAllAfterCurrent().catchError((Object _) {}),
      );
    }
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
        error is ConversationSyncException && error.isTransient,
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
          !ref.watch(androidPushTransportHydrationProvider).hasValue ||
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
        pushProvider: PushGatewayProvider.fcm,
      );
      final fcm = AndroidFcmChannel(onToken: coordinator.installToken);
      var fcmDisposed = false;
      Future<void>? fcmStart;
      void startFcm() {
        if (fcmDisposed || fcmStart != null) {
          return;
        }
        late final Future<void> current;
        current = _startAndroidFcmWithRetry(fcm, cancelled: () => fcmDisposed)
            .whenComplete(() {
              if (identical(fcmStart, current)) {
                fcmStart = null;
              }
            });
        fcmStart = current;
      }

      final resumeSubscription = ref
          .watch(appLifecycleResumeEventsProvider)
          .listen((_) => startFcm());
      final platform = ref.watch(androidWebPushPlatformProvider);
      ref.onDispose(() {
        fcmDisposed = true;
        unawaited(resumeSubscription.cancel());
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
        startFcm();
      }, fireImmediately: true);
      return coordinator;
    });

Future<void> _startAndroidFcmWithRetry(
  AndroidFcmChannel fcm, {
  required bool Function() cancelled,
}) async {
  const delays = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
  ];
  for (var attempt = 0; attempt <= delays.length; attempt++) {
    if (cancelled()) {
      return;
    }
    try {
      await fcm.start();
      return;
    } on Object {
      if (attempt == delays.length) {
        return;
      }
      await Future<void>.delayed(delays[attempt]);
    }
  }
}

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

/// Shows Talk messages as desktop notifications while the app runs.
///
/// Windows and macOS both need this, and for the same reason: Nextcloud maps
/// only the Android and iOS user agents to `apptype='talk'`, so its push proxy
/// hands a desktop client nothing as soon as the account has a phone
/// registered. Client Push keeps the app in sync over its websocket - the gap
/// this fills is that nothing ever told the user. Null on Android and iOS,
/// which really do get a push of their own.
final windowsNotificationServiceProvider =
    Provider<WindowsNotificationService?>((ref) {
      // Same gate as `clientPushEnabledProvider`: a widget test on a desktop
      // host would otherwise open a live Drift query and leave its timer
      // pending after the tree is gone.
      if ((!Platform.isWindows && !Platform.isMacOS) ||
          !ref.watch(clientPushEnabledProvider)) {
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
                messageId,
              }) => _runOneShotNotificationAction(
                ref,
                kind: kind,
                accountId: accountId,
                roomToken: roomToken,
                replyText: replyText,
                messageId: messageId,
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
        ({
          required kind,
          required accountId,
          required roomToken,
          replyText,
          notificationId,
          messageId,
        }) => _runOneShotNotificationAction(
          ref,
          kind: kind,
          accountId: accountId,
          roomToken: roomToken,
          replyText: replyText,
          notificationId: notificationId,
          messageId: messageId,
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
    Provider<PushRegistrationCoordinator?>((ref) {
      if (!Platform.isIOS && !Platform.isMacOS) {
        return null;
      }
      final deviceKeyChannel = ApplePushDeviceKeyChannel();
      final coordinator = PushRegistrationCoordinator(
        accounts: ref.watch(accountRepositoryProvider),
        credentials: ref.watch(credentialVaultProvider),
        api: ref.watch(nextcloudApiProvider),
        keyStore: deviceKeyChannel,
        gateway: PushGatewayOrigin.parse('https://push.example.invalid'),
        tokenHandlePrefix: 'apns-token',
        pushProvider: PushGatewayProvider.apns,
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
///
/// A reply from the shade answers the notified message, not the room: the
/// message id comes with the notification ([messageId], desktop builds the
/// notification from the cached message) or is looked up through the
/// Notifications API by [notificationId] (Android and iOS only get the room
/// token in the push). When neither yields a message — the notification is
/// gone, or the server has no reply support — the text still goes out as a
/// plain message rather than being lost.
Future<void> _sendNotificationReply(
  Ref ref, {
  required String accountId,
  required String roomToken,
  required String text,
  int? notificationId,
  int? messageId,
}) async {
  final chat = ref.read(chatServiceProvider);
  var replyTo = messageId;
  if (replyTo == null && notificationId != null) {
    replyTo = await _notifiedMessageId(
      ref,
      accountId: accountId,
      roomToken: roomToken,
      notificationId: notificationId,
    );
  }
  if (replyTo != null) {
    try {
      await chat.sendText(
        accountId: accountId,
        roomToken: roomToken,
        message: text,
        replyTo: replyTo,
      );
      return;
    } on ChatServiceException catch (error) {
      if (error.code != ChatServiceError.sendUnsupported) {
        rethrow;
      }
    }
  }
  await chat.sendText(
    accountId: accountId,
    roomToken: roomToken,
    message: text,
  );
}

/// Message id behind a notification, or null when the server cannot say.
/// A network failure here is not the reply's failure: the text is still
/// worth sending, just without the quote.
Future<int?> _notifiedMessageId(
  Ref ref, {
  required String accountId,
  required String roomToken,
  required int notificationId,
}) async {
  final account = await ref
      .read(accountRepositoryProvider)
      .getAccount(accountId);
  final appPassword = await ref
      .read(credentialVaultProvider)
      .readAppPassword(accountId);
  if (account == null || appPassword == null) {
    return null;
  }
  try {
    return await ref
        .read(nextcloudApiProvider)
        .getNotificationChatMessageId(
          server: ServerBase.parse(account.serverUrl),
          loginName: account.loginName,
          appPassword: appPassword,
          notificationId: notificationId,
          roomToken: roomToken,
        );
  } on NextcloudApiException {
    return null;
  }
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
          notificationId: action.notificationId,
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
  int? notificationId,
  int? messageId,
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
        notificationId: notificationId,
        messageId: messageId,
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
  // Every runner with a `com.nkshub.nextcloudtalk/deep_link` channel. Windows
  // was missing here while its runner already spoke the channel, so a link
  // handed over via WM_COPYDATA restored the window and went nowhere.
  if (!Platform.isAndroid &&
      !Platform.isIOS &&
      !Platform.isMacOS &&
      !Platform.isWindows) {
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
