# Technická rozhodnutí

[Zpět na rozhodnutí a otevřené volby](decisions.md)


### D-007: Modulární klient

Stav: Přijato pro první implementační baseline 22. srpna 2026.

Pure Dart `talk_protocol` + Flutter app. Storage a sync zůstávají uvnitř app,
dokud další skutečná implementace neodůvodní package. Android Web Push používá
embedded distributor bez projektové gateway; budoucí iOS APNs/PushKit relay je
samostatná Apple platformní hranice, ne součást klientského runtime.

### D-008: Standardní Notifications app

Stav: Přijato jako kompatibilní serverová hranice; Android transport zpřesňuje
D-025.

Android používá přímo standardní Notifications Web Push. Nový Talk event
listener ani tenký bridge se nevytváří, protože by nepokryl úplnou notification
a markProcessed/delete semantiku. Historický Notifications push-v2 gateway
kontrakt zůstává výzkumným důkazem, ne povinnou službou.

### D-009: Relační SQLite store

Stav: Přijato pro první implementační baseline 22. srpna 2026.

Message, thread, parent, room a read marker vyžadují atomické transakce.
Použije se Drift. Lokální Flutter 3.44.4/Dart 3.12.2 a pub.dev metadata z
22. srpna 2026 potvrzují kompatibilitu řad Drift 2.34 a `drift_flutter` 0.3.
Flutter aplikace nyní uzamyká Drift 2.34.3 a `drift_flutter` 0.3.1, používá
account-scoped tabulky a transakční conversation merge. Android a Windows
debug build i repository testy prošly; message/outbox migrace a Apple/Linux
build zůstávají povinným důkazem dalších řezů.

Drift volá `onUpgrade` také při downgrade. Migrační strategie proto jako první
odmítne `versionBefore > schemaVersion`; starší build nesmí přepsat
`PRAGMA user_version` novější databáze ani nad neznámým schématem pokračovat.
File-backed test kontroluje nejen chybu při open, ale také zachování původní
verze a dat po odmítnutém rollbacku.

Talk neposkytuje seznam identit čtenářů. `lastCommonReadMessage` je room-wide
minimum markerů pouze public user actors; guesté do něj nevstupují. Klient smí
agregovaný stav ukázat jen u vlastní serverem potvrzené zprávy, pokud současný
account současně prokazuje capability `chat-read-status` a public
`config.chat.read-privacy`. Private, chybějící nebo nevalidní policy marker
explicitně zneplatní; absence hlavičky nesmí ponechat stale „přečteno“.
Invalidace uloží sentinel 0 atomicky do chat scope i cached conversation a
reprojektuje outgoing UI zpět na `sent`. Pozdější public snapshot bez nového
serverového markeru nesmí historickou hodnotu obnovit.

### D-010: Riverpod pro application/UI state

Stav: Přijato pro první implementační baseline 22. srpna 2026.

Chatujme poskytuje ověřený lokální vzor a Riverpod umožní account-scoped
providery. Databázový stav však zůstává zdrojem pravdy; provider nesmí duplikovat
sync store. První řez použije ručně definované providery bez code generation;
generátor se přidá jen tehdy, když sníží skutečnou složitost.

### D-019: Adaptivní navigace a form factors

Stav: Přijato jako mobilní implementační baseline.

Telefon používá stack `onboarding → conversations → chat → thread`. Bottom
navigation se nepřidá bez alespoň tří rovnocenných top-level cílů. Tablet,
foldable a desktop použijí nad stejným route modelem adaptivní list-detail.
Od 720 logical px se zobrazí account rail, seznam a detail; onboarding přechází
od 900 px do dvou sloupců. Deep link
nejprve kryptograficky nebo lokálním account mappingem vybere `accountId` a až
potom sestaví room/thread stack; nesmí implicitně použít právě aktivní účet.
Unified-search výsledek stejně zachová vlastní account, room, message a
canonical thread identitu. Root výsledek otevře room scope, reply otevře
ordinary nebo named thread podle validního cached rootu a chybějící či neshodný
root se fail-closed neotevře v jiném scope. Jump loader musí cíl zkontrolovat i
po posledním povoleném history fetchi, ne jen před ním. Každé asynchronní
dokončení je navíc svázané s route identitou, generací a účtem; výsledek starší
search navigace nesmí ovládat novější route ani po opožděném history fetchi.

iOS zachová edge-swipe back a Android systémový i predictive back. Gestures
jsou pouze zkratky s viditelnou alternativou. Touch target má nejméně 44 pt na
iOS a 48 dp na Androidu. Podrobný checkpoint je v
[mobilním návrhu](../plans/2026-08-22-original-flutter-client-design.md).

Windows, macOS a Linux nejsou samostatný klient. Stejná Flutter codebase musí
navíc projít změnou velikosti okna, klávesovou navigací, focus/hover stavy a
buildem na každém cílovém OS. Aktuální foundation prokazuje rozložení a Windows
runtime, ne všechny desktop lifecycle funkce.

### D-020: Rich chat jako typovaná online mutation hranice

Stav: Přijato a implementováno v pure Dart runtime; Flutter transport, Drift a
live serverový důkaz zůstávají součástí řezu 4.

Mentions, threads, reactions, edit/delete, pin, reminders a schedule se volí
výhradně z unikátních globálních a lokálních Talk features. Každý request i
response je svázaný s účtem, kanonickým serverem a dostupným room/message/thread
kontextem. Rich stav je account-scoped vrstva nad existujícím chat snapshotem a
mění se jen přes single-use candidate plán.

Nested `first` a `last` zprávy thread metadata jsou důvěryhodné jen při shodě
room tokenu a canonical `threadId`. `first.id` musí být root threadu a
`last.id` musí odpovídat `lastMessageId`; obě zprávy musí nést stejný canonical
`threadId`. Metadata-only rename v jednom candidate reprojektuje nový title do
cached first/last/root, všech jejich parent kopií a immutable wire reprezentací.

Markdown se nepropouští přímo do Flutter widgetů. Balíček `markdown` vytvoří
AST a vlastní renderer jej převede na bounded semantic tree s typovanými Rich
Object Strings, neaktivním raw HTML a same-origin link policy. Plaintext i
Markdown sdílí node budget, který se spotřebuje před konstrukcí semantic uzlu;
pozdní kontrola již materializovaného stromu není bezpečnostní hranice.

