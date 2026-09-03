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
  String get appTitle => 'NKS Talk';

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
  String get reauthenticateAccountTitle => 'Znovu se přihlásit k tomuto účtu';

  @override
  String get serverAddressLabel => 'Adresa serveru';

  @override
  String get serverAddressHint => 'cloud.example.com';

  @override
  String get connect => 'Pokračovat';

  @override
  String get reauthenticateAccountAction => 'Přihlásit se znovu';

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
  String get incomingShareTitle => 'Sdílet do konverzace';

  @override
  String get incomingShareAccount => 'Účet';

  @override
  String get incomingShareConversation => 'Konverzace';

  @override
  String get incomingShareSend => 'Odeslat';

  @override
  String get incomingShareNoTargets =>
      'Není dostupná žádná konverzace, do které lze psát.';

  @override
  String get incomingShareSendFailed =>
      'Položku se nepodařilo zařadit k odeslání. Zkontrolujte účet a zkuste to znovu.';

  @override
  String get incomingShareCleanupFailed =>
      'Položka byla odeslána, ale její dočasnou kopii se nepodařilo odstranit.';

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
  String get reauthenticateAccountMismatch =>
      'Přihlaste se ke stejnému účtu. Uložený účet nebyl změněn.';

  @override
  String get localPersistenceFailed =>
      'Účet se nepodařilo bezpečně uložit do tohoto zařízení.';

  @override
  String get unexpectedError => 'Něco se nepodařilo. Data účtu nebyla změněna.';

  @override
  String get accounts => 'Účty';

  @override
  String get hideConversationList => 'Skrýt seznam konverzací';

  @override
  String get showConversationList => 'Zobrazit seznam konverzací';

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
  String get emojiPickerTitle => 'Emoji';

  @override
  String get emojiPickerCloseTooltip => 'Zavřít výběr emoji';

  @override
  String get emojiManageFavorites => 'Spravovat oblíbené';

  @override
  String get emojiFinishManagingFavorites => 'Dokončit úpravy oblíbených';

  @override
  String get emojiFavoriteModeHint =>
      'Klepnutím na emoji ho přidáte do oblíbených nebo odeberete.';

  @override
  String get emojiAddFavoriteLabel => 'Přidat do oblíbených';

  @override
  String get emojiRemoveFavoriteLabel => 'Odebrat z oblíbených';

  @override
  String get emojiSearchHint => 'Vyhledat emoji';

  @override
  String get emojiNoResults => 'Žádné emoji nenalezeno';

  @override
  String get emojiNoRecents => 'Žádné nedávno použité emoji';

  @override
  String get emojiNoFavorites => 'Žádné oblíbené emoji';

  @override
  String get emojiCategoryFavorites => 'Oblíbené';

  @override
  String get emojiCategoryRecent => 'Nedávné';

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
  String get emojiCategoryFlags => 'Vlajky';

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
  String get jumpToNewestMessages => 'Skočit na nejnovější zprávy';

  @override
  String get silentSendOff => 'Odeslat bez upozornění';

  @override
  String get silentSendOn => 'Odesílá se bez upozornění';

  @override
  String get chatHistoryGapNotice => 'Část zpráv zde chybí';

  @override
  String get readOnlyConversation => 'Tato konverzace je jen pro čtení.';

  @override
  String get noChatPermissionConversation =>
      'V této konverzaci nemáte oprávnění psát.';

  @override
  String get lobbyConversation =>
      'Konverzace zatím nezačala. Až ji moderátor otevře, budete moct psát.';

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
  String get threadManagementTitle => 'Vlákna';

  @override
  String get threadManagementOpenTooltip => 'Spravovat vlákna';

  @override
  String get threadManagementRecentTab => 'Nedávná';

  @override
  String get threadManagementSubscribedTab => 'Sledovaná';

  @override
  String get threadManagementRecentEmpty => 'Žádná nedávná vlákna';

  @override
  String get threadManagementRecentEmptyBody =>
      'Odpověď na zprávu vlákno nezaloží. Vlákno vznikne, až ho z některé zprávy založíte, a pak se objeví tady.';

  @override
  String get threadManagementSubscribedEmpty => 'Žádná sledovaná vlákna';

  @override
  String get threadManagementSubscribedEmptyBody =>
      'Vlákna sledovaná v tomto účtu se zobrazí tady, i z jiných konverzací.';

  @override
  String get threadManagementConversationMissing =>
      'Tato konverzace ještě není v místní mezipaměti.';

  @override
  String get threadManagementDetailTitle => 'Detail vlákna';

  @override
  String get threadManagementRenameDialogTitle => 'Přejmenovat vlákno';

  @override
  String get threadManagementRenameAction => 'Přejmenovat vlákno';

  @override
  String get threadManagementNameLabel => 'Název vlákna';

  @override
  String get threadManagementNameRequired => 'Zadejte název vlákna.';

  @override
  String get threadManagementActionsNeedConnection =>
      'Připojte se k serveru, aby aplikace ověřila dostupné akce vlákna.';

  @override
  String get threadManagementUnsupported =>
      'Tento server nepodporuje správu vláken.';

  @override
  String get threadManagementPermissionDenied =>
      'Nemáte oprávnění toto vlákno změnit.';

  @override
  String get threadManagementNotFound => 'Vlákno už na serveru není dostupné.';

  @override
  String get threadManagementAmbiguous =>
      'Server mohl změnu provést. Před dalším pokusem vlákno obnovte.';

  @override
  String get threadManagementOpenUnavailable =>
      'Vlákno se nepodařilo otevřít z ověřené odpovědi serveru.';

  @override
  String get edited => 'upraveno';

  @override
  String get attachment => 'Příloha';

  @override
  String get openAttachment => 'Otevřít přílohu';

  @override
  String openLocation(String name) {
    return 'Otevřít polohu: $name';
  }

  @override
  String get shareLocation => 'Poloha';

  @override
  String get sharedLocationDefaultName => 'Sdílená poloha';

  @override
  String get locationConfirmTitle => 'Sdílet aktuální polohu?';

  @override
  String locationCoordinates(String latitude, String longitude) {
    return '$latitude, $longitude';
  }

  @override
  String get locationPermissionDenied => 'Přístup k poloze byl zamítnut.';

  @override
  String get locationPermissionDeniedForever =>
      'Přístup k poloze je vypnutý v nastavení systému.';

  @override
  String get openAppSettings => 'Otevřít nastavení';

  @override
  String get openAppSettingsFailed =>
      'Nastavení systému se nepodařilo otevřít.';

  @override
  String get locationServicesDisabled =>
      'Zapněte služby určování polohy a zkuste to znovu.';

  @override
  String get locationUnavailable => 'Aktuální polohu se nepodařilo zjistit.';

  @override
  String get locationShareFailed => 'Polohu se nepodařilo sdílet.';

  @override
  String get locationShareAmbiguous =>
      'Server mohl polohu přijmout. Než pokus zopakujete, zkontrolujte chat.';

  @override
  String get locationShared => 'Poloha byla sdílena.';

  @override
  String outOfOffice(String user) {
    return '$user je mimo kancelář a nemusí odpovědět.';
  }

  @override
  String absencePeriod(String startDate, String endDate) {
    return 'Období nepřítomnosti: $startDate – $endDate';
  }

  @override
  String absenceReplacement(String name) {
    return 'Zástup: $name';
  }

  @override
  String get upcomingEventDefaultTitle => 'Nadcházející událost';

  @override
  String get dismissUpcomingEvent => 'Skrýt nadcházející událost';

  @override
  String get contactAttachment => 'Kontakt';

  @override
  String openContact(String name) {
    return 'Otevřít kontakt: $name';
  }

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
  String get transcribeVoiceMessage => 'Přepsat';

  @override
  String get cancelVoiceTranscription => 'Zrušit přepis';

  @override
  String get voiceTranscriptionRunning => 'Přepisuji hlasovou zprávu…';

  @override
  String get copyVoiceTranscript => 'Kopírovat přepis';

  @override
  String get voiceTranscriptCopied => 'Přepis zkopírován do schránky';

  @override
  String get voiceTranscriptionDenied =>
      'Přístup k rozpoznávání řeči byl zamítnut.';

  @override
  String get voiceTranscriptionRestricted =>
      'Rozpoznávání řeči je na tomto zařízení omezeno.';

  @override
  String get voiceTranscriptionUnavailable =>
      'Rozpoznávání řeči v zařízení není dostupné.';

  @override
  String get voiceTranscriptionInvalidFile =>
      'Tuto hlasovou zprávu nelze přepsat.';

  @override
  String get voiceTranscriptionFailed =>
      'Hlasovou zprávu se nepodařilo přepsat.';

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
  String get roomDetailsCallNotificationsLabel => 'Oznámení hovorů';

  @override
  String get roomDetailsCallNotificationsSubtitle =>
      'Upozornit při zahájení hovoru';

  @override
  String get roomDetailsMessageExpirationLabel => 'Expirace zpráv';

  @override
  String get roomDetailsMessageExpirationDialogTitle =>
      'Nastavit expiraci zpráv';

  @override
  String get roomDetailsMessageExpirationHint =>
      'Sdílené soubory už nebudou v této konverzaci dostupné, ale vlastníkovi se nesmažou.';

  @override
  String get roomDetailsMessageExpirationOff => 'Vypnuto';

  @override
  String get roomDetailsMessageExpirationOneHour => '1 hodina';

  @override
  String get roomDetailsMessageExpirationEightHours => '8 hodin';

  @override
  String get roomDetailsMessageExpirationOneDay => '1 den';

  @override
  String get roomDetailsMessageExpirationOneWeek => '1 týden';

  @override
  String get roomDetailsMessageExpirationFourWeeks => '4 týdny';

  @override
  String roomDetailsMessageExpirationCustom(int seconds) {
    return 'Vlastní ($seconds sekund)';
  }

  @override
  String get roomDetailsMessageExpirationRejected =>
      'Server toto nastavení expirace odmítl.';

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
  String get roomDetailsImportantLabel => 'Důležitá konverzace';

  @override
  String get roomDetailsImportantSubtitle =>
      'Upozorňovat i při zapnutém režimu Nerušit';

  @override
  String get roomDetailsSensitiveLabel => 'Citlivá konverzace';

  @override
  String get roomDetailsSensitiveSubtitle =>
      'Skrýt poslední zprávu a náhledy v oznámeních';

  @override
  String get roomDetailsSensitiveClassifiedSubtitle =>
      'Povinné u klasifikovaných konverzací';

  @override
  String get roomDetailsSensitiveRejected =>
      'U této konverzace musí náhledy zpráv zůstat skryté.';

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
  String get roomDetailsBotsTitle => 'Boti';

  @override
  String get roomDetailsBotsEmpty =>
      'Pro tuto konverzaci nejsou dostupní žádní boti.';

  @override
  String get roomDetailsBotEnabled => 'Zapnutý';

  @override
  String get roomDetailsBotDisabled => 'Vypnutý';

  @override
  String get roomDetailsBotEnable => 'Zapnout bota';

  @override
  String get roomDetailsBotDisable => 'Vypnout bota';

  @override
  String get roomDetailsBotUpdating => 'Aktualizuji bota…';

  @override
  String get roomDetailsBotsLoadFailed => 'Boty se nepodařilo načíst.';

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
  String get settingsProfileSection => 'Profil';

  @override
  String get settingsOpenProfile => 'Profil a stav';

  @override
  String get settingsOpenProfileSubtitle =>
      'Zobrazit profil a nastavit dostupnost';

  @override
  String get settingsRepliesSection => 'Odpovědi';

  @override
  String get settingsReplyLayoutInline => 'V konverzaci';

  @override
  String get settingsReplyLayoutInlineDescription =>
      'Odpověď zůstává v konverzaci pod citací zprávy, na kterou reaguje.';

  @override
  String get settingsReplyLayoutThread => 'V podvláknu';

  @override
  String get settingsReplyLayoutThreadDescription =>
      'Odpovědi z konverzace mizí a otevírají se v samostatném vlákně.';

  @override
  String get settingsThemeSection => 'Vzhled';

  @override
  String get settingsSecuritySection => 'Zabezpečení';

  @override
  String get settingsAppLock => 'Zámek aplikace';

  @override
  String get settingsAppLockSubtitle =>
      'Před zobrazením konverzací vyžadovat ověření zařízením.';

  @override
  String get settingsAppLockChangeFailed =>
      'Nastavení zámku aplikace se nepodařilo změnit.';

  @override
  String get appLockAuthenticationReason =>
      'Odemkněte své konverzace v NKS Talk';

  @override
  String get appLockAuthenticationCancelled =>
      'Ověření zařízením bylo zrušeno.';

  @override
  String get appLockLockedTitle => 'NKS Talk je zamčený';

  @override
  String get appLockLockedMessage =>
      'Pro pokračování se ověřte pomocí zařízení.';

  @override
  String get appLockLoadFailed =>
      'Nastavení zámku aplikace se nepodařilo bezpečně načíst. Zkuste to znovu.';

  @override
  String get appLockUnlock => 'Odemknout';

  @override
  String get settingsThemeSystem => 'Podle systému';

  @override
  String get settingsThemeLight => 'Světlý';

  @override
  String get settingsThemeDark => 'Tmavý';

  @override
  String get settingsDesktopSection => 'Počítač';

  @override
  String get settingsDesktopAutostart => 'Otevřít NKS Talk po přihlášení';

  @override
  String get settingsDesktopAutostartChecking =>
      'Kontroluji systémové automatické spuštění…';

  @override
  String get settingsDesktopAutostartOnSubtitle =>
      'NKS Talk se po přihlášení otevře automaticky.';

  @override
  String get settingsDesktopAutostartOffSubtitle =>
      'NKS Talk zůstane zavřený, dokud ho neotevřete.';

  @override
  String get settingsDesktopAutostartFailed =>
      'Systémové automatické spuštění se nepodařilo změnit.';

  @override
  String get settingsPushSection => 'Push notifikace';

  @override
  String get settingsNotificationPermission => 'Systémové oprávnění notifikací';

  @override
  String get settingsNotificationPermissionGranted => 'Uděleno';

  @override
  String get settingsNotificationPermissionDenied => 'Zamítnuto';

  @override
  String get settingsNotificationPermissionNotDetermined => 'Zatím nevyžádáno';

  @override
  String get settingsNotificationPermissionChecking => 'Kontrola…';

  @override
  String get settingsNotificationPermissionRequest => 'Povolit';

  @override
  String get settingsNotificationPermissionFailed =>
      'O oprávnění notifikací se nepodařilo požádat.';

  @override
  String get settingsPushTransportProxy => 'Vlastní proxy';

  @override
  String get settingsPushTransportProxySubtitle =>
      'Notifikace jdou stejnou cestou jako na iOS, přes nks-talk-notify.';

  @override
  String get settingsPushTransportWebPush => 'Web Push (záloha)';

  @override
  String get settingsPushTransportWebPushSubtitle =>
      'Vede přes veřejnou bránu UnifiedPush. Použijte, když proxy dělá potíže.';

  @override
  String get settingsPushTransportSwitchFailed =>
      'Přepnutí se nepovedlo. Platí dál původní registrace.';

  @override
  String get settingsDiagnosticsSection => 'Diagnostika';

  @override
  String get settingsOpenDiagnostics => 'Lokální diagnostika';

  @override
  String get settingsOpenDiagnosticsSubtitle => 'Lokální stav aktivního účtu';

  @override
  String get diagnosticsTitle => 'Lokální diagnostika';

  @override
  String get diagnosticsRefresh => 'Načíst znovu';

  @override
  String get diagnosticsLoadFailed => 'Lokální stav se nepodařilo načíst.';

  @override
  String get diagnosticsAppSection => 'Aplikace';

  @override
  String get diagnosticsLicenses => 'Licence otevřeného softwaru';

  @override
  String get diagnosticsLicensesSubtitle =>
      'Licence knihoven, ze kterých je aplikace složená';

  @override
  String get diagnosticsLicensesLegalese =>
      'NKS Talk je svobodný software pod licencí GNU GPL-3.0-or-later. Obsahuje UnifiedPush embedded FCM distributor (LGPL-2.1) jako součást tohoto GPL díla podle LGPL, oddíl 3. Úplný odpovídající zdrojový kód tohoto sestavení dostane každý příjemce na vyžádání od toho, kdo mu sestavení předal.';

  @override
  String get diagnosticsAppVersion => 'Verze';

  @override
  String get diagnosticsAppBuild => 'Sestavení';

  @override
  String get diagnosticsPlatform => 'Platforma';

  @override
  String get diagnosticsDatabaseSection => 'Databáze';

  @override
  String get diagnosticsSchemaVersion => 'Uložená verze schématu';

  @override
  String get diagnosticsExpectedSchemaVersion => 'Očekávaná verze schématu';

  @override
  String get diagnosticsMigrationState => 'Stav migrace';

  @override
  String get diagnosticsMigrationUpToDate => 'Aktuální';

  @override
  String get diagnosticsMigrationUpgradeRequired => 'Vyžaduje migraci';

  @override
  String get diagnosticsMigrationNewerThanApp => 'Novější než aplikace';

  @override
  String get diagnosticsForeignKeyViolations => 'Porušení cizích klíčů';

  @override
  String get diagnosticsConversationRows => 'Konverzace v cache';

  @override
  String get diagnosticsMessageRows => 'Zprávy v cache';

  @override
  String get diagnosticsThreadRows => 'Vlákna v cache';

  @override
  String get diagnosticsTextOutboxRows => 'Položky textového outboxu';

  @override
  String get diagnosticsAttachmentOutboxRows => 'Položky outboxu příloh';

  @override
  String get diagnosticsOutboxSection => 'Odchozí fronta';

  @override
  String get diagnosticsOutboxTextTitle => 'Textové zprávy';

  @override
  String get diagnosticsOutboxAttachmentsTitle => 'Přílohy';

  @override
  String get diagnosticsStalledAttachmentsSection => 'Nedokončené přílohy';

  @override
  String get diagnosticsStalledAttachmentsNone => 'Žádná nedokončená příloha';

  @override
  String get diagnosticsStalledAttachmentKindVoice => 'Hlasová zpráva';

  @override
  String get diagnosticsStalledAttachmentKindFile => 'Soubor';

  @override
  String get diagnosticsStalledAttachmentAttempts => 'Pokusů';

  @override
  String get diagnosticsStalledAttachmentAge => 'Stáří';

  @override
  String get diagnosticsStalledAttachmentCancel => 'Zrušit nahrávání';

  @override
  String get diagnosticsStalledAttachmentCancelTitle =>
      'Zrušit toto nahrávání?';

  @override
  String get diagnosticsStalledAttachmentCancelBody =>
      'Příloha se neodešle a její místní kopie se smaže. Vrátit to zpět nejde.';

  @override
  String get diagnosticsStalledAttachmentCancelConfirm => 'Zrušit nahrávání';

  @override
  String get diagnosticsStalledAttachmentCancelDismiss => 'Ponechat';

  @override
  String get diagnosticsStalledAttachmentCancelFailed =>
      'Nahrávání se nepodařilo zrušit.';

  @override
  String get diagnosticsStalledAttachmentLocked =>
      'Už předáno serveru, zrušit nelze';

  @override
  String get diagnosticsOutboxPending => 'Čeká';

  @override
  String get diagnosticsOutboxFailed => 'Selhalo';

  @override
  String get diagnosticsOutboxLastError => 'Poslední chyba';

  @override
  String get diagnosticsSyncSection => 'Synchronizace';

  @override
  String get diagnosticsSyncLastSuccess => 'Poslední úspěšná synchronizace';

  @override
  String get diagnosticsSyncLastError => 'Poslední chyba';

  @override
  String get diagnosticsPushSection => 'Registrace push';

  @override
  String get diagnosticsPushPhase => 'Fáze';

  @override
  String get diagnosticsPushGeneration => 'Generace';

  @override
  String get diagnosticsPushNextGeneration => 'Příští generace';

  @override
  String get diagnosticsPushPendingEvents => 'Události ve frontě';

  @override
  String get diagnosticsPushPlatformUnsupported =>
      'Na této platformě není k dispozici.';

  @override
  String diagnosticsPushReadFailed(String code) {
    return 'Nepodařilo se načíst ($code).';
  }

  @override
  String get diagnosticsCapabilitiesSection => 'Funkce Talku';

  @override
  String get diagnosticsTalkFeatureCount => 'Nahlášené featury';

  @override
  String get diagnosticsValueNone => 'Žádná';

  @override
  String get diagnosticsValueNever => 'Nikdy';

  @override
  String get diagnosticsValueYes => 'Ano';

  @override
  String get diagnosticsValueNo => 'Ne';

  @override
  String get profileTitle => 'Profil a stav';

  @override
  String get profileUserIdLabel => 'ID uživatele';

  @override
  String get profileEmailLabel => 'E-mail';

  @override
  String get profileServerLabel => 'Server';

  @override
  String get profileStatusSection => 'Dostupnost';

  @override
  String get profileStatusUnavailable =>
      'Server neuvádí podporu kompatibilního uživatelského stavu.';

  @override
  String get profileStatusOnline => 'Online';

  @override
  String get profileStatusAway => 'Pryč';

  @override
  String get profileStatusBusy => 'Zaneprázdněn';

  @override
  String get profileStatusDoNotDisturb => 'Nerušit';

  @override
  String get profileStatusInvisible => 'Neviditelný';

  @override
  String get profileStatusOffline => 'Offline';

  @override
  String get profileStatusIconLabel => 'Emoji stavu';

  @override
  String get profileStatusIconHelp =>
      'Použijte jedno emoji podporované serverem.';

  @override
  String get profileStatusMessageLabel => 'Zpráva stavu';

  @override
  String get profileStatusSave => 'Uložit stav';

  @override
  String get profileStatusClear => 'Smazat zprávu';

  @override
  String get profileStatusExpiryLabel => 'Vymazat stav';

  @override
  String get profileStatusExpiryNever => 'Nikdy';

  @override
  String get profileStatusExpiryHalfHour => 'Za 30 minut';

  @override
  String get profileStatusExpiryHour => 'Za hodinu';

  @override
  String get profileStatusExpiryFourHours => 'Za 4 hodiny';

  @override
  String get profileStatusExpiryToday => 'Dnes';

  @override
  String get profileStatusExpiryWeek => 'Tento týden';

  @override
  String get profileStatusSaved => 'Stav byl aktualizován.';

  @override
  String get profileErrorAccountMissing => 'Tento účet už není dostupný.';

  @override
  String get profileErrorReauth =>
      'Pro zobrazení nebo změnu profilu se přihlaste znovu.';

  @override
  String get profileErrorForbidden => 'Server tuto akci s profilem nepovolil.';

  @override
  String get profileErrorRateLimited =>
      'Příliš mnoho požadavků. Zkuste to za chvíli.';

  @override
  String get profileErrorUnavailable => 'Služba profilu je dočasně nedostupná.';

  @override
  String get profileErrorNetwork => 'Server je nedostupný.';

  @override
  String get profileErrorInvalidInput =>
      'Použijte nejvýše 80 znaků zprávy a jedno emoji stavu.';

  @override
  String get profileErrorInvalidResponse =>
      'Server poslal neočekávanou odpověď profilu.';

  @override
  String get conversationActionsTitle => 'Akce konverzace';

  @override
  String get conversationActionMarkUnread => 'Označit jako nepřečtené';

  @override
  String get conversationActionArchive => 'Archivovat konverzaci';

  @override
  String get conversationActionUnarchive => 'Zrušit archivaci konverzace';

  @override
  String get conversationFiltersLabel => 'Filtry konverzací';

  @override
  String get conversationFilterUnread => 'Nepřečtené';

  @override
  String get conversationFilterMentions => 'Zmínky';

  @override
  String get conversationFilterArchived => 'Archivované';

  @override
  String get conversationFilterNoResults => 'Žádné odpovídající konverzace';

  @override
  String get conversationFilterNoResultsBody =>
      'Změňte nebo zrušte filtr a zobrazí se další konverzace.';

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
  String searchMessagesInConversation(String conversation) {
    return 'Hledat v $conversation';
  }

  @override
  String get searchInConversation => 'Hledat v konverzaci';

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
  String get newConversationPublicNameDialogTitle =>
      'Pojmenujte veřejnou konverzaci';

  @override
  String get newConversationNameLabel => 'Název konverzace';

  @override
  String get newConversationCreate => 'Vytvořit';

  @override
  String get newConversationCreateGroupAction =>
      'Vytvořit skupinovou konverzaci';

  @override
  String get newConversationCreatePublicAction =>
      'Vytvořit veřejnou konverzaci';

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
  String get messageActionNoteToSelf => 'Poslat do Note to self';

  @override
  String get messageActionForward => 'Přeposlat';

  @override
  String get messageActionPrivateReply => 'Odpovědět soukromě';

  @override
  String get privateReplyTitle => 'Soukromá odpověď';

  @override
  String get privateReplyHint => 'Napište odpověď';

  @override
  String get privateReplyExplanation =>
      'Odpověď se odešle do soukromé konverzace s autorem, ne sem.';

  @override
  String get privateReplySend => 'Odeslat';

  @override
  String privateReplySent(String author) {
    return 'Odpověď odeslána do soukromé konverzace s $author';
  }

  @override
  String get privateReplyFailed => 'Soukromou odpověď se nepodařilo odeslat.';

  @override
  String get privateReplyUnsupported => 'Server soukromé odpovědi nepodporuje.';

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
  String get saveAttachment => 'Uložit přílohu';

  @override
  String get shareAttachment => 'Sdílet přílohu';

  @override
  String get attachmentSaved => 'Příloha byla uložena.';

  @override
  String get attachmentSaveFailed => 'Přílohu se nepodařilo uložit.';

  @override
  String get attachmentShareFailed => 'Přílohu se nepodařilo sdílet.';

  @override
  String get attachmentSaveCancelled => 'Ukládání bylo zrušeno.';

  @override
  String get attachmentDownloading => 'Stahuji přílohu…';

  @override
  String attachmentDownloadingPercent(Object percent) {
    return 'Stahuji přílohu… $percent %';
  }

  @override
  String get attachmentDownloadFailed => 'Přílohu se nepodařilo stáhnout.';

  @override
  String get attachmentReauthenticationRequired =>
      'Pro stažení přílohy se přihlaste znovu.';

  @override
  String get attachmentTooLarge => 'Tato příloha je pro export příliš velká.';

  @override
  String get attachmentInvalid => 'Tato příloha už není platná.';

  @override
  String get attachmentPermissionDenied =>
      'Vybrané umístění nedovoluje tento soubor uložit.';

  @override
  String get attachmentStorageFailed =>
      'Přílohu se nepodařilo zapsat do vybraného umístění.';

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
  String get attachmentGalleryDenied =>
      'Výběr obrázku vyžaduje přístup ke galerii. Povolte ho v nastavení systému a zkuste to znovu.';

  @override
  String get attachmentGalleryUnavailable =>
      'Knihovna fotek není na tomto zařízení dostupná.';

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
      'Účet byl z tohoto zařízení odebrán, ale server nepotvrdil odvolání aplikačního hesla. Aplikace to po připojení k serveru ještě nějakou dobu zkouší znovu; můžete ho také odvolat sami na serveru v Nastavení, Zabezpečení.';

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
  String get roomDetailsSipLabel => 'Telefonické a SIP připojení';

  @override
  String get roomDetailsSipDisabled => 'Vypnuto';

  @override
  String get roomDetailsSipWithPin => 'Zapnuto s osobním PINem';

  @override
  String get roomDetailsSipWithoutPin => 'Zapnuto bez PINu';

  @override
  String get roomDetailsSipDialogTitle => 'Telefonické a SIP připojení';

  @override
  String get roomDetailsSipNotConfigured =>
      'SIP připojení není na tomto serveru nakonfigurované.';

  @override
  String get roomDetailsSipDialInHeader => 'Údaje pro telefonické připojení';

  @override
  String get roomDetailsSipInstructionsLoadError =>
      'Pokyny pro telefonické připojení se nepodařilo načíst.';

  @override
  String get roomDetailsSipInstructionsUnavailable =>
      'Server neposkytl pokyny pro telefonické připojení.';

  @override
  String get roomDetailsSipMeetingId => 'ID schůzky';

  @override
  String get roomDetailsSipPersonalPin => 'Váš PIN';

  @override
  String get roomDetailsSipPinUnavailable => 'Server zatím váš PIN neposkytl.';

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
  String get roomDetailsAvatarColorLabel => 'Barva pozadí';

  @override
  String get roomDetailsAvatarColorDefault =>
      'Podle světlého nebo tmavého režimu';

  @override
  String get roomDetailsChatBackgroundAction => 'Pozadí zpráv';

  @override
  String roomDetailsAvatarColorSemantics(String color) {
    return 'Barva $color';
  }

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
  String get roomDetailsClearHistoryAction => 'Vymazat historii konverzace';

  @override
  String get roomDetailsClearHistoryDialogTitle =>
      'Vymazat historii konverzace?';

  @override
  String get roomDetailsClearHistoryDialogMessage =>
      'Tímto trvale smažete zprávy a vlákna všem v této konverzaci. Akci nelze vrátit zpět.';

  @override
  String get roomDetailsClearHistoryConfirm => 'Vymazat historii';

  @override
  String get roomDetailsClearHistorySucceeded =>
      'Historie konverzace byla vymazána.';

  @override
  String get roomDetailsClearHistoryExternalCopiesWarning =>
      'Historie konverzace zde byla vymazána. Externí služby mohou stále uchovávat kopie.';

  @override
  String get roomDetailsClearHistoryRefreshFailed =>
      'Historie konverzace byla vymazána, ale aktuální stav se zatím nepodařilo načíst. Pro obnovení konverzaci znovu otevřete.';

  @override
  String get roomDetailsConversationTagsAction => 'Štítky konverzace';

  @override
  String roomDetailsConversationTagsSelectedCount(int count) {
    return 'Vybráno: $count';
  }

  @override
  String get roomDetailsConversationTagsDialogTitle => 'Štítky konverzace';

  @override
  String get roomDetailsConversationTagsDialogHint =>
      'Vyberte štítky, podle kterých bude tato konverzace uspořádaná ve vašem účtu.';

  @override
  String get roomDetailsConversationTagsEmpty =>
      'Než zde štítek přiřadíte, vytvořte si vlastní štítek v Nextcloud Talk.';

  @override
  String get roomDetailsConversationTagsSave => 'Uložit štítky';

  @override
  String get roomDetailsConversationTagsSaved =>
      'Štítky konverzace byly aktualizovány.';

  @override
  String get roomDetailsConversationTagsUnsupported =>
      'Tento server už štítky konverzací nepodporuje.';

  @override
  String get roomDetailsAvatarPickImage => 'Vybrat obrázek';

  @override
  String get roomDetailsAvatarTypeRejected =>
      'Jako obrázek konverzace projde jen čtvercový PNG nebo JPEG.';

  @override
  String get roomDetailsAvatarTooLarge => 'Tento obrázek je příliš velký.';

  @override
  String get roomDetailsAvatarRejected => 'Server tento obrázek nepřijal.';

  @override
  String get messageActionPin => 'Připnout zprávu';

  @override
  String get messageActionUnpin => 'Odepnout zprávu';

  @override
  String get messagePinned => 'Zpráva připnuta';

  @override
  String get messageUnpinned => 'Zpráva odepnuta';

  @override
  String get pinnedMessageLabel => 'Připnutá zpráva';

  @override
  String get pinnedMessageOpen => 'Zobrazit připnutou zprávu';

  @override
  String get pinnedMessageHide => 'Skrýt pro mě';

  @override
  String get messageActionRemind => 'Připomenout';

  @override
  String get reminderTitle => 'Připomenout tuto zprávu';

  @override
  String get reminderLaterToday => 'Dnes večer';

  @override
  String get reminderTomorrow => 'Zítra ráno';

  @override
  String get reminderThisWeekend => 'O víkendu';

  @override
  String get reminderNextWeek => 'Příští týden';

  @override
  String get reminderCustom => 'Vybrat datum a čas';

  @override
  String get reminderRemove => 'Zrušit připomenutí';

  @override
  String reminderSet(String time) {
    return 'Připomenutí nastaveno na $time';
  }

  @override
  String get reminderRemoved => 'Připomenutí zrušeno';

  @override
  String reminderExisting(String time) {
    return 'Připomenutí nastaveno na $time';
  }

  @override
  String get scheduleMessage => 'Odeslat později';

  @override
  String get scheduleMessageTitle => 'Odeslat tuto zprávu později';

  @override
  String scheduleMessageSet(String time) {
    return 'Zpráva naplánována na $time';
  }

  @override
  String get scheduledMessagesTitle => 'Naplánované zprávy';

  @override
  String get scheduledMessagesOpen => 'Naplánované zprávy';

  @override
  String get scheduledMessagesEmpty =>
      'V této konverzaci není nic naplánováno.';

  @override
  String get scheduledMessageDelete => 'Smazat naplánovanou zprávu';

  @override
  String get scheduledMessageDeleted => 'Naplánovaná zpráva smazána';

  @override
  String get scheduleTimeInPast => 'Vyberte čas v budoucnosti.';

  @override
  String get roomDetailsSharedItemsAction => 'Sdílené položky';

  @override
  String get sharedItemsTitle => 'Sdílené položky';

  @override
  String get sharedItemsEmpty => 'V této kategorii zatím není nic sdíleného.';

  @override
  String get sharedItemsLoadMore => 'Načíst další';

  @override
  String get sharedItemsCategoryAudio => 'Zvuk';

  @override
  String get sharedItemsCategoryDeckCards => 'Karty Deck';

  @override
  String get sharedItemsCategoryFiles => 'Soubory';

  @override
  String get sharedItemsCategoryLocations => 'Polohy';

  @override
  String get sharedItemsCategoryMedia => 'Média';

  @override
  String get sharedItemsCategoryOther => 'Ostatní';

  @override
  String get sharedItemsCategoryPinned => 'Připnuté';

  @override
  String get sharedItemsCategoryPolls => 'Ankety';

  @override
  String get sharedItemsCategoryRecordings => 'Nahrávky';

  @override
  String get sharedItemsCategoryVoice => 'Hlasové zprávy';

  @override
  String get sharedItemsUnsupported =>
      'Sdílené položky nejsou pro tuto konverzaci dostupné.';

  @override
  String get sharedItemsLobbyRestricted =>
      'Sdílené položky jsou skryté, dokud čekáte v předsálí.';

  @override
  String get sharedItemsInvalidResponse =>
      'Server poslal neplatnou odpověď sdílených položek.';

  @override
  String get messageActionTranslate => 'Přeložit';

  @override
  String get translationTitle => 'Přeložit zprávu';

  @override
  String get translationFrom => 'Přeložit z';

  @override
  String get translationTo => 'Přeložit do';

  @override
  String get translationDetectLanguage => 'Rozpoznat jazyk';

  @override
  String get translationAction => 'Přeložit';

  @override
  String get translationAiNotice =>
      'Překlad vytvořila AI a může obsahovat chyby.';

  @override
  String get translationCopy => 'Zkopírovat přeložený text';

  @override
  String get translationCopied => 'Překlad zkopírován do schránky';

  @override
  String get translationCopyFailed => 'Překlad se nepodařilo zkopírovat.';

  @override
  String get translationUnavailable =>
      'Překlad zpráv není na tomto serveru dostupný.';

  @override
  String get translationInvalidInput =>
      'Tuto zprávu nebo zvolenou kombinaci jazyků nelze přeložit.';

  @override
  String get translationInvalidResponse =>
      'Server poslal neplatnou odpověď překladu.';

  @override
  String get pollCreateTitle => 'Vytvořit anketu';

  @override
  String get pollCreated => 'Anketa vytvořena';

  @override
  String get pollCreateAction => 'Vytvořit';

  @override
  String get pollVoteAction => 'Hlasovat';

  @override
  String get pollQuestion => 'Otázka';

  @override
  String get pollQuestionRequired => 'Zadejte otázku.';

  @override
  String pollOption(int number) {
    return 'Možnost $number';
  }

  @override
  String get pollOptionRequired => 'Zadejte možnost.';

  @override
  String get pollAddOption => 'Přidat možnost';

  @override
  String get pollRemoveOption => 'Odebrat možnost';

  @override
  String get pollMultipleAnswers => 'Povolit více odpovědí';

  @override
  String get pollHiddenResults => 'Skrýt výsledky do ukončení ankety';

  @override
  String get pollSelectOption => 'Vyberte alespoň jednu možnost.';

  @override
  String get pollUnsupported => 'Ankety nejsou v této konverzaci dostupné.';

  @override
  String get pollPermissionDenied =>
      'V této anketě nemůžete vytvářet ani hlasovat.';

  @override
  String get pollRateLimited =>
      'Příliš mnoho požadavků na anketu. Zkuste to později.';

  @override
  String get pollAmbiguous =>
      'Server mohl akci přijmout. Před dalším pokusem obnovte konverzaci.';

  @override
  String get pollFailed => 'Akce s anketou se nezdařila.';

  @override
  String get pollSignInAgain => 'Přihlaste tento účet znovu.';

  @override
  String get pollMenuAction => 'Anketa';

  @override
  String get pollChecking => 'Ověřuji podporu anket';

  @override
  String get pollLoading => 'Načítám anketu';

  @override
  String get pollReloadAction => 'Zkusit znovu';

  @override
  String pollOpenAction(String name) {
    return 'Otevřít anketu $name';
  }

  @override
  String typingOne(String name) {
    return '$name píše…';
  }

  @override
  String typingTwo(String first, String second) {
    return '$first a $second píší…';
  }

  @override
  String typingThree(String first, String second, String third) {
    return '$first, $second a $third píší…';
  }

  @override
  String typingOneOther(String first, String second, String third) {
    return '$first, $second, $third a další píší…';
  }

  @override
  String typingOthers(String first, String second, String third, int count) {
    return '$first, $second, $third a $count dalších píší…';
  }

  @override
  String get certificateUnverifiedTitle => 'Neověřený certifikát serveru';

  @override
  String certificateUnverifiedBody(String host) {
    return 'Server $host předložil certifikát, který zařízení neumí ověřit. Pokračujte jen tehdy, když otisk níže odpovídá tomu, co ukazuje váš server.';
  }

  @override
  String get certificateFingerprintLabel => 'Otisk SHA-256';

  @override
  String get certificateTrustAction => 'Důvěřovat a pokračovat';

  @override
  String get certificateChangedTitle => 'Certifikát serveru se změnil';

  @override
  String certificateChangedBody(String host) {
    return 'Server $host nyní předkládá jiný certifikát, než kterému tento účet důvěřuje. Pokud jste certifikát vyměnili vy, účet odeberte a přidejte znovu.';
  }

  @override
  String get attachFromServer => 'Soubor z Nextcloudu';

  @override
  String get remoteFilesTitle => 'Soubory';

  @override
  String get remoteFilesEmpty => 'Tato složka je prázdná.';

  @override
  String remoteFilesTruncated(int count) {
    return 'Zobrazeno prvních $count položek této složky.';
  }

  @override
  String get remoteFilesLoadFailed => 'Složku se nepodařilo načíst.';

  @override
  String get remoteFilesSignInAgain => 'Tento účet je potřeba znovu přihlásit.';

  @override
  String get remoteFilesShareTitle => 'Sdílet soubor do konverzace?';

  @override
  String remoteFilesShareBody(String name) {
    return 'Soubor $name zůstane na vašem serveru. Všichni v této konverzaci k němu získají přístup, dokud sdílení nezrušíte v Souborech.';
  }

  @override
  String get remoteFilesShareAction => 'Sdílet';

  @override
  String get remoteFilesShared => 'Soubor byl sdílen do konverzace.';

  @override
  String get remoteFilesShareFailed => 'Soubor se nepodařilo sdílet.';

  @override
  String get remoteFilesShareForbidden =>
      'Tento účet tady ten soubor sdílet nemůže.';

  @override
  String get openConversations => 'Otevřené konverzace';

  @override
  String get openConversationsEmpty =>
      'Tento server žádné otevřené konverzace nenabízí.';

  @override
  String get openConversationsJoin => 'Připojit se';

  @override
  String federationInvitationsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count pozvánek do konverzací na jiných serverech',
      few: '$count pozvánky do konverzací na jiných serverech',
      one: '1 pozvánka do konverzace na jiném serveru',
    );
    return '$_temp0';
  }

  @override
  String get federationInvitationsShow => 'Zobrazit';

  @override
  String get federationInvitationsTitle => 'Federované pozvánky';

  @override
  String get federationInvitationsEmpty => 'Žádné čekající pozvánky.';

  @override
  String federationInvitationFrom(String inviter, String server) {
    return 'Od $inviter na $server';
  }

  @override
  String get federationInvitationAccept => 'Přijmout';

  @override
  String get federationInvitationDecline => 'Odmítnout';

  @override
  String get federationInvitationAccepted =>
      'Pozvánka přijata. Konverzace je teď v seznamu.';

  @override
  String get federationInvitationDeclined => 'Pozvánka odmítnuta.';

  @override
  String get federationInvitationGone => 'Tato pozvánka už není k dispozici.';

  @override
  String get federationInvitationFailed =>
      'Pozvánku se nepodařilo zpracovat. Zkuste to později.';

  @override
  String get openConversationsPasswordTitle => 'Konverzace má heslo';

  @override
  String get openConversationsPasswordLabel => 'Heslo konverzace';

  @override
  String get openConversationsJoined => 'Připojili jste se ke konverzaci.';

  @override
  String get newConversationErrorUnavailable =>
      'Tato konverzace už není otevřená.';

  @override
  String get newConversationErrorPasswordRequired =>
      'Heslo konverzace nesouhlasí.';
}
