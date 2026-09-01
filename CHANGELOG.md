# Changelog

Vydání, která se dostala k testerům. Čísla v závorce jsou build number, tedy
`versionCode` na Androidu a `CFBundleVersion` na Apple platformách; obě strany
drží stejné číslo, aby se hlášení od testerů daly spárovat napříč platformami.

Zdrojem pravdy o verzi je `apps/mobile/pubspec.yaml`; `apps/mobile/lib/core/app_version.dart`
ji zrcadlí a test hlídá, aby se ty dvě nerozešly.

Buildy 17 až 19 tag nemají, a mít ho nebudou: na Play je nahradil build 20
ještě před schválením a na TestFlight se vůbec nedostaly. Tag drží jen to,
co se opravdu dostalo k testerům.

Buildy 1 a 3 vznikly ještě před uzavřeným testováním na Play a šly jen na
TestFlight. Jejich obsah se nedá rozepsat po položkách: v té době se číslo
buildu nezvedalo commitem, takže k nim nevede hranice v historii. Uvedené je
proto jen to, co je doložitelné z App Store Connect.

## 0.1.0 (38) — 1. 9. 2026

Vydáno ze zdroje `7c8e2fb8e5b2e0209d589669c79515cd7564e6ac`.

Play (uzavřené testování, track alpha): vydání `(38) 0.1.0` je `completed`
s version code 38 a je jediné na tracku. AAB má 83 989 490 B a SHA-256
`ad435dce6e0db02f376d8ed3cd044da1d3b81a4023f37056928a7c99e446d6a8`, je
podepsané upload klíčem `CN=NKS Talk` a `jarsigner` hlásí `jar verified`.
Poznámky ve všech šesti jazycích se po nahrání znak po znaku shodují se
zdrojovým souborem.

TestFlight: IPA má 30 167 493 B a SHA-256
`0729aeb954ed92d301d340bc665ee7ea5032999db01a16345ded03f2d18f60af`. Delivery
UUID i App Store Connect build record jsou
`ec28eef5-d5d4-4d34-9e71-b09185b685a6`. App Store Connect vrací `VALID`,
minimum iOS 15.0, encryption `false` a české poznámky. Obě skupiny jsou
`IN_BETA_TESTING`; beta review bylo odesláno a v době zápisu čeká.

Sada `apps/mobile` skončila 1635 prošlo a 4 přeskočeno. Dvě selhání
(`ios_app_icon_metadata`, `macos_push_capability`) jsou starší a padají i na
čistém základu, protože v čerstvém worktree chybí `Podfile.lock`.

- Přihlašovací pole začíná na `https://` a rozumí adrese vložené ze schránky.
  Odkaz zkopírovaný z prohlížeče se zbaví parametrů i kotvy a zkrátí se na
  adresu serveru, takže `.../index.php/apps/spreed/` už neskončí chybou.
  Podadresář instalace zůstává zachovaný a vložené `http://` se tiše nemění
  na zabezpečené.
- Výběr GIFů hledá při psaní. Rychlé psaní pošle jeden dotaz místo jednoho na
  každou klávesu, vymazání pole se vrátí k doporučeným.
- Nastavení → Diagnostika ukazuje nedokončené přílohy: typ, fázi, stáří
  a rozsah pokusů, nic víc. Zrušit jde jen to, co zrušit skutečně lze;
  příloha už předaná serveru má místo tlačítka zámek, aby se nepředstíralo,
  že se neodeslala.
- Bublina odesílané zprávy je nižší a vypadá jako běžná odchozí zpráva místo
  samostatné karty. Stav, opakování i zrušení zůstaly.
- Náhledová karta odkazu má čitelnou hierarchii: nejdřív titulek, pod ním
  zdroj, až potom popis. Odkaz s náhledem i bez něj drží stejný tvar.

## 0.1.0 (37) — 1. 9. 2026

Vydáno ze zdroje `0a388e63263d8e9aa47cd75652611cd37235b324`.

Play (uzavřené testování, track alpha): vydání `(37) 0.1.0` je `completed`
s version code 37. AAB má 83 952 784 B a SHA-256
`8c969f7d4c8369ab1b4458a92ef2495b1ea7a1df6d889f1443aa954eb1b65566`, je
podepsané upload klíčem `CN=NKS Talk` a `jarsigner` hlásí `jar verified`.
Poznámky k vydání ve všech šesti jazycích se po nahrání znak po znaku shodují
se zdrojovým souborem. V balíčku jsou nastavené hostitele Sentry i Rybbit.

TestFlight: IPA má 30 166 266 B a SHA-256
`f33f82aedc252f61ff055c4466f0b7a11872622d8511b4c96667c35340fd4cbc`. Delivery
UUID i App Store Connect build record jsou
`aebb5664-02d5-4c24-b0c0-5e6458d865e8`. App Store Connect vrací `VALID`,
minimum iOS 15.0, encryption `false` a české poznámky. Skupina Testeři je
`IN_BETA_TESTING`; Externí testeři byli odesláni do beta review, které v době
zápisu čeká na vyřízení.

- Příloha, kterou pořadí v místnosti drží zpátky, už nezastaví celou frontu.
  Dřív stačila jedna starší úloha čekající na potvrzení a každý další obrázek
  ve stejné konverzaci zůstal navždy na „Čeká na nahrání“, bez chyby a bez
  možnosti to rozjet. Odmítnutý plán teď znamená jen přeskočení té jedné
  úlohy; zaparkované potvrzení navíc nebrání finalizaci pozdějších příloh,
  protože samo se pohne až na výslovné zopakování. Nevyřízené přílohy se
  dotáhnou samy, i po restartu aplikace.
