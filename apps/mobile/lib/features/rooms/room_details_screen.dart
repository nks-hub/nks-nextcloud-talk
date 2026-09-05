import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mime/mime.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../app_providers.dart';
import '../../core/desktop_metrics.dart';
import '../../core/text_prompt_dialog.dart';
import '../../data/app_database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../platform/media/image_attachment_picker.dart';
import '../chat/chat_participant_avatar.dart';
import '../chat/chat_background_surface.dart';
import '../chat/chat_background_theme.dart';
import '../conversations/conversation_avatar_widget.dart';
import '../shareditems/shared_items_screen.dart';
import 'bots_service.dart';
import 'conversation_tags_service.dart';
import 'guest_link_sharer.dart';
import 'participants_service.dart';
import 'room_settings_service.dart';

part 'room_details_actions.part.dart';
part 'room_details_background.part.dart';
part 'room_details_bots.part.dart';
part 'room_details_clear_history.part.dart';
part 'room_details_conversation_tags.part.dart';
part 'room_details_importance_sensitivity.part.dart';
part 'room_details_message_expiration.part.dart';
part 'room_details_shared_items.part.dart';
part 'room_details_sip.part.dart';
part 'room_details_support.part.dart';
part 'room_details_widgets.part.dart';

const int _roomTypeOneToOne = 1;
const int _roomTypeGroup = 2;
const int _roomTypePublic = 3;
const int _roomTypeChangelog = 4;
const int _roomTypeFormerOneToOne = 5;
const int _roomTypeNoteToSelf = 6;

const int _notificationDefault = 0;
const int _notificationAlways = 1;
const int _notificationMention = 2;
const int _notificationNever = 3;

/// Talk capability names that gate the administration actions, from
/// `docs/capabilities.md`: `avatar` (Talk 17), `read-only-rooms` (6.0),
/// `webinary-lobby` (7.0), `sip-support` / `sip-support-nopin` and `ban-v1`
/// (20). Making a conversation public and setting its password need no
/// capability at all.
const String _avatarCapability = 'avatar';
const String _readOnlyCapability = 'read-only-rooms';
const String _lobbyCapability = 'webinary-lobby';
const String _breakoutCapability = 'breakout-rooms-v1';
const String _breakoutObjectType = 'room';
const String _sipCapability = 'sip-support';
const String _sipNoPinCapability = 'sip-support-nopin';
const String _banCapability = 'ban-v1';
const String _messageExpirationCapability = 'message-expiration';
const String _clearHistoryCapability = 'clear-history';
const String _conversationTagsCapability = 'conversation-tags';
const String _importantCapability = 'important-conversations';
const String _sensitiveCapability = 'sensitive-conversations';
const String _sharedItemsCapability = 'rich-object-list-media';
const String _federatedSharedItemsCapability = 'federated-shared-items';
const String _botsCapability = 'bots-v1';
const int _classifiedRoomAttribute = 4;

/// The emoji the avatar picker offers. Talk accepts any single emoji; this is
/// a short, keyboard-free shortlist rather than a full picker.
// ponytail: a fixed grid, not an emoji keyboard — swap in a picker package if
// users ask for the full set.
const List<String> _avatarEmoji = <String>[
  '\u{1F4AC}',
  '\u{1F680}',
  '\u{1F4C5}',
  '\u{1F389}',
  '\u{1F4DA}',
  '\u{1F527}',
  '\u{1F3AF}',
  '\u{2615}',
  '\u{1F4C8}',
  '\u{1F510}',
  '\u{1F30D}',
  '\u{2764}',
];

/// What a moderator can do to one attendee from the participant menu: the
/// three participant-moderation endpoints plus a ban, which is a different
/// API but belongs in the same place.
enum ParticipantAction { promote, demote, remove, ban }

/// Conversation details: room metadata, the moderator-gated settings
/// actions (rename, description, notification level, favorite, avatar,
/// public/private, password, message expiration, lobby, SIP, read-only, leave,
/// delete) and the participant list with each attendee's role, status and
/// moderation menu.
final class RoomDetailsScreen extends ConsumerStatefulWidget {
  const RoomDetailsScreen({
    super.key,
    required this.account,
    required this.conversation,
    this.linkSharer = const PlatformGuestLinkSharer(),
    this.imagePicker = const PlatformAttachmentSelectionBackend(),
    this.onClose,
  });

  final StoredAccount account;
  final CachedConversation conversation;

