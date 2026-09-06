part of 'app_providers.dart';

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