- Background síťové úlohy už při zániku vlastníka nezůstávají bez dozoru.
  Client Push ruší capability request, připojování, handshake, event stream i
  backoff; pozdě připojený socket zavře a při více účtech signalizuje zrušení
  všem současně. Veřejná hranice synchronizace konverzací převádí transportní
  chyby na typed sync stav a zachovává force-full retry po selhání slabšího
  incremental flightu.
- Watchdog telemetrie výslovně zapíná AppHang 2 s, native breadcrumbs a scope
  sync. Předchozí běh ukládá jen čtyři privacy-safe tagy: typ běhu, lifecycle,
  RSS bucket a zaznamenaný memory pressure. Release gate po vyčištění scope
  tyto tagy znovu přidá a test kontroluje skutečný výsledný Sentry event.
- Audit historických Sentry skupin odlišil syntetické release brány od reálných
  pádů. `NKS-TALK-2` z buildu 1 se na původním ani současném layoutu nepodařilo
  reprodukovat, proto nevznikla spekulativní oprava. Reálný `NKS-TALK-P`
  z buildu 36 — fyzický iPhone ve fázi `localPrepared` bez jediného pokusu
  i bez credential retry — opravuje první bod tohoto vydání. Chyba nebyla
  v Apple Keychainu: nulový počet credential retry a chybějící událost
  o nedostupném přihlášení dokazují, že se běh k přihlašovacím údajům vůbec
  nedostal. Zbývá průchod na fyzickém zařízení s tímto buildem.

## 0.1.0 (36) — 1. 9. 2026

Play: build 36 nebyl v této prioritní iOS opravě vydán.
TestFlight: Apple ContentDelivery přijal právě jednu IPA o velikosti
30 149 946 B, ověřil její MD5
`AD2E839D201A6A640A17D50CDFDA9357` a dokončil upload bez chyby. Delivery UUID
i App Store Connect build record jsou
`<provisioning-profile-uuid>`. App Store Connect vrací `VALID`,
minimum iOS 15.0, encryption `false`, české poznámky odpovídající tomuto
changelogu, interní i externí skupinu `IN_BETA_TESTING` a beta review
`APPROVED`.

Původní lokální IPA byla po úspěšném uploadu omylem odstraněná automaticky
opakovaným release jobem, proto její SHA-256 není poctivě doložitelný.
Opakovaný export měl jinou velikost i MD5 a jeho SHA se za distribuovaný
artefakt nevydává. Distribuční source je přesný commit `9edf7c6` se stejným
tree jako `da84214`; git archive měl 13 086 720 B a SHA-256
`5266F1494A636BCADD51321F36F288D0CCA482F93A7D3CDBAC8215B6938E93BB`.
Flutter testy skončily 95/95 a protokolové attachment testy 30/30. Store build
obsahuje čtyři běžné production telemetry hodnoty, ale syntetický release gate
je vypnutý, takže testeři nevytvářejí ověřovací eventy při každém startu.
Po vydání se odstranilo přibližně 1,68 GiB přesně vymezeného build, archive,
export, DerivedData a dočasného obsahu; čistý source, simulátorová data,
nainstalovaný simulátorový build 36 a signing zůstaly.

- iOS upload už po úspěšném přijetí přílohy nezůstane navždy ve fázi
  `localPrepared`, když druhé čtení Apple Keychainu dočasně vrátí `-25320`
  nebo `-60008`. Scheduler chybu zachytí, zopakuje čtení po 2 s, 10 s a 60 s
  a při trvalém selhání ukáže reautentizaci místo nekonečného čekání. Stejný
  tok respektuje zrušení účtu, zavření služby, FIFO i existující retry timer.
- Sentry má povinnou release bránu pro aplikační chybu i strukturovaná
  attachment data. Android 14 release a iOS 18.6 Simulator build 36 odeslaly
  oba eventy pod `production` a `dist=36`; attachment payload neobsahoval user,
  request ani breadcrumbs. Všechna dříve otevřená NKS Talk issue byla po
  přiřazení fixu a ověření uzavřená; v okamžiku release gate vracel dotaz
  `is:unresolved` prázdný seznam. Pozdější `NKS-TALK-P` je popsán v Nevydáno.
- Skutečný iOS 18.6 PHPicker upload buildu 36 prošel od výběru JPEG přes
  app-owned kopii, WebDAV a Talk finalize až k jedné autoritativně potvrzené
  serverové zprávě. Zdroj se uvolnil, job neměl chybu a testovací zpráva byla
  po důkazu smazaná.

## 0.1.0 (35) — 1. 9. 2026

Play: build 35 nebyl v této prioritní iOS opravě vydán.
TestFlight: IPA má 30 151 224 B a SHA-256
`35C44CAC2C468D28725069626A375B81E13F45C270D3CBBE3A5F827F05843A1E`.
App Store Connect vrací build record
`f9f729fa-e50b-4733-b4ef-ae706db5b10a` ve stavu `VALID`, minimum iOS 15.0,
encryption `false`, přesné české poznámky a interní i externí skupinu
`IN_BETA_TESTING`; beta review je `APPROVED`.

Čistý build-mac source na `e9b52fe` prošel 75/75 zaměřenými testy a analyze bez
nálezu. Distribuční artefakt má platnou Sentry konfiguraci v prostředí
`production`. Po buildu se odstranilo přibližně 1,62 GiB archive, export,
DerivedData, Pods a dočasných dat; simulátorová data a signing zůstaly.