Autoritativní reaction/edit/delete odpověď se v jednom candidate plánu
propaguje do kanonické zprávy, každé reply a scheduled parent kopie, thread
first/last, room preview a jejich immutable wire reprezentace.

Rich mutace jsou v tomto řezu pouze online. Nejednoznačný výsledek se
automaticky neopakuje a nezapisuje se do text-send outboxu. Offline replay smí
vzniknout až samostatným kontraktem pro každý operation kind podle D-006.

### D-021: Příloha jako potvrzovaný durable dvoufázový job

Stav: Přijato a implementováno v pure Dart runtime, Flutter HTTP transportu,
Drift job store a orchestraci; kombinovaný live-server/process-death a
platformní lifecycle důkaz zůstávají součástí řezu 5.

Příloha používá jeden durable job pro Talk OCS Draft probe, WebDAV normal nebo
chunk upload, Talk finalize a následné potvrzení chatem. Job smí držet pouze
app-owned kopii nebo persistable URI grant a před každým uploadem či resume
znovu ověří velikost a SHA-256. Source mismatch nesmí pod původním
`referenceId` odeslat jiný obsah.

Chunk v1 nepoužívá HTTP `Range`; byte rozsah je jen v názvu chunku a `MOVE`
vždy posílá přesný `OC-Total-Length`. XML multistatus je UTF-8-only, odmítá DTD
a entity a má průběžný byte, depth a node limit.

Upload cílovou path nikdy nepřepisuje. Normal PUT používá
`If-None-Match: *`, chunk MOVE `Overwrite: F` a HTTP 412 je typovaná kolize,
po které job durable zvolí další z nejvýše 16 kandidátních názvů. Cizí
kolidující path se nesmí mazat ani při pozdějším cancel nebo cleanupu.

Finalize není atomický. Úspěšná response, 5xx, ztracená response, možná
odeslané body i restart ve `finalizing` vedou do `awaitingConfirmation`, nikdy
k blind POSTu. Job dokončí právě jedna account/server/room/reference-bound
`file_shared` zpráva se správným `comment` nebo `voice-message` typem a file
rich objektem. Nula shod není důkaz neprovedení a více shod zůstává ambiguous.

Ordinary reply smí po ambiguous finalize nebo restartu přijmout compact deleted
parent jen při přesném `parent.id == replyTo`, chybějících parent room/thread
metadatech a kladném outer `threadId`. Named thread má oddělený deleted-root
shape svázaný s canonical rootem. Klient po restartu neopakuje finalize POST;
čeká na autoritativní catch-up a právě jedna shoda dokončí job i jednorázový
cleanup jeho durable source.

V jedné room platí FIFO a single-flight pro finalizaci. Cancel před finalize
uklízí pouze jobem vlastněnou chunk session a Draft temp soubor; po zahájení
finalize se možný finální soubor automaticky nemaže.

Flutter transport otevře app-owned zdroj jednou, ověří celý snapshot a pro
jednotlivé chunky vyžaduje efektivní bounded range read bez lineárního zahazování
předchozích bytes. Cancel, timeout a close jsou odpojitelné a pozdě získaný lease
se zavře. Cleanup má společný bounded budget, ale po selhání jedné akce pokračuje
dalšími kroky; žádný tento transportní důkaz zatím neprokazuje Drift resume ani
skutečný serverový upload.

### D-022: Oddělené signaling transporty a ephemeral session epoch

Stav: Přijato pro implementaci řezu 10.

Internal OCS long poll a external HPB WebSocket mají samostatný wire profil a
reconnect semantiku. Sdílejí account-scoped preparation coordinator,
participant snapshot a topology model, ne společnou frontu JSON zpráv.

HPB resume se používá pouze ve 30sekundovém serverovém okně a musí zachovat
signaling session ID. Full hello vytvoří novou session epoch, zahodí staré
participant/room potvrzení a všechny pending peer frame a vyžádá nový room
join. Signaling frame jsou ephemeral a nikdy netvoří durable outbox.

Stav `signalingReady` není `mediaReady`. Řez 10 nevystaví call REST mutaci ani
uživatelské call ovládání; serverové in-call flags vzniknou až s reálným media
enginem v řezu 11.

### D-023: Per-account push key handle a společný Dart orchestrátor

Stav: Nahrazeno pro Android rozhodnutím D-025. Implementovaný pure Dart
Notifications push-v2 runtime zůstává historickým protokolovým důkazem a
podkladem pro budoucí iOS relay, ale neřídí Android delivery.

Jeden provider token vydaný Firebase/APNs projektem aplikace smí obsluhovat více
účtů, ale není jejich identitou. Každý `accountId` má samostatný
neexportovatelný RSA-2048 key handle, public key, generaci a registrační revizi.
Private key neopouští Android Keystore nebo iOS Keychain; Dart dostává pouze
handle a kryptograficky ověřený výsledek.

Pure Dart runtime vlastní jednu deterministickou single-flight registrační
frontu, authority/token/key binding, přesný retry, 409 recovery a revokaci.
Příchozí obálku smí doroutovat jen právě jeden kandidát s platným podpisem a
decryptem. Dokončení se před routováním znovu porovná s aktuálním provider
tokenem, registered stavem, key handle/generací a registration revision. Nula,
více nebo zastaralý kandidát nevybere účet ani nespustí OCS sync.

Capability disable zachová account key pro případné znovuzapnutí. Odebrání účtu
provede Nextcloud unregister, gateway unregister a teprve potom zničení klíče.
Transientní vzdálený cleanup zůstává jako durable account-bound revocation
tombstone; capability refresh nesmí změnit dříve vyžádaný logout na pouhé
vypnutí push. Druhý účet ani společný provider token se nesmí odstranit.

### D-024: At-least-once push delivery a idempotentní mobilní zpracování

Stav: Nahrazeno pro Android na transportní hranici D-025. Obecný požadavek na
idempotentní mobilní zpracování duplicit zůstává platný; gateway queue část se
na Android Web Push nepřenáší.

Opakovaný `/notifications` batch se deduplikuje před durable enqueue podle
registrace a digestu opaque obálky. Provider worker používá bounded lease a
at-least-once retry. FCM neposkytuje aplikační idempotency key, takže crash po
provider ACK a před lokálním commitem může stejnou obálku doručit znovu;
gateway nesmí deklarovat exactly-once.

