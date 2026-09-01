import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/platform/media/desktop_attachment_source.dart';
import 'package:nextcloudtalk/platform/media/durable_attachment_source_store.dart';
import 'package:nextcloudtalk/platform/media/image_attachment_picker.dart';
import 'package:talk_protocol/talk_protocol.dart';

void main() {
  late Directory root;
  late DurableAttachmentSourceStore store;
  late DurableImageAttachmentPicker picker;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('nctalk-desktop-drop-test-');
    store = DurableAttachmentSourceStore(root: root, maximumSourceBytes: 64);
    await store.initialize();
    picker = DurableImageAttachmentPicker(
      backend: const _UnusedSelectionBackend(),
      store: store,
      maximumImageBytes: 64,
    );
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('a regular file becomes an app-owned durable source', () async {
    final preparer = DesktopAttachmentSourcePreparer(picker: picker);

    final source = await preparer.prepare(
      DropItemFile.fromData(
        Uint8List.fromList('desktop payload'.codeUnits),
        name: 'report.txt',
        path: 'report.txt',
        mimeType: 'text/plain',
      ),
    );

    expect(source.ownership, AttachmentSourceOwnership.appOwnedCopy);
    expect(source.displayName, 'report.txt');
    expect(source.mimeType, 'text/plain');
    expect((await store.observe(source.handle)).matches(source), isTrue);
  });

  test('a directory is rejected without creating a durable source', () async {
    final preparer = DesktopAttachmentSourcePreparer(picker: picker);

    await expectLater(
      preparer.prepare(DropItemDirectory('folder', const <DropItem>[])),
      throwsA(
        isA<ImageAttachmentPickerException>().having(
          (error) => error.code,
          'code',
          ImageAttachmentPickerError.unsupportedType,
        ),
      ),
    );
    expect(await _storedFiles(root), isEmpty);
  });

  test('an oversize file is rejected before a durable copy is kept', () async {
    final preparer = DesktopAttachmentSourcePreparer(picker: picker);

    await expectLater(
      preparer.prepare(
        DropItemFile.fromData(
          Uint8List(65),
          name: 'large.bin',
          path: 'large.bin',
        ),
      ),
      throwsA(
        isA<DurableAttachmentSourceException>().having(
          (error) => error.code,
          'code',
          DurableAttachmentSourceError.sourceTooLarge,
        ),
      ),
    );
    expect(await _storedFiles(root), isEmpty);
  });

  test('macOS security access encloses the durable copy', () async {
    final calls = <String>[];
    final preparer = DesktopAttachmentSourcePreparer(
      picker: picker,
      startSecurityAccess: (bookmark) async {
        calls.add('start:${bookmark.single}');
        return true;
      },
      stopSecurityAccess: (bookmark) async {
        calls.add('stop:${bookmark.single}');
        return true;
      },
    );
    final item = DropItemFile.fromData(
      Uint8List.fromList(<int>[1, 2, 3]),
      name: 'private.bin',
      path: 'private.bin',
    )..extraAppleBookmark = Uint8List.fromList(<int>[7]);

    final source = await preparer.prepare(item);

    expect(calls, <String>['start:7', 'stop:7']);
    expect((await store.observe(source.handle)).matches(source), isTrue);
  });

  test(
    'refused macOS security access does not read or copy the file',
    () async {
      final preparer = DesktopAttachmentSourcePreparer(
        picker: picker,
        startSecurityAccess: (_) async => false,
      );
      final item = DropItemFile.fromData(
        Uint8List.fromList(<int>[1, 2, 3]),
        name: 'private.bin',
        path: 'private.bin',
      )..extraAppleBookmark = Uint8List.fromList(<int>[7]);

      await expectLater(
        preparer.prepare(item),
        throwsA(
          isA<ImageAttachmentPickerException>().having(
            (error) => error.code,
            'code',
            ImageAttachmentPickerError.invalidSelection,
          ),
        ),
      );
      expect(await _storedFiles(root), isEmpty);
    },
  );

  test(
    'security release failure does not strand an accepted durable copy',
    () async {
      final preparer = DesktopAttachmentSourcePreparer(
        picker: picker,
        startSecurityAccess: (_) async => true,
        stopSecurityAccess: (_) async => throw PlatformException(code: 'stop'),
      );
      final item = DropItemFile.fromData(
        Uint8List.fromList(<int>[1, 2, 3]),
        name: 'private.bin',
        path: 'private.bin',
      )..extraAppleBookmark = Uint8List.fromList(<int>[7]);

      final source = await preparer.prepare(item);

      expect((await store.observe(source.handle)).matches(source), isTrue);
    },
  );
}

Future<List<File>> _storedFiles(Directory root) async => root
    .list(recursive: true)
    .where((entry) => entry is File)
    .cast<File>()
    .toList();

final class _UnusedSelectionBackend implements ImageSelectionBackend {
  const _UnusedSelectionBackend();

  @override
  Future<ImageSelection?> selectImage(AttachmentPickerSource source) =>
      throw UnsupportedError('desktop drop does not open a picker');
}
