import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/chat/chat_background_store.dart';
import 'package:nextcloudtalk/features/chat/chat_background_surface.dart';
import 'package:nextcloudtalk/features/owntalk_extensions/owntalk_background_photo.dart';
import 'package:nextcloudtalk/features/owntalk_extensions/owntalk_extensions_service.dart';
import 'package:nextcloudtalk/features/owntalk_extensions/owntalk_image_cache.dart';
import 'package:nextcloudtalk/features/owntalk_extensions/owntalk_room_extras.dart';
import 'package:nextcloudtalk/features/owntalk_extensions/owntalk_settings_store.dart';
import 'package:nextcloudtalk/network/nextcloud_api.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'owntalk_extensions_test_support.dart';
import 'test_support.dart';

const _account = 'account-a';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late FakeOwnTalkServer server;
  late Directory directory;

  setUp(() async {
    database = openTestDatabase();
    await AccountRepository(database).upsertAccount(
      accountId: _account,
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      talkFeatures: const {},
      createdAt: DateTime.utc(2026, 1, 1),
    );
    server = FakeOwnTalkServer();
    directory = await Directory.systemTemp.createTemp('owntalk-images-');
  });

  tearDown(() async {
    await database.close();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  OwnTalkExtensionsService service() => OwnTalkExtensionsService(
    accounts: AccountRepository(database),
    credentials: MemoryCredentialVault()..values[_account] = 'fixture-password',
    api: HttpNextcloudApi(client: server.client),
  );

  group('image cache', () {
    test('keeps bytes per account and hash', () async {
      final cache = OwnTalkImageCache.forTesting(directory);
      final bytes = ownTalkTestJpeg(1);
      final sha = ownTalkTestSha(bytes);

      expect(await cache.read(_account, sha), isNull);
      await cache.write(_account, sha, bytes);
      expect(await cache.read(_account, sha), orderedEquals(bytes));
      expect(await cache.read('account-b', sha), isNull);
      expect(
        await cache.read(_account, ownTalkTestSha(ownTalkTestJpeg(2))),
        isNull,
      );
    });

    test('refuses a name that is not a lower-case SHA-256', () async {
      final cache = OwnTalkImageCache.forTesting(directory);
      for (final bad in ['../../x', 'abc', 'A' * 64, '']) {
        expect(() => cache.read(_account, bad), throwsArgumentError);
        expect(
          () => cache.write(_account, bad, ownTalkTestJpeg()),
          throwsArgumentError,
        );
      }
    });

    test('removing an account leaves the others alone', () async {
      final cache = OwnTalkImageCache.forTesting(directory);
      final bytes = ownTalkTestJpeg();
      final sha = ownTalkTestSha(bytes);
      await cache.write(_account, sha, bytes);
      await cache.write('account-b', sha, bytes);

      await cache.removeAccount(_account);
      expect(await cache.read(_account, sha), isNull);
      expect(await cache.read('account-b', sha), isNotNull);
      // Nothing to remove is fine too.
      await cache.removeAccount('account-c');
    });

    test('keeps only the newest photos of an account', () async {
      final cache = OwnTalkImageCache.forTesting(directory);
      final shas = <String>[];
      for (var index = 0; index < 24; index++) {
        final bytes = ownTalkTestJpeg(index);
        shas.add(ownTalkTestSha(bytes));
        await cache.write(_account, shas.last, bytes);
      }
      // Make the age explicit instead of relying on the clock's resolution.
      final files = directory.listSync().whereType<File>().toList();
      for (final file in files) {
        final sha = file.uri.pathSegments.last.split('-').last.split('.').first;
        file.setLastModifiedSync(
          DateTime(2026, 1, 1).add(Duration(hours: shas.indexOf(sha))),
        );
      }
      final extra = ownTalkTestJpeg(99);
      await cache.write(_account, ownTalkTestSha(extra), extra);

      expect(await cache.read(_account, shas.first), isNull);
      expect(await cache.read(_account, shas[1]), isNotNull);
      expect(await cache.read(_account, ownTalkTestSha(extra)), isNotNull);
    });
  });

  group('image loader', () {
    final jpeg = ownTalkTestJpeg();
    final sha = ownTalkTestSha(jpeg);

    OwnTalkImageLoader loader(OwnTalkImageCache? cache) =>
        OwnTalkImageLoader(service: service(), cache: cache);

    Future<Uint8List?> load(OwnTalkImageLoader loader) => loader.load(
      accountId: _account,
      roomToken: ownTalkTestToken,
      sha256: sha,
    );

    void publish() {
      server
        ..images[sha] = jpeg
        ..setExternally({'chat.backgroundImage': sha});
    }

    test('fetches a photo it does not hold and caches it', () async {
      publish();
      final cache = OwnTalkImageCache.forTesting(directory);
      expect(await load(loader(cache)), orderedEquals(jpeg));
      expect(server.downloads, hasLength(1));
      expect(await cache.read(_account, sha), orderedEquals(jpeg));
    });

    test('a cached photo is never fetched again', () async {
      publish();
      final cache = OwnTalkImageCache.forTesting(directory);
      await load(loader(cache));
      expect(server.downloads, hasLength(1));

      for (var index = 0; index < 3; index++) {
        expect(await load(loader(cache)), orderedEquals(jpeg));
      }
      expect(server.downloads, hasLength(1));
      // Not even the capabilities are read for a hit.
      expect(
        server.requests.where((r) => r.url.path.contains('capabilities')),
        hasLength(1),
      );
    });

    test('without a cache every load goes to the server', () async {
      publish();
      final plain = loader(null);
      await load(plain);
      await load(plain);
      expect(server.downloads, hasLength(2));
    });

    test('a broken disk does not lose the photo', () async {
      publish();
      final blocked = File('${directory.path}${Platform.pathSeparator}blocked')
        ..writeAsStringSync('not a directory');
      final cache = OwnTalkImageCache.forTesting(Directory(blocked.path));
      expect(await load(loader(cache)), orderedEquals(jpeg));
    });

    test(
      'bytes that do not hash to the name are refused and not kept',
      () async {
        // The server answers another picture for this hash.
        server
          ..images[sha] = ownTalkTestJpeg(77)
          ..setExternally({'chat.backgroundImage': sha});
        final cache = OwnTalkImageCache.forTesting(directory);
        expect(await load(loader(cache)), isNull);
        expect(await cache.read(_account, sha), isNull);
      },
    );

    test(
      'a hash that is not the current image is gone, not an error',
      () async {
        final cache = OwnTalkImageCache.forTesting(directory);
        expect(await load(loader(cache)), isNull);
        expect(server.downloads, hasLength(1));
      },
    );

    test('a failure that may pass is reported, not swallowed', () async {
      publish();
      for (final entry in {
        503: OwnTalkExtensionsError.unavailable,
        429: OwnTalkExtensionsError.rateLimited,
        401: OwnTalkExtensionsError.reauthenticationRequired,
      }.entries) {
        server.failDownloadWith = entry.key;
        await expectLater(
          load(loader(null)),
          throwsA(
            isA<OwnTalkExtensionsException>().having(
              (error) => error.code,
              'code',
              entry.value,
            ),
          ),
          reason: '${entry.key}',
        );
      }
    });

    test('an answer that is not a JPEG is an invalid response', () async {
      publish();
      server.images[sha] = Uint8List.fromList(List.filled(16, 7));
      await expectLater(
        load(loader(null)),
        throwsA(
          isA<OwnTalkExtensionsException>().having(
            (error) => error.code,
            'code',
            OwnTalkExtensionsError.invalidResponse,
          ),
        ),
      );
    });
  });

  group('image upload through the service', () {
    final jpeg = ownTalkTestJpeg(5);

    Future<OwnTalkSettingsUpdateResult> upload({
      Uint8List? bytes,
      String contentType = 'image/jpeg',
      int base = 0,
    }) => service().uploadImage(
      accountId: _account,
      roomToken: ownTalkTestToken,
      bytes: bytes ?? jpeg,
      contentType: contentType,
      baseRevision: base,
    );

    test(
      'is a PUT of the raw bytes with type, If-Match and credentials',
      () async {
        final result = await upload();
        final request = server.uploads.single;
        expect(request.method, 'PUT');
        expect(
          request.url.path,
          endsWith(
            '/ocs/v2.php/apps/owntalk_extensions/api/v1/room/'
            '$ownTalkTestToken/settings/image',
          ),
        );
        expect(request.headers['Content-Type'], 'image/jpeg');
        expect(request.headers['If-Match'], '"r0"');
        expect(request.headers['OCS-APIRequest'], 'true');
        expect(request.headers['Authorization'], startsWith('Basic '));
        expect(request.bodyBytes, orderedEquals(jpeg));

        final saved = result as OwnTalkSettingsSaved;
        expect(
          saved.document[OwnTalkSettingField.chatBackgroundImage],
          ownTalkTestSha(jpeg),
        );
        expect(saved.document.revision, 1);
        expect(saved.etag, '"r1-e1"');
      },
    );

    test('sends the content type of a PNG or WebP as it is', () async {
      for (final type in ['image/png', 'image/webp']) {
        await upload(contentType: type);
        expect(server.uploads.last.headers['Content-Type'], type);
      }
    });

    test('the If-Match revision is the one the edit started from', () async {
      server.setExternally({'bubble.ownColor': '#101010'});
      await upload(base: 1);
      expect(server.uploads.single.headers['If-Match'], '"r1"');
    });

    test(
      'a photo changed meanwhile is a conflict with the current document',
      () async {
        server.beforePatch = () => server.setExternally({
          'chat.backgroundImage': ownTalkTestSha(ownTalkTestJpeg(9)),
        });
        final result = await upload();
        final conflict = result as OwnTalkSettingsConflict;
        expect(conflict.conflictingFields, [
          OwnTalkSettingField.chatBackgroundImage,
        ]);
        expect(conflict.current.revision, 1);
      },
    );

    test('maps the server refusals', () async {
      const expected = {
        400: OwnTalkExtensionsFailureKind.rejected,
        403: OwnTalkExtensionsFailureKind.forbidden,
        404: OwnTalkExtensionsFailureKind.notFound,
        413: OwnTalkExtensionsFailureKind.payloadTooLarge,
        415: OwnTalkExtensionsFailureKind.unsupportedMediaType,
        428: OwnTalkExtensionsFailureKind.preconditionRequired,
        429: OwnTalkExtensionsFailureKind.rateLimited,
        503: OwnTalkExtensionsFailureKind.unavailable,
        507: OwnTalkExtensionsFailureKind.quotaExceeded,
      };
      for (final entry in expected.entries) {
        server.failUploadWith = entry.key;
        final result = await upload();
        expect(
          (result as OwnTalkSettingsUpdateFailure).kind,
          entry.value,
          reason: '${entry.key}',
        );
      }
    });

    test('a viewer who may not edit gets field_forbidden', () async {
      server.canEdit = false;
      final failure = (await upload()) as OwnTalkSettingsUpdateFailure;
      expect(failure.kind, OwnTalkExtensionsFailureKind.forbidden);
      expect(failure.errorCode, 'field_forbidden');
    });

    test(
      'never sends a body the server would refuse by size or type',
      () async {
        server.capability = ownTalkCapabilityJson(
          limits: {'maxImageBytes': 8, 'maxImageEdge': 100},
        );
        await expectLater(
          upload(),
          throwsA(isA<OwnTalkExtensionsException>()),
          reason: '12 bytes over an 8 byte limit',
        );
        server.capability = ownTalkCapabilityJson();
        await expectLater(
          upload(contentType: 'image/gif'),
          throwsA(isA<OwnTalkExtensionsException>()),
        );
        expect(server.uploads, isEmpty);
      },
    );

    test('is refused without the image feature', () async {
      server.capability = ownTalkCapabilityJson(
        features: ['appearance.colors'],
      );
      await expectLater(upload(), throwsA(isA<OwnTalkExtensionsException>()));
      expect(server.uploads, isEmpty);
    });
  });

  group('photo preparation', () {
    Future<Uint8List> noisePng(int width, int height) async {
      final random = Random(7);
      final pixels = Uint8List(width * height * 4);
      for (var index = 0; index < pixels.length; index++) {
        pixels[index] = index % 4 == 3 ? 255 : random.nextInt(256);
      }
      final decoded = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        pixels,
        width,
        height,
        ui.PixelFormat.rgba8888,
        decoded.complete,
      );
      final image = await decoded.future;
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    }

    Future<({int width, int height})> sizeOf(Uint8List bytes) async {
      final codec = await ui.instantiateImageCodec(bytes);
      final image = (await codec.getNextFrame()).image;
      return (width: image.width, height: image.height);
    }

    Future<void> expectPhotoError(
      Future<OwnTalkBackgroundPhoto> future,
      OwnTalkPhotoError error,
    ) => expectLater(
      future,
      throwsA(
        isA<OwnTalkPhotoException>().having((e) => e.error, 'error', error),
      ),
    );

    test('a photo within the limits is sent as it is', () async {
      final png = await noisePng(40, 30);
      final prepared = await prepareOwnTalkBackgroundPhoto(
        png,
        maxBytes: 1 << 20,
        maxEdge: 2560,
      );
      expect(identical(prepared.bytes, png), isTrue);
      expect(prepared.contentType, 'image/png');
    });

    test('the type is read from the content, not from a name', () async {
      for (final entry in {
        'image/jpeg': [0xFF, 0xD8, 0xFF, 0xE0],
        'image/webp': [
          0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50, //
        ],
      }.entries) {
        // A real header over undecodable data: the type is accepted, the
        // decoder is the one that objects.
        await expectPhotoError(
          prepareOwnTalkBackgroundPhoto(
            Uint8List.fromList([...entry.value, 1, 2, 3, 4, 5, 6, 7, 8]),
            maxBytes: 1 << 20,
            maxEdge: 2560,
          ),
          OwnTalkPhotoError.unreadable,
        );
      }
    });

    test('anything else is an unsupported type', () async {
      for (final bytes in [
        Uint8List.fromList(List.filled(32, 0)),
        Uint8List.fromList('GIF89a....'.codeUnits),
        Uint8List(0),
        // RIFF without WEBP, such as a WAV file
        Uint8List.fromList([
          0x52,
          0x49,
          0x46,
          0x46,
          0,
          0,
          0,
          0,
          0x57,
          0x41,
          0x56,
          0x45,
        ]),
      ]) {
        await expectPhotoError(
          prepareOwnTalkBackgroundPhoto(
            bytes,
            maxBytes: 1 << 20,
            maxEdge: 2560,
          ),
          OwnTalkPhotoError.unsupportedType,
        );
      }
    });

    test('a PNG header over garbage is unreadable', () async {
      final bytes = Uint8List.fromList([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4, 5, 6, //
      ]);
      await expectPhotoError(
        prepareOwnTalkBackgroundPhoto(bytes, maxBytes: 1 << 20, maxEdge: 2560),
        OwnTalkPhotoError.unreadable,
      );
    });

    test('a photo much larger than the server edge is scaled down', () async {
      final png = await noisePng(300, 100);
      final prepared = await prepareOwnTalkBackgroundPhoto(
        png,
        maxBytes: 1 << 20,
        maxEdge: 100,
      );
      expect(prepared.contentType, 'image/png');
      expect(await sizeOf(prepared.bytes), (width: 100, height: 33));
    });

    test('a portrait photo is scaled by its height', () async {
      final png = await noisePng(100, 300);
      final prepared = await prepareOwnTalkBackgroundPhoto(
        png,
        maxBytes: 1 << 20,
        maxEdge: 100,
      );
      expect(await sizeOf(prepared.bytes), (width: 33, height: 100));
    });

    test('a photo over the byte limit is scaled until it fits', () async {
      final png = await noisePng(400, 400);
      final limit = png.length ~/ 3;
      final prepared = await prepareOwnTalkBackgroundPhoto(
        png,
        maxBytes: limit,
        maxEdge: 400,
      );
      expect(prepared.bytes.length, lessThanOrEqualTo(limit));
      expect(prepared.bytes.length, lessThan(png.length));
      final size = await sizeOf(prepared.bytes);
      expect(size.width, lessThan(400));
    });

    test('a photo that cannot be made small enough is reported', () async {
      final png = await noisePng(64, 64);
      await expectPhotoError(
        prepareOwnTalkBackgroundPhoto(png, maxBytes: 16, maxEdge: 64),
        OwnTalkPhotoError.tooLarge,
      );
    });
  });

  group('account removal', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('owntalk-removal-');
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    ProviderContainer containerWith({bool brokenSettingsStore = false}) {
      final container = ProviderContainer(
        overrides: [
          chatBackgroundStoreProvider.overrideWith(
            (ref) async => ChatBackgroundStore.forTesting(
              Directory('${root.path}/backgrounds'),
            ),
          ),
          ownTalkSettingsStoreProvider.overrideWith(
            (ref) => brokenSettingsStore
                ? Future<OwnTalkSettingsStore>.error(StateError('disk'))
                : OwnTalkSettingsStore.forTesting(
                    Directory('${root.path}/settings'),
                  ),
          ),
          ownTalkImageCacheProvider.overrideWith(
            (ref) =>
                OwnTalkImageCache.forTesting(Directory('${root.path}/images')),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('removes the cached photos of that account only', () async {
      final container = containerWith();
      final cache = await container.read(ownTalkImageCacheProvider.future);
      final bytes = ownTalkTestJpeg();
      final sha = ownTalkTestSha(bytes);
      await cache.write(_account, sha, bytes);
      await cache.write('account-b', sha, bytes);

      await container.read(accountAppearanceCleanupProvider)(_account);

      expect(await cache.read(_account, sha), isNull);
      expect(await cache.read('account-b', sha), isNotNull);
    });

    test(
      'clears the colours and the shared settings of the account too',
      () async {
        final container = containerWith();
        final colours = await container.read(
          chatBackgroundStoreProvider.future,
        );
        final settings = await container.read(
          ownTalkSettingsStoreProvider.future,
        );
        const key = (accountId: _account, roomToken: ownTalkTestToken);
        await colours.write(key, '#123456');
        await settings.write(
          key,
          OwnTalkRoomSettings.fromJson(FakeOwnTalkServer().document()),
        );

        await container.read(accountAppearanceCleanupProvider)(_account);

        expect(await colours.read(key), isNull);
        expect(await settings.read(key), isNull);
      },
    );

    test('a store that fails does not keep the photos on the device', () async {
      final container = containerWith(brokenSettingsStore: true);
      final cache = await container.read(ownTalkImageCacheProvider.future);
      final bytes = ownTalkTestJpeg();
      final sha = ownTalkTestSha(bytes);
      await cache.write(_account, sha, bytes);

      await expectLater(
        container.read(accountAppearanceCleanupProvider)(_account),
        throwsA(isA<StateError>()),
      );
      expect(await cache.read(_account, sha), isNull);
    });
  });
}