- Build 35 opravil blokaci nového uploadu starším automatickým retry a přidal
  fázovou diagnostiku. Následný fyzický test ale doložil druhou nezávislou
  chybu: dočasně odmítnuté druhé Keychain čtení ukončilo scheduler future a
  příloha přesto zůstala na „Čeká na nahrání“. Tento build proto není finální
  oprava iOS galerie; úplná oprava je až v následujícím řezu.
- V detailu konverzace mohou vlastníci a moderátoři na serveru s `bots-v1`
  zobrazit dostupné boty a zapínat nebo vypínat je. Seznam se načte až po
  otevření sekce, umí prázdný/chybový stav a znovu ověřuje aktuální oprávnění
  před každou změnou.
- Když Apple Keychain během uspání nebo dark wake dočasně odmítne přístup,
  aplikace už tuto situaci nehlásí jako pád ani jako chybějící heslo. Uložený
  účet zůstane nedotčený a synchronizace i push registrace se bezpečně zopakují;
  pozdní pokus po odebrání účtu jej nemůže znovu zaregistrovat.

## 0.1.0 (34) — 1. 9. 2026

Play: AAB se zapnutým Sentry i Rybbit má 83 485 780 B a SHA-256
`<fingerprint>`.
Publishing API jej nahrálo a commitnulo do uzavřeného `alpha` tracku; nový
edit vrací `(34) 0.1.0` ve stavu `completed` a šest skutečně přeložených sad
poznámek.
TestFlight: IPA má 30 024 771 B a SHA-256
`<fingerprint>`.
App Store Connect vrací `VALID`, minimum iOS 15.0, encryption `false`, české
poznámky a interní i externí skupinu `IN_BETA_TESTING`; beta review je
`APPROVED`.

Android 14 release build aktualizačně zachoval účet a živě prošel app lock,
cold i warm Direct Share textu, References restartem v light/dark a opraveným
composerem. iOS 18.6 update install zachoval účet; sponka je na x=12 samostatně
vlevo a Giphy, emoji, mikrofon a Odeslat jsou vpravo na x=240/288/336/384.
Podepsané native XCTest skončily 27/27.

- Akční řádek pod psacím polem má vlevo samotnou sponku. Giphy, emoji,
  mikrofon a Odeslat jsou znovu seskupené vpravo v původním pořadí; rozložení
  zůstává stejné i během načítání a po chybě hlasové zprávy.
- Na Androidu lze do NKS Talk sdílet text nebo jeden soubor z jiné aplikace.
  Po cold i warm startu se vybere přesný účet a konverzace; soubor se nejdřív
  bezpečně zkopíruje do úložiště aplikace a opakované systémové doručení jej
  neodešle podruhé.
- Běžné HTTPS odkazy ve zprávách se na serveru s References API zobrazí jako
  OpenGraph karta. Neznámý provider má bezpečný obecný náhled; při chybě zůstane
  původní inline odkaz a klepnutí nikdy nepoužije serverem podvržený cíl.
- Do otevřené konverzace na Windows, macOS a Linuxu lze přetáhnout jeden
  soubor. Adresář, více souborů nebo příliš velký vstup se odmítne; přijatý
  soubor se okamžitě bezpečně zkopíruje a pokračuje stejným uploadem jako sponka.
- V nastavení na Androidu a iOS lze zapnout zámek aplikace. Účty a zprávy se po
  startu nebo návratu z pozadí nezobrazí, dokud systém nepotvrdí biometrii nebo
  kód zařízení; zrušení a chyba nechají aplikaci zamčenou s možností opakování.

## 0.1.0 (33) — 1. 9. 2026

Play: AAB se zapnutým Sentry i Rybbit má 82 500 756 B a SHA-256
`5239FEBE8009AFA24945F873148401F24152A3708913A2E58E3AB936A177DE38`.
Publishing API jej nahrálo a commitnulo do uzavřeného `alpha` tracku; nový
edit vrací `(33) 0.1.0` ve stavu `completed` a šest skutečně přeložených sad
poznámek.
TestFlight: IPA má 29 783 651 B a SHA-256
`8D5E5C68F34ECC399262E4E0578598A9D3454E1377DBEC8A7CE93D75FE6E9DC2`.
App Store Connect vrací `VALID`, minimum iOS 15.0, encryption `false`, české
poznámky a interní i externí skupinu `IN_BETA_TESTING`; beta review je
`APPROVED`.

Android release APK se aktualizačně nainstalovalo na Android 14 se zachovaným
účtem. Cold start otevřel přihlášený seznam konverzací, proces zůstal živý a
jeho log neměl FATAL, ANR ani neošetřenou výjimku.

- Ze sponky lze vybrat kontakt ze systémového adresáře a odeslat jej jako
  standardní vCard přílohu. Android ani iOS nepožadují plošný přístup ke
  kontaktům; uživatel vybírá právě jednu kartu. Fotografie se z exportu
  odstraní, velikost je omezená na 2 MiB a příloha používá stejný bezpečný
  upload jako ostatní soubory.
- Call lifecycle před každou serverovou mutací aktivuje přesnou Talk room
  session a přenese její cookie pouze v rámci daného účtu. Skutečný hovor
  spuštěný z webové Talk session se na iOS zobrazil v živém banneru a po
  ukončení zase zmizel. WebRTC média a tlačítko připojení zůstávají vypnuté.
- Podpora iOS Universal Links pro referenční Nextcloud host je připravená.
  Jeden HTTPS/no-userinfo validator zachovává pořadí cold/warm odkazů.
  Server už publikuje verzovaný AASA dokument pro `/call/*` a
  `/index.php/call/*` bez redirectu. Produkční Apple CDN vrací stejný dokument
  a iOS 18.6 otevřel HTTPS odkaz přímo ve správné místnosti bez Safari.