Gateway uzná položku jako přijatou až po DB commitu. Notifications na ověřeném
SHA po transportní chybě stejný batch aplikačně neopakuje, takže in-memory nebo
předčasně potvrzený enqueue by wake-up nevratně ztratil.

Mobil po kryptografickém account routingu počítá SHA-256 přes přesné dešifrované
payload bajty a ledger klíčuje dvojicí accountId + fingerprint ve stejném
AES-GCM state commitu jako event frontu. Payload s `nid`, `nids` nebo activation
tokenem má strong TTL 7 dní; delete-all a Message bez serverového ID jsou weak
jen 60 sekund. Ledger je omezený na 128 položek na účet a 512 globálně. Starý
state bez ledgeru se načte jako prázdný. Opakování může bezpečně spustit OCS
catch-up, ale nesmí enqueueovat, zobrazit ani zmutovat druhou událost.

### D-025: Android přes Notifications Web Push

Stav: NAHRAZENO D-038 27. srpna 2026. Web Push zůstává jako přepínatelná
záloha, ale výchozí transport na Androidu je od té doby vlastní proxy a FCM.
Vše níže popisuje tu záložní větev, ne výchozí stav.

Původní stav: Přijato po ověření Nextcloud Notifications 34.0.3 na SHA
`2a62d472d31b97de522c897c979912cd49b820a9`; P1 platformní příjem a durable
lifecycle jsou implementované, serverová P2 orchestrace a delivery E2E chybějí.

Android používá capability `webpush`, UnifiedPush connector baseline 3.3.5 a
embedded FCM distributor 3.1.0. Upgrade v `1250c44` zachoval stávající API,
ověřenou Apache-2.0 licenci i oddělenou verzi distributoru a prošel Kotlin
testy, compile, duplicate-classes kontrolou i `assembleDebug`. Server dodá
VAPID public key, klient získá
subscription endpoint a dokončí register → activation token → activate tok za
běhu pro každý `accountId`.

Správce Nextcloudu Web Push výslovně zapne přepínačem v Administration →
Notifications; nezadává FCM credentials ani gateway. Klient každému účtu přidělí
vlastní connector instance a subscription generation. Callback se přijme jen
pro právě aktuální dvojici a poté spustí account-scoped OCS catch-up.

Android platformní notification ID není serverové `nid` ani globální konstanta.
Šifrovaný bounded ledger mapuje `(accountId, nid)` na stabilní kladné ID,
vynechává rezervované hodnoty a při hash kolizi deterministicky hledá další.
Tap, reply, read, delete-one i delete-all nejdřív resolveují stejnou account
route; nikdy nesmí zrušit ani otevřít notifikaci jiného účtu. Upgrade starého
state bez ledgeru začíná prázdnou mapou a zachová ostatní push stav.

V záložní Web Push větvi nepotřebuje veřejný Android build publisher Firebase
projekt, `google-services.json`, vlastní mobilní gateway ani per-server
rebuild; výchozí proxy větev podle D-038 je naopak má. Embedded distributor je
knihovna uvnitř APK, ne další aplikace. Nextcloud 34+ nepotřebuje addon;
případný Nextcloud 33 backport musí být úplná samostatná AGPL implementace Web
Push, nikoli tenký bridge.

Duplicitní nebo opožděný payload smí pouze idempotentně probudit account-scoped
OCS catch-up. Subscription endpoint, auth secret, activation token ani payload
se nesmějí logovat. Přesný tok a testovací matice jsou v
[push analýze](../research/push-fcm.md).

Pokud přihlášené capabilities `webpush` neobsahují, klient nesmí číst VAPID,
žádat notification permission ani zahájit registraci. Existující aktivní nebo
rozpracovaná generace se durable převede do server-revoke-pending a credentialed
OCS DELETE se smí opakovat pouze idempotentně. Lokální retire/unregister je
povolen až po HTTP 200/202; transientní chyba ponechá credential i generaci pro
bounded account retry.

Nativní P1 adapter ukládá callback synchronně do AES-GCM obálky chráněné Android
Keystore a až potom oznamuje Dartu dostupnou událost. Endpoint commit je
oddělený od event `ack`. Náhrada subscription používá make-before-break:
starou generaci lze nativně odregistrovat až po potvrzeném serverovém revoke.
Samovolný distributor unregister nelze znovu otevřít pod stejnou generací.
Pozdní endpoint ani jeho pozdní commit po `UNREGISTERED` proto nesmí obnovit
generation nebo přepsat ID posledního serverem potvrzeného endpointu.
Tyto invarianty mají focused Dart/Kotlin testy a dvoukrokovou instrumentaci po
ukončení procesu; neprokazují zatím OCS aktivaci, lokální notifikaci ani
background/killed payload ze skutečného Nextcloudu.

Provider ACK není zdrojem pravdy pro obsah notifikací. Každý aktivní účet proto
provede bounded OCS reconciliation po foreground/resume, po návratu connectivity
a nejvýše po šesti hodinách. Wake-upy se coalescují globálně i per account;
transientní sync chyba se retryuje, ale jedna chyba nesmí blokovat jiný účet.
Odebrání účtu nejdřív zvýší epochu a suspenduje jeho lane. Pozdní lifecycle nebo
notification-open callback se starou epochou pak nesmí znovu spustit registraci
ani catch-up před dokončením revokace.

Tato garance začíná až callbackem connectoru. Embedded FCM distributor 3.1.0
potvrzuje provideru GMS broadcast/RPC dříve, než zprávu předá aplikačnímu
receiveru; současný build proto neprokazuje durable commit před provider FCM
ACK. Pád procesu v tomto okně může ztratit wake-up, nikdy však serverová OCS
data. Klient musí při foreground/resume a v bounded periodické práci provést
account-scoped OCS reconciliation. Vlastní fork distributoru není podmínkou P1;
stal by se nutný jen při budoucím požadavku na silnější transportní garanci.

### D-026: Minimální platformní baseline

Stav: Aktualizováno po prvním skutečném macOS buildu 26. srpna 2026.

- Android minSdk 24, targetSdk 36 a compileSdk 37 v ověřeném debug buildu;
- iOS deployment target 13.0;
- macOS deployment target 11.0; `gal 2.3.3`, používaný pro ukládání médií,
  deklaruje stejné minimum v Swift Package i CocoaPods kontraktu;
