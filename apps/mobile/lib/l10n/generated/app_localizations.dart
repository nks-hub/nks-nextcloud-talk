import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_cs.dart';
import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('cs'),
    Locale('en'),
  ];

  /// No description provided for @dateHeaderToday.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get dateHeaderToday;

  /// No description provided for @dateHeaderYesterday.
  ///
  /// In en, this message translates to:
  /// **'Yesterday'**
  String get dateHeaderYesterday;

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'NKS Talk'**
  String get appTitle;

  /// No description provided for @onboardingTitle.
  ///
  /// In en, this message translates to:
  /// **'Your conversations, one app'**
  String get onboardingTitle;

  /// No description provided for @onboardingBody.
  ///
  /// In en, this message translates to:
  /// **'Connect any supported Nextcloud server. Accounts, cache and background work stay strictly separated.'**
  String get onboardingBody;

  /// No description provided for @multiServerTitle.
  ///
  /// In en, this message translates to:
  /// **'Built for multiple servers'**
  String get multiServerTitle;

  /// No description provided for @multiServerBody.
  ///
  /// In en, this message translates to:
  /// **'Add personal and work accounts without rebuilding the app or sharing their data.'**
  String get multiServerBody;

  /// No description provided for @secureTitle.
  ///
  /// In en, this message translates to:
  /// **'Credentials stay on this device'**
  String get secureTitle;

  /// No description provided for @secureBody.
  ///
  /// In en, this message translates to:
  /// **'App passwords are stored in the system Keychain or Keystore, never in the conversation database.'**
  String get secureBody;

  /// No description provided for @addServerTitle.
  ///
  /// In en, this message translates to:
  /// **'Add a Nextcloud server'**
  String get addServerTitle;

  /// No description provided for @serverAddressLabel.
  ///
  /// In en, this message translates to:
  /// **'Server address'**
  String get serverAddressLabel;

  /// No description provided for @serverAddressHint.
  ///
  /// In en, this message translates to:
  /// **'cloud.example.com'**
  String get serverAddressHint;

  /// No description provided for @connect.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get connect;

  /// No description provided for @checkingServer.
  ///
  /// In en, this message translates to:
  /// **'Checking the server…'**
  String get checkingServer;

  /// No description provided for @openingLogin.
  ///
  /// In en, this message translates to:
  /// **'Opening secure sign-in…'**
  String get openingLogin;

  /// No description provided for @waitingForLogin.
  ///
  /// In en, this message translates to:
  /// **'Finish signing in in your browser'**
  String get waitingForLogin;

  /// No description provided for @waitingForLoginBody.
  ///
  /// In en, this message translates to:
  /// **'This screen will continue automatically after Nextcloud approves the app.'**
  String get waitingForLoginBody;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get retry;

  /// No description provided for @invalidServer.
  ///
  /// In en, this message translates to:
  /// **'Enter a valid HTTPS Nextcloud address.'**
  String get invalidServer;

  /// No description provided for @serverUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The server could not be reached. Check the address and your connection.'**
  String get serverUnavailable;

  /// No description provided for @serverMaintenance.
  ///
  /// In en, this message translates to:
  /// **'This server is currently in maintenance mode.'**
  String get serverMaintenance;

  /// No description provided for @serverNotInstalled.
  ///
  /// In en, this message translates to:
  /// **'Nextcloud is not installed on this server yet.'**
  String get serverNotInstalled;

  /// No description provided for @serverUpgrade.
  ///
  /// In en, this message translates to:
  /// **'The server must finish its database upgrade first.'**
  String get serverUpgrade;

  /// No description provided for @invalidResponse.
  ///
  /// In en, this message translates to:
  /// **'The server returned a response this app cannot safely use.'**
  String get invalidResponse;

  /// No description provided for @browserUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The sign-in page could not be opened.'**
  String get browserUnavailable;

  /// No description provided for @loginTimedOut.
  ///
  /// In en, this message translates to:
  /// **'The sign-in request expired. Start it again.'**
  String get loginTimedOut;

  /// No description provided for @talkUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Nextcloud Talk is not available for this account.'**
  String get talkUnavailable;

  /// No description provided for @localPersistenceFailed.
  ///
  /// In en, this message translates to:
  /// **'The account could not be stored securely on this device.'**
  String get localPersistenceFailed;

  /// No description provided for @unexpectedError.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong. No account data was changed.'**
  String get unexpectedError;

  /// No description provided for @accounts.
  ///
  /// In en, this message translates to:
  /// **'Accounts'**
  String get accounts;

  /// No description provided for @conversations.
  ///
  /// In en, this message translates to:
  /// **'Conversations'**
  String get conversations;

  /// No description provided for @addAccount.
  ///
  /// In en, this message translates to:
  /// **'Add account'**
  String get addAccount;

  /// No description provided for @switchAccount.
  ///
  /// In en, this message translates to:
  /// **'Switch account'**
  String get switchAccount;

  /// No description provided for @refresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get refresh;

  /// No description provided for @syncing.
  ///
  /// In en, this message translates to:
  /// **'Syncing…'**
  String get syncing;

  /// No description provided for @cached.
  ///
  /// In en, this message translates to:
  /// **'Showing saved conversations'**
  String get cached;

  /// No description provided for @noConversations.
  ///
  /// In en, this message translates to:
  /// **'No conversations yet'**
  String get noConversations;

  /// No description provided for @noConversationsBody.
  ///
  /// In en, this message translates to:
  /// **'When a conversation appears on this Nextcloud account, it will be shown here.'**
  String get noConversationsBody;

  /// No description provided for @selectConversation.
  ///
  /// In en, this message translates to:
  /// **'Select a conversation'**
  String get selectConversation;

  /// No description provided for @selectConversationBody.
  ///
  /// In en, this message translates to:
  /// **'Choose a conversation to see its account-scoped details.'**
  String get selectConversationBody;

  /// No description provided for @conversationDetails.
  ///
  /// In en, this message translates to:
  /// **'Conversation details'**
  String get conversationDetails;

  /// No description provided for @server.
  ///
  /// In en, this message translates to:
  /// **'Server'**
  String get server;

  /// No description provided for @signedInAs.
  ///
  /// In en, this message translates to:
  /// **'Signed in as'**
  String get signedInAs;

  /// No description provided for @unreadMessages.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No unread messages} =1{1 unread message} other{{count} unread messages}}'**
  String unreadMessages(num count);

  /// No description provided for @lastMessageUnavailable.
  ///
  /// In en, this message translates to:
  /// **'New activity'**
  String get lastMessageUnavailable;

  /// No description provided for @syncCredentialMissing.
  ///
  /// In en, this message translates to:
  /// **'This account must be signed in again.'**
  String get syncCredentialMissing;

  /// No description provided for @syncTalkUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Talk is no longer available on this server.'**
  String get syncTalkUnavailable;

  /// No description provided for @syncUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This server does not expose a supported conversation API.'**
  String get syncUnsupported;

  /// No description provided for @syncRateLimited.
  ///
  /// In en, this message translates to:
  /// **'The server asked the app to wait before syncing again.'**
  String get syncRateLimited;

  /// No description provided for @syncUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Conversation sync is temporarily unavailable.'**
  String get syncUnavailable;

  /// No description provided for @syncUpgradeRequired.
  ///
  /// In en, this message translates to:
  /// **'The server must be upgraded before conversations can sync.'**
  String get syncUpgradeRequired;

  /// No description provided for @syncInvalidResponse.
  ///
  /// In en, this message translates to:
  /// **'Saved conversations are kept, but the latest server response was rejected.'**
  String get syncInvalidResponse;

  /// No description provided for @syncNetwork.
  ///
  /// In en, this message translates to:
  /// **'Offline. Saved conversations remain available.'**
  String get syncNetwork;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @chatEmpty.
  ///
  /// In en, this message translates to:
  /// **'No messages yet'**
  String get chatEmpty;

  /// No description provided for @chatEmptyBody.
  ///
  /// In en, this message translates to:
  /// **'Messages in this conversation will appear here.'**
  String get chatEmptyBody;

  /// No description provided for @messageHint.
  ///
  /// In en, this message translates to:
  /// **'Write a message'**
  String get messageHint;

  /// No description provided for @sendMessage.
  ///
  /// In en, this message translates to:
  /// **'Send message'**
  String get sendMessage;

  /// No description provided for @openEmojiPicker.
  ///
  /// In en, this message translates to:
  /// **'Open emoji picker'**
  String get openEmojiPicker;

  /// No description provided for @emojiSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search emoji'**
  String get emojiSearchHint;

  /// No description provided for @emojiNoResults.
  ///
  /// In en, this message translates to:
  /// **'No emoji found'**
  String get emojiNoResults;

  /// No description provided for @emojiCategorySmileys.
  ///
  /// In en, this message translates to:
  /// **'Smileys'**
  String get emojiCategorySmileys;

  /// No description provided for @emojiCategoryPeople.
  ///
  /// In en, this message translates to:
  /// **'People'**
  String get emojiCategoryPeople;

  /// No description provided for @emojiCategoryAnimals.
  ///
  /// In en, this message translates to:
  /// **'Animals'**
  String get emojiCategoryAnimals;

  /// No description provided for @emojiCategoryFood.
  ///
  /// In en, this message translates to:
  /// **'Food'**
  String get emojiCategoryFood;

  /// No description provided for @emojiCategoryActivities.
  ///
  /// In en, this message translates to:
  /// **'Activities'**
  String get emojiCategoryActivities;

  /// No description provided for @emojiCategoryTravel.
  ///
  /// In en, this message translates to:
  /// **'Travel'**
  String get emojiCategoryTravel;

  /// No description provided for @emojiCategoryObjects.
  ///
  /// In en, this message translates to:
  /// **'Objects'**
  String get emojiCategoryObjects;

  /// No description provided for @emojiCategorySymbols.
  ///
  /// In en, this message translates to:
  /// **'Symbols'**
  String get emojiCategorySymbols;

  /// No description provided for @openGiphyPicker.
  ///
  /// In en, this message translates to:
  /// **'Open GIF picker'**
  String get openGiphyPicker;

  /// No description provided for @giphyChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking GIF availability…'**
  String get giphyChecking;

  /// No description provided for @giphyRetry.
  ///
  /// In en, this message translates to:
  /// **'Try GIF integration again'**
  String get giphyRetry;

  /// No description provided for @giphyUnavailable.
  ///
  /// In en, this message translates to:
  /// **'GIFs are not available on this server.'**
  String get giphyUnavailable;

  /// No description provided for @giphySearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search GIFs'**
  String get giphySearchHint;

  /// No description provided for @giphyNoResults.
  ///
  /// In en, this message translates to:
  /// **'No GIFs found'**
  String get giphyNoResults;

  /// No description provided for @giphyLoadMore.
  ///
  /// In en, this message translates to:
  /// **'Load more'**
  String get giphyLoadMore;

  /// No description provided for @giphyPoweredBy.
  ///
  /// In en, this message translates to:
  /// **'Powered by GIPHY'**
  String get giphyPoweredBy;

  /// No description provided for @messageTooLong.
  ///
  /// In en, this message translates to:
  /// **'The message is too long.'**
  String get messageTooLong;

  /// No description provided for @loadOlderMessages.
  ///
  /// In en, this message translates to:
  /// **'Load older messages'**
  String get loadOlderMessages;

  /// No description provided for @loadingOlderMessages.
  ///
  /// In en, this message translates to:
  /// **'Loading older messages…'**
  String get loadingOlderMessages;

  /// No description provided for @readOnlyConversation.
  ///
  /// In en, this message translates to:
  /// **'This conversation is read-only.'**
  String get readOnlyConversation;

  /// No description provided for @deletedMessage.
  ///
  /// In en, this message translates to:
  /// **'Message deleted'**
  String get deletedMessage;

  /// No description provided for @outboxQueued.
  ///
  /// In en, this message translates to:
  /// **'Waiting to send'**
  String get outboxQueued;

  /// No description provided for @outboxSending.
  ///
  /// In en, this message translates to:
  /// **'Sending…'**
  String get outboxSending;

  /// No description provided for @outboxRetryable.
  ///
  /// In en, this message translates to:
  /// **'Waiting for a connection'**
  String get outboxRetryable;

  /// No description provided for @outboxAwaitingConfirmation.
  ///
  /// In en, this message translates to:
  /// **'The server may already have received this message.'**
  String get outboxAwaitingConfirmation;

  /// No description provided for @outboxFailed.
  ///
  /// In en, this message translates to:
  /// **'Message could not be sent'**
  String get outboxFailed;

  /// No description provided for @retrySend.
  ///
  /// In en, this message translates to:
  /// **'Retry sending'**
  String get retrySend;

  /// No description provided for @resendMessage.
  ///
  /// In en, this message translates to:
  /// **'Resend message'**
  String get resendMessage;

  /// No description provided for @duplicateRiskTitle.
  ///
  /// In en, this message translates to:
  /// **'Send this message again?'**
  String get duplicateRiskTitle;

  /// No description provided for @duplicateRiskBody.
  ///
  /// In en, this message translates to:
  /// **'The first attempt may have reached the server. Sending again can create a duplicate message.'**
  String get duplicateRiskBody;

  /// No description provided for @confirmResend.
  ///
  /// In en, this message translates to:
  /// **'Send again'**
  String get confirmResend;

  /// No description provided for @chatUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This server does not expose a supported chat API.'**
  String get chatUnsupported;

  /// No description provided for @chatUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Chat is temporarily unavailable. Saved messages remain visible.'**
  String get chatUnavailable;

  /// No description provided for @chatInvalidResponse.
  ///
  /// In en, this message translates to:
  /// **'Saved messages are kept, but the latest chat response was rejected.'**
  String get chatInvalidResponse;

  /// No description provided for @thread.
  ///
  /// In en, this message translates to:
  /// **'Thread'**
  String get thread;

  /// No description provided for @threadReplies.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 reply} other{{count} replies}}'**
  String threadReplies(num count);

  /// No description provided for @openThread.
  ///
  /// In en, this message translates to:
  /// **'Open thread'**
  String get openThread;

  /// No description provided for @edited.
  ///
  /// In en, this message translates to:
  /// **'edited'**
  String get edited;

  /// No description provided for @attachment.
  ///
  /// In en, this message translates to:
  /// **'Attachment'**
  String get attachment;

  /// No description provided for @openAttachment.
  ///
  /// In en, this message translates to:
  /// **'Open attachment'**
  String get openAttachment;

  /// No description provided for @imageAttachment.
  ///
  /// In en, this message translates to:
  /// **'Image attachment'**
  String get imageAttachment;

  /// No description provided for @openImage.
  ///
  /// In en, this message translates to:
  /// **'Open image'**
  String get openImage;

  /// No description provided for @loadingImage.
  ///
  /// In en, this message translates to:
  /// **'Loading image…'**
  String get loadingImage;

  /// No description provided for @imageLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'The image could not be loaded.'**
  String get imageLoadFailed;

  /// No description provided for @zoomOut.
  ///
  /// In en, this message translates to:
  /// **'Zoom out'**
  String get zoomOut;

  /// No description provided for @resetZoom.
  ///
  /// In en, this message translates to:
  /// **'Reset zoom'**
  String get resetZoom;

  /// No description provided for @zoomIn.
  ///
  /// In en, this message translates to:
  /// **'Zoom in'**
  String get zoomIn;

  /// No description provided for @attachImage.
  ///
  /// In en, this message translates to:
  /// **'Attach image'**
  String get attachImage;

  /// No description provided for @preparingImage.
  ///
  /// In en, this message translates to:
  /// **'Preparing image…'**
  String get preparingImage;

  /// No description provided for @imageUploadQueued.
  ///
  /// In en, this message translates to:
  /// **'Waiting to upload'**
  String get imageUploadQueued;

  /// No description provided for @uploadingImage.
  ///
  /// In en, this message translates to:
  /// **'Uploading image… {percent}%'**
  String uploadingImage(int percent);

  /// No description provided for @confirmingAttachment.
  ///
  /// In en, this message translates to:
  /// **'Confirming the attachment…'**
  String get confirmingAttachment;

  /// No description provided for @cancellingUpload.
  ///
  /// In en, this message translates to:
  /// **'Cancelling upload…'**
  String get cancellingUpload;

  /// No description provided for @imageSent.
  ///
  /// In en, this message translates to:
  /// **'Image sent'**
  String get imageSent;

  /// No description provided for @imageUploadFailed.
  ///
  /// In en, this message translates to:
  /// **'The image could not be sent.'**
  String get imageUploadFailed;

  /// No description provided for @uploadCancelled.
  ///
  /// In en, this message translates to:
  /// **'Upload cancelled'**
  String get uploadCancelled;

  /// No description provided for @participantAvatarGuest.
  ///
  /// In en, this message translates to:
  /// **'Guest'**
  String get participantAvatarGuest;

  /// No description provided for @participantAvatarBot.
  ///
  /// In en, this message translates to:
  /// **'Bot'**
  String get participantAvatarBot;

  /// No description provided for @participantAvatarBridge.
  ///
  /// In en, this message translates to:
  /// **'Bridge participant'**
  String get participantAvatarBridge;

  /// No description provided for @participantAvatarSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get participantAvatarSystem;

  /// No description provided for @participantAvatarUnknown.
  ///
  /// In en, this message translates to:
  /// **'Participant'**
  String get participantAvatarUnknown;

  /// No description provided for @replyingTo.
  ///
  /// In en, this message translates to:
  /// **'Replying to {name}'**
  String replyingTo(Object name);

  /// No description provided for @mediaCapabilityChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking attachment support…'**
  String get mediaCapabilityChecking;

  /// No description provided for @mediaCapabilityUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Attachments are temporarily unavailable.'**
  String get mediaCapabilityUnavailable;

  /// No description provided for @retryMediaCapabilities.
  ///
  /// In en, this message translates to:
  /// **'Try attachments again'**
  String get retryMediaCapabilities;

  /// No description provided for @recordVoiceMessage.
  ///
  /// In en, this message translates to:
  /// **'Record voice message'**
  String get recordVoiceMessage;

  /// No description provided for @stopVoiceRecording.
  ///
  /// In en, this message translates to:
  /// **'Stop recording'**
  String get stopVoiceRecording;

  /// No description provided for @playVoicePreview.
  ///
  /// In en, this message translates to:
  /// **'Play voice message preview'**
  String get playVoicePreview;

  /// No description provided for @cancelVoiceMessage.
  ///
  /// In en, this message translates to:
  /// **'Cancel voice message'**
  String get cancelVoiceMessage;

  /// No description provided for @sendVoiceMessage.
  ///
  /// In en, this message translates to:
  /// **'Send voice message'**
  String get sendVoiceMessage;

  /// No description provided for @voiceMessageQueued.
  ///
  /// In en, this message translates to:
  /// **'Voice message waiting to send'**
  String get voiceMessageQueued;

  /// No description provided for @voiceUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Voice messages are not supported in this conversation.'**
  String get voiceUnsupported;

  /// No description provided for @voicePermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Microphone access was denied.'**
  String get voicePermissionDenied;

  /// No description provided for @voicePermissionPermanentlyDenied.
  ///
  /// In en, this message translates to:
  /// **'Allow microphone access in system settings.'**
  String get voicePermissionPermanentlyDenied;

  /// No description provided for @voicePermissionRequestFailed.
  ///
  /// In en, this message translates to:
  /// **'Microphone access could not be checked.'**
  String get voicePermissionRequestFailed;

  /// No description provided for @voiceRecordingFailed.
  ///
  /// In en, this message translates to:
  /// **'The voice message could not be recorded.'**
  String get voiceRecordingFailed;

  /// No description provided for @voiceInvalidRecording.
  ///
  /// In en, this message translates to:
  /// **'The recording is empty or unsupported.'**
  String get voiceInvalidRecording;

  /// No description provided for @voicePlaybackFailed.
  ///
  /// In en, this message translates to:
  /// **'The recording preview could not be played.'**
  String get voicePlaybackFailed;

  /// No description provided for @voiceSendFailed.
  ///
  /// In en, this message translates to:
  /// **'The voice message could not be queued.'**
  String get voiceSendFailed;

  /// No description provided for @voiceCleanupFailed.
  ///
  /// In en, this message translates to:
  /// **'The recording could not be removed safely.'**
  String get voiceCleanupFailed;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['cs', 'en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'cs':
      return AppLocalizationsCs();
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
