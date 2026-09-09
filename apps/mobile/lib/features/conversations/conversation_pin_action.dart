import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/app_database.dart';
import '../../l10n/generated/app_localizations.dart';
import 'conversation_header_actions.dart';
import 'conversation_shortcuts.dart';

/// Whether this launcher accepts a pinned shortcut.
///
/// Asked once per app run: it depends on the installed launcher, which does not
/// change under a running app, and a menu that has to wait for a channel round
/// trip before it can be drawn is worse than one item arriving a frame late.
final launcherPinSupportedProvider = FutureProvider<bool>((ref) {
  return ref.read(conversationShortcutPublisherProvider).pinSupported();
});

/// The "pin to the home screen" action, or nothing where a launcher will not
/// take one.
///
/// This is not Direct Share and not the recent-conversation shortcut list: the
/// four dynamic entries follow activity and churn, while a pin is a deliberate
/// choice that stays until the person removes it.
List<ConversationHeaderAction> conversationPinActions(
  BuildContext context,
  WidgetRef ref, {
  required StoredAccount account,
  required CachedConversation conversation,
}) {
  if (ref.watch(launcherPinSupportedProvider).valueOrNull != true) {
    return const <ConversationHeaderAction>[];
  }
  final shortcut = conversationShortcutFor(
    account: account,
    room: conversation,
  );
  if (shortcut == null) {
    return const <ConversationHeaderAction>[];
  }
  final strings = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  return <ConversationHeaderAction>[
    ConversationHeaderAction(
      id: const Key('pin-conversation-to-launcher'),
      icon: Icons.push_pin_outlined,
      label: strings.pinConversationToLauncher,
      onPressed: () => unawaited(() async {
        final asked = await ref
            .read(conversationShortcutPublisherProvider)
            .requestPin(shortcut);
        // Whether a pin appears is the launcher's own question to the person;
        // all this can honestly say is whether it was asked.
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              asked
                  ? strings.pinConversationRequested
                  : strings.pinConversationRefused,
            ),
          ),
        );
      }()),
    ),
  ];
}