- České iOS systémové oprávnění k poloze už nemíchá anglický purpose string.
  Build 33 obsahuje samostatný český a anglický `InfoPlist.strings` a živý
  iOS 18.6 dialog ukázal správnou českou větu.
- Android release licenční brána teď sleduje i přesné Maven souřadnice a obsah
  skutečného runtime graphu. Změna závislosti proto znovu vygeneruje SBOM a
  notice místo použití starého cache výstupu; build 33 pokrývá také
  `play-services-location` přivedené produkčním geolokačním pluginem.

## 0.1.0 (32) — 1. 9. 2026

Play: AAB se zapnutým Sentry i Rybbit má 82 411 005 B a SHA-256
`9E9A7A6B1558777F8E7070E3641AFBC4AED393A1DF0823A66CB44019B1845C02`.
Publishing API jej nahrálo a commitnulo do uzavřeného `alpha` tracku; nový
edit vrací `(32) 0.1.0` ve stavu `completed` a šest skutečně přeložených sad
poznámek.
TestFlight: IPA má 29 760 109 B a SHA-256
`<fingerprint>`.
App Store Connect vrací `VALID`, minimum iOS 15.0, encryption `false`, české
poznámky a interní i externí skupinu `IN_BETA_TESTING`; beta review je
`APPROVED`.

Android release APK se nainstalovalo přes `adb install -r` se zachovaným
účtem. Živě potvrdilo toolbar od levého okraje, Anketu ve sponce podporované
místnosti a tři stejná vlákna po dvou dalších refresh cyklech. Stejný commit
na zachovaném iOS 18.6 simulátoru potvrdil pořadí toolbaru, Anketu, skutečný
conversation-list underlay při edge swipe a stabilní trojici vláken po dvou
pull-refresh gestech.

- Akce pod psacím řádkem začínají od levého okraje v pořadí sponka, Giphy,
  emoji, mikrofon a Odeslat. Stejné zarovnání platí i během načítání a po chybě.
- Obyčejná vlákna odvozená z odpovědí už při opakovaném obnovení seznamu
  střídavě nemizí. Refresh znovu označí lokálně odvozený řádek jako recent a
  zachová jeho odběr, detail i úroveň oznámení; serverový pojmenovaný řádek
  lokální projekce nepřepíše.
- Otevřená nabídka sponky reaguje na dokončení kontroly capability. Anketa se
  objeví bez zavření a nového otevření nabídky; po chybě kontroly zmizí pouze
  stav načítání a nepodporovaná akce zůstane skrytá.
- iOS swipe zpět z hlavní konverzace používá skutečnou route nad živým
  cachovaným seznamem. Interaktivní náhled proto ukazuje reálné konverzace
  stejně jako návrat z detailu vlákna. Z podřízeného detailu první krok zpět
  vrátí hlavní konverzaci a teprve druhý seznam; Android systémové zpět se
  nemění.
- Typing protistrany v 1:1 konverzaci znovu funguje. Klient před HPB připojením
  aktivuje Talk room, použije vrácené nenulové session ID a drží session cookie
  pouze v paměti konkrétního účtu. Cookies se nesdílejí ani mezi dvěma účty na
  stejném serveru. Serializovaný lease brání starému cleanupu zrušit novější
  session; deaktivace, 401, zavření API i odebrání účtu ukončí pouze vlastní
  generaci. Account removal atomicky zavře admission, serverovou session i HPB
  lane před revokací credentials; opožděná aktivace ji nemůže znovu otevřít.

## 0.1.0 (31) — 1. 9. 2026

Play: AAB se zapnutým Sentry i Rybbit má 82 281 069 B a SHA-256
`011F43C5C9A8C187510E87A8B03DD3F801F23EEF8BE1F9F5EF3196BD34E9882A`.
Publishing API jej nahrálo a commitnulo do uzavřeného `alpha` tracku; nový
edit vrací `(31) 0.1.0` ve stavu `completed`.
TestFlight: IPA má 29 724 195 B a SHA-256
`<fingerprint>`.
App Store Connect vrací `VALID`, minimum iOS 15.0, encryption `false`, české
poznámky a interní i externí skupinu `IN_BETA_TESTING`; beta review je
`APPROVED`.

Na zachovaném iPhone 16 Pro Max / iOS 18.6 prošla aktualizační instalace ze
stejného commitu. Reálná fotografie z PHPickeru skončila `completed` i se
starším vyčerpaným `retryable` jobem bez časovače ve stejné místnosti. Starý
job zůstal zachovaný, nový zdroj se uvolnil a server přes autentizovaný
context request potvrdil přesný message ID i název souboru. Testovací zprávy,
fixture i lokální záloha byly po důkazu odstraněné.

- Secure Storage má vlastní verzované migrace oddělené od schématu databáze.
  Přerušený přesun credentialů se bezpečně obnoví, konfliktní kopie a neznámá
  novější verze selžou bez smazání app passwordu.
- Desktopové nastavení nabízí automatické spuštění po přihlášení. Windows
  používá uživatelský `HKCU Run`, macOS 13+ `SMAppService` a Linux XDG
  Autostart; klient po změně znovu ověří skutečný systémový stav.
- Odebrání účtu nejdřív zastaví jeho root i thread long polly, upload requesty
  a retry timery. Pozdní odpověď po logoutu už nemůže zapsat stav ani znovu
  spustit upload a ostatní účty zůstávají aktivní.
