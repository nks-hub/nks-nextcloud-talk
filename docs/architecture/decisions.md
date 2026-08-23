# Rozhodnutí a otevřené volby

Stavy:

- **Přijato**: uživatel rozhodl, jde o nutnou invariantu nebo o ověřenou
  technickou baseline pro implementaci.
- **Doporučeno**: analýza má preferovanou variantu, čeká na potvrzení.
- **Otevřeno**: bez volby se příslušný scaffold nebo feature nesmí uzamknout.
- **Odloženo**: není v prvním release, ale architektura zachovává hranici.

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

### D-003: Capability-first

Stav: Přijato jako protokolová invarianta.

Číslo Talk release není feature flag. Resolver kombinuje globální,
features-local a room-scoped capabilities.

### D-004: Žádné fake subsystémy

Stav: Přijato podle projektových pravidel.

Call preparation znamená funkční signaling state machine a contract testy, ne
neaktivní tlačítko nebo interface vracející OK.

### D-005: Jedna veřejná push identita

Stav: Přijato jako důsledek veřejného multi-server produktu.

Jeden store build používá jeden applicationId/bundle ID, Firebase projekt a
gateway vydavatele pro všechny podporované Nextcloud servery. Klient při
runtime registraci předá gateway URL do Notifications API v2. Správce serveru
nepotřebuje Firebase credential ani rebuild.

Firebase konfigurace se nesmí načítat z libovolného připojeného Nextcloudu.
Plně nezávislý Firebase/APNs projekt je možný pouze pro samostatně podepsaný
vlastní build.

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

### D-014: Android applicationId

Stav: Přijato uživatelem.

Veřejný Android build používá `com.nkshub.nextcloudtalk`. Identifikátor je
stabilní součást podpisové, store a Firebase identity aplikace; nemění se podle
připojeného Nextcloud serveru a nestahuje se za běhu ze serveru.

Toto rozhodnutí nezamyká iOS bundle ID ani identitu případného samostatného
self-hosted buildu s vlastním Firebase projektem.

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

Stav: Přijato a implementováno v pure Dart parseru a merge planneru; skutečný
Drift transakční adapter zůstává součástí řezu 2.

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

### D-017: Autoritativní chat cursor a bezpečný text-send outbox

Stav: Přijato a implementováno v pure Dart planneru a outboxu; skutečný
SQLite commit zůstává neprokázaný.

Chat history a future jsou dva směry stejného account/room/thread scope.
`X-Chat-Last-Given` je autoritativní hranice i při prázdném viditelném body;
history `304` ukončuje starší historii a future `304` potvrzuje konvergenci.
Response se smí commitnout jen při shodě request anchoru s aktuálním cursorem.
Message identity, intervaly, parent/thread, read hodnoty a outbox reconciliation
se mění atomicky a schema diagnostika neobsahuje hodnoty zpráv.

`referenceId` je korelace, ne idempotency key. První povolený durable registry
kind je pouze `textSend` s revision
`talk-chat-text-send-f2958bb-f9b9e947-r1`. Request prokazatelně zastavený před
body může být retryable. Možná odeslané body, přerušený proces, `201 null` nebo
identity mismatch přejdou do `awaitingConfirmation` a nesmějí se automaticky
znovu odeslat. Jedna autoritativní shoda dokončí operaci, více shod zůstane
ambiguous a nula shod neprokazuje neprovedení. Ruční resend vyžaduje varování
před duplicitou a nesmí pokračovat po nalezené serverové shodě. HTTP 400
`error=message` a 5xx jsou ambiguous; pouze doložený pre-save 429
`error=mentions` je retryable podle `Retry-After` nebo lokálního backoffu.
V jedné room platí FIFO a single-flight, různé rooms mohou pokračovat souběžně.
Cross-room private-reply wire formát je známý, ale command admission zůstává bez
plného eligibility snapshotu odmítnutý. Neznámý kind nebo revision admission
odmítne.

Pure Dart single-use plán nyní dokládá společný candidate snapshot pro chat
merge a outbox confirmation i úplný rollback zahozením plánu. Společná SQLite
transakce zůstává povinným, ale dosud neprokázaným runtime invariantem.

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

Pure Dart talk_protocol + Flutter app + samostatná push gateway. Storage a sync
zůstávají uvnitř app, dokud další skutečná implementace neodůvodní package.

### D-008: Standardní Notifications app

Stav: Přijato jako kompatibilní serverová hranice.

Vlastní gateway zachová Notifications v2 protokol. Nový Talk event listener se
nevytváří, protože by nepokryl úplnou notification a markProcessed semantiku.

