# Rozhodnutí a otevřené volby

Stavy:

- **Přijato**: uživatel rozhodl, jde o nutnou invariantu nebo o ověřenou
  technickou baseline pro implementaci.
- **Doporučeno**: analýza má preferovanou variantu, čeká na potvrzení.
- **Otevřeno**: bez volby se příslušný scaffold nebo feature nesmí uzamknout.
- **Odloženo**: není v prvním release, ale architektura zachovává hranici.
- **Nahrazeno**: rozhodnutí zůstává historicky dohledatelné, ale nový řez se
  jím už neřídí.

## Přijatá rozhodnutí

### D-001: Multi-server produkt

Stav: Přijato.

Klient není white-label pro jeden server. Referenční instance slouží pouze k
testování.

Důsledek: žádná produkční URL, capability nebo účet nesmí být globální
konstanta.

### D-002: Multi-account izolace

Stav: Přijato jako nutný důsledek multi-server produktu.

Credentials, cache, push identity, connections, badge a deep links se scopují
accountId.

Asynchronní UI akce zachytí accountId objektu při otevření a používají jej po
celý request i následný sync. Pozdější změna globálně vybraného účtu nesmí akci
přesměrovat; account-specific filtry pohledu se při přepnutí resetují.

Conversation-list filtry na ověřeném Android upstream SHA `5428960` kombinují
nepřečtené a zmínky jako AND. Archivovaný pohled je dostupný pouze za
`archived-conversations-v2`; bez něj i bez aktivního filtru zůstávají
archivované rooms skryté. Mention filtr přijme explicitní `unreadMention` a
také každou nepřečtenou one-to-one nebo former-one-to-one room.

### D-003: Capability-first

Stav: Přijato jako protokolová invarianta.

Číslo Talk release není feature flag. Resolver kombinuje globální,
features-local a room-scoped capabilities.

Každá mutace musí ověřit přihlášený account-scoped snapshot v odpovědné service
nebo protokolové vrstvě, ne jen skrýt tlačítko v UI. Archivace například nesmí
vydat request bez jednoznačné capability `archived-conversations-v2`.

Room settings respektují přesný upstream kontrakt, ne domyšlenou společnou
bránu. `message-expiration` se povolí jen moderátorovi se stejnojmennou
capability a používá nezáporné sekundy, kde 0 vypíná; serverem vynucená hodnota
zůstává autoritativní. `notify-calls` na ověřeném upstream SHA samostatnou
capability nemá a používá pouze absolutní level 0/1. Obě response znovu dekódují
autoritativní room místo lokálního přepnutí optimistic stavem.

`important` a `sensitive` nejsou moderátorská room metadata, ale osobní
participant-scoped nastavení. Každé vyžaduje vlastní capability a absolutní
POST/DELETE bez body; federované rooms jsou podporované. Classified room nesmí
vypnout `sensitive` a serverový error `classified` se nesmí převést na lokální
úspěch. I zde je zdrojem pravdy autoritativní room z response.

`clear-history` je destruktivní moderator-only online operace bez klientského
idempotency key. Po fresh authenticated capability snapshotu používá jediný
DELETE bez body a nikdy nevstoupí do outboxu ani automatického retry. HTTP 200
i 202 znamenají provedené smazání; 202 navíc vyžaduje varování, že federace či
externí bridge mohou držet kopie. Lokální purge je account/room-scoped a nesmí
smazat drafty, durable upload zdroje ani pending outbox. Selhání následného
refresh nesmí uživatele vyzvat k opakování již provedeného DELETE.

Thread request musí oddělit cílovou zprávu od identity canonical rootu.
Notification-level request používá jako cíl výhradně canonical `threadId`, i
když historický název route parametru na serveru zní `messageId`. Response
wrapper musí nést `threadId` a legacy `messageId` se fail-closed odmítá. Decoder
odmítá room/root mismatch a zachová původní request; merge planner odmítá
account/server snapshot mismatch. Libovolný serverem vrácený root se nepřijímá.

### D-004: Žádné fake subsystémy

