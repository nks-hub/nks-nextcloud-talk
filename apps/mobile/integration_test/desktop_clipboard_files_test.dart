@TestOn('windows')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nextcloudtalk/features/chat/composer/attachment_submission.dart';
import 'package:nextcloudtalk/features/chat/composer/chat_media_composer.dart';
import 'package:nextcloudtalk/platform/media/durable_attachment_source_store.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../test/test_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Windows clipboard files become separate pending attachments', (
    tester,
  ) async {
    final root = await Directory.systemTemp.createTemp('talk-clipboard-');
    addTearDown(() => root.delete(recursive: true));
    final files = <String>[];
    for (final name in ['slides.pptx', 'document.docx']) {
      final file = File('${root.path}/$name');
      await file.writeAsBytes([0x50, 0x4b, 3, 4]);
      files.add(file.path);
    }
    final store = DurableAttachmentSourceStore(
      root: Directory('${root.path}/sources'),
    );
    await store.initialize();
    final account = AccountId.parse('clipboard-test');
    final server = ServerBase.parse('https://cloud.example.invalid');
    final room = ConversationToken.parse(
      'roomone',
      path: r'$.roomToken',
      code: TalkProtocolErrorCode.invalidAttachmentModel,
    );
    final profile = AttachmentCapabilityProfile.fromSnapshot(
      CapabilitySnapshot.fromJson({
        'ocs': {
          'meta': {'status': 'ok', 'statuscode': 200, 'message': 'OK'},
          'data': {
            'version': {
              'major': 34,
              'minor': 0,
              'micro': 0,
              'string': '34.0.0',
              'edition': '',
            },
            'capabilities': {
              'spreed': {
                'features': ['chat-reference-id'],
                'config': {
                  'attachments': {
                    'allowed': true,
                    'conversation-subfolders': true,
                  },
                },
              },
            },
          },
        },
      }, context: CapabilityContext.authenticated),
      federated: false,
    );
    final controller = ChatMediaComposerController();
    await tester.pumpWidget(
      localizedTestApp(
        home: Scaffold(
          body: ChatMediaComposer(
            accountId: account,
            server: server,
            roomToken: room,
            threadId: null,
            replyTarget: null,
            onReplyDurablyAccepted: null,
            sourceStore: store,
            capabilityProfile: profile,
            controller: controller,
            submissionBridge: AttachmentSubmissionBridge(
              accountId: account,
              server: server,
              roomToken: room,
              prepare:
                  ({
                    required accountId,
                    required roomToken,
                    required source,
                    required metadata,
                  }) async =>
                      throw StateError('Pasting must not submit a file'),
              enqueue: (_) async =>
                  throw StateError('Pasting must not enqueue'),
            ),
          ),
        ),
      ),
    );
    expect(await Pasteboard.writeFiles(files), isTrue);
    final pasted = await Pasteboard.files();
    expect(pasted, files);
    expect(await controller.attachFiles(pasted), isTrue);
    await tester.pumpAndSettle();
    expect(find.text('slides.pptx'), findsOneWidget);
    expect(find.text('document.docx'), findsOneWidget);
    expect(controller.hasPreparedAttachment, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
