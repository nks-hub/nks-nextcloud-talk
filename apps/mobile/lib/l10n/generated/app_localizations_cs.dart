// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Czech (`cs`).
class AppLocalizationsCs extends AppLocalizations {
  AppLocalizationsCs([String locale = 'cs']) : super(locale);

  @override
  String get dateHeaderToday => 'Dnes';

  @override
  String get dateHeaderYesterday => 'Včera';

  @override
  String get appTitle => 'NCloudTalk';

  @override
  String get onboardingTitle => 'Všechny konverzace v jedné aplikaci';

  @override
  String get onboardingBody =>
      'Připojte libovolný podporovaný Nextcloud server. Účty, mezipaměť i práce na pozadí zůstávají přísně oddělené.';

  @override
  String get multiServerTitle => 'Připraveno pro více serverů';

  @override
  String get multiServerBody =>
      'Přidejte osobní i pracovní účty bez nového sestavení aplikace a bez sdílení jejich dat.';

  @override
  String get secureTitle => 'Přihlašovací údaje zůstávají v zařízení';

  @override
  String get secureBody =>
      'Hesla aplikace se ukládají do systémového Keychainu nebo Keystoru, nikdy do databáze konverzací.';

  @override
  String get addServerTitle => 'Přidat Nextcloud server';

  @override
  String get serverAddressLabel => 'Adresa serveru';

  @override
  String get serverAddressHint => 'cloud.example.com';

  @override
  String get connect => 'Pokračovat';

  @override
  String get checkingServer => 'Kontroluji server…';

  @override
  String get openingLogin => 'Otevírám bezpečné přihlášení…';

  @override
  String get waitingForLogin => 'Dokončete přihlášení v prohlížeči';

  @override
  String get waitingForLoginBody =>
      'Po schválení aplikace v Nextcloudu bude tato obrazovka automaticky pokračovat.';

  @override
  String get cancel => 'Zrušit';

  @override
  String get retry => 'Zkusit znovu';

  @override
  String get invalidServer => 'Zadejte platnou HTTPS adresu Nextcloud serveru.';

  @override
  String get serverUnavailable =>
      'Server se nepodařilo kontaktovat. Zkontrolujte adresu a připojení.';

  @override
  String get serverMaintenance => 'Server je právě v režimu údržby.';

  @override
  String get serverNotInstalled =>
      'Nextcloud na tomto serveru zatím není nainstalovaný.';

  @override
  String get serverUpgrade =>
      'Server musí nejdřív dokončit aktualizaci databáze.';

  @override
  String get invalidResponse =>
      'Server vrátil odpověď, kterou aplikace nemůže bezpečně použít.';

  @override
  String get browserUnavailable =>
      'Přihlašovací stránku se nepodařilo otevřít.';

  @override
  String get loginTimedOut =>
      'Požadavek na přihlášení vypršel. Spusťte jej znovu.';

  @override
  String get talkUnavailable => 'Nextcloud Talk není pro tento účet dostupný.';

  @override
  String get localPersistenceFailed =>
      'Účet se nepodařilo bezpečně uložit do tohoto zařízení.';

  @override
  String get unexpectedError => 'Něco se nepodařilo. Data účtu nebyla změněna.';

  @override
  String get accounts => 'Účty';

  @override
  String get conversations => 'Konverzace';

  @override
  String get addAccount => 'Přidat účet';

  @override
  String get switchAccount => 'Přepnout účet';

  @override
  String get refresh => 'Obnovit';

  @override
  String get syncing => 'Synchronizuji…';

  @override
  String get cached => 'Zobrazuji uložené konverzace';

  @override
  String get noConversations => 'Zatím žádné konverzace';

  @override
  String get noConversationsBody =>
      'Jakmile se na tomto Nextcloud účtu objeví konverzace, zobrazí se zde.';

  @override
  String get selectConversation => 'Vyberte konverzaci';

  @override
  String get selectConversationBody =>
      'Vyberte konverzaci a zobrazí se její údaje oddělené podle účtu.';

  @override
  String get conversationDetails => 'Podrobnosti konverzace';

  @override
  String get server => 'Server';

  @override
  String get signedInAs => 'Přihlášený účet';

