part of 'app_providers.dart';

final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  return ChatRepository(ref.watch(appDatabaseProvider));
});

final recoverableTextDraftStoreProvider =
    ChangeNotifierProvider<RecoverableTextDraftStore>(
      (ref) => RecoverableTextDraftStore(ref.watch(appDatabaseProvider)),
    );

final roomRefusedDraftsProvider = StreamProvider.autoDispose
    .family<List<RefusedTextDraft>, ChatRoomProviderKey>(
      (ref, key) => ref
          .watch(recoverableTextDraftStoreProvider.notifier)
          .watch(key.accountId, key.roomToken, key.threadId),
    );

final accountRepositoryProvider = Provider<AccountRepository>((ref) {
  return AccountRepository(
    ref.watch(appDatabaseProvider),
    onAccountPurged: ref
        .watch(recoverableTextDraftStoreProvider.notifier)
        .forgetAccount,
  );
});

final attachmentRoomJobsProvider = StreamProvider.autoDispose
    .family<List<StoredAttachmentJob>, ChatRoomProviderKey>((ref, key) {
      return ref
          .watch(attachmentRepositoryProvider)
          .watchRoomJobs(
            accountId: key.accountId,
            roomToken: key.roomToken,
            threadId: key.threadId,
            inlineReplies: ref.watch(replyLayoutProvider) == ReplyLayout.inline,
          );
    });

/// The one keep-alive of the process, shared by everything that sends, so
/// an upload finishing does not release it under a message still on its way.
/// Android only: nothing else freezes the app seconds after it is left.
final transferKeepAliveProvider = Provider<AttachmentTransferKeepAlive?>((ref) {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    return null;
  }
  final keepAlive = AttachmentTransferKeepAlive();
  ref.onDispose(keepAlive.dispose);
  return keepAlive;
});

/// Asks the platform for one drain as soon as a network is there, if the
/// app is out of sight and text is still waiting to be sent.
///
/// Called when the app leaves the screen and when a send started just before
/// that gives up for now. A drain the platform starts never comes through
/// here, so a server that keeps failing cannot make this go round.
Future<void> requestWakeForUnsentText(Ref ref) async {
  final state = WidgetsBinding.instance.lifecycleState;
  if (state != ui.AppLifecycleState.paused &&
      state != ui.AppLifecycleState.hidden) {
    return;
  }
  try {
    final pending = await ref
        .read(chatRepositoryProvider)
        .roomsWithPendingTextSends();
    if (pending.isNotEmpty) {
      await ref.read(backgroundDrainScheduleProvider).requestOnce();
    }
  } on Object {
    // Best effort; the recurring wake still stands.
  }
}

