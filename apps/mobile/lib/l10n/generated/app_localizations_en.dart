// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get dateHeaderToday => 'Today';

  @override
  String get dateHeaderYesterday => 'Yesterday';

  @override
  String get appTitle => 'NCloudTalk';

  @override
  String get onboardingTitle => 'Your conversations, one app';

  @override
  String get onboardingBody =>
      'Connect any supported Nextcloud server. Accounts, cache and background work stay strictly separated.';

  @override
  String get multiServerTitle => 'Built for multiple servers';

  @override
  String get multiServerBody =>
      'Add personal and work accounts without rebuilding the app or sharing their data.';

  @override
  String get secureTitle => 'Credentials stay on this device';

  @override
  String get secureBody =>
      'App passwords are stored in the system Keychain or Keystore, never in the conversation database.';

  @override
  String get addServerTitle => 'Add a Nextcloud server';

  @override
  String get serverAddressLabel => 'Server address';

  @override
  String get serverAddressHint => 'cloud.example.com';

  @override
  String get connect => 'Continue';

  @override
  String get checkingServer => 'Checking the server…';

  @override
  String get openingLogin => 'Opening secure sign-in…';

  @override
  String get waitingForLogin => 'Finish signing in in your browser';

  @override
  String get waitingForLoginBody =>
      'This screen will continue automatically after Nextcloud approves the app.';

  @override
  String get cancel => 'Cancel';

  @override
  String get retry => 'Try again';

  @override
  String get invalidServer => 'Enter a valid HTTPS Nextcloud address.';

  @override
  String get serverUnavailable =>
      'The server could not be reached. Check the address and your connection.';

  @override
  String get serverMaintenance =>
      'This server is currently in maintenance mode.';

  @override
  String get serverNotInstalled =>
      'Nextcloud is not installed on this server yet.';

  @override
  String get serverUpgrade =>
      'The server must finish its database upgrade first.';

  @override
  String get invalidResponse =>
      'The server returned a response this app cannot safely use.';

  @override
  String get browserUnavailable => 'The sign-in page could not be opened.';

  @override
  String get loginTimedOut => 'The sign-in request expired. Start it again.';

  @override
  String get talkUnavailable =>
      'Nextcloud Talk is not available for this account.';

  @override
  String get localPersistenceFailed =>
      'The account could not be stored securely on this device.';

  @override
  String get unexpectedError =>
      'Something went wrong. No account data was changed.';

  @override
  String get accounts => 'Accounts';

  @override
  String get conversations => 'Conversations';

  @override
  String get addAccount => 'Add account';

  @override
  String get switchAccount => 'Switch account';

  @override
  String get refresh => 'Refresh';

  @override
  String get syncing => 'Syncing…';

  @override
  String get cached => 'Showing saved conversations';

  @override
  String get noConversations => 'No conversations yet';

  @override
  String get noConversationsBody =>
      'When a conversation appears on this Nextcloud account, it will be shown here.';

  @override
  String get selectConversation => 'Select a conversation';

  @override
  String get selectConversationBody =>
      'Choose a conversation to see its account-scoped details.';

  @override
  String get conversationDetails => 'Conversation details';

  @override
  String get server => 'Server';

  @override
  String get signedInAs => 'Signed in as';

  @override
  String unreadMessages(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count unread messages',
      one: '1 unread message',
      zero: 'No unread messages',
    );
    return '$_temp0';
  }

  @override
  String get lastMessageUnavailable => 'New activity';

  @override
  String get syncCredentialMissing => 'This account must be signed in again.';

  @override
  String get syncTalkUnavailable =>
      'Talk is no longer available on this server.';

  @override
  String get syncUnsupported =>
      'This server does not expose a supported conversation API.';

  @override
  String get syncRateLimited =>
      'The server asked the app to wait before syncing again.';

  @override
  String get syncUnavailable => 'Conversation sync is temporarily unavailable.';

  @override
  String get syncUpgradeRequired =>
      'The server must be upgraded before conversations can sync.';

  @override
  String get syncInvalidResponse =>
      'Saved conversations are kept, but the latest server response was rejected.';

  @override
  String get syncNetwork => 'Offline. Saved conversations remain available.';

  @override
  String get close => 'Close';

  @override
  String get chatEmpty => 'No messages yet';

  @override
  String get chatEmptyBody => 'Messages in this conversation will appear here.';

  @override
  String get messageHint => 'Write a message';

  @override
  String get sendMessage => 'Send message';

  @override
  String get openEmojiPicker => 'Open emoji picker';

  @override
  String get emojiSearchHint => 'Search emoji';

  @override
  String get emojiNoResults => 'No emoji found';

  @override
  String get emojiCategorySmileys => 'Smileys';

  @override
  String get emojiCategoryPeople => 'People';

  @override
  String get emojiCategoryAnimals => 'Animals';

  @override
  String get emojiCategoryFood => 'Food';

  @override
  String get emojiCategoryActivities => 'Activities';

  @override
  String get emojiCategoryTravel => 'Travel';

  @override
  String get emojiCategoryObjects => 'Objects';

  @override
  String get emojiCategorySymbols => 'Symbols';

  @override
  String get mentionSuggestionsEmpty => 'No matches';

  @override
  String get mentionSuggestionsError => 'Couldn\'t load suggestions';

  @override
  String get openGiphyPicker => 'Open GIF picker';

  @override
  String get giphyChecking => 'Checking GIF availability…';

  @override
  String get giphyRetry => 'Try GIF integration again';

  @override
  String get giphyUnavailable => 'GIFs are not available on this server.';

  @override
  String get giphySearchHint => 'Search GIFs';

  @override
  String get giphyNoResults => 'No GIFs found';

  @override
  String get giphyLoadMore => 'Load more';

  @override
  String get giphyPoweredBy => 'Powered by GIPHY';

  @override
  String get messageTooLong => 'The message is too long.';

  @override
  String get loadOlderMessages => 'Load older messages';

  @override
  String get loadingOlderMessages => 'Loading older messages…';

  @override
  String get chatHistoryGapNotice => 'Some messages between here are missing';

  @override
  String get readOnlyConversation => 'This conversation is read-only.';

  @override
  String get deletedMessage => 'Message deleted';

  @override
  String get outboxQueued => 'Waiting to send';

  @override
  String get outboxSending => 'Sending…';

  @override
  String get outboxRetryable => 'Waiting for a connection';

  @override
  String get outboxAwaitingConfirmation =>
      'The server may already have received this message.';

  @override
  String get outboxFailed => 'Message could not be sent';

  @override
  String get messageSent => 'Sent';

  @override
  String get messageRead => 'Read';

  @override
  String get retrySend => 'Retry sending';

  @override
  String get resendMessage => 'Resend message';

  @override
  String get duplicateRiskTitle => 'Send this message again?';

  @override
  String get duplicateRiskBody =>
      'The first attempt may have reached the server. Sending again can create a duplicate message.';

  @override
  String get confirmResend => 'Send again';

  @override
  String get chatUnsupported =>
      'This server does not expose a supported chat API.';

  @override
  String get chatUnavailable =>
      'Chat is temporarily unavailable. Saved messages remain visible.';

  @override
  String get chatInvalidResponse =>
      'Saved messages are kept, but the latest chat response was rejected.';

  @override
  String get thread => 'Thread';

  @override
  String threadReplies(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count replies',
      one: '1 reply',
    );
    return '$_temp0';
  }

  @override
  String get openThread => 'Open thread';

  @override
  String get edited => 'edited';

  @override
  String get attachment => 'Attachment';

  @override
  String get openAttachment => 'Open attachment';

  @override
  String get imageAttachment => 'Image attachment';

  @override
  String get openImage => 'Open image';

  @override
  String get loadingImage => 'Loading image…';

  @override
  String get imageLoadFailed => 'The image could not be loaded.';

  @override
  String get zoomOut => 'Zoom out';

  @override
  String get resetZoom => 'Reset zoom';

  @override
  String get zoomIn => 'Zoom in';

  @override
  String get attachImage => 'Attach image';

  @override
  String get preparingImage => 'Preparing image…';

  @override
  String get imageUploadQueued => 'Waiting to upload';

  @override
  String uploadingImage(int percent) {
    return 'Uploading image… $percent%';
  }

  @override
  String get confirmingAttachment => 'Confirming the attachment…';

  @override
  String get cancellingUpload => 'Cancelling upload…';

  @override
  String get imageSent => 'Image sent';

  @override
  String get imageUploadFailed => 'The image could not be sent.';

  @override
  String get imageUploadFailedQuota =>
      'The image could not be sent: storage quota exceeded.';

  @override
  String get imageUploadFailedPermission =>
      'The image could not be sent: you do not have permission to upload files here.';

  @override
  String get uploadCancelled => 'Upload cancelled';

  @override
  String get participantAvatarGuest => 'Guest';

  @override
  String get participantAvatarBot => 'Bot';

  @override
  String get participantAvatarBridge => 'Bridge participant';

  @override
  String get participantAvatarSystem => 'System';

  @override
  String get participantAvatarUnknown => 'Participant';

  @override
  String get cancelReply => 'Cancel reply';

  @override
  String replyingTo(Object name) {
    return 'Replying to $name';
  }

  @override
  String get mediaCapabilityChecking => 'Checking attachment support…';

  @override
  String get mediaCapabilityUnavailable =>
      'Attachments are temporarily unavailable.';

  @override
  String get retryMediaCapabilities => 'Try attachments again';

  @override
  String get recordVoiceMessage => 'Record voice message';

  @override
  String get stopVoiceRecording => 'Stop recording';

  @override
  String get playVoiceMessage => 'Play voice message';

  @override
  String get stopVoiceMessage => 'Stop voice message';

  @override
  String get playVoicePreview => 'Play voice message preview';

  @override
  String get cancelVoiceMessage => 'Cancel voice message';

  @override
  String get sendVoiceMessage => 'Send voice message';

  @override
  String get voiceMessageQueued => 'Voice message waiting to send';

  @override
  String get voiceUnsupported =>
      'Voice messages are not supported in this conversation.';

  @override
  String get voicePermissionDenied => 'Microphone access was denied.';

  @override
  String get voicePermissionPermanentlyDenied =>
      'Allow microphone access in system settings.';

  @override
  String get voicePermissionRequestFailed =>
      'Microphone access could not be checked.';

  @override
  String get voiceRecordingFailed => 'The voice message could not be recorded.';

  @override
  String get voiceInvalidRecording => 'The recording is empty or unsupported.';

  @override
  String get voicePlaybackFailed =>
      'The recording preview could not be played.';

  @override
  String voicePlaybackPosition(Object duration, Object position) {
    return '$position of $duration';
  }

  @override
  String get voiceSendFailed => 'The voice message could not be queued.';

  @override
  String get voiceCleanupFailed => 'The recording could not be removed safely.';

  @override
  String get presenceOnline => 'Online';

  @override
  String get presenceAway => 'Away';

  @override
  String get presenceBusy => 'Busy';

  @override
  String get presenceDoNotDisturb => 'Do not disturb';

  @override
  String get roomDetailsOpenTooltip => 'Conversation details';

  @override
  String get roomDetailsTitle => 'Conversation details';

  @override
  String get roomDetailsDescriptionLabel => 'Description';

  @override
  String get roomDetailsTypeLabel => 'Type';

  @override
  String get roomDetailsTypeOneToOne => 'One-to-one conversation';

  @override
  String get roomDetailsTypeGroup => 'Group conversation';

  @override
  String get roomDetailsTypePublic => 'Public channel';

  @override
  String get roomDetailsTypeChangelog => 'Changelog';

  @override
  String get roomDetailsTypeFormerOneToOne => 'Former one-to-one conversation';

  @override
  String get roomDetailsTypeNoteToSelf => 'Note to self';

  @override
  String get roomDetailsTypeUnknown => 'Unknown';

  @override
  String get roomDetailsReadOnlyLabel => 'Read-only';

  @override
  String get roomDetailsReadOnlyYes => 'Yes';

  @override
  String get roomDetailsReadOnlyNo => 'No';

  @override
  String get roomDetailsNotificationLabel => 'Notifications';

  @override
  String get roomDetailsNotificationDefault => 'Default';

  @override
  String get roomDetailsNotificationAlways => 'All messages';

  @override
  String get roomDetailsNotificationMention => 'Mentions only';

  @override
  String get roomDetailsNotificationNever => 'Off';

  @override
  String get roomDetailsNotificationUnknown => 'Unknown';

  @override
  String get roomDetailsParticipantsHeader => 'Participants';

  @override
  String roomDetailsParticipantsCount(int count) {
    return '$count participants';
  }

  @override
  String get roomDetailsParticipantsEmpty => 'No participants found.';

  @override
  String get roomDetailsLoadError => 'Participants could not be loaded.';

  @override
  String get roomDetailsRoleOwner => 'Owner';

  @override
  String get roomDetailsRoleModerator => 'Moderator';

  @override
  String get roomDetailsRoleUser => 'User';

  @override
  String get roomDetailsRoleGuest => 'Guest';

  @override
  String get roomDetailsRoleGuestModerator => 'Guest moderator';

  @override
  String get roomDetailsRoleUnknown => 'Unknown role';

  @override
  String get roomDetailsActionsHeader => 'Conversation settings';

  @override
  String get roomDetailsRenameAction => 'Rename conversation';

  @override
  String get roomDetailsRenameDialogTitle => 'Rename conversation';

  @override
  String get roomDetailsRenameFieldLabel => 'Name';

  @override
  String get roomDetailsDescriptionEditAction => 'Edit description';

  @override
  String get roomDetailsDescriptionDialogTitle => 'Edit description';

  @override
  String get roomDetailsDescriptionFieldLabel => 'Description';

  @override
  String get roomDetailsSave => 'Save';

  @override
  String get roomDetailsNotificationDialogTitle => 'Notification level';

  @override
  String get roomDetailsFavoriteLabel => 'Favorite conversation';

  @override
  String get roomDetailsLeaveAction => 'Leave conversation';

  @override
  String get roomDetailsLeaveDialogTitle => 'Leave conversation?';

  @override
  String get roomDetailsLeaveDialogMessage =>
      'You will stop receiving new messages from this conversation until someone invites you back.';

  @override
  String get roomDetailsLeaveDialogConfirm => 'Leave';

  @override
  String get roomDetailsActionErrorGeneric =>
      'The change could not be saved. Please try again.';

  @override
  String get roomDetailsActionErrorReauth =>
      'Please sign in again to make this change.';

  @override
  String get roomDetailsActionErrorForbidden =>
      'You don\'t have permission to do this.';

  @override
  String get roomDetailsActionErrorRoomMissing =>
      'This conversation no longer exists.';

  @override
  String get roomDetailsLeaveRejected =>
      'You can\'t leave until another moderator is promoted.';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsAccountsSection => 'Accounts';

  @override
  String get settingsAccountSelected => 'Active';

  @override
  String get settingsAccountsLoadFailed => 'Accounts could not be loaded.';

  @override
  String get settingsAddAccount => 'Add account';

  @override
  String get settingsRemoveAccountUnavailable =>
      'Removing an account isn\'t supported yet. Sign out of it on the server if you need to revoke access.';

  @override
  String get settingsThemeSection => 'Appearance';

  @override
  String get settingsThemeSystem => 'Match system';

  @override
  String get settingsThemeLight => 'Light';

  @override
  String get settingsThemeDark => 'Dark';

  @override
  String get conversationActionsTitle => 'Conversation actions';

  @override
  String get conversationActionMarkUnread => 'Mark as unread';

  @override
  String get conversationActionArchive => 'Archive conversation';

  @override
  String get conversationActionUnarchive => 'Unarchive conversation';

  @override
  String conversationArchivedSectionShow(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Archived ($count)',
      one: 'Archived (1)',
    );
    return '$_temp0';
  }

  @override
  String get conversationArchivedSectionHide => 'Back to conversations';

  @override
  String get conversationActionErrorGeneric =>
      'The action could not be completed. Please try again.';

  @override
  String get conversationActionErrorReauth =>
      'Please sign in again to make this change.';

  @override
  String get messageActionReply => 'Reply';

  @override
  String get messageActionCopy => 'Copy text';

  @override
  String get messageActionEdit => 'Edit';

  @override
  String get messageActionDelete => 'Delete';

  @override
  String get messageActionReact => 'React';

  @override
  String get messageCopied => 'Copied to clipboard';

  @override
  String get editMessageTitle => 'Edit message';

  @override
  String get editMessageSave => 'Save';

  @override
  String get deleteMessageConfirmTitle => 'Delete this message?';

  @override
  String get deleteMessageConfirmBody => 'This cannot be undone.';

  @override
  String get reactionPickerMore => 'More emoji…';

  @override
  String get messageActionUnsupported => 'This action isn\'t available here.';

  @override
  String get messageActionMessageMissing =>
      'This message is no longer available.';

  @override
  String get searchMessagesTooltip => 'Search messages';

  @override
  String get searchMessagesTitle => 'Search messages';

  @override
  String get searchMessagesHint => 'Search messages';

  @override
  String get searchMessagesPrompt => 'Type to search messages';

  @override
  String get searchMessagesNoResults => 'No messages found';

  @override
  String get searchMessagesError => 'Search failed. Try again.';

  @override
  String get newConversationTitle => 'New conversation';

  @override
  String get newConversationSearchLabel => 'Search people and groups';

  @override
  String get newConversationIdle => 'Type a name to find someone to chat with.';

  @override
  String get newConversationEmpty => 'No people or groups found.';

  @override
  String get newConversationNameDialogTitle => 'Name this group conversation';

  @override
  String get newConversationNameLabel => 'Conversation name';

  @override
  String get newConversationCreate => 'Create';

  @override
  String get newConversationErrorAccountMissing =>
      'This account is no longer available.';

  @override
  String get newConversationErrorCredentialMissing =>
      'Sign in again to search for people and groups.';

  @override
  String get newConversationErrorInvalidSearchTerm => 'Enter a search term.';

  @override
  String get newConversationErrorRoomNameRequired =>
      'The conversation needs a name.';

  @override
  String get newConversationErrorReauthenticationRequired =>
      'Sign in again to continue.';

  @override
  String get newConversationErrorOcsFailure =>
      'The server rejected the request.';

  @override
  String get newConversationErrorRateLimited =>
      'Too many requests. Try again soon.';

  @override
  String get newConversationErrorServiceUnavailable =>
      'The server is temporarily unavailable.';

  @override
  String get newConversationErrorInvalidResponse =>
      'The server sent an unexpected response.';

  @override
  String get newConversationErrorNetwork => 'Could not reach the server.';

  @override
  String get roomDetailsParticipantActionsTooltip => 'Participant actions';

  @override
  String get roomDetailsPromoteModerator => 'Promote to moderator';

  @override
  String get roomDetailsDemoteModerator => 'Remove moderator rights';

  @override
  String get roomDetailsRemoveParticipant => 'Remove from conversation';

  @override
  String get roomDetailsRemoveDialogTitle => 'Remove participant?';

  @override
  String roomDetailsRemoveDialogMessage(String name) {
    return '$name will lose access to this conversation until someone invites them back.';
  }

  @override
  String get roomDetailsRemoveDialogConfirm => 'Remove';

  @override
  String get roomDetailsParticipantActionRejected =>
      'The server refused this change for this participant.';

  @override
  String get jumpToOriginalMessage => 'Show the original message';

  @override
  String get jumpToMessageNotFound =>
      'That message is no longer available in this conversation.';

  @override
  String get jumpToMessageConversationMissing =>
      'That conversation is not available on this device.';
}
