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
  String get appTitle => 'NKS Talk';

  @override
  String get onboardingTitle => 'Your conversations, one app';

  @override
  String get onboardingBody =>
      'Connect any supported Nextcloud server. Accounts, their stored data and background work stay strictly separated.';

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
  String get reauthenticateAccountTitle => 'Sign in to this account again';

  @override
  String get serverAddressLabel => 'Server address';

  @override
  String get serverAddressHint => 'cloud.example.com';

  @override
  String get connect => 'Continue';

  @override
  String get reauthenticateAccountAction => 'Sign in again';

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
  String get incomingShareTitle => 'Share to a conversation';

  @override
  String get incomingShareAccount => 'Account';

  @override
  String get incomingShareConversation => 'Conversation';

  @override
  String get incomingShareNoFileTargets =>
      'None of your accounts takes file attachments. Their servers have them turned off; text can still be shared.';

  @override
  String get incomingShareSearch => 'Search conversations';

  @override
  String get incomingShareNoMatches => 'No conversation matches that.';

  @override
  String get incomingShareFile => 'Sharing a file';

  @override
  String get incomingShareText => 'Sharing text';

  @override
  String get incomingShareSend => 'Send';

  @override
  String get incomingShareNoTargets =>
      'No writable conversations are available.';

  @override
  String get incomingShareSendFailed =>
      'The item could not be queued. Check the account and try again.';

  @override
  String get incomingShareCleanupFailed =>
      'The shared item was sent, but its temporary copy could not be removed.';

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
  String get reauthenticateAccountMismatch =>
      'Sign in with the same account. The stored account was not changed.';

  @override
  String get localPersistenceFailed =>
      'The account could not be stored securely on this device.';

  @override
  String get scanLoginCode => 'Scan a login code';

  @override
  String get scanLoginCodeHint =>
      'Point the camera at the QR code your server shows under Settings, Security, Create new app password.';

  @override
  String get scanLoginCodeCameraDenied =>
      'Camera access is turned off. Allow it in system settings to scan a login code.';

  @override
  String get scanLoginCodeCameraUnavailable =>
      'This device has no camera that can read a login code.';

  @override
  String get scanLoginCodeUnreadable => 'This is not a Nextcloud login code.';

  @override
  String get scannedLoginRejected =>
      'The scanned login code could not be used. Create a new one on the server.';

  @override
  String get unexpectedError =>
      'Something went wrong. No account data was changed.';

  @override
  String get accounts => 'Accounts';

  @override
  String get hideConversationList => 'Hide the conversation list';

  @override
  String get showConversationList => 'Show the conversation list';

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
      'The server asked the app to wait a moment. Syncing resumes on its own.';

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
  String get emojiPickerTitle => 'Emoji';

  @override
  String get emojiPickerCloseTooltip => 'Close emoji picker';

  @override
  String get emojiManageFavorites => 'Manage favourites';

  @override
  String get emojiFinishManagingFavorites => 'Finish managing favourites';

  @override
  String get emojiFavoriteModeHint => 'Tap emoji to add or remove favourites';

  @override
  String get emojiAddFavoriteLabel => 'Add to favourites';

  @override
  String get emojiRemoveFavoriteLabel => 'Remove from favourites';

  @override
  String get emojiSearchHint => 'Search emoji';

  @override
  String get emojiNoResults => 'No emoji found';

  @override
  String get emojiNoRecents => 'No recently used emoji';

  @override
  String get emojiNoFavorites => 'No favourite emoji';

  @override
  String get emojiCategoryFavorites => 'Favourites';

  @override
  String get emojiCategoryRecent => 'Recent';

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
  String get emojiCategoryFlags => 'Flags';

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
  String get jumpToNewestMessages => 'Jump to newest messages';

  @override
  String get silentSendOff => 'Send without notification';

  @override
  String get silentSendOn => 'Sending without notification';

  @override
  String get chatHistoryGapNotice => 'Some messages are missing here';

  @override
  String get readOnlyConversation => 'This conversation is read-only.';

  @override
  String get noChatPermissionConversation =>
      'You do not have permission to post in this conversation.';

  @override
  String get lobbyConversation =>
      'The conversation has not started yet. You can post once a moderator opens it.';

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
  String get threadManagementTitle => 'Threads';

  @override
  String get threadManagementOpenTooltip => 'Manage threads';

  @override
  String get threadManagementRecentTab => 'Recent';

  @override
  String get threadManagementSubscribedTab => 'Subscribed';

  @override
  String get threadManagementRecentEmpty => 'No recent threads';

  @override
  String get threadManagementRecentEmptyBody =>
      'Replying to a message does not start a thread. One appears here once you start it from a message.';

  @override
  String get threadManagementSubscribedEmpty => 'No subscribed threads';

  @override
  String get threadManagementSubscribedEmptyBody =>
      'Threads you follow across this account appear here, including ones from other conversations.';

  @override
  String get threadManagementConversationMissing =>
      'This conversation is not available on this device yet.';

  @override
  String get threadManagementDetailTitle => 'Thread details';

  @override
  String get threadManagementRenameDialogTitle => 'Rename thread';

  @override
  String get threadManagementRenameAction => 'Rename thread';

  @override
  String get threadManagementNameLabel => 'Thread name';

  @override
  String get threadManagementNameRequired => 'Enter a thread name.';

  @override
  String get threadManagementActionsNeedConnection =>
      'Connect to the server to check which thread actions are available.';

  @override
  String get threadManagementUnsupported =>
      'This server does not support thread management.';

  @override
  String get threadManagementPermissionDenied =>
      'You do not have permission to change this thread.';

  @override
  String get threadManagementNotFound =>
      'The thread is no longer available on the server.';

  @override
  String get threadManagementAmbiguous =>
      'The server may have applied the change. Refresh the thread before trying again.';

  @override
  String get threadManagementOpenUnavailable =>
      'The thread could not be opened from the validated server response.';

  @override
  String get edited => 'edited';

  @override
  String get attachment => 'Attachment';

  @override
  String get openAttachment => 'Open attachment';

  @override
  String openLocation(String name) {
    return 'Open location: $name';
  }

  @override
  String get shareLocation => 'Location';

  @override
  String get sharedLocationDefaultName => 'Shared location';

  @override
  String get locationConfirmTitle => 'Share current location?';

  @override
  String locationCoordinates(String latitude, String longitude) {
    return '$latitude, $longitude';
  }

  @override
  String get locationPermissionDenied => 'Location access was denied.';

  @override
  String get locationPermissionDeniedForever =>
      'Location access is disabled in system settings.';

  @override
  String get openAppSettings => 'Open settings';

  @override
  String get openAppSettingsFailed =>
      'The system settings could not be opened.';

  @override
  String get locationServicesDisabled =>
      'Turn on location services and try again.';

  @override
  String get locationUnavailable =>
      'The current location could not be determined.';

  @override
  String get locationShareFailed => 'The location could not be shared.';

  @override
  String get locationShareAmbiguous =>
      'The server may have received the location. Check the chat before trying again.';

  @override
  String get locationShared => 'Location shared.';

  @override
  String outOfOffice(String user) {
    return '$user is out of office and might not respond.';
  }

  @override
  String absencePeriod(String startDate, String endDate) {
    return 'Absence period: $startDate – $endDate';
  }

  @override
  String absenceReplacement(String name) {
    return 'Replacement: $name';
  }

  @override
  String get upcomingEventDefaultTitle => 'Upcoming event';

  @override
  String get dismissUpcomingEvent => 'Dismiss upcoming event';

  @override
  String get contactAttachment => 'Contact';

  @override
  String openContact(String name) {
    return 'Open contact: $name';
  }

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
  String get preparingImage => 'Preparing attachment…';

  @override
  String get imageUploadQueued => 'Waiting to upload';

  @override
  String get attachmentReadyToSend => 'Ready to send with your message';

  @override
  String get remove => 'Remove';

  @override
  String uploadingImage(int percent) {
    return 'Uploading… $percent%';
  }

  @override
  String get confirmingAttachment => 'Confirming the attachment…';

  @override
  String get cancellingUpload => 'Cancelling upload…';

  @override
  String get imageSent => 'Attachment sent';

  @override
  String get imageUploadFailed => 'The attachment could not be sent.';

  @override
  String get imageUploadFailedQuota =>
      'The attachment could not be sent: storage quota exceeded.';

  @override
  String get imageUploadFailedPermission =>
      'The attachment could not be sent: you do not have permission to upload files here.';

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
  String get voiceMessagePlaybackFailed =>
      'The voice message could not be played.';

  @override
  String voicePlaybackPosition(Object duration, Object position) {
    return '$position of $duration';
  }

  @override
  String get voiceSendFailed => 'The voice message could not be queued.';

  @override
  String get voiceCleanupFailed => 'The recording could not be removed safely.';

  @override
  String get transcribeVoiceMessage => 'Transcribe';

  @override
  String get cancelVoiceTranscription => 'Cancel transcription';

  @override
  String get voiceTranscriptionRunning => 'Transcribing the voice message…';

  @override
  String get copyVoiceTranscript => 'Copy transcription';

  @override
  String get voiceTranscriptCopied => 'Transcription copied to clipboard';

  @override
  String get voiceTranscriptionDenied =>
      'Speech recognition permission was denied.';

  @override
  String get voiceTranscriptionRestricted =>
      'Speech recognition is restricted on this device.';

  @override
  String get voiceTranscriptionUnavailable =>
      'On-device speech recognition is unavailable.';

  @override
  String get voiceTranscriptionInvalidFile =>
      'This voice message cannot be transcribed.';

  @override
  String get voiceTranscriptionFailed =>
      'The voice message could not be transcribed.';

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
  String get roomDetailsCallNotificationsLabel => 'Call notifications';

  @override
  String get roomDetailsCallNotificationsSubtitle =>
      'Notify me when a call starts';

  @override
  String get roomDetailsMessageExpirationLabel => 'Message expiration';

  @override
  String get roomDetailsMessageExpirationDialogTitle =>
      'Set message expiration';

  @override
  String get roomDetailsMessageExpirationHint =>
      'Shared files will no longer be shared in this conversation, but the owner\'s files will not be deleted.';

  @override
  String get roomDetailsMessageExpirationOff => 'Off';

  @override
  String get roomDetailsMessageExpirationOneHour => '1 hour';

  @override
  String get roomDetailsMessageExpirationEightHours => '8 hours';

  @override
  String get roomDetailsMessageExpirationOneDay => '1 day';

  @override
  String get roomDetailsMessageExpirationOneWeek => '1 week';

  @override
  String get roomDetailsMessageExpirationFourWeeks => '4 weeks';

  @override
  String roomDetailsMessageExpirationCustom(int seconds) {
    return 'Custom ($seconds seconds)';
  }

  @override
  String get roomDetailsMessageExpirationRejected =>
      'The server rejected this expiration setting.';

  @override
  String get roomDetailsParticipantsHeader => 'Participants';

  @override
  String get roomDetailsAddParticipant => 'Add';

  @override
  String get roomDetailsAddParticipantTitle => 'Add to the conversation';

  @override
  String get roomDetailsAddParticipantSearch => 'Search for people and groups';

  @override
  String get roomDetailsAddParticipantEmpty => 'Nobody matches';

  @override
  String roomDetailsAddParticipantAdded(String name) {
    return '$name was added';
  }

  @override
  String roomDetailsParticipantsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count participants',
      one: '1 participant',
    );
    return '$_temp0';
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
  String get roomDetailsFavoriteLabel => 'Favourite conversation';

  @override
  String get roomDetailsImportantLabel => 'Important conversation';

  @override
  String get roomDetailsImportantSubtitle =>
      'Notify me even while Do Not Disturb is active';

  @override
  String get roomDetailsSensitiveLabel => 'Sensitive conversation';

  @override
  String get roomDetailsSensitiveSubtitle =>
      'Hide the last message and notification previews';

  @override
  String get roomDetailsSensitiveClassifiedSubtitle =>
      'Required for classified conversations';

  @override
  String get roomDetailsSensitiveRejected =>
      'This conversation must keep message previews hidden.';

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
  String get roomDetailsBotsTitle => 'Bots';

  @override
  String get roomDetailsBotsEmpty =>
      'No bots are available for this conversation.';

  @override
  String get roomDetailsBotEnabled => 'Enabled';

  @override
  String get roomDetailsBotDisabled => 'Disabled';

  @override
  String get roomDetailsBotEnable => 'Enable bot';

  @override
  String get roomDetailsBotDisable => 'Disable bot';

  @override
  String get roomDetailsBotUpdating => 'Updating bot…';

  @override
  String get roomDetailsBotsLoadFailed => 'Bots could not be loaded.';

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
  String get settingsProfileSection => 'Profile';

  @override
  String get settingsOpenProfile => 'Profile and status';

  @override
  String get settingsOpenProfileSubtitle =>
      'View your profile and manage your availability';

  @override
  String get settingsRepliesSection => 'Replies';

  @override
  String get settingsCallsSection => 'Calls';

  @override
  String get settingsCallRelayOnly => 'Always use a relay server';

  @override
  String get settingsCallRelayOnlyDescription =>
      'Send calls through the relay server your Nextcloud administrator set up instead of connecting directly. Slower, but it gets through a network that blocks direct connections. Applies to the next call.';

  @override
  String get settingsReplyLayoutInline => 'In the conversation';

  @override
  String get settingsReplyLayoutInlineDescription =>
      'A reply stays in the conversation under a quote of the message it answers.';

  @override
  String get settingsReplyLayoutThread => 'In a thread';

  @override
  String get settingsReplyLayoutThreadDescription =>
      'Replies leave the conversation and open in a separate thread.';

  @override
  String get settingsThemeSection => 'Appearance';

  @override
  String get settingsSecuritySection => 'Security';

  @override
  String get settingsAppLock => 'App lock';

  @override
  String get settingsAppLockSubtitle =>
      'Require device authentication before showing your conversations.';

  @override
  String get settingsAppLockChangeFailed =>
      'The app lock setting could not be changed.';

  @override
  String get appLockAuthenticationReason =>
      'Unlock your NKS Talk conversations';

  @override
  String get appLockAuthenticationCancelled =>
      'Device authentication was cancelled.';

  @override
  String get appLockLockedTitle => 'NKS Talk is locked';

  @override
  String get appLockLockedMessage =>
      'Authenticate with your device to continue.';

  @override
  String get appLockLoadFailed =>
      'The app lock setting could not be read safely. Try again to continue.';

  @override
  String get appLockUnlock => 'Unlock';

  @override
  String get settingsThemeSystem => 'Match system';

  @override
  String get settingsThemeLight => 'Light';

  @override
  String get settingsThemeDark => 'Dark';

  @override
  String get settingsDesktopSection => 'Desktop';

  @override
  String get settingsDesktopAutostart => 'Open NKS Talk when I sign in';

  @override
  String get settingsDesktopAutostartChecking =>
      'Checking the system startup setting…';

  @override
  String get settingsDesktopAutostartOnSubtitle =>
      'NKS Talk opens automatically after you sign in.';

  @override
  String get settingsDesktopAutostartOffSubtitle =>
      'NKS Talk stays closed until you open it.';

  @override
  String get settingsDesktopAutostartFailed =>
      'The system startup setting could not be changed.';

  @override
  String get settingsUpdatesSection => 'Updates';

  @override
  String get settingsUpdateCheck => 'Look for newer builds';

  @override
  String get settingsUpdateCheckSubtitle =>
      'Turned on, the app asks GitHub which build is the newest, which tells GitHub that this installation exists. Nothing about you, your account or your conversations is sent. On Windows you can then choose to download the installer and have it checked before anything runs; nothing downloads or runs without you saying so, twice.';

  @override
  String settingsUpdateCheckCurrentBuild(Object build) {
    return 'This build is $build';
  }

  @override
  String get settingsUpdateCheckChecking => 'Asking GitHub…';

  @override
  String get settingsUpdateCheckUpToDate => 'Nothing newer has been published.';

  @override
  String settingsUpdateCheckAvailable(Object build, Object name) {
    return 'Build $build is out: $name';
  }

  @override
  String get settingsUpdateCheckFailed =>
      'GitHub could not be asked. Try again later.';

  @override
  String get settingsUpdateCheckOpen => 'Open release';

  @override
  String get settingsUpdateCheckOpenFailed =>
      'The release page could not be opened.';

  @override
  String get settingsUpdateCheckDownloadInstall => 'Download and install';

  @override
  String get settingsUpdateCheckDownloadConfirmTitle =>
      'Download the installer?';

  @override
  String get settingsUpdateCheckDownloadConfirmBody =>
      'This downloads the Windows installer from GitHub into a temporary folder and checks it against the checksum GitHub published for it. Nothing runs yet.';

  @override
  String get settingsUpdateCheckDownloadConfirmAction => 'Download';

  @override
  String get settingsUpdateCheckDownloadDismiss => 'Not now';

  @override
  String settingsUpdateCheckDownloadingProgress(Object percent) {
    return 'Downloading… $percent%';
  }

  @override
  String get settingsUpdateCheckDownloadingUnknown => 'Downloading…';

  @override
  String get settingsUpdateCheckDownloadCancel => 'Cancel download';

  @override
  String get settingsUpdateCheckDownloadCancelled => 'Download cancelled.';

  @override
  String get settingsUpdateCheckDownloadFailed =>
      'The installer could not be downloaded. Try again later.';

  @override
  String get settingsUpdateCheckVerificationFailed =>
      'The download did not match the checksum GitHub published for it, so it was refused and deleted.';

  @override
  String get settingsUpdateCheckInstallNow => 'Install now';

  @override
  String get settingsUpdateCheckInstallConfirmTitle => 'Install now?';

  @override
  String get settingsUpdateCheckInstallConfirmBody =>
      'This starts the installer, which closes NKS Talk to finish installing the new build.';

  @override
  String get settingsUpdateCheckInstallConfirmAction => 'Install';

  @override
  String get settingsUpdateCheckInstallDismiss => 'Not now';

  @override
  String get settingsUpdateCheckInstallStarted => 'The installer has started.';

  @override
  String get settingsUpdateCheckInstallStartFailed =>
      'The installer could not be started.';

  @override
  String get settingsPushSection => 'Push notifications';

  @override
  String get settingsNotificationPermission => 'System notification permission';

  @override
  String get settingsNotificationPermissionGranted => 'Granted';

  @override
  String get settingsNotificationPermissionDenied => 'Denied';

  @override
  String get settingsNotificationPermissionNotDetermined => 'Not requested yet';

  @override
  String get settingsNotificationPermissionChecking => 'Checking…';

  @override
  String get settingsNotificationPermissionRequest => 'Allow';

  @override
  String get settingsNotificationPermissionFailed =>
      'Notification permission could not be requested.';

  @override
  String get settingsPushTransportProxy => 'Our own proxy';

  @override
  String get settingsPushTransportProxySubtitle =>
      'Notifications take the same path as on iOS, through this application\'s own notification service.';

  @override
  String get settingsPushTransportWebPush => 'Web Push (fallback)';

  @override
  String get settingsPushTransportWebPushSubtitle =>
      'Routes through the public UnifiedPush gateway. Use this if the proxy gives trouble.';

  @override
  String get settingsPushTransportSwitchFailed =>
      'Could not switch. The previous registration is still in place.';

  @override
  String get settingsDiagnosticsSection => 'Diagnostics';

  @override
  String get settingsOpenDiagnostics => 'Local diagnostics';

  @override
  String get settingsOpenDiagnosticsSubtitle =>
      'Local state of the active account';

  @override
  String get diagnosticsTitle => 'Local diagnostics';

  @override
  String get diagnosticsRefresh => 'Read again';

  @override
  String get diagnosticsLoadFailed => 'The local state could not be read.';

  @override
  String get diagnosticsAppSection => 'Application';

  @override
  String get diagnosticsLicenses => 'Open source licences';

  @override
  String get diagnosticsLicensesSubtitle =>
      'Licences of the libraries this app is built from';

  @override
  String get diagnosticsLicensesLegalese =>
      'NKS Talk is free software under the GNU GPL-3.0-or-later. It ships the UnifiedPush embedded FCM distributor (LGPL-2.1) as part of this GPL work under LGPL section 3. The complete corresponding source of this build is available to every recipient on request from whoever distributed it to you.';

  @override
  String get diagnosticsAppVersion => 'Version';

  @override
  String get diagnosticsAppBuild => 'Build';

  @override
  String get diagnosticsPlatform => 'Platform';

  @override
  String get diagnosticsDatabaseSection => 'Database';

  @override
  String get diagnosticsSchemaVersion => 'Stored schema version';

  @override
  String get diagnosticsExpectedSchemaVersion => 'Expected schema version';

  @override
  String get diagnosticsMigrationState => 'Migration state';

  @override
  String get diagnosticsMigrationUpToDate => 'Up to date';

  @override
  String get diagnosticsMigrationUpgradeRequired => 'Upgrade required';

  @override
  String get diagnosticsMigrationNewerThanApp => 'Newer than this app';

  @override
  String get diagnosticsForeignKeyViolations => 'Foreign-key violations';

  @override
  String get diagnosticsConversationRows => 'Cached conversations';

  @override
  String get diagnosticsMessageRows => 'Cached messages';

  @override
  String get diagnosticsThreadRows => 'Cached threads';

  @override
  String get diagnosticsTextOutboxRows => 'Text outbox entries';

  @override
  String get diagnosticsAttachmentOutboxRows => 'Attachment outbox entries';

  @override
  String get diagnosticsOutboxSection => 'Outbox';

  @override
  String get diagnosticsOutboxTextTitle => 'Text messages';

  @override
  String get diagnosticsOutboxAttachmentsTitle => 'Attachments';

  @override
  String get diagnosticsStalledAttachmentsSection => 'Unfinished attachments';

  @override
  String get diagnosticsStalledAttachmentsNone => 'No unfinished attachment';

  @override
  String get diagnosticsStalledAttachmentKindVoice => 'Voice message';

  @override
  String get diagnosticsStalledAttachmentKindFile => 'File';

  @override
  String get diagnosticsStalledAttachmentAttempts => 'Attempts';

  @override
  String get diagnosticsStalledAttachmentAge => 'Age';

  @override
  String get diagnosticsStalledAttachmentCancel => 'Cancel upload';

  @override
  String get diagnosticsStalledAttachmentCancelTitle => 'Cancel this upload?';

  @override
  String get diagnosticsStalledAttachmentCancelBody =>
      'The attachment will not be sent and its local copy is removed. This cannot be undone.';

  @override
  String get diagnosticsStalledAttachmentCancelConfirm => 'Cancel upload';

  @override
  String get diagnosticsStalledAttachmentCancelDismiss => 'Keep';

  @override
  String get diagnosticsStalledAttachmentCancelFailed =>
      'The upload could not be cancelled.';

  @override
  String get diagnosticsStalledAttachmentLocked =>
      'Already handed to the server, cannot be cancelled';

  @override
  String get diagnosticsOutboxPending => 'Waiting';

  @override
  String get diagnosticsOutboxFailed => 'Failed';

  @override
  String get diagnosticsOutboxLastError => 'Last error';

  @override
  String get diagnosticsSyncSection => 'Synchronisation';

  @override
  String get diagnosticsSyncLastSuccess => 'Last successful sync';

  @override
  String get diagnosticsSyncLastError => 'Last error';

  @override
  String get diagnosticsPushSection => 'Push registration';

  @override
  String get diagnosticsPushPhase => 'Phase';

  @override
  String get diagnosticsPushGeneration => 'Generation';

  @override
  String get diagnosticsPushNextGeneration => 'Next generation';

  @override
  String get diagnosticsPushPendingEvents => 'Queued events';

  @override
  String get diagnosticsPushPlatformUnsupported =>
      'Not available on this platform.';

  @override
  String diagnosticsPushReadFailed(String code) {
    return 'Could not be read ($code).';
  }

  @override
  String get diagnosticsCapabilitiesSection => 'Talk capabilities';

  @override
  String get diagnosticsTalkFeatureCount => 'Reported features';

  @override
  String get diagnosticsValueNone => 'None';

  @override
  String get diagnosticsValueNever => 'Never';

  @override
  String get diagnosticsValueYes => 'Yes';

  @override
  String get diagnosticsValueNo => 'No';

  @override
  String get profileTitle => 'Profile and status';

  @override
  String get profileUserIdLabel => 'User ID';

  @override
  String get profileEmailLabel => 'Email';

  @override
  String get profileServerLabel => 'Server';

  @override
  String get profileStatusSection => 'Availability';

  @override
  String get profileStatusUnavailable =>
      'This server does not advertise compatible user status support.';

  @override
  String get profileStatusOnline => 'Online';

  @override
  String get profileStatusAway => 'Away';

  @override
  String get profileStatusBusy => 'Busy';

  @override
  String get profileStatusDoNotDisturb => 'Do not disturb';

  @override
  String get profileStatusInvisible => 'Invisible';

  @override
  String get profileStatusOffline => 'Offline';

  @override
  String get profileStatusIconLabel => 'Status emoji';

  @override
  String get profileStatusIconHelp =>
      'Use a single emoji supported by your server.';

  @override
  String get profileStatusMessageLabel => 'Status message';

  @override
  String get profileStatusSave => 'Save status';

  @override
  String get profileStatusClear => 'Clear message';

  @override
  String get profileStatusExpiryLabel => 'Clear status';

  @override
  String get profileStatusExpiryNever => 'Never';

  @override
  String get profileStatusExpiryHalfHour => 'In 30 minutes';

  @override
  String get profileStatusExpiryHour => 'In an hour';

  @override
  String get profileStatusExpiryFourHours => 'In 4 hours';

  @override
  String get profileStatusExpiryToday => 'Today';

  @override
  String get profileStatusExpiryWeek => 'This week';

  @override
  String get profileStatusSaved => 'Status updated.';

  @override
  String get profileErrorAccountMissing =>
      'This account is no longer available.';

  @override
  String get profileErrorReauth =>
      'Sign in again to open or change your profile.';

  @override
  String get profileErrorForbidden =>
      'The server did not permit this profile action.';

  @override
  String get profileErrorRateLimited => 'Too many requests. Try again soon.';

  @override
  String get profileErrorUnavailable =>
      'The profile service is temporarily unavailable.';

  @override
  String get profileErrorNetwork => 'Could not reach the server.';

  @override
  String get profileErrorInvalidInput =>
      'Use at most 80 message characters and one status emoji.';

  @override
  String get profileErrorInvalidResponse =>
      'The server sent an unexpected profile response.';

  @override
  String get conversationActionsTitle => 'Conversation actions';

  @override
  String get conversationActionMarkUnread => 'Mark as unread';

  @override
  String get conversationActionArchive => 'Archive conversation';

  @override
  String get conversationActionUnarchive => 'Unarchive conversation';

  @override
  String get conversationFiltersLabel => 'Conversation filters';

  @override
  String get conversationFilterUnread => 'Unread';

  @override
  String get conversationFilterMentions => 'Mentions';

  @override
  String get conversationFilterArchived => 'Archived';

  @override
  String get conversationFilterNoResults => 'No matching conversations';

  @override
  String get conversationFilterNoResultsBody =>
      'Change or clear a filter to show more conversations.';

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
  String searchMessagesInConversation(String conversation) {
    return 'Search in $conversation';
  }

  @override
  String get searchInConversation => 'Search in conversation';

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
  String get newConversationPublicNameDialogTitle =>
      'Name this public conversation';

  @override
  String get newConversationNameLabel => 'Conversation name';

  @override
  String get newConversationCreate => 'Create';

  @override
  String get newConversationCreateGroupAction => 'Create group conversation';

  @override
  String get newConversationCreatePublicAction => 'Create public conversation';

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
  String get callBannerTitle => 'Call in progress';

  @override
  String callBannerRunningFor(String duration) {
    return 'Running for $duration';
  }

  @override
  String get callBannerJoin => 'Join call';

  @override
  String get callStartAudio => 'Start a call';

  @override
  String get callStartVideo => 'Start a call with video';

  @override
  String get callBannerLeave => 'Leave call';

  @override
  String get callBannerMute => 'Mute microphone';

  @override
  String get callBannerUnmute => 'Unmute microphone';

  @override
  String get callBannerSpeakerOn => 'Switch to speaker';

  @override
  String get callBannerSpeakerOff => 'Switch to earpiece';

  @override
  String get callBannerAudioRoute => 'Audio output';

  @override
  String get callAudioRouteSpeaker => 'Speaker';

  @override
  String get callAudioRouteEarpiece => 'Earpiece';

  @override
  String get callAudioRouteBluetooth => 'Bluetooth';

  @override
  String get callAudioRouteWiredHeadset => 'Wired headset';

  @override
  String get callBannerRaiseHand => 'Raise hand';

  @override
  String get callBannerLowerHand => 'Lower hand';

  @override
  String get callBannerReact => 'Send a reaction';

  @override
  String get callBannerOpenCallView => 'Open the call view';

  @override
  String callScreenTitle(int count) {
    return 'Call ($count)';
  }

  @override
  String get callBannerCameraOn => 'Turn camera on';

  @override
  String get callBannerCameraOff => 'Turn camera off';

  @override
  String callParticipantsTitle(int count) {
    return 'In the call ($count)';
  }

  @override
  String get callParticipantsYou => 'You';

  @override
  String callScreenSharedBy(String name) {
    return '$name is sharing their screen';
  }

  @override
  String get callBannerShareScreen => 'Share your screen';

  @override
  String get callBannerStopSharing => 'Stop sharing your screen';

  @override
  String get callBannerStartRecording => 'Start recording';

  @override
  String get callBannerStopRecording => 'Stop recording';

  @override
  String get callParticipantConnected => 'Audio connected';

  @override
  String get callParticipantConnecting => 'Connecting…';

  @override
  String get callParticipantMuted => 'Muted';

  @override
  String get callParticipantHandRaised => 'Hand raised';

  @override
  String get callParticipantNotResponding => 'Not responding';

  @override
  String get callBannerJoining => 'Joining the call…';

  @override
  String callBannerTransportReady(String transport) {
    return 'The call runs through $transport.';
  }

  @override
  String get callBannerAudioNegotiating => 'Connecting audio…';

  @override
  String get callBannerAudioConnected => 'Audio connected';

  @override
  String get callBannerAudioWaiting => 'Waiting for the other participants…';

  @override
  String get callBannerMicrophoneDenied =>
      'The microphone was refused. Allow it in the system settings and join again.';

  @override
  String get callBannerMicrophoneUnavailable =>
      'The microphone could not be opened.';

  @override
  String get callBannerAudioFailed =>
      'The call audio could not be established.';

  @override
  String get callBannerAudioSignalingLost =>
      'The connection to the call server dropped, so the audio stopped.';

  @override
  String get callBannerMcuUnsupported =>
      'This server routes calls through a central media server, which this app cannot join yet.';

  @override
  String get callBannerJoinFailed => 'Joining the call failed.';

  @override
  String get callBannerSignalingUnavailable =>
      'The server has not opened a call in this conversation, so it cannot be joined.';

  @override
  String get callBannerTransportChecking => 'Checking where this call goes…';

  @override
  String get callBannerTransportUnavailable =>
      'This call cannot be joined right now. Try again in a moment.';

  @override
  String get callBannerTransportReauth =>
      'Sign in again before you can join the call.';

  @override
  String get callBannerTransportRoomUnavailable =>
      'This conversation is no longer available on the server.';

  @override
  String get callTransportInternal => 'this Nextcloud';

  @override
  String get callTransportExternalHpb => 'a separate call server';

  @override
  String get messageActionNoteToSelf => 'Send to Note to self';

  @override
  String get messageActionForward => 'Forward';

  @override
  String get messageActionPrivateReply => 'Reply privately';

  @override
  String get privateReplyTitle => 'Private reply';

  @override
  String get privateReplyHint => 'Write your reply';

  @override
  String get privateReplyExplanation =>
      'The reply goes to your private conversation with the author, not here.';

  @override
  String get privateReplySend => 'Send';

  @override
  String privateReplySent(String author) {
    return 'Reply sent to your private conversation with $author';
  }

  @override
  String get privateReplyFailed => 'The private reply could not be sent.';

  @override
  String get privateReplyUnsupported =>
      'The server does not support private replies.';

  @override
  String get forwardMessageTitle => 'Forward to conversation';

  @override
  String get forwardNoConversations => 'No other conversation is available.';

  @override
  String messageForwarded(String conversation) {
    return 'Message forwarded to $conversation';
  }

  @override
  String get messageForwardFailed => 'The message could not be forwarded.';

  @override
  String get cancelSend => 'Cancel sending';

  @override
  String get outboxCancelAmbiguous =>
      'This message may already have reached the server, so it can no longer be cancelled.';

  @override
  String get roomDetailsDeleteAction => 'Delete conversation';

  @override
  String get roomDetailsDeleteDialogTitle => 'Delete conversation?';

  @override
  String get roomDetailsDeleteDialogMessage =>
      'The conversation and all of its messages are removed for everyone. This cannot be undone.';

  @override
  String get roomDetailsDeleteDialogConfirm => 'Delete';

  @override
  String get roomDetailsDeleteRejected =>
      'This conversation cannot be deleted. You can only leave a one-to-one conversation.';

  @override
  String get saveImage => 'Save image';

  @override
  String get shareImage => 'Share image';

  @override
  String get imageSavedToGallery => 'Image saved to your gallery.';

  @override
  String get imageSavePermissionDenied =>
      'Saving needs access to your gallery. Grant it in the system settings and try again.';

  @override
  String get imageSaveOutOfSpace =>
      'There is not enough free space to save the image.';

  @override
  String get imageSaveFailed => 'The image could not be saved.';

  @override
  String get imageShareFailed => 'The image could not be shared.';

  @override
  String get saveAttachment => 'Save attachment';

  @override
  String get shareAttachment => 'Share attachment';

  @override
  String get attachmentSaved => 'Attachment saved.';

  @override
  String get attachmentSaveFailed => 'The attachment could not be saved.';

  @override
  String get attachmentShareFailed => 'The attachment could not be shared.';

  @override
  String get attachmentSaveCancelled => 'Saving cancelled.';

  @override
  String get attachmentDownloading => 'Downloading the attachment…';

  @override
  String attachmentDownloadingPercent(Object percent) {
    return 'Downloading the attachment… $percent%';
  }

  @override
  String get attachmentDownloadFailed =>
      'The attachment could not be downloaded.';

  @override
  String get attachmentReauthenticationRequired =>
      'Sign in again to download this attachment.';

  @override
  String get attachmentTooLarge => 'This attachment is too large to export.';

  @override
  String get attachmentInvalid => 'This attachment is no longer valid.';

  @override
  String get attachmentPermissionDenied =>
      'The selected location does not allow this file to be saved.';

  @override
  String get attachmentStorageFailed =>
      'The attachment could not be written to the selected location.';

  @override
  String get jumpToOriginalMessage => 'Show the original message';

  @override
  String get jumpToMessageNotFound =>
      'That message is no longer available in this conversation.';

  @override
  String get jumpToMessageConversationMissing =>
      'That conversation is not available on this device.';

  @override
  String get searchMessagesErrorAccountMissing =>
      'This account is no longer available.';

  @override
  String get searchMessagesErrorCredentialMissing =>
      'Sign in again to search messages.';

  @override
  String get searchMessagesErrorReauthentication =>
      'Your session expired. Sign in again.';

  @override
  String get searchMessagesErrorProviderMissing =>
      'This server does not offer message search.';

  @override
  String get searchMessagesErrorTransient =>
      'The server is busy. Try again in a moment.';

  @override
  String get searchMessagesErrorServer => 'The server rejected the search.';

  @override
  String get searchMessagesErrorInvalidResponse =>
      'The server sent a search response this app could not read.';

  @override
  String get searchMessagesErrorNetwork => 'Could not reach the server.';

  @override
  String get addAttachment => 'Add attachment';

  @override
  String get attachFromGallery => 'Choose a picture';

  @override
  String get attachFromCamera => 'Take a picture';

  @override
  String get attachFromFile => 'Choose a file';

  @override
  String get attachmentCameraDenied =>
      'Taking a picture needs camera access. Grant it in the system settings and try again.';

  @override
  String get attachmentCameraUnavailable =>
      'No camera is available on this device.';

  @override
  String get attachmentGalleryDenied =>
      'Choosing a photo needs gallery access. Grant it in the system settings and try again.';

  @override
  String get attachmentGalleryUnavailable =>
      'The photo library is unavailable on this device.';

  @override
  String get attachmentTypeUnsupported =>
      'That file type cannot be attached here.';

  @override
  String get pauseVoiceRecording => 'Pause recording';

  @override
  String get resumeVoiceRecording => 'Resume recording';

  @override
  String get voiceRecordingLevel => 'Recording level';

  @override
  String get voicePauseFailed => 'The recording could not be paused.';

  @override
  String get pauseVoiceMessage => 'Pause voice message';

  @override
  String get voiceMessagePosition => 'Playback position';

  @override
  String voiceMessageProgress(String position, String duration) {
    return '$position of $duration';
  }

  @override
  String get settingsRemoveAccount => 'Remove account';

  @override
  String get settingsRemoveAccountDialogTitle => 'Remove this account?';

  @override
  String settingsRemoveAccountDialogMessage(
    Object loginName,
    Object serverUrl,
  ) {
    return '$loginName on $serverUrl will be removed from this device. Its conversations, messages, drafts, queued uploads, cached pictures and voice messages, and its stored password are deleted, and the app password is revoked on the server.';
  }

  @override
  String get settingsRemoveAccountDialogConfirm => 'Remove';

  @override
  String get settingsRemoveAccountDone => 'The account was removed.';

  @override
  String get settingsRemoveAccountDoneNotRevoked =>
      'The account was removed from this device, but the server did not confirm the app password was revoked. The app keeps retrying for a while once the server is reachable; you can also revoke it yourself under Settings, Security on the server.';

  @override
  String get roomDetailsGuestsLabel => 'Guests';

  @override
  String get roomDetailsGuestsAllowed => 'Anyone with the link can join';

  @override
  String get roomDetailsGuestsBlocked => 'Invited people only';

  @override
  String get roomDetailsGuestsCloseDialogTitle => 'Stop allowing guests?';

  @override
  String get roomDetailsGuestsCloseDialogMessage =>
      'The link stops working and any guest who joined through it loses access. Invited participants are not affected.';

  @override
  String get roomDetailsGuestsCloseDialogConfirm => 'Make private';

  @override
  String get roomDetailsInviteLinkAction => 'Share the guest link';

  @override
  String get roomDetailsInviteLinkSubtitle =>
      'Anyone with this link can join as a guest';

  @override
  String get roomDetailsInviteLinkShareSubject => 'Join the conversation';

  @override
  String get roomDetailsPasswordLabel => 'Password';

  @override
  String get roomDetailsPasswordSet => 'Guests need a password';

  @override
  String get roomDetailsPasswordUnset => 'No password';

  @override
  String get roomDetailsPasswordDialogTitle => 'Password for guests';

  @override
  String get roomDetailsPasswordFieldLabel => 'New password';

  @override
  String get roomDetailsPasswordRemoveAction => 'Remove the password';

  @override
  String get roomDetailsPasswordRemoveDialogTitle => 'Remove the password?';

  @override
  String get roomDetailsPasswordRemoveDialogMessage =>
      'Anyone with the link will be able to join without a password.';

  @override
  String get roomDetailsPasswordRemoveDialogConfirm => 'Remove';

  @override
  String get roomDetailsPasswordRejected => 'The server refused this password.';

  @override
  String get roomDetailsLobbyLabel => 'Lobby';

  @override
  String get roomDetailsBreakoutLabel => 'Breakout rooms';

  @override
  String get roomDetailsBreakoutNotConfigured => 'None yet';

  @override
  String get roomDetailsBreakoutStopped => 'Created, not started';

  @override
  String get roomDetailsBreakoutStarted => 'Started';

  @override
  String roomDetailsBreakoutAssistanceRequested(String rooms) {
    return 'Started — $rooms asks for a moderator';
  }

  @override
  String get roomDetailsBreakoutCreate => 'Create breakout rooms';

  @override
  String get roomDetailsBreakoutCreateDialogTitle => 'How many breakout rooms?';

  @override
  String get roomDetailsBreakoutModeAutomatic => 'Spread everyone evenly';

  @override
  String get roomDetailsBreakoutModeManual => 'Assign people myself';

  @override
  String get roomDetailsBreakoutModeFree => 'Let people pick a room';

  @override
  String get roomDetailsBreakoutAssignTitle => 'Who goes where';

  @override
  String roomDetailsBreakoutAssignRoom(int number) {
    return 'Room $number';
  }

  @override
  String get roomDetailsBreakoutAssignUnassigned => 'Not assigned';

  @override
  String get roomDetailsBreakoutAssignConfirm => 'Create';

  @override
  String get roomDetailsBreakoutSwitch => 'Move to another room';

  @override
  String get roomDetailsBreakoutSwitchTitle => 'Which room?';

  @override
  String get roomDetailsBreakoutSwitchEmpty =>
      'No breakout room is open right now.';

  @override
  String roomDetailsBreakoutSwitched(String name) {
    return 'You are now in $name.';
  }

  @override
  String get roomDetailsBreakoutStart => 'Start the breakout rooms';

  @override
  String get roomDetailsBreakoutStop => 'Stop the breakout rooms';

  @override
  String get roomDetailsBreakoutBroadcast => 'Message all breakout rooms';

  @override
  String get roomDetailsBreakoutBroadcastHint =>
      'One message, posted in every breakout room';

  @override
  String get roomDetailsBreakoutBroadcastSend => 'Send';

  @override
  String get roomDetailsBreakoutRemove => 'Remove the breakout rooms';

  @override
  String get roomDetailsBreakoutRemoveDialogTitle =>
      'Remove the breakout rooms?';

  @override
  String get roomDetailsBreakoutRemoveDialogMessage =>
      'The breakout rooms and their chats are deleted. The main conversation stays.';

  @override
  String get roomDetailsBreakoutRemoveDialogConfirm => 'Remove';

  @override
  String get roomDetailsBreakoutRequestAssistance =>
      'Ask a moderator to come over';

  @override
  String get roomDetailsBreakoutWithdrawAssistance =>
      'Withdraw the request for a moderator';

  @override
  String get roomDetailsLobbyOff => 'Everyone can take part';

  @override
  String get roomDetailsLobbyOn => 'Only moderators can take part';

  @override
  String roomDetailsLobbyOnUntil(String time) {
    return 'Only moderators until $time';
  }

  @override
  String get roomDetailsLobbyDialogTitle => 'Open the lobby';

  @override
  String get roomDetailsLobbyDialogMessage =>
      'While the lobby is on, only moderators can read, write and call. Pick when it should open, or leave it for a moderator to open by hand.';

  @override
  String get roomDetailsLobbyTimerNone => 'No end time';

  @override
  String get roomDetailsLobbyTimerPick => 'Pick a date and time';

  @override
  String get roomDetailsLobbyDialogConfirm => 'Turn the lobby on';

  @override
  String get roomDetailsSipLabel => 'Phone and SIP dial-in';

  @override
  String get roomDetailsSipDisabled => 'Disabled';

  @override
  String get roomDetailsSipWithPin => 'Enabled with a personal PIN';

  @override
  String get roomDetailsSipWithoutPin => 'Enabled without a PIN';

  @override
  String get roomDetailsSipDialogTitle => 'Phone and SIP dial-in';

  @override
  String get roomDetailsSipNotConfigured =>
      'SIP dial-in is not configured on this server.';

  @override
  String get roomDetailsSipDialInHeader => 'Dial-in information';

  @override
  String get roomDetailsSipInstructionsLoadError =>
      'Dial-in instructions could not be loaded.';

  @override
  String get roomDetailsSipInstructionsUnavailable =>
      'The server did not provide dial-in instructions.';

  @override
  String get roomDetailsSipMeetingId => 'Meeting ID';

  @override
  String get roomDetailsSipPersonalPin => 'Your PIN';

  @override
  String get roomDetailsSipPinUnavailable =>
      'The server has not provided your PIN yet.';

  @override
  String get roomDetailsReadOnlyToggleLabel => 'Read-only';

  @override
  String get roomDetailsReadOnlyToggleOn => 'Nobody can write or call';

  @override
  String get roomDetailsReadOnlyToggleOff => 'Everyone can write';

  @override
  String get roomDetailsReadOnlyDialogTitle => 'Lock the conversation?';

  @override
  String get roomDetailsReadOnlyDialogMessage =>
      'Nobody will be able to send messages or start a call until a moderator unlocks it again.';

  @override
  String get roomDetailsReadOnlyDialogConfirm => 'Lock';

  @override
  String get roomDetailsAvatarAction => 'Conversation picture';

  @override
  String get roomDetailsAvatarDialogTitle => 'Conversation picture';

  @override
  String get roomDetailsAvatarDialogMessage =>
      'Pick an emoji to use as the conversation picture.';

  @override
  String get roomDetailsAvatarSetAction => 'Use this emoji';

  @override
  String get roomDetailsAvatarColorLabel => 'Background colour';

  @override
  String get roomDetailsAvatarColorDefault => 'Follow light or dark mode';

  @override
  String get roomDetailsChatBackgroundAction => 'Chat background';

  @override
  String roomDetailsAvatarColorSemantics(String color) {
    return 'Colour $color';
  }

  @override
  String get roomDetailsAvatarRemoveAction => 'Remove the picture';

  @override
  String roomDetailsAvatarEmojiSemantics(String emoji) {
    return 'Emoji $emoji';
  }

  @override
  String get roomDetailsBanParticipant => 'Ban from the conversation';

  @override
  String get roomDetailsBanDialogTitle => 'Ban this participant?';

  @override
  String roomDetailsBanDialogMessage(String name) {
    return '$name is removed from the conversation and cannot rejoin until the ban is lifted.';
  }

  @override
  String get roomDetailsBanNoteLabel => 'Reason (only moderators see it)';

  @override
  String get roomDetailsBanDialogConfirm => 'Ban';

  @override
  String get roomDetailsBansAction => 'Banned participants';

  @override
  String get roomDetailsBansDialogTitle => 'Banned participants';

  @override
  String get roomDetailsBansEmpty => 'Nobody is banned.';

  @override
  String get roomDetailsBansLoadError => 'Bans could not be loaded.';

  @override
  String get roomDetailsUnbanAction => 'Lift the ban';

  @override
  String get roomDetailsBanRejected => 'The server refused this ban.';

  @override
  String get roomDetailsClearHistoryAction => 'Clear conversation history';

  @override
  String get roomDetailsClearHistoryDialogTitle =>
      'Clear conversation history?';

  @override
  String get roomDetailsClearHistoryDialogMessage =>
      'This permanently deletes messages and threads for everyone in this conversation. This cannot be undone.';

  @override
  String get roomDetailsClearHistoryConfirm => 'Clear history';

  @override
  String get roomDetailsClearHistorySucceeded =>
      'Conversation history was cleared.';

  @override
  String get roomDetailsClearHistoryExternalCopiesWarning =>
      'Conversation history was cleared here. External services may still retain copies.';

  @override
  String get roomDetailsClearHistoryRefreshFailed =>
      'Conversation history was cleared, but the latest conversation state could not be loaded yet. Reopen the conversation to refresh it.';

  @override
  String get roomDetailsConversationTagsAction => 'Conversation tags';

  @override
  String roomDetailsConversationTagsSelectedCount(int count) {
    return 'Selected: $count';
  }

  @override
  String get roomDetailsConversationTagsDialogTitle => 'Conversation tags';

  @override
  String get roomDetailsConversationTagsDialogHint =>
      'Choose the tags used to organise this conversation for your account.';

  @override
  String get roomDetailsConversationTagsEmpty =>
      'Create a custom tag in Nextcloud Talk before assigning it here.';

  @override
  String get roomDetailsConversationTagsSave => 'Save tags';

  @override
  String get roomDetailsConversationTagsSaved => 'Conversation tags updated.';

  @override
  String get roomDetailsConversationTagsUnsupported =>
      'This server no longer supports conversation tags.';

  @override
  String get roomDetailsAvatarPickImage => 'Choose a picture';

  @override
  String get roomDetailsAvatarTypeRejected =>
      'Only a square PNG or JPEG works as a conversation picture.';

  @override
  String get roomDetailsAvatarTooLarge => 'That picture is too large.';

  @override
  String get roomDetailsAvatarRejected =>
      'The server would not take this picture.';

  @override
  String get messageActionPin => 'Pin message';

  @override
  String get messageActionUnpin => 'Unpin message';

  @override
  String get messagePinned => 'Message pinned';

  @override
  String get messageUnpinned => 'Message unpinned';

  @override
  String get pinnedMessageLabel => 'Pinned message';

  @override
  String get pinnedMessageOpen => 'Show pinned message';

  @override
  String get pinnedMessageHide => 'Hide for me';

  @override
  String get messageActionRemind => 'Remind me';

  @override
  String get reminderTitle => 'Remind me about this message';

  @override
  String get reminderLaterToday => 'Later today';

  @override
  String get reminderTomorrow => 'Tomorrow morning';

  @override
  String get reminderThisWeekend => 'This weekend';

  @override
  String get reminderNextWeek => 'Next week';

  @override
  String get reminderCustom => 'Pick a date and time';

  @override
  String get reminderRemove => 'Remove reminder';

  @override
  String reminderSet(String time) {
    return 'Reminder set for $time';
  }

  @override
  String get reminderRemoved => 'Reminder removed';

  @override
  String reminderExisting(String time) {
    return 'Reminder set for $time';
  }

  @override
  String get scheduleMessage => 'Send later';

  @override
  String get scheduleMessageTitle => 'Send this message later';

  @override
  String scheduleMessageSet(String time) {
    return 'Message scheduled for $time';
  }

  @override
  String get scheduledMessagesTitle => 'Scheduled messages';

  @override
  String get scheduledMessagesOpen => 'Scheduled messages';

  @override
  String get scheduledMessagesEmpty =>
      'Nothing is scheduled in this conversation.';

  @override
  String get scheduledMessageDelete => 'Delete scheduled message';

  @override
  String get scheduledMessageDeleted => 'Scheduled message deleted';

  @override
  String get scheduleTimeInPast => 'Pick a time in the future.';

  @override
  String get roomDetailsSharedItemsAction => 'Shared items';

  @override
  String get sharedItemsTitle => 'Shared items';

  @override
  String get sharedItemsEmpty =>
      'Nothing has been shared in this category yet.';

  @override
  String get sharedItemsLoadMore => 'Load more';

  @override
  String get sharedItemsCategoryAudio => 'Audio';

  @override
  String get sharedItemsCategoryDeckCards => 'Deck cards';

  @override
  String get sharedItemsCategoryFiles => 'Files';

  @override
  String get sharedItemsCategoryLocations => 'Locations';

  @override
  String get sharedItemsCategoryMedia => 'Media';

  @override
  String get sharedItemsCategoryOther => 'Other';

  @override
  String get sharedItemsCategoryPinned => 'Pinned';

  @override
  String get sharedItemsCategoryPolls => 'Polls';

  @override
  String get sharedItemsCategoryRecordings => 'Recordings';

  @override
  String get sharedItemsCategoryVoice => 'Voice messages';

  @override
  String get sharedItemsUnsupported =>
      'Shared items are not available for this conversation.';

  @override
  String get sharedItemsLobbyRestricted =>
      'Shared items are hidden while you are waiting in the lobby.';

  @override
  String get sharedItemsInvalidResponse =>
      'The server returned an invalid shared-items response.';

  @override
  String get messageActionTranslate => 'Translate';

  @override
  String get translationTitle => 'Translate message';

  @override
  String get translationFrom => 'Translate from';

  @override
  String get translationTo => 'Translate to';

  @override
  String get translationDetectLanguage => 'Detect language';

  @override
  String get translationAction => 'Translate';

  @override
  String get translationAiNotice =>
      'This translation is AI generated and may contain mistakes.';

  @override
  String get translationCopy => 'Copy translated text';

  @override
  String get translationCopied => 'Translation copied to clipboard';

  @override
  String get translationCopyFailed => 'Translation could not be copied.';

  @override
  String get translationUnavailable =>
      'Message translation is not available on this server.';

  @override
  String get translationInvalidInput =>
      'This message or language selection cannot be translated.';

  @override
  String get translationInvalidResponse =>
      'The server returned an invalid translation response.';

  @override
  String get pollCreateTitle => 'Create poll';

  @override
  String get pollCreated => 'Poll created';

  @override
  String get pollCreateAction => 'Create';

  @override
  String get pollVoteAction => 'Vote';

  @override
  String get pollQuestion => 'Question';

  @override
  String get pollQuestionRequired => 'Enter a question.';

  @override
  String pollOption(int number) {
    return 'Option $number';
  }

  @override
  String get pollOptionRequired => 'Enter an option.';

  @override
  String get pollAddOption => 'Add option';

  @override
  String get pollRemoveOption => 'Remove option';

  @override
  String get pollMultipleAnswers => 'Allow multiple answers';

  @override
  String get pollHiddenResults => 'Hide results until the poll ends';

  @override
  String get pollSelectOption => 'Select at least one option.';

  @override
  String get pollUnsupported => 'Polls are not available in this conversation.';

  @override
  String get pollPermissionDenied => 'You cannot create or vote in this poll.';

  @override
  String get pollRateLimited => 'Too many poll requests. Try again later.';

  @override
  String get pollAmbiguous =>
      'The server may have accepted this action. Refresh the conversation before trying again.';

  @override
  String get pollFailed => 'The poll action failed.';

  @override
  String get pollSignInAgain => 'Sign in to this account again.';

  @override
  String get pollMenuAction => 'Poll';

  @override
  String get pollChecking => 'Checking poll support…';

  @override
  String get pollLoading => 'Loading poll…';

  @override
  String get pollReloadAction => 'Try again';

  @override
  String pollOpenAction(String name) {
    return 'Open poll $name';
  }

  @override
  String typingOne(String name) {
    return '$name is typing…';
  }

  @override
  String typingTwo(String first, String second) {
    return '$first and $second are typing…';
  }

  @override
  String typingThree(String first, String second, String third) {
    return '$first, $second and $third are typing…';
  }

  @override
  String typingOneOther(String first, String second, String third) {
    return '$first, $second, $third and 1 other are typing…';
  }

  @override
  String typingOthers(String first, String second, String third, int count) {
    return '$first, $second, $third and $count others are typing…';
  }

  @override
  String get certificateUnverifiedTitle => 'Unverified server certificate';

  @override
  String certificateUnverifiedBody(String host) {
    return '$host presented a certificate this device cannot verify. Continue only if the fingerprint below is the one your server shows.';
  }

  @override
  String get certificateFingerprintLabel => 'SHA-256 fingerprint';

  @override
  String get certificateTrustAction => 'Trust and continue';

  @override
  String get certificateChangedTitle => 'Server certificate changed';

  @override
  String certificateChangedBody(String host) {
    return '$host now presents a different certificate than the one this account trusts. If you replaced the certificate yourself, remove the account and add it again.';
  }

  @override
  String get attachFromServer => 'File from Nextcloud';

  @override
  String get remoteFilesTitle => 'Files';

  @override
  String get remoteFilesEmpty => 'This folder is empty.';

  @override
  String remoteFilesTruncated(int count) {
    return 'Showing the first $count items of this folder.';
  }

  @override
  String get remoteFilesLoadFailed => 'This folder could not be loaded.';

  @override
  String get remoteFilesSignInAgain => 'This account must be signed in again.';

  @override
  String get remoteFilesShareTitle => 'Share this file into the conversation?';

  @override
  String remoteFilesShareBody(String name) {
    return '$name stays on your server. Everyone in this conversation gets access to it until you remove the share in Files.';
  }

  @override
  String get remoteFilesShareAction => 'Share';

  @override
  String get remoteFilesShared => 'The file was shared into the conversation.';

  @override
  String get remoteFilesShareFailed => 'The file could not be shared.';

  @override
  String get remoteFilesShareForbidden =>
      'This account may not share that file here.';

  @override
  String get openConversations => 'Open conversations';

  @override
  String get openConversationsEmpty =>
      'This server publishes no open conversations.';

  @override
  String get openConversationsJoin => 'Join';

  @override
  String federationInvitationsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count invitations to conversations on other servers',
      one: '1 invitation to a conversation on another server',
    );
    return '$_temp0';
  }

  @override
  String get federationInvitationsShow => 'Show';

  @override
  String get federationInvitationsTitle => 'Federated invitations';

  @override
  String get federationInvitationsEmpty => 'No pending invitations.';

  @override
  String federationInvitationFrom(String inviter, String server) {
    return 'From $inviter on $server';
  }

  @override
  String get federationInvitationAccept => 'Accept';

  @override
  String get federationInvitationDecline => 'Decline';

  @override
  String get federationInvitationAccepted =>
      'Invitation accepted. The conversation is now in your list.';

  @override
  String get federationInvitationDeclined => 'Invitation declined.';

  @override
  String get federationInvitationGone =>
      'This invitation is no longer available.';

  @override
  String get federationInvitationFailed =>
      'The invitation could not be processed. Try again later.';

  @override
  String get openConversationsPasswordTitle =>
      'This conversation has a password';

  @override
  String get openConversationsPasswordLabel => 'Conversation password';

  @override
  String get openConversationsJoined => 'You joined the conversation.';

  @override
  String get newConversationErrorUnavailable =>
      'This conversation is no longer open.';

  @override
  String get newConversationErrorPasswordRejected =>
      'The conversation password is wrong.';
}
