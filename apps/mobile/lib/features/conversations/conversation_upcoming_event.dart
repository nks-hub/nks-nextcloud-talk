import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import '../../data/app_database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../network/nextcloud_api.dart';

typedef ConversationUpcomingEventKey = ({String accountId, String roomToken});
typedef ConversationUpcomingEventLoader =
    Future<UpcomingTalkEvent?> Function(
      ConversationUpcomingEventKey key,
      Future<void> abortTrigger,
    );

final conversationUpcomingEventLoaderProvider =
    Provider<ConversationUpcomingEventLoader>((ref) {
      final accounts = ref.watch(accountRepositoryProvider);
      final credentials = ref.watch(credentialVaultProvider);
      final api = ref.watch(nextcloudApiProvider);
      return (key, abortTrigger) async {
        final account = await accounts.getAccount(key.accountId);
        final password = await credentials.readAppPassword(key.accountId);
        if (account == null || password == null) {
          return null;
        }
        final server = ServerBase.parse(account.serverUrl);
        final capabilities = await api.getAuthenticatedCapabilitiesWithSource(
          server: server,
          loginName: account.loginName,
          appPassword: password,
          abortTrigger: abortTrigger,
        );
        if (!capabilities.snapshot.supportsTalk('upcoming-reminders')) {
          return null;
        }
        return api.getUpcomingConversationEvent(
          server: server,
          loginName: account.loginName,
          appPassword: password,
          roomToken: key.roomToken,
          abortTrigger: abortTrigger,
        );
      };
    });

final class ConversationUpcomingEventBanner extends ConsumerStatefulWidget {
  const ConversationUpcomingEventBanner({
    required this.account,
    required this.conversation,
    super.key,
  });

  final StoredAccount account;
  final CachedConversation conversation;

  @override
  ConsumerState<ConversationUpcomingEventBanner> createState() =>
      _ConversationUpcomingEventBannerState();
}

final class _ConversationUpcomingEventBannerState
    extends ConsumerState<ConversationUpcomingEventBanner> {
  Completer<void>? _abort;
  Future<UpcomingTalkEvent?>? _event;
  String? _dismissedIdentity;
  var _generation = 0;

  ConversationUpcomingEventKey? get _key {
    final conversation = widget.conversation;
    final token = conversation.token;
    if (conversation.accountId != widget.account.id ||
        token.isEmpty ||
        token.runes.length > 512) {
      return null;
    }
    return (accountId: widget.account.id, roomToken: token);
  }

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(covariant ConversationUpcomingEventBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.id != widget.account.id ||
        oldWidget.conversation.accountId != widget.conversation.accountId ||
        oldWidget.conversation.token != widget.conversation.token) {
      _reload();
    }
  }

  void _reload() {
    _cancel();
    _generation++;
    _dismissedIdentity = null;
    final key = _key;
    if (key == null) {
      _event = Future<UpcomingTalkEvent?>.value();
      return;
    }
    final abort = _abort = Completer<void>();
    _event = ref.read(conversationUpcomingEventLoaderProvider)(
      key,
      abort.future,
    );
  }

  void _cancel() {
    final abort = _abort;
    if (abort != null && !abort.isCompleted) {
      abort.complete();
    }
    _abort = null;
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<UpcomingTalkEvent?>(
      key: ValueKey(_generation),
      future: _event,
      builder: (context, snapshot) {
        final event = snapshot.data;
        if (event == null || event.identity == _dismissedIdentity) {
          return const SizedBox.shrink();
        }
        return _UpcomingEventBanner(
          event: event,
          onDismiss: () => setState(() => _dismissedIdentity = event.identity),
        );
      },
    );
  }
}

final class _UpcomingEventBanner extends StatelessWidget {
  const _UpcomingEventBanner({required this.event, required this.onDismiss});

  final UpcomingTalkEvent event;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final localizations = MaterialLocalizations.of(context);
    final summary = event.summary?.trim().isNotEmpty == true
        ? event.summary!.trim()
        : strings.upcomingEventDefaultTitle;
    final localStart = event.start?.toLocal();
    final start = localStart == null
        ? null
        : '${localizations.formatMediumDate(localStart)}, '
              '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(localStart))}';
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const Key('conversation-upcoming-event'),
      width: double.infinity,
      color: colors.secondaryContainer,
      padding: const EdgeInsetsDirectional.only(
        start: 16,
        end: 4,
        top: 8,
        bottom: 8,
      ),
      child: Row(
        children: [
          Icon(Icons.event_outlined, color: colors.onSecondaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Semantics(
              label: <String>[summary, ?start].join(' '),
              excludeSemantics: true,
              child: DefaultTextStyle(
                style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                  color: colors.onSecondaryContainer,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      summary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    if (start != null)
                      Text(start, maxLines: 2, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            key: const Key('dismiss-upcoming-event'),
            onPressed: onDismiss,
            tooltip: strings.dismissUpcomingEvent,
            icon: const Icon(Icons.close),
            color: colors.onSecondaryContainer,
          ),
        ],
      ),
    );
  }
}
