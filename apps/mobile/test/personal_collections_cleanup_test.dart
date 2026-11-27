import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/chat_media_cache.dart';
import 'package:nextcloudtalk/features/chat/composer/draft_handoff.dart';
import 'package:nextcloudtalk/features/chat/composer/emoji_usage_store.dart';
import 'package:nextcloudtalk/features/chat/composer/gif_favorites.dart';
import 'package:nextcloudtalk/features/chat/composer/giphy.dart';
import 'package:nextcloudtalk/features/chat/composer/message_collections.dart';
import 'package:nextcloudtalk/features/chat/composer/reply_templates.dart';
import 'package:nextcloudtalk/features/settings/account_removal_service.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:nextcloudtalk/platform/media/durable_attachment_source_store.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'test_support.dart';

void main() {
  test(
    'account removal retries a locked collection and erases only its owner',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'owntalk-collections-cleanup-',
      );
      addTearDown(() => root.delete(recursive: true));
      final db = openTestDatabase();
      addTearDown(db.close);
      final accounts = AccountRepository(db);
      final owner = AccountId.parse('owner');
      final other = AccountId.parse('other');
      final gifs = GifFavoritesStore(directory: root);
      final templates = ReplyTemplateStore(directory: root);
      final collections = MessageCollectionStore(directory: root);
      DraftHandoffStore openDrafts() => DraftHandoffStore(
        ({
          required accountId,
          required feature,
          required path,
          method = 'GET',
          query,
          values,
        }) => fail('Local account removal must not make a network request'),
        directory: root,
      );
      final drafts = openDrafts();
      addTearDown(drafts.dispose);
      final providers = ProviderContainer(
        overrides: [
          gifFavoritesStoreProvider.overrideWithValue(gifs),
          replyTemplateStoreProvider.overrideWithValue(templates),
          messageCollectionStoreProvider.overrideWithValue(collections),
          draftHandoffProvider.overrideWithValue(drafts),
        ],
      );
      addTearDown(providers.dispose);
      final purge = providers.read(personalCollectionsCleanupProvider);
      var blocked = true;
      final api = HttpNextcloudApi();
      addTearDown(api.close);
      final service = AccountRemovalService(
        accounts: accounts,
        credentials: MemoryCredentialVault(),
        api: api,
        mediaCache: ChatMediaCache(),
        mediaDiskCache: ChatMediaDiskCache(rootDirectory: () async => root),
        emojiUsage: FileEmojiUsageStore(directory: root),
        clearChatBackgrounds: (_) async {},
        voiceDirectory: () async => root,
        chatAttachmentDirectory: () async => root,
        attachmentSources: () async => DurableAttachmentSourceStore(root: root),
        clearPersonalCollections: (id) async {
          if (blocked) throw const FileSystemException('locked collection');
          await purge(id);
        },
      );
      for (final account in [owner, other]) {
        await accounts.upsertAccount(
          accountId: account.value,
          serverUrl: 'https://cloud.example.invalid',
          loginName: account.value,
          serverProductName: 'Nextcloud',
          serverThemeColor: null,
          createdAt: DateTime.utc(2026),
        );
        await templates.save(account, name: 'Reply', text: 'Hello');
        await collections.create(account, 'Later');
        await drafts.setEnabled(account.value, true);
        await drafts.stage(
          (accountId: account.value, roomToken: 'room123', threadId: null),
          'Draft for ${account.value}',
          null,
        );
        await gifs.setFavorite(
          account,
          GiphyEntry(
            thumbnailUrl: Uri.parse(
              'https://cloud.example.invalid/apps/integration_giphy/gif/otter',
            ),
            resourceUrl: Uri.parse('https://giphy.com/gifs/otter'),
            title: 'Otter',
            subline: '',
          ),
          saved: true,
        );
      }
      await expectLater(
        service.removeAccount(owner.value),
        throwsA(isA<FileSystemException>()),
      );
      expect(await accounts.getAccount(owner.value), isNotNull);
      final ownerRows = await drafts.read(owner);
      expect(ownerRows.map((row) => row['text']), contains('Draft for owner'));
      blocked = false;
      await service.removeAccount(owner.value);
      expect(await accounts.getAccount(owner.value), isNull);
      expect(await GifFavoritesStore(directory: root).read(owner), isEmpty);
      expect(await ReplyTemplateStore(directory: root).read(owner), isEmpty);
      expect(
        await MessageCollectionStore(directory: root).read(owner),
        isEmpty,
      );
      expect(await gifs.read(other), hasLength(1));
      expect(await templates.read(other), hasLength(1));
      expect(await collections.read(other), hasLength(1));
      final reopened = openDrafts();
      addTearDown(reopened.dispose);
      expect(await reopened.read(owner), isEmpty);
      final otherRows = await reopened.read(other);
      expect(otherRows.map((row) => row['text']), contains('Draft for other'));
    },
  );
}
