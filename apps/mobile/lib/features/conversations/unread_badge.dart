import 'dart:async';
import 'dart:io';

import 'package:app_badge_plus/app_badge_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_providers.dart';
import '../../data/app_database.dart';
import '../../l10n/generated/app_localizations.dart';

/// Sum of `unreadMessages` across [conversations].
///
/// Pure by design: account isolation comes entirely from the caller only
/// ever passing conversations already scoped to one account (see
/// `AccountRepository.watchConversations`), not from any filtering done here.
int unreadCountOf(Iterable<CachedConversation> conversations) {
  return conversations.fold(
    0,
    (sum, conversation) => sum + conversation.unreadMessages,
  );
}

/// Per-account unread message counts, plus the [total] across every account.
@immutable
final class UnreadSummary {
  const UnreadSummary(this.byAccount);

  static const empty = UnreadSummary({});

  final Map<String, int> byAccount;

  int countFor(String accountId) => byAccount[accountId] ?? 0;

  int get total => byAccount.values.fold(0, (sum, count) => sum + count);
}

/// Recomputed whenever the account list or any single account's conversation
/// stream changes; each account's count only ever depends on that account's
/// own [conversationsProvider] stream, so one account's data can never leak
/// into another account's count.
final unreadSummaryProvider = Provider<UnreadSummary>((ref) {
  final accounts = ref.watch(accountsProvider).valueOrNull ?? const [];
  final byAccount = <String, int>{
    for (final account in accounts)
      account.id: unreadCountOf(
        ref.watch(conversationsProvider(account.id)).valueOrNull ?? const [],
      ),
  };
  return UnreadSummary(byAccount);
});

/// A small unread-count badge, meant to overlay an account avatar wherever
/// the account switcher shows one.
///
/// Plain [StatelessWidget] on purpose: `ConversationWorkspace` and everything
/// under it (`_AccountRail`, `_AccountMenu`, `_AccountAvatar`, ...) is
/// data-driven and rendered in tests without a `ProviderScope`. Reading
/// [unreadSummaryProvider] happens once, higher up in `_ConversationShellState`
/// (which is already `ConsumerStatefulWidget`), and the resulting counts are
/// threaded down as plain data.
final class UnreadCountBadge extends StatelessWidget {
  const UnreadCountBadge({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: AppLocalizations.of(context).unreadMessages(count),
      child: ExcludeSemantics(
        child: Container(
          constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(
            color: scheme.error,
            borderRadius: BorderRadius.circular(9),
          ),
          alignment: Alignment.center,
          child: Text(
            count > 99 ? '99+' : '$count',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.onError,
              fontWeight: FontWeight.w700,
              fontSize: 10,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

/// Talks to the runner that owns the Windows taskbar overlay icon.
///
/// `app_badge_plus` declares only `android`, `ios` and `macos`, and Windows
/// has no launcher badge API at all — the taskbar button takes a small overlay
/// icon instead, which the runner draws from this count.
const _windowsTaskbarBadgeChannel = MethodChannel(
  'com.nkshub.nextcloudtalk/taskbar_badge',
);

/// Hands [count] to the runner, which redraws or clears the overlay icon.
Future<void> setWindowsTaskbarBadge(int count) {
  return _windowsTaskbarBadgeChannel.invokeMethod<void>('setBadge', count);
}

bool get _usesWindowsTaskbar => !kIsWeb && Platform.isWindows;

Future<bool> _platformIsSupported() async {
  return _usesWindowsTaskbar ? true : AppBadgePlus.isSupported();
}

Future<void> _platformUpdateBadge(int count) {
  return _usesWindowsTaskbar
      ? setWindowsTaskbarBadge(count)
      : AppBadgePlus.updateBadge(count);
}

/// Best-effort launcher icon badge: Android and iOS launchers plus the macOS
/// dock through `app_badge_plus`, and the Windows taskbar through the runner.
/// `isSupported()` covers
/// launchers that don't offer badges at all (checked once and cached), and
/// every call is swallowed so a badge failure — unsupported launcher,
/// missing platform channel, anything else — never crashes the app or
/// surfaces an error to the user.
final class AppIconBadgeUpdater {
  AppIconBadgeUpdater({
    Future<bool> Function()? isSupported,
    Future<void> Function(int)? updateBadge,
  }) : _isSupported = isSupported ?? _platformIsSupported,
       _updateBadge = updateBadge ?? _platformUpdateBadge;

  final Future<bool> Function() _isSupported;
  final Future<void> Function(int) _updateBadge;
  bool? _supported;

  Future<void> update(int count) async {
    try {
      _supported ??= await _isSupported();
      if (_supported != true) {
        return;
      }
      await _updateBadge(count < 0 ? 0 : count);
    } on Object {
      // ponytail: launcher badge support is best-effort and cosmetic; never
      // let it crash the app or surface an error to the user.
    }
  }
}

final appIconBadgeUpdaterProvider = Provider<AppIconBadgeUpdater>((ref) {
  return AppIconBadgeUpdater();
});

/// Watching this provider keeps the OS launcher badge in sync with
/// [unreadSummaryProvider] for as long as something keeps it alive; the
/// conversation shell watches it for the app's lifetime.
final appIconBadgeSyncProvider = Provider<void>((ref) {
  final updater = ref.watch(appIconBadgeUpdaterProvider);
  ref.listen<UnreadSummary>(unreadSummaryProvider, (previous, next) {
    unawaited(updater.update(next.total));
  }, fireImmediately: true);
});
