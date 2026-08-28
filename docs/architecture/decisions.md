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

Conversation tags jsou na ověřeném upstream SHA `f2958bb` také
participant-scoped, nikoli moderator-only. Klient za capability
`conversation-tags` načte definice, nabídne pouze custom tagy a při změně odešle
úplnou výslednou množinu `tagIds`; lokální delta ani skryté predefined tagy
nesmějí serverový stav přepsat.

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

Push delivery se liší podle platformy. Podle D-038 registrují Android i Apple
proti vlastní proxy `nks-talk-notify`, která drží FCM i APNs větev; Web Push
podle D-025 zůstal jako přepínatelná androidí záloha a jen ta se obejde bez
publisher Firebase projektu a vlastní gateway. Firebase nebo APNs credentials se nikdy nestahují z
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

Autentizační HTTP 401 se ukládá jako durable `reauthRequired` a zastaví další
account requesty. Re-auth znovu používá Login Flow, ale server je uzamčený na
původní origin a base path a výsledek musí mít stejný login i `accountId`.
Cizí credential se nesmí uložit a best effort se odvolá. Teprve úspěšná shoda
nahradí secure credential, zachová account cache, smaže chybu a obnoví live
sync. Invalidace capability cache po 401 musí současně odpovídat credential
fingerprintu, originu a nejkonkrétnější base path; shodný Basic Auth na jiném
serveru nesmí ztratit svůj zdravý snapshot.

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

Přesunuto do [Technická rozhodnutí](decisions-technical.md): D-007 až D-010
a D-019 a výš, aby tento soubor zůstal pod limitem D-030. Produktová
rozhodnutí a otevřené volby zůstávají tady.

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
