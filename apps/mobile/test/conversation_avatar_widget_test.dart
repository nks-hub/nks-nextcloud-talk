import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nextcloudtalk/app_providers.dart';
import 'package:nextcloudtalk/core/app_theme.dart';
import 'package:nextcloudtalk/data/app_database.dart';
import 'package:nextcloudtalk/data/conversation_avatar_repository.dart';
import 'package:nextcloudtalk/features/conversations/conversation_avatar_widget.dart';

void main() {
  const account = StoredAccount(
    id: 'account-a',
    serverUrl: 'https://cloud.example.invalid',
    loginName: 'fixture-user',
    serverProductName: 'Nextcloud',
    talkFeaturesJson: '["avatar"]',
    selected: true,
    createdAtMillis: 1767225600000,
  );
  const conversation = CachedConversation(
    accountId: 'account-a',
    token: 'room-a',
    displayName: 'OpenClaw Bot',
    description: '',
    lastActivity: 1724300000,
    unreadMessages: 0,
    favorite: false,
    isArchived: false,
    readOnly: 0,
    roomType: 1,
    roomName: 'openclaw-bot',
    objectType: '',
    avatarVersion: '',
    isCustomAvatar: false,
    rawJson: '{}',
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'generated direct avatar uses accessible initials in ${brightness.name}',
      (tester) async {
        final semantics = tester.ensureSemantics();
        await tester.pumpWidget(
          _app(
            brightness: brightness,
            image: ConversationAvatarImage(
              body: base64Decode(_transparentGif),
              contentType: 'image/gif',
              isCustomAvatar: false,
            ),
            child: const ConversationAvatar(
              account: account,
              conversation: conversation,
            ),
          ),
        );
        await tester.pump();

        expect(find.text('OB'), findsOneWidget);
        expect(find.byType(Image), findsNothing);
        final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
        expect(
          _contrast(avatar.foregroundColor!, avatar.backgroundColor!),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          tester.getSemantics(find.byType(ConversationAvatar)),
          matchesSemantics(label: 'OpenClaw Bot', isImage: true),
        );
        semantics.dispose();
      },
    );
  }

  testWidgets('custom direct avatar remains an image', (tester) async {
    await tester.pumpWidget(
      _app(
        brightness: Brightness.light,
        image: ConversationAvatarImage(
          body: base64Decode(_transparentGif),
          contentType: 'image/gif',
          isCustomAvatar: true,
        ),
        child: const ConversationAvatar(
          account: account,
          conversation: conversation,
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(Image), findsOneWidget);
    expect(find.text('OB'), findsNothing);
  });
}

Widget _app({
  required Brightness brightness,
  required ConversationAvatarImage image,
  required Widget child,
}) {
  return ProviderScope(
    overrides: [
      conversationAvatarProvider.overrideWith((ref, key) async => image),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
      home: Scaffold(body: Center(child: child)),
    ),
  );
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

const _transparentGif = 'R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==';
