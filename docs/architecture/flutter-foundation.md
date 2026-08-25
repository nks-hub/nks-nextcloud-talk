# Flutter aplikační základ

Datum aktualizace: 25. srpna 2026.

## Stav

V `apps/mobile` existuje spustitelná Flutter aplikace, ne pouze scaffold.
Implementuje řez od přidání serveru po lokálně uložený účet, account-scoped
seznam konverzací a první cache-first chat/thread obrazovku s foreground
pollingem, textovým durable outboxem, emoji a Giphy composerem, obrázkovými a
hlasovými médii i nativní Android Web Push delivery hranicí. Aktuální APK má
ověřený build a aktualizační instalaci. Skutečný Login Flow, živý seznam
konverzací, otevření room a inline animovaný Giphy send patří historickému APK.
Tento Giphy běh používal nyní nahrazenou wire-reference variantu; nový skutečný
`image/gif` attachment tok je od `7ca580e` implementovaný a automatizovaně
ověřený, ale zatím nemá live serverový důkaz.

Celý Nextcloud Talk klient tím ještě hotový není. Aktuální root/thread
cross-device refresh, živá příloha a voice matice, skutečné background/killed
FCM doručení, live read přechod, doložené delivered, presence, dva účty na dvou
serverech a hovory zůstávají otevřené funkční brány.

## Platformy a identita

Jeden Flutter projekt obsahuje targety pro Android, iOS, Windows, macOS a Linux.
Android namespace/applicationId, iOS a macOS bundle ID i Linux application ID
jsou `com.nkshub.nextcloudtalk`. Android build má efektivní minSdk 24; iOS
deployment target je 13.0 a macOS target 10.15.

Aktuální Android debug build se sestavil, aktualizačně nainstaloval a spustil na
`emulator-5554`. Na Windows dříve prošel release build i živý onboarding smoke.
Platformní projekty pro iOS, macOS a Linux existují, ale jejich build na
odpovídajícím hostu zatím není runtime důkazem.

## Implementovaný tok

1. Uživatel zadá Nextcloud URL.
2. Klient ji kanonizuje a načte veřejný `status.php`.
3. Login Flow v2 se otevře v systémovém prohlížeči a poll zůstává svázaný s
   původním originem a base path.
4. Přihlášené capabilities musí potvrdit Talk a `conversation-v4`.
5. App password se uloží do platformního secure storage; Drift drží jen
   account-scoped metadata.
6. Conversation sync používá mode-aware per-account single-flight a atomický
   full/delta merge z `talk_protocol`; foreground loop je incremental a ruční
   refresh vynutí full reconciliation.
7. UI pozoruje Drift a nikdy nepoužije aktivní účet jako globální autoritu pro
   jiný account scope.
8. Otevřený chat nebo thread spustí scope-bound foreground binding; přijatá
   response se nejdřív commitne do Drift a teprve pak přes Riverpod překreslí
   `ChatRoomPane`.
9. Vybraná Giphy URL je pouze vstup account-scoped References resolveru. Klient
   přijme validní `image/gif` bajty, uloží je do durable app-owned zdroje a
   odešle standardním Talk Draft/WebDAV/finalize attachment tokem. URL nevstoupí
   do textového composeru, `sendText` ani textového outboxu.
10. Android UnifiedPush callback validuje wake-up payload, uloží ho do šifrované
    account-scoped fronty a tap předá do Flutteru přes jednorázový token. Zdroj
    pravdy po probuzení zůstává OCS, ne push payload.

Drift schema v4 ukládá u room `avatarVersion` a `isCustomAvatar` a drží avatar
bytes pod `(accountId, URI)`. Verzované URL se považují za immutable, neverzované
se po expiraci revalidují přes ETag a při offline chybě zůstane dostupná stale
cache. Metadata z `X-NC-IsCustomAvatar` rozhodují, zda se vykreslí vlastní image,
nebo lokální fallback ikona/iniciály. Migrace v2 → v4 backfilluje room metadata;
v3 → v4 zahodí cache, u které custom původ nebylo možné bezpečně určit.

Ruční refresh posílá full conversation request bez `modifiedSince`, takže může
odstranit stale room chybějící v autoritativním seznamu. Periodický foreground
loop po získání cursoru zůstává incremental. Pokud manual full přijde za
rozběhnutou deltou, počká a následně spustí nebo joinne vlastní full flight.
Smazání je account-scoped a nesmí odstranit pending outbox ani stejný token
jiného účtu; full-empty stále vyžaduje dva různé full requesty v ochranném okně.

