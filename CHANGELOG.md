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

## 0.1.0 (54) — 3. 9. 2026

Vydáno ze zdroje `8730973`, tag `v0.1.0+54`.

Android: release APK 91 097 916 B, SHA-256
`3376a891408ac4689bba302c6ae9e6cb5ab7498167b7fd870e57c0785639c18f`,
versionCode 54; na Android 14 emulátoru běží dva účty na dvou serverech,
federovaná pozvánka přijata a zprávy tečou oběma směry, push z druhého
serveru dorazil. Play track nenahrán (kadence).

Windows: instalátor `NKS-Talk-0.1.0-54-windows-x64-setup.exe` 35 457 353 B,
SHA-256 `97d9e14b3fb1f1daa985db2bcf7a0b8cf91b1858000b31c78b9dc965be74e159`,
nepodepsaný; tichá instalace na `windows-test-vm`, `nextcloudtalk.exe` hlásí
`0.1.0+54` (PID 7868).

iOS: simulátor iPhone 16 Pro Max / iOS 18.6, debug build nainstalován a
spuštěn. TestFlight nenahrán (kadence, poslední je 51).

macOS: `nks-talk-macos-54.zip` 32 917 467 B, SHA-256
`20df8cde271e16cc808e13f4c3a225b6c923ff860b0347511e235dd511aafd74`,
Developer ID Application (TEAMID0000), notarizováno (Accepted), stapled,
`spctl`: Notarized Developer ID — ověřeno na souboru staženém zpět z
Nextcloudu; běží na build-mac (PID 76194). Poslán do chatu Pimpula (share 8919,
zpráva 78838).

- Pozvánky do konverzací na jiných serverech (federace): pruh nad seznamem
  s počtem čekajících pozvánek, přehled s tlačítky Přijmout / Odmítnout;
  přijatá konverzace se rovnou otevře. Federovaná konverzace se načte a
  zprávy jdou oběma směry.
- Přihlášení na server s „hezkými" adresami bez `index.php` (výchozí u
  Docker image Nextcloudu) už neskončí chybou.
- Seznam konverzací ze serveru s Talkem 22 (bez štítků, připnutých a
  plánovaných zpráv) se už neodmítá.
- Dva účty na dvou různých serverech v jedné aplikaci — živě ověřeno včetně
  oddělených přihlášení a push notifikací z obou serverů.
- Nový testovací server `talk2.example.invalid` (Nextcloud 32 / Talk 22) pro
  federaci a scénáře se dvěma servery.

## 0.1.0 (53) — 3. 9. 2026

Vydáno ze zdroje `fdbc3eb`, tag `v0.1.0+53`.

Android: release APK 90 917 560 B, SHA-256
`1ac61d2016a85606f0ae9312397557d73f656deee84c633b9f1bec72ebee0987`,
versionCode 53; na Android 14 emulátoru se panel emoji po odeslání 😀 zavřel
a zpráva dorazila na server. Play track nenahrán (kadence).

Windows: instalátor `NKS-Talk-0.1.0-53-windows-x64-setup.exe` 35 436 443 B,
SHA-256 `9ea6211b9110f3a5f8ccfa066ce67252f6484e82bbb8ce8a31cf6b6c3ca735e5`,
nepodepsaný; tichá instalace na `windows-test-vm`, `nextcloudtalk.exe` hlásí
`0.1.0+53` (PID 20348).

iOS: simulátor iPhone 16 Pro Max / iOS 18.6, debug build nainstalován a
spuštěn; emoji z panelu odesláno a panel se zavřel. TestFlight nenahrán
(kadence, poslední je 51).

macOS: `nks-talk-macos-53.zip` 32 882 920 B, SHA-256
`6a71b3e7a00f047832024b3aedb6d8854a718688fb98b15d1657c2dafd05dc0b`,
Developer ID Application (TEAMID0000), notarizováno (Accepted), stapled,
`spctl`: Notarized Developer ID — ověřeno na souboru staženém zpět z
Nextcloudu; běží na build-mac (PID 47641). Poslán do chatu Pimpula (share 8911,
zpráva 78812).

- Panel emoji se po odeslání zprávy zavře sám.
- Seznam konverzací si každých pět minut vyžádá celý přehled ze serveru,
  takže místnost smazaná nebo opuštěná na serveru zmizí i bez ručního
  obnovení (dosud zůstávala, dokud se aplikace nespustila znovu).
