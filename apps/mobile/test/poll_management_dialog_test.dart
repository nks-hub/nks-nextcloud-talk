import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/chat/poll_dialog.dart';
import 'package:nextcloudtalk/features/chat/poll_service.dart';
import 'package:talk_protocol/talk_protocol.dart';
import 'package:nextcloudtalk/features/chat/media/chat_attachment_exporter.dart';

import 'poll_test_support.dart';
import 'test_support.dart';

const _roomKey = (
  accountId: 'account-a',
  roomToken: 'roomtoken',
  threadId: null,
);

void main() {
  Future<void> open(WidgetTester tester, FakePollSender sender) async {
    await tester.pumpWidget(
      localizedTestApp(
        home: Scaffold(
          body: PollViewerDialog(sender: sender, roomKey: _roomKey, pollId: 7),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'ending a poll needs confirmation and uses the returned closed poll',
    (tester) async {
      final sender = FakePollSender(
        access: const PollManagementAccess(canClose: true),
      );
      await open(tester, sender);
      await tester.tap(find.byKey(const Key('poll-end')));
      await tester.pumpAndSettle();
      expect(sender.closeCalls, 0);
      await tester.tap(find.byKey(const Key('poll-confirm')));
      await tester.pumpAndSettle();
      expect(sender.closeCalls, 1);
      expect(sender.mutationKeys, [_roomKey]);
      expect(find.byKey(const Key('poll-viewer-vote')), findsNothing);
      expect(find.text('Poll ended'), findsOneWidget);
    },
  );

  testWidgets('ordinary participants do not receive management controls', (
    tester,
  ) async {
    await open(tester, FakePollSender());
    expect(find.byKey(const Key('poll-end')), findsNothing);
    expect(find.byKey(const Key('poll-export')), findsNothing);
    expect(find.byKey(const Key('poll-viewer-vote')), findsOneWidget);
  });

  testWidgets('closed results cannot be selected or voted on', (tester) async {
    final sender = FakePollSender()
      ..loadedPoll = pollFixture(status: PollStatus.closed);
    await open(tester, sender);
    expect(
      tester
          .widget<RadioListTile<int>>(
            find.byKey(const Key('poll-viewer-option-0')),
          )
          .enabled,
      isFalse,
    );
    expect(find.byKey(const Key('poll-viewer-vote')), findsNothing);
  });

  testWidgets(
    'a rejected end operation retains the open poll and releases controls',
    (tester) async {
      final sender = FakePollSender(
        access: const PollManagementAccess(canClose: true),
      )..managementError = PollServiceError.permissionDenied;
      await open(tester, sender);
      await tester.tap(find.byKey(const Key('poll-end')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('poll-confirm')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('poll-viewer-error')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('poll-viewer-vote')))
            .onPressed,
        isNotNull,
      );
      expect(sender.closeCalls, 1);
    },
  );

  for (final format in PollExportFormat.values) {
    testWidgets(
      '${format.name} export uses the native saver and reports its result',
      (tester) async {
        final sender = FakePollSender(
          access: const PollManagementAccess(canExport: true),
        );
        final system = _ExportSystem();
        await tester.pumpWidget(
          localizedTestApp(
            home: Scaffold(
              body: PollViewerDialog(
                sender: sender,
                roomKey: _roomKey,
                pollId: 7,
                exportSystem: system,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('poll-export')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.text(
            format == PollExportFormat.csv ? 'Export CSV' : 'Export ODS',
          ),
        );
        await tester.pumpAndSettle();
        expect(sender.exports, [format]);
        expect(system.saved, 'poll-7.${format.name}');
        expect(system.bytes, [1, 2, 3]);
        expect(find.text('Results saved'), findsOneWidget);
      },
    );
  }

  for (final result in [
    ChatAttachmentSystemResult.cancelled,
    ChatAttachmentSystemResult.storageFailed,
  ]) {
    testWidgets('native save ${result.name} is not reported as success', (
      tester,
    ) async {
      final sender = FakePollSender(
        access: const PollManagementAccess(canExport: true),
      );
      final system = _ExportSystem()..result = result;
      await tester.pumpWidget(
        localizedTestApp(
          home: Scaffold(
            body: PollViewerDialog(
              sender: sender,
              roomKey: _roomKey,
              pollId: 7,
              exportSystem: system,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('poll-export')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export CSV'));
      await tester.pumpAndSettle();
      expect(find.text('Results saved'), findsNothing);
      expect(
        find.byKey(const Key('poll-viewer-error')),
        result == ChatAttachmentSystemResult.cancelled
            ? findsNothing
            : findsOneWidget,
      );
      expect(
        tester
            .widget<PopupMenuButton<PollExportFormat>>(
              find.byKey(const Key('poll-export')),
            )
            .enabled,
        isTrue,
      );
    });
  }

  testWidgets(
    'a late export after account switch never opens the system saver',
    (tester) async {
      final sender = FakePollSender(
        access: const PollManagementAccess(canExport: true),
      )..exportCompleter = Completer<PollExportFile>();
      final system = _ExportSystem();
      var current = true;
      await tester.pumpWidget(
        localizedTestApp(
          home: Scaffold(
            body: PollViewerDialog(
              sender: sender,
              roomKey: _roomKey,
              pollId: 7,
              exportSystem: system,
              isCurrent: () => current,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('poll-export')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export CSV'));
      await tester.pump();
      current = false;
      sender.exportCompleter!.complete(
        PollExportFile(
          bytes: Uint8List.fromList([1]),
          fileName: 'poll-7.csv',
          mimeType: 'text/csv',
        ),
      );
      await tester.pumpAndSettle();
      expect(system.saved, isNull);
      expect(find.text('Results saved'), findsNothing);
    },
  );

  testWidgets(
    'switching scope during close confirmation prevents the mutation',
    (tester) async {
      final sender = FakePollSender(
        access: const PollManagementAccess(canClose: true),
      );
      var current = true;
      await tester.pumpWidget(
        localizedTestApp(
          home: Scaffold(
            body: PollViewerDialog(
              sender: sender,
              roomKey: _roomKey,
              pollId: 7,
              isCurrent: () => current,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('poll-end')));
      await tester.pumpAndSettle();
      current = false;
      await tester.tap(find.byKey(const Key('poll-confirm')));
      await tester.pumpAndSettle();
      expect(sender.closeCalls, 0);
    },
  );
}

final class _ExportSystem implements ChatAttachmentSystem {
  ChatAttachmentSystemResult result = ChatAttachmentSystemResult.completed;
  String? saved;
  Uint8List? bytes;
  @override
  Future<ChatAttachmentSystemResult> save({
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  }) async {
    saved = fileName;
    this.bytes = bytes;
    return result;
  }

  @override
  Future<ChatAttachmentSystemResult> share({
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  }) => throw UnimplementedError();
}