Chyba před dokončením secure a databázového commitu nezanechá napůl vytvořený
účet. Chybějící credential, Talk nebo conversation-v4 se projeví explicitním
stavem a nespustí nepodporovaný endpoint.

## Chat a thread UI

Telefonní route i expanded detail používají stejný `ChatRoomPane`. Produkční
widget zobrazuje cache-first timeline, GFM/Rich Object obsah, obrázky, reakce,
reply preview, participant avatary, stav outboxu a composer pro text, emoji,
Giphy, obrázek a voice. Nový Giphy výběr se po resolve a validaci předá do
stejného durable attachment toku jako `image/gif`; wire URL se nesmí vytvořit
jako nová zpráva. Historický URL renderer zůstává pouze pro kompatibilní čtení
starších zpráv. Root a každý thread mají samostatný
`(accountId, roomToken, threadId|null)` scope. Platné nové vlákno lze otevřít i
před první odpovědí.

Dva widget-integration testy používají produkční `ChatService`, HTTP adapter,
Drift repository a Riverpod projekci s deterministickým `MockClient`. Pro root
i thread ověřují future requesty `timeout=0 → 30 → 0`, přijetí cursoru 120,
konvergentní stav po následném `304`, zobrazení externí zprávy a prázdný opačný
scope. Jde o automatizovaný wire-adapter důkaz, ne o skutečný serverový socket
nebo web↔emulátor E2E.

Thread-scoped merge zároveň obnovuje cached original z úplného embedded parentu
jen při přesné shodě room/thread identity. Chybí-li serverové `threadReplies`,
repository odvodí počet z unikátních scoped reply ID, vynechá original a replay
a nesníží vyšší cached počet. Explicitní serverový počet zůstává autoritativní.
Repository test prošel 7/7 a zachoval reply mimo root timeline.

Composer rozlišuje obyčejný reply thread a serverový named thread. Reply
odesílá `replyTo`; named thread pod lokální capability `threads` odesílá pouze
`threadId`. Text-send replay contract r2, HTTP adapter a Drift schema v5 tuto
vazbu zachovají. File-backed reopen test drží queued i sending `threadId`,
restart recovery převádí přerušený `sending` na `awaitingConfirmation` a
správně svázaná named-thread confirmation atomicky aktualizuje cached root
`threadId`, `isThread` a `threadReplies`. Přímá response je parentless;
history/future confirmation smí nést přesně svázaný full root nebo compact
deleted root. Tento řez zatím nemá live serverový ani aktuální APK důkaz.

## Historický Android Giphy wire-reference runtime

Debug APK v
`apps\mobile\build\app\outputs\flutter-apk\app-debug.apk` má SHA-256
`0d38d4ab2a665883d0ee0de7426f201c107cefc6b5f7e701b1c856255f6195cf`
a velikost 203 683 536 B. Artefakt odpovídá commitu `5f6e2f4`. Dne 25. srpna
2026 bylo aktualizačně nainstalované na
`emulator-5554` přes `adb install -r`; SHA-256 nainstalovaného `base.apk` je
shodný.

Na tomto hashi skutečně prošel Login Flow v2 včetně druhého faktoru a schválení
přístupu, načetl se přihlášený seznam konverzací a otevřel room detail. Účet
přežil další aktualizační instalaci i ukončení a nový start procesu. Dva měřené
cold starty skončily za 5 094 ms a 4 587 ms.

Giphy wire-reference send v otevřené room zobrazil animovaný GIF inline bez
viditelné nebo klikací URL. Dva časově oddělené cropy měly rozdílné hashe, takže
nešlo o statický náhled. Po ukončení procesu zůstala wire-reference zpráva
uložená a znovu se vykreslila. Po cold startu trvalo načtení vzdáleného média
přibližně osm sekund; krátký banner o dočasně nedostupném chatu po retry zmizel.
To je známý runtime signál pro další diagnostiku, ne ztráta zprávy.

Tento běh je důkazem historického rendereru, nikoli nového Giphy attachment
toku. Nové odeslání musí skončit skutečnou `image/gif` přílohou přes
Draft/WebDAV/finalize; commity `5d49cbb` a `9de5727` zatím dokazují pouze
přípravu bajtů a admission do media composeru.

Tento běh ještě neprokazuje živý Giphy/image/voice attachment send a viewer,
cross-device root/thread refresh ani skutečný Nextcloud → FCM tok v
background/killed procesu.

## Historický post-review Windows release runtime smoke

