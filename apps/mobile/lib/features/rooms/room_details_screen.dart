import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:talk_protocol/talk_protocol.dart';

import '../../data/app_database.dart';
import '../../l10n/generated/app_localizations.dart';
import '../chat/chat_participant_avatar.dart';
import '../conversations/conversation_avatar_widget.dart';
import 'guest_link_sharer.dart';
import 'participants_service.dart';
import 'room_settings_service.dart';

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
/// `webinary-lobby` (7.0) and `ban-v1` (20). Making a conversation public and
/// setting its password need no capability at all.
const String _avatarCapability = 'avatar';
const String _readOnlyCapability = 'read-only-rooms';
const String _lobbyCapability = 'webinary-lobby';
const String _banCapability = 'ban-v1';

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
/// public/private, password, lobby, read-only, leave, delete) and the
/// participant list with each attendee's role, status and moderation menu.
final class RoomDetailsScreen extends ConsumerStatefulWidget {
  const RoomDetailsScreen({
    super.key,
    required this.account,
    required this.conversation,
    this.linkSharer = const PlatformGuestLinkSharer(),
  });

  final StoredAccount account;
  final CachedConversation conversation;

  /// The system share sheet, which no widget test can reach; replaced there.
  final GuestLinkSharer linkSharer;

  @override
  ConsumerState<RoomDetailsScreen> createState() => _RoomDetailsScreenState();
}

final class _RoomDetailsScreenState extends ConsumerState<RoomDetailsScreen> {
  late Future<List<Participant>> _participants;
  late ConversationRoom? _room;
  late bool _isFavorite;
  late int _notificationLevel;
  bool _busy = false;

  late Set<String> _talkFeatures;

  @override
  void initState() {
    super.initState();
    _participants = _load();
    _room = _parseCachedRoom(widget.conversation);
    _isFavorite = widget.conversation.favorite;
    _notificationLevel = _room?.notificationLevel ?? _notificationDefault;
    _talkFeatures = _decodeTalkFeatures(widget.account.talkFeaturesJson);
  }

  Future<List<Participant>> _load() {
    return ref
        .read(participantsServiceProvider)
        .fetchParticipants(
          accountId: widget.account.id,
          roomToken: widget.conversation.token,
        );
  }

  void _retry() {
    setState(() {
      _participants = _load();
    });
  }

  /// Owners, moderators and guest moderators may rename the conversation and
  /// change its description; a plain participant must never see these.
  bool get _isModerator {
    return switch (participantRoleFor(_room?.participantType ?? -1)) {
      ParticipantRole.owner ||
      ParticipantRole.moderator ||
      ParticipantRole.guestModerator => true,
      _ => false,
    };
  }

  /// The server is the source of truth for whether leaving is currently
  /// allowed (e.g. it is refused for the last moderator); default to hidden
  /// when that could not be determined from the cached room.
  bool get _canLeave => _room?.canLeaveConversation ?? false;

  /// The server decides who may delete a conversation for everyone: it is
  /// refused without moderator rights and in one-to-one conversations, and
  /// reports that as `canDeleteConversation`. Hidden when the cached room
  /// could not be parsed, and paired with the local moderator check so a
  /// plain participant never sees the action.
  bool get _canDelete =>
      _isModerator && (_room?.canDeleteConversation ?? false);

  int get _roomType => _room?.type ?? widget.conversation.roomType;

  bool get _isPublic => _roomType == _roomTypePublic;

  /// The three administration endpoints the server only accepts for group and
  /// public conversations. Talk answers `400` for every other type on
  /// read-only and lobby ("only group and public conversation"), and
  /// `BanService::createBan` throws `InvalidArgumentException('room')` unless
  /// the room is `TYPE_GROUP` or `TYPE_PUBLIC`.
  bool get _isGroupOrPublic =>
      _roomType == _roomTypeGroup || _roomType == _roomTypePublic;

  /// Making a conversation public is only offered for a group conversation,
  /// and making it private only for a public one — the server answers `400`
  /// for the other direction.
  bool get _canToggleGuests => _isModerator && _isGroupOrPublic;

  /// A password only exists on a public conversation: Talk answers `403`
  /// "When the conversation is not a public conversation".
  bool get _canSetPassword => _isModerator && _isPublic;

  bool get _canSetReadOnly =>
      _isModerator &&
      _isGroupOrPublic &&
      _talkFeatures.contains(_readOnlyCapability);

  bool get _canSetLobby =>
      _isModerator &&
      _isGroupOrPublic &&
      _talkFeatures.contains(_lobbyCapability);

  /// The avatar endpoints refuse a one-to-one conversation with `400`, so the
  /// action stays hidden there even for a moderator.
  bool get _canSetAvatar =>
      _isModerator &&
      _roomType != _roomTypeOneToOne &&
      _talkFeatures.contains(_avatarCapability);

  /// Talk `docs/avatar.md` recommends checking `isCustomAvatar` to decide
  /// whether to offer the removal at all.
  bool get _canRemoveAvatar =>
      _canSetAvatar && (_room?.isCustomAvatar ?? false);

  bool get _canBan =>
      _isModerator && _isGroupOrPublic && _talkFeatures.contains(_banCapability);

  bool get _hasPassword => _room?.hasPassword ?? false;

  int get _lobbyState => _room?.lobbyState ?? 0;

