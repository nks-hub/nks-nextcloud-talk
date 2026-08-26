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
  /// **'NCloudTalk'**
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

  /// No description provided for @mentionSuggestionsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No matches'**
  String get mentionSuggestionsEmpty;

  /// No description provided for @mentionSuggestionsError.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load suggestions'**
  String get mentionSuggestionsError;

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

  /// No description provided for @chatHistoryGapNotice.
  ///
  /// In en, this message translates to:
  /// **'Some messages between here are missing'**
  String get chatHistoryGapNotice;

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

  /// No description provided for @messageSent.
  ///
  /// In en, this message translates to:
  /// **'Sent'**
  String get messageSent;

  /// No description provided for @messageRead.
  ///
  /// In en, this message translates to:
  /// **'Read'**
  String get messageRead;

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
  /// **'Preparing attachment…'**
  String get preparingImage;

  /// No description provided for @imageUploadQueued.
  ///
  /// In en, this message translates to:
  /// **'Waiting to upload'**
  String get imageUploadQueued;

  /// No description provided for @uploadingImage.
  ///
  /// In en, this message translates to:
  /// **'Uploading… {percent}%'**
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
  /// **'Attachment sent'**
  String get imageSent;

  /// No description provided for @imageUploadFailed.
  ///
  /// In en, this message translates to:
  /// **'The attachment could not be sent.'**
  String get imageUploadFailed;

  /// No description provided for @imageUploadFailedQuota.
  ///
  /// In en, this message translates to:
  /// **'The attachment could not be sent: storage quota exceeded.'**
  String get imageUploadFailedQuota;

  /// No description provided for @imageUploadFailedPermission.
  ///
  /// In en, this message translates to:
  /// **'The attachment could not be sent: you do not have permission to upload files here.'**
  String get imageUploadFailedPermission;

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

  /// No description provided for @cancelReply.
  ///
  /// In en, this message translates to:
  /// **'Cancel reply'**
  String get cancelReply;

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

  /// No description provided for @playVoiceMessage.
  ///
  /// In en, this message translates to:
  /// **'Play voice message'**
  String get playVoiceMessage;

  /// No description provided for @stopVoiceMessage.
  ///
  /// In en, this message translates to:
  /// **'Stop voice message'**
  String get stopVoiceMessage;

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

  /// No description provided for @voicePlaybackPosition.
  ///
  /// In en, this message translates to:
  /// **'{position} of {duration}'**
  String voicePlaybackPosition(Object duration, Object position);

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

  /// No description provided for @presenceOnline.
  ///
  /// In en, this message translates to:
  /// **'Online'**
  String get presenceOnline;

  /// No description provided for @presenceAway.
  ///
  /// In en, this message translates to:
  /// **'Away'**
  String get presenceAway;

  /// No description provided for @presenceBusy.
  ///
  /// In en, this message translates to:
  /// **'Busy'**
  String get presenceBusy;

  /// No description provided for @presenceDoNotDisturb.
  ///
  /// In en, this message translates to:
  /// **'Do not disturb'**
  String get presenceDoNotDisturb;

  /// No description provided for @roomDetailsOpenTooltip.
  ///
  /// In en, this message translates to:
  /// **'Conversation details'**
  String get roomDetailsOpenTooltip;

  /// No description provided for @roomDetailsTitle.
  ///
  /// In en, this message translates to:
  /// **'Conversation details'**
  String get roomDetailsTitle;

  /// No description provided for @roomDetailsDescriptionLabel.
  ///
  /// In en, this message translates to:
  /// **'Description'**
  String get roomDetailsDescriptionLabel;

  /// No description provided for @roomDetailsTypeLabel.
  ///
  /// In en, this message translates to:
  /// **'Type'**
  String get roomDetailsTypeLabel;

  /// No description provided for @roomDetailsTypeOneToOne.
  ///
  /// In en, this message translates to:
  /// **'One-to-one conversation'**
  String get roomDetailsTypeOneToOne;

  /// No description provided for @roomDetailsTypeGroup.
  ///
  /// In en, this message translates to:
  /// **'Group conversation'**
  String get roomDetailsTypeGroup;

  /// No description provided for @roomDetailsTypePublic.
  ///
  /// In en, this message translates to:
  /// **'Public channel'**
  String get roomDetailsTypePublic;

  /// No description provided for @roomDetailsTypeChangelog.
  ///
  /// In en, this message translates to:
  /// **'Changelog'**
  String get roomDetailsTypeChangelog;

  /// No description provided for @roomDetailsTypeFormerOneToOne.
  ///
  /// In en, this message translates to:
  /// **'Former one-to-one conversation'**
  String get roomDetailsTypeFormerOneToOne;

  /// No description provided for @roomDetailsTypeNoteToSelf.
  ///
  /// In en, this message translates to:
  /// **'Note to self'**
  String get roomDetailsTypeNoteToSelf;

  /// No description provided for @roomDetailsTypeUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get roomDetailsTypeUnknown;

  /// No description provided for @roomDetailsReadOnlyLabel.
  ///
  /// In en, this message translates to:
  /// **'Read-only'**
  String get roomDetailsReadOnlyLabel;

  /// No description provided for @roomDetailsReadOnlyYes.
  ///
  /// In en, this message translates to:
  /// **'Yes'**
  String get roomDetailsReadOnlyYes;

  /// No description provided for @roomDetailsReadOnlyNo.
  ///
  /// In en, this message translates to:
  /// **'No'**
  String get roomDetailsReadOnlyNo;

  /// No description provided for @roomDetailsNotificationLabel.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get roomDetailsNotificationLabel;

  /// No description provided for @roomDetailsNotificationDefault.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get roomDetailsNotificationDefault;

  /// No description provided for @roomDetailsNotificationAlways.
  ///
  /// In en, this message translates to:
  /// **'All messages'**
  String get roomDetailsNotificationAlways;

  /// No description provided for @roomDetailsNotificationMention.
  ///
  /// In en, this message translates to:
  /// **'Mentions only'**
  String get roomDetailsNotificationMention;

  /// No description provided for @roomDetailsNotificationNever.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get roomDetailsNotificationNever;

  /// No description provided for @roomDetailsNotificationUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get roomDetailsNotificationUnknown;

  /// No description provided for @roomDetailsCallNotificationsLabel.
  ///
  /// In en, this message translates to:
  /// **'Call notifications'**
  String get roomDetailsCallNotificationsLabel;

  /// No description provided for @roomDetailsCallNotificationsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Notify me when a call starts'**
  String get roomDetailsCallNotificationsSubtitle;

  /// No description provided for @roomDetailsMessageExpirationLabel.
  ///
  /// In en, this message translates to:
  /// **'Message expiration'**
  String get roomDetailsMessageExpirationLabel;

  /// No description provided for @roomDetailsMessageExpirationDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Set message expiration'**
  String get roomDetailsMessageExpirationDialogTitle;

  /// No description provided for @roomDetailsMessageExpirationHint.
  ///
  /// In en, this message translates to:
  /// **'Shared files will no longer be shared in this conversation, but the owner\'s files will not be deleted.'**
  String get roomDetailsMessageExpirationHint;

  /// No description provided for @roomDetailsMessageExpirationOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get roomDetailsMessageExpirationOff;

  /// No description provided for @roomDetailsMessageExpirationOneHour.
  ///
  /// In en, this message translates to:
  /// **'1 hour'**
  String get roomDetailsMessageExpirationOneHour;

  /// No description provided for @roomDetailsMessageExpirationEightHours.
  ///
  /// In en, this message translates to:
  /// **'8 hours'**
  String get roomDetailsMessageExpirationEightHours;

  /// No description provided for @roomDetailsMessageExpirationOneDay.
  ///
  /// In en, this message translates to:
  /// **'1 day'**
  String get roomDetailsMessageExpirationOneDay;

  /// No description provided for @roomDetailsMessageExpirationOneWeek.
  ///
  /// In en, this message translates to:
  /// **'1 week'**
  String get roomDetailsMessageExpirationOneWeek;

  /// No description provided for @roomDetailsMessageExpirationFourWeeks.
  ///
  /// In en, this message translates to:
  /// **'4 weeks'**
  String get roomDetailsMessageExpirationFourWeeks;

  /// No description provided for @roomDetailsMessageExpirationCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom ({seconds} seconds)'**
  String roomDetailsMessageExpirationCustom(int seconds);

  /// No description provided for @roomDetailsMessageExpirationRejected.
  ///
  /// In en, this message translates to:
  /// **'The server rejected this expiration setting.'**
  String get roomDetailsMessageExpirationRejected;

  /// No description provided for @roomDetailsParticipantsHeader.
  ///
  /// In en, this message translates to:
  /// **'Participants'**
  String get roomDetailsParticipantsHeader;

  /// No description provided for @roomDetailsParticipantsCount.
  ///
  /// In en, this message translates to:
  /// **'{count} participants'**
  String roomDetailsParticipantsCount(int count);

  /// No description provided for @roomDetailsParticipantsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No participants found.'**
  String get roomDetailsParticipantsEmpty;

  /// No description provided for @roomDetailsLoadError.
  ///
  /// In en, this message translates to:
  /// **'Participants could not be loaded.'**
  String get roomDetailsLoadError;

  /// No description provided for @roomDetailsRoleOwner.
  ///
  /// In en, this message translates to:
  /// **'Owner'**
  String get roomDetailsRoleOwner;

  /// No description provided for @roomDetailsRoleModerator.
  ///
  /// In en, this message translates to:
  /// **'Moderator'**
  String get roomDetailsRoleModerator;

  /// No description provided for @roomDetailsRoleUser.
  ///
  /// In en, this message translates to:
  /// **'User'**
  String get roomDetailsRoleUser;

  /// No description provided for @roomDetailsRoleGuest.
  ///
  /// In en, this message translates to:
  /// **'Guest'**
  String get roomDetailsRoleGuest;

  /// No description provided for @roomDetailsRoleGuestModerator.
  ///
  /// In en, this message translates to:
  /// **'Guest moderator'**
  String get roomDetailsRoleGuestModerator;

  /// No description provided for @roomDetailsRoleUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown role'**
  String get roomDetailsRoleUnknown;

  /// No description provided for @roomDetailsActionsHeader.
  ///
  /// In en, this message translates to:
  /// **'Conversation settings'**
  String get roomDetailsActionsHeader;

  /// No description provided for @roomDetailsRenameAction.
  ///
  /// In en, this message translates to:
  /// **'Rename conversation'**
  String get roomDetailsRenameAction;

  /// No description provided for @roomDetailsRenameDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Rename conversation'**
  String get roomDetailsRenameDialogTitle;

  /// No description provided for @roomDetailsRenameFieldLabel.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get roomDetailsRenameFieldLabel;

  /// No description provided for @roomDetailsDescriptionEditAction.
  ///
  /// In en, this message translates to:
  /// **'Edit description'**
  String get roomDetailsDescriptionEditAction;

  /// No description provided for @roomDetailsDescriptionDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit description'**
  String get roomDetailsDescriptionDialogTitle;

  /// No description provided for @roomDetailsDescriptionFieldLabel.
  ///
  /// In en, this message translates to:
  /// **'Description'**
  String get roomDetailsDescriptionFieldLabel;

  /// No description provided for @roomDetailsSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get roomDetailsSave;

  /// No description provided for @roomDetailsNotificationDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Notification level'**
  String get roomDetailsNotificationDialogTitle;

  /// No description provided for @roomDetailsFavoriteLabel.
  ///
  /// In en, this message translates to:
  /// **'Favorite conversation'**
  String get roomDetailsFavoriteLabel;

  /// No description provided for @roomDetailsImportantLabel.
  ///
  /// In en, this message translates to:
  /// **'Important conversation'**
  String get roomDetailsImportantLabel;

  /// No description provided for @roomDetailsImportantSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Notify me even while Do Not Disturb is active'**
  String get roomDetailsImportantSubtitle;

  /// No description provided for @roomDetailsSensitiveLabel.
  ///
  /// In en, this message translates to:
  /// **'Sensitive conversation'**
  String get roomDetailsSensitiveLabel;

  /// No description provided for @roomDetailsSensitiveSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Hide the last message and notification previews'**
  String get roomDetailsSensitiveSubtitle;

  /// No description provided for @roomDetailsSensitiveClassifiedSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Required for classified conversations'**
  String get roomDetailsSensitiveClassifiedSubtitle;

  /// No description provided for @roomDetailsSensitiveRejected.
  ///
  /// In en, this message translates to:
  /// **'This conversation must keep message previews hidden.'**
  String get roomDetailsSensitiveRejected;

  /// No description provided for @roomDetailsLeaveAction.
  ///
  /// In en, this message translates to:
  /// **'Leave conversation'**
  String get roomDetailsLeaveAction;

  /// No description provided for @roomDetailsLeaveDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Leave conversation?'**
  String get roomDetailsLeaveDialogTitle;

  /// No description provided for @roomDetailsLeaveDialogMessage.
  ///
  /// In en, this message translates to:
  /// **'You will stop receiving new messages from this conversation until someone invites you back.'**
  String get roomDetailsLeaveDialogMessage;

  /// No description provided for @roomDetailsLeaveDialogConfirm.
  ///
  /// In en, this message translates to:
  /// **'Leave'**
  String get roomDetailsLeaveDialogConfirm;

  /// No description provided for @roomDetailsActionErrorGeneric.
  ///
  /// In en, this message translates to:
  /// **'The change could not be saved. Please try again.'**
  String get roomDetailsActionErrorGeneric;

  /// No description provided for @roomDetailsActionErrorReauth.
  ///
  /// In en, this message translates to:
  /// **'Please sign in again to make this change.'**
  String get roomDetailsActionErrorReauth;

  /// No description provided for @roomDetailsActionErrorForbidden.
  ///
  /// In en, this message translates to:
  /// **'You don\'t have permission to do this.'**
  String get roomDetailsActionErrorForbidden;

  /// No description provided for @roomDetailsActionErrorRoomMissing.
  ///
  /// In en, this message translates to:
  /// **'This conversation no longer exists.'**
  String get roomDetailsActionErrorRoomMissing;

  /// No description provided for @roomDetailsLeaveRejected.
  ///
  /// In en, this message translates to:
  /// **'You can\'t leave until another moderator is promoted.'**
  String get roomDetailsLeaveRejected;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @settingsAccountsSection.
  ///
  /// In en, this message translates to:
  /// **'Accounts'**
  String get settingsAccountsSection;

  /// No description provided for @settingsAccountSelected.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get settingsAccountSelected;

  /// No description provided for @settingsAccountsLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Accounts could not be loaded.'**
  String get settingsAccountsLoadFailed;

  /// No description provided for @settingsAddAccount.
  ///
  /// In en, this message translates to:
  /// **'Add account'**
  String get settingsAddAccount;

  /// No description provided for @settingsRemoveAccountUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Removing an account isn\'t supported yet. Sign out of it on the server if you need to revoke access.'**
  String get settingsRemoveAccountUnavailable;

  /// No description provided for @settingsThemeSection.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get settingsThemeSection;

  /// No description provided for @settingsThemeSystem.
  ///
  /// In en, this message translates to:
  /// **'Match system'**
  String get settingsThemeSystem;

  /// No description provided for @settingsThemeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get settingsThemeLight;

  /// No description provided for @settingsThemeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get settingsThemeDark;

  /// No description provided for @conversationActionsTitle.
  ///
  /// In en, this message translates to:
  /// **'Conversation actions'**
  String get conversationActionsTitle;

  /// No description provided for @conversationActionMarkUnread.
  ///
  /// In en, this message translates to:
  /// **'Mark as unread'**
  String get conversationActionMarkUnread;

  /// No description provided for @conversationActionArchive.
  ///
  /// In en, this message translates to:
  /// **'Archive conversation'**
  String get conversationActionArchive;

  /// No description provided for @conversationActionUnarchive.
  ///
  /// In en, this message translates to:
  /// **'Unarchive conversation'**
  String get conversationActionUnarchive;

  /// No description provided for @conversationArchivedSectionShow.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Archived (1)} other{Archived ({count})}}'**
  String conversationArchivedSectionShow(int count);

  /// No description provided for @conversationArchivedSectionHide.
  ///
  /// In en, this message translates to:
  /// **'Back to conversations'**
  String get conversationArchivedSectionHide;

  /// No description provided for @conversationActionErrorGeneric.
  ///
  /// In en, this message translates to:
  /// **'The action could not be completed. Please try again.'**
  String get conversationActionErrorGeneric;

  /// No description provided for @conversationActionErrorReauth.
  ///
  /// In en, this message translates to:
  /// **'Please sign in again to make this change.'**
  String get conversationActionErrorReauth;

  /// No description provided for @messageActionReply.
  ///
  /// In en, this message translates to:
  /// **'Reply'**
  String get messageActionReply;

  /// No description provided for @messageActionCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy text'**
  String get messageActionCopy;

  /// No description provided for @messageActionEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get messageActionEdit;

  /// No description provided for @messageActionDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get messageActionDelete;

  /// No description provided for @messageActionReact.
  ///
  /// In en, this message translates to:
  /// **'React'**
  String get messageActionReact;

  /// No description provided for @messageCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied to clipboard'**
  String get messageCopied;

  /// No description provided for @editMessageTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit message'**
  String get editMessageTitle;

  /// No description provided for @editMessageSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get editMessageSave;

  /// No description provided for @deleteMessageConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete this message?'**
  String get deleteMessageConfirmTitle;

  /// No description provided for @deleteMessageConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'This cannot be undone.'**
  String get deleteMessageConfirmBody;

  /// No description provided for @reactionPickerMore.
  ///
  /// In en, this message translates to:
  /// **'More emoji…'**
  String get reactionPickerMore;

  /// No description provided for @messageActionUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This action isn\'t available here.'**
  String get messageActionUnsupported;

  /// No description provided for @messageActionMessageMissing.
  ///
  /// In en, this message translates to:
  /// **'This message is no longer available.'**
  String get messageActionMessageMissing;

  /// No description provided for @searchMessagesTooltip.
  ///
  /// In en, this message translates to:
  /// **'Search messages'**
  String get searchMessagesTooltip;

  /// No description provided for @searchMessagesTitle.
  ///
  /// In en, this message translates to:
  /// **'Search messages'**
  String get searchMessagesTitle;

  /// No description provided for @searchMessagesHint.
  ///
  /// In en, this message translates to:
  /// **'Search messages'**
  String get searchMessagesHint;

  /// No description provided for @searchMessagesPrompt.
  ///
  /// In en, this message translates to:
  /// **'Type to search messages'**
  String get searchMessagesPrompt;

  /// No description provided for @searchMessagesNoResults.
  ///
  /// In en, this message translates to:
  /// **'No messages found'**
  String get searchMessagesNoResults;

  /// No description provided for @searchMessagesError.
  ///
  /// In en, this message translates to:
  /// **'Search failed. Try again.'**
  String get searchMessagesError;

  /// No description provided for @newConversationTitle.
  ///
  /// In en, this message translates to:
  /// **'New conversation'**
  String get newConversationTitle;

  /// No description provided for @newConversationSearchLabel.
  ///
  /// In en, this message translates to:
  /// **'Search people and groups'**
  String get newConversationSearchLabel;

  /// No description provided for @newConversationIdle.
  ///
  /// In en, this message translates to:
  /// **'Type a name to find someone to chat with.'**
  String get newConversationIdle;

  /// No description provided for @newConversationEmpty.
  ///
  /// In en, this message translates to:
  /// **'No people or groups found.'**
  String get newConversationEmpty;

  /// No description provided for @newConversationNameDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Name this group conversation'**
  String get newConversationNameDialogTitle;

  /// No description provided for @newConversationNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Conversation name'**
  String get newConversationNameLabel;

  /// No description provided for @newConversationCreate.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get newConversationCreate;

  /// No description provided for @newConversationErrorAccountMissing.
  ///
  /// In en, this message translates to:
  /// **'This account is no longer available.'**
  String get newConversationErrorAccountMissing;

  /// No description provided for @newConversationErrorCredentialMissing.
  ///
  /// In en, this message translates to:
  /// **'Sign in again to search for people and groups.'**
  String get newConversationErrorCredentialMissing;

  /// No description provided for @newConversationErrorInvalidSearchTerm.
  ///
  /// In en, this message translates to:
  /// **'Enter a search term.'**
  String get newConversationErrorInvalidSearchTerm;

  /// No description provided for @newConversationErrorRoomNameRequired.
  ///
  /// In en, this message translates to:
  /// **'The conversation needs a name.'**
  String get newConversationErrorRoomNameRequired;

  /// No description provided for @newConversationErrorReauthenticationRequired.
  ///
  /// In en, this message translates to:
  /// **'Sign in again to continue.'**
  String get newConversationErrorReauthenticationRequired;

  /// No description provided for @newConversationErrorOcsFailure.
  ///
  /// In en, this message translates to:
  /// **'The server rejected the request.'**
  String get newConversationErrorOcsFailure;

  /// No description provided for @newConversationErrorRateLimited.
  ///
  /// In en, this message translates to:
  /// **'Too many requests. Try again soon.'**
  String get newConversationErrorRateLimited;

  /// No description provided for @newConversationErrorServiceUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The server is temporarily unavailable.'**
  String get newConversationErrorServiceUnavailable;

  /// No description provided for @newConversationErrorInvalidResponse.
  ///
  /// In en, this message translates to:
  /// **'The server sent an unexpected response.'**
  String get newConversationErrorInvalidResponse;

  /// No description provided for @newConversationErrorNetwork.
  ///
  /// In en, this message translates to:
  /// **'Could not reach the server.'**
  String get newConversationErrorNetwork;

  /// No description provided for @roomDetailsParticipantActionsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Participant actions'**
  String get roomDetailsParticipantActionsTooltip;

  /// No description provided for @roomDetailsPromoteModerator.
  ///
  /// In en, this message translates to:
  /// **'Promote to moderator'**
  String get roomDetailsPromoteModerator;

  /// No description provided for @roomDetailsDemoteModerator.
  ///
  /// In en, this message translates to:
  /// **'Remove moderator rights'**
  String get roomDetailsDemoteModerator;

  /// No description provided for @roomDetailsRemoveParticipant.
  ///
  /// In en, this message translates to:
  /// **'Remove from conversation'**
  String get roomDetailsRemoveParticipant;

  /// No description provided for @roomDetailsRemoveDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove participant?'**
  String get roomDetailsRemoveDialogTitle;

  /// No description provided for @roomDetailsRemoveDialogMessage.
  ///
  /// In en, this message translates to:
  /// **'{name} will lose access to this conversation until someone invites them back.'**
  String roomDetailsRemoveDialogMessage(String name);

  /// No description provided for @roomDetailsRemoveDialogConfirm.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get roomDetailsRemoveDialogConfirm;

  /// No description provided for @roomDetailsParticipantActionRejected.
  ///
  /// In en, this message translates to:
  /// **'The server refused this change for this participant.'**
  String get roomDetailsParticipantActionRejected;

  /// No description provided for @callBannerTitle.
  ///
  /// In en, this message translates to:
  /// **'Call in progress'**
  String get callBannerTitle;

  /// No description provided for @callBannerRunningFor.
  ///
  /// In en, this message translates to:
  /// **'Running for {duration}'**
  String callBannerRunningFor(String duration);

  /// No description provided for @callBannerJoin.
  ///
  /// In en, this message translates to:
  /// **'Join call'**
  String get callBannerJoin;

  /// No description provided for @callBannerJoinUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Joining is not implemented yet ({transport} signalling).'**
  String callBannerJoinUnsupported(String transport);

  /// No description provided for @callBannerTransportChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking how this call is signalled…'**
  String get callBannerTransportChecking;

  /// No description provided for @callBannerTransportUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The call transport could not be resolved.'**
  String get callBannerTransportUnavailable;

  /// No description provided for @callBannerTransportReauth.
  ///
  /// In en, this message translates to:
  /// **'Sign in again to see how this call is signalled.'**
  String get callBannerTransportReauth;

  /// No description provided for @callBannerTransportRoomUnavailable.
  ///
  /// In en, this message translates to:
  /// **'This conversation is no longer available on the server.'**
  String get callBannerTransportRoomUnavailable;

  /// No description provided for @callTransportInternal.
  ///
  /// In en, this message translates to:
  /// **'internal'**
  String get callTransportInternal;

  /// No description provided for @callTransportExternalHpb.
  ///
  /// In en, this message translates to:
  /// **'external HPB'**
  String get callTransportExternalHpb;

  /// No description provided for @messageActionForward.
  ///
  /// In en, this message translates to:
  /// **'Forward'**
  String get messageActionForward;

  /// No description provided for @forwardMessageTitle.
  ///
  /// In en, this message translates to:
  /// **'Forward to conversation'**
  String get forwardMessageTitle;

  /// No description provided for @forwardNoConversations.
  ///
  /// In en, this message translates to:
  /// **'No other conversation is available.'**
  String get forwardNoConversations;

  /// No description provided for @messageForwarded.
  ///
  /// In en, this message translates to:
  /// **'Message forwarded to {conversation}'**
  String messageForwarded(String conversation);

  /// No description provided for @messageForwardFailed.
  ///
  /// In en, this message translates to:
  /// **'The message could not be forwarded.'**
  String get messageForwardFailed;

  /// No description provided for @cancelSend.
  ///
  /// In en, this message translates to:
  /// **'Cancel sending'**
  String get cancelSend;

  /// No description provided for @outboxCancelAmbiguous.
  ///
  /// In en, this message translates to:
  /// **'This message may already have reached the server, so it can no longer be cancelled.'**
  String get outboxCancelAmbiguous;

  /// No description provided for @roomDetailsDeleteAction.
  ///
  /// In en, this message translates to:
  /// **'Delete conversation'**
  String get roomDetailsDeleteAction;

  /// No description provided for @roomDetailsDeleteDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete conversation?'**
  String get roomDetailsDeleteDialogTitle;

  /// No description provided for @roomDetailsDeleteDialogMessage.
  ///
  /// In en, this message translates to:
  /// **'The conversation and all of its messages are removed for everyone. This cannot be undone.'**
  String get roomDetailsDeleteDialogMessage;

  /// No description provided for @roomDetailsDeleteDialogConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get roomDetailsDeleteDialogConfirm;

  /// No description provided for @roomDetailsDeleteRejected.
  ///
  /// In en, this message translates to:
  /// **'This conversation cannot be deleted. You can only leave a one-to-one conversation.'**
  String get roomDetailsDeleteRejected;

  /// No description provided for @saveImage.
  ///
  /// In en, this message translates to:
  /// **'Save image'**
  String get saveImage;

  /// No description provided for @shareImage.
  ///
  /// In en, this message translates to:
  /// **'Share image'**
  String get shareImage;

  /// No description provided for @imageSavedToGallery.
  ///
  /// In en, this message translates to:
  /// **'Image saved to your gallery.'**
  String get imageSavedToGallery;

  /// No description provided for @imageSavePermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Saving needs access to your gallery. Grant it in the system settings and try again.'**
  String get imageSavePermissionDenied;

  /// No description provided for @imageSaveOutOfSpace.
  ///
  /// In en, this message translates to:
  /// **'There is not enough free space to save the image.'**
  String get imageSaveOutOfSpace;

  /// No description provided for @imageSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'The image could not be saved.'**
  String get imageSaveFailed;

  /// No description provided for @imageShareFailed.
  ///
  /// In en, this message translates to:
  /// **'The image could not be shared.'**
  String get imageShareFailed;

  /// No description provided for @jumpToOriginalMessage.
  ///
  /// In en, this message translates to:
  /// **'Show the original message'**
  String get jumpToOriginalMessage;

  /// No description provided for @jumpToMessageNotFound.
  ///
  /// In en, this message translates to:
  /// **'That message is no longer available in this conversation.'**
  String get jumpToMessageNotFound;

  /// No description provided for @jumpToMessageConversationMissing.
  ///
  /// In en, this message translates to:
  /// **'That conversation is not available on this device.'**
  String get jumpToMessageConversationMissing;

  /// No description provided for @searchMessagesErrorAccountMissing.
  ///
  /// In en, this message translates to:
  /// **'This account is no longer available.'**
  String get searchMessagesErrorAccountMissing;

  /// No description provided for @searchMessagesErrorCredentialMissing.
  ///
  /// In en, this message translates to:
  /// **'Sign in again to search messages.'**
  String get searchMessagesErrorCredentialMissing;

  /// No description provided for @searchMessagesErrorReauthentication.
  ///
  /// In en, this message translates to:
  /// **'Your session expired. Sign in again.'**
  String get searchMessagesErrorReauthentication;

  /// No description provided for @searchMessagesErrorProviderMissing.
  ///
  /// In en, this message translates to:
  /// **'This server does not offer message search.'**
  String get searchMessagesErrorProviderMissing;

  /// No description provided for @searchMessagesErrorTransient.
  ///
  /// In en, this message translates to:
  /// **'The server is busy. Try again in a moment.'**
  String get searchMessagesErrorTransient;

  /// No description provided for @searchMessagesErrorServer.
  ///
  /// In en, this message translates to:
  /// **'The server rejected the search.'**
  String get searchMessagesErrorServer;

  /// No description provided for @searchMessagesErrorInvalidResponse.
  ///
  /// In en, this message translates to:
  /// **'The server sent a search response this app could not read.'**
  String get searchMessagesErrorInvalidResponse;

  /// No description provided for @searchMessagesErrorNetwork.
  ///
  /// In en, this message translates to:
  /// **'Could not reach the server.'**
  String get searchMessagesErrorNetwork;

  /// No description provided for @addAttachment.
  ///
  /// In en, this message translates to:
  /// **'Add attachment'**
  String get addAttachment;

  /// No description provided for @attachFromGallery.
  ///
  /// In en, this message translates to:
  /// **'Choose a picture'**
  String get attachFromGallery;

  /// No description provided for @attachFromCamera.
  ///
  /// In en, this message translates to:
  /// **'Take a picture'**
  String get attachFromCamera;

  /// No description provided for @attachFromFile.
  ///
  /// In en, this message translates to:
  /// **'Choose a file'**
  String get attachFromFile;

  /// No description provided for @attachmentCameraDenied.
  ///
  /// In en, this message translates to:
  /// **'Taking a picture needs camera access. Grant it in the system settings and try again.'**
  String get attachmentCameraDenied;

  /// No description provided for @attachmentCameraUnavailable.
  ///
  /// In en, this message translates to:
  /// **'No camera is available on this device.'**
  String get attachmentCameraUnavailable;

  /// No description provided for @attachmentTypeUnsupported.
  ///
  /// In en, this message translates to:
  /// **'That file type cannot be attached here.'**
  String get attachmentTypeUnsupported;

  /// No description provided for @pauseVoiceRecording.
  ///
  /// In en, this message translates to:
  /// **'Pause recording'**
  String get pauseVoiceRecording;

  /// No description provided for @resumeVoiceRecording.
  ///
  /// In en, this message translates to:
  /// **'Resume recording'**
  String get resumeVoiceRecording;

  /// No description provided for @voiceRecordingLevel.
  ///
  /// In en, this message translates to:
  /// **'Recording level'**
  String get voiceRecordingLevel;

  /// No description provided for @voicePauseFailed.
  ///
  /// In en, this message translates to:
  /// **'The recording could not be paused.'**
  String get voicePauseFailed;

  /// No description provided for @pauseVoiceMessage.
  ///
  /// In en, this message translates to:
  /// **'Pause voice message'**
  String get pauseVoiceMessage;

  /// No description provided for @voiceMessagePosition.
  ///
  /// In en, this message translates to:
  /// **'Playback position'**
  String get voiceMessagePosition;

  /// No description provided for @voiceMessageProgress.
  ///
  /// In en, this message translates to:
  /// **'{position} of {duration}'**
  String voiceMessageProgress(String position, String duration);

  /// No description provided for @settingsRemoveAccount.
  ///
  /// In en, this message translates to:
  /// **'Remove account'**
  String get settingsRemoveAccount;

  /// No description provided for @settingsRemoveAccountDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove this account?'**
  String get settingsRemoveAccountDialogTitle;

  /// No description provided for @settingsRemoveAccountDialogMessage.
  ///
  /// In en, this message translates to:
  /// **'{loginName} on {serverUrl} will be removed from this device. Its conversations, messages, drafts, queued uploads, cached pictures and voice messages, and its stored password are deleted, and the app password is revoked on the server.'**
  String settingsRemoveAccountDialogMessage(Object loginName, Object serverUrl);

  /// No description provided for @settingsRemoveAccountDialogConfirm.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get settingsRemoveAccountDialogConfirm;

  /// No description provided for @settingsRemoveAccountDone.
  ///
  /// In en, this message translates to:
  /// **'The account was removed.'**
  String get settingsRemoveAccountDone;

  /// No description provided for @settingsRemoveAccountDoneNotRevoked.
  ///
  /// In en, this message translates to:
  /// **'The account was removed from this device, but the server did not confirm the app password was revoked. Revoke it yourself under Settings, Security on the server.'**
  String get settingsRemoveAccountDoneNotRevoked;

  /// Switch that turns a group conversation into a public one anyone with the link can join.
  ///
  /// In en, this message translates to:
  /// **'Guests'**
  String get roomDetailsGuestsLabel;

  /// Subtitle of the guest switch while the conversation is public.
  ///
  /// In en, this message translates to:
  /// **'Anyone with the link can join'**
  String get roomDetailsGuestsAllowed;

  /// Subtitle of the guest switch while the conversation is private.
  ///
  /// In en, this message translates to:
  /// **'Invited people only'**
  String get roomDetailsGuestsBlocked;

  /// Title of the dialog confirming that a public conversation becomes private.
  ///
  /// In en, this message translates to:
  /// **'Stop allowing guests?'**
  String get roomDetailsGuestsCloseDialogTitle;

  /// Body of the dialog confirming that a public conversation becomes private.
  ///
  /// In en, this message translates to:
  /// **'The link stops working and any guest who joined through it loses access. Invited participants are not affected.'**
  String get roomDetailsGuestsCloseDialogMessage;

  /// Confirm button that turns a public conversation private.
  ///
  /// In en, this message translates to:
  /// **'Make private'**
  String get roomDetailsGuestsCloseDialogConfirm;

  /// Action that opens the system share sheet with the conversation's guest link.
  ///
  /// In en, this message translates to:
  /// **'Share the guest link'**
  String get roomDetailsInviteLinkAction;

  /// Subtitle explaining what the shared guest link grants.
  ///
  /// In en, this message translates to:
  /// **'Anyone with this link can join as a guest'**
  String get roomDetailsInviteLinkSubtitle;

  /// Subject line offered to the system share sheet for a guest link.
  ///
  /// In en, this message translates to:
  /// **'Join the conversation'**
  String get roomDetailsInviteLinkShareSubject;

  /// Label of the conversation password action.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get roomDetailsPasswordLabel;

  /// Subtitle shown while the public conversation is password protected.
  ///
  /// In en, this message translates to:
  /// **'Guests need a password'**
  String get roomDetailsPasswordSet;

  /// Subtitle shown while the public conversation has no password.
  ///
  /// In en, this message translates to:
  /// **'No password'**
  String get roomDetailsPasswordUnset;

  /// Title of the dialog that sets the conversation password.
  ///
  /// In en, this message translates to:
  /// **'Password for guests'**
  String get roomDetailsPasswordDialogTitle;

  /// Label of the password text field.
  ///
  /// In en, this message translates to:
  /// **'New password'**
  String get roomDetailsPasswordFieldLabel;

  /// Action that clears the conversation password.
  ///
  /// In en, this message translates to:
  /// **'Remove the password'**
  String get roomDetailsPasswordRemoveAction;

  /// Title of the dialog confirming that the conversation password is removed.
  ///
  /// In en, this message translates to:
  /// **'Remove the password?'**
  String get roomDetailsPasswordRemoveDialogTitle;

  /// Body of the dialog confirming that the conversation password is removed.
  ///
  /// In en, this message translates to:
  /// **'Anyone with the link will be able to join without a password.'**
  String get roomDetailsPasswordRemoveDialogMessage;

  /// Confirm button that clears the conversation password.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get roomDetailsPasswordRemoveDialogConfirm;

  /// Message shown when the server rejects a password and sends no explanation.
  ///
  /// In en, this message translates to:
  /// **'The server refused this password.'**
  String get roomDetailsPasswordRejected;

  /// Label of the lobby switch.
  ///
  /// In en, this message translates to:
  /// **'Lobby'**
  String get roomDetailsLobbyLabel;

  /// Subtitle shown while the lobby is off.
  ///
  /// In en, this message translates to:
  /// **'Everyone can take part'**
  String get roomDetailsLobbyOff;

  /// Subtitle shown while the lobby is on without an end time.
  ///
  /// In en, this message translates to:
  /// **'Only moderators can take part'**
  String get roomDetailsLobbyOn;

  /// Subtitle shown while the lobby is on and lifts itself at a set time.
  ///
  /// In en, this message translates to:
  /// **'Only moderators until {time}'**
  String roomDetailsLobbyOnUntil(String time);

  /// Title of the dialog that turns the lobby on.
  ///
  /// In en, this message translates to:
  /// **'Open the lobby'**
  String get roomDetailsLobbyDialogTitle;

  /// Body of the dialog that turns the lobby on.
  ///
  /// In en, this message translates to:
  /// **'While the lobby is on, only moderators can read, write and call. Pick when it should open, or leave it for a moderator to open by hand.'**
  String get roomDetailsLobbyDialogMessage;

  /// Option that keeps the lobby on until a moderator turns it off.
  ///
  /// In en, this message translates to:
  /// **'No end time'**
  String get roomDetailsLobbyTimerNone;

  /// Option that opens the pickers for the lobby end time.
  ///
  /// In en, this message translates to:
  /// **'Pick a date and time'**
  String get roomDetailsLobbyTimerPick;

  /// Confirm button that turns the lobby on.
  ///
  /// In en, this message translates to:
  /// **'Turn the lobby on'**
  String get roomDetailsLobbyDialogConfirm;

  /// Label of the read-only switch.
  ///
  /// In en, this message translates to:
  /// **'Read-only'**
  String get roomDetailsReadOnlyToggleLabel;

  /// Subtitle shown while the conversation is read-only.
  ///
  /// In en, this message translates to:
  /// **'Nobody can write or call'**
  String get roomDetailsReadOnlyToggleOn;

  /// Subtitle shown while the conversation is read-write.
  ///
  /// In en, this message translates to:
  /// **'Everyone can write'**
  String get roomDetailsReadOnlyToggleOff;

  /// Title of the dialog that turns read-only mode on.
  ///
  /// In en, this message translates to:
  /// **'Lock the conversation?'**
  String get roomDetailsReadOnlyDialogTitle;

  /// Body of the dialog that turns read-only mode on.
  ///
  /// In en, this message translates to:
  /// **'Nobody will be able to send messages or start a call until a moderator unlocks it again.'**
  String get roomDetailsReadOnlyDialogMessage;

  /// Confirm button that turns read-only mode on.
  ///
  /// In en, this message translates to:
  /// **'Lock'**
  String get roomDetailsReadOnlyDialogConfirm;

  /// Action that opens the conversation avatar options.
  ///
  /// In en, this message translates to:
  /// **'Conversation picture'**
  String get roomDetailsAvatarAction;

  /// Title of the dialog that picks an emoji as the conversation picture.
  ///
  /// In en, this message translates to:
  /// **'Conversation picture'**
  String get roomDetailsAvatarDialogTitle;

  /// Body of the dialog that picks an emoji as the conversation picture.
  ///
  /// In en, this message translates to:
  /// **'Pick an emoji to use as the conversation picture.'**
  String get roomDetailsAvatarDialogMessage;

  /// Confirm button that sets the picked emoji as the conversation picture.
  ///
  /// In en, this message translates to:
  /// **'Use this emoji'**
  String get roomDetailsAvatarSetAction;

  /// Action that removes a custom conversation picture.
  ///
  /// In en, this message translates to:
  /// **'Remove the picture'**
  String get roomDetailsAvatarRemoveAction;

  /// Accessibility label of one selectable emoji.
  ///
  /// In en, this message translates to:
  /// **'Emoji {emoji}'**
  String roomDetailsAvatarEmojiSemantics(String emoji);

  /// Moderation action that bans one attendee.
  ///
  /// In en, this message translates to:
  /// **'Ban from the conversation'**
  String get roomDetailsBanParticipant;

  /// Title of the dialog confirming a ban.
  ///
  /// In en, this message translates to:
  /// **'Ban this participant?'**
  String get roomDetailsBanDialogTitle;

  /// Body of the dialog confirming a ban.
  ///
  /// In en, this message translates to:
  /// **'{name} is removed from the conversation and cannot rejoin until the ban is lifted.'**
  String roomDetailsBanDialogMessage(String name);

  /// Label of the optional internal ban note field.
  ///
  /// In en, this message translates to:
  /// **'Reason (only moderators see it)'**
  String get roomDetailsBanNoteLabel;

  /// Confirm button that bans an attendee.
  ///
  /// In en, this message translates to:
  /// **'Ban'**
  String get roomDetailsBanDialogConfirm;

  /// Action that opens the list of bans on the conversation.
  ///
  /// In en, this message translates to:
  /// **'Banned participants'**
  String get roomDetailsBansAction;

  /// Title of the dialog listing the bans on the conversation.
  ///
  /// In en, this message translates to:
  /// **'Banned participants'**
  String get roomDetailsBansDialogTitle;

  /// Message shown when the conversation has no bans.
  ///
  /// In en, this message translates to:
  /// **'Nobody is banned.'**
  String get roomDetailsBansEmpty;

  /// Message shown when the ban list fails to load.
  ///
  /// In en, this message translates to:
  /// **'Bans could not be loaded.'**
  String get roomDetailsBansLoadError;

  /// Action that lifts one ban.
  ///
  /// In en, this message translates to:
  /// **'Lift the ban'**
  String get roomDetailsUnbanAction;

  /// Message shown when the server refuses a ban.
  ///
  /// In en, this message translates to:
  /// **'The server refused this ban.'**
  String get roomDetailsBanRejected;

  /// Button that opens the gallery to pick a conversation picture.
  ///
  /// In en, this message translates to:
  /// **'Choose a picture'**
  String get roomDetailsAvatarPickImage;

  /// Message shown when the picked file is not a type the server accepts.
  ///
  /// In en, this message translates to:
  /// **'Only a square PNG or JPEG works as a conversation picture.'**
  String get roomDetailsAvatarTypeRejected;

  /// Message shown when the picked picture exceeds the upload limit.
  ///
  /// In en, this message translates to:
  /// **'That picture is too large.'**
  String get roomDetailsAvatarTooLarge;

  /// Message shown when the server refuses an avatar upload without an explanation.
  ///
  /// In en, this message translates to:
  /// **'The server would not take this picture.'**
  String get roomDetailsAvatarRejected;

  /// No description provided for @messageActionPin.
  ///
  /// In en, this message translates to:
  /// **'Pin message'**
  String get messageActionPin;

  /// No description provided for @messageActionUnpin.
  ///
  /// In en, this message translates to:
  /// **'Unpin message'**
  String get messageActionUnpin;

  /// No description provided for @messagePinned.
  ///
  /// In en, this message translates to:
  /// **'Message pinned'**
  String get messagePinned;

  /// No description provided for @messageUnpinned.
  ///
  /// In en, this message translates to:
  /// **'Message unpinned'**
  String get messageUnpinned;

  /// No description provided for @pinnedMessageLabel.
  ///
  /// In en, this message translates to:
  /// **'Pinned message'**
  String get pinnedMessageLabel;

  /// No description provided for @pinnedMessageOpen.
  ///
  /// In en, this message translates to:
  /// **'Show pinned message'**
  String get pinnedMessageOpen;

  /// No description provided for @pinnedMessageHide.
  ///
  /// In en, this message translates to:
  /// **'Hide for me'**
  String get pinnedMessageHide;

  /// No description provided for @messageActionRemind.
  ///
  /// In en, this message translates to:
  /// **'Remind me'**
  String get messageActionRemind;

  /// No description provided for @reminderTitle.
  ///
  /// In en, this message translates to:
  /// **'Remind me about this message'**
  String get reminderTitle;

  /// No description provided for @reminderLaterToday.
  ///
  /// In en, this message translates to:
  /// **'Later today'**
  String get reminderLaterToday;

  /// No description provided for @reminderTomorrow.
  ///
  /// In en, this message translates to:
  /// **'Tomorrow morning'**
  String get reminderTomorrow;

  /// No description provided for @reminderThisWeekend.
  ///
  /// In en, this message translates to:
  /// **'This weekend'**
  String get reminderThisWeekend;

  /// No description provided for @reminderNextWeek.
  ///
  /// In en, this message translates to:
  /// **'Next week'**
  String get reminderNextWeek;

  /// No description provided for @reminderCustom.
  ///
  /// In en, this message translates to:
  /// **'Pick a date and time'**
  String get reminderCustom;

  /// No description provided for @reminderRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove reminder'**
  String get reminderRemove;

  /// No description provided for @reminderSet.
  ///
  /// In en, this message translates to:
  /// **'Reminder set for {time}'**
  String reminderSet(String time);

  /// No description provided for @reminderRemoved.
  ///
  /// In en, this message translates to:
  /// **'Reminder removed'**
  String get reminderRemoved;

  /// No description provided for @reminderExisting.
  ///
  /// In en, this message translates to:
  /// **'Reminder set for {time}'**
  String reminderExisting(String time);

  /// No description provided for @scheduleMessage.
  ///
  /// In en, this message translates to:
  /// **'Send later'**
  String get scheduleMessage;

  /// No description provided for @scheduleMessageTitle.
  ///
  /// In en, this message translates to:
  /// **'Send this message later'**
  String get scheduleMessageTitle;

  /// No description provided for @scheduleMessageSet.
  ///
  /// In en, this message translates to:
  /// **'Message scheduled for {time}'**
  String scheduleMessageSet(String time);

  /// No description provided for @scheduledMessagesTitle.
  ///
  /// In en, this message translates to:
  /// **'Scheduled messages'**
  String get scheduledMessagesTitle;

  /// No description provided for @scheduledMessagesOpen.
  ///
  /// In en, this message translates to:
  /// **'Scheduled messages'**
  String get scheduledMessagesOpen;

  /// No description provided for @scheduledMessagesEmpty.
  ///
  /// In en, this message translates to:
  /// **'Nothing is scheduled in this conversation.'**
  String get scheduledMessagesEmpty;

  /// No description provided for @scheduledMessageDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete scheduled message'**
  String get scheduledMessageDelete;

  /// No description provided for @scheduledMessageDeleted.
  ///
  /// In en, this message translates to:
  /// **'Scheduled message deleted'**
  String get scheduledMessageDeleted;

  /// No description provided for @scheduleTimeInPast.
  ///
  /// In en, this message translates to:
  /// **'Pick a time in the future.'**
  String get scheduleTimeInPast;
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
