import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/network/attachment_transport.dart';
import 'package:nextcloudtalk/platform/contacts/contact_attachment_picker.dart';
import 'package:nextcloudtalk/platform/media/durable_attachment_source_store.dart';
import 'package:talk_protocol/talk_protocol.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(PlatformContactSelectionBackend.channelName);

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('platform picker decodes one selected vCard', () async {
    final bytes = Uint8List.fromList(_vCard('Alice Example'));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'pickContact');
          return <String, Object?>{
            'displayName': 'Alice Example',
            'vcard': bytes,
          };
        });

    final selected = await const PlatformContactSelectionBackend()
        .selectContact();

    expect(selected?.displayName, 'Alice Example');
    expect(selected?.vcard, bytes);
  });

  test(
    'platform picker treats a dismissed system sheet as cancellation',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => null);

      expect(
        await const PlatformContactSelectionBackend().selectContact(),
        isNull,
      );
    },
  );

  test(
    'platform picker reports permission denial without a fallback contact',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) => throw PlatformException(code: 'permission_denied'),
          );

      await expectLater(
        const PlatformContactSelectionBackend().selectContact(),
        throwsA(
          isA<ContactPickerException>().having(
            (error) => error.failure,
            'failure',
            ContactPickerFailure.permissionDenied,
          ),
        ),
      );
    },
  );

  test('durable picker owns a validated and safely named vCard copy', () async {
    final root = await Directory.systemTemp.createTemp(
      'nctalk-contact-picker-test-',
    );
    addTearDown(() => root.delete(recursive: true));
    final store = DurableAttachmentSourceStore(
      root: root,
      maximumSourceBytes: 64 * 1024,
    );
    await store.initialize();
    final picker = DurableContactAttachmentPicker(
      backend: _ContactBackend(
        ContactSelection(
          displayName: '../Alice: Example',
          vcard: Uint8List.fromList(_vCard('Alice Example')),
        ),
      ),
      store: store,
    );

    final source = await picker.pick(
      fallbackDisplayName: 'Contact',
      cancellationSignal: AttachmentCancellationController().signal,
    );

    expect(source, isNotNull);
    expect(source!.displayName, 'Alice Example.vcf');
    expect(source.mimeType, 'text/vcard');
    expect(source.ownership, AttachmentSourceOwnership.appOwnedCopy);
    final path = await store.resolveVerifiedPath(source);
    expect(await File(path).readAsBytes(), _vCard('Alice Example'));
  });

  test(
    'durable picker rejects multiple cards from the platform boundary',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'nctalk-contact-picker-test-',
      );
      addTearDown(() => root.delete(recursive: true));
      final store = DurableAttachmentSourceStore(
        root: root,
        maximumSourceBytes: 64 * 1024,
      );
      await store.initialize();
      final twoCards = <int>[
        ..._vCard('Alice Example'),
        ..._vCard('Bob Example'),
      ];
      final picker = DurableContactAttachmentPicker(
        backend: _ContactBackend(
          ContactSelection(
            displayName: 'Alice Example',
            vcard: Uint8List.fromList(twoCards),
          ),
        ),
        store: store,
      );

      await expectLater(
        picker.pick(
          fallbackDisplayName: 'Contact',
          cancellationSignal: AttachmentCancellationController().signal,
        ),
        throwsA(
          isA<ContactPickerException>().having(
            (error) => error.failure,
            'failure',
            ContactPickerFailure.invalidSelection,
          ),
        ),
      );
    },
  );

  test(
    'durable picker rejects a vCard without its required FN field',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'nctalk-contact-picker-test-',
      );
      addTearDown(() => root.delete(recursive: true));
      final store = DurableAttachmentSourceStore(
        root: root,
        maximumSourceBytes: 64 * 1024,
      );
      await store.initialize();
      final picker = DurableContactAttachmentPicker(
        backend: _ContactBackend(
          ContactSelection(
            displayName: 'Alice Example',
            vcard: Uint8List.fromList(
              'BEGIN:VCARD\r\nVERSION:3.0\r\nEND:VCARD\r\n'.codeUnits,
            ),
          ),
        ),
        store: store,
      );

      await expectLater(
        picker.pick(
          fallbackDisplayName: 'Contact',
          cancellationSignal: AttachmentCancellationController().signal,
        ),
        throwsA(isA<ContactPickerException>()),
      );
    },
  );

  test(
    'durable picker rejects a contact above the contact byte limit',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'nctalk-contact-picker-test-',
      );
      addTearDown(() => root.delete(recursive: true));
      final store = DurableAttachmentSourceStore(
        root: root,
        maximumSourceBytes: maximumContactVCardBytes * 2,
      );
      await store.initialize();
      final oversizedName = 'A' * maximumContactVCardBytes;
      final picker = DurableContactAttachmentPicker(
        backend: _ContactBackend(
          ContactSelection(
            displayName: 'Alice Example',
            vcard: Uint8List.fromList(
              'BEGIN:VCARD\r\nVERSION:3.0\r\nFN:$oversizedName\r\n'
                      'END:VCARD\r\n'
                  .codeUnits,
            ),
          ),
        ),
        store: store,
      );

      await expectLater(
        picker.pick(
          fallbackDisplayName: 'Contact',
          cancellationSignal: AttachmentCancellationController().signal,
        ),
        throwsA(isA<ContactPickerException>()),
      );
    },
  );
}

List<int> _vCard(String name) => Uint8List.fromList(
  'BEGIN:VCARD\r\nVERSION:3.0\r\nFN:$name\r\nEND:VCARD\r\n'.codeUnits,
);

final class _ContactBackend implements ContactSelectionBackend {
  const _ContactBackend(this.selection);

  final ContactSelection? selection;

  @override
  Future<ContactSelection?> selectContact() async => selection;
}