- Nové vzdálené zprávy v právě otevřené konverzaci se předávají odečítači
  obrazovky. Historie, vlastní outbox, systémové a reaction zprávy se
  neoznamují a více rychlých příchodů se sloučí do jednoho krátkého oznámení.
- V detailu konverzace lze nastavit vlastní barvu pozadí zpráv nebo se vrátit
  k motivu aplikace. Volba je oddělená podle účtu a místnosti, platí i ve
  vláknech a kontrastní brána ji podle světlého, tmavého i serverového motivu
  zeslabí tak, aby texty a oddělovače zůstaly čitelné.
- Starý upload, který po vyčerpání automatických pokusů čeká na ruční řešení,
  už neblokuje nově vybranou fotografii ve stejné konverzaci. Novější příloha
  může projít uploadem i finalize; původní job a jeho soubor zůstanou zachované
  pro ruční opakování nebo úklid.

## 0.1.0 (30) — 31. 8. 2026

Play: AAB se zapnutým Sentry i Rybbit byl přes Publishing API nahrán a
commitnut do uzavřeného alpha tracku; track vrací build 30 ve stavu
`completed`.
TestFlight: build je `VALID`, bez non-exempt encryption, od iOS 15.0 a v
interní i externí skupině `IN_BETA_TESTING`; beta review je `APPROVED`.
Předchozí iOS build 29 byl po nalezení poll rendereru expirován a odebrán z
obou skupin, na Play nahrán nebyl.

- Barevný accent aplikace se řídí motivem právě vybraného Nextcloud účtu.
  Barva je ověřená z autentizovaných capabilities, ukládá se odděleně pro
  každý účet a při přepnutí účtu se změní bez sdílení stavu mezi servery.
- Psací řádek má sponku jako první akci, vedle ní Giphy a emoji. Mikrofon je
  přímo před Odeslat a duplicitní rychlé obrázkové tlačítko s `+` bylo
  odstraněno; galerie zůstává ve sponce.
- Na podporovaném serveru lze ze sponky vytvořit anketu, zvolit jednu nebo více
  odpovědí a hned hlasovat. Klient váže mutace na aktuální účet, místnost a
  vlákno a při nejasné odpovědi je slepě neopakuje.
- Sdílená poloha ukazuje přímo ve zprávě lokální náhled se značkou. Živé
  dlaždice OpenStreetMap načte až po výslovném klepnutí; používá pouze ověřené
  souřadnice a ignoruje serverem dodaný odkaz.
- Když systém zamítne přístup ke kameře, fotogalerii, ukládání obrázku nebo
  mikrofonu, chybový stav nabídne přímé otevření nastavení aplikace. Síťové,
  kvótové a serverové chyby tuto akci nenabízejí.
- Nastavení Push notifikací ukazuje skutečný systémový stav oprávnění. Lze zde
  provést první žádost nebo po zamítnutí otevřít nastavení aplikace; po návratu
  se stav automaticky obnoví.
- iOS galerie prošla na čistém iOS 18.6 Simulatoru se skutečným assetem:
  durable kopie, WebDAV/finalize i serverová zpráva skončily za 2,16 s.
  Tento důkaz ale neobsahoval starší vyčerpaný upload zachovaný při TestFlight
  aktualizaci. Následné hlášení z fyzického buildu 29 proto odhalilo další
  blokaci fronty, kterou build 30 ještě neopravuje.

## 0.1.0 (28) — 31. 8. 2026

Play: přes Publishing API nahráno a commitnuto do uzavřeného alpha tracku;
track po commitu vrací build 28 ve stavu `completed`.
TestFlight: nevydáno. V této relaci není dostupný RemoteCmd/build-mac nástroj,
takže Apple build se nepředstírá jako hotový.

- Do hlavního psacího řádku se vrátilo rychlé obrázkové tlačítko s `+` pro
  přímý výběr z galerie. Sponka pro další zdroje a samostatný GIF zůstávají.
- Android 13+ používá systémovou predictive-back větev místo zastaralého
  callbacku. Když je přístup k poloze trvale zakázaný, chybová hláška nabídne
  přímé otevření nastavení aplikace.
- Po prvním načtení se Giphy picker znovu otevře z teplé account-scoped cache
  bez dalšího trending requestu a celoplošného kolečka. Sponka pro přílohy
  zůstává v toolbaru i během prvotní kontroly Giphy.
- Ve sponce přibyla Poloha. Aplikace si vyžádá foreground oprávnění, zjistí
  aktuální souřadnice, ukáže je před odesláním a sdílí je jen na serveru, který
  tuto funkci podporuje. Background sledování polohy nepoužívá. Pokud se po
  odeslání ztratí odpověď serveru, aplikace upozorní na možný úspěch místo
  slepého opakování a rizika duplicitní zprávy.

## 0.1.0 (27) — 31. 8. 2026

Play: přes Publishing API nahráno a commitnuto do uzavřeného alpha tracku;
track po commitu vrací build 27 ve stavu `completed`.
TestFlight: nevydáno. V této relaci není dostupný RemoteCmd nástroj a poslední
ověřený stav build-mac relay odmítá uložené tokeny 401; Apple build se proto
nepředstírá jako hotový.

- Fotografie vybraná z iOS Fotek už nespouští síťovou část nahrávání, dokud
  se aplikace po zavření pickeru skutečně nevrátí do popředí. Příloha tak
  nezůstane viset na „Čeká na nahrání“; pokud se návrat nedokončí, čekání je
  omezené a nabídne opakování.
- Sponka v psacím řádku sdružuje galerii, fotoaparát a soubor. GIF zůstává jako
  rychlá ikona vedle pole. Dlouhý stisk tlačítka Odeslat nově nabízí tiché a,
  kde jej server podporuje, také odložené odeslání.