Stav: Přijato podle projektových pravidel.

Call preparation znamená funkční signaling state machine a contract testy, ne
neaktivní tlačítko nebo interface vracející OK.

### D-005: Jedna veřejná aplikační identita

Stav: Přijato jako důsledek veřejného multi-server produktu.

Jeden distribuovaný build používá stabilní applicationId/bundle ID pro všechny
podporované Nextcloud servery. Připojení dalšího serveru nesmí měnit binary,
signing ani identitu aplikace.

Push delivery se liší podle platformy. Android podle D-025 vyjedná per-account
Web Push subscription za běhu a nemá publisher Firebase projekt ani vlastní
gateway. iOS APNs/PushKit podle Apple identity vyžaduje pozdější
publisher-owned relay. Firebase nebo APNs credentials se nikdy nestahují z
libovolného připojeného Nextcloudu.

### D-006: Outbox jen s ověřeným replay kontraktem

Stav: Přijato jako datová a bezpečnostní invarianta.

Lokální operationId, referenceId ani HTTP metoda samy neprokazují serverovou
idempotenci. Každý operationKind se smí zařadit do durable outboxu až po
capability/SHA-bound kontraktu, který popíše bezpečný retry před odesláním,
reconciliation nejednoznačného výsledku, terminální odpovědi, compensation a
uživatelskou akci. Neověřená operace se nesmí vydávat za offline podporovanou.

### D-013: Vlastní Talk-inspirovaná implementace

Stav: Přijato uživatelem.

Klient nebude pixelově věrná kopie ani překlad GPL Android/iOS zdrojového
kódu. Vznikne vlastní Flutter implementace podle veřejných protokolů a vlastních
specifikací. Zachová známou informační architekturu Talku, ale použije vlastní
komponenty, vizuální variaci a doplní multi-server, offline a diagnostické
stavy.

Upstream se používá jako SHA-bound reference chování, wire kompatibility a
testovacích scénářů. Licence je vyřešená v D-018; původní implementační proces
zůstává zachovaný.

### D-014: Identita aplikace

Stav: Přijato uživatelem.

Android applicationId, iOS a macOS bundle ID a Linux application ID jsou
`com.nkshub.nextcloudtalk`. Windows používá stejný produktový název a publisher
namespace v runner metadatech. Identita se nemění podle připojeného Nextcloud
serveru a nestahuje se za běhu.

Samostatně podepsaná fork distribuce může identitu změnit, ale jde o jiný
binary a vlastní release/signing odpovědnost.

### D-015: Bezpečný klientský bootstrap

Stav: Přijato jako trust a multi-account invarianta.

Uživatelem zadaný server se nejprve kanonizuje a ověří přes veřejný status.
Login Flow v2 URL i credential `server` musí zachovat stejný origin a Nextcloud
base path; v production musí být origin HTTPS. Cross-origin, base-path escape,
userinfo, query, fragment, encoded nejednoznačnost a production HTTP se
odmítají před otevřením URL nebo odesláním tokenu. Explicitní debug HTTP policy
se musí zachovat přes normalizaci, Login Flow i credential validaci.

Anonymní capabilities jsou pouze onboarding data. Po jednorázovém úspěchu se
app password uloží přímo do platformního secure storage, vytvoří se náhodné
lokální `accountId` a teprve přihlášený capability snapshot se uloží jako
account-scoped autorita. HTTP 404 poll nerozlišuje pending, invalid, expired ani
consumed stav a nesmí se interpretovat přesněji.

### D-016: Account-scoped conversation merge

Stav: Přijato a implementováno v pure Dart parseru, merge planneru i Flutter
Drift transakčním adapteru. Zbývá úplná multi-server a process-death runtime
matice.

`conversation-v4` v přihlášeném capability snapshotu volí pouze kandidátní
endpoint. Aktivní profil `cursor-v4` vznikne až po schema-validní full response
s kanonickým cursorem a neprázdným Talk hashem. Legacy wire profil bez těchto
hlaviček zůstává unsupported, dokud nevznikne samostatný adapter.
HTTP 401 znamená re-auth, zatímco 426, 429, 503 a validní OCS failure pouze
odkládají potvrzení profilu; samy nedokazují nekompatibilní wire formát.

