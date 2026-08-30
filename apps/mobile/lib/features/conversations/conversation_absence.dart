import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import '../../data/app_database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../network/nextcloud_api.dart';

typedef ConversationAbsenceKey = ({String accountId, String userId});
typedef ConversationAbsenceLoader =
    Future<CurrentOutOfOffice?> Function(
      ConversationAbsenceKey key,
      Future<void> abortTrigger,
    );

final conversationAbsenceLoaderProvider = Provider<ConversationAbsenceLoader>((
  ref,
) {
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
    final dav = capabilities.snapshot.capabilities['dav'];
    if (dav is! Map<String, Object?> || dav['absence-supported'] != true) {
      return null;
    }
    return api.getCurrentOutOfOffice(
      server: server,
      loginName: account.loginName,
      appPassword: password,
      userId: key.userId,
      abortTrigger: abortTrigger,
    );
  };
});

final class ConversationAbsenceBanner extends ConsumerStatefulWidget {
  const ConversationAbsenceBanner({
    required this.account,
    required this.conversation,
    super.key,
  });

  final StoredAccount account;
  final CachedConversation conversation;

  @override
  ConsumerState<ConversationAbsenceBanner> createState() =>
      _ConversationAbsenceBannerState();
}

final class _ConversationAbsenceBannerState
    extends ConsumerState<ConversationAbsenceBanner> {
  Completer<void>? _abort;
  Future<CurrentOutOfOffice?>? _absence;

  ConversationAbsenceKey? get _key {
    final conversation = widget.conversation;
    if (conversation.accountId != widget.account.id ||
        conversation.roomType != 1 ||
        conversation.roomName.trim().isEmpty) {
      return null;
    }
    return (accountId: widget.account.id, userId: conversation.roomName.trim());
  }

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(covariant ConversationAbsenceBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.id != widget.account.id ||
        oldWidget.conversation.accountId != widget.conversation.accountId ||
        oldWidget.conversation.roomType != widget.conversation.roomType ||
        oldWidget.conversation.roomName != widget.conversation.roomName) {
      _reload();
    }
  }

  void _reload() {
    _cancel();
    final key = _key;
    if (key == null) {
      _absence = Future<CurrentOutOfOffice?>.value();
      return;
    }
    final abort = _abort = Completer<void>();
    _absence = ref.read(conversationAbsenceLoaderProvider)(key, abort.future);
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
    return FutureBuilder<CurrentOutOfOffice?>(
      future: _absence,
      builder: (context, snapshot) {
        final absence = snapshot.data;
        return absence == null
            ? const SizedBox.shrink()
            : _AbsenceBanner(
                absence: absence,
                displayName: widget.conversation.displayName,
              );
      },
    );
  }
}

final class _AbsenceBanner extends StatelessWidget {
  const _AbsenceBanner({required this.absence, required this.displayName});

  final CurrentOutOfOffice absence;
  final String displayName;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final dates = MaterialLocalizations.of(context);
    final replacement = absence.replacementUserDisplayName?.trim();
    final message = absence.message.trim().isNotEmpty
        ? absence.message.trim()
        : absence.shortMessage.trim();
    final period = strings.absencePeriod(
      dates.formatShortDate(absence.start.toLocal()),
      dates.formatShortDate(absence.end.toLocal()),
    );
    return Semantics(
      container: true,
      label: <String>[
        strings.outOfOffice(displayName),
        period,
        if (message.isNotEmpty) message,
        if (replacement?.isNotEmpty == true)
          strings.absenceReplacement(replacement!),
      ].join(' '),
      excludeSemantics: true,
      child: Container(
        key: const Key('conversation-absence-banner'),
        width: double.infinity,
        color: Theme.of(context).colorScheme.tertiaryContainer,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.event_busy_outlined,
              color: Theme.of(context).colorScheme.onTertiaryContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DefaultTextStyle(
                style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                  color: Theme.of(context).colorScheme.onTertiaryContainer,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      strings.outOfOffice(displayName),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(period),
                    if (message.isNotEmpty)
                      Text(
                        message,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    if (replacement?.isNotEmpty == true)
                      Text(
                        strings.absenceReplacement(replacement!),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