- Běžný řetězec odpovědí otevřený ze seznamu vláken už nekončí hláškou, že
  vlákno na serveru není dostupné. Taková položka vzniká z místní historie a
  nyní se otevře rovnou v chatu; serverový detail zůstává jen pro skutečně
  pojmenovaná vlákna.
- Zprávu lze přeložit do některého z jazyků, které nabízí připojený Nextcloud.
  Aplikace umí nechat zdrojový jazyk rozpoznat, zachová zmínky a dovolí výsledek
  zkopírovat. Volba se zobrazí jen na serveru s aktivním překladovým
  poskytovatelem.
- V detailu podporované konverzace jsou dostupné sdílené soubory, obrázky,
  nahrávky, polohy, ankety a další serverové kategorie. Seznam se stránkuje,
  lze v něm opakovat neúspěšné načtení a klepnutí otevře původní zprávu i ve
  vlákně.
- Při přepnutí konverzace v širokém třípanelovém rozvržení už detail nepřenese
  ovládací prvky a oprávnění předchozí místnosti.

## 0.1.0 (26) — 31. 8. 2026

Play: přes Publishing API nahráno a commitnuto do uzavřeného alpha tracku;
track po commitu vrací build 26 ve stavu `completed`.
TestFlight: build `VALID`, bez non-exempt encryption, minimum iOS 15.0,
v interní i externí skupině s českými poznámkami.

- Lokální diagnostika ukazuje skutečnou uloženou i očekávanou verzi databáze,
  stav migrace a počet porušení cizích klíčů. Dříve zobrazovala jen číslo
  zabudované v aplikaci, takže starou nebo novější databázi nerozpoznala.
- Kontrakt založení konverzace odmítne skupinovou místnost s pozváním
  konkrétního uživatele. Talk tuto kombinaci nepodporuje; uživatelé se do
  skupiny přidávají až participant endpointem.
- Souhrn v detailu konverzace se po změně veřejného přístupu, režimu jen ke
  čtení nebo obrázku hned srovná s ovládacími prvky. Dříve po změně ukazoval
  původní typ, stav a avatar.

## 0.1.0 (25) — 31. 8. 2026

Play: přes Publishing API nahráno a commitnuto do uzavřeného alpha tracku;
track po commitu vrací build 25 ve stavu `completed`.
TestFlight: build `VALID`, bez non-exempt encryption, minimum iOS 15.0,
v interní i externí skupině s českými poznámkami.

- Když na iOS nezačne nahrávání hlasové zprávy, čekání po 10 sekundách skončí
  chybou a aplikace zůstane použitelná. Další pokus už neblokuje předchozí
  nativní nahrávání.
- Česká chybová hláška hlasové zprávy se vejde do spodní lišty i se všemi
  akcemi. Dříve přetékala mimo obrazovku.
- Z obrazovky nové konverzace lze vytvořit prázdnou skupinovou nebo veřejnou
  místnost bez hledání a pozvání prvního účastníka.
- Sdílená poloha se v chatu zobrazí se jménem místa a ikonou mapy. Klepnutí ji
  otevře v OpenStreetMap; neplatné nebo podvržené souřadnice zůstanou bezpečně
  neaktivní.
- V soukromé konverzaci se zobrazí aktuální nepřítomnost druhého člověka,
  včetně období, zprávy a případného zástupu. Dlouhý text banner neroztáhne
  přes celý chat ani při zvětšeném systémovém písmu.
- Nad chatem se připomene nejbližší událost kalendáře, která odkazuje na danou
  konverzaci. Banner ukazuje název a čas a lze jej zavřít.
- Sdílený kontakt ve formátu vCard se zobrazí jako kontakt místo obecného
  souboru. Klepnutí jej bezpečně stáhne a otevře v systémovém náhledu kontaktu.
- V otevřené konverzaci se ukáže, kdo právě píše. Více píšících lidí se sloučí
  do jednoho řádku; indikátor zmizí po ukončení psaní nebo po výpadku spojení a
  respektuje nastavení soukromí Nextcloud Talk. Vlastní indikátor se správně
  odešle i po obnovení signalingu; starý neprázdný koncept jej sám znovu
  nespustí.
- GIF přijatý ze serveru bez aktivní Giphy integrace už nenabízí nefunkční
  opakování. Místo něj ukáže, že GIFy na serveru nejsou dostupné; samotný odkaz
  přitom nezobrazí.
- Výběr GIFů si v rámci účtu pamatuje už stažené náhledy. Při opětovném
  otevření stejné mřížky je znovu nestahuje.
- Moderátor může v detailu podporované konverzace zapnout telefonické a SIP
  připojení s osobním PINem, bez PINu nebo jej vypnout. Volby se zobrazí jen
  tehdy, když je server i účet skutečně podporují. Po zapnutí uvidí každý
  účastník serverové pokyny, ID schůzky a případně svůj osobní PIN.

## 0.1.0 (23) — 30. 8. 2026

Play: odesláno ke kontrole. TestFlight: build `VALID`, obě skupiny.

- Opraven pád, který mohl nastat při otevření konverzace z notifikace nebo
  odkazu ve chvíli, kdy se hlavní obrazovka právě zavírala. Rozpracovaná
  navigace se nyní bezpečně ukončí.

## 0.1.0 (22) — 30. 8. 2026

Play: publikováno 30. 8. 14:39, k dispozici testerům, 177 zemí.
TestFlight: build `VALID`, obě skupiny.