  @override
  String unreadMessages(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count nepřečtených zpráv',
      few: '$count nepřečtené zprávy',
      one: '1 nepřečtená zpráva',
      zero: 'Žádné nepřečtené zprávy',
    );
    return '$_temp0';
  }

  @override
  String get lastMessageUnavailable => 'Nová aktivita';

  @override
  String get syncCredentialMissing => 'Tento účet se musí znovu přihlásit.';

  @override
  String get syncTalkUnavailable => 'Talk už na tomto serveru není dostupný.';

  @override
  String get syncUnsupported =>
      'Server neposkytuje podporované rozhraní konverzací.';

  @override
  String get syncRateLimited =>
      'Server požádal aplikaci, aby před další synchronizací počkala.';

  @override
  String get syncUnavailable =>
      'Synchronizace konverzací je dočasně nedostupná.';

  @override
  String get syncUpgradeRequired =>
      'Před synchronizací konverzací je nutné aktualizovat server.';

  @override
  String get syncInvalidResponse =>
      'Uložené konverzace zůstaly zachované, ale nová odpověď serveru byla odmítnuta.';

  @override
  String get syncNetwork =>
      'Jste offline. Uložené konverzace zůstávají dostupné.';

  @override
  String get close => 'Zavřít';

  @override
  String get chatEmpty => 'Zatím žádné zprávy';

  @override
  String get chatEmptyBody => 'Zprávy v této konverzaci se zobrazí zde.';

  @override
  String get messageHint => 'Napište zprávu';

  @override
  String get sendMessage => 'Odeslat zprávu';

  @override
  String get openEmojiPicker => 'Otevřít výběr emoji';

  @override
  String get emojiSearchHint => 'Vyhledat emoji';

  @override
  String get emojiNoResults => 'Žádné emoji nenalezeno';

  @override
  String get emojiCategorySmileys => 'Emotikony';

  @override
  String get emojiCategoryPeople => 'Lidé';

  @override
  String get emojiCategoryAnimals => 'Zvířata';

  @override
  String get emojiCategoryFood => 'Jídlo';

  @override
  String get emojiCategoryActivities => 'Aktivity';

  @override
  String get emojiCategoryTravel => 'Cestování';

  @override
  String get emojiCategoryObjects => 'Předměty';

  @override
  String get emojiCategorySymbols => 'Symboly';

  @override
  String get mentionSuggestionsEmpty => 'Žádné shody';

  @override
  String get mentionSuggestionsError => 'Návrhy se nepodařilo načíst';

  @override
  String get openGiphyPicker => 'Otevřít výběr GIFů';

  @override
  String get giphyChecking => 'Kontroluji dostupnost GIFů…';

  @override
  String get giphyRetry => 'Zkusit znovu načíst GIFy';

  @override
  String get giphyUnavailable => 'GIFy nejsou na tomto serveru dostupné.';

  @override
  String get giphySearchHint => 'Hledat GIFy';

  @override
  String get giphyNoResults => 'Žádné GIFy nenalezeny';

  @override
  String get giphyLoadMore => 'Načíst další';

  @override
  String get giphyPoweredBy => 'Powered by GIPHY';

  @override
  String get messageTooLong => 'Zpráva je příliš dlouhá.';

  @override
  String get loadOlderMessages => 'Načíst starší zprávy';

  @override
  String get loadingOlderMessages => 'Načítám starší zprávy…';

  @override
  String get chatHistoryGapNotice => 'Část zpráv zde chybí';

  @override
  String get readOnlyConversation => 'Tato konverzace je jen pro čtení.';

  @override
  String get deletedMessage => 'Zpráva byla smazána';

  @override
  String get outboxQueued => 'Čeká na odeslání';

  @override
  String get outboxSending => 'Odesílám…';

  @override
  String get outboxRetryable => 'Čeká na připojení';

  @override
  String get outboxAwaitingConfirmation =>
      'Server už mohl tuto zprávu přijmout.';

  @override
  String get outboxFailed => 'Zprávu se nepodařilo odeslat';

  @override
  String get messageSent => 'Odesláno';

  @override
  String get messageRead => 'Přečteno';

  @override
  String get retrySend => 'Zkusit odeslat znovu';

  @override
  String get resendMessage => 'Odeslat zprávu znovu';

  @override
  String get duplicateRiskTitle => 'Odeslat tuto zprávu znovu?';

  @override
  String get duplicateRiskBody =>
      'První pokus mohl dorazit na server. Opětovné odeslání může vytvořit duplicitní zprávu.';

  @override
  String get confirmResend => 'Odeslat znovu';

  @override
  String get chatUnsupported =>
      'Server neposkytuje podporované rozhraní chatu.';

  @override
  String get chatUnavailable =>
      'Chat je dočasně nedostupný. Uložené zprávy zůstávají viditelné.';

  @override
  String get chatInvalidResponse =>
      'Uložené zprávy zůstaly zachované, ale nová odpověď chatu byla odmítnuta.';

  @override
  String get thread => 'Vlákno';

  @override
  String threadReplies(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count odpovědí',
      few: '$count odpovědi',
      one: '1 odpověď',
    );
    return '$_temp0';
  }

  @override
  String get openThread => 'Otevřít vlákno';

  @override
  String get edited => 'upraveno';

  @override
  String get attachment => 'Příloha';

  @override
  String get openAttachment => 'Otevřít přílohu';

  @override
  String get imageAttachment => 'Obrázková příloha';

  @override
  String get openImage => 'Otevřít obrázek';

  @override
  String get loadingImage => 'Načítám obrázek…';

  @override
  String get imageLoadFailed => 'Obrázek se nepodařilo načíst.';

  @override
  String get zoomOut => 'Oddálit';

  @override
  String get resetZoom => 'Obnovit přiblížení';

  @override
  String get zoomIn => 'Přiblížit';

  @override
  String get attachImage => 'Připojit obrázek';

  @override
  String get preparingImage => 'Připravuji přílohu…';

  @override
  String get imageUploadQueued => 'Čeká na nahrání';

  @override
  String uploadingImage(int percent) {
    return 'Nahrávám… $percent %';
  }

  @override
  String get confirmingAttachment => 'Potvrzuji přílohu…';

  @override
  String get cancellingUpload => 'Ruším nahrávání…';

  @override
  String get imageSent => 'Příloha byla odeslána';

  @override
  String get imageUploadFailed => 'Přílohu se nepodařilo odeslat.';

  @override
  String get imageUploadFailedQuota =>
      'Přílohu se nepodařilo odeslat: úložiště je zaplněné.';

  @override
  String get imageUploadFailedPermission =>
      'Přílohu se nepodařilo odeslat: nemáte oprávnění sem nahrávat soubory.';

  @override
  String get uploadCancelled => 'Nahrávání bylo zrušeno';

  @override
  String get participantAvatarGuest => 'Host';

  @override
  String get participantAvatarBot => 'Bot';

  @override
  String get participantAvatarBridge => 'Účastník propojené služby';

  @override
  String get participantAvatarSystem => 'Systém';

  @override
  String get participantAvatarUnknown => 'Účastník';

  @override
  String get cancelReply => 'Zrušit odpověď';

  @override
  String replyingTo(Object name) {
    return 'Odpověď uživateli $name';
  }

  @override
  String get mediaCapabilityChecking => 'Ověřuji podporu příloh…';

  @override
  String get mediaCapabilityUnavailable => 'Přílohy jsou dočasně nedostupné.';

  @override
  String get retryMediaCapabilities => 'Zkusit přílohy znovu';

  @override
  String get recordVoiceMessage => 'Nahrát hlasovou zprávu';

  @override
  String get stopVoiceRecording => 'Zastavit nahrávání';

  @override
  String get playVoiceMessage => 'Přehrát hlasovou zprávu';

  @override
  String get stopVoiceMessage => 'Zastavit hlasovou zprávu';

  @override
  String get playVoicePreview => 'Přehrát náhled hlasové zprávy';

  @override
  String get cancelVoiceMessage => 'Zrušit hlasovou zprávu';

  @override
  String get sendVoiceMessage => 'Odeslat hlasovou zprávu';

  @override
  String get voiceMessageQueued => 'Hlasová zpráva čeká na odeslání';

  @override
  String get voiceUnsupported => 'Tato konverzace nepodporuje hlasové zprávy.';

  @override
  String get voicePermissionDenied => 'Přístup k mikrofonu byl zamítnut.';

  @override
  String get voicePermissionPermanentlyDenied =>
      'Povolte přístup k mikrofonu v nastavení systému.';

  @override
  String get voicePermissionRequestFailed =>
      'Přístup k mikrofonu se nepodařilo ověřit.';

  @override
  String get voiceRecordingFailed => 'Hlasovou zprávu se nepodařilo nahrát.';

  @override
  String get voiceInvalidRecording => 'Nahrávka je prázdná nebo nepodporovaná.';

  @override
  String get voicePlaybackFailed => 'Náhled nahrávky se nepodařilo přehrát.';

  @override
  String voicePlaybackPosition(Object duration, Object position) {
    return '$position z $duration';
  }

  @override
  String get voiceSendFailed =>
      'Hlasovou zprávu se nepodařilo zařadit k odeslání.';

  @override
  String get voiceCleanupFailed => 'Nahrávku se nepodařilo bezpečně odstranit.';

  @override
  String get presenceOnline => 'Online';

  @override
  String get presenceAway => 'Pryč';

  @override
  String get presenceBusy => 'Zaneprázdněn';

  @override
  String get presenceDoNotDisturb => 'Nerušit';

  @override
  String get roomDetailsOpenTooltip => 'Informace o konverzaci';

  @override
  String get roomDetailsTitle => 'Informace o konverzaci';

  @override
  String get roomDetailsDescriptionLabel => 'Popis';

  @override
  String get roomDetailsTypeLabel => 'Typ';

  @override
  String get roomDetailsTypeOneToOne => 'Soukromá konverzace';

  @override
  String get roomDetailsTypeGroup => 'Skupinová konverzace';

  @override
  String get roomDetailsTypePublic => 'Veřejný kanál';

  @override
  String get roomDetailsTypeChangelog => 'Přehled novinek';

  @override
  String get roomDetailsTypeFormerOneToOne => 'Bývalá soukromá konverzace';

  @override
  String get roomDetailsTypeNoteToSelf => 'Poznámky pro sebe';

  @override
  String get roomDetailsTypeUnknown => 'Neznámý';

  @override
  String get roomDetailsReadOnlyLabel => 'Pouze pro čtení';

  @override
  String get roomDetailsReadOnlyYes => 'Ano';

  @override
  String get roomDetailsReadOnlyNo => 'Ne';

  @override
  String get roomDetailsNotificationLabel => 'Oznámení';

  @override
  String get roomDetailsNotificationDefault => 'Výchozí';

  @override
  String get roomDetailsNotificationAlways => 'Všechny zprávy';

  @override
  String get roomDetailsNotificationMention => 'Jen zmínky';

  @override
  String get roomDetailsNotificationNever => 'Vypnuto';

  @override
  String get roomDetailsNotificationUnknown => 'Neznámé';

  @override
  String get roomDetailsParticipantsHeader => 'Účastníci';

  @override
  String roomDetailsParticipantsCount(int count) {
    return '$count účastníků';
  }

  @override
  String get roomDetailsParticipantsEmpty => 'Žádní účastníci.';

  @override
  String get roomDetailsLoadError => 'Účastníky se nepodařilo načíst.';

  @override
  String get roomDetailsRoleOwner => 'Vlastník';

  @override
  String get roomDetailsRoleModerator => 'Moderátor';

  @override
  String get roomDetailsRoleUser => 'Uživatel';

  @override
  String get roomDetailsRoleGuest => 'Host';

  @override
  String get roomDetailsRoleGuestModerator => 'Moderátor (host)';

  @override
  String get roomDetailsRoleUnknown => 'Neznámá role';

  @override
  String get roomDetailsActionsHeader => 'Nastavení konverzace';

  @override
  String get roomDetailsRenameAction => 'Přejmenovat konverzaci';

  @override
  String get roomDetailsRenameDialogTitle => 'Přejmenovat konverzaci';

  @override
  String get roomDetailsRenameFieldLabel => 'Název';

  @override
  String get roomDetailsDescriptionEditAction => 'Upravit popis';

  @override
  String get roomDetailsDescriptionDialogTitle => 'Upravit popis';

  @override
  String get roomDetailsDescriptionFieldLabel => 'Popis';

  @override
  String get roomDetailsSave => 'Uložit';

  @override
  String get roomDetailsNotificationDialogTitle => 'Úroveň oznámení';

  @override
  String get roomDetailsFavoriteLabel => 'Oblíbená konverzace';

  @override
  String get roomDetailsLeaveAction => 'Opustit konverzaci';

  @override
  String get roomDetailsLeaveDialogTitle => 'Opustit konverzaci?';

  @override
  String get roomDetailsLeaveDialogMessage =>
      'Přestanete dostávat nové zprávy z této konverzace, dokud vás do ní někdo znovu nepozve.';

  @override
  String get roomDetailsLeaveDialogConfirm => 'Opustit';

  @override
  String get roomDetailsActionErrorGeneric =>
      'Změnu se nepodařilo uložit. Zkuste to prosím znovu.';

  @override
  String get roomDetailsActionErrorReauth =>
      'Pro tuto změnu se prosím přihlaste znovu.';

  @override
  String get roomDetailsActionErrorForbidden => 'K této akci nemáte oprávnění.';

  @override
  String get roomDetailsActionErrorRoomMissing =>
      'Tato konverzace už neexistuje.';

  @override
  String get roomDetailsLeaveRejected =>
      'Nemůžete konverzaci opustit, dokud nepovýšíte jiného moderátora.';

  @override
  String get settingsTitle => 'Nastavení';

  @override
  String get settingsAccountsSection => 'Účty';

  @override
  String get settingsAccountSelected => 'Aktivní';

  @override
  String get settingsAccountsLoadFailed => 'Účty se nepodařilo načíst.';

  @override
  String get settingsAddAccount => 'Přidat účet';

  @override
  String get settingsRemoveAccountUnavailable =>
      'Odebrání účtu zatím není podporováno. Přístup zrušíte odhlášením na serveru.';

  @override
  String get settingsThemeSection => 'Vzhled';

  @override
  String get settingsThemeSystem => 'Podle systému';

  @override
  String get settingsThemeLight => 'Světlý';

  @override
  String get settingsThemeDark => 'Tmavý';

  @override
  String get conversationActionsTitle => 'Akce konverzace';

  @override
  String get conversationActionMarkUnread => 'Označit jako nepřečtené';

  @override
  String get conversationActionArchive => 'Archivovat konverzaci';

  @override
  String get conversationActionUnarchive => 'Zrušit archivaci konverzace';

  @override
  String conversationArchivedSectionShow(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Archivováno ($count)',
      few: 'Archivováno ($count)',
      one: 'Archivováno (1)',
    );
    return '$_temp0';
  }

  @override
  String get conversationArchivedSectionHide => 'Zpět na konverzace';

  @override
  String get conversationActionErrorGeneric =>
      'Akci se nepodařilo dokončit. Zkuste to prosím znovu.';

  @override
  String get conversationActionErrorReauth =>
      'Pro tuto změnu se prosím přihlaste znovu.';

  @override
  String get messageActionReply => 'Odpovědět';

  @override
  String get messageActionCopy => 'Kopírovat text';

  @override
  String get messageActionEdit => 'Upravit';

  @override
  String get messageActionDelete => 'Smazat';

  @override
  String get messageActionReact => 'Reagovat';

  @override
  String get messageCopied => 'Zkopírováno do schránky';

  @override
  String get editMessageTitle => 'Upravit zprávu';

  @override
  String get editMessageSave => 'Uložit';

  @override
  String get deleteMessageConfirmTitle => 'Smazat tuto zprávu?';

  @override
  String get deleteMessageConfirmBody => 'Tuto akci nelze vrátit zpět.';

  @override
  String get reactionPickerMore => 'Další emoji…';

  @override
  String get messageActionUnsupported => 'Tato akce zde není dostupná.';

  @override
  String get messageActionMessageMissing => 'Tato zpráva už není dostupná.';

  @override
  String get searchMessagesTooltip => 'Hledat ve zprávách';

  @override
  String get searchMessagesTitle => 'Hledat ve zprávách';

  @override
  String get searchMessagesHint => 'Hledat ve zprávách';

  @override
  String get searchMessagesPrompt => 'Zadejte hledaný text';

  @override
  String get searchMessagesNoResults => 'Nic nenalezeno';

  @override
  String get searchMessagesError => 'Hledání selhalo. Zkuste to znovu.';

  @override
  String get newConversationTitle => 'Nová konverzace';

  @override
  String get newConversationSearchLabel => 'Hledat lidi a skupiny';

  @override
  String get newConversationIdle =>
      'Začněte psát jméno a najděte, s kým chcete chatovat.';

  @override
  String get newConversationEmpty => 'Nenašli se žádní lidé ani skupiny.';

  @override
  String get newConversationNameDialogTitle =>
      'Pojmenujte skupinovou konverzaci';

  @override
  String get newConversationNameLabel => 'Název konverzace';

  @override
  String get newConversationCreate => 'Vytvořit';

  @override
  String get newConversationErrorAccountMissing =>
      'Tento účet už není dostupný.';

  @override
  String get newConversationErrorCredentialMissing =>
      'Přihlaste se znovu, abyste mohli hledat lidi a skupiny.';

  @override
  String get newConversationErrorInvalidSearchTerm => 'Zadejte hledaný výraz.';

  @override
  String get newConversationErrorRoomNameRequired =>
      'Konverzace potřebuje název.';

  @override
  String get newConversationErrorReauthenticationRequired =>
      'Pro pokračování se přihlaste znovu.';

  @override
  String get newConversationErrorOcsFailure => 'Server požadavek odmítl.';

  @override
  String get newConversationErrorRateLimited =>
      'Příliš mnoho požadavků. Zkuste to za chvíli.';

  @override
  String get newConversationErrorServiceUnavailable =>
      'Server je dočasně nedostupný.';

  @override
  String get newConversationErrorInvalidResponse =>
      'Server poslal neočekávanou odpověď.';

  @override
  String get newConversationErrorNetwork => 'Server je nedostupný.';

  @override
  String get roomDetailsParticipantActionsTooltip => 'Akce s účastníkem';

  @override
  String get roomDetailsPromoteModerator => 'Povýšit na moderátora';

  @override
  String get roomDetailsDemoteModerator => 'Odebrat práva moderátora';

  @override
  String get roomDetailsRemoveParticipant => 'Odebrat z konverzace';

  @override
  String get roomDetailsRemoveDialogTitle => 'Odebrat účastníka?';

  @override
  String roomDetailsRemoveDialogMessage(String name) {
    return '$name ztratí přístup do této konverzace, dokud ho někdo znovu nepozve.';
  }

  @override
  String get roomDetailsRemoveDialogConfirm => 'Odebrat';

  @override
  String get roomDetailsParticipantActionRejected =>
      'Server tuto změnu u tohoto účastníka odmítl.';

  @override
  String get callBannerTitle => 'Probíhá hovor';

  @override
  String callBannerRunningFor(String duration) {
    return 'Běží $duration';
  }

  @override
  String get callBannerJoin => 'Připojit se k hovoru';

  @override
  String callBannerJoinUnsupported(String transport) {
    return 'Připojení zatím není implementované (signalizace: $transport).';
  }

  @override
  String get callBannerTransportChecking =>
      'Zjišťuji, jak je hovor signalizován…';

  @override
  String get callBannerTransportUnavailable =>
      'Transport hovoru se nepodařilo zjistit.';

  @override
  String get callBannerTransportReauth =>
      'Přihlaste se znovu, aby šlo zjistit signalizaci hovoru.';

  @override
  String get callBannerTransportRoomUnavailable =>
      'Tato konverzace už na serveru není dostupná.';

  @override
  String get callTransportInternal => 'interní';

  @override
  String get callTransportExternalHpb => 'externí HPB';

  @override
  String get messageActionForward => 'Přeposlat';

  @override
  String get forwardMessageTitle => 'Přeposlat do konverzace';

  @override
  String get forwardNoConversations =>
      'Žádná jiná konverzace není k dispozici.';

  @override
  String messageForwarded(String conversation) {
    return 'Zpráva přeposlána do $conversation';
  }

  @override
  String get messageForwardFailed => 'Zprávu se nepodařilo přeposlat.';

  @override
  String get cancelSend => 'Zrušit odeslání';

  @override
  String get outboxCancelAmbiguous =>
      'Zprávu už nelze zrušit, mohla dorazit na server.';

  @override
  String get roomDetailsDeleteAction => 'Smazat konverzaci';

  @override
  String get roomDetailsDeleteDialogTitle => 'Smazat konverzaci?';

  @override
  String get roomDetailsDeleteDialogMessage =>
      'Konverzace i všechny její zprávy se smažou všem účastníkům. Akci nelze vzít zpět.';

  @override
  String get roomDetailsDeleteDialogConfirm => 'Smazat';

  @override
  String get roomDetailsDeleteRejected =>
      'Tuto konverzaci nelze smazat. Konverzaci jeden na jednoho lze jen opustit.';

  @override
  String get saveImage => 'Uložit obrázek';

  @override
  String get shareImage => 'Sdílet obrázek';

  @override
  String get imageSavedToGallery => 'Obrázek byl uložen do galerie.';

  @override
  String get imageSavePermissionDenied =>
      'Uložení vyžaduje přístup do galerie. Povolte ho v nastavení systému a zkuste to znovu.';

  @override
  String get imageSaveOutOfSpace =>
      'V zařízení není dost volného místa pro uložení obrázku.';

  @override
  String get imageSaveFailed => 'Obrázek se nepodařilo uložit.';

  @override
  String get imageShareFailed => 'Obrázek se nepodařilo sdílet.';

  @override
  String get jumpToOriginalMessage => 'Zobrazit původní zprávu';

  @override
  String get jumpToMessageNotFound =>
      'Tato zpráva už v konverzaci není dostupná.';

  @override
  String get jumpToMessageConversationMissing =>
      'Tato konverzace není v zařízení dostupná.';

  @override
  String get searchMessagesErrorAccountMissing =>
      'Tento účet už není dostupný.';

  @override
  String get searchMessagesErrorCredentialMissing =>
      'Pro hledání ve zprávách se přihlaste znovu.';

  @override
  String get searchMessagesErrorReauthentication =>
      'Vaše přihlášení vypršelo. Přihlaste se znovu.';

  @override
  String get searchMessagesErrorProviderMissing =>
      'Tento server hledání ve zprávách nenabízí.';

  @override
  String get searchMessagesErrorTransient =>
      'Server je vytížený. Zkuste to za chvíli.';

  @override
  String get searchMessagesErrorServer => 'Server hledání odmítl.';

  @override
  String get searchMessagesErrorInvalidResponse =>
      'Server poslal odpověď hledání, které aplikace nerozumí.';

  @override
  String get searchMessagesErrorNetwork => 'Server je nedostupný.';

  @override
  String get addAttachment => 'Přidat přílohu';

  @override
  String get attachFromGallery => 'Vybrat obrázek';

  @override
  String get attachFromCamera => 'Vyfotit';

  @override
  String get attachFromFile => 'Vybrat soubor';

  @override
  String get attachmentCameraDenied =>
      'Focení vyžaduje přístup ke kameře. Povolte ho v nastavení systému a zkuste to znovu.';

  @override
  String get attachmentCameraUnavailable =>
      'Toto zařízení nemá dostupnou kameru.';

  @override
  String get attachmentTypeUnsupported =>
      'Tento typ souboru sem nelze připojit.';

  @override
  String get pauseVoiceRecording => 'Pozastavit nahrávání';

  @override
  String get resumeVoiceRecording => 'Pokračovat v nahrávání';

  @override
  String get voiceRecordingLevel => 'Hlasitost nahrávání';

  @override
  String get voicePauseFailed => 'Nahrávání se nepodařilo pozastavit.';

  @override
  String get pauseVoiceMessage => 'Pozastavit hlasovou zprávu';

  @override
  String get voiceMessagePosition => 'Pozice přehrávání';

  @override
  String voiceMessageProgress(String position, String duration) {
    return '$position z $duration';
  }

  @override
  String get settingsRemoveAccount => 'Odebrat účet';

  @override
  String get settingsRemoveAccountDialogTitle => 'Odebrat tento účet?';

  @override
  String settingsRemoveAccountDialogMessage(
    Object loginName,
    Object serverUrl,
  ) {
    return 'Účet $loginName na $serverUrl bude z tohoto zařízení odebrán. Smažou se jeho konverzace, zprávy, rozepsané texty, čekající nahrávání, uložené náhledy i hlasové zprávy a uložené heslo. Aplikační heslo se odvolá na serveru.';
  }

  @override
  String get settingsRemoveAccountDialogConfirm => 'Odebrat';

  @override
  String get settingsRemoveAccountDone => 'Účet byl odebrán.';

  @override
  String get settingsRemoveAccountDoneNotRevoked =>
      'Účet byl z tohoto zařízení odebrán, ale server nepotvrdil odvolání aplikačního hesla. Odvolejte ho sami na serveru v Nastavení, Zabezpečení.';

  @override
  String get roomDetailsGuestsLabel => 'Hosté';

  @override
  String get roomDetailsGuestsAllowed => 'Připojí se každý, kdo má odkaz';

  @override
  String get roomDetailsGuestsBlocked => 'Jen pozvaní lidé';

  @override
  String get roomDetailsGuestsCloseDialogTitle => 'Zakázat hosty?';

  @override
  String get roomDetailsGuestsCloseDialogMessage =>
      'Odkaz přestane fungovat a hosté, kteří přes něj přišli, ztratí přístup. Pozvaných účastníků se to netýká.';

  @override
  String get roomDetailsGuestsCloseDialogConfirm => 'Změnit na soukromou';

  @override
  String get roomDetailsInviteLinkAction => 'Sdílet odkaz pro hosty';

  @override
  String get roomDetailsInviteLinkSubtitle =>
      'Kdo má tento odkaz, připojí se jako host';

  @override
  String get roomDetailsInviteLinkShareSubject => 'Připojte se do konverzace';

  @override
  String get roomDetailsPasswordLabel => 'Heslo';

  @override
  String get roomDetailsPasswordSet => 'Hosté potřebují heslo';

  @override
  String get roomDetailsPasswordUnset => 'Bez hesla';

  @override
  String get roomDetailsPasswordDialogTitle => 'Heslo pro hosty';

  @override
  String get roomDetailsPasswordFieldLabel => 'Nové heslo';

  @override
  String get roomDetailsPasswordRemoveAction => 'Zrušit heslo';

  @override
  String get roomDetailsPasswordRemoveDialogTitle => 'Zrušit heslo?';

  @override
  String get roomDetailsPasswordRemoveDialogMessage =>
      'Kdokoli s odkazem se pak připojí bez hesla.';

  @override
  String get roomDetailsPasswordRemoveDialogConfirm => 'Zrušit heslo';

  @override
  String get roomDetailsPasswordRejected => 'Server toto heslo odmítl.';

  @override
  String get roomDetailsLobbyLabel => 'Čekárna';

  @override
  String get roomDetailsLobbyOff => 'Zapojit se může každý';

  @override
  String get roomDetailsLobbyOn => 'Zapojit se mohou jen moderátoři';

  @override
  String roomDetailsLobbyOnUntil(String time) {
    return 'Jen moderátoři do $time';
  }

  @override
  String get roomDetailsLobbyDialogTitle => 'Zapnout čekárnu';

  @override
  String get roomDetailsLobbyDialogMessage =>
      'Dokud čekárna běží, mohou číst, psát a volat jen moderátoři. Vyberte, kdy se má otevřít, nebo ji nechte otevřít ručně.';

  @override
  String get roomDetailsLobbyTimerNone => 'Bez času otevření';

  @override
  String get roomDetailsLobbyTimerPick => 'Vybrat datum a čas';

  @override
  String get roomDetailsLobbyDialogConfirm => 'Zapnout čekárnu';

  @override
  String get roomDetailsReadOnlyToggleLabel => 'Jen ke čtení';

  @override
  String get roomDetailsReadOnlyToggleOn => 'Nikdo nemůže psát ani volat';

  @override
  String get roomDetailsReadOnlyToggleOff => 'Psát může každý';

  @override
  String get roomDetailsReadOnlyDialogTitle => 'Uzamknout konverzaci?';

  @override
  String get roomDetailsReadOnlyDialogMessage =>
      'Nikdo nebude moci poslat zprávu ani zahájit hovor, dokud ji moderátor zase neodemkne.';

  @override
  String get roomDetailsReadOnlyDialogConfirm => 'Uzamknout';

  @override
  String get roomDetailsAvatarAction => 'Obrázek konverzace';

  @override
  String get roomDetailsAvatarDialogTitle => 'Obrázek konverzace';

  @override
  String get roomDetailsAvatarDialogMessage =>
      'Vyberte emoji, které bude sloužit jako obrázek konverzace.';

  @override
  String get roomDetailsAvatarSetAction => 'Použít toto emoji';

  @override
  String get roomDetailsAvatarRemoveAction => 'Odebrat obrázek';

  @override
  String roomDetailsAvatarEmojiSemantics(String emoji) {
    return 'Emoji $emoji';
  }

  @override
  String get roomDetailsBanParticipant => 'Zabanovat v konverzaci';

  @override
  String get roomDetailsBanDialogTitle => 'Zabanovat účastníka?';

  @override
  String roomDetailsBanDialogMessage(String name) {
    return '$name bude z konverzace odebrán a nepřipojí se zpět, dokud ban nezrušíte.';
  }

  @override
  String get roomDetailsBanNoteLabel => 'Důvod (uvidí ho jen moderátoři)';

  @override
  String get roomDetailsBanDialogConfirm => 'Zabanovat';

  @override
  String get roomDetailsBansAction => 'Zabanovaní účastníci';

  @override
  String get roomDetailsBansDialogTitle => 'Zabanovaní účastníci';

  @override
  String get roomDetailsBansEmpty => 'Nikdo není zabanovaný.';

  @override
  String get roomDetailsBansLoadError => 'Bany se nepodařilo načíst.';

  @override
  String get roomDetailsUnbanAction => 'Zrušit ban';

  @override
  String get roomDetailsBanRejected => 'Server tento ban odmítl.';

  @override
  String get roomDetailsAvatarPickImage => 'Vybrat obrázek';

  @override
  String get roomDetailsAvatarTypeRejected =>
      'Jako obrázek konverzace projde jen čtvercový PNG nebo JPEG.';

  @override
  String get roomDetailsAvatarTooLarge => 'Tento obrázek je příliš velký.';

  @override
  String get roomDetailsAvatarRejected => 'Server tento obrázek nepřijal.';
}
