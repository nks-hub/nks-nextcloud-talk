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
    test('a thumbnail path lookup checks the size without hashing', () async {
      final store = DurableAttachmentSourceStore(root: root);
      final source = await store.copyFromStream(
        stream: Stream<List<int>>.value(<int>[1, 2, 3, 4]),
        mimeType: 'image/png',
        displayName: 'photo.png',
      );
      final path = await store.resolvePath(source);

      // Same size, other bytes: only a lookup that hashed would notice.
      await File(path).writeAsBytes(<int>[9, 9, 9, 9], flush: true);
      expect(await store.resolvePath(source), path);
      await expectLater(
        store.resolveVerifiedPath(source),
        throwsA(isA<DurableAttachmentSourceException>()),
      );

      await File(path).writeAsBytes(<int>[9], flush: true);
      await expectLater(
        store.resolvePath(source),
        throwsA(isA<DurableAttachmentSourceException>()),
      );
    });

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

    test('restart cleanup removes every abandoned external write', () async {
      final firstStore = DurableAttachmentSourceStore(root: root);
      final pending = <DurableAttachmentWriteSession>[];
      for (var index = 0; index < 6; index++) {
        final session = await firstStore.beginExternalWrite(
          fileExtension: '.wav',
        );
        await File(
          session.filePath,
        ).writeAsBytes(<int>[index + 1], flush: true);
        pending.add(session);
      }

      final restartedStore = DurableAttachmentSourceStore(root: root);
      expect(await restartedStore.cleanupTemporaryFiles(), pending.length);
      for (final session in pending) {
        expect(await File(session.filePath).exists(), isFalse);
      }
    });

    test('the sweep removes only old sources no job names', () async {
      // A picked file waits in the composer until the send; when the process
      // dies first, its durable copy has no job and nothing would ever delete
      // it. Referenced and freshly written sources must survive the sweep.
      final store = DurableAttachmentSourceStore(root: root);
      Future<PreparedAttachmentSource> put(String name) => store.copyFromStream(
        stream: Stream<List<int>>.value(<int>[1, 2, 3]),
        mimeType: 'image/png',
        displayName: name,
      );
      final orphan = await put('orphan.png');
      final referenced = await put('referenced.png');
      final fresh = await put('fresh.png');
      final sources = Directory('${root.path}${Platform.pathSeparator}sources');
      final old = DateTime.now().subtract(const Duration(hours: 1));
      for (final file in await _filesBelow(sources)) {
        if (!file.path.contains(_sourceId(fresh))) {
          await file.setLastModified(old);
        }
      }

      final removed = await store.discardUnreferenced(
        referenced: {referenced.handle.value},
      );

      expect(removed, 1);
      final remaining = (await _filesBelow(
        sources,
      )).map((file) => file.uri.pathSegments.last).toList();
      expect(remaining, isNot(contains('${_sourceId(orphan)}.source')));
      expect(remaining, contains('${_sourceId(referenced)}.source'));
      expect(remaining, contains('${_sourceId(fresh)}.source'));
    });

    test('the orphan sweep keeps at most four deletions active', () async {
      final store = DurableAttachmentSourceStore(root: root);
      final sources = <PreparedAttachmentSource>[];
      for (var index = 0; index < 6; index++) {
        sources.add(
          await store.copyFromStream(
            stream: Stream<List<int>>.value(<int>[index + 1]),
            mimeType: 'application/octet-stream',
            displayName: 'orphan-$index.bin',
          ),
        );
      }
      final sourceDirectory = Directory(
        '${root.path}${Platform.pathSeparator}sources',
      );
      final old = DateTime.now().subtract(const Duration(hours: 1));
      for (final file in await _filesBelow(sourceDirectory)) {
        await file.setLastModified(old);
      }
      final held = <AttachmentSourceLease>[
        for (final source in sources) await store.open(source.handle),
      ];
      final sweep = store.discardUnreferenced(referenced: <String>{});
      addTearDown(() async {
        for (final lease in held) {
          await lease.close();
        }
        held.clear();
        await sweep;
      });

      for (var turn = 0; turn < 20; turn++) {
        if (await _unavailableCount(store, sources) == 4) {
          break;
        }
        await pumpEventQueue();
      }
      expect(await _unavailableCount(store, sources), 4);

      for (final lease in held) {
        await lease.close();
      }
      held.clear();
      expect(await sweep, 6);
      expect(await _allUnavailable(store, sources), isTrue);
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

    test('discarding a batch keeps at most four deletions active', () async {
      final store = DurableAttachmentSourceStore(root: root);
      final sources = <PreparedAttachmentSource>[];
      for (var index = 0; index < 6; index++) {
        sources.add(
          await store.copyFromStream(
            stream: Stream<List<int>>.value(<int>[index + 1]),
            mimeType: 'application/octet-stream',
            displayName: 'source-$index.bin',
          ),
        );
      }
      final held = <AttachmentSourceLease>[
        for (final source in sources.take(4)) await store.open(source.handle),
      ];
      final discard = store.discardAll(sources.map((source) => source.handle));
      addTearDown(() async {
        for (final lease in held) {
          await lease.close();
        }
        await discard;
      });

      for (var turn = 0; turn < 20; turn++) {
        if (await _allUnavailable(store, sources.take(4))) {
          break;
        }
        await pumpEventQueue();
      }
      expect(await _allUnavailable(store, sources.take(4)), isTrue);

      final fifth = await store.open(sources[4].handle);
      final sixth = await store.open(sources[5].handle);
      await fifth.close();
      await sixth.close();

      for (final lease in held) {
        await lease.close();
      }
      held.clear();
      await discard;
      expect(await _allUnavailable(store, sources), isTrue);
    });

    test('discarding a batch continues after invalid handles', () async {
      final store = DurableAttachmentSourceStore(root: root);
      Future<PreparedAttachmentSource> put(int value) => store.copyFromStream(
        stream: Stream<List<int>>.value(<int>[value]),
        mimeType: 'application/octet-stream',
        displayName: 'source-$value.bin',
      );
      final first = await put(1);
      final second = await put(2);
      final invalid = AttachmentSourceHandle.parse(
        'nctalk-media-v1:../../outside',
      );

      await expectLater(
        store.discardAll(<AttachmentSourceHandle>[
          invalid,
          invalid,
          invalid,
          invalid,
          first.handle,
          second.handle,
        ]),
        throwsA(
          isA<DurableAttachmentSourceException>().having(
            (error) => error.code,
            'code',
            DurableAttachmentSourceError.invalidHandle,
          ),
        ),
      );
      expect(
        await _allUnavailable(store, <PreparedAttachmentSource>[first, second]),
        isTrue,
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

String _sourceId(PreparedAttachmentSource source) =>
    source.handle.value.split(':').last;

Future<bool> _allUnavailable(
  DurableAttachmentSourceStore store,
  Iterable<PreparedAttachmentSource> sources,
) async {
  final pending = sources.toList(growable: false);
  return await _unavailableCount(store, pending) == pending.length;
}

Future<int> _unavailableCount(
  DurableAttachmentSourceStore store,
  Iterable<PreparedAttachmentSource> sources,
) async {
  var unavailable = 0;
  for (final source in sources) {
    try {
      final lease = await store.open(source.handle);
      await lease.close();
    } on DurableAttachmentSourceException catch (error) {
      if (error.code != DurableAttachmentSourceError.sourceUnavailable) {
        rethrow;
      }
      unavailable++;
    }
  }
  return unavailable;
}