- Windows a Linux podle toolchain baseline Flutter 3.44.4.

Zvýšení minima vyžaduje konkrétní dependency nebo OS API důvod. První vzdálený
macOS build přesně doložil konflikt původních 10.15 s nativním minimem `gal`.
Snížení minima vyžaduje reálný build a runtime test, ne pouze změnu čísla.

### D-027: Desktop jako plnohodnotný produktový cíl

Stav: Přijato uživatelem 23. srpna 2026.

Windows, macOS a Linux používají stejný account, protocol, Drift a feature
model jako mobil. Expanded shell je třípanelový a reaguje na změnu okna.
Desktop-specific klávesnice, hover/focus, system tray, auto-start, file drop a
background delivery vzniknou pouze jako ověřené platformní řezy; nesmí se
předstírat existencí generated runneru.

Auto-start je lokální preference aplikace, nikoli účtu. Windows ji vlastní v
per-user `HKCU Run`, macOS 13+ přes `SMAppService.mainApp` a Linux přes XDG
Autostart soubor v uživatelském config adresáři. Flutter po zápisu vždy znovu
čte skutečný stav OS; neúplný zápis ani login item čekající na schválení se
nesmí zobrazit jako zapnutý. macOS 11–12 zůstává explicitně unsupported místo
legacy helperu nebo zápisu mimo sandbox.

Windows důkaz ze source `0be4c88` prošel release buildem, 29/29 bundle
manifestem a responsivním runtime na samostatné Windows 11 VM. Inspector capture
prokazuje Flutter render, ne skutečné pixely release DirectComposition okna;
přihlášený desktop E2E proto zůstává samostatná brána. Commit `1b1066a`
zabalil stejný produkt jako per-user Inno Setup instalaci. Vyhrazená VM ověřila
clean install, launch, upgrade za běhu, odmítnutí downgradu bez změny bajtů,
zachování support dat a uninstall. Release signing zůstává otevřený.

Apple důkaz ze source `83078cd` prošel na macOS 15.7.4 arm64 přes analyze,
čistý debug i universal release build, codesign verify a živé okno 800×628.
Skutečný Flutter inspector render prokazuje debug UI; nativní window capture
selhal a není důkazem. Stejný source prošel čistým iOS Simulator buildem,
instalací, spuštěním a framebuffer capture na iPhone 16 Pro s iOS 18.6. Ad-hoc
podpis ani simulátor neprokazují distribuční signing, fyzické zařízení,
Keychain login, APNs/PushKit nebo background lifecycle.

### D-028: Giphy jako renderovaná reference

Stav: Přepsáno 25. srpna 2026 výslovným uživatelským rozhodnutím. Předchozí
attachment varianta je popsaná níže a už neplatí.

GIF se neukládá do úložiště uživatele. Výběr v pickeru odešle `resourceUrl`
jako zprávu a bublina ji vykreslí: klient si referenci vyřeší přes
account-scoped Nextcloud References resolver a zobrazí animovaný GIF inline.
Uživatel tedy nevidí URL, ale animaci.

Důvodem změny je, že příloha zakládá soubor ve Files uživatele, což je pro
odeslání GIFu nepřiměřené. Renderovaná reference odpovídá tomu, jak to řeší
Chatujme.

Bezpečnostní hranice zůstávají: klient přijme jen `integration_giphy_gif`,
same-origin proxy konkrétního serveru a validní `image/gif` bajty. Loader je
account-scoped, bounded a s LRU. Jediný viditelný externí odkaz je povinná
GIPHY attribution v pickeru.

Picker thumbnail repository sdílí souběžný request stejné URL a drží nejvýše
32 ověřených obrázků nebo 16 MiB na instanci účtu. Cache se zahodí s repository;
explicitně rušený load zůstává samostatný, aby jeden caller nerušil ostatní.

Známé omezení: příjemce bez zapnuté Giphy integrace na svém serveru referenci
nevyřeší a uvidí odkaz. To je cena zvolené varianty.

### D-028a: Historická varianta Giphy jako Talk příloha

Stav: Původní wire-reference varianta byla 25. srpna 2026 nahrazena výslovným
uživatelským rozhodnutím. Commit `7ca580e` propojuje picker se skutečným
attachment tokem a má automatizovaný důkaz; live serverový round trip zůstává
otevřený.

Vybraný `resourceUrl` slouží jen jako vstup do account-scoped Nextcloud
References resolveru. Klient přijme pouze `integration_giphy_gif`, same-origin
proxy a validní `image/gif` bajty. Bajty uloží do durable app-owned zdroje a
odešle přes stejný Talk Draft/WebDAV/finalize tok jako jiný obrázkový attachment.
Do `sendText`, composeru ani outboxu textových zpráv se Giphy URL nikdy nevloží.

Původní renderer skryté wire URL zůstává pouze kvůli kompatibilitě se staršími
zprávami. Historický Android test této varianty je platným důkazem tehdejšího
chování, ale neprokazuje nový cílový attachment tok. Nový tok se nesmí při
žádné chybě vrátit k URL textové zprávě.

### D-029: Presence pouze ze serverového user status

Stav: Přijato 25. srpna 2026, commit `85fdb44`. Live ověřeno proti referenční
instanci na `emulator-5554`.

Presence se odvozuje výhradně z pole `status` v conversation v4 room objektu,
které server dodá po `includeStatus=true`. Klient nesmí presence odhadovat z
lokální aktivity, doby posledního pollu, otevřeného websocketu ani z
`lastActivity`. Badge se vykreslí jen pro one-to-one room (`type = 1`);
`offline`, `invisible` a neznámá hodnota badge nevykreslí vůbec.

`statusIcon` a `statusMessage` jsou vlastní status uživatele. Klient je
zobrazí jen dokud `statusClearAt` neuplynulo; po expiraci zůstane pouze
základní stav bez cizího textu.

Inkrementální odpověď, která room vrátí bez klíče `status`, předchozí hodnotu
zachová. Plná odpověď je autoritativní a hodnotu přepíše i na prázdnou.
Důvodem je, že delta je částečný pohled, zatímco full fetch reprezentuje
kompletní serverový stav účtu.