- „Vybrat obrázek“ na iOS otevírá knihovnu Fotek. Dříve tato volba omylem
  otevřela prohlížeč dokumentů, takže screenshot uložený jen ve Fotkách nešel
  k zprávě přiložit.

## 0.1.0 (21) — 30. 8. 2026

Play: publikováno 30. 8. 13:36, k dispozici testerům, 177 zemí.
TestFlight: build `VALID`, obě skupiny.

- Při tažení otevřené konverzace zpět je nově vidět skutečný seznam
  konverzací pod ní. Dříve se chat sice posouval správně, ale odkrýval jen
  prázdné pozadí.

## 0.1.0 (20) — 30. 8. 2026

Play: publikováno 30. 8. 8:51, k dispozici testerům, 177 zemí.
TestFlight: build `VALID`, obě skupiny.

- Emoji jako obrázek konverzace si můžete obarvit. K výběru emoji přibyla
  řada barev pozadí. Ve výchozím stavu se barva neposílá vůbec, takže se
  pozadí řídí světlým nebo tmavým režimem, jak to dělal doteď.

Tento build zároveň přináší všechno z buildů 17 až 19, které Play nestihl
schválit a nahradil je:

- Hledat jde i uvnitř jedné konverzace. V její liště přibyla lupa, která
  prohledá jen ji; hledání ze seznamu konverzací zůstává přes všechny.
- Stav si můžete nechat vymazat sám: za 30 minut, za hodinu, za 4 hodiny,
  dnes nebo tento týden.
- Na zprávu ve skupině jde odpovědět soukromě.

## 0.1.0 (19) — 30. 8. 2026

Play: odesláno ke kontrole, ještě před schválením nahrazeno buildem 20.
TestFlight: přeskočeno, nahradil ho build 20.

- Hledat jde i uvnitř jedné konverzace. V její liště přibyla lupa, která
  prohledá jen ji; hledání ze seznamu konverzací zůstává přes všechny.
  Aplikace to uměla odjakživa, ale nikde se na to nedalo kliknout.

## 0.1.0 (18) — 30. 8. 2026

Play: odesláno ke kontrole, ještě před schválením nahrazeno buildem 20.
TestFlight: přeskočeno, nahradil ho build 20.

- Stav si můžete nechat vymazat sám. K poli se zprávou přibyla volba
  „Vymazat stav": za 30 minut, za hodinu, za 4 hodiny, dnes nebo tento
  týden. Doteď šel stav nastavit, ale ne zrušit časem, takže „Jsem na
  obědě" viselo u jména do večera.
- „Dnes" končí o půlnoci a „Tento týden" v neděli, obojí podle času
  vašeho telefonu.

## 0.1.0 (17) — 30. 8. 2026

Play: odesláno ke kontrole, ještě před schválením nahrazeno buildem 18.
TestFlight: přeskočeno, nahradil ho build 20.

- Na zprávu ve skupině jde odpovědět soukromě. V nabídce u cizí zprávy
  přibylo „Odpovědět soukromě": napsaná odpověď se odešle do vaší
  soukromé konverzace s autorem a nese s sebou odkaz na původní zprávu,
  takže druhá strana vidí, čeho se týká. Konverzace se založí sama,
  pokud ještě neexistuje.
- Soukromá odpověď by přitom doteď neprošla vůbec. Aplikace čekala, že
  server pojmenuje soukromou konverzaci seznamem obou účastníků, jenže
  ten posílá jméno druhého člověka. Ověřování tak selhalo pokaždé.

## 0.1.0 (16) — 29. 8. 2026

Play: publikováno. TestFlight: build `VALID`, obě skupiny.

- V nastavení přibyly licence knihoven, ze kterých je aplikace složená.
  Najdete je v Lokální diagnostice. Aplikace stojí na 171 balíčcích
  a jejich licence vyžadují, aby jejich znění šlo s programem — dosud
  se v aplikaci nedalo dostat nikam, kde by bylo k přečtení.

## 0.1.0 (15) — 29. 8. 2026

Play: publikováno. TestFlight: build `VALID`, obě skupiny.

- Napsaný text se odešle jako popisek přílohy. Když máte něco rozepsaného
  a připnete obrázek nebo soubor, text půjde s ním místo aby zůstal
  v poli. Prázdné pole popisek neposílá a hlasovka ho nebere.

## 0.1.0 (14) — 29. 8. 2026

Play: publikováno. TestFlight: build `VALID`, obě skupiny.

- Ztracené spojení s notifikačním kanálem se přestalo hlásit jako pád
  aplikace. Když systém uspí telefon a spojení zahodí, jeho zavírání
  selže — to je běžný konec spojení, ne havárie.
- Aplikace se při tom navíc přestala zasekávat: úklid toho spojení
  v takovém případě nikdy nedoběhl.

## 0.1.0 (13) — 29. 8. 2026

Play: publikováno. TestFlight: build `VALID`, obě skupiny.

- Moderátor může smazat i zprávu, kterou nenapsal. Server to dovoluje
  odjakživa, aplikace ale nabízela mazání jen u vlastních zpráv, takže
  moderátor s nevhodným příspěvkem nemohl udělat nic.

## 0.1.0 (12) — 29. 8. 2026

Play: publikováno. TestFlight: build `VALID`, obě skupiny.

- Konverzace, do které psát nesmíte, už nenabízí psací pole. Doteď šlo
  zprávu napsat a odeslat a teprve pak přišlo odmítnutí. Týká se dvou
  případů, které aplikace neuměla rozlišit: moderátor vám v konverzaci vzal
  právo psát, nebo konverzace ještě nezačala a čekáte v čekárně. Místo pole
  je teď zámek, který řekne, o který z nich jde.