- Živé důkazy: TalkBack vysloví příchozí zprávu („New activity. NCloudTalk
  Test 2: …"), obrazovky při 200 % textu ve světlém i tmavém tématu bez
  přetečení, macOS Developer ID + notarizace jako trvalý postup.

## 0.1.0 (52) — 3. 9. 2026

Vydáno ze zdroje `81ea963`, tag `v0.1.0+52`.

Android: release APK 90 917 560 B, SHA-256
`a673d1466b88ddedf3ee15d2869ffc7634018384fb17741aa9d0ddfd95f27cce`,
versionCode 52; na Android 14 emulátoru doručil po startu tři zprávy
zafrontované offline v buildu 51 a odpověď z notifikace odešla jako reply
(zpráva 78744, parent 78742). Play track: viz poznámka k vydání 51.

Windows: instalátor `NKS-Talk-0.1.0-52-windows-x64-setup.exe` 35 445 402 B,
SHA-256 `a49e2f84be83f132e0cb0e0259fba3f7c3a376a976c99c2ff8d65064ead68441`,
nepodepsaný; tichá instalace na `windows-test-vm`, `nextcloudtalk.exe` hlásí
`0.1.0+52` (PID 8448). Předchozí instalátor s tímto názvem (SHA
`31044eb8…`) nesl exe z doby před bumpem a byl nahrazen.

iOS: simulátor iPhone 16 Pro Max / iOS 18.6, debug build nainstalován a
spuštěn; po „Odpovědět" je banner odpovědi a kurzor v psacím řádku.
TestFlight: build 51 nahrán (Delivery `ba8a770d-d5a9-42a8-a211-dd79c6ced135`,
VALID) po opravě portálu; 52 se na TestFlight nenahrával (kadence).

macOS: `nks-talk-macos-52.zip` 32 883 246 B, SHA-256
`8e88f15e2c07f404b3314fc57bdf3c0c49f5b6d8f24adcbab5e8df8a92522c38`,
Developer ID Application (TEAMID0000), notarizováno (Accepted), stapled,
`spctl`: Notarized Developer ID — ověřeno na souboru staženém zpět z
Nextcloudu; běží na build-mac (PID 31592). Poslán do chatu Pimpula (share 8909,
zpráva 78763). Past: entitlements podepsané přímo ze zdrojového souboru
nesou nerozvinuté `$(APS_ENVIRONMENT)`/`$(AppIdentifierPrefix)` a amfid
aplikaci nepustí („No matching profile found"); CRLF v `.entitlements` z
Windows archivu shodí parser.

- Konverzace s obrázky už při scrollování nahoru netáhne zpět dolů: bublina
  obrázku má velikost podle rozměrů, které Talk posílá, ještě než se náhled
  načte, takže se pod čtenářem nic nepřeskládá.
- Odpověď z notifikace je skutečná odpověď na tu zprávu (citace v bublině),
  ne nová zpráva — na Androidu, iOS, macOS i Windows.
- Po „Odpovědět" dostane psací řádek rovnou focus.
- Tažení oddělovače seznamu konverzací je plynulé — měří se od začátku
  gesta, ne z poslední překreslené šířky.
- Zprávy napsané bez připojení se odešlou hned po návratu sítě nebo po
  startu aplikace i bez otevřené konverzace; příloha, které vypršely
  automatické pokusy, se po návratu sítě zkusí znovu sama.
- Akce zprávy fungují i offline z uložených capabilities.
- Živé důkazy: stav přečtení u přílohy, hlasovky i polohy podle serverového
  markeru; sdílené položky jako příjemce včetně druhé stránky (32 souborů);
  karta odkazu na iOS; trvalý outbox po pádu procesu; odpověď na obrázek.

## 0.1.0 (51) — 3. 9. 2026

Vydáno ze zdroje `24390c5`, tag `v0.1.0+51`.

Android: release APK 90 884 792 B, SHA-256
`a86548a9b8848ffab82087fb779cdac016643898cf7ab20ab346b246e273566c`,
versionCode 51; na Android 14 emulátoru hledání „hlodavec" v anglickém UI
vrací Mouse, Rat, Hamster a Beaver. Play track nenahrán.

Windows: instalátor `NKS-Talk-0.1.0-51-windows-x64-setup.exe` 35 439 793 B,
SHA-256 `07dae9d6a952b10b775fa302390a63a3ebb1592a157ce2b2c69e32b9392a47b2`,
nepodepsaný; tichá instalace na `windows-vm`, `nextcloudtalk.exe` hlásí
`0.1.0+51` (PID 320).

iOS: simulátor iPhone 16 Pro Max / iOS 18.6, debug build nainstalován a
spuštěn. TestFlight NEVYDÁN (provisioning).

macOS: debug build + ad-hoc podpis, 30 s bez pádu.

- Výběr emoji zná česky celý katalog: 4 361 názvů a klíčových slov z Unicode
  CLDR, takže „hlodavec" najde bobra a „tající" tající obličej. Ručně psaných
  31 názvů zůstává a má přednost.
- Rozhodnuto, od které řady serveru klient funguje: Talk 22 (Nextcloud 32) —
  tam vznikla poslední povinná capability (`threads`); jediná mladší,
  štítky konverzací, jen zapíná funkci (D-047).
- Připraven spike volání: `flutter_webrtc` 1.6.1 se postaví a naváže spojení
  na Windows, Androidu, macOS i v iOS simulátoru; podrobnosti a pasti
  v `docs/TODO-notifications-calls.md`. Do aplikace se zatím nepřidává.
- Úklid TODO: uzavřeno sedm položek, které byly buď duplicitní, překonané
  funkční cestou (macOS ad-hoc běh, Windows build mimo VM), nebo zásady
  místo úkolů; changelog na NKS IS je synchronizovaný s repozitářem.

## 0.1.0 (50) — 3. 9. 2026

Vydáno ze zdroje `9a530d7`, tag `v0.1.0+50`.

Android: release APK 89 115 320 B, SHA-256
`78a316e3f53c59c7836e5070aaef986cfff3372f3d345f9fc2f998ffd2279b78`,
versionCode 50; na Android 14 emulátoru běží, sync bez opakovaného
stahování capabilities. Play track nenahrán.

Windows: instalátor `NKS-Talk-0.1.0-50-windows-x64-setup.exe` 35 215 152 B,
SHA-256 `735af5242196d460d2cf1f616d7427519228e271889fa5eac940e83ba05a8531`,
nepodepsaný; tichá instalace na `windows-vm`, `nextcloudtalk.exe` hlásí
`0.1.0+50` (PID 9608), účet přihlášený a synchronizuje.

iOS: simulátor iPhone 16 Pro Max / iOS 18.6, debug build nainstalován a
spuštěn se seznamem konverzací. TestFlight NEVYDÁN (provisioning).

macOS: debug build + ad-hoc podpis, 30 s bez pádu, bez účtu.

- Synchronizace seznamu konverzací už nestahuje každých 15 s znovu 13 kB
  capabilities. Přerušitelné čtení, kterým sync jede, nikdy nenahradilo
  prošlý záznam v paměťové cache, takže po pěti minutách běhu každý cyklus
  šel na server dvakrát.
- Krátké přerušení okna — výběr fotky, dialog oprávnění, panel oznámení —
  už neshazuje a neobnovuje přítomnost v místnosti. Server dostával pro každé
  klepnutí odhlášení a přihlášení session i nový signaling; přítomnost se
  teď pouští až po dvou sekundách nečinnosti, což pro potlačení notifikací
  nehraje roli.
- Ověřeno živě: zaparkovaný účet na Windows se s buildem 49 sám uvolnil;
  upload obrázku z pickeru trvá ~2 s; odmítnutý mikrofon nabídne nastavení;
  rotace s otevřenou konverzací přepne dvoupanelový layout bez pádu;
  „Poslat do Note to self" funguje i na iOS.

## 0.1.0 (49) — 3. 9. 2026

Vydáno ze zdroje `1e1f4ca`, tag `v0.1.0+49`. Dávka vznikla ze Sentry nálezů
buildu 47 a z živého ladění stavu „přihlásit se znovu".

Android: release APK 89 115 320 B, SHA-256
`88a8f8a550050a20c69a8f1658db8aef54211c7febc15fe9befca86ebd7619b5`,
versionCode 49. Živě na Android 14 emulátoru: zaparkovaný účet se po
instalaci sám uvolnil (room sync 200 bez zásahu), cold-start sdílení textu
do vybrané místnosti, „Poslat do Note to self" z akcí zprávy. Play track
nenahrán.

Windows: instalátor `NKS-Talk-0.1.0-49-windows-x64-setup.exe` 35 212 253 B,
SHA-256 `3ca79e7bcbe450716e57ca5adfb464c78391e271d5aab4e35555cea2c3411ff5`,
nepodepsaný; tichá instalace na `windows-vm` pod RDP, `nextcloudtalk.exe`
hlásí `0.1.0+49`, okno „NKS Talk" žije (PID 9960).

iOS: simulátor iPhone 16 Pro Max / iOS 18.6, debug build z téhož zdroje
nainstalován a spuštěn, seznam konverzací přihlášeného účtu. TestFlight
NEVYDÁN (provisioning, viz 48).

macOS: debug build přes `xcodebuild` + ad-hoc podpis, běh 30 s bez pádu;
bez přihlášeného účtu.


- Účet už nespadne do „přihlásit se znovu" kvůli jednomu chybnému 401.
  Referenční server 2. 9. večer vracel na několik sekund 401 pro platné
  tokeny třem klientům najednou; aplikace každý takový výpadek brala jako
  odvolané přihlášení a zůstala v něm, dokud se uživatel nepřihlásil ručně.
  Teď se 401 ověřuje druhým čtením po dvou sekundách, a účet, který už
  v tom stavu je, se sám uvolní, jakmile jeho token zase funguje.
- Krátce po startu mohl trezor s heslem odpovědět „nic tu není", než byl
  systémový keystore připravený; aplikace to zapsala jako chybějící
  přihlášení a přestala synchronizovat. Čtení se opakuje a stav není trvalý.
- Přihlášení znovu už neshodí stará odpověď: 401 pro heslo, které uživatel
  mezitím nahradil, se ignoruje.
- Čtyři pády hlášené ze Sentry (build 47): registrace push při výpadku sítě,
  probuzení synchronizace zaparkovaného účtu, odmítnuté oprávnění
  k oznámením na iOS a start bez složky Dokumenty. Žádný z nich už není pád.
- Akce zprávy „Poslat do Note to self" pošle text rovnou do vlastní
  poznámkové konverzace.
- Lišta stahování přílohy zná procenta i tam, kde server nepošle délku:
  vezme velikost souboru ze sdílení.

## 0.1.0 (48) — 2. 9. 2026

Vydáno ze zdroje `8b32836` (+ docs).

Android: release APK 89 098 936 B, SHA-256
`3ee52907b5cd5fd8edae0254eb0f10fd5a8044e1beee54347033d0067a9dc483`,
versionCode 48. Ověřeno živě na Android 14 emulátoru: přihlášení fixture-user,
Note to self (zpráva dorazila na server), odpověď jako citovaná bublina,
průběh stahování 6 MB přílohy s procenty. Play track zatím nenahrán.

Windows: instalátor `NKS-Talk-0.1.0-48-windows-x64-setup.exe` 35 210 814 B,
SHA-256 `e1988a72d6694499da89bed6f056df2df9b2dd6ab7186cf4e80bb0d7493f0c25`,
nepodepsaný; nainstalován tichým během na `windows-vm` pod uživatelem RDP do
`%LOCALAPPDATA%\Programs\NKS Talk`, `nextcloudtalk.exe` hlásí `0.1.0+48`
a okno „NKS Talk" žije. Build na tom VM nejde (MSVC × `jni`), stavěno
lokálně. Účet na VM je od dřívějška ve stavu „přihlásit se znovu", takže
UI důkaz nových položek na Windows je jen z widget testů pro platformu
windows.

iOS: simulátor iPhone 16 Pro Max / iOS 18.6, debug build z téhož zdroje.
Ověřeno přihlášení, Share Extension ze Safari až po zprávu na serveru,
odpověď v konverzaci, tlačítko přepisu (přepis sám v simulátoru nedoběhne,
viz níže). TestFlight NEVYDÁN: App Store profil nemá App Groups a pro
Share Extension profil neexistuje.

macOS: debug build přes `xcodebuild` bez podpisu + ad-hoc `codesign`
(`valid on disk`), aplikace běžela 40 s bez pádu; přihlášení na build-mac
vyžaduje člověka u stroje, GUI důkaz chybí.

- Otevřená konverzace na desktopu konečně dá vědět o nové zprávě. Aplikace
  serveru hlásila, že je uživatel v místnosti přítomný, dokud tu konverzaci
  neopustil — a Nextcloud přítomnému schválně notifikaci potlačí, aby mu
  nepípal na zprávu, kterou si právě čte. Na telefonu to sedí, na desktopu ale
  okno drží konverzaci otevřenou za třemi jinými okny, takže server mlčel celou
  dobu. Nezaostřené okno se teď za přítomnost nepovažuje.
- Živý kanál se po výpadku zase zvedne. Když přihlašovací údaj nebyl v tu
  chvíli čitelný — a na desktopu není hned po startu okna — aplikace to četla
  jako „tenhle server živý kanál nenabízí" a vypnula ho na celý běh. Teď to
  zkouší dál.
- Notifikace na Windows zní jako zpráva, ne obecně. Stejný rozdíl mezi zvukem
  zprávy a zvukem hovoru dělá i oficiální aplikace Talk.
- Na širokém okně už aplikace neplatí místem za přepínač účtů, který nemá mezi
  čím přepínat, a seznam konverzací jde složit; volba přežije restart.
- Odpověď zůstává v konverzaci. Server od Talku 22 zakládá každou odpovědí
  vlákno a aplikace ji podle toho z konverzace schovávala, takže odpověď šla
  najít jen přes „N odpovědí" pod původní zprávou. Teď se odpověď zobrazí
  klasicky: citovaná bublina, na kterou reaguje, a pod ní vlastní text. Kdo
  chce vlákna, přepne si to v Nastavení → Odpovědi; pojmenovaná vlákna
  zůstávají dostupná v obou režimech.
- Stahování přílohy už nemlčí. Otevření, uložení i sdílení přílohy ukazuje od
  prvního okamžiku lištu s procenty; když server délku neprozradí, běží lišta
  neurčitě, ale aspoň je vidět, že se něco děje.
- Na desktopu jde myší vybrat text z bubliny a zkopírovat ho. Dlouhé stisknutí
  bubliny dál otevírá akce zprávy.
- Hlasovou zprávu jde na iPhonu přepsat na text přímo v zařízení, bez odeslání
  nahrávky kamkoli ven; přepis jde jedním klepnutím zkopírovat. Když jazyk
  aplikace nemá v iOS offline model (čeština ho nemá), použije se jazyk
  zařízení. V simulátoru rozpoznávání končí systémovou chybou 1101, skutečný
  přepis potvrdí až fyzický iPhone.
- iOS má Share Extension: text nebo jeden soubor sdílený ze systémové nabídky
  jde poslat do vybraného účtu a konverzace, stejně jako na Androidu.
- macOS: „Uložit jako" u přílohy dřív skončilo bez souboru, protože sandbox
  povoloval jen čtení vybraného umístění. Zápis je teď povolený.

## 0.1.0 (47) — 2. 9. 2026

Vydáno ze zdroje `4bfaf70`, tag `v0.1.0+47`.

Play (uzavřené testování, track alpha): vydání `(47) 0.1.0` je `completed`
s version code 47. AAB má 84 337 287 B a SHA-256
`c9d0758420e061f1b27862197356749851d8e41bcf222e32a931f5e5870c5dd7`. Poznámky
v šesti jazycích ověřeny zpětným dotazem na track.

TestFlight: IPA 30 237 904 B nahrána z build-mac, `xcrun altool` hlásí „No errors
uploading archive". Export dřív padal na tom, že provisioning profil nemá
Associated Domains; entitlement byl odstraněn, protože hlásil natvrdo doménu
jednoho serveru, což v multi-server klientovi nedává smysl, a žádný kód
univerzální odkazy nepoužíval.

macOS: ZIP 32 022 517 B, SHA-256
`c55ab36ffdf544a40e701c3ea80cc8fa4364e6566611049ea96da170ba4ee6f3`, podepsáno
Developer ID (team TEAMID0000), `app-sandbox` i `aps-environment`, `codesign
--verify` hlásí „satisfies its Designated Requirement".

Windows: nasazeno na `windows-vm`, instalátor ohlásil `Installed 0.1.0+47`.
Android ověřen na emulátoru `chatujmePixel` (`versionCode=47`), iOS na
simulátoru iPhone 16 Pro Max.

- macOS konečně dá vědět o nové zprávě, i se zvukem a s akcemi Odpovědět
  a Označit jako přečtené. Nextcloud posílá Talk notifikace jen zařízením,
  která se hlásí jako Android nebo iOS, takže desktopový klient z jeho proxy
  nedostane nic, jakmile má účet registrovaný telefon. Windows si notifikaci
  od dávky 45 zobrazuje sám nad živým kanálem; macOS neměl nic, takže se
  aplikace poctivě synchronizovala, ale uživateli to nikdy neřekla.
- Hledání v konverzaci zase vrací výsledky. Server na dotaz do jedné místnosti
  odpoví i shodami odjinud — parametr `from` je nápověda pro řazení, ne filtr —
  a aplikace kvůli jediné cizí položce zahodila celou odpověď a hlásila, že jí
  nerozumí. Cizí výsledky se teď přeskočí a zbytek dorazí.
- Seznam konverzací jde chytit za oddělovač a přetáhnout na jinou šířku; volba
  přežije restart. Táhací je sám oddělovač, ne pruh navíc, aby splitter nebral
  konverzaci místo, které jí má vracet.
- Když na konverzaci zbývá málo místa, seznam se složí sám a po zvětšení okna
  se vrátí. Uložené předvolby se to nedotkne — ta je volbou pro okna, která
  místo mají.
- Nadpis v hlavičce seznamu se přestal lámat uprostřed slova. V pruhu širokém
  300 px se tloukl s avatarem a třemi tlačítky, takže z „Konverzace" zbylo
  „Konverzac / e"; nadpis zmizel, čtečky obrazovky ho ale dál dostanou.

## 0.1.0 (46) — 2. 9. 2026

Vydáno ze zdroje `f9d2380`, tag `v0.1.0+46`, postaveno z čistého worktree.
Poprvé na všechny tři platformy najednou.

Play (uzavřené testování, track alpha): vydání `(46) 0.1.0` je `completed`
s version code 46. AAB má 84 306 565 B a SHA-256
`7fe346441b6c2e88408523060ff2d35ec3e498e13ea53e462de4d1d8ea73d37a`, SHA-1
`d553b29fe37624008c892bff28ff4cc087340d36`. Poznámky v šesti jazycích ověřeny
zpětným dotazem na track.

Windows: ZIP má SHA-256
`ef7508d85aefb2c6beaccf74698aee3f758239fa879e0755a478ef1d5200e600`, nasazený
instalačním skriptem na `windows-test-vm` do `C:\Program Files\NKS Talk`. Ověřeno za
běhu: jediná instance, `0.1.0+46`, okno „NKS Talk".

macOS: postaveno na Codemagicu (build `<codemagic-app-id>`), ZIP má
SHA-256 `df4cd128b1e2a1487430a7638c5cd21abe11a541013bb935b56c8c6d9841827b`,
`CFBundleVersion` 46, minimum macOS 12.0. POZOR: balík je podepsaný AD-HOC a
NEMÁ provisioning profil, takže na něm nemohou fungovat push notifikace —
integrace App Store Connect nedodala CLI `ISSUER_ID`. Zbývá dořešit.

TestFlight: nevydáno, `build-mac` je stále mimo a iOS workflow zatím neběželo.


- Na širokém okně už aplikace neplatí místem za přepínač účtů, který nemá mezi
  čím přepínat. S jediným účtem zabírala svislá lišta vlevo 88 pixelů na celou
  výšku okna pro logo, avatar, na který nešlo ani kliknout, a dvě tlačítka.
  Lišta se teď objeví až u druhého účtu; její akce mezitím drží nabídka pod
  avatarem v hlavičce seznamu, stejná jako na telefonu. Konverzace tím dostala
  89 pixelů zpět — na notebooku s šířkou 1024 skoro devět procent obrazovky.
- Seznam konverzací jde složit. V hlavičce otevřené konverzace přibylo
  tlačítko, které seznam schová a zase vrátí, takže na čtení delší konverzace
  je k dispozici celé okno. Volba přežije restart aplikace.

## 0.1.0 (45) — 2. 9. 2026

Vydáno ze zdroje `f5b82dc`, tag `v0.1.0+45`, postaveno z čistého worktree.

Play (uzavřené testování, track alpha): vydání `(45) 0.1.0` je `completed`
s version code 45. AAB má 84 298 278 B a SHA-256
`6a63491c6f6ddb3dba63eb712d5221d385c985e7afa3aa96275b27fd10f7fdf4`, SHA-1
`bd2f07a55a8fecd44e4b42b91f0390e5672ca51d`. Poznámky v šesti jazycích ověřeny
zpětným dotazem na track.

Windows: poprvé se vydává i desktopový balík. ZIP má SHA-256
`84e330681f2e8b68243840616dd35d9d67ea3508b5ccc69142a16139c2a6895a` a je
nasazený na `windows-test-vm` novým instalačním skriptem do
`C:\Program Files\NKS Talk`; `nextcloudtalk.exe` hlásí `0.1.0+45`.

TestFlight a macOS: NEVYDÁNO. `build-mac` není připojený k RemoteCmd relay
a Codemagic zatím není k tomuto repozitáři připojený, takže Apple artefakt
vůbec nevznikl. Nevydává se za to falešný důkaz.


- Odkaz na konverzaci konečně otevře aplikaci i na Windows. Schéma `nctalk:`
  se registruje v instalátoru, který ale projekt nikdy neměl, takže každé
  ruční rozbalení buildu deep linky tiše postrádalo — v registru nebyl
  po odkazu ani záznam. Registraci teď dělá nový instalační skript a běžící
  aplikace odkaz převezme místo aby se spustila podruhé.
- Přibyl instalační skript pro Windows. Vznikl z chyby, která se nemá
  opakovat: build se rozbalil vedle starší instalace, ta si nechala své
  zástupce a tester pak otevíral týden starou verzi. Skript instaluje vždy
  přes existující kopii, přesměruje zástupce a odmítne skončit se dvěma
  kopiemi na jednom stroji.

## 0.1.0 (44) — 2. 9. 2026

Vydáno ze zdroje `26a1c5c`, tag `v0.1.0+44`, postaveno z čistého worktree
`origin/main`.

Play (uzavřené testování, track alpha): vydání `(44) 0.1.0` je `completed`
s version code 44. AAB má 84 298 247 B a SHA-256
`cfa37169aad17dc30c23b114c5e2ff7dde9400442b79d7211f721f30ea8961f3`, SHA-1
`75560d3ac0d4755a2297d9c5edd1cc9804aee738`. Poznámky v šesti jazycích ověřeny
zpětným dotazem na track. Licenční brána prošla se 148 Flutter balíky a 113
Android runtime komponentami. Na emulátoru Android 16 ověřen `versionCode=44`,
běžící proces a log bez FATAL/ANR.

TestFlight: NEVYDÁNO, stejně jako u buildu 43 — `build-mac` není připojený
k RemoteCmd relay, takže iOS artefakt nevznikl a iOS ani macOS se neotestovaly.


- Výkonové metriky odcházely s drobečkovou stopou navíc. Serverové ověření
  buildu 43 ukázalo, že událost dorazí s záznamy o životním cyklu, baterii
  a navigaci, přestože se staví prázdná a odesílá s vyčištěným kontextem —
  SDK je doplní až za ním. Sráží se teď na stejném místě, kde se to už dělá
  pro diagnostiku příloh. Běžné hlášení pádu si svoje záznamy ponechává.
- Sondy přístupnosti pokrývají navíc psací lištu, obrazovku nové konverzace,
  diagnostiku a dialog hesla místnosti.

## 0.1.0 (43) — 2. 9. 2026

Vydáno ze zdroje `c171d71`, tag `v0.1.0+43`, postaveno z čistého worktree
`origin/main`, ne z pracovní kopie.

Play (uzavřené testování, track alpha): vydání `(43) 0.1.0` je `completed`
s version code 43. AAB má 84 298 648 B a SHA-256
`02f8e35b3630671a2151c73e1b8216f276276a30e4dbd4d9f4c99f9ebee6cf9a`, SHA-1
`547ad0066276685f4de18adf200eef509e206db1`. Poznámky v šesti jazycích
ověřeny zpětným dotazem na track. Licenční brána prošla se 148 Flutter
balíky a 113 Android runtime komponentami.

TestFlight: NEVYDÁNO. Stroj `build-mac` nebyl v době vydání připojený k RemoteCmd
relay, takže iOS artefakt nevznikl a iOS ani macOS se neotestovaly. Nevydává
se za to falešný důkaz; iOS půlka buildu 43 zbývá.

- Potvrzovací dialogy jde odpovědět i při dvojnásobném systémovém písmu.
  Dialog „Sdílet soubor do konverzace" v angličtině přetékal o 48 px dolů,
  takže tlačítka Zrušit a Sdílet skončila mimo obrazovku a soubor nešlo ani
  sdílet, ani dialog zavřít. Změřeno na skutečné obrazovce, ne na kopii
  v testu. Stejná ochrana je nasazená na dalších dvanácti dialozích, které
  nemají vlastní rolování — mazání zprávy, odebrání účtu, opuštění a smazání
  konverzace, vymazání historie, odebrání účastníka, zrušení nedokončeného
  uploadu, heslo k otevřené konverzaci, otisk certifikátu, úprava zprávy
  a pojmenování vlákna.
- Odmítnutá příloha konečně řekne proč. Hlášení z terénu (Galaxy Z Fold 6,
  Android 16): sponka → vybrat obrázek → okamžitě „zkusit znovu". V telemetrii
  z toho byla jediná značka `dispatch`, protože se všechny příčiny odchytávaly
  jedním `on Object`. Přitom jsou to čtyři různé problémy s různými opravami —
  místnost, do které se nesmí psát; účet, jehož server se rozešel s požadavkem;
  chybějící heslo aplikace; a aplikace, která se po zavření galerie nevrátila
  do popředí. Služba je teď hlásí typovaně a příští výskyt se pozná na první
  pohled. Samotná příčina onoho hlášení tím ještě opravená není.
- Výkonové metriky se poprvé opravdu měří. Vrstva byla hotová už dřív, ale
  nikdo ji nevolal; teď měří start aplikace, synchronizaci seznamu, otevření
  konverzace, upload přílohy a probuzení pushem. Ven jde jméno operace
  z uzavřeného výčtu, výsledek a koš trvání — nikdy adresa serveru, room token
  ani název souboru. Sentry tracing zůstává vypnutý schválně: jeho automatické
  spany jsou popsané URL, na kterou šly.
- Dva účty na dvou serverech se stejným tokenem konverzace: doloženo, že
  požadavek jde na vlastní server s vlastním heslem, že přečtený stav jednoho
  účtu nehne druhým a že běžící dotaz jednoho účtu nikdy neodpoví za druhý.
- Audit přístupnosti se rozšířil ze dvou obrazovek na pět skutečných:
  pracovní plocha konverzací, nastavení, diagnostika, detail konverzace
  a potvrzovací dialogy. Nově hlídá i pořadí čtení odečítačem a počet
  živých oblastí, ne jen jména ovládacích prvků.

## 0.1.0 (42) — 2. 9. 2026

Vydáno ze zdroje `9393081`.

Play (uzavřené testování, track alpha): vydání `(42) 0.1.0` je `completed`
s version code 42. AAB má 84 293 448 B a SHA-256
`7b98dbd729171b754e7171cb9c5c9f670bb713795dd0c1181fe60181e6136d08`. Poznámky
v šesti jazycích se po nahrání shodují se zdrojem.

TestFlight: IPA má 30 237 979 B a SHA-256
`7ab21ef2f1648ae05cab61ee312172e133e3a4454a6eb636815c6e919cf2e97c`, delivery
UUID `284a27cd-7cc1-496d-b3ab-02e61767963f`.

Oba artefakty se poprvé staví z ČISTÉHO checkoutu `origin/main`, ne z pracovní
kopie. Ta totiž nese rozdělanou práci jiné větve (iOS Share Extension,
transkripce, lifecycle policy) a lokálně stavěné buildy ji mohly obsahovat —
u tohoto vydání je to vyloučené.

- Pruh „Tento účet je potřeba znovu přihlásit" se vejde na obrazovku i při
  zvětšeném systémovém písmu. Text a tlačítko se dřív tlačily do jedné řady
  a v češtině při dvojnásobném písmu přetekly o 228 px mimo displej; nad
  zhruba 1,3× měřítka se akce teď skládá pod zprávu.
- Uvnitř přibyly tři brány, které tohle hlídají samy: kontrastní matice 28
  barevných dvojic (nejnižší naměřená hodnota 6,4606:1), sonda na přetečení
  rozložení při 200 % textu ověřená proti sobě schválně přeteklým případem,
  a kontrola, že každý ovládací prvek s pouhou ikonou nese jméno pro odečítač
  obrazovky.
- Rozhodnutý offline scope prvního release (Q-004): cache historie, durable
  textový outbox a durable přílohy s obnovou po restartu; ostatní akce
  zůstávají online-only a fail-closed, protože pro ně neexistuje replay
  kontrakt.
- Připravená měřicí vrstva pro výkonové metriky. Zatím nic neodesílá; měřit
  jde jen šest pojmenovaných operací a měření nese pouze jméno operace,
  výsledek a koš trvání, takže do něj nejde vložit účet, room ani adresu.

Zbývá prověřit: při zkoušce na ručně sestaveném potvrzovacím dialogu přeteklo
i to v angličtině, ale měřeno na kopii v testu, ne na skutečné obrazovce —
popsané v `docs/TODO-quality-operations.md`.

## 0.1.0 (41) — 1. 9. 2026

Vydáno ze zdroje `5fd2a0a`.

Play (uzavřené testování, track alpha): vydání `(41) 0.1.0` je `completed`
s version code 41. AAB má 84 291 246 B a SHA-256
`2fdbec524a211642d9109ef0554174404cc90dd8d667d539d8ed4b342cebac6f`. Poznámky
v šesti jazycích se po nahrání shodují se zdrojem.

TestFlight: IPA má 30 237 177 B a SHA-256
`629e358d6ac8a839f0a591373294cf59735c9381dbe62ab00679680338a50bef`. Delivery
UUID i build record jsou `4c804b9b-dd16-4822-9d5e-469fdc920a3f`, stav `VALID`,
minimum iOS 15.0, encryption `false`, obě skupiny `IN_BETA_TESTING` a beta
review `APPROVED`.

Před vydáním prošla celá sada: mobil 1679 testů se 4 přeskočeními, protokol
1026 testů, oboje bez červené. Na Androidu 14 (emulátor, release APK build 41)
je „Otevřené konverzace" v nové konverzaci živě dostupné a referenční server
na dotaz odpověděl, že žádné otevřené konverzace nenabízí — samotné připojení
proto zatím dokládají jen testy, ne živý průchod.

- V nové konverzaci přibyly „Otevřené konverzace". Server ukáže, co zveřejňuje
  jako otevřené, a jedno klepnutí do takové konverzace připojí; chráněná se
  nejdřív zeptá na heslo, které jde v těle požadavku, ne v adrese. Připojení
  se počítá až podle odpovědi serveru, takže chybová odpověď schovaná
  v úspěšném HTTP kódu konverzaci neotevře.
- Aplikace rozumí vzdálenému vymazání účtu. Když správce zařízení vymaže,
  přestane app password fungovat — a protože stejně vypadá i běžně odvolaný
  token, aplikace se serveru zeptá, o co jde. Účet a všechna jeho lokální data
  smaže jen na výslovné potvrzení; nedostupný server, nejasná odpověď ani
  chybějící přihlašovací údaj nikdy nic nemažou.

## 0.1.0 (40) — 1. 9. 2026

Vydáno ze zdroje `ea02f94`.

Play (uzavřené testování, track alpha): vydání `(40) 0.1.0` je `completed`
s version code 40. AAB má 84 214 115 B a SHA-256
`af24c7ed8cc3d381fdbdf04f172e061dcbbfa5b59265337dc4cd4f83fa20a928`. Poznámky
v šesti jazycích se po nahrání shodují se zdrojem.

TestFlight: IPA má 30 214 746 B a SHA-256
`3724174384f3ead271a1020dca55a15f7d9293a0accb1faab18019d699a4a73d`. Delivery
UUID i build record jsou `fbd805e8-3b28-4fe4-9983-e4d9fe96c714`, stav `VALID`,
minimum iOS 15.0, encryption `false`, obě skupiny `IN_BETA_TESTING` a beta
review `APPROVED`.

Živě ověřeno před vydáním na iOS 18.6 simulátoru (build-mac) a na Androidu 14
(emulátor, release APK build 40): menu příloh ukazuje všech sedm položek včetně
ankety a polohy, procházení vlastního Nextcloudu vrátilo skutečné složky
i soubory a na iOS proběhlo celé sdílení souboru do konverzace včetně
potvrzení; testovací zpráva byla potom smazána. macOS a Windows runtime se
ověřit nepodařilo — důvody jsou zapsané v `docs/TODO-platforms.md` a ani jeden
z nich nesouvisí s touto změnou.

- V menu příloh přibyl „Soubor z Nextcloudu". Prochází se vlastní úložiště
  účtu po jedné složce a vybraný soubor se sdílí do konverzace — nenahrává se
  kopie a nevzniká veřejný odkaz. Před odesláním je potvrzení, které říká, že
  soubor zůstává na serveru a účastníci k němu mají přístup, dokud se sdílení
  nezruší v Souborech.
- Menu příloh se přestalo zasekávat. Když se konverzace dozvěděla o anketě
  nebo poloze až po otevření menu, položky se doplnily jen někdy; teď se
  doplní vždy a delší menu jde na krátké obrazovce odrolovat.
- Vlastní nebo self-signed certifikát serveru jde potvrdit při přidávání účtu.
  Aplikace ukáže otisk SHA-256 po dvojicích, aby se dal porovnat s tím, co
  server vypisuje, a teprve po potvrzení se na server něco pošle. Otisk patří
  účtu a s jeho odebráním zmizí; opuštěné přidávání serveru po sobě žádnou
  důvěru nenechá.
- Certifikát, který se u už důvěřovaného serveru změní, se nepřijme a znovu se
  na něj neptá. Obnova certifikátu vypadá zvenku stejně jako útok, takže se
  řeší vědomě: odebráním a novým přidáním účtu.

## 0.1.0 (39) — 1. 9. 2026

Vydáno ze zdroje `daa1039`.

Play (uzavřené testování, track alpha): vydání `(39) 0.1.0` je `completed`
s version code 39. AAB má 84 005 134 B a SHA-256
`92ee4e5e7278474ee1f101e46b06b5af6ae834cd8aeacd59fae721cb79d555fd`, podepsané
upload klíčem `CN=NKS Talk`. Poznámky v šesti jazycích se po nahrání znak po
znaku shodují se zdrojem.

TestFlight: IPA má 30 173 759 B a SHA-256
`6054a93a4bb5d55d67fa24582248fb236eca1344846fd3a8ca0ed21f63e93526`. Delivery
UUID i build record jsou `74a53a71-e81e-426b-9bcb-3a58cb3daf39`, stav `VALID`,
minimum iOS 15.0, encryption `false`, obě skupiny `IN_BETA_TESTING` a beta
review odesláno.

Během přípravy tohoto buildu jsem si sám způsobil regresi: převedení
`loadPreview` na nesynchronní metodu začalo házet výjimku dřív, než ji volající
mohl zachytit ve `Future`. Chytil to existující test
`chat_media_repository_test.dart`, oprava je součástí vydaného zdroje.

- Obrázky a GIFy v otevřené konverzaci už každých pár sekund neproblikávají.
  Náhledy se držely na klíči, který nesl celý řádek účtu, a ten každá
  synchronizace přepsala — obrázek se proto pokaždé stahoval znovu. Klíč teď
  drží jen to, co skutečně určuje stažení.
- Náhled odkazu ukazuje obrázek, když ho server nabídne. Načítá se výhradně
  z vlastního Nextcloudu, který ho proxuje; adresa odkazovaného webu se
  nestahuje, takže otevření konverzace o čtenáři nic neprozradí.

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
