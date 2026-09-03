import 'dart:async';

import 'package:flutter/material.dart';
import 'package:talk_protocol/talk_protocol.dart' show FederationInvitation;

import '../../l10n/generated/app_localizations.dart';

/// Decides one invitation. Returns the message to show; the caller (the
/// shell) talks to the service, refreshes the list and opens the room.
typedef FederationInvitationDecision =
    Future<String> Function(
      FederationInvitation invitation, {
      required bool accept,
    });

/// Strip above the conversation list naming how many invitations from other
/// servers wait for a decision; absent when there are none, so a
/// single-server setup never sees it. Pure: the shell hands the list in.
final class FederationInvitationStrip extends StatelessWidget {
  const FederationInvitationStrip({
    super.key,
    required this.invitations,
    required this.onDecide,
  });

  final List<FederationInvitation> invitations;
  final FederationInvitationDecision onDecide;

  @override
  Widget build(BuildContext context) {
    if (invitations.isEmpty) {
      return const SizedBox.shrink();
    }
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Material(
        key: const Key('federation-invitation-strip'),
        color: scheme.tertiaryContainer,
        child: InkWell(
          onTap: () => _showSheet(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Icon(Icons.hub_rounded, color: scheme.onTertiaryContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    strings.federationInvitationsCount(invitations.length),
                    style: TextStyle(color: scheme.onTertiaryContainer),
                  ),
                ),
                TextButton(
                  key: const Key('federation-invitations-show'),
                  style: TextButton.styleFrom(
                    foregroundColor: scheme.onTertiaryContainer,
                  ),
                  onPressed: () => _showSheet(context),
                  child: Text(strings.federationInvitationsShow),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showSheet(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _FederationInvitationSheet(
        invitations: invitations,
        onDecide: onDecide,
      ),
    );
  }
}

final class _FederationInvitationSheet extends StatefulWidget {
  const _FederationInvitationSheet({
    required this.invitations,
    required this.onDecide,
  });

  final List<FederationInvitation> invitations;
  final FederationInvitationDecision onDecide;

  @override
  State<_FederationInvitationSheet> createState() =>
      _FederationInvitationSheetState();
}

final class _FederationInvitationSheetState
    extends State<_FederationInvitationSheet> {
  int? _busyId;
  final Set<int> _decided = <int>{};

  Future<void> _decide(FederationInvitation invitation, bool accept) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final navigator = Navigator.of(context);
    setState(() => _busyId = invitation.id);
    final notice = await widget.onDecide(invitation, accept: accept);
    if (!mounted) {
      return;
    }
    setState(() {
      _busyId = null;
      _decided.add(invitation.id);
    });
    messenger?.showSnackBar(SnackBar(content: Text(notice)));
    // An accepted room is being opened by the shell; the sheet is in the way.
    if (accept && navigator.canPop()) {
      navigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final items = widget.invitations
        .where((invitation) => !_decided.contains(invitation.id))
        .toList(growable: false);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                strings.federationInvitationsTitle,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                child: Text(strings.federationInvitationsEmpty),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final invitation = items[index];
                    final busy = _busyId == invitation.id;
                    final inviter = invitation.inviterDisplayName.isEmpty
                        ? invitation.inviterCloudId
                        : invitation.inviterDisplayName;
                    return ListTile(
                      key: Key('federation-invitation-${invitation.id}'),
                      leading: const Icon(Icons.hub_rounded),
                      title: Text(
                        invitation.roomName.isEmpty
                            ? invitation.remoteToken
                            : invitation.roomName,
                      ),
                      subtitle: Text(
                        strings.federationInvitationFrom(
                          inviter,
                          invitation.remoteServerUrl,
                        ),
                      ),
                      isThreeLine: true,
                      trailing: busy
                          ? const SizedBox.square(
                              dimension: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Wrap(
                              spacing: 4,
                              children: [
                                IconButton(
                                  key: Key(
                                    'federation-invitation-decline-'
                                    '${invitation.id}',
                                  ),
                                  tooltip: strings.federationInvitationDecline,
                                  onPressed: _busyId != null
                                      ? null
                                      : () => unawaited(
                                          _decide(invitation, false),
                                        ),
                                  icon: const Icon(Icons.close_rounded),
                                ),
                                IconButton.filled(
                                  key: Key(
                                    'federation-invitation-accept-'
                                    '${invitation.id}',
                                  ),
                                  tooltip: strings.federationInvitationAccept,
                                  onPressed: _busyId != null
                                      ? null
                                      : () => unawaited(
                                          _decide(invitation, true),
                                        ),
                                  icon: const Icon(Icons.check_rounded),
                                ),
                              ],
                            ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
