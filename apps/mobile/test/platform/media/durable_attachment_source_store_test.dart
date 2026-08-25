import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/network/attachment_transport.dart';
import 'package:nextcloudtalk/platform/media/durable_attachment_source_store.dart';
import 'package:talk_protocol/talk_protocol.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('nctalk-media-store-test-');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  group('DurableAttachmentSourceStore', () {
    test(
      'copies atomically, hashes bytes, and returns an opaque handle',
      () async {
        final store = DurableAttachmentSourceStore(
          root: root,
          maximumSourceBytes: 32,
        );

        final source = await store.copyFromStream(
          stream: Stream<List<int>>.fromIterable(<List<int>>[
            <int>[104, 101, 108, 108, 111, 32],
            <int>[119, 111, 114, 108, 100],
          ]),
          expectedByteLength: 11,
          mimeType: 'image/png',
          displayName: 'photo.png',
        );

        expect(source.byteLength, 11);
        expect(
          source.sha256.value,
          'b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9',
        );
        expect(source.ownership, AttachmentSourceOwnership.appOwnedCopy);
        expect(source.handle.value, startsWith('nctalk-media-v1:'));
        expect(source.handle.value, isNot(contains(root.path)));
        expect(source.handle.value, isNot(contains('photo.png')));
        expect(
          await _filesBelow(
            Directory('${root.path}${Platform.pathSeparator}staging'),
          ),
          isEmpty,
        );
        expect(
          await _filesBelow(
            Directory('${root.path}${Platform.pathSeparator}sources'),
          ),
          hasLength(1),
        );
      },
    );

    test(
      'removes partial output when a copy fails or exceeds its limit',
      () async {
        final store = DurableAttachmentSourceStore(
          root: root,
          maximumSourceBytes: 4,
        );

        await expectLater(
          store.copyFromStream(
            stream: Stream<List<int>>.fromIterable(<List<int>>[
              <int>[1, 2, 3],
              <int>[4, 5],
            ]),
            mimeType: 'image/png',
            displayName: 'large.png',
          ),
          throwsA(
            isA<DurableAttachmentSourceException>().having(
              (error) => error.code,
              'code',
              DurableAttachmentSourceError.sourceTooLarge,
            ),
          ),
        );

        expect(await _allStoreFiles(root), isEmpty);
      },
    );

    test(
      'reopens after restart and serves bounded ranges with seeking',
      () async {
        final firstStore = DurableAttachmentSourceStore(root: root);
        final source = await firstStore.copyFromStream(
          stream: Stream<List<int>>.value(<int>[0, 1, 2, 3, 4, 5, 6, 7]),
          expectedByteLength: 8,
          mimeType: 'application/octet-stream',
          displayName: 'payload.bin',
        );

        final restartedStore = DurableAttachmentSourceStore(root: root);
        final observation = await restartedStore.observe(source.handle);
        expect(observation.matches(source), isTrue);

        final lease = await restartedStore.open(source.handle);
        addTearDown(lease.close);
        expect(await _collect(lease.openRead(offset: 3, length: 3)), <int>[
          3,
          4,
          5,
        ]);
        expect(await _collect(lease.openRead(offset: 6)), <int>[6, 7]);
      },
    );

    test('rejects traversal and handles owned by another provider', () async {
      final store = DurableAttachmentSourceStore(root: root);

      for (final value in <String>[
        'nctalk-media-v1:../../outside',
        'app-private://voice-fixture.wav',
        'nctalk-media-v2:0123456789abcdef0123456789abcdef',
      ]) {
        await expectLater(
          store.open(AttachmentSourceHandle.parse(value)),
          throwsA(
            isA<DurableAttachmentSourceException>().having(
              (error) => error.code,
              'code',
              DurableAttachmentSourceError.invalidHandle,
            ),
          ),
        );
      }
    });

    test('cancellation closes the input and removes staging bytes', () async {
      final store = DurableAttachmentSourceStore(root: root);
      final cancellation = AttachmentCancellationController();
      final listening = Completer<void>();
      final input = StreamController<List<int>>(
        onListen: () => listening.complete(),
      );
      addTearDown(() async {
        if (input.hasListener) {
          await input.close();
        }
      });

      final copy = store.copyFromStream(
        stream: input.stream,
        mimeType: 'image/png',
        displayName: 'cancelled.png',
        cancellationSignal: cancellation.signal,
      );
      await listening.future;
      input.add(<int>[1, 2, 3]);
      await Future<void>.delayed(Duration.zero);
      cancellation.cancel();

      await expectLater(
        copy,
        throwsA(
          isA<DurableAttachmentSourceException>().having(
            (error) => error.code,
            'code',
            DurableAttachmentSourceError.cancelled,
          ),
        ),
      );
      expect(input.hasListener, isFalse);
      expect(await _allStoreFiles(root), isEmpty);
    });

    test('restart cleanup removes an abandoned external write', () async {
      final firstStore = DurableAttachmentSourceStore(root: root);
      final pending = await firstStore.beginExternalWrite(
        fileExtension: '.wav',
      );
      await File(pending.filePath).writeAsBytes(<int>[1, 2, 3], flush: true);

      final restartedStore = DurableAttachmentSourceStore(root: root);
      expect(await restartedStore.cleanupTemporaryFiles(), 1);
      expect(await File(pending.filePath).exists(), isFalse);
    });

    test('verified resolution detects changed bytes', () async {
      final store = DurableAttachmentSourceStore(root: root);
      final source = await store.copyFromStream(
        stream: Stream<List<int>>.value(<int>[1, 2, 3, 4]),
        mimeType: 'audio/wav',
        displayName: 'voice.wav',
      );
      final stored = (await _filesBelow(
        Directory('${root.path}${Platform.pathSeparator}sources'),
      )).single;
      await stored.writeAsBytes(<int>[4, 3, 2, 1], flush: true);

      await expectLater(
        store.resolveVerifiedPath(source),
        throwsA(
          isA<DurableAttachmentSourceException>().having(
            (error) => error.code,
            'code',
            DurableAttachmentSourceError.sourceChanged,
          ),
        ),
      );
    });

    test('discard waits for leases and prevents later opens', () async {
      final store = DurableAttachmentSourceStore(root: root);
      final source = await store.copyFromStream(
        stream: Stream<List<int>>.value(<int>[1, 2, 3]),
        mimeType: 'application/octet-stream',
        displayName: 'leased.bin',
      );
      final lease = await store.open(source.handle);
      var discarded = false;
      final discard = store
          .discard(source.handle)
          .then((_) => discarded = true);

      await Future<void>.delayed(Duration.zero);
      expect(discarded, isFalse);
      await lease.close();
      await discard;
      expect(discarded, isTrue);
      await expectLater(
        store.open(source.handle),
        throwsA(
          isA<DurableAttachmentSourceException>().having(
            (error) => error.code,
            'code',
            DurableAttachmentSourceError.sourceUnavailable,
          ),
        ),
      );
    });
  });
}

Future<List<int>> _collect(Stream<List<int>> stream) async =>
    stream.expand((chunk) => chunk).toList();

Future<List<File>> _filesBelow(Directory directory) async {
  if (!await directory.exists()) {
    return <File>[];
  }
  return directory
      .list(recursive: true, followLinks: false)
      .where((entity) => entity is File)
      .cast<File>()
      .toList();
}

Future<List<File>> _allStoreFiles(Directory root) async => _filesBelow(root);
