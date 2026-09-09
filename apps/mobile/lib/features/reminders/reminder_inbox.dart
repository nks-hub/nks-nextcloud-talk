/// One list of every reminder pending on every signed-in account.
///
/// The server route behind it is account-wide but single-account
/// (`GET v1/chat/upcoming-reminders`), so the list across accounts is this
/// client's own fan-out: one request per account, several in flight at a time,
/// and one account that cannot answer costs only its own rows.
///
/// Identity here is always account plus room token plus message ID. Tokens and
/// message IDs are per server, so two accounts on the same server routinely
/// hold reminders that agree on both - that is two reminders, not one, and a
/// row keyed on the token alone would delete or open the wrong one.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import '../../data/app_database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../chat/chat_pin_reminder_schedule.dart';
import '../conversations/conversation_presence.dart';

/// How many accounts are asked at once.
///
/// The fan-out is bounded because the number of accounts is the user's choice,
/// not ours: every one of these is an authenticated HTTPS round trip, and a
/// person with a dozen accounts must not open a dozen connections at once just
/// by opening a screen.
const int reminderInboxFanOutLimit = 4;

typedef UpcomingReminderLister =
    Future<List<RichChatUpcomingReminder>> Function(String accountId);
typedef UpcomingReminderRemover = Future<void> Function(ReminderInboxRow row);

/// Puts the reminded message on screen once its account has been selected.
///
/// A seam, so that the account switch can be asserted without building a chat
/// room: the real screen brings its own timers and its own network work into a
/// test about a list.
typedef ReminderMessagePresenter =
    Future<void> Function(
      BuildContext context, {
      required StoredAccount account,
      required CachedConversation conversation,
      required int messageId,
    });
typedef ConversationNameLookup =
    Future<String?> Function(String accountId, String roomToken);

/// One reminder, bound to the account whose server answered with it.
final class ReminderInboxRow {
  const ReminderInboxRow({
    required this.accountId,
    required this.accountLabel,
    required this.conversationName,
    required this.reminder,
  });

  final String accountId;

  /// How the account names itself in the row: login name and server host.
  final String accountLabel;

  /// Name of the conversation from the local cache, or null when this device
  /// has never synchronized that room.
  final String? conversationName;

  final RichChatUpcomingReminder reminder;

  String get roomToken => reminder.roomToken.value;
  int get messageId => reminder.messageId;

  /// Stable identity of the row across a reload.
  String get identity => '$accountId|$roomToken|$messageId';

  DateTime get dueAt => DateTime.fromMillisecondsSinceEpoch(
    reminder.reminderTimestamp * 1000,
    isUtc: true,
  );
}

/// The result of one fan-out: the rows that were read, and the accounts that
/// could not be read at all.
final class ReminderInbox {
  ReminderInbox({
    required Iterable<ReminderInboxRow> rows,
    required Iterable<String> unreadableAccounts,
  }) : rows = List.unmodifiable(rows),
       unreadableAccounts = List.unmodifiable(unreadableAccounts);

  final List<ReminderInboxRow> rows;

  /// Labels of the accounts whose reminders are missing from [rows].
  final List<String> unreadableAccounts;

  /// Whether nothing at all could be read. An inbox with no rows means "no
  /// reminders"; this means "we do not know".
  bool get everythingFailed => rows.isEmpty && unreadableAccounts.isNotEmpty;
}

String reminderAccountLabel(StoredAccount account) =>
    '${account.loginName}@${Uri.parse(account.serverUrl).host}';

/// Asks every account in [accounts] for its pending reminders, at most
/// [concurrency] at a time, and returns them soonest deadline first.
///
/// A failing account is recorded in [ReminderInbox.unreadableAccounts] and
/// never aborts the others: signing out of one account, or one server being
/// unreachable, must not empty a list the remaining accounts can still fill.
Future<ReminderInbox> loadReminderInbox({
  required List<StoredAccount> accounts,
  required UpcomingReminderLister lister,
  required ConversationNameLookup conversationName,
  int concurrency = reminderInboxFanOutLimit,
}) async {
  final rows = <ReminderInboxRow>[];
  final unreadable = <String>[];
  var next = 0;

  Future<void> worker() async {
    while (true) {
      // Single-threaded event loop: no other worker can observe this index
      // between the read and the increment.
      final index = next++;
      if (index >= accounts.length) {
        return;
      }
      final account = accounts[index];
      final label = reminderAccountLabel(account);
      final List<RichChatUpcomingReminder> reminders;
      try {
        reminders = await lister(account.id);
      } on Exception {
        // Deliberately only Exception: a signed-out account, a missing
        // credential, an unreachable server and a refusing server all arrive
        // as one, while a programming error stays a crash instead of quietly
        // turning into "this account is unavailable".
        unreadable.add(label);
        continue;
      }
      for (final reminder in reminders) {
        rows.add(
          ReminderInboxRow(
            accountId: account.id,
            accountLabel: label,
            conversationName: await conversationName(
              account.id,
              reminder.roomToken.value,
            ),
            reminder: reminder,
          ),
        );
      }
    }
  }

  await Future.wait(
    List<Future<void>>.generate(
      math.min(concurrency, accounts.length),
      (_) => worker(),
    ),
  );

  // Soonest first, then a total order so two accounts colliding on the same
  // token and message ID keep a stable, distinguishable place in the list.
  rows.sort((a, b) {
    final byDeadline = a.reminder.reminderTimestamp.compareTo(
      b.reminder.reminderTimestamp,
    );
    return byDeadline != 0 ? byDeadline : a.identity.compareTo(b.identity);
  });
  unreadable.sort();
  return ReminderInbox(rows: rows, unreadableAccounts: unreadable);
}

