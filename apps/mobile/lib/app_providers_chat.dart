part of 'app_providers.dart';

final chatServiceProvider = Provider<ChatService>((ref) {
  final service = ChatService(
    accounts: ref.watch(accountRepositoryProvider),
    chat: ref.watch(chatRepositoryProvider),
    credentials: ref.watch(credentialVaultProvider),
    api: ref.watch(nextcloudApiProvider),
  );
  ref.onDispose(() => unawaited(service.close()));
  return service;
});

/// Everything a wake-up owes the user: queued text in rooms nobody has open,
/// revocations owed to servers that were unreachable, and uploads whose
/// automatic retries ran out while the device had no network.
///
/// Shared by the foreground hints and by the headless isolate the platform's
/// background scheduler starts, so both do exactly the same work.
Future<void> drainForBackground(ProviderContainer container) async {
  await container.read(chatServiceProvider).drainPendingSends();
  await container.read(appPasswordRevocationQueueProvider).drain();
  await (await container.read(
    attachmentServiceProvider.future,
  )).resumeRetries();
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
  var running = false;
  Future<void> drain() async {
    if (running) {
      return;
    }
    running = true;
    try {
      await chat.drainPendingSends();
      await ref.read(appPasswordRevocationQueueProvider).drain();
    } on Object {
      // A drain is best effort; the outbox keeps its rows for the next one.
    } finally {
      running = false;
    }
  }

  final wakes = <StreamSubscription<void>>[
    for (final events in [
      ref.watch(connectivityWakeEventsProvider),
      ref.watch(appLifecycleResumeEventsProvider),
    ])
      events.listen((_) => unawaited(drain())),
  ];
  final readers = chat.readerWakeEvents.listen((_) => unawaited(drain()));
  final channel = ref.watch(backgroundDrainChannelProvider);
  channel.setMethodCallHandler((call) async {
    if (call.method != 'runDrain') {
      throw MissingPluginException('${call.method} is not handled here');
    }
    await drain();
    // The attachment service keeps its own wake sources; a scheduled wake
    // reaches it here because the platform hint is not one of them.
    await (await ref.read(attachmentServiceProvider.future)).resumeRetries();
    return null;
  });
  ref.onDispose(() {
    channel.setMethodCallHandler(null);
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
    normalUploadMaximumBytes: 1024 * 1024,
    chunkSizeBytes: 1024000,
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

final attachmentServiceProvider = FutureProvider<AttachmentService>((
  ref,
) async {
  final source = await ref.watch(attachmentSourceProvider.future);
  final chat = ref.watch(chatServiceProvider);
  final service = AttachmentService(
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
  );
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
    unawaited(service.close());
  });
  await service.ready;
  // Jobs are loaded, so anything the store holds without a job is an orphan:
  // a pick the user never sent before the process died, or a job removed
  // without its source. Best effort; the next start tries again.
  unawaited(
    ref
        .read(attachmentRepositoryProvider)
        .referencedSourceHandles()
        .then(
          (referenced) => source.discardUnreferenced(referenced: referenced),
        )
        .catchError((Object _) => 0),
  );
  return service;
});