Původní schema v8 přidalo projekční sloupce bez backfillu starého `raw_json`.
Schema v13 proto jednorázově opraví databáze v8–v12 pouze tehdy, když je celá
presence čtveřice NULL a `raw_json` obsahuje validní textový `status`. Nikdy
nepřepisuje existující projekci a malformed nebo status-absent payload je
bezpečný no-op; repair je idempotentní.

`includeStatus=true` mění povahu inkrementálního fetchu: server v něm vrací
všechny 1:1 rooms, aby mohl obnovit presence. Kompaktní refresh proto není
zdarma a tato cena je vědomě přijatá výměnou za presence.

Barvy badge jsou definované pro každý theme zvlášť a každý stav má vlastní
glyph, aby stav nezávisel jen na barvě. Textová alternativa je povinná, protože
samotná barevná tečka je pro čtečku obrazovky neviditelná.

### D-030: Atomizace ručně udržovaných souborů

Stav: Přijato uživatelem 26. srpna 2026.

Ručně udržovaný zdrojový nebo testovací soubor má zůstat pod 1000 řádky. Větší
celek se rozdělí podle odpovědností do menších souborů s úzkým veřejným
rozhraním; samotné přesunutí řádků bez zmenšení odpovědnosti není dokončení.
Generated soubory jsou z limitu vyňaté, ale nesmějí se ručně editovat.

Výchozí audit evidoval 24 ručně udržovaných souborů nad limitem. Čerstvý audit
na `83078cd` už nenašel žádný; největší ručně udržované soubory mají 977 řádků.
Nad limitem zůstávají pouze generated `app_database.g.dart` a lokalizační
`lib/l10n/generated/app_localizations*.dart`. Limit zůstává průběžnou bránou,
aby další změny atomizaci nevrátily zpět.

### D-031: Offline admission textové zprávy z persistentního snapshotu

Stav: Přijato 26. srpna 2026, commity `47ec902` a `83078cd`.

Pouze `sendText` smí při transientním selhání načtení capabilities použít
persistentní account-scoped snapshot. Snapshot musí mít lane `ready`, jeho
fingerprint se musí přesně shodovat s kanonickým `talkFeaturesJson` účtu a profil
musí stále povolovat text send. Chybějící, poškozený nebo neshodný snapshot,
401, cancellation a neplatná odpověď zůstávají fail-closed.

Offline větev pouze připustí durable operaci ve stavu `queued`. Nesmí ji claimnout
ani vydat POST, protože bez síťového důkazu by transport vytvořil falešný
ambiguous stav. In-memory capability cache není online důkaz: API vrací
provenanci `network` nebo `memoryCache` a send admission vynutí fresh request.
Neúspěšný fresh read odstraní nahrazenou hot cache a teprve potom smí použít
persistentní fallback. Fresh foreground sync znovu načte autoritativní
capabilities; pouze při stále platné generation/replay autoritě operaci odešle
právě jednou. Commit `924f44c` probudí room binding přes coalesced
connectivity/lifecycle signál, zruší aktivní poll bez zavření bindingu a před
claimem znovu vynutí fresh capability read. Falešný signál nic neclaimne.
Android E2E potvrdilo bez restartu přechod z `queued`, attempt 0 do `completed`,
attempt 1 s jedinou serverovou i cached zprávou. Rozhodnutí stále nezavádí
background scheduler a neuzavírá live process-death/offline matici.

### D-032: Desktop credential vault podle nativní platformy

Stav: Přijato 26. srpna 2026, macOS řez `9695c9f`.

Desktop nesmí nahrazovat platformní secure storage plaintextem v Drift ani
v souboru. macOS používá nesynchronizovaný login Keychain s přístupností
`AfterFirstUnlockThisDeviceOnly`; pro sandboxovaný ad-hoc runner nepoužívá Data
Protection Keychain, protože ten bez odpovídajícího access-group entitlementu
round trip odmítá. Nativní test ověřil add, read a delete skutečné generic
password položky a po testu ji odstranil.

Toto rozhodnutí neprokazuje přihlášený macOS E2E ani Linux. Linux musí dostat
samostatný ověřený Secret Service/keyring backend; při jeho nedostupnosti se
credential nesmí tiše uložit méně bezpečně.

### D-033: Redigované bezpečnostní a migrační brány

Stav: Přijato 26. srpna 2026, commity `5f91e37`, `f184f9d` a `73ce1fc`.

Průběžný secret/log gate skenuje tracked zdrojové soubory a na požádání také
explicitní build nebo runtime-log artefakty. Nález zveřejní pouze cestu, číslo
řádku a stabilní rule ID; nikdy match, okolní řádek ani nalezenou hodnotu.
Čistý běh vrací 0, nález 1 a chyba vstupu nebo Gitu 2. Syntetické testovací
hodnoty nesmějí způsobit, že gate selže sama nad sebou.

Podporované release vstupy databáze jsou Git-backed schema v7 až v13. Každý se
otevře ze samostatného file-backed snapshotu, migruje do aktuální v14 a ověří
zachování account/conversation dat, presence, archivace, nové tabulky,
`user_version` a foreign-key integritu. Novější schema se nadále fail-closed
odmítá bez změny verze nebo dat. Budoucí release schema musí do stejné matice
přibýt současně se zvýšením `schemaVersion`.

### D-037: Vybraná konverzace je jediný zdroj pravdy pro obě šířky okna

Stav: Přijato 27. srpna 2026, commity `052a006` a `1b8687d`.

Otevřenou konverzaci drží výhradně výběr v shellu. Úzké okno ji vykreslí na
místě seznamu, široké okno v pravém panelu. Přepnutí mezi nimi je tím pádem
čistě otázkou rozvržení a funguje obousměrně bez zvláštní logiky. Systémové
tlačítko zpět a zpětné tlačítko v hlavičce ruší výběr, nezavírají aplikaci.

Předchozí pokus předával konverzaci navigátoru jako pushnutou obrazovku.
Zúžení okna fungovalo, rozšíření ne: aplikace zůstala v jednosloupcovém režimu
i na maximalizovaném okně. Příčinou nebyl chybějící pop, ale to, že vznikly
dva zdroje pravdy — výběr v shellu a stack navigátoru — a kopírovalo se jen
jedním směrem.

Opravit to zevnitř nešlo. Navigátor nebuduje route pod první neprůhlednou
route, takže se nestaví ani workspace, ani shell a ani jeden z nich se
o změnu velikosti okna nedozví; změřeno instrumentovaným testem, který
napočítal nula postavených shellů a jednu route. Jakákoliv reakce na resize
napsaná pod pushnutou obrazovkou je proto mrtvý kód.

