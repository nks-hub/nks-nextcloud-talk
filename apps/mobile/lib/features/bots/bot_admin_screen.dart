import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../l10n/generated/app_localizations.dart';
import '../chat/chat_pin_reminder_schedule.dart' show formatMoment;
import 'bot_admin_service.dart';

/// Every bot installed on one account's server, with the health the server
/// reports for it. Reached from Settings, and offered only where the server
/// publishes `bots-v1`.
///
/// Nothing here is editable. A bot's secret and the full webhook address never
/// reach this screen at all - the decoder keeps only the address's host - so
/// the whole screen is safe to read out during a support call.
final class BotAdminScreen extends ConsumerWidget {
  const BotAdminScreen({required this.accountId, super.key});

  final String accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = AppLocalizations.of(context);
    final listing = ref.watch(botAdminListingProvider(accountId));

    return Scaffold(
      appBar: AppBar(
        title: Text(strings.settingsOpenBotAdmin),
        actions: [
          IconButton(
            key: const Key('bot-admin-refresh'),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: strings.diagnosticsRefresh,
            onPressed: () => ref.invalidate(botAdminListingProvider(accountId)),
          ),
        ],
      ),
      body: listing.when(
        data: (data) => _BotList(data),
        // Deliberately not an indeterminate spinner: it animates forever and
        // wedges any pumpAndSettle. The request is one round trip.
        loading: () => const SizedBox(height: 24),
        error: (error, stackTrace) => _BotAdminFailure(error),
      ),
    );
  }
}

final class _BotList extends StatelessWidget {
  const _BotList(this.listing);

  final BotAdminListing listing;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    if (listing.bots.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(key: const Key('bot-admin-empty'), strings.botAdminEmpty),
      );
    }
    return ListView(
      children: [
        for (final bot in listing.bots) _BotTile(bot),
        if (listing.truncated)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              key: const Key('bot-admin-truncated'),
              strings.botAdminTruncated(listing.bots.length),
            ),
          ),
      ],
    );
  }
}

final class _BotTile extends StatelessWidget {
  const _BotTile(this.bot);

  final AdminBot bot;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final switchedOff = bot.state == BotState.unavailable;
    final reason = bot.lastErrorMessage;
    return ListTile(
      key: Key('bot-admin-row-${bot.id}'),
      isThreeLine: true,
      leading: Icon(
        switch (bot.state) {
          // A switched-off app is not a bot that is breaking, so it does not
          // get the failure icon.
          BotState.unavailable => Icons.extension_off_outlined,
          _ when bot.isFailing => Icons.error_outline_rounded,
          _ => Icons.smart_toy_outlined,
        },
        color: bot.isFailing ? scheme.error : scheme.outline,
      ),
      title: Text(bot.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_stateLabel(strings, bot.state)),
          Text(
            bot.urlHost == null
                ? strings.botAdminWebhookHostUnknown
                : strings.botAdminWebhookHost(bot.urlHost!),
          ),
          // The server's own words for why, and nothing else: for this state it
          // invents the count and dates the failure to the moment of the
          // request, so neither may be shown as if it were measured.
          if (switchedOff && reason != null)
            Text(key: Key('bot-admin-switched-off-${bot.id}'), reason),
          // A bot that has never failed gets no error area at all, rather than
          // an empty one that reads as a missing value.
          if (bot.isFailing) _BotFailure(bot),
        ],
      ),
    );
  }
}

final class _BotFailure extends StatelessWidget {
  const _BotFailure(this.bot);

  final AdminBot bot;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final lastErrorAt = bot.lastErrorAt;
    final reason = bot.lastErrorMessage;
    return Column(
      key: Key('bot-admin-failure-${bot.id}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          strings.botAdminFailures(bot.errorCount),
          style: TextStyle(color: scheme.error),
        ),
        // The server sends `last_error_date: 0` for a bot it counted an error
        // for without recording when, so the moment stays optional even here.
        if (lastErrorAt != null)
          Text(strings.botAdminLastFailure(formatMoment(context, lastErrorAt))),
        if (reason != null) Text(reason),
      ],
    );
  }
}

/// Why the list is not on screen. `403` is the case that matters: it is the
/// server working exactly as designed, so it says what is true about this
/// account instead of reporting a fault.
final class _BotAdminFailure extends StatelessWidget {
  const _BotAdminFailure(this.error);

  final Object error;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final code = error is BotAdminException
        ? (error as BotAdminException).code
        : null;
    final (key, message) = switch (code) {
      BotAdminError.notAdministrator => (
        'bot-admin-not-administrator',
        strings.botAdminNotAdministrator,
      ),
      BotAdminError.unsupported => (
        'bot-admin-unsupported',
        strings.botAdminUnsupported,
      ),
      BotAdminError.reauthenticationRequired => (
        'bot-admin-sign-in-again',
        strings.reauthenticateAccountTitle,
      ),
      BotAdminError.rateLimited => (
        'bot-admin-rate-limited',
        strings.profileErrorRateLimited,
      ),
      _ => ('bot-admin-load-failed', strings.botAdminUnavailable),
    };
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Text(key: Key(key), message),
    );
  }
}

String _stateLabel(AppLocalizations strings, BotState state) => switch (state) {
  BotState.enabled => strings.roomDetailsBotEnabled,
  BotState.disabled => strings.roomDetailsBotDisabled,
  BotState.noSetup => strings.botAdminStateNoSetup,
  BotState.unavailable => strings.botAdminStateUnavailable,
};