  /// Renders as a panel with its own close affordance instead of a route with
  /// an app bar. The caller decides which it is, because only the caller knows
  /// whether the window has room for a third column.
  final VoidCallback? onClose;

  /// The system share sheet, which no widget test can reach; replaced there.
  final GuestLinkSharer linkSharer;

  /// The gallery picker, which is a platform channel; replaced in tests.
  final ImageSelectionBackend imagePicker;

  @override
  ConsumerState<RoomDetailsScreen> createState() => _RoomDetailsScreenState();
}

final class _RoomDetailsScreenState extends ConsumerState<RoomDetailsScreen>
    with
        _RoomDetailsStateLogic,
        _RoomSipStateLogic,
        _RoomImportanceSensitivityStateLogic,
        _RoomBotsStateLogic {
  void _setBusy(bool value) {
    setState(() => _busy = value);
  }

  void _setAuthoritativeRoom(ConversationRoom room) {
    setState(() => _room = room);
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final onClose = widget.onClose;
    if (onClose != null) {
      return Material(
        key: const Key('room-details-panel'),
        color: Theme.of(context).colorScheme.surface,
        child: Column(
          children: [
            Container(
              constraints: BoxConstraints(minHeight: context.paneHeaderHeight),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(
                        strings.roomDetailsTitle,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('close-room-details'),
                    tooltip: MaterialLocalizations.of(context).closeButtonLabel,
                    icon: const Icon(Icons.close_rounded),
                    onPressed: onClose,
                  ),
                ],
              ),
            ),
            Expanded(child: _body(context)),
          ],
        ),
      );
    }
    return Scaffold(
      key: const Key('room-details-screen'),
      appBar: AppBar(title: Text(strings.roomDetailsTitle)),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final backgroundKey = (
      accountId: widget.account.id,
      roomToken: widget.conversation.token,
    );
    final background = ref
        .watch(chatBackgroundProvider(backgroundKey))
        .valueOrNull;
    return ContentColumn(
      child: ListView(
        children: [
          _RoomSummary(
            account: widget.account,
            conversation: _summaryConversation,
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              strings.roomDetailsActionsHeader,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          if (_canEditRoomMetadata)
            ListTile(
              key: const Key('room-details-rename'),
              leading: const Icon(Icons.edit_outlined),
              title: Text(strings.roomDetailsRenameAction),
              onTap: _busy ? null : _renameRoom,
            ),
          if (_canEditRoomMetadata)
            ListTile(
              key: const Key('room-details-description-edit'),
              leading: const Icon(Icons.short_text),
              title: Text(strings.roomDetailsDescriptionEditAction),
              onTap: _busy ? null : _editDescription,
            ),
          ListTile(
            key: const Key('room-details-notification-picker'),
            leading: const Icon(Icons.notifications_outlined),
            title: Text(strings.roomDetailsNotificationLabel),
            subtitle: Text(
              _notificationLabel(strings, _notificationLevel),
              key: const Key('room-details-notification-subtitle'),
            ),
            onTap: _busy ? null : _changeNotificationLevel,
          ),
          if (_room != null)
            SwitchListTile(
              key: const Key('room-details-call-notifications-toggle'),
              secondary: const Icon(Icons.call_outlined),
              title: Text(strings.roomDetailsCallNotificationsLabel),
              subtitle: Text(strings.roomDetailsCallNotificationsSubtitle),
              value: _callNotificationsEnabled,
              onChanged: _busy ? null : _toggleCallNotifications,
            ),
          if (_canSetImportant)
            SwitchListTile(
              key: const Key('room-details-important-toggle'),
              secondary: const Icon(Icons.priority_high),
              title: Text(strings.roomDetailsImportantLabel),
              subtitle: Text(strings.roomDetailsImportantSubtitle),
              value: _room!.isImportant,
              onChanged: _busy ? null : _toggleImportant,
            ),
          if (_canSetSensitive)
            SwitchListTile(
              key: const Key('room-details-sensitive-toggle'),
              secondary: const Icon(Icons.visibility_off_outlined),
              title: Text(strings.roomDetailsSensitiveLabel),
              subtitle: Text(
                _isClassified
                    ? strings.roomDetailsSensitiveClassifiedSubtitle
                    : strings.roomDetailsSensitiveSubtitle,
              ),
              value: _room!.isSensitive,
              onChanged: _busy || _isClassified ? null : _toggleSensitive,
            ),
          if (_canSetMessageExpiration)
            ListTile(
              key: const Key('room-details-message-expiration'),
              leading: const Icon(Icons.auto_delete_outlined),
              title: Text(strings.roomDetailsMessageExpirationLabel),
              subtitle: Text(
                _messageExpirationLabel(strings, _messageExpirationSeconds),
                key: const Key('room-details-message-expiration-subtitle'),
              ),
              onTap: _busy ? null : _changeMessageExpiration,
            ),
          if (_canOpenSharedItems)
            ListTile(
              key: const Key('room-details-shared-items'),
              leading: const Icon(Icons.collections_outlined),
              title: Text(strings.roomDetailsSharedItemsAction),
              trailing: const Icon(Icons.chevron_right),
              onTap: _openSharedItems,
            ),
          if (_canManageConversationTags)
            ListTile(
              key: const Key('room-details-conversation-tags'),
              leading: const Icon(Icons.label_outline),
              title: Text(strings.roomDetailsConversationTagsAction),
              subtitle: Text(
                strings.roomDetailsConversationTagsSelectedCount(
                  _room!.tagIds.length,
                ),
                key: const Key('room-details-conversation-tags-subtitle'),
              ),
              onTap: _busy ? null : _manageConversationTags,
            ),
          SwitchListTile(
            key: const Key('room-details-favorite-toggle'),
            secondary: const Icon(Icons.star_outline),
            title: Text(strings.roomDetailsFavoriteLabel),
            value: _isFavorite,
            onChanged: _busy ? null : _toggleFavorite,
          ),
          ListTile(
            key: const Key('room-details-chat-background'),
            leading: const Icon(Icons.wallpaper_outlined),
            title: Text(strings.roomDetailsChatBackgroundAction),
            subtitle: Text(
              background ?? strings.roomDetailsAvatarColorDefault,
              key: const Key('room-details-chat-background-subtitle'),
            ),
            trailing: background == null
                ? null
                : IconButton(
                    key: const Key('room-details-chat-background-reset'),
                    tooltip: strings.roomDetailsAvatarColorDefault,
                    icon: const Icon(Icons.brightness_auto_rounded),
                    onPressed: _busy ? null : _resetChatBackground,
                  ),
            onTap: _busy ? null : _changeChatBackground,
          ),
          if (_canSetAvatar)
            ListTile(
              key: const Key('room-details-avatar'),
              leading: const Icon(Icons.photo_outlined),
              title: Text(strings.roomDetailsAvatarAction),
              onTap: _busy ? null : _changeAvatar,
            ),
          if (_canRemoveAvatar)
            ListTile(
              key: const Key('room-details-avatar-remove'),
              leading: const Icon(Icons.hide_image_outlined),
              title: Text(strings.roomDetailsAvatarRemoveAction),
              onTap: _busy ? null : _removeAvatar,
            ),
          if (_canToggleGuests)
            SwitchListTile(
              key: const Key('room-details-guests-toggle'),
              secondary: const Icon(Icons.public),
              title: Text(strings.roomDetailsGuestsLabel),
              subtitle: Text(
                _isPublic
                    ? strings.roomDetailsGuestsAllowed
                    : strings.roomDetailsGuestsBlocked,
                key: const Key('room-details-guests-subtitle'),
              ),
              value: _isPublic,
              onChanged: _busy ? null : _toggleGuests,
            ),
          if (_isPublic)
            ListTile(
              key: const Key('room-details-invite-link'),
              leading: const Icon(Icons.link),
              title: Text(strings.roomDetailsInviteLinkAction),
              subtitle: Text(strings.roomDetailsInviteLinkSubtitle),
              onTap: _busy ? null : _shareGuestLink,
            ),
          if (_canSetPassword)
            ListTile(
              key: const Key('room-details-password'),
              leading: const Icon(Icons.password_outlined),
              title: Text(strings.roomDetailsPasswordLabel),
              subtitle: Text(
                _hasPassword
                    ? strings.roomDetailsPasswordSet
                    : strings.roomDetailsPasswordUnset,
                key: const Key('room-details-password-subtitle'),
              ),
              onTap: _busy ? null : _setPassword,
            ),
          if (_canSetPassword && _hasPassword)
            ListTile(
              key: const Key('room-details-password-remove'),
              leading: const Icon(Icons.lock_open_outlined),
              title: Text(strings.roomDetailsPasswordRemoveAction),
              onTap: _busy ? null : _removePassword,
            ),
          if (_canSetLobby)
            SwitchListTile(
              key: const Key('room-details-lobby-toggle'),
              secondary: const Icon(Icons.meeting_room_outlined),
              title: Text(strings.roomDetailsLobbyLabel),
              subtitle: Text(
                _lobbyLabel(strings),
                key: const Key('room-details-lobby-subtitle'),
              ),
              value: _lobbyState != 0,
              onChanged: _busy ? null : _toggleLobby,
            ),
          if (_canManageBreakoutRooms)
            ListTile(
              key: const Key('room-details-breakout'),
              leading: const Icon(Icons.groups_2_outlined),
              title: Text(strings.roomDetailsBreakoutLabel),
              subtitle: Text(
                _breakoutLabel(strings),
                key: const Key('room-details-breakout-subtitle'),
              ),
              onTap: _busy ? null : _manageBreakoutRooms,
            ),
          if (_canSwitchBreakoutRoom)
            ListTile(
              key: const Key('room-details-breakout-switch'),
              leading: const Icon(Icons.swap_horiz_rounded),
              title: Text(strings.roomDetailsBreakoutSwitch),
              onTap: _busy ? null : _switchBreakoutRoom,
            ),
          if (_isBreakoutRoom)
            ListTile(
              key: const Key('room-details-breakout-assistance'),
              leading: const Icon(Icons.support_agent_outlined),
              title: Text(
                _breakoutStatus == 2
                    ? strings.roomDetailsBreakoutWithdrawAssistance
                    : strings.roomDetailsBreakoutRequestAssistance,
              ),
              onTap: _busy ? null : _toggleBreakoutAssistance,
            ),
          if (_canSetSip)
            ListTile(
              key: const Key('room-details-sip'),
              leading: const Icon(Icons.dialpad_outlined),
              title: Text(strings.roomDetailsSipLabel),
              subtitle: Text(
                _sipLabel(strings),
                key: const Key('room-details-sip-subtitle'),
              ),
              onTap: _busy ? null : _changeSip,
            ),
          if (_showsSipDialIn) _buildSipDialInPanel(context),
          if (_canSetReadOnly)
            SwitchListTile(
              key: const Key('room-details-read-only-toggle'),
              secondary: const Icon(Icons.edit_off_outlined),
              title: Text(strings.roomDetailsReadOnlyToggleLabel),
              subtitle: Text(
                _readOnly != 0
                    ? strings.roomDetailsReadOnlyToggleOn
                    : strings.roomDetailsReadOnlyToggleOff,
                key: const Key('room-details-read-only-subtitle'),
              ),
              value: _readOnly != 0,
              onChanged: _busy ? null : _toggleReadOnly,
            ),
          if (_canManageBots) _buildBotsSection(context),
          if (_canBan)
            ListTile(
              key: const Key('room-details-bans'),
              leading: const Icon(Icons.block_outlined),
              title: Text(strings.roomDetailsBansAction),
              onTap: _busy ? null : _showBans,
            ),
          if (_canClearHistory)
            ListTile(
              key: const Key('room-details-clear-history'),
              leading: Icon(
                Icons.delete_sweep_outlined,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                strings.roomDetailsClearHistoryAction,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: _busy ? null : _confirmClearHistory,
            ),
          if (_canLeave)
            ListTile(
              key: const Key('room-details-leave'),
              leading: Icon(
                Icons.logout,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                strings.roomDetailsLeaveAction,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: _busy ? null : _confirmLeave,
            ),
          if (_canDelete)
            ListTile(
              key: const Key('room-details-delete'),
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                strings.roomDetailsDeleteAction,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: _busy ? null : _confirmDelete,
            ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    strings.roomDetailsParticipantsHeader,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                // Adding someone was missing entirely until 5 September 2026:
                // the list could be read and its attendees moderated, but
                // nobody could be let in.
                if (_isModerator)
                  TextButton.icon(
                    key: const Key('room-details-add-participant'),
                    onPressed: _busy ? null : _addParticipant,
                    icon: const Icon(Icons.person_add_alt_1_rounded),
                    label: Text(strings.roomDetailsAddParticipant),
                  ),
              ],
            ),
          ),
          FutureBuilder<List<Participant>>(
            key: const Key('room-details-participants'),
            future: _participants,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (snapshot.hasError) {
                return _ParticipantsError(onRetry: _retry);
              }
              final participants = snapshot.data ?? const <Participant>[];
              if (participants.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(strings.roomDetailsParticipantsEmpty),
                );
              }
              return Column(
                children: [
                  for (final participant in participants)
                    _ParticipantTile(
                      account: widget.account,
                      participant: participant,
                      actions: _availableActions(participant),
                      onAction: _busy
                          ? null
                          : (action) =>
                                _runParticipantAction(participant, action),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
