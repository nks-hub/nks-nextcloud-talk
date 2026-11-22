part of 'app_providers.dart';

final chatAttachmentCacheMaintenanceFactoryProvider =
    Provider<ChatAttachmentCacheMaintenanceFactory>((ref) {
      return ChatAttachmentCacheHousekeeper.new;
    });

/// Starts attachment-cache cleanup once for the process and on every resume.
final chatAttachmentCacheMaintenanceProvider = Provider<void>((ref) {
  final maintenance = ref.watch(
    chatAttachmentCacheMaintenanceFactoryProvider,
  )();
  final resumes = ref
      .watch(appLifecycleResumeEventsProvider)
      .listen((_) => unawaited(maintenance.run()));
  ref.onDispose(() {
    unawaited(resumes.cancel());
    maintenance.dispose();
  });
  unawaited(maintenance.run());
});

typedef ChatVoiceProviderKey = ({
  StoredAccount account,
  Uri uri,
  int messageId,
});

typedef ChatVoiceTranscriberFactory = VoiceTranscriber Function();

/// Re-reads the message behind a download that failed and answers with the
/// attachment's corrected address, or `null` when nothing changed.
///
/// A provider rather than a bare call so a widget test can render an
/// attachment bubble without the repair reaching the database behind
/// `chatServiceProvider` — which never settles under `pumpAndSettle`.
typedef AttachmentUriRepair =
    Future<Uri?> Function({
      required StoredAccount account,
      required String roomToken,
      required int messageId,
      required int index,
      required Uri failedUri,
    });

final attachmentUriRepairProvider = Provider<AttachmentUriRepair>((ref) {
  return ({
    required StoredAccount account,
    required String roomToken,
    required int messageId,
    required int index,
    required Uri failedUri,
  }) => repairAttachmentUri(
    ref,
    account: account,
    roomToken: roomToken,
    messageId: messageId,
    index: index,
    failedUri: failedUri,
  );
});

final chatVoiceTranscriberFactoryProvider =
    Provider<ChatVoiceTranscriberFactory?>((ref) {
      if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
        return null;
      }
      return MethodChannelVoiceTranscriber.new;
    });

/// Player a chat bubble uses for a voice message. Injected so widget tests can
/// drive playback without a platform audio session.
final chatVoicePlaybackBackendProvider =
    Provider<VoicePlaybackBackend Function()>(
      (ref) => AudioplayersVoicePlaybackBackend.new,
    );

/// Where downloaded voice messages are materialised. Shared with account
/// removal so both sides agree on the directory that has to be cleaned.
final chatVoiceCacheDirectoryProvider = Provider<Future<Directory> Function()>((
  ref,
) {
  return () async => Directory(
    '${(await getApplicationCacheDirectory()).path}'
    '${Platform.pathSeparator}voice',
  );
});

/// A voice message is fetched once per room visit and materialised in the
/// app cache directory so a platform player can open it.
final chatVoiceFileProvider = FutureProvider.autoDispose
    .family<ChatVoiceFile, ChatVoiceProviderKey>((ref, key) async {
      final directory = await ref.watch(chatVoiceCacheDirectoryProvider)();
      final file = await ref
          .watch(chatMediaRepositoryProvider)
          .loadVoiceFile(
            account: key.account,
            uri: key.uri,
            directory: directory,
            cacheKey: chatVoiceCacheKey(
              accountId: key.account.id,
              messageId: key.messageId,
            ),
          );
      // The file just written is the newest, so the bound never drops the one
      // about to play. Nothing else evicts this directory outside account
      // removal, so without this it grows for as long as the account exists.
      await pruneAccountVoiceFiles(
        directory: directory,
        accountId: key.account.id,
      );
      return file;
    });

final chatMediaCacheProvider = Provider<ChatMediaCache>((ref) {
  return ChatMediaCache();
});

/// Previews are chat content, so they stay in the private app cache directory
/// that `allowBackup="false"` and the platform sandbox already cover.
final chatMediaDiskCacheProvider = Provider<ChatMediaDiskCache>((ref) {
  return ChatMediaDiskCache(
    rootDirectory: () async => Directory(
      '${(await getApplicationCacheDirectory()).path}'
      '${Platform.pathSeparator}previews',
    ),
  );
});

final chatPreviewDownscaleProvider =
    Provider<Future<ChatMediaImage?> Function(Uint8List)>((ref) {
      return _downscaledPreview;
    });