### D-009: Relační SQLite store

Stav: Přijato pro první implementační baseline 22. srpna 2026.

Message, thread, parent, room a read marker vyžadují atomické transakce.
Použije se Drift. Lokální Flutter 3.44.4/Dart 3.12.2 a pub.dev metadata z
22. srpna 2026 potvrzují kompatibilitu řad Drift 2.34 a `drift_flutter` 0.3.
Lockfile, migration testy a skutečný Android/iOS build zůstávají povinným
důkazem konkrétní verze.

### D-010: Riverpod pro application/UI state

Stav: Přijato pro první implementační baseline 22. srpna 2026.

Chatujme poskytuje ověřený lokální vzor a Riverpod umožní account-scoped
providery. Databázový stav však zůstává zdrojem pravdy; provider nesmí duplikovat
sync store. První řez použije ručně definované providery bez code generation;
generátor se přidá jen tehdy, když sníží skutečnou složitost.

### D-019: Mobilní navigace a form factors

Stav: Přijato jako mobilní implementační baseline.

Telefon používá stack `onboarding → conversations → chat → thread`. Bottom
navigation se nepřidá bez alespoň tří rovnocenných top-level cílů. Tablet a
foldable použijí nad stejným route modelem adaptivní list-detail. Deep link
nejprve kryptograficky nebo lokálním account mappingem vybere `accountId` a až
potom sestaví room/thread stack; nesmí implicitně použít právě aktivní účet.

iOS zachová edge-swipe back a Android systémový i predictive back. Gestures
jsou pouze zkratky s viditelnou alternativou. Touch target má nejméně 44 pt na
iOS a 48 dp na Androidu. Podrobný checkpoint je v
[mobilním návrhu](../plans/2026-08-22-original-flutter-client-design.md).

### D-020: Rich chat jako typovaná online mutation hranice

Stav: Přijato a implementováno v pure Dart runtime; Flutter transport, Drift a
live serverový důkaz zůstávají součástí řezu 4.

Mentions, threads, reactions, edit/delete, pin, reminders a schedule se volí
výhradně z unikátních globálních a lokálních Talk features. Každý request i
response je svázaný s účtem, kanonickým serverem a dostupným room/message/thread
kontextem. Rich stav je account-scoped vrstva nad existujícím chat snapshotem a
mění se jen přes single-use candidate plán.

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

Stav: Přijato a implementováno v pure Dart runtime; Flutter transport, Drift,
live server a platformní UI zůstávají součástí řezu 5.

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

V jedné room platí FIFO a single-flight pro finalizaci. Cancel před finalize
uklízí pouze jobem vlastněnou chunk session a Draft temp soubor; po zahájení
finalize se možný finální soubor automaticky nemaže.

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

## Vyřešené volby

### Q-001: Licence

Stav: Vyřešeno v D-018.

Uživatel zvolil `GPL-3.0-or-later`. Audit původu kódu, assetů a závislostí je
průběžná distribuční brána, nikoli otevřená volba licence.

## Otevřené volby

### Q-002: Minimální platformy

Je nutné určit Android minSdk a minimální iOS. Upstream minima jsou pouze vstup
do rozhodnutí, ne automatická volba.

### Q-003: Identita aplikace a signing

Android `applicationId` je přijaté v D-014. Zbývá iOS bundle ID, jeden Firebase
projekt vydavatele, Android signing owner a Apple/APNs signing workflow.

### Q-004: Offline scope prvního release

Možnosti:

1. Cache historie + textový outbox.
2. Plný outbox včetně upload resume od prvního release.

Architektura podporuje obě, ale acceptance scope a pořadí řezů se liší.

### Q-005: Giphy režim

Možnosti:

1. Poslat URL a použít Talk Reference Provider, stejně jako upstream iOS.
2. Stáhnout GIF a uložit jako Nextcloud attachment.

První varianta je doporučená kvůli shodě se serverovým web/iOS chováním a menší
spotřebě úložiště.

### Q-006: Podporované serverové řady

Je nutné určit minimální Nextcloud/Talk řadu. Multi-server neznamená automaticky
podporu všech historických verzí.

### Q-007: Gateway implementační stack

Volba přijde po contract prototypu. Kritéria:

- ověřená FCM HTTP v1 knihovna;
- RSA/SHA-512 a key parsing;
- bounded concurrency a retry;
- bezpečný secret management;
- snadné nasazení a observability;
- dlouhodobá údržba.

Stack se nemá vybrat podle osobní preference bez prototypu kontraktu.

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