/// The reminder inbox with every side effect handed in, so the screen itself
/// holds nothing but the list and what the person does to it.
final class ReminderInboxScreen extends StatefulWidget {
  const ReminderInboxScreen({
    super.key,
    required this.accounts,
    required this.lister,
    required this.remover,
    required this.conversationName,
    required this.onOpen,
    this.concurrency = reminderInboxFanOutLimit,
  });

  final List<StoredAccount> accounts;
  final UpcomingReminderLister lister;
  final UpcomingReminderRemover remover;
  final ConversationNameLookup conversationName;
  final ValueChanged<ReminderInboxRow> onOpen;
  final int concurrency;

  @override
  State<ReminderInboxScreen> createState() => _ReminderInboxScreenState();
}

class _ReminderInboxScreenState extends State<ReminderInboxScreen> {
  var _generation = 0;
  var _loading = true;
  ReminderInbox? _inbox;

  /// Rows whose removal is in flight, so a second tap cannot send a second
  /// delete for the same reminder.
  final _removing = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final generation = ++_generation;
    // The first load starts from `initState`, which runs inside a build: the
    // field already says "loading", so only a refresh has anything to mark.
    if (!_loading) {
      setState(() => _loading = true);
    }
    final inbox = await loadReminderInbox(
      accounts: widget.accounts,
      lister: widget.lister,
      conversationName: widget.conversationName,
      concurrency: widget.concurrency,
    );
    if (!mounted || generation != _generation) {
      return;
    }
    setState(() {
      _inbox = inbox;
      _loading = false;
      _removing.clear();
    });
  }

  Future<void> _remove(ReminderInboxRow row) async {
    if (!_removing.add(row.identity)) {
      return;
    }
    setState(() {});
    final strings = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    var removed = true;
    try {
      await widget.remover(row);
    } on Exception {
      removed = false;
    }
    if (!mounted) {
      return;
    }
    if (removed) {
      final inbox = _inbox;
      setState(() {
        _removing.remove(row.identity);
        if (inbox != null) {
          _inbox = ReminderInbox(
            rows: inbox.rows.where(
              (candidate) => candidate.identity != row.identity,
            ),
            unreadableAccounts: inbox.unreadableAccounts,
          );
        }
      });
    } else {
      setState(() => _removing.remove(row.identity));
    }
    if (messenger?.mounted ?? false) {
      messenger!
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            key: Key(
              removed
                  ? 'reminder-inbox-removed'
                  : 'reminder-inbox-remove-failed',
            ),
            content: Text(
              removed
                  ? strings.reminderRemoved
                  : strings.reminderInboxRemoveFailed,
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Scaffold(
      key: const Key('reminder-inbox-screen'),
      appBar: AppBar(
        title: Text(strings.reminderInboxTitle),
        actions: [
          IconButton(
            key: const Key('reminder-inbox-refresh'),
            onPressed: _loading ? null : () => unawaited(_load()),
            tooltip: strings.refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _buildBody(context, strings),
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations strings) {
    if (_loading) {
      return const Center(
        key: Key('reminder-inbox-loading'),
        child: CircularProgressIndicator(),
      );
    }
    final inbox = _inbox;
    if (inbox == null || inbox.everythingFailed) {
      return Center(
        key: const Key('reminder-inbox-unavailable'),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            strings.reminderInboxUnavailable,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return Column(
      children: [
        if (inbox.unreadableAccounts.isNotEmpty)
          _UnreadableAccountsNotice(accounts: inbox.unreadableAccounts),
        Expanded(
          child: inbox.rows.isEmpty
              ? Center(
                  key: const Key('reminder-inbox-empty'),
                  child: Text(strings.reminderInboxEmpty),
                )
              : ListView.builder(
                  key: const Key('reminder-inbox-list'),
                  itemCount: inbox.rows.length,
                  itemBuilder: (context, index) {
                    final row = inbox.rows[index];
                    return _ReminderInboxTile(
                      row: row,
                      // The account only earns a line of its own once there is
                      // more than one to tell apart.
                      showAccount: widget.accounts.length > 1,
                      removing: _removing.contains(row.identity),
                      onOpen: () => widget.onOpen(row),
                      onRemove: () => unawaited(_remove(row)),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

final class _UnreadableAccountsNotice extends StatelessWidget {
  const _UnreadableAccountsNotice({required this.accounts});

  final List<String> accounts;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const Key('reminder-inbox-accounts-unavailable'),
      width: double.infinity,
      color: colors.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.cloud_off_outlined, color: colors.onSecondaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              strings.reminderInboxAccountsUnavailable(accounts.join(', ')),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colors.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class _ReminderInboxTile extends StatelessWidget {
  const _ReminderInboxTile({
    required this.row,
    required this.showAccount,
    required this.removing,
    required this.onOpen,
    required this.onRemove,
  });

  final ReminderInboxRow row;
  final bool showAccount;
  final bool removing;
  final VoidCallback onOpen;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final due = strings.reminderInboxDue(formatMoment(context, row.dueAt));
    final conversation = row.conversationName ?? row.roomToken;
    final author = row.reminder.actorDisplayName.trim().isEmpty
        ? row.reminder.actorId
        : row.reminder.actorDisplayName;
    final preview = row.reminder.preview;
    return ListTile(
      key: Key('reminder-inbox-row-${row.identity}'),
      isThreeLine: true,
      onTap: onOpen,
      title: Text(conversation, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(due, style: Theme.of(context).textTheme.labelMedium),
          Text(
            preview.isEmpty ? author : '$author: $preview',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (showAccount)
            Text(
              row.accountLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall,
            ),
        ],
      ),
      trailing: IconButton(
        key: Key('reminder-inbox-remove-${row.identity}'),
        onPressed: removing ? null : onRemove,
        tooltip: strings.reminderRemove,
        icon: const Icon(Icons.alarm_off_outlined),
      ),
    );
  }
}

/// Opens the reminder inbox.
void openReminderInbox(BuildContext context) {
  Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/reminders'),
      builder: (context) => const ReminderInboxRoute(),
    ),
  );
}

/// Wires the inbox to the app's repositories and to navigation.
final class ReminderInboxRoute extends ConsumerStatefulWidget {
  const ReminderInboxRoute({super.key, this.presentMessage = _pushChatRoom});

  /// How the reminded message is shown. Overridden only by tests.
  final ReminderMessagePresenter presentMessage;

  @override
  ConsumerState<ReminderInboxRoute> createState() => _ReminderInboxRouteState();
}

class _ReminderInboxRouteState extends ConsumerState<ReminderInboxRoute> {
  var _opening = false;

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(accountsProvider).valueOrNull;
    if (accounts == null) {
      return const Scaffold(
        key: Key('reminder-inbox-screen'),
        body: Center(
          key: Key('reminder-inbox-loading'),
          child: CircularProgressIndicator(),
        ),
      );
    }
    final service = ref.watch(chatMessageActionsServiceProvider);
    final repository = ref.watch(accountRepositoryProvider);
    return ReminderInboxScreen(
      accounts: accounts,
      lister: (accountId) =>
          service.listUpcomingReminders(accountId: accountId),
      remover: (row) => service.deleteUpcomingReminder(
        accountId: row.accountId,
        roomToken: row.roomToken,
        messageId: row.messageId,
      ),
      conversationName: (accountId, roomToken) async {
        final conversation = await repository.getConversation(
          accountId: accountId,
          token: roomToken,
        );
        return conversation?.displayName;
      },
      onOpen: (row) => unawaited(_open(row)),
    );
  }

  /// Opens the reminded message in the account that holds the reminder.
  ///
  /// The account is switched first, because the shell underneath this route
  /// tracks one selected account and the conversation belongs to whichever
  /// account the row names - not to whichever one happened to be on screen.
  Future<void> _open(ReminderInboxRow row) async {
    if (_opening) {
      return;
    }
    setState(() => _opening = true);
    try {
      final repository = ref.read(accountRepositoryProvider);
      final account = await repository.getAccount(row.accountId);
      final conversation = account == null
          ? null
          : await repository.getConversation(
              accountId: row.accountId,
              token: row.roomToken,
            );
      if (!mounted) {
        return;
      }
      if (account == null || conversation == null) {
        _reportMissingConversation();
        return;
      }
      if (ref.read(selectedAccountProvider).valueOrNull?.id != account.id) {
        await repository.selectAccount(account.id);
        if (!mounted) {
          return;
        }
      }
      await widget.presentMessage(
        context,
        account: account,
        conversation: conversation,
        messageId: row.messageId,
      );
    } finally {
      if (mounted) {
        setState(() => _opening = false);
      }
    }
  }

  void _reportMissingConversation() {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) {
      return;
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: const Key('reminder-inbox-conversation-missing'),
          content: Text(
            AppLocalizations.of(context).jumpToMessageConversationMissing,
          ),
        ),
      );
  }
}

Future<void> _pushChatRoom(
  BuildContext context, {
  required StoredAccount account,
  required CachedConversation conversation,
  required int messageId,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/reminders/message'),
      builder: (context) => PresenceChatRoomScreen(
        account: account,
        conversation: conversation,
        jumpToMessageId: messageId,
      ),
    ),
  );
}