final chatMediaProvider = FutureProvider.autoDispose
    .family<ChatMediaImage?, ChatMediaProviderKey>((ref, key) async {
      final accountId = key.account.id;
      final cacheKey = ChatMediaCache.keyOf(accountId: accountId, uri: key.uri);
      final cache = ref.watch(chatMediaCacheProvider);
      final disk = ref.watch(chatMediaDiskCacheProvider);
      final repository = ref.watch(chatMediaRepositoryProvider);
      final downscale = ref.watch(chatPreviewDownscaleProvider);
      return cache.withEntry(cacheKey, () async {
        if (!repository.isAccountActive(accountId)) return null;
        final cached = cache.read(cacheKey);
        if (cached != null) {
          return cached;
        }
        final persisted = await disk.read(accountId: accountId, uri: key.uri);
        if (!repository.isAccountActive(accountId)) return null;
        if (persisted != null) {
          cache.write(cacheKey, persisted);
          return persisted;
        }
        final loaded =
            await repository.loadPreview(account: key.account, uri: key.uri) ??
            await _loadOriginalAsPreview(repository, key, downscale);
        // Conversion can finish after removal suspended this repository.
        if (loaded == null || !repository.isAccountActive(accountId)) {
          return null;
        }
        cache.write(cacheKey, loaded);
        await disk.write(accountId: accountId, uri: key.uri, image: loaded);
        return repository.isAccountActive(accountId) ? loaded : null;
      });
    });

/// Largest original read to stand in for a missing preview. A Retina
/// screenshot is 10-15 MB, and a server that loses its own preview of one
/// (Nextcloud 34.0.3 deletes it when two requests generate it at once) left
/// such pictures with no image at all.
const int _maximumOriginalAsPreviewBytes = 32 * 1024 * 1024;

/// An original above this many pixels is not decoded on the device at all.
const int _maximumOriginalAsPreviewPixels = 48 * 1000 * 1000;

/// The box a downscaled original is fitted into, matching the preview size
/// the bubble asks the server for.
const int _originalAsPreviewBox = 1024;

/// The attachment itself, read as the picture, for a file the server has no
/// preview of. `null` means there is no picture to show - the original is not
/// an image or is too large to stand in for one - and the bubble offers the
/// file instead. Any other failure is reported, so the bubble can retry it.
///
/// An original over the preview budget is shrunk to the preview box before it
/// is cached, so one large picture does not fill the memory and disk caches.
Future<ChatMediaImage?> _loadOriginalAsPreview(
  ChatMediaRepository repository,
  ChatMediaProviderKey key,
  Future<ChatMediaImage?> Function(Uint8List) downscale,
) async {
  final uri = key.originalUri;
  final contentType = key.originalContentType;
  if (uri == null || contentType == null || !contentType.startsWith('image/')) {
    return null;
  }
  try {
    final file = await repository.loadOriginalFile(
      account: key.account,
      uri: uri,
      expectedContentType: contentType,
      maximumBytes: _maximumOriginalAsPreviewBytes,
    );
    if (file.body.lengthInBytes <=
        ChatMediaRepository.maximumPreviewFallbackBytes) {
      return ChatMediaImage.takeOwnership(
        body: file.body,
        contentType: file.contentType,
      );
    }
    return await downscale(file.body);
  } on ChatMediaRepositoryException catch (failure) {
    if (failure.code == ChatMediaRepositoryError.responseTooLarge) return null;
    rethrow;
  }
}

/// Re-encodes [original] as a PNG no larger than the preview box, or `null`
/// when it cannot be decoded or has too many pixels to decode safely.
Future<ChatMediaImage?> _downscaledPreview(Uint8List original) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(original);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final width = descriptor.width;
    final height = descriptor.height;
    if (width < 1 ||
        height < 1 ||
        width * height > _maximumOriginalAsPreviewPixels) {
      return null;
    }
    final landscape = width >= height;
    final longest = landscape ? width : height;
    final fitted = longest > _originalAsPreviewBox
        ? _originalAsPreviewBox
        : longest;
    codec = await descriptor.instantiateCodec(
      targetWidth: landscape ? fitted : null,
      targetHeight: landscape ? null : fitted,
    );
    image = (await codec.getNextFrame()).image;
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) return null;
    return ChatMediaImage.takeOwnership(
      body: png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      contentType: 'image/png',
    );
  } on Object {
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}
