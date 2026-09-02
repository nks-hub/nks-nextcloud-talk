import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/features/chat/media/remote_file_picker_screen.dart';
import 'package:nextcloudtalk/features/chat/remote_file_share_service.dart';
import 'package:nextcloudtalk/l10n/generated/app_localizations.dart';
import 'package:talk_protocol/talk_protocol.dart';

import 'accessibility_probe.dart';

final class _FakeRemoteFiles implements RemoteFileShareService {
  _FakeRemoteFiles({required this.directories, this.shareFailure});

  final Map<String, List<RemoteFileEntry>> directories;
  final RemoteFileError? shareFailure;
  final List<String> listed = <String>[];
  final List<String> shared = <String>[];

  @override
  Future<RemoteDirectoryListing> listDirectory({
    required String accountId,
    required String path,
    Future<void>? abortTrigger,
  }) async {
    listed.add(path);
    final entries = directories[path];
    if (entries == null) {
      throw const RemoteFileException(RemoteFileError.unavailable);
    }
    return RemoteDirectoryListing(path: path, entries: entries);
  }

  @override
  Future<void> shareIntoRoom({
    required String accountId,
    required String roomToken,
    required String path,
    Future<void>? abortTrigger,
  }) async {
    if (shareFailure != null) {
      throw RemoteFileException(shareFailure!);
    }
    shared.add(path);
  }
}

RemoteFileEntry _directory(String path) => RemoteFileEntry(
  path: path,
  name: path.split('/').last,
  isDirectory: true,
  sizeBytes: null,
  mimeType: null,
  hasPreview: false,
  lastModified: null,
);

RemoteFileEntry _file(String path, {int size = 1024}) => RemoteFileEntry(
  path: path,
  name: path.split('/').last,
  isDirectory: false,
  sizeBytes: size,
  mimeType: 'application/pdf',
  hasPreview: false,
  lastModified: null,
);

/// Opens the picker and returns the sink the route result lands in, so a test
/// can read what the picker reported after it closed.
Future<List<RemoteFilePickerResult?>> _open(
  WidgetTester tester,
  _FakeRemoteFiles files, {
  double textScale = 1,
  Locale locale = const Locale('en'),
}) async {
  final results = <RemoteFilePickerResult?>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [remoteFileShareServiceProvider.overrideWithValue(files)],
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, inner) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: inner!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                results.add(
                  await Navigator.of(context).push<RemoteFilePickerResult>(
                    MaterialPageRoute<RemoteFilePickerResult>(
                      builder: (_) => const RemoteFilePickerScreen(
                        accountId: 'account-a',
                        roomToken: 'room1234',
                      ),
                    ),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return results;
}

void main() {
  testWidgets('walks into a folder and shares the picked file', (tester) async {
    final files = _FakeRemoteFiles(
      directories: {
        '': [_directory('Documents'), _file('root.pdf')],
        'Documents': [_file('Documents/report.pdf')],
      },
    );

    final results = await _open(tester, files);

    expect(results, isEmpty);
    expect(files.listed, <String>['']);
    expect(find.byKey(const Key('remote-file-Documents')), findsOneWidget);

    await tester.tap(find.byKey(const Key('remote-file-Documents')));
    await tester.pumpAndSettle();

    expect(files.listed, <String>['', 'Documents']);
    expect(find.text('report.pdf'), findsOneWidget);

    await tester.tap(find.byKey(const Key('remote-file-Documents/report.pdf')));
    await tester.pumpAndSettle();

    // Nothing is shared before the confirmation is answered.
    expect(find.byKey(const Key('remote-file-share-dialog')), findsOneWidget);
    expect(files.shared, isEmpty);

    await tester.tap(find.byKey(const Key('remote-file-share-confirm')));
    await tester.pumpAndSettle();

    expect(files.shared, <String>['Documents/report.pdf']);
    expect(results, <RemoteFilePickerResult>[RemoteFilePickerResult.shared]);
  });

  testWidgets('cancelling the confirmation shares nothing', (tester) async {
    final files = _FakeRemoteFiles(
      directories: {
        '': [_file('root.pdf')],
      },
    );

    await _open(tester, files);
    await tester.tap(find.byKey(const Key('remote-file-root.pdf')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(files.shared, isEmpty);
    // The picker stays open so another file can be chosen.
    expect(find.byKey(const Key('remote-file-picker-list')), findsOneWidget);
  });

  testWidgets('a refused share leaves the picker with a reason', (
    tester,
  ) async {
    final files = _FakeRemoteFiles(
      directories: {
        '': [_file('root.pdf')],
      },
      shareFailure: RemoteFileError.forbidden,
    );

    final results = await _open(tester, files);
    await tester.tap(find.byKey(const Key('remote-file-root.pdf')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('remote-file-share-confirm')));
    await tester.pumpAndSettle();

    // The picker closes carrying the reason, so the conversation can say it.
    expect(results, <RemoteFilePickerResult>[RemoteFilePickerResult.forbidden]);
    expect(files.shared, isEmpty);
  });

  testWidgets('an unreadable folder offers a retry instead of an empty list', (
    tester,
  ) async {
    final files = _FakeRemoteFiles(directories: const {});

    await _open(tester, files);

    expect(find.byKey(const Key('remote-file-picker-error')), findsOneWidget);
    expect(find.byKey(const Key('remote-file-picker-list')), findsNothing);
  });

  testWidgets('back inside a folder goes up, not out of the picker', (
    tester,
  ) async {
    final files = _FakeRemoteFiles(
      directories: {
        '': [_directory('Documents')],
        'Documents': [_file('Documents/report.pdf')],
      },
    );

    await _open(tester, files);
    await tester.tap(find.byKey(const Key('remote-file-Documents')));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(files.listed, <String>['', 'Documents', '']);
    expect(find.byKey(const Key('remote-file-Documents')), findsOneWidget);
  });

  for (final locale in const [Locale('cs'), Locale('en')]) {
    testWidgets(
      'the share confirmation fits at 200 % text — ${locale.languageCode}',
      (tester) async {
        useTightPhoneViewport(tester);
        final files = _FakeRemoteFiles(
          directories: {
            // A long real-world name, because the body text interpolates it
            // and a short fixture would hide the case that actually breaks.
            '': [_file('Quarterly-infrastructure-review-final-v3.pdf')],
          },
        );

        // A dialog does not scroll its actions, so this is one of the screens
        // that can genuinely overflow — unlike the scrolled forms, where a
        // bigger text size only produces a longer scroll.
        final overflows = await overflowsWhile(() async {
          await _open(tester, files, textScale: 2, locale: locale);
          await tester.tap(
            find.byKey(
              const Key(
                'remote-file-Quarterly-infrastructure-review-final-v3.pdf',
              ),
            ),
          );
          await tester.pumpAndSettle();
        });

        expect(
          find.byKey(const Key('remote-file-share-dialog')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('remote-file-share-confirm')),
          findsOneWidget,
          reason: 'the confirmation must survive the larger text',
        );
        expect(
          overflows,
          isEmpty,
          reason: '${locale.languageCode}: ${overflows.join(' | ')}',
        );
      },
    );
  }
}