Request nese `accountId`, lokální request ID a kanonický serverový origin.
Dekódovaná response zachová tentýž request a planner odvodí celý kontext pouze
z ní. Uložený account stav nese očekávaný origin a odlišný server odmítne před
výpočtem upsertů nebo mazání.

Validovaný room model musí předat klientovi `objectType`, `avatarVersion`,
`isCustomAvatar` a volitelný `remoteServer`; federovaný stav se odvodí pouze z
neprázdného `remoteServer`. Talk/PHP může prázdné `messageParameters` a
`reactions` serializovat jako `[]`. Parser tuto jedinou variantu normalizuje na
prázdnou mapu, ale neprázdné pole odmítne, aby neskrylo schema drift.

Store klíč je `(accountId, roomToken)`. Inkrementální response nikdy nemaže
chybějící rooms; validní neprázdný full response je může odstranit. První
full-empty response při existující cache pouze založí potvrzovací stav. Smazání
smí potvrdit až jiný full request do 300 sekund. Starší důkaz expiruje a
neprázdná mezilehlá delta jej okamžitě ruší.

Room upsert, případné mazání, serverový cursor a Talk configuration hash se
commitnou v jedné transakci. Chyba schema, OCS, semantiky nebo DB cursor
neposune. Schema diagnostika smí obsahovat jen strukturální path a typ
validatoru, nikdy hodnotu z response. Změna hash vyžádá account-scoped
capability/settings refresh, nikoli smazání rooms. O typu merge rozhoduje
explicitní režim requestu, ne samotná hodnota `modifiedSince`.

Foreground loop používá po získání cursoru levný incremental režim. Ruční
refresh explicitně požaduje full reconciliation, protože delta nemá removal
tombstone a pouze full response smí odstranit room, kterou server už nevrací.
Per-account single-flight je mode-aware: full intent za rozběhnutou deltou musí
po jejím dokončení spustit nebo joinnout nový full request a nesmí být deltou
považovaný za splněný. Full-empty ochrana udrží oba potvrzovací pokusy ve full
režimu a s různými request ID. Odstranění stale conversation cache nesmí smazat
pending outbox ani stejný room token jiného účtu.

### D-017: Autoritativní chat cursor a bezpečný text-send outbox

Stav: Přijato a implementováno v pure Dart planneru/outboxu i Flutter Drift
repository. Live restart a vzdálená reconciliation matice zůstávají
neprokázané.

Chat history a future jsou dva směry stejného account/room/thread scope.
`X-Chat-Last-Given` je autoritativní hranice i při prázdném viditelném body;
history `304` ukončuje starší historii a future `304` potvrzuje konvergenci.
Response se smí commitnout jen při shodě request anchoru s aktuálním cursorem.
Message identity, intervaly, parent/thread, read hodnoty a outbox reconciliation
se mění atomicky a schema diagnostika neobsahuje hodnoty zpráv.

Autoritativní editace nebo smazání zprávy se nesmí uložit jen do samostatného
řádku parentu. Ve stejné Drift transakci se promítne do každé full parent kopie
v cached replies stejného accountu a roomu a případně do conversation preview.
Full i compact deleted parent se v UI vykreslí jako smazaný bez původního
autora, obsahu nebo interaktivního jump cíle.

Read a mark-unread mutace se pořadově serializují pouze v lane
`(accountId, roomToken)`. Zachová se tedy skutečné pořadí read → unread i
unread → read v jedné room, zatímco jiné rooms a účty mohou pokračovat
souběžně. Očekávané runtime a DB výjimky se na hranici služby mapují na
`invalidResponse`, programátorský `StateError` se neskrývá a lane se po obou
druzích chyby vždy uvolní. Žádná z těchto mutací nedostává blind replay.

