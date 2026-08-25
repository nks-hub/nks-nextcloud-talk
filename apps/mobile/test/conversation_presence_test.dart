import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/core/app_theme.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/features/conversations/conversation_presence.dart';

import 'test_support.dart';

void main() {
  CachedConversation conversation({
    int roomType = 1,
    String? status,
    String? statusIcon,
    String? statusMessage,
    int? statusClearAt,
  }) {
    return CachedConversation(
      accountId: 'account-a',
      token: 'rooma123',
      displayName: 'Synthetic peer',
      description: 'Synthetic conversation A',
      lastActivity: 1724300000,
      unreadMessages: 0,
      favorite: false,
      isArchived: false,
      readOnly: 0,
      roomType: roomType,
      roomName: 'synthetic-room-a',
      objectType: '',
      avatarVersion: '',
      isCustomAvatar: false,
      peerStatus: status,
      peerStatusIcon: statusIcon,
      peerStatusMessage: statusMessage,
      peerStatusClearAt: statusClearAt,
      rawJson: '{}',
    );
  }

  test('presence is derived only from a one-to-one server status', () {
    expect(ConversationPresence.fromConversation(conversation()), isNull);
    expect(
      ConversationPresence.fromConversation(
        conversation(roomType: 2, status: 'online'),
      ),
      isNull,
      reason: 'group rooms do not carry a single peer status',
    );
    expect(
      ConversationPresence.fromConversation(
        conversation(status: 'offline'),
      ),
      isNull,
      reason: 'offline and invisible must not render a presence badge',
    );
    expect(
      ConversationPresence.fromConversation(conversation(status: 'online'))!
          .kind,
      ConversationPresenceKind.online,
    );
    expect(
      ConversationPresence.fromConversation(conversation(status: 'dnd'))!.kind,
      ConversationPresenceKind.doNotDisturb,
    );
  });

  test('an expired custom status stops being presented', () {
    final now = DateTime.utc(2026, 8, 25, 12);
    final expired = ConversationPresence.fromConversation(
      conversation(
        status: 'away',
        statusIcon: '☕',
        statusMessage: 'Coffee break',
        statusClearAt: now.millisecondsSinceEpoch ~/ 1000 - 1,
      ),
      now: now,
    )!;
    expect(expired.kind, ConversationPresenceKind.away);
    expect(expired.icon, isNull);
    expect(expired.message, isNull);

    final active = ConversationPresence.fromConversation(
      conversation(
        status: 'away',
        statusIcon: '☕',
        statusMessage: 'Coffee break',
        statusClearAt: now.millisecondsSinceEpoch ~/ 1000 + 60,
      ),
      now: now,
    )!;
    expect(active.icon, '☕');
    expect(active.message, 'Coffee break');
  });

  testWidgets('the badge announces its state instead of relying on color', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      localizedTestApp(
        home: Scaffold(
          body: ConversationPresenceBadge(
            conversation: conversation(status: 'dnd'),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const Key('conversation-presence-badge-rooma123')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Do not disturb'),
      findsOneWidget,
      reason: 'a bare colored dot is invisible to assistive technology',
    );
    handle.dispose();
  });

  testWidgets('the room title exposes exactly one presence announcement', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      localizedTestApp(
        home: Scaffold(
          body: ConversationPresenceTitle(
            conversation: conversation(status: 'online'),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.bySemanticsLabel('Online'), findsOneWidget);
    handle.dispose();
  });

  for (final brightness in Brightness.values) {
    test('presence badges keep a 3:1 contrast in $brightness', () {
      final theme = brightness == Brightness.dark
          ? AppTheme.dark()
          : AppTheme.light();
      final scheme = theme.colorScheme;
      final backgrounds = <String, Color>{
        'surface': scheme.surface,
        'surfaceContainerLowest': scheme.surfaceContainerLowest,
        'surfaceContainerLow': scheme.surfaceContainerLow,
        'surfaceContainer': scheme.surfaceContainer,
      };

      for (final kind in ConversationPresenceKind.values) {
        final color = presenceColor(kind, brightness);
        for (final background in backgrounds.entries) {
          final ratio = _contrast(color, background.value);
          expect(
            ratio,
            greaterThanOrEqualTo(3.0),
            reason:
                '$kind on ${background.key} in $brightness is '
                '${ratio.toStringAsFixed(2)}:1',
          );
        }
      }
    });

    test('presence text keeps a 4.5:1 contrast in $brightness', () {
      final theme = brightness == Brightness.dark
          ? AppTheme.dark()
          : AppTheme.light();
      final scheme = theme.colorScheme;
      for (final background in <String, Color>{
        'surface': scheme.surface,
        'surfaceContainerLowest': scheme.surfaceContainerLowest,
        'surfaceContainer': scheme.surfaceContainer,
      }.entries) {
        final ratio = _contrast(scheme.onSurfaceVariant, background.value);
        expect(
          ratio,
          greaterThanOrEqualTo(4.5),
          reason:
              'presence subtitle on ${background.key} in $brightness is '
              '${ratio.toStringAsFixed(2)}:1',
        );
      }
    });
  }
}

double _contrast(Color foreground, Color background) {
  final foregroundLuminance = foreground.computeLuminance();
  final backgroundLuminance = background.computeLuminance();
  final lighter = foregroundLuminance > backgroundLuminance
      ? foregroundLuminance
      : backgroundLuminance;
  final darker = foregroundLuminance > backgroundLuminance
      ? backgroundLuminance
      : foregroundLuminance;
  return (lighter + 0.05) / (darker + 0.05);
}
