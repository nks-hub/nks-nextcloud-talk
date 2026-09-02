import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/features/conversations/list_pane_preference.dart';

/// The fold has to survive a restart, or a desktop window gets refolded every
/// launch — which is the whole reason it is a preference and not layout state.
void main() {
  late Directory root;
  late FileListPanePreferenceStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('nctalk-list-pane-');
    store = FileListPanePreferenceStore(directory: root);
  });

  tearDown(() async {
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }
  });

  test('a window that was never folded opens with the list shown', () async {
    expect(await store.readCollapsed(), isFalse);
  });

  test('the fold survives a restart, in both directions', () async {
    await store.writeCollapsed(collapsed: true);
    expect(
      await FileListPanePreferenceStore(directory: root).readCollapsed(),
      isTrue,
    );

    await store.writeCollapsed(collapsed: false);
    expect(
      await FileListPanePreferenceStore(directory: root).readCollapsed(),
      isFalse,
    );
  });

  test(
    'an unreadable preference shows the list rather than hiding it',
    () async {
      // The safe direction on purpose: a wrongly hidden list reads as lost
      // conversations, a wrongly shown one costs a single click.
      final file = File('${root.path}/conversation_list_collapsed.txt');
      await file.writeAsString('something else entirely');

      expect(await store.readCollapsed(), isFalse);
    },
  );

  test(
    'writing into a directory that does not exist yet still works',
    () async {
      final nested = Directory('${root.path}/not/created/yet');
      final deep = FileListPanePreferenceStore(directory: nested);

      await deep.writeCollapsed(collapsed: true);

      expect(await deep.readCollapsed(), isTrue);
    },
  );
}