Deep link musí v tomto modelu nejdřív odstranit vše nad kořenovou obrazovkou
a teprve pak nastavit výběr. Odkaz může přijít, když je uživatel kdekoliv,
a samotné nastavení výběru by ho nechalo dívat se na to, co má navrchu.

Poznámka k dohledatelnosti: shell část této změny nese commit `052a006`
s hlavičkou o doplnění klíče widgetu, protože vznikla nechtěně stagenutím
celého souboru s cizí rozpracovanou prací. Obsahově patří k `1b8687d`.

### D-034: Desktopová hustota podle vstupního zařízení, ne podle šířky okna

Stav: Přijato 27. srpna 2026, commity `7cde8ca`, `520c88e`, `289a6ee`
a `539a776`.

Rozměry ovládacích prvků se odvozují od `defaultTargetPlatform`. Windows, macOS
a Linux dostávají hustotu pro myš a klávesnici, ostatní platformy zůstávají
beze změny na dotykovém minimu 48 dp. Hranicí je platforma, protože zúžené okno
na desktopu se pořád ovládá myší a rozšířený tablet prstem — šířka okna
o vstupním zařízení nevypovídá.

Změřeno widget testem při 1400×900 a `devicePixelRatio` 1: před opravou měl
standardní interaktivní prvek 48 px proti 34 px v Nextcloudu, řádek konverzace
80 px proti 53 px a hlavička panelu 76 px proti 44 px. Po opravě je na desktopu
`IconButton` 36, `FilledButton` 38, `TextField` 40, řádek konverzace 56,
avatar 40, hlavička 52 a šířka seznamu 300, což je `$navigation-width`
z `nextcloud/server`.

Příčinou NENÍ `ThemeData.visualDensity`. Flutter ho podle platformy dopočítá
sám (`theme_data.dart:412`), na desktopu tedy compact hustota už platí — ale
ubere jen 8 px u widgetů založených na `minimumSize` a na `contentPadding`,
zaoblení ani typografii nedosáhne vůbec. Skutečné příčiny byly dvě: téma
vnucovalo dotykové minimum všem platformám, a rozměry natvrdo zapsané ve
widgetech, na které hustota nemá vliv.

Dvě zjištění, která z návrhu neplynula a vyšla až z měření. `IconButton` na
`minimumSize` nereaguje, protože se řídí paddingem kolem ikony a v Material 3
si pinuje `VisualDensity.standard`; skutečným knoflíkem je `padding`
a `tapTargetSize`. A `minimumSize` se musí zadávat o osm větší, než má být
výsledek, protože desktopová compact hustota osm bodů odečte.

Guard test `desktop_density_test.dart` drží mobilní minimum 48 dp i spodní mez
24 px, aby se hustota nedala snižovat donekonečna.

### D-035: Přerušená migrace databáze se zotavuje, neprovádí se atomicky

Stav: Přijato 27. srpna 2026, commity `04528c3`, `0b3c201` a `5c7cd96`.

Každý krok `onUpgrade` musí být idempotentní, aby ho šlo bezpečně zopakovat.
Migrace se záměrně neobaluje do jedné transakce.

Důvodem je stav doložený na vyhrazené Windows VM: `user_version` zůstalo 7,
ale schéma bylo už po krok 10, takže každý další start replayoval kroky, které
schéma mělo, a skončil na `duplicate column name: is_archived`. Aplikace se
neotevřela, tlačítko pro nový pokus jen zopakovalo tutéž migraci a z UI
nevedla cesta ven.

Atomicita by tento stav nikdy neuzdravila, pouze zabránila vzniku nových.
Navíc by sama o sobě nestačila: `user_version` zapisuje drift až po dokončení
`onUpgrade`, takže pád v tom okně vyrobí tentýž rozejitý stav a bookkeeping by
se musel obcházet ručně.

Idempotentní musel být jediný krok. `migrator.createTable` drift generuje jako
`CREATE TABLE IF NOT EXISTS`, indexy mají `IF NOT EXISTS` ručně a backfilly
přepočítávají z `raw_json`. Neidempotentní byl pouze `migrator.addColumn`,
který nyní prochází přes kontrolu `PRAGMA table_info`.

Databáze také přestala vznikat v uživatelské složce Dokumenty. Nešlo o problém
jediné platformy: `drift_flutter` má výchozí adresář
`getApplicationDocumentsDirectory()` všude, takže na Windows šlo o složku
synchronizovanou OneDrivem, na Linuxu o `~/Documents`, na macOS bez sandboxu
totéž a na iOS o sandbox viditelný ve Files a zálohovaný do iCloud; jen Android
mířil do app-private adresáře. Přesun stěhuje i `-wal` a `-shm`, protože
samotný hlavní soubor by zahodil transakce ve write-ahead logu, a existující
soubor v cíli nikdy nepřepíše.

### D-036: Chat providery se uvolňují se zavřením místnosti

Stav: Přijato 27. srpna 2026, commit `142d5c6`.

Rodinné providery držící zprávy, stavy odeslání, outbox operace a scope jsou
`autoDispose`. Bez toho si každá kdy otevřená místnost natrvalo držela živý
drift subscription i poslední kompletní seznam zpráv a zavření místnosti
neuvolnilo nic.

Změřeno na produkční widget cestě: 2,9 kB rezidentní paměti na cachovanou
zprávu, tedy zhruba 58 MB pro místnost s dvaceti tisíci zprávami. Průchod
dvanácti místnostmi po dvou tisících zprávách vyrostl před opravou o 57,9 MB
a po ní o 16,3 MB, což je o 72 % méně.

Dvě související změny byly posouzeny a zamítnuty, obě s měřením. Okno nad
dotazem na zprávy nemá co opravovat, protože místnost s dvaceti tisíci
nacachovanými zprávami se otevře za 231 ms a po `autoDispose` se drží jen jedna
otevřená; navíc by tiše rozbilo skok na zprávu, protože bloky popisují, co je
stažené, a ne co dotaz vydává. Evikce nacachovaných zpráv nemá co odříznout,
protože z 1 199 B na řádek je 714 B samotná zpráva — mazala by uživatelskou
historii, ne režii.

### D-038: Vlastní push proxy je výchozí transport na Androidu i Apple

