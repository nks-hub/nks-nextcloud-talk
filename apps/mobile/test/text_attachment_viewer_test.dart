import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nextcloudtalk/data/account_repository.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/chat_media_repository.dart';
import 'package:nextcloudtalk/features/chat/media/text_attachment_viewer.dart';

import 'test_support.dart';

final Uri _uri = Uri.parse(
  'https://cloud.example.invalid/remote.php/dav/files/fixture-user/Talk/notes.md',
);

ChatMediaRepository _repository(List<int> body, {String type = 'text/markdown'}) {
  final vault = MemoryCredentialVault()
    ..values['account-a'] = 'fixture-app-password';
  return ChatMediaRepository(
    vault,
    wait: (_) async {},
    client: MockClient(
      (request) async => http.Response.bytes(
        body,
        200,
        headers: {'content-type': type},
      ),
    ),
  );
}

Future<void> _pump(
  WidgetTester tester,
  StoredAccount account,
  ChatMediaRepository repository, {
  String type = 'text/markdown',
  VoidCallback? onOpenExternally,
}) async {
  await tester.pumpWidget(
    localizedTestApp(
      home: TextAttachmentViewer(
        account: account,
        uri: _uri,
        fileName: 'notes.md',
        contentType: type,
        repository: repository,
        onOpenExternally: onOpenExternally,
      ),
    ),
  );
  await tester.pump();
  await tester.pumpAndSettle();
}

void main() {
  late AppDatabase database;
  late StoredAccount account;

  setUp(() async {
    database = openTestDatabase();
    account = await AccountRepository(database).upsertAccount(
      accountId: 'account-a',
      serverUrl: 'https://cloud.example.invalid',
      loginName: 'fixture-user',
      serverProductName: 'Nextcloud',
      createdAt: DateTime.utc(2026, 1, 1),
    );
  });

  tearDown(() => database.close());

  test('only plain text and Markdown are read in the app', () {
    expect(isReadableText('text/plain'), isTrue);
    expect(isReadableText('text/markdown'), isTrue);
    expect(isReadableText('text/markdown; charset=utf-8'), isTrue);
    expect(isReadableText('TEXT/PLAIN'), isTrue);
    // Reading these means interpreting them, which is somebody else's job.
    expect(isReadableText('text/html'), isFalse);
    expect(isReadableText('application/pdf'), isFalse);
    expect(isReadableText('image/png'), isFalse);
  });

  testWidgets('a Markdown attachment is shown as its own source', (
    tester,
  ) async {
    const source = '# Notes\n\nA line with **stars** and <b>markup</b>.';
    final repository = _repository(utf8.encode(source));
    addTearDown(repository.close);

    await _pump(tester, account, repository);

    expect(find.byKey(const Key('text-attachment-viewer')), findsOneWidget);
    final shown = tester
        .widget<SelectableText>(find.byKey(const Key('text-attachment-content')))
        .data;
    expect(shown, source);
    expect(
      shown,
      contains('<b>markup</b>'),
      reason: 'markup stays text; nothing here interprets it',
    );
    expect(find.byKey(const Key('text-attachment-truncated')), findsNothing);
  });

  testWidgets('a file too long to show says so and still shows the start', (
    tester,
  ) async {
    final long = utf8.encode('x' * (maximumReadableTextBytes + 500));
    final repository = _repository(long, type: 'text/plain');
    addTearDown(repository.close);

    await _pump(tester, account, repository, type: 'text/plain');

    expect(find.byKey(const Key('text-attachment-truncated')), findsOneWidget);
    expect(
      tester
          .widget<SelectableText>(
            find.byKey(const Key('text-attachment-content')),
          )
          .data!
          .length,
      maximumReadableTextBytes,
    );
  });

  testWidgets('bytes that are not valid UTF-8 still open', (tester) async {
    final repository = _repository(<int>[
      ...utf8.encode('before '),
      0xff,
      0xfe,
      ...utf8.encode(' after'),
    ], type: 'text/plain');
    addTearDown(repository.close);

    await _pump(tester, account, repository, type: 'text/plain');

    final shown = tester
        .widget<SelectableText>(find.byKey(const Key('text-attachment-content')))
        .data!;
    expect(shown, startsWith('before '));
    expect(shown, endsWith(' after'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed download offers a retry, not an empty page', (
    tester,
  ) async {
    var attempts = 0;
    final vault = MemoryCredentialVault()
      ..values['account-a'] = 'fixture-app-password';
    final repository = ChatMediaRepository(
      vault,
      wait: (_) async {},
      client: MockClient((request) async {
        attempts++;
        if (attempts == 1) {
          return http.Response('', 503);
        }
        return http.Response.bytes(
          utf8.encode('recovered'),
          200,
          headers: const {'content-type': 'text/plain'},
        );
      }),
    );
    addTearDown(repository.close);

    await _pump(tester, account, repository, type: 'text/plain');
    expect(find.byKey(const Key('text-attachment-failed')), findsOneWidget);

    await tester.tap(find.byKey(const Key('text-attachment-retry')));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<SelectableText>(
            find.byKey(const Key('text-attachment-content')),
          )
          .data,
      'recovered',
    );
  });

  testWidgets('a line can be selected and copied out', (tester) async {
    const source = 'alpha beta gamma';
    final repository = _repository(utf8.encode(source), type: 'text/plain');
    addTearDown(repository.close);
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map<Object?, Object?>)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await _pump(tester, account, repository, type: 'text/plain');

    // Reading a log in place is only useful if a line can be taken out of it.
    final finder = find.byKey(const Key('text-attachment-content'));
    // The centre of a wide, one-line block is past the end of the text, where
    // a press selects nothing; the word itself is near the start.
    await tester.longPressAt(tester.getTopLeft(finder) + const Offset(20, 8));
    await tester.pumpAndSettle();
    final state = tester.state<EditableTextState>(
      find.descendant(of: finder, matching: find.byType(EditableText)),
    );
    expect(state.textEditingValue.selection.isCollapsed, isFalse);
    expect(
      state.textEditingValue.selection.textInside(source).trim(),
      isNotEmpty,
    );

    state.copySelection(SelectionChangedCause.toolbar);
    await tester.pump();
    expect(copied, isNotEmpty);
    expect(source, contains(copied.single));
  });

  testWidgets('a credential the server no longer accepts is reported', (
    tester,
  ) async {
    final vault = MemoryCredentialVault()
      ..values['account-a'] = 'fixture-app-password';
    final repository = ChatMediaRepository(
      vault,
      wait: (_) async {},
      client: MockClient((request) async => http.Response('', 401)),
    );
    addTearDown(repository.close);

    await _pump(tester, account, repository, type: 'text/plain');

    expect(find.byKey(const Key('text-attachment-failed')), findsOneWidget);
    expect(find.byKey(const Key('text-attachment-content')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('handing the file to another app stays available', (
    tester,
  ) async {
    var opened = 0;
    final repository = _repository(utf8.encode('hello'), type: 'text/plain');
    addTearDown(repository.close);

    await _pump(
      tester,
      account,
      repository,
      type: 'text/plain',
      onOpenExternally: () => opened++,
    );

    await tester.tap(
      find.byKey(const Key('text-attachment-open-externally')),
    );
    await tester.pump();

    expect(opened, 1);
  });
}