- Přeposlat zprávu nejde do konverzace, kde byste ji stejně neodeslali.

## 0.1.0 (11) — 29. 8. 2026

Play: publikováno. TestFlight: build `VALID`, obě skupiny.

- Vlákna v seznamu se jmenují podle zprávy, ze které vznikla. Vlákno bez
  názvu se doteď jmenovalo jen „Vlákno", takže dvě vlákna v jedné konverzaci
  nešla od sebe rozeznat.
- Seznam vláken už netvrdí, že žádná nejsou, dokud se nezeptá serveru.
  Načítání se pouštělo až po prvním vykreslení, takže obrazovka odpověděla
  dřív, než se stačila zeptat.
- Výpadek sítě při probuzení na notifikaci se přestal hlásit jako pád
  aplikace. Sync se v takové chvíli běžně nepovede, protože se zařízení
  teprve připojuje; druhá probouzecí cesta to tak brala odjakživa.

## 0.1.0 (10) — 29. 8. 2026

Play: publikováno. TestFlight: build `VALID`, obě skupiny.

- Seznam vláken ukazuje i vlákna, která vznikla odpovídáním. Server v seznamu
  hlásí jen pojmenovaná vlákna, takže konverzace plná odpovědí vypadala prázdně.
  Aplikace teď doplní ta, která zná ze svých uložených zpráv.

## 0.1.0 (9) — 29. 8. 2026

Play: odesláno ke kontrole. TestFlight: build `VALID`, obě skupiny.

- Odkaz na konverzaci už aplikaci neshodí. Odkaz dorazil dvakrát: jednou naším
  kanálem, který ho vyhodnotí proti přihlášeným účtům, a podruhé jako
  pojmenovaná trasa od systému. Na tu druhou aplikace neměla čím odpovědět
  a padala na každém otevřeném odkazu. Nahlásila to telemetrie ze skutečného
  zařízení.

## 0.1.0 (8) — 29. 8. 2026

Play: publikováno 29. 8. 9:29. TestFlight: build `VALID`, obě skupiny.

- Prázdný seznam vláken už neplete. Odpověď na zprávu vlákno nezaloží, což
  obrazovka doteď zamlčovala a vypadalo to, že aplikace zatajuje odpovědi,
  které uživatel prokazatelně má.

## 0.1.0 (7) — 29. 8. 2026

Play: publikováno 29. 8. 6:36. TestFlight: build `VALID`, obě skupiny.

- Čtení historie už nic neruší. Zpráva, která dorazí, když jste zanoření ve
  starších zprávách, vás nechá přesně tam, kde jste. Doteď vás odsunula o výšku
  své bubliny. Časová osa je nově `CustomScrollView` s `center` klíčem, takže
  jeden konec seznamu nepřeindexuje druhý.
- Animovaný GIF se dekóduje na velikost, ve které se opravdu kreslí, místo
  napevno zadaných 1080 pixelů.

## 0.1.0 (6) — 29. 8. 2026

Play: publikováno. TestFlight: build `VALID`, obě skupiny.

- Tažením od levého kraje se vrátíte na seznam konverzací. V kompaktním
  rozvržení se konverzace nepushuje jako route, takže systémové gesto nemělo co
  vyhodit ze zásobníku a nedělalo nic.
- Tiché odeslání platí i pro psanou zprávu, ne jen pro přílohy. Server bez
  `silent-send` požadavek odmítne, místo aby ho poslal nahlas.
- Windows si drží jednu instanci a přidává ikonu do systémové lišty.

## 0.1.0 (5) — 29. 8. 2026

Play: publikováno. TestFlight: build `VALID`, obě skupiny.

- Druhá fajfka u přečtené zprávy se po návratu do konverzace neztrácí.
  Agregovaný read marker nebyl zapnutý na žádném serveru, protože profil
  schopností ho měl natvrdo vypnutý.
- Reakce ostatních dorazí do otevřené konverzace. Doteď šly vidět jen ty
  přidané z tohoto zařízení.
- Odeslaná zpráva zmizí z psacího pole hned. Když se během odesílání psalo dál,
  zůstávala tam a šla omylem poslat podruhé.
- Skok na konec konverzace po zanoření do historie.
- Odpověď tahem za bublinu.
- Samotné emoji ve zprávě i v reakci se vykreslí větší.

## 0.1.0 (4) — 29. 8. 2026

Jen TestFlight; na Play se toto číslo nedostalo, protože Apple už měl obsazené
buildy 1 až 3 a čísla se sjednocovala.

- Stejný obsah jako 0.1.0 (2) plus telemetrie zkompilovaná do buildu.

## 0.1.0 (3) — 28. 8. 2026

Jen TestFlight, build `VALID` od 28. 8., přiřazený do interní i externí skupiny.
První build, který dostal české poznámky pro testery.

## 0.1.0 (2) — 28. 8. 2026

Play: publikováno 28. 8. 23:10, první vydání dostupné testerům.

- Notifikace chodí i uživateli, který má vedle toho oficiální aplikaci Talk.
  Registrace push zařízení posílá správný User-Agent, podle kterého server
  určuje typ aplikace.
- Obrázky se nedeformují ani v náhledu, ani po rozkliknutí.
- Bundle přestal žádat oprávnění k fotkám a videím, která aplikace nepoužívá.

## 0.1.0 (1) — 27. 8. 2026

Jen TestFlight, build `VALID` od 27. 8. První build aplikace, který se vůbec
dostal k testerům. Cestu k němu a čtyři blokády, které přitom padly, popisuje
`docs/architecture/apple-distribution.md`.