final chatServiceProvider = Provider<ChatService>((ref) {
  final keepAlive = ref.watch(transferKeepAliveProvider)?.holder();
  final service = ChatService(
    accounts: ref.watch(accountRepositoryProvider),
    chat: ref.watch(chatRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    api: ref.watch(nextcloudApiProvider),
    reportSendActivity: (active) {
      keepAlive?.call(active);
      if (!active) {
        unawaited(requestWakeForUnsentText(ref));
      }
    },
  );
  ref.onDispose(() => unawaited(service.close()));
  return service;
});

/// Everything a wake-up owes the user: queued text in rooms nobody has open,
/// revocations owed to servers that were unreachable, and uploads ready to
/// continue after a restart or a failed attempt.
///
/// The platform can tear down the headless engine as soon as this returns.
Future<void> drainForBackground(ProviderContainer container) async {
  final retry = await container.read(chatServiceProvider).drainPendingSends();
  await container.read(appPasswordRevocationQueueProvider).drain();
  final attachments = await container.read(attachmentServiceProvider.future);
  try {
    await attachments.drainForBackground();
  } finally {
    await attachments.close();
  }
  _reportBackgroundTextResult(retry);
}

void _reportBackgroundTextResult(bool retry) {
  if (retry) {
    throw PlatformException(code: 'text_delivery_pending');
  }
}

Future<void> _recoverBrowserLoginsWhileVisible(
  AppPasswordRevocationQueue queue,
) async {
  bool visible() =>
      WidgetsBinding.instance.lifecycleState == ui.AppLifecycleState.resumed;
  if (!visible()) return;
  try {
    if (await queue.recoverBrowserLogins(canPoll: visible)) await queue.drain();
  } on Object {
    // Secure recovery state survives the current wake.
  }
}

/// Replays queued text sends for rooms that are not open, on start and on
/// every hint that the network is back. The room pane covers its own room.
///
/// Also answers the platform's background scheduler. A wake that finds this
/// process already alive is served by the app's own services rather than by a
/// second engine: two [ChatService] instances in one process each hold their
/// own outbox snapshot, and both would claim the same queued row and send the
/// message twice.
final outboxDrainProvider = Provider<void>((ref) {
  final chat = ref.watch(chatServiceProvider);
  Future<bool>? activeDrain;
  Future<bool> drainOnce() async {
    try {
      final revocations = ref.read(appPasswordRevocationQueueProvider);
      unawaited(_recoverBrowserLoginsWhileVisible(revocations));
      final retry = await chat.drainPendingSends();
      await revocations.drain();
      return retry;
    } on Object {
      return true;
    }
  }

  Future<bool> drain() => activeDrain ??= drainOnce().whenComplete(() {
    activeDrain = null;
  });

  final wakes = <StreamSubscription<void>>[
    for (final events in [
      ref.watch(connectivityWakeEventsProvider),
      ref.watch(appLifecycleResumeEventsProvider),
    ])
      events.listen((_) => unawaited(drain())),
  ];
  final readers = chat.readerWakeEvents.listen((_) => unawaited(drain()));
  final keepAlive = ref.watch(transferKeepAliveProvider);
  final waitingHold = keepAlive?.holder(waiting: true);
  final unsentHold = waitingHold == null
      ? null
      : UnsentTextHold(
          watchPending: ref
              .watch(chatRepositoryProvider)
              .watchHasPendingTextSends,
          hold: waitingHold,
          onWindowEnd: () {
            unawaited(requestWakeForUnsentText(ref));
            // Nothing sends it from here until a wake gets the network.
            keepAlive?.unsentNotice(true);
          },
        );
  final leaving = AppLifecycleListener(
    onPause: () {
      unawaited(requestWakeForUnsentText(ref));
      unsentHold?.paused();
    },
    onResume: () {
      unsentHold?.resumed();
      keepAlive?.unsentNotice(false);
    },
  );
  final channel = ref.watch(backgroundDrainChannelProvider);
  channel.setMethodCallHandler((call) async {
    if (call.method != 'runDrain') {
      throw MissingPluginException('${call.method} is not handled here');
    }
    final retry = await drain();
    if ((await ref.read(chatRepositoryProvider).roomsWithPendingTextSends())
        .isEmpty) {
      keepAlive?.unsentNotice(false);
    }
    // The attachment service keeps its own wake sources; a scheduled wake
    // reaches it here because the platform hint is not one of them.
    await (await ref.read(attachmentServiceProvider.future)).resumeRetries();
    _reportBackgroundTextResult(retry);
    return null;
  });
  ref.onDispose(() {
    channel.setMethodCallHandler(null);
    leaving.dispose();
    unsentHold?.dispose();
    unawaited(readers.cancel());
    for (final wake in wakes) {
      unawaited(wake.cancel());
    }
  });
  unawaited(drain());
  unawaited(ref.watch(backgroundDrainScheduleProvider).ensure());
});

/// Seam for tests, which must not talk to a real platform channel.
final backgroundDrainChannelProvider = Provider<MethodChannel>(
  (ref) => backgroundDrainChannel,
);

final backgroundDrainScheduleProvider = Provider<BackgroundDrainSchedule>((
  ref,
) {
  return BackgroundDrainSchedule(
    channel: ref.watch(backgroundDrainChannelProvider),
  );
});

final threadManagementServiceProvider = Provider<ThreadManagementService>((
  ref,
) {
  return ThreadManagementService(
    accounts: ref.watch(accountRepositoryProvider),
    chat: ref.watch(chatRepositoryProvider),
    threads: ref.watch(threadRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    api: ref.watch(nextcloudApiProvider),
  );
});

final attachmentSourceProvider = FutureProvider<DurableAttachmentSourceStore>((
  ref,
) {
  return DurableAttachmentSourceStore.openApplicationSupport();
});

final attachmentUploadPolicyProvider = Provider<AttachmentUploadPolicy>((ref) {
  return AttachmentUploadPolicy(
    normalUploadMaximumBytes: 10 * 1024 * 1024,
    chunkSizeBytes: 5 * 1024 * 1024,
  );
});

final chatMessageActionsServiceProvider = Provider<ChatMessageActionsService>((
  ref,
) {
  return ChatMessageActionsService(
    accounts: ref.watch(accountRepositoryProvider),
    chat: ref.watch(chatRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    api: ref.watch(nextcloudApiProvider),
  );
});

final messageTranslationServiceProvider = Provider<MessageTranslationService>((
  ref,
) {
  return HttpMessageTranslationService(
    accounts: ref.watch(accountRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    api: ref.watch(nextcloudApiProvider),
  );
});

final currentLocationSourceProvider = Provider<CurrentLocationSource>((ref) {
  return GeolocatorCurrentLocationSource();
});

final placeSearchSourceProvider = Provider<PlaceSearchSource>((ref) {
  return NominatimPlaceSearch();
});

final appSettingsOpenerProvider = Provider<AppSettingsOpener>((ref) {
  return const GeolocatorAppSettingsOpener();
});

final locationShareServiceProvider = Provider<LocationShareSender>((ref) {
  return LocationShareService(
    accounts: ref.watch(accountRepositoryProvider),
    chat: ref.watch(chatRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    api: ref.watch(nextcloudApiProvider),
  );
});

final pollServiceProvider = Provider<PollSender>((ref) {
  return PollService(
    accounts: ref.watch(accountRepositoryProvider),
    chat: ref.watch(chatRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    api: ref.watch(nextcloudApiProvider),
  );
});

final pollAvailabilityProvider = FutureProvider.autoDispose
    .family<bool, PollRoomKey>((ref, key) {
      return ref.watch(pollServiceProvider).isAvailable(key);
    });

final chatMessageActionsProfileProvider = FutureProvider.autoDispose
    .family<RichChatCapabilityProfile, ChatRoomProviderKey>((ref, key) async {
      return ref
          .watch(chatMessageActionsServiceProvider)
          .resolveProfile(accountId: key.accountId, roomToken: key.roomToken);
    });

final chatAttachmentContextResolverProvider =
    Provider<ChatAttachmentContextResolver>((ref) {
      return ChatAttachmentContextResolver(
        accounts: ref.watch(accountRepositoryProvider),
        chat: ref.watch(chatRepositoryProvider),
        credentials: ref.watch(credentialVaultProvider),
        api: ref.watch(nextcloudApiProvider),
        uploadPolicy: ref.watch(attachmentUploadPolicyProvider),
      );
    });

typedef ChatAttachmentDependencies = ({
  DurableAttachmentSourceStore source,
  AttachmentService service,
  ChatAttachmentContextResolver resolver,
  AttachmentCapabilityProfile profile,
});

final _chatAttachmentPreparationProvider = FutureProvider.autoDispose
    .family<ChatAttachmentDependencies, ChatRoomProviderKey>((ref, key) async {
      final source = ref.watch(attachmentSourceProvider.future);
      final service = ref.watch(attachmentServiceProvider.future);
      final resolver = ref.watch(chatAttachmentContextResolverProvider);
      final preparedSource = await source;
      final readyService = await service;
      final profile = await resolver.resolveProfile(
        accountId: AccountId.parse(key.accountId),
        roomToken: ConversationToken.parse(key.roomToken, path: r'$.roomToken'),
      );
      return (
        source: preparedSource,
        service: readyService,
        resolver: resolver,
        profile: profile,
      );
    });

final chatAttachmentDependenciesProvider = FutureProvider.autoDispose
    .family<ChatAttachmentDependencies, ChatRoomProviderKey>((ref, key) {
      final preparation = _chatAttachmentPreparationProvider(key);
      // Keep watching the result after the UI's deadline. A second engine can
      // still release the runtime without the user having to reopen the room.
      return ref
          .watch(preparation)
          .when(
            skipLoadingOnRefresh: false,
            data: (ready) => ready,
            error: (error, stack) {
              if (error is! ChatAttachmentContextException ||
                  error.code ==
                      ChatAttachmentContextError.capabilitiesUnavailable ||
                  error.code == ChatAttachmentContextError.contextChanged) {
                _scheduleAttachmentCheckRetry(ref, key);
              }
              Error.throwWithStackTrace(error, stack);
            },
            loading: () {
              final pending = ref.watch(preparation.future);
              const limit = Duration(seconds: 30);
              final expired = Completer<ChatAttachmentDependencies>();
              final timer = Timer(limit, () {
                expired.completeError(
                  TimeoutException('Preparing chat attachments', limit),
                );
              });
              ref.onDispose(timer.cancel);
              return Future.any([
                pending,
                expired.future,
              ]).whenComplete(timer.cancel);
            },
          );
    });

void _scheduleAttachmentCheckRetry(Ref ref, ChatRoomProviderKey key) {
  var waiting = true;
  void retry() {
    if (!waiting) return;
    waiting = false;
    if (ref
        .read(_chatAttachmentPreparationProvider(key))
        .unwrapPrevious()
        .hasError) {
      _retryAttachmentPreparation(key, ref.read, ref.invalidate);
    }
  }

  final timer = Timer(const Duration(seconds: 10), retry);
  final subscriptions = [
    for (final wakes in [
      connectivityWakeEventsProvider,
      appLifecycleResumeEventsProvider,
    ])
      ref
          .watch(wakes)
          .listen((_) => retry(), onError: (Object _, StackTrace _) {}),
  ];
  ref.onDispose(() {
    waiting = false;
    timer.cancel();
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel());
    }
  });
}

void _retryAttachmentPreparation(
  ChatRoomProviderKey key,
  T Function<T>(ProviderListenable<T>) read,
  void Function(ProviderOrFamily) invalidate,
) {
  final preparation = _chatAttachmentPreparationProvider(key);
  if (read(preparation).isLoading) return;
  final source = read(attachmentSourceProvider).unwrapPrevious();
  final service = read(attachmentServiceProvider).unwrapPrevious();
  if (source.hasError) {
    invalidate(attachmentSourceProvider);
  } else if (service.hasError) {
    invalidate(attachmentServiceProvider);
  }
  invalidate(preparation);
}

void retryChatAttachmentDependencies(WidgetRef ref, ChatRoomProviderKey key) {
  _retryAttachmentPreparation(key, ref.read, ref.invalidate);
  ref.invalidate(chatAttachmentDependenciesProvider(key));
}

/// Bytes of each upload request in flight, by job id, for the progress bar.
final attachmentInFlightBytesProvider =
    Provider<ValueNotifier<Map<String, int>>>(
      (ref) => ValueNotifier<Map<String, int>>(const <String, int>{}),
    );

final attachmentServiceProvider = FutureProvider<AttachmentService>((
  ref,
) async {
  var disposed = false;
  ref.onDispose(() => disposed = true);
  final source = await ref.watch(attachmentSourceProvider.future);
  if (disposed) throw AttachmentServiceClosed();
  final chat = ref.watch(chatServiceProvider);
  final keepAlive = ref.watch(transferKeepAliveProvider);
  final owner = AttachmentRuntimeOwner(reserveAttachmentRuntime());
  Future<int>? sourceSweep;
  ref.onDispose(() => unawaited(owner.close(maintenance: sourceSweep)));
  try {
    final service = await owner.open(
      () => AttachmentService(
        repository: ref.watch(attachmentRepositoryProvider),
        credentials: ref.watch(credentialVaultProvider),
        releaseSource: (attachment) => source.discard(attachment.handle),
        transport: HttpAttachmentTransport(
          client: ref.watch(certificateTrustGateProvider).createClient(),
          sourceProvider: source,
        ),
        catchUpConfirmation:
            ({required accountId, required roomToken, required threadId}) =>
                chat.catchUpRoom(
                  accountId: accountId.value,
                  roomToken: roomToken.value,
                  threadId: threadId,
                ),
        reportTransferActivity: keepAlive?.holder(),
        inFlightBytes: ref.watch(attachmentInFlightBytesProvider),
      ),
    );
    if (disposed) throw AttachmentServiceClosed();
    // A network hint or a resumed app is worth one more attempt for uploads
    // whose automatic retries ran out while the device was offline.
    final wakes = <StreamSubscription<void>>[
      for (final events in [
        ref.watch(connectivityWakeEventsProvider),
        ref.watch(appLifecycleResumeEventsProvider),
      ])
        events.listen((_) => unawaited(service.resumeRetries())),
    ];
    final readers = chat.readerWakeEvents.listen(
      (room) => unawaited(
        service.resumeDeferredConfirmations(
          accountId: room.accountId,
          roomToken: room.roomToken,
        ),
      ),
    );
    ref.onDispose(() {
      unawaited(readers.cancel());
      for (final wake in wakes) {
        unawaited(wake.cancel());
      }
    });
    await service.ready;
    if (disposed) throw AttachmentServiceClosed();
    // Jobs are loaded, so anything the store holds without a job is an orphan:
    // a pick the user never sent before the process died, or a job removed
    // without its source. Best effort; the next start tries again.
    sourceSweep = ref
        .read(attachmentRepositoryProvider)
        .referencedSourceHandles()
        .then(
          (referenced) => source.discardUnreferenced(referenced: referenced),
        )
        .catchError((Object _) => 0);
    unawaited(sourceSweep);
    return service;
  } on Object catch (error, stack) {
    try {
      await owner.close();
    } finally {
      Error.throwWithStackTrace(error, stack);
    }
  }
});