Stav: Přijato 27. srpna 2026, doručení prokázané naživo 28. srpna 2026.
Nahrazuje androidí část D-025.

Android i Apple platformy registrují push-v2 proti vlastní proxy
`nks-talk-notify`, ta drží odesílací větev na FCM v1 a na APNs. Projekt tedy
publisher Firebase projekt i vlastní gateway MÁ; starší tvrzení o opaku v
D-025 a v okolních odstavcích platí jen pro záložní Web Push větev.
Web Push přes UnifiedPush zůstává nesmazaný, přepínatelný za běhu.

Nextcloud vybírá cílová zařízení podle sloupce `apptype`, který odvozuje
výhradně z User-Agentu registračního požadavku, a Talk notifikaci pošle
`talk` zařízením — na ostatní spadne jen tehdy, když účet žádné `talk`
zařízení nemá. Klient se proto při registraci hlásí jako Talk klient
(`f52a587`); bez toho účet, který používá i oficiální aplikaci Talk,
nedostane v této aplikaci ani jednu notifikaci. Podrobné měření je
v `TODO-notifications-calls.md`.

Proxy obsah notifikace nedešifruje. Otevře ho až klientský RSA klíč, takže
účet určuje ten klíč, který payload rozšifroval, ne hostitel ani aktivní účet.

### D-039: Typing stav je transientní room session se zdroji per composer

Stav: Přijato 30. srpna 2026, commit `9499288`.

Indikátor se zapne pouze při autentizovaném `signaling-v3`, feature
`typing-privacy`, veřejné `config.chat.typing-privacy=0` a external HPB
transportu. Chybějící nebo privátní policy je fail-closed: klient nepřijímá ani
neodesílá typing stav. Rozhodnutí odpovídá `talk-android@5428960` a
`talk-ios@2d31eda`.

Příchozí stav je account/room/peer-scoped a po 15 sekundách bez obnovy zmizí.
Odchozí start se obnovuje po 10 sekundách souvislého psaní a po pěti sekundách
nečinnosti se odešle stop. Nejde o durable data a nepatří do Drift databáze.
Provider drží pouze non-secret signaling authority potřebnou k obnovení lane.

Root a thread stejné místnosti sdílejí jednu signaling session, ale ne jediný
boolean aktivity. Každý composer má identity source a controller agreguje
jejich množinu; stop se odešle až po deaktivaci posledního zdroje. Tím vedlejší
nefocusovaný root nezastaví aktivní thread v desktop split view.

Live web → iOS round trip na referenční instanci prokázal start i stop bez
odeslání zprávy. Pixelově změřený banner měl 4,72:1 ve světlém a 11,15:1 v
tmavém režimu.

Doplnění 1. září 2026, commity `a9e08f4`, `ea19395`, `3c89513`, `2760623` a
`5c2df5d`: typing provider před
HPB připojením aktivuje místnost přes `participants/active` a přijme pouze
odpověď se stejným room tokenem a nenulovým session ID. Talk session cookie je
jen v paměti, pod klíčem konkrétního `accountId` a přesného serveru. Aktivace a
deaktivace mají serializovaný generation lease, takže opožděný cleanup starého
provideru nesmí smazat novější session. Odebrání účtu před revokací credentials
uzavře admission, serverovou session i HPB lane; opožděný active/settings/call
response už nesmí zachytit cookie, vrátit úspěch ani obnovit DB stav. API close
invaliduje generation, bounded zruší response stream a čeká na cleanup tail.
401, invalidní odpověď, dispose a deaktivace mají bounded cleanup. Cookie path,
domain, expiry, `Max-Age`, prázdná hodnota a ordering se vyhodnocují bez sdílení
mezi účty. Živý web → Android průchod zobrazil start do 2 sekund a stop do 5
sekund.

### D-040: Absence protistrany je transientní account-scoped DAV pohled

Stav: Přijato 31. srpna 2026, commit `16101db`.

Aktuální absence se načítá pouze pro otevřenou 1:1 konverzaci a jen za
`dav.absence-supported = true`. User ID pochází z account-bound roomu a GET
používá origin, login i credential stejného účtu. Account mismatch, skupina,
prázdné user ID nebo chybějící capability nesmí spustit žádný request.

Absence není chat zpráva ani durable synchronizační stav. Neukládá se do Drift
databáze a po otevření nebo změně konverzace se načte z autoritativního DAV
endpointu. Vlastníkem requestu je banner; při změně scope nebo dispose zruší
capability i navazující GET, aby starý výsledek nemohl přeskočit do jiné room.

Serverový text zůstává celý pro čtečku obrazovky, ale vizuální řádky jsou
omezené. Tím validní bounded payload neznepřístupní chat při zvětšeném písmu.

### D-041: Kalendářový reminder patří k přesné call location

Stav: Přijato 31. srpna 2026, commit `be6cfe5`.

Nadcházející událost se nehledá podle názvu místnosti ani účastníků. Klíčem je
přesná absolutní location `{accountOrigin}/call/{roomToken}`, kterou používá i
upstream Talk Android. Endpoint se volá jen za `upcoming-reminders` a se stejným
account originem, loginem a credentialem jako otevřená room.

Reminder je transientní serverový pohled, ne chat zpráva ani durable cache.
Zobrazuje se první použitelný event a zavření platí pro aktuálně otevřený pane.
Při změně scope se request zruší a generation-bound widget zahodí stará data
ještě před dokončením nové odpovědi.

Location v odpovědi se musí přesně rovnat request filtru. Tím ani validní OCS
payload nemůže přeskočit mezi dvěma rooms stejného účtu nebo mezi účty se
shodným tokenem.

### D-042: Sdílený kontakt je vCard file attachment

Stav: Přijato 31. srpna 2026, commity `9d6b0fe` a `f743c45`.

Upstream Android exportuje kontakt do `.vcf` a pošle jej standardním attachment
tokem. Klient proto nepřidává nový rich object druh ani zvláštní download
transport. Příjem zůstává v account-authenticated DAV file pipeline.

Strong vCard MIME je autoritativní. Generic binární MIME smí použít contact UI
jen tehdy, když poslední segment validovaného `DavRelativePath` končí `.vcf`.
Display name není trust boundary a příponu nesmí dodat ani přepsat.