Ordinary reply view a named-thread network scope jsou oddělené projekce.
Přechod z ordinary view do named threadu nesmí migrovat ordinary cursor ani
posunout nový network scope. Root merge se smí promítnout jen do stejného
accountu a roomu. Tyto hranice mají automatizované regresní testy.

Otevřený thread route, včetně vstupu ze search, odvozuje kind a title průběžně
z canonical cached rootu; snapshot z okamžiku navigace není autorita pro další
send. Asynchronně připravený media request je immutable: resolver jej sváže s
aktuálním rootem a durable repository ve stejné transakci těsně před insertem
exact binding znovu ověří. Změna ordinary ↔ named, missing, deleted nebo invalid
root admission fail-closed odmítne; repository metadata potichu nepřepisuje.
Stejná autorita platí pro text: po asynchronním capability read se cached root
znovu dekóduje a musí být nesmazaný, nesystémový a canonical. Named root navíc
vyžaduje neprázdný bounded title a shodný `threadId`; jinak nevznikne outbox
řádek ani HTTP POST. Validní ordinary ↔ named změna se naopak použije jako
aktuální wire binding.

Full embedded parent z thread response smí obnovit cached thread original jen
při shodě room tokenu, parent/original ID a thread ID. Explicitní serverové
`threadReplies` je autoritativní. Když chybí, Flutter repository odvodí počet z
unikátních reply ID daného account/room/thread scope, vynechá original a replay
a zachová vyšší uložený počet. Neshodný parent nesmí cached original přepsat.

`referenceId` je korelace, ne idempotency key. První povolený durable registry
kind je pouze `textSend` s revision
`talk-chat-text-send-f2958bb-f9b9e947-r2`. Revize r2 přidává explicitní
`threadId` pro named-thread send; obyčejná zpráva má `replyTo == null` i
`threadId == null`, reply používá `replyTo` a named-thread zpráva používá pouze
`threadId`. Named-thread admission a replay navíc vyžadují lokální capability
`threads`; r1 operace se pod r2 autoritou nesmí automaticky replayovat.

Request a response semantika nejsou totožné. Plain request nemá `threadId`, ale
plain direct response je parentless a server vrací `threadId == messageId`.
Same-room reply vrací topmost thread ID z immediate parentu. Cross-room private
reply vrací lokální copied-parent ID a `parent.threadId == 0`; named-thread
direct response zůstává parentless s požadovaným thread ID.

Request prokazatelně zastavený před body může být retryable. Možná odeslané
body, přerušený proces, `201 null` nebo identity mismatch přejdou do
`awaitingConfirmation` a nesmějí se automaticky znovu odeslat. Jedna
autoritativní shoda stejného plain/reply/thread kontextu dokončí operaci, více
shod zůstane ambiguous a nula shod neprokazuje neprovedení. Ruční resend
vyžaduje varování před duplicitou a nesmí pokračovat po nalezené serverové
shodě. HTTP 400 `error=message` a 5xx jsou ambiguous; pouze doložený pre-save
429 `error=mentions` je retryable podle `Retry-After` nebo lokálního backoffu.
V jedné room platí FIFO a single-flight, různé rooms mohou pokračovat souběžně.
Cross-room private-reply wire formát je známý, ale command admission zůstává bez
plného eligibility snapshotu odmítnutý. Neznámý kind nebo revision admission
odmítne.

Pure Dart single-use plán dokládá společný candidate snapshot pro chat merge a
outbox confirmation i úplný rollback zahozením plánu. Flutter `ChatRepository`
načte snapshot, vytvoří plán a uloží message/scope/outbox změny uvnitř jedné
Drift transakce. Fault-injection test potvrzuje úplný rollback zprávy i outboxu,
když selže view projekce. Ordinary reply zůstává viditelná od pending stavu přes
HTTP 201 a Reply UI vyžaduje vyřešený profil s capability `chat-replies`.