  int get _readOnly => _room?.readOnly ?? widget.conversation.readOnly;

  String _lobbyLabel(AppLocalizations strings) {
    if (_lobbyState == 0) {
      return strings.roomDetailsLobbyOff;
    }
    final timer = _room?.lobbyTimer ?? 0;
    return timer > 0
        ? strings.roomDetailsLobbyOnUntil(_formatLobbyTimer(timer))
        : strings.roomDetailsLobbyOn;
  }

  /// The guest link is a client-side URL, not an API call. Talk's
  /// `PageController` declares the route
  /// `#[FrontpageRoute(verb: 'GET', url: '/call/{token}', ...)]`, and the
  /// official web client builds exactly this address in
  /// `src/utils/handleUrl.ts` (`generateFullConversationLink` ->
  /// `generateAbsoluteUrl('/call/{token}', { token })`). The `index.php` form
  /// is used because it resolves whether or not the instance has pretty URLs,
  /// which is the same choice this app already makes for avatar URLs.
  Uri get _guestLink {
    final server = ServerBase.parse(widget.account.serverUrl);
    return server.uri.replace(
      path: '${server.basePath}/index.php/call/${widget.conversation.token}',
    );
  }

  Future<void> _runAction(
    Future<void> Function() action, {
    String Function(AppLocalizations, RoomSettingsError) errorMessage =
        _actionErrorMessage,
    String Function(AppLocalizations, ParticipantsServiceError)
    participantErrorMessage = _participantActionErrorMessage,
  }) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await action();
    } on RoomSettingsException catch (error) {
      // Talk tells clients to show `ocs.data.message` verbatim when a
      // password violates the instance policy, because only the server knows
      // which rule failed and it already translated the explanation.
      final message = error.message;
      if (message != null && message.trim().isNotEmpty) {
        _showMessage(message);
      } else {
        _showActionError(errorMessage, error.code);
      }
    } on ParticipantsServiceException catch (error) {
      _showActionError(participantErrorMessage, error.code);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _showActionError<T>(
    String Function(AppLocalizations, T) message,
    T code,
  ) {
    if (!mounted) {
      return;
    }
    _showMessage(message(AppLocalizations.of(context), code));
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _renameRoom() async {
    final strings = AppLocalizations.of(context);
    final controller = TextEditingController(text: widget.conversation.displayName);
    final newName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.roomDetailsRenameDialogTitle),
        content: TextField(
          key: const Key('room-details-rename-field'),
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: strings.roomDetailsRenameFieldLabel),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(strings.cancel),
          ),
          TextButton(
            key: const Key('room-details-rename-save'),
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: Text(strings.roomDetailsSave),
          ),
        ],
      ),
    );
    if (newName == null || newName.trim().isEmpty || !mounted) {
      return;
    }
    await _runAction(() async {
      final room = await ref
          .read(roomSettingsServiceProvider)
          .renameRoom(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            name: newName,
          );
      if (mounted) {
        setState(() => _room = room);
      }
    });
  }

  Future<void> _editDescription() async {
    final strings = AppLocalizations.of(context);
    final controller = TextEditingController(text: widget.conversation.description);
    final newDescription = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.roomDetailsDescriptionDialogTitle),
        content: TextField(
          key: const Key('room-details-description-field'),
          controller: controller,
          autofocus: true,
          minLines: 2,
          maxLines: 6,
          decoration: InputDecoration(labelText: strings.roomDetailsDescriptionFieldLabel),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(strings.cancel),
          ),
          TextButton(
            key: const Key('room-details-description-save'),
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: Text(strings.roomDetailsSave),
          ),
        ],
      ),
    );
    if (newDescription == null || !mounted) {
      return;
    }
    await _runAction(() async {
      final room = await ref
          .read(roomSettingsServiceProvider)
          .updateDescription(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            description: newDescription,
          );
      if (mounted) {
        setState(() => _room = room);
      }
    });
  }

  Future<void> _changeNotificationLevel() async {
    final strings = AppLocalizations.of(context);
    final current = switch (_notificationLevel) {
      _notificationAlways => RoomNotificationLevel.always,
      _notificationMention => RoomNotificationLevel.mentions,
      _notificationNever => RoomNotificationLevel.never,
      _ => null,
    };
    final selected = await showDialog<RoomNotificationLevel>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        key: const Key('room-details-notification-dialog'),
        title: Text(strings.roomDetailsNotificationDialogTitle),
        children: [
          for (final level in RoomNotificationLevel.values)
            SimpleDialogOption(
              key: Key('room-details-notification-${level.name}'),
              onPressed: () => Navigator.of(dialogContext).pop(level),
              child: Row(
                children: [
                  SizedBox(
                    width: 24,
                    child: level == current ? const Icon(Icons.check, size: 20) : null,
                  ),
                  const SizedBox(width: 8),
                  Text(_notificationLevelLabel(strings, level)),
                ],
              ),
            ),
        ],
      ),
    );
    if (selected == null || !mounted) {
      return;
    }
    await _runAction(() async {
      await ref
          .read(roomSettingsServiceProvider)
          .setNotificationLevel(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            level: selected,
          );
      if (mounted) {
        setState(() => _notificationLevel = selected.wireValue);
      }
    });
  }

  Future<void> _toggleFavorite(bool value) async {
    await _runAction(() async {
      await ref
          .read(roomSettingsServiceProvider)
          .setFavorite(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            favorite: value,
          );
      if (mounted) {
        setState(() => _isFavorite = value);
      }
    });
  }

  Future<void> _confirmLeave() async {
    final strings = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('room-details-leave-dialog'),
        title: Text(strings.roomDetailsLeaveDialogTitle),
        content: Text(strings.roomDetailsLeaveDialogMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          TextButton(
            key: const Key('room-details-leave-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.roomDetailsLeaveDialogConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    var left = false;
    await _runAction(() async {
      await ref
          .read(roomSettingsServiceProvider)
          .leaveRoom(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
          );
      left = true;
    });
    if (left && mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _confirmDelete() async {
    final strings = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('room-details-delete-dialog'),
        title: Text(strings.roomDetailsDeleteDialogTitle),
        content: Text(strings.roomDetailsDeleteDialogMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          TextButton(
            key: const Key('room-details-delete-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.roomDetailsDeleteDialogConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    var deleted = false;
    await _runAction(() async {
      await ref
          .read(roomSettingsServiceProvider)
          .deleteRoom(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            canDeleteConversation: _room?.canDeleteConversation ?? false,
          );
      deleted = true;
    }, errorMessage: _deleteErrorMessage);
    if (deleted && mounted) {
      // Popping once would land on the chat of a conversation that no longer
      // exists, so unwind to the conversation list instead.
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  /// Applies one administration change and folds whatever refreshed room the
  /// server answered with back into the screen. The endpoints that answer
  /// without a room leave [_room] alone, so [fallback] patches the one field
  /// the caller knows changed.
  Future<void> _administer(
    Future<ConversationRoom?> Function() action, {
    required Map<String, Object?> Function() fallback,
    String Function(AppLocalizations, RoomSettingsError)? errorMessage,
  }) async {
    await _runAction(() async {
      final room = await action();
      if (!mounted) {
        return;
      }
      setState(() => _room = room ?? _patchCachedRoom(_room, fallback()));
    }, errorMessage: errorMessage ?? _actionErrorMessage);
  }

  Future<void> _toggleGuests(bool value) async {
    if (!value && !await _confirm(
      key: 'room-details-guests-close-dialog',
      confirmKey: 'room-details-guests-close-confirm',
      title: (strings) => strings.roomDetailsGuestsCloseDialogTitle,
      message: (strings) => strings.roomDetailsGuestsCloseDialogMessage,
      confirmLabel: (strings) => strings.roomDetailsGuestsCloseDialogConfirm,
    )) {
      return;
    }
    await _administer(
      () => ref
          .read(roomSettingsServiceProvider)
          .setPublic(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            public: value,
          ),
      // Turning guests off also drops any password, because a password only
      // exists on a public conversation.
      fallback: () => {
        'type': value ? _roomTypePublic : _roomTypeGroup,
        if (!value) 'hasPassword': false,
      },
    );
  }

  Future<void> _shareGuestLink() async {
    final strings = AppLocalizations.of(context);
    await widget.linkSharer.share(
      uri: _guestLink,
      subject: strings.roomDetailsInviteLinkShareSubject,
    );
  }

  Future<void> _setPassword() async {
    final strings = AppLocalizations.of(context);
    final password = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _PasswordDialog(strings: strings),
    );
    if (password == null || !mounted) {
      return;
    }
    await _administer(
      () => ref
          .read(roomSettingsServiceProvider)
          .setPassword(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            password: password,
          ),
      fallback: () => {'hasPassword': true},
      errorMessage: _passwordErrorMessage,
    );
  }

  Future<void> _removePassword() async {
    if (!await _confirm(
      key: 'room-details-password-remove-dialog',
      confirmKey: 'room-details-password-remove-confirm',
      title: (strings) => strings.roomDetailsPasswordRemoveDialogTitle,
      message: (strings) => strings.roomDetailsPasswordRemoveDialogMessage,
      confirmLabel: (strings) => strings.roomDetailsPasswordRemoveDialogConfirm,
    )) {
      return;
    }
    await _administer(
      () => ref
          .read(roomSettingsServiceProvider)
          .setPassword(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            password: '',
          ),
      fallback: () => {'hasPassword': false},
      errorMessage: _passwordErrorMessage,
    );
  }

  Future<void> _toggleLobby(bool value) async {
    int? timer;
    if (value) {
      final choice = await showDialog<_LobbyChoice>(
        context: context,
        builder: (dialogContext) => _LobbyDialog(
          strings: AppLocalizations.of(context),
          now: DateTime.now(),
        ),
      );
      if (choice == null || !mounted) {
        return;
      }
      timer = choice.timerSecondsSinceEpoch;
    }
    await _administer(
      () => ref
          .read(roomSettingsServiceProvider)
          .setLobby(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            state: value ? RoomLobbyState.moderatorsOnly : RoomLobbyState.none,
            timerSecondsSinceEpoch: timer,
          ),
      fallback: () => {
        'lobbyState': value ? 1 : 0,
        'lobbyTimer': timer ?? 0,
      },
    );
  }

  Future<void> _toggleReadOnly(bool value) async {
    if (value && !await _confirm(
      key: 'room-details-read-only-dialog',
      confirmKey: 'room-details-read-only-confirm',
      title: (strings) => strings.roomDetailsReadOnlyDialogTitle,
      message: (strings) => strings.roomDetailsReadOnlyDialogMessage,
      confirmLabel: (strings) => strings.roomDetailsReadOnlyDialogConfirm,
    )) {
      return;
    }
    await _administer(
      () => ref
          .read(roomSettingsServiceProvider)
          .setReadOnly(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            state: value
                ? RoomReadOnlyState.readOnly
                : RoomReadOnlyState.readWrite,
          ),
      fallback: () => {'readOnly': value ? 1 : 0},
    );
  }

  Future<void> _changeAvatar() async {
    final emoji = await showDialog<String>(
      context: context,
      builder: (dialogContext) =>
          _AvatarDialog(strings: AppLocalizations.of(context)),
    );
    if (emoji == null || !mounted) {
      return;
    }
    await _administer(
      () => ref
          .read(roomSettingsServiceProvider)
          .setEmojiAvatar(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            emoji: emoji,
          ),
      fallback: () => {'isCustomAvatar': true},
    );
  }

  Future<void> _removeAvatar() async {
    await _administer(
      () => ref
          .read(roomSettingsServiceProvider)
          .deleteAvatar(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
          ),
      fallback: () => {'isCustomAvatar': false},
    );
  }

  /// Bans one attendee. The server removes them from the conversation in the
  /// same call, so the participant list is refetched afterwards.
  Future<void> _ban(Participant participant) async {
    final actorType = bannedActorTypeFor(participant.actorType);
    if (actorType == null) {
      return;
    }
    final note = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _BanDialog(
        strings: AppLocalizations.of(context),
        displayName: participant.displayName,
      ),
    );
    if (note == null || !mounted) {
      return;
    }
    var banned = false;
    await _runAction(() async {
      await ref
          .read(participantsServiceProvider)
          .banActor(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            actorType: actorType,
            actorId: participant.actorId,
            internalNote: note,
          );
      banned = true;
    }, participantErrorMessage: _banErrorMessage);
    if (banned && mounted) {
      _retry();
    }
  }

  Future<void> _showBans() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _BansDialog(
        account: widget.account,
        roomToken: widget.conversation.token,
      ),
    );
  }

  /// One confirmation dialog for every destructive administration change, so
  /// each of them does not repeat the same twenty lines.
  Future<bool> _confirm({
    required String key,
    required String confirmKey,
    required String Function(AppLocalizations) title,
    required String Function(AppLocalizations) message,
    required String Function(AppLocalizations) confirmLabel,
  }) async {
    final strings = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: Key(key),
        title: Text(title(strings)),
        content: Text(message(strings)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          TextButton(
            key: Key(confirmKey),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel(strings)),
          ),
        ],
      ),
    );
    return confirmed == true && mounted;
  }

  /// Runs a moderation change and refetches the list, because the endpoints
  /// answer with an empty payload and the new roles are only visible after a
  /// reload.
  Future<void> _moderate(
    Participant participant,
    ParticipantModerationAction action,
  ) async {
    if (action == ParticipantModerationAction.remove &&
        !await _confirmRemoval(participant)) {
      return;
    }
    var changed = false;
    await _runAction(() async {
      await ref
          .read(participantsServiceProvider)
          .moderateParticipant(
            accountId: widget.account.id,
            roomToken: widget.conversation.token,
            attendeeId: participant.attendeeId,
            action: action,
          );
      changed = true;
    });
    if (changed && mounted) {
      _retry();
    }
  }

  Future<bool> _confirmRemoval(Participant participant) async {
    final strings = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('room-details-remove-participant-dialog'),
        title: Text(strings.roomDetailsRemoveDialogTitle),
        content: Text(
          strings.roomDetailsRemoveDialogMessage(participant.displayName),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          TextButton(
            key: const Key('room-details-remove-participant-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.roomDetailsRemoveDialogConfirm),
          ),
        ],
      ),
    );
    return confirmed == true && mounted;
  }

  /// Which moderation actions the server would accept for this attendee, so
  /// the menu never offers a change that is guaranteed to come back as an
  /// error. The server stays the authority; this only trims the obvious ones.
  List<ParticipantAction> _availableActions(Participant participant) {
    if (!_isModerator || _isSelf(participant)) {
      return const [];
    }
    final moderation = switch (participant.role) {
      ParticipantRole.user ||
      ParticipantRole.userSelfJoined ||
      ParticipantRole.guest => const [
        ParticipantAction.promote,
        ParticipantAction.remove,
      ],
      ParticipantRole.moderator || ParticipantRole.guestModerator => const [
        ParticipantAction.demote,
      ],
      // Owners cannot be demoted or removed, and an unknown role means a
      // participant type this build does not understand.
      ParticipantRole.owner || null => const <ParticipantAction>[],
    };
    // A ban is offered wherever a removal is, and only for the actor types the
    // ban endpoint accepts: `BanController::banActor` declares
    // `'users'|'guests'|'emails'|'ip'`, and `ip` is not something the attendee
    // list can name.
    final bannable =
        _canBan &&
        moderation.contains(ParticipantAction.remove) &&
        bannedActorTypeFor(participant.actorType) != null;
    return [...moderation, if (bannable) ParticipantAction.ban];
  }

  Future<void> _runParticipantAction(
    Participant participant,
    ParticipantAction action,
  ) async {
    if (action == ParticipantAction.ban) {
      return _ban(participant);
    }
    return _moderate(participant, switch (action) {
      ParticipantAction.promote => ParticipantModerationAction.promote,
      ParticipantAction.demote => ParticipantModerationAction.demote,
      ParticipantAction.remove ||
      ParticipantAction.ban => ParticipantModerationAction.remove,
    });
  }

  /// Best-effort self match so a moderator is not offered actions on their own
  /// row; the login name is usually the user id, and the server refuses
  /// self-demotion anyway when it is not.
  bool _isSelf(Participant participant) {
    return participant.actorType == 'users' &&
        participant.actorId == widget.account.loginName;
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Scaffold(
      key: const Key('room-details-screen'),
      appBar: AppBar(title: Text(strings.roomDetailsTitle)),
      body: ListView(
        children: [
          _RoomSummary(
            account: widget.account,
            conversation: widget.conversation,
            displayName: _room?.displayName ?? widget.conversation.displayName,
            description: _room?.description ?? widget.conversation.description,
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              strings.roomDetailsActionsHeader,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          if (_isModerator)
            ListTile(
              key: const Key('room-details-rename'),
              leading: const Icon(Icons.edit_outlined),
              title: Text(strings.roomDetailsRenameAction),
              onTap: _busy ? null : _renameRoom,
            ),
          if (_isModerator)
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
          SwitchListTile(
            key: const Key('room-details-favorite-toggle'),
            secondary: const Icon(Icons.star_outline),
            title: Text(strings.roomDetailsFavoriteLabel),
            value: _isFavorite,
            onChanged: _busy ? null : _toggleFavorite,
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
          if (_canBan)
            ListTile(
              key: const Key('room-details-bans'),
              leading: const Icon(Icons.block_outlined),
              title: Text(strings.roomDetailsBansAction),
              onTap: _busy ? null : _showBans,
            ),
          if (_canLeave)
            ListTile(
              key: const Key('room-details-leave'),
              leading: Icon(Icons.logout, color: Theme.of(context).colorScheme.error),
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
            child: Text(
              strings.roomDetailsParticipantsHeader,
              style: Theme.of(context).textTheme.titleMedium,
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

final class _RoomSummary extends StatelessWidget {
  const _RoomSummary({
    required this.account,
    required this.conversation,
    required this.displayName,
    required this.description,
  });

  final StoredAccount account;
  final CachedConversation conversation;

  /// The live name and description, which may already reflect a rename or
  /// description edit made in this screen; [conversation] itself never
  /// changes for the lifetime of the widget.
  final String displayName;
  final String description;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ExcludeSemantics(
                child: ConversationAvatar(
                  account: account,
                  conversation: conversation,
                  radius: 28,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  displayName,
                  key: const Key('room-details-name'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ],
          ),
          if (description.trim().isNotEmpty) ...[
            const SizedBox(height: 16),
            _InfoRow(
              label: strings.roomDetailsDescriptionLabel,
              value: description,
            ),
          ],
          const SizedBox(height: 12),
          _InfoRow(
            label: strings.roomDetailsTypeLabel,
            value: _roomTypeLabel(strings, conversation.roomType),
          ),
          const SizedBox(height: 12),
          _InfoRow(
            label: strings.roomDetailsReadOnlyLabel,
            value: conversation.readOnly != 0
                ? strings.roomDetailsReadOnlyYes
                : strings.roomDetailsReadOnlyNo,
          ),
        ],
      ),
    );
  }
}

final class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
        Text(value, style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }
}

final class _ParticipantTile extends StatelessWidget {
  const _ParticipantTile({
    required this.account,
    required this.participant,
    required this.actions,
    required this.onAction,
  });

  final StoredAccount account;
  final Participant participant;

  /// Moderation actions to offer for this attendee; empty for anyone the
  /// signed-in account may not moderate, which hides the menu entirely.
  final List<ParticipantAction> actions;
  final void Function(ParticipantAction)? onAction;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final online = participant.status == 'online';
    return ListTile(
      key: Key('room-participant-${participant.attendeeId}'),
      leading: ExcludeSemantics(
        child: ChatParticipantAvatar(
          account: account,
          actorType: participant.actorType,
          actorId: participant.actorId,
          displayName: participant.displayName,
        ),
      ),
      title: Text(participant.displayName),
      subtitle: Text(_roleLabel(strings, participant.role)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (participant.status != null)
            Icon(
              Icons.circle,
              size: 10,
              color: online ? Colors.green : scheme.outline,
              semanticLabel: online
                  ? strings.presenceOnline
                  : participant.status,
            ),
          if (actions.isNotEmpty)
            PopupMenuButton<ParticipantAction>(
              key: Key('room-participant-menu-${participant.attendeeId}'),
              tooltip: strings.roomDetailsParticipantActionsTooltip,
              enabled: onAction != null,
              onSelected: onAction,
              itemBuilder: (context) => [
                for (final action in actions)
                  PopupMenuItem(
                    key: Key(
                      'room-participant-${participant.attendeeId}-'
                      '${action.name}',
                    ),
                    value: action,
                    child: Text(_moderationActionLabel(strings, action)),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Asks for a new conversation password.
///
/// Stateful so the dialog itself owns the controller and disposes it: the
/// field holds a secret, and a controller outliving its dialog would keep it
/// in memory after the dialog is gone.
final class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({required this.strings});

  final AppLocalizations strings;

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

final class _PasswordDialogState extends State<_PasswordDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _obscured = true;

  @override
  void dispose() {
    _controller.clear();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    return AlertDialog(
      key: const Key('room-details-password-dialog'),
      title: Text(strings.roomDetailsPasswordDialogTitle),
      content: TextField(
        key: const Key('room-details-password-field'),
        controller: _controller,
        autofocus: true,
        obscureText: _obscured,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: strings.roomDetailsPasswordFieldLabel,
          suffixIcon: IconButton(
            key: const Key('room-details-password-reveal'),
            icon: Icon(
              _obscured ? Icons.visibility_outlined : Icons.visibility_off_outlined,
            ),
            onPressed: () => setState(() => _obscured = !_obscured),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        TextButton(
          key: const Key('room-details-password-save'),
          onPressed: () {
            final value = _controller.text;
            // An empty value would silently clear the protection instead of
            // setting one; that is what the separate removal action is for.
            if (value.isEmpty) {
              Navigator.of(context).pop();
              return;
            }
            Navigator.of(context).pop(value);
          },
          child: Text(strings.roomDetailsSave),
        ),
      ],
    );
  }
}

/// What the lobby dialog answers with: the lobby goes on, optionally with the
/// moment it lifts itself.
final class _LobbyChoice {
  const _LobbyChoice({this.timerSecondsSinceEpoch});

  final int? timerSecondsSinceEpoch;
}

/// Turns the lobby on, with an optional end time.
final class _LobbyDialog extends StatefulWidget {
  const _LobbyDialog({required this.strings, required this.now});

  final AppLocalizations strings;
  final DateTime now;

  @override
  State<_LobbyDialog> createState() => _LobbyDialogState();
}

final class _LobbyDialogState extends State<_LobbyDialog> {
  DateTime? _until;

  Future<void> _pick() async {
    final date = await showDatePicker(
      context: context,
      initialDate: widget.now.add(const Duration(hours: 1)),
      firstDate: widget.now,
      lastDate: widget.now.add(const Duration(days: 365)),
    );
    if (date == null || !mounted) {
      return;
    }
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(widget.now),
    );
    if (time == null || !mounted) {
      return;
    }
    setState(() {
      _until = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    final until = _until;
    return AlertDialog(
      key: const Key('room-details-lobby-dialog'),
      title: Text(strings.roomDetailsLobbyDialogTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(strings.roomDetailsLobbyDialogMessage),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            key: const Key('room-details-lobby-timer'),
            icon: const Icon(Icons.schedule),
            label: Text(
              until == null
                  ? strings.roomDetailsLobbyTimerPick
                  : _formatLobbyTimer(until.millisecondsSinceEpoch ~/ 1000),
            ),
            onPressed: _pick,
          ),
          if (until != null)
            TextButton(
              key: const Key('room-details-lobby-timer-clear'),
              onPressed: () => setState(() => _until = null),
              child: Text(strings.roomDetailsLobbyTimerNone),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        TextButton(
          key: const Key('room-details-lobby-confirm'),
          onPressed: () => Navigator.of(context).pop(
            _LobbyChoice(
              // A timer in the past would be refused by the server, so it is
              // simply dropped and the lobby stays on until switched off.
              timerSecondsSinceEpoch: until != null && until.isAfter(widget.now)
                  ? until.millisecondsSinceEpoch ~/ 1000
                  : null,
            ),
          ),
          child: Text(strings.roomDetailsLobbyDialogConfirm),
        ),
      ],
    );
  }
}

/// Picks one emoji as the conversation avatar.
final class _AvatarDialog extends StatefulWidget {
  const _AvatarDialog({required this.strings});

  final AppLocalizations strings;

  @override
  State<_AvatarDialog> createState() => _AvatarDialogState();
}

final class _AvatarDialogState extends State<_AvatarDialog> {
  String _selected = _avatarEmoji.first;

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      key: const Key('room-details-avatar-dialog'),
      title: Text(strings.roomDetailsAvatarDialogTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(strings.roomDetailsAvatarDialogMessage),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final emoji in _avatarEmoji)
                Semantics(
                  label: strings.roomDetailsAvatarEmojiSemantics(emoji),
                  selected: emoji == _selected,
                  button: true,
                  child: InkWell(
                    key: Key('room-details-avatar-emoji-$emoji'),
                    onTap: () => setState(() => _selected = emoji),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      width: 44,
                      height: 44,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: emoji == _selected
                            ? scheme.primaryContainer
                            : null,
                        border: Border.all(
                          color: emoji == _selected
                              ? scheme.primary
                              : scheme.outlineVariant,
                        ),
                      ),
                      child: ExcludeSemantics(
                        child: Text(
                          emoji,
                          style: const TextStyle(fontSize: 22),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        TextButton(
          key: const Key('room-details-avatar-save'),
          onPressed: () => Navigator.of(context).pop(_selected),
          child: Text(strings.roomDetailsAvatarSetAction),
        ),
      ],
    );
  }
}

/// Confirms a ban and collects the optional moderator-only note.
final class _BanDialog extends StatefulWidget {
  const _BanDialog({required this.strings, required this.displayName});

  final AppLocalizations strings;
  final String displayName;

  @override
  State<_BanDialog> createState() => _BanDialogState();
}

final class _BanDialogState extends State<_BanDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    return AlertDialog(
      key: const Key('room-details-ban-dialog'),
      title: Text(strings.roomDetailsBanDialogTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(strings.roomDetailsBanDialogMessage(widget.displayName)),
          const SizedBox(height: 16),
          TextField(
            key: const Key('room-details-ban-note-field'),
            controller: _controller,
            maxLength: banNoteMaximumLength,
            maxLines: 3,
            minLines: 1,
            decoration: InputDecoration(
              labelText: strings.roomDetailsBanNoteLabel,
              counterText: '',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        TextButton(
          key: const Key('room-details-ban-confirm'),
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: Text(strings.roomDetailsBanDialogConfirm),
        ),
      ],
    );
  }
}

/// Lists the bans on a conversation and lifts them one at a time.
final class _BansDialog extends ConsumerStatefulWidget {
  const _BansDialog({required this.account, required this.roomToken});

  final StoredAccount account;
  final String roomToken;

  @override
  ConsumerState<_BansDialog> createState() => _BansDialogState();
}

final class _BansDialogState extends ConsumerState<_BansDialog> {
  late Future<List<RoomBan>> _bans;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _bans = _load();
  }

  Future<List<RoomBan>> _load() {
    return ref
        .read(participantsServiceProvider)
        .fetchBans(
          accountId: widget.account.id,
          roomToken: widget.roomToken,
        );
  }

  Future<void> _unban(RoomBan ban) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await ref
          .read(participantsServiceProvider)
          .unbanActor(
            accountId: widget.account.id,
            roomToken: widget.roomToken,
            banId: ban.id,
          );
    } on ParticipantsServiceException {
      // The reload below is what tells the moderator whether it worked; a
      // dialog on top of a dialog would only get in the way.
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _bans = _load();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return AlertDialog(
      key: const Key('room-details-bans-dialog'),
      title: Text(strings.roomDetailsBansDialogTitle),
      content: SizedBox(
        width: 320,
        child: FutureBuilder<List<RoomBan>>(
          future: _bans,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                  // A bounded indicator: an indeterminate one never settles,
                  // which would hang every pumpAndSettle in this tree.
                  child: CircularProgressIndicator(value: 0),
                ),
              );
            }
            if (snapshot.hasError) {
              return Text(strings.roomDetailsBansLoadError);
            }
            final bans = snapshot.data ?? const <RoomBan>[];
            if (bans.isEmpty) {
              return Text(strings.roomDetailsBansEmpty);
            }
            return ListView(
              shrinkWrap: true,
              children: [
                for (final ban in bans)
                  ListTile(
                    key: Key('room-ban-${ban.id}'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(ban.bannedDisplayName),
                    subtitle: ban.internalNote.isEmpty
                        ? null
                        : Text(ban.internalNote),
                    trailing: TextButton(
                      key: Key('room-ban-${ban.id}-lift'),
                      onPressed: _busy ? null : () => _unban(ban),
                      child: Text(strings.roomDetailsUnbanAction),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          key: const Key('room-details-bans-close'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.close),
        ),
      ],
    );
  }
}

final class _ParticipantsError extends StatelessWidget {
  const _ParticipantsError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Text(strings.roomDetailsLoadError),
          const SizedBox(height: 8),
          OutlinedButton(
            key: const Key('room-details-retry'),
            onPressed: onRetry,
            child: Text(strings.retry),
          ),
        ],
      ),
    );
  }
}

String _roomTypeLabel(AppLocalizations strings, int roomType) {
  return switch (roomType) {
    _roomTypeOneToOne => strings.roomDetailsTypeOneToOne,
    _roomTypeGroup => strings.roomDetailsTypeGroup,
    _roomTypePublic => strings.roomDetailsTypePublic,
    _roomTypeChangelog => strings.roomDetailsTypeChangelog,
    _roomTypeFormerOneToOne => strings.roomDetailsTypeFormerOneToOne,
    _roomTypeNoteToSelf => strings.roomDetailsTypeNoteToSelf,
    _ => strings.roomDetailsTypeUnknown,
  };
}

/// Labels the wire-level notification value shown as read-only room
/// metadata, including the `default` value the picker never offers.
String _notificationLabel(AppLocalizations strings, int notificationLevel) {
  return switch (notificationLevel) {
    _notificationDefault => strings.roomDetailsNotificationDefault,
    _notificationAlways => strings.roomDetailsNotificationAlways,
    _notificationMention => strings.roomDetailsNotificationMention,
    _notificationNever => strings.roomDetailsNotificationNever,
    _ => strings.roomDetailsNotificationUnknown,
  };
}

String _notificationLevelLabel(AppLocalizations strings, RoomNotificationLevel level) {
  return switch (level) {
    RoomNotificationLevel.always => strings.roomDetailsNotificationAlways,
    RoomNotificationLevel.mentions => strings.roomDetailsNotificationMention,
    RoomNotificationLevel.never => strings.roomDetailsNotificationNever,
  };
}

String _roleLabel(AppLocalizations strings, ParticipantRole? role) {
  return switch (role) {
    ParticipantRole.owner => strings.roomDetailsRoleOwner,
    ParticipantRole.moderator => strings.roomDetailsRoleModerator,
    ParticipantRole.user => strings.roomDetailsRoleUser,
    ParticipantRole.guest => strings.roomDetailsRoleGuest,
    ParticipantRole.userSelfJoined => strings.roomDetailsRoleUser,
    ParticipantRole.guestModerator => strings.roomDetailsRoleGuestModerator,
    null => strings.roomDetailsRoleUnknown,
  };
}

String _moderationActionLabel(
  AppLocalizations strings,
  ParticipantAction action,
) {
  return switch (action) {
    ParticipantAction.promote => strings.roomDetailsPromoteModerator,
    ParticipantAction.demote => strings.roomDetailsDemoteModerator,
    ParticipantAction.remove => strings.roomDetailsRemoveParticipant,
    ParticipantAction.ban => strings.roomDetailsBanParticipant,
  };
}

/// Same as [_actionErrorMessage], except that a refusal here means the server
/// would not accept the password rather than that leaving is blocked. It only
/// runs when the server sent no explanation of its own; when it did, that
/// text is shown verbatim instead.
String _passwordErrorMessage(
  AppLocalizations strings,
  RoomSettingsError code,
) {
  return code == RoomSettingsError.rejected
      ? strings.roomDetailsPasswordRejected
      : _actionErrorMessage(strings, code);
}

String _banErrorMessage(
  AppLocalizations strings,
  ParticipantsServiceError code,
) {
  return code == ParticipantsServiceError.rejected
      ? strings.roomDetailsBanRejected
      : _participantActionErrorMessage(strings, code);
}

/// Folds the fields an endpoint changed into the cached room when the server
/// answered without a fresh copy of it. The wire object is the same validated
/// JSON the decoder produced, so re-parsing the patched map cannot widen what
/// the rest of the screen trusts.
ConversationRoom? _patchCachedRoom(
  ConversationRoom? room,
  Map<String, Object?> patch,
) {
  if (room == null) {
    return null;
  }
  try {
    return ConversationRoom.fromJson({...room.wire, ...patch});
  } on Object {
    return room;
  }
}

/// Renders a UNIX timestamp as a local date and time, without pulling in a
/// locale-aware formatter for one label.
// ponytail: ISO-ish local time, not a localized format — swap in `intl`'s
// DateFormat if the label ever needs to read naturally in every locale.
String _formatLobbyTimer(int secondsSinceEpoch) {
  final at = DateTime.fromMillisecondsSinceEpoch(
    secondsSinceEpoch * 1000,
  ).toLocal();
  String pad(int value) => value.toString().padLeft(2, '0');
  return '${at.year}-${pad(at.month)}-${pad(at.day)} '
      '${pad(at.hour)}:${pad(at.minute)}';
}

Set<String> _decodeTalkFeatures(String source) {
  try {
    final decoded = jsonDecode(source);
    if (decoded is List<Object?> && decoded.every((value) => value is String)) {
      return decoded.cast<String>().toSet();
    }
  } on FormatException {
    // A corrupt local capability cache falls back to capability-free
    // behavior, which hides every gated action rather than guessing.
  }
  return const {};
}

String _participantActionErrorMessage(
  AppLocalizations strings,
  ParticipantsServiceError code,
) {
  return switch (code) {
    ParticipantsServiceError.reauthenticationRequired =>
      strings.roomDetailsActionErrorReauth,
    ParticipantsServiceError.forbidden =>
      strings.roomDetailsActionErrorForbidden,
    ParticipantsServiceError.roomMissing =>
      strings.roomDetailsActionErrorRoomMissing,
    ParticipantsServiceError.rejected =>
      strings.roomDetailsParticipantActionRejected,
    ParticipantsServiceError.accountMissing ||
    ParticipantsServiceError.credentialMissing ||
    ParticipantsServiceError.rateLimited ||
    ParticipantsServiceError.serviceUnavailable ||
    ParticipantsServiceError.invalidResponse ||
    ParticipantsServiceError.network => strings.roomDetailsActionErrorGeneric,
  };
}

/// Same as [_actionErrorMessage], except that a refusal here means the room
/// itself cannot be deleted rather than that leaving is blocked.
String _deleteErrorMessage(AppLocalizations strings, RoomSettingsError code) {
  return code == RoomSettingsError.rejected
      ? strings.roomDetailsDeleteRejected
      : _actionErrorMessage(strings, code);
}

String _actionErrorMessage(AppLocalizations strings, RoomSettingsError code) {
  return switch (code) {
    RoomSettingsError.reauthenticationRequired => strings.roomDetailsActionErrorReauth,
    RoomSettingsError.forbidden => strings.roomDetailsActionErrorForbidden,
    RoomSettingsError.roomMissing => strings.roomDetailsActionErrorRoomMissing,
    RoomSettingsError.rejected => strings.roomDetailsLeaveRejected,
    RoomSettingsError.accountMissing ||
    RoomSettingsError.credentialMissing ||
    RoomSettingsError.rateLimited ||
    RoomSettingsError.serviceUnavailable ||
    RoomSettingsError.invalidResponse ||
    RoomSettingsError.network => strings.roomDetailsActionErrorGeneric,
  };
}

/// The cached room JSON is written from the same validated decoder that
/// produces it, so this only fails on local corruption; the screen simply
/// hides the actions (like rename) that need it when parsing fails.
ConversationRoom? _parseCachedRoom(CachedConversation conversation) {
  try {
    return ConversationRoom.fromJson(jsonDecode(conversation.rawJson));
  } on Object {
    return null;
  }
}