Flutter 3.44.4 sestavil 24. srpna 2026 Windows x64 release bundle za 76,7 s nad
source snapshotem se 150 vstupy SHA-256
`847e81f27311e5ce1ae37169e989a3dab497825aa21f3c53f1c722b1bd98030d`, který
zůstal před i po buildu shodný. Spuštěný `nextcloudtalk.exe` měl SHA-256
`5339f4f0d8caf04da2152a2ca5ddf32cd2ff9f26e259a24660e764c84a43af9e`
a Dart AOT `data/app.so` SHA-256
`01a4cb3cf65bc4f4147e741a9deb1fd584c169ff275105d6eae4da64dfeffa62`.
Proces v okně `NKS Talk` zobrazil tmavý expanded onboarding „Všechny konverzace
v jedné aplikaci“ a po 356,7 s byl stále živý a responsivní. Manifest 17 souborů
release bundlu byl znovu ověřený 17/17 bez chyb; redigované runtime metadata a
screenshot jsou v ignorované složce
`.artifacts/windows-smoke-post-review-20260824-142126`. Všech 10 JSON evidence
souborů se parsuje, screenshot je platný 1920×1032 PNG a build log neobsahuje
warning, error, failed ani exception. Scan deseti textových důkazů proti sedmi
secret/path vzorům měl 0 nálezů.

Tento smoke neměl uložený účet ani credentials. Neověřuje proto Login Flow,
secure storage, chat, dva servery, restart/upgrade, installer ani signing.
Windows UI Automation viděla jen kořen Flutter okna a žádné potomky, takže z
tohoto běhu nelze tvrdit Windows screen-reader nebo keyboard accessibility.

## Historický reálný thread smoke

Předchozí debug APK SHA-256
`<fingerprint>`
bylo 24. srpna 2026 aktualizačně nainstalované na `chatujmePixel`. Cold start
zachoval autentizovaný účet. Existující thread se otevřel z root timeline přes
`Open thread` a anonymizovaný scénář prokázal:

- jedna nová webová thread reply se ve foreground Flutteru zobrazila za 2,3 s;
- thread root byl vykreslen právě jednou;
- redundantní parent preview se nevykreslilo ani jednou;
- nová reply se neobjevila v root timeline;
- počítadlo odpovědí u kořene se aktualizovalo na 4.

Tento historický smoke neprokazuje stejné chování na novém post-review APK,
opačný směr z Flutter composeru do webového Talk ani celý obousměrný E2E.

## Historické UI, kontrast a avatary

Installed `base.apk` načtené ze zařízení má podle `sha256sum` přesně stejný
SHA-256 jako tehdejší lokální build:
`<fingerprint>`.

Harness pro tento hash vytvořil light, dark a light-200-percent capture. Všechny
tři snímky vizuálně zobrazují thread, datum, root, 4 odpovědi a composer bez layout
vady. Explicitní pixelový report prošel 24/24:

- minimum textu 7,2725:1 při limitu 4,5:1;
- minimum UI 3,252078:1 při limitu 3:1.

Redigovaný process-scoped logcat nemá warning, error, fatal ani známou UI
diagnostiku. Harness po běhu skutečně obnovil původní stav zařízení:
`night=yes`, `font_scale` znovu unset/null a proces aplikace běží.

Runtime seznam konverzací zobrazil 9 viditelných tiles a 9 avatarů: 3 síťové
obrázky, 4 fallback ikony a 2 iniciály. Skutečná příchozí skupinová zpráva měla
participant avatar; outgoing-only testovací thread správně avatary nezobrazuje.
Samostatný avatar pixelový report prošel 4/4 s minimem UI ikony 7,2725:1 a
textu iniciály 7,2739:1.

## Historický obousměrný thread baseline

Starší debug APK SHA-256
`1c4372cad3bbf3f7b1d56664c5da9f353be24bb2b456a919b2393cd6879ba861`
24. srpna 2026 prokázalo dvě webové replies v různých polling cyklech, jejich
nepřítomnost v root timeline a reply z Flutter thread composeru doručenou do
webového Talk. Tento běh zůstává historickým transportním baseline; změny v
předchozím runtime APK ani v aktuálním buildu jím nejsou znovu ověřené.

Testovací room token ani texty zpráv se do dokumentace neukládají. Dočasná room
byla 2026-08-24 přes trvalou webovou E2E relaci odstraněná; následný snapshot
ověřil její nepřítomnost v seznamu a zachování přihlášené relace.

## Adaptivní rozložení

Telefon pod 720 logical px používá kompaktní stack. Od 720 px se zobrazí tři
panely v pořadí account rail, seznam konverzací a detail. Seznam má 330 px a od
1100 px 390 px; detail spotřebuje zbývající prostor. Onboarding přechází od
900 px z vertikálního toku na úvod a serverovou kartu vedle sebe.