Schema v5 ukládá nullable `threadId`; file-backed reopen zachová queued i
sending named-thread operaci a restart recovery převede `sending` na
`awaitingConfirmation`. Legacy schema migrace zachová a dokončí queued named
send. Potvrzená named-thread zpráva, ať jde o parentless direct POST nebo
autoritativní history/future shape s přesně svázaným full či compact deleted
rootem, současně obnoví cached root `threadId`, `isThread` a `threadReplies`.
Zbývá live process-death a vzdálená reconciliation.

### D-018: Licence mobilního klienta

Stav: Přijato uživatelem 22. srpna 2026.

Mobilní aplikace a její vlastní zdrojový kód jsou licencované pod
`GPL-3.0-or-later`. Úplný text je v kořenovém souboru `LICENSE`. Volba umožňuje
GPL-kompatibilní převzetí z oficiálních Talk klientů, ale žádné takové převzetí
nesmí být skryté: musí mít dohledatelný původ, zachované copyright notices a
samostatný licenční audit.

Přijatý vlastní Talk-inspirovaný směr z D-013 se nemění. Každý asset a závislost
musí být před distribucí kompatibilní s GPL a zaznamenaný v průběžném auditu.

## Přijatá technická rozhodnutí

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

Stav: Přijato po ověření Nextcloud Notifications 34.0.3 na SHA
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

Veřejný Android build nemá publisher Firebase projekt, `google-services.json`,
vlastní mobilní gateway ani per-server rebuild. Embedded distributor je
knihovna uvnitř APK, ne další aplikace. Nextcloud 34+ nepotřebuje addon;
případný Nextcloud 33 backport musí být úplná samostatná AGPL implementace Web
Push, nikoli tenký bridge.

Duplicitní nebo opožděný payload smí pouze idempotentně probudit account-scoped
OCS catch-up. Subscription endpoint, auth secret, activation token ani payload
se nesmějí logovat. Přesný tok a testovací matice jsou v
[push analýze](../research/push-fcm.md).

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

Windows důkaz ze source `0be4c88` prošel release buildem, 29/29 bundle
manifestem a responsivním runtime na samostatné Windows 11 VM. Inspector capture
prokazuje Flutter render, ne skutečné pixely release DirectComposition okna;
přihlášený desktop E2E proto zůstává samostatná brána.

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

## Vyřešené volby

### Q-001: Licence

Stav: Vyřešeno v D-018.

Uživatel zvolil `GPL-3.0-or-later`. Audit původu kódu, assetů a závislostí je
průběžná distribuční brána, nikoli otevřená volba licence.

### Q-002: Minimální platformy

Stav: Vyřešeno v D-026.

### Q-005: Giphy režim

Stav: Vyřešeno v D-028.

### Q-007: Android gateway implementační stack

Stav: Vyřešeno jako nepotřebné v D-025.

Historické Go/Node porovnání se neimplementuje pro Android. Budoucí iOS relay
projde novým výběrem až s APNs kontraktem a nemá předem zvolený stack.

## Otevřené volby

### Q-003: Release signing a Apple push

Identita aplikace je vyřešená v D-014. Pro vývoj lze iOS podepsat pro vlastní
zařízení. Před veřejnou distribucí zbývá Android release key workflow, Apple
developer tým, store provisioning a APNs/PushKit relay credentials. Android
publisher Firebase projekt není potřeba.

### Q-004: Offline scope prvního release

Možnosti:

1. Cache historie + textový outbox.
2. Plný outbox včetně upload resume od prvního release.

Architektura podporuje obě, ale acceptance scope a pořadí řezů se liší.

### Q-006: Podporované serverové řady

Je nutné určit minimální Nextcloud/Talk řadu. Multi-server neznamená automaticky
podporu všech historických verzí.

## Odložená rozhodnutí

### D-011: Plná call parity

Stav: Odloženo za chat a push parity.

Architektura zachovává signaling, coordinator, platform a media hranice.
Konkrétní WebRTC balík se vybere až po internal/HPB signaling prototypu a
Android/iOS lifecycle spike.

### D-012: Share Extension a App Intents

Stav: Odloženo.

Datový a deep-link model s nimi počítá, ale první implementace je nesmí
předstírat.
