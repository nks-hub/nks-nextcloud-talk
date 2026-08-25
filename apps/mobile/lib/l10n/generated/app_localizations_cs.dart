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
  String get preparingImage => 'Připravuji obrázek…';

  @override
  String get imageUploadQueued => 'Čeká na nahrání';

  @override
  String uploadingImage(int percent) {
    return 'Nahrávám obrázek… $percent %';
  }

  @override
  String get confirmingAttachment => 'Potvrzuji přílohu…';

  @override
  String get cancellingUpload => 'Ruším nahrávání…';

  @override
  String get imageSent => 'Obrázek byl odeslán';

  @override
  String get imageUploadFailed => 'Obrázek se nepodařilo odeslat.';

  @override
  String get imageUploadFailedQuota =>
      'Obrázek se nepodařilo odeslat: úložiště je zaplněné.';

  @override
  String get imageUploadFailedPermission =>
      'Obrázek se nepodařilo odeslat: nemáte oprávnění sem nahrávat soubory.';

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
}