Stejný widget strom slouží tabletu, foldable i desktopu. Desktop není druhá
aplikace a nesdílí data přes další serverovou službu. Klávesové zkratky,
system tray, auto-start a doručování při úplně ukončené desktop aplikaci zatím
nejsou implementované a nesmějí být vydávány za hotové.

## Runtime a testovací důkaz

- Flutter analyze na commitu `5f6e2f4`: 0 nálezů.
- Souhrnný Flutter gate na commitu `3c74165`: 354 úspěšných testů, 1 read-only
  live test přeskočený pouze bez environment credentials a 0 selhání.
- Historická přesná Giphy wire oprava `5f6e2f4`: 11/11 cílených a 75/75 širších
  chat/Giphy testů. Nejde o důkaz nového attachment toku.
- Nové Giphy attachment propojení `7ca580e`: celý
  `chat_composer_integration_test.dart` 4/4, loader/media composer 15/15 a
  scoped analyze změněných souborů bez nálezu. Test ověřuje nulový Giphy
  text-send, přesné uploadované bajty a Talk finalize hashovaného `.gif` názvu.
- Server-backed read a silent background polling `e4840e5` + `02b79eb`:
  status/live-sync sada 11/11 a scoped analyze pěti změněných souborů bez
  nálezu. `read` vyžaduje server-confirmed message a common-read cursor;
  `delivered` se nevytváří.
- Android Web Push koordinátor `c37bf66`: coordinator 21/21, push/API 39/39,
  celý Flutter analyze a debug APK build prošly. Retry je account-scoped,
  exponenciálně omezený a jen pro doložené transientní chyby; skutečný provider
  delivery tím není prokázaný.
- Celý `talk_protocol`: 569/569; čerstvá cílená conversation sada 25. srpna
  2026: 74/74.
- Čerstvá scoped Flutter foundation/conversation sada: 60 PASS, 1 read-only
  live SKIP pouze bez environment credentials. Zahrnuje onboarding, account
  repository, HTTP adaptér, Drift migrace, full/delta sync, foreground loop,
  avatary a adaptivní shell.
- Android Web Push native gate na commitu `3c74165`: Kotlin unit 16/16 a
  connected test na `emulator-5554` 15/15. Callback je v testu injektovaný;
  nejde o důkaz skutečného provider delivery.
- Avatar repository/widget a migrace navíc ověřují immutable versioned cache,
  ETag revalidaci, offline stale fallback, izolaci stejné URL mezi účty,
  generated/custom vykreslení a upgrady v2/v3 → v4.
- Aktuální Android debug APK build a `adb install -r`: úspěšné. Lokální i
  nainstalovaný artefakt mají SHA-256
  `0d38d4ab2a665883d0ee0de7426f201c107cefc6b5f7e701b1c856255f6195cf`.
- Na historickém APK prošel skutečný Login Flow, seznam konverzací, otevření
  room, inline Giphy wire-reference send a process-death návrat. Dva cold starty
  trvaly 5 094 ms a 4 587 ms.
- Historický Windows x64 release build a onboarding runtime: úspěšné; EXE
  SHA-256
  `5339f4f0d8caf04da2152a2ca5ddf32cd2ff9f26e259a24660e764c84a43af9e`,
  Dart AOT SHA-256
  `01a4cb3cf65bc4f4147e741a9deb1fd584c169ff275105d6eae4da64dfeffa62`,
  17/17 bundle hashů a 356,7 s responsivního procesu.
- Předchozí APK hash
  `<fingerprint>`
  historicky prokázal cold start, otevření threadu,
  příjem nové webové reply za 2,3 s a root/thread izolaci. Obousměrný web round
  trip je doložený jen ještě starším APK uvedeným výše.
- Předchozí hash
  `<fingerprint>` má
  historický light/dark/200% thread pixelový report 24/24 PASS, avatar report
  4/4 PASS a redigovaný process logcat bez
  varování, chyb a UI diagnostik. Aktuální hash tento historický důkaz nepřebírá.
- Historický Windows debug `kernel_blob.bin`: SHA-256
  `78fc9e2a9b104eb3ac4da54887e9741c15be1d524b89edd5ff11c9f0473432a0`.

Debug cold start není release výkonový benchmark. Skutečné Nextcloud → FCM
doručení v background/killed procesu, změny reálného rádia a dlouhodobá spotřeba
musí projít fyzickým Android zařízením.

