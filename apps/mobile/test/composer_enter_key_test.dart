import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/app_theme.dart';
import 'package:nextcloudtalk/core/desktop_metrics.dart';
import 'package:nextcloudtalk/features/chat/composer/composer_text_editing.dart';

/// Enter sends on desktop and breaks the line on touch.
void main() {
  group('composerEnterAction', () {
    test('sends what is typed', () {
      expect(
        composerEnterAction(
          text: 'ahoj',
          caret: 4,
          shiftPressed: false,
          sending: false,
        ),
        ComposerEnterAction.send,
      );
    });

    test('leaves Shift+Enter to the field', () {
      expect(
        composerEnterAction(
          text: 'ahoj',
          caret: 4,
          shiftPressed: true,
          sending: false,
        ),
        ComposerEnterAction.insertNewline,
      );
    });

    test('leaves Enter inside a mention to the suggestion list', () {
      expect(
        composerEnterAction(
          text: 'ahoj @pet',
          caret: 9,
          shiftPressed: false,
          sending: false,
        ),
        ComposerEnterAction.insertNewline,
      );
    });

    test('a caret that has left the mention sends again', () {
      expect(
        composerEnterAction(
          text: 'ahoj @petr ',
          caret: 11,
          shiftPressed: false,
          sending: false,
        ),
        ComposerEnterAction.send,
      );
    });

    test('an attachment with no caption still sends', () {
      // Reported on 5 September 2026: a screenshot pasted with Ctrl+V went out
      // on the Send button but not on Enter, because the decision read the
      // text alone.
      expect(
        composerEnterAction(
          text: '',
          caret: 0,
          shiftPressed: false,
          sending: false,
          hasAttachment: true,
        ),
        ComposerEnterAction.send,
      );
      // The other rules still win over it.
      expect(
        composerEnterAction(
          text: '',
          caret: 0,
          shiftPressed: true,
          sending: false,
          hasAttachment: true,
        ),
        ComposerEnterAction.insertNewline,
      );
      expect(
        composerEnterAction(
          text: '',
          caret: 0,
          shiftPressed: false,
          sending: true,
          hasAttachment: true,
        ),
        ComposerEnterAction.swallow,
      );
    });

    test('swallows Enter on an empty composer', () {
      for (final text in const ['', '   ', '\n']) {
        expect(
          composerEnterAction(
            text: text,
            caret: text.length,
            shiftPressed: false,
            sending: false,
          ),
          ComposerEnterAction.swallow,
          reason: 'a blank composer must not gain a stray line either',
        );
      }
    });

    test('swallows Enter while a send is already in flight', () {
      expect(
        composerEnterAction(
          text: 'ahoj',
          caret: 4,
          shiftPressed: false,
          sending: true,
        ),
        ComposerEnterAction.swallow,
      );
    });

    test('an unknown caret is treated as outside a mention', () {
      expect(
        composerEnterAction(
          text: 'ahoj @pet',
          caret: -1,
          shiftPressed: false,
          sending: false,
        ),
        ComposerEnterAction.send,
      );
    });
  });

  group('sendsOnEnter', () {
    testWidgets('is on for pointers and off for fingers', (tester) async {
      Future<bool> resolve(VisualDensity density) async {
        late bool value;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(visualDensity: density),
            home: Builder(
              builder: (context) {
                value = context.sendsOnEnter;
                return const SizedBox.shrink();
              },
            ),
          ),
        );
        await tester.pump();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        return value;
      }

      expect(await resolve(VisualDensity.compact), isTrue);
      expect(await resolve(VisualDensity.standard), isFalse);
    });

    testWidgets('the shipped theme agrees with the density rule', (
      tester,
    ) async {
      // `defaultTargetPlatform` is android inside `flutter_test` whatever the
      // host is, so the shipped theme has to be asked about a platform
      // explicitly; reading it plain would only ever describe a phone.
      Future<bool> resolveShipped(TargetPlatform platform) async {
        debugDefaultTargetPlatformOverride = platform;
        late bool value;
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            home: Builder(
              builder: (context) {
                value = context.sendsOnEnter;
                return const SizedBox.shrink();
              },
            ),
          ),
        );
        await tester.pump();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        debugDefaultTargetPlatformOverride = null;
        return value;
      }

      expect(await resolveShipped(TargetPlatform.windows), isTrue);
      expect(await resolveShipped(TargetPlatform.macOS), isTrue);
      expect(await resolveShipped(TargetPlatform.android), isFalse);
      expect(await resolveShipped(TargetPlatform.iOS), isFalse);
    });
  });
}