Odeslání kontaktu z platformního adresáře je samostatná funkce s vlastními
permission a privacy hranicemi. Příjem vCardu ji nepředstírá ani nevyžaduje
přístup ke kontaktům zařízení.

Android a iOS používají foreground systémový picker, který vrací právě jeden
kontakt bez plošného oprávnění. Nativní hranice odstraní PHOTO, odmítne více
karet nebo chybějící FN a vynutí 2MiB limit. App-owned vCard pokračuje beze
změny přes stávající file attachment admission, takže zdědí account/room/thread
binding, durable source a autoritativní serverové potvrzení.

### D-043: Serverový accent je account-scoped capability state

Stav: Přijato 31. srpna 2026, commit `75127b9`.

Autentizovaný capability snapshot přijímá pouze opaque `#RRGGBB`. Barva se
ukládá v samostatné tabulce vázané cizím klíčem na `accountId`; nesdílí se s
Talk feature fingerprintem ani jiným serverem. Chybějící nebo neplatná hodnota
starý accent odstraní a použije výchozí seed.

Theme se přegeneruje při změně vybraného účtu. Material color scheme zůstává
odpovědný za light/dark kontrast, který hlídá výpočet minimálně 4,5:1.

### D-044: Živá mapa polohy vyžaduje výslovný souhlas

Stav: Přijato 31. srpna 2026, commity `4b0e659` a `b3c751e`.

Zobrazení zprávy nesmí samo poslat souřadnice třetí straně. Výchozí náhled je
lokální schéma s markerem. OSM dlaždice se načtou až po samostatném přístupném
klepnutí; serverem dodaný link není důvěryhodný síťový cíl.

Loader má pevný HTTPS origin, zakázané redirecty, limit čtyř requestů po
256 KiB, souběh dva a timeout. Bajty zůstávají jen ve widget-local
`Image.memory`; account switch nebo dispose zavře klienta a generation guard
zahodí pozdní výsledek. Nevzniká globální cross-account image cache.

### D-045: Ankety jsou online-only serverové mutace

Stav: Přijato 31. srpna 2026, commity `d714f70` a `5f48ca7`.

Poll create, show a vote používají exact upstream Talk v1 kontrakt a feature
`talk-polls`. Create vyžaduje write oprávnění; show a vote zůstávají dostupné
platnému účastníkovi read-only konverzace podle controller atributů upstreamu.
Thread poll navíc vyžaduje canonical nesmazaný root.

Create ani vote nemají idempotency key, proto se nezařazují do durable outboxu
a po nejednoznačném výsledku se automaticky neopakují. Přijatý `talk-poll`
rich object nese pouze validovaný poll ID; aktuální stav a hlasování se vždy
načtou account/room-bound GETem ze serveru. Canonical serverová zpráva je běžný
`comment` s prázdným `systemMessage`, textem `{object}` a přesně odpovídajícím
`messageParameters.object`. Viewer proto váže parametr na placeholder, ne na
historicky předpokládané `object_shared`; odpojené metadata zůstane inertní.

### D-046: Secure store má vlastní account-scoped migrace

Stav: Přijato 31. srpna 2026.

Verze credential vaultu není odvozená z Drift `schemaVersion` a žádný secure
store zápis neběží v `onUpgrade`. Každý účet má durable marker přímo ve
stejném platformním secure store jako jeho app password. Tím lze databázi
otevřít, opravit nebo bezpečně odmítnout nezávisle na dostupnosti Keychainu či
Keystore.

Migrace v1 na v2 je copy-verify-commit-cleanup. Neversionovaný klíč se nejdřív
zkopíruje do versionovaného account-scoped klíče, kopie se zpětně ověří a až
potom se zapíše marker `2`. Legacy klíč se smaže teprve po ověření markeru.
Přerušení proto nechá nejméně jednu úplnou kopii a další přístup stejný krok
idempotentně dokončí.

Dvě různé hodnoty, nečitelný marker nebo verze novější než klient zastaví
přístup bez přepsání či smazání secretu. Souběžné první requesty stejného účtu
sdílejí jeden migrační future; jiné účty zůstávají nezávislé.

### D-047: Minimální podporovaná řada je Talk 22 (Nextcloud 32)

Stav: Přijato 3. září 2026.

Klient stojí na třech tvrdých branách: `conversation-v4` (Talk 12), `chat-v2`
(Talk 3.2) a `threads` (Talk 22). Nejmladší z nich určuje minimum, takže
podporovaná řada začíná Talkem 22, tedy Nextcloudem 32. Vše, co klient dál
používá, existuje od starší řady než 22 — `chat-replies` 8, `chat-reference-id`
9, `delete-messages` 11.1, `clear-history` 12.1, `reactions`, `unified-search`,
`silent-send` a `message-expiration` 15, `avatar` 17, `media-caption` a
`note-to-self` 18, `edit-messages` a `federation-v1` 19, `ban-v1` 20,
`archived-conversations-v2` 20.1, `important-conversations` a
`sensitive-conversations` 21.1 — a na Talku 22+ je tedy k dispozici vždy.
Jediná mladší capability je `conversation-tags` (Talk 24); ta gatuje jen
štítky a chybět smí.

Zdroj: `docs/capabilities.md` v `nextcloud/spreed` (větev `main`, čteno
3. 9. 2026), kde je každá capability zapsaná pod řadou, ve které vznikla.
Server se starší řadou hlásí `conversationProfileUnsupported` (chybí
`conversation-v4`) nebo chybí `threads`; obojí aplikace hlásí jako nepodporovaný
server, ne jako chybu sítě. Ověřit měřením na starší řadě nelze bez druhého
serveru; rozhodnutí proto vychází z dokumentace upstreamu, ne z běhu.

Změřeno 3. 9. 2026 na druhém serveru `talk2.example.invalid` (Nextcloud 32.0.14,
Talk 22.0.17): řada 22 neposílá v `v4/room` pole `tagIds`, `lastPinnedId`,
`hiddenPinnedId`, `hasScheduledMessages` ani `attributes` a parser je do té
doby vyžadoval, takže seznam konverzací odmítl celý. Od `275c039`/`talk22`
fixture jsou tato pole volitelná s prázdnou/nulovou výchozí hodnotou; když
přijdou, validují se stejně přísně jako dřív. Totéž platí pro Login Flow v2
na serveru s pretty URL (bez `index.php`), který oficiální Docker image
používá.