Widget a11y kontrakty ověřují, že vybraný room je jediný označený semantic
button se stavem selected, hodnotou preview/čas/unread a cílem nejméně 48 dp.
Chat header a composer rostou při 200% textu, avatar vedle viditelného autora
nevytváří duplicitní image uzel a inline odkaz je jediný semantic link s tap
akcí, cílem nejméně 48×48 dp a zalomením při 200% textu. Composer má právě jeden
pojmenovaný editovatelný semantics node se `setText` a tap akcí. Tyto testy
nenahrazují skutečně vyslovený TalkBack ani runtime screenshot.

## Historický thread kontrast, 200% text a TalkBack

Následující důkaz patří ke staršímu APK SHA-256
`1c4372cad3bbf3f7b1d56664c5da9f353be24bb2b456a919b2393cd6879ba861`.
Reálné screenshoty `nctalk-thread-light-final.png` a
`nctalk-thread-dark-final.png` jsou v ignorované lokální `.artifacts` složce;
kvůli testovacím datům se necommitují. PIL výpočet nad skutečnými pixely naměřil:

| Prvek | Světlý motiv | Tmavý motiv |
| --- | ---: | ---: |
| text zprávy | 7,27:1 | 7,27:1 |
| čas | 5,03:1 | 5,55:1 |
| autor reply | 9,40:1 | 11,63:1 |
| text reply | 9,36:1 | 11,61:1 |
| systémová zpráva a datum | 8,88:1 | 11,15:1 |
| primární prvek | 6,16:1 | 11,17:1 |
| send ikona | 6,50:1 | 7,77:1 |
| header | 16,24:1 | 14,62:1 |
| separator | 3,25:1 | 3,36:1 |

Světlý composer border měl 6,50:1. Měřený thread tedy splnil minimum 4,5:1
pro text a 3:1 pro UI prvky v obou motivech na tomto starším APK.

Screenshot `nctalk-thread-light-font200.png` zachycuje skutečný font scale 2,0.
Zprávy se zalomily, header i composer zůstaly dostupné a logcat neobsahoval
RenderFlex ani jinou layout chybu.

TalkBack služba byla skutečně bound a `touchExplorationEnabled=true`. Flutter
semantics test potvrzuje právě jeden pojmenovaný editovatelný composer node se
`setText` a tap akcí. Flutter Android AccessibilityBridge mapuje label/hint
textového pole do `AccessibilityNodeInfo.hintText`, zatímco uiautomator XML
`hintText` neserializuje; jeho `NAF=true` je proto false positive. Následná
dočasná UiAutomator JAR sonda mimo repo četla přímo `AccessibilityNodeInfo` a
prošla 1/1: `editorCount=1`, `hintMatchesExpected=true`, hint měl délku 15
(`Write a message`), `editable=true` a click akci. Text i `contentDescription`
byly podle bridge prázdné. Před a po sondě byly accessibility hodnoty přesně
`0/null/0/null`; APK ani app data se neměnily a host/device temp artefakty byly
odstraněné. Runtime platformní název composeru je tedy PASS. Zvukové vyslovení
TalkBack nebylo odposlechnuté a širší screen-reader navigace zůstává otevřená.

`mobile_audit.py` vrátil 48 heuristických regex shod. Manuální kontrola proti
widgetům, semantics dumpům a runtime výsledku je potvrdila jako false positives.
Skript zůstává podpůrný signál, nikoli pass/fail brána; rozhoduje kombinace
testů, ručního auditu, runtime a pixelového měření.

## Foundation kontrastní důkaz

Světlý i tmavý onboarding prošel screenshotem reálného Android běhu. Windows
release smoke samostatně zachytil tmavý expanded onboarding, ale neobsahoval
pixelové WCAG měření ani accessibility tree potomků. Následující pixelový
výpočet po složení skutečných barev patří Android důkazu:

| Prvek | Světlý motiv | Tmavý motiv |
| --- | ---: | ---: |
| hlavní text | 16,24:1 | 14,62:1 |
| sekundární text | 8,88:1 | 11,15:1 |
| obrys karty | 3,43:1 | 3,50:1 |
| obrys pole | 4,97:1 | 4,36:1 |
| text tlačítka | 6,50:1 | 7,77:1 |

Jednopixelový obrys se na reálném rasteru skládal do dvou polovičních pixelů a
nedosáhl 3:1. Produkční motiv proto používá dvoupixelový obrys pro pole, karty a
outlined tlačítka a test tento minimální width hlídá. Předchozí runtime APK má
vlastní light/dark a 200% thread runtime i pixelový důkaz výše. Aktuální APK ani
další obrazovky tento historický důkaz nepřebírají.
Historický
runtime `getHintText` důkaz
composeru prošel;
screen-reader brána dál čeká na zvukové vyslovení a širší TalkBack/VoiceOver
navigaci, ne na opravu composer semantics.
