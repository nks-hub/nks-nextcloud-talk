import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/app_theme.dart';
import 'package:nextcloudtalk/features/chat/chat_background_surface.dart';
import 'package:nextcloudtalk/features/chat/chat_background_theme.dart';

void main() {
  testWidgets('surface follows persisted room colour in both themes', (
    tester,
  ) async {
    const key = (accountId: 'account-a', roomToken: 'rooma123');

    for (final theme in <ThemeData>[AppTheme.light(), AppTheme.dark()]) {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            chatBackgroundProvider(
              key,
            ).overrideWith((ref) => Stream<String?>.value('#FF00FF')),
          ],
          child: MaterialApp(
            theme: theme,
            home: const ChatBackgroundSurface(
              accountId: 'account-a',
              roomToken: 'rooma123',
              child: SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final box = tester.widget<ColoredBox>(
        find.byKey(const Key('chat-background-surface')),
      );
      final renderedScheme = Theme.of(
        tester.element(find.byKey(const Key('chat-background-surface'))),
      ).colorScheme;
      expect(
        box.color,
        safeChatBackground(const Color(0xFFFF00FF), renderedScheme),
      );
      expect(
        chatBackgroundContrast(box.color, renderedScheme.onSurface),
        greaterThanOrEqualTo(4.5),
      );
    }
  });
}
