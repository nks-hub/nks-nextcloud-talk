# Systémový návrh

## Hodnocené varianty

### Varianta A: jeden Flutter projekt

Všechny API klienty, modely, storage a UI jsou v jednom aplikačním projektu.

Výhoda je nejrychlejší začátek. Nevýhodou je silné riziko, že OCS, WebDAV,
signaling a platformní lifecycle prorostou do UI. Pure Dart contract testy a
pozdější CLI diagnostika by závisely na Flutter runtime.

### Varianta B: modulární klient a samostatná gateway

Flutter app používá malý pure Dart balík pro wire protokol. Storage a sync
zůstávají uvnitř aplikace v jasných modulech. Push gateway je samostatná
služba.

To je doporučená varianta. Odděluje skutečné trust a runtime hranice bez
vytváření balíčku pro každou třídu.

### Varianta C: mnoho Dart balíků a federované pluginy od začátku

Každá feature, signaling, storage i platformní funkce mají vlastní package.
To usnadňuje izolaci, ale před existencí druhé implementace vytváří velkou
konfigurační a release režii. Pro první implementaci je to předčasné.

## Doporučená topologie

~~~mermaid
flowchart LR
    UI[Flutter features] --> APP[Application controllers]
    APP --> SYNC[Account-scoped sync engine]
    APP --> STORE[Relational local store]
    SYNC --> STORE
    SYNC --> PROTO[Pure Dart Talk protocol]
    PROTO --> NC[Nextcloud OCS and WebDAV]
    PROTO --> HPB[Internal or HPB signaling]
    PUSH[FCM and APNs platform ingress] --> ROUTER[Push account router]
    ROUTER --> CRYPTO[Signature verify and decrypt]
    CRYPTO --> SYNC
    NC --> GATEWAY[Compatible push gateway]
    GATEWAY --> FCM[FCM HTTP v1]
    GATEWAY -. future calls .-> VOIP[APNs VoIP provider]
    APP --> PLATFORM[Kotlin and Swift platform modules]
    PLATFORM --> MEDIA[Future WebRTC media engine]
~~~

## Repozitářové hranice

Po schválení návrhu:

~~~text
apps/
  mobile/                 Flutter aplikace a platformní targety
packages/
  talk_protocol/          Pure Dart OCS, Talk, WebDAV a wire modely
services/
  push_gateway/           Notifications-compatible FCM gateway
docs/
  research/
  architecture/
  adr/
~~~

Další package vznikne jen tehdy, když má vlastní release/test hranici nebo dvě
reálné implementace. Call signaling může začít jako modul v aplikaci; oddělí se
až při skutečné implementaci internal i HPB transportu.

## Zodpovědnosti

### talk_protocol

- kanonizace server origin a bezpečné skládání URL;
- OCS request headers, envelope a error mapping;
- Login Flow v2 wire modely;
- capability resolver;
- rooms, chat, threads, reactions, polls a call API;
- WebDAV path encoding, upload session a Files share payload;
- Rich Object String transportní modely;
- interní a HPB signaling wire zprávy až ve fázi call přípravy.

Balík nesmí importovat Flutter, UI, secure storage ani konkrétní databázi.

### Account runtime

Každý accountId vlastní:

- kanonický server origin a uživatelskou identitu;
- referenci na app password v secure storage;
- capability snapshot;
- HTTP session a cancel scope;
- long-poll nebo websocket lifecycle;
- sync lane;
- push registration a key references;
- lokální datový partition.

Aktivní UI účet je pouze prezentace. Background push a sync nesmějí používat
globální activeAccount jako autorizační zdroj.

### Sync engine

Jediný vlastník převodu serverových a lokálních událostí do databázového stavu.
UI controller nesmí ručně přepisovat message, thread nebo room tabulky.

Vstupy:

- initial/catch-up HTTP page;
- chat long poll;
- HPB chat relay;
- push wake-up;
- outbox response;
- explicitní refresh;
- změna credentials nebo capabilities.

Výstupem je atomicky commitnutý lokální stav, který UI pouze pozoruje.

### Flutter features

Feature moduly skládají application use cases a UI:

- onboarding/accounts;
- conversations;
- chat/threads;
- composer/media/voice/Giphy;
- search/shared items;
- notifications/settings;
- calls až po signaling řezu.

Transportní DTO se nevystavuje widgetům. UI dostává doménový read model s
explicitními loading, stale, pending a failed stavy.

### Platformní vrstva

Android:

- FCM background entry point;
- notification actions a channels;
- secure key storage;
- foreground service pro budoucí call;
- audio focus, Bluetooth, PiP a screen capture až při call řezu.

iOS:

- Keychain a App Group;
- Notification Service Extension;
- APNs/FCM token lifecycle;
- PushKit token lifecycle až v call řezu;
- později PushKit, CallKit a ReplayKit Broadcast Extension.

Platformní modul neimplementuje Talk business pravidla. Předává typované
události do account routeru nebo call coordinatoru.

### Push gateway

- kompatibilní POST/DELETE /devices;
- 409 conflict recovery s ověřením `cloudId` podle push-v2;
- izolovaný cloudId verifier s přesným parserem, public-HTTPS-only egress,
  DNS/IP revalidací, zakázanými redirecty a bounded response;
- kompatibilní POST /notifications;
- ověření registračních a notification podpisů;
- mapping deviceIdentifier na jednu nebo více typovaných delivery endpoints;
- opaque forwarding přes FCM HTTP v1;
- hranice pro budoucí přímý APNs VoIP provider;
- invalid-token cleanup, rate limits, retry a redigovaný audit;
- žádný plaintext chat obsah.

Gateway není Talk plugin ani druhý notification engine.

cloudId verifier nesmí přeposlat app password, push token ani interní header.
Veřejná gateway odmítá loopback, private, link-local a reserved IPv4/IPv6 i
DNS rebinding. LAN-only server proto nemá garantovaný 409 recovery; vlastní
gateway jej smí povolit jen explicitním operátorským allowlistem a oddělenou
egress politikou.

Veřejný store build používá jeden Firebase projekt a gateway vydavatele pro
všechny podporované Nextcloud servery. `proxyServer` předává klient při runtime
registraci; správce serveru nedostává Firebase credential a nevytváří vlastní
mobilní build. Gateway přijímá libovolný validní server až po kryptografickém
ověření registrace a payloadu, ne podle ručně udržovaného tenant allowlistu.

## Dependency pravidla

Povolený směr:

UI → application → sync/store/protocol → platformní nebo síťová hranice.

Zakázané směry:

- protocol → Flutter UI;
- gateway → mobilní databáze;
- widget → Dio/HTTP;
- platformní notification callback → activeAccount;
- repository → konkrétní obrazovka;
- feature controller → přímý zápis několika synchronizačních tabulek.

## Runtime toky

### Přidání účtu

1. Uživatel zadá server origin.
2. Klient jej normalizuje, ověří status a anonymní onboarding capabilities.
3. Login Flow vrátí app password a klient znovu ověří credential server.
4. Vznikne náhodné accountId a secret se zapíše do Keystore/Keychain.
5. Lokální transakce vytvoří Account a credential reference ve stavu
   capabilitiesPending.
6. Přihlášený capability request uloží account-scoped snapshot a přepne účet
   do ready.
7. Spustí se initial room sync.
8. Push registrace běží samostatně a její selhání neznefunkční chat.

Síťová chyba v kroku 6 ponechá zabezpečený účet v capabilitiesPending a request
lze opakovat bez nového Login Flow. Přesný wire a trust kontrakt popisuje
[přidání Nextcloud účtu](client-bootstrap-api.md).

### Otevření místnosti

1. UI čte lokální room a dostupné chat blocks.
2. Sync engine vybere anchor a provede catch-up.
3. Merge transakce opraví messages, threads, room preview a read markers.
4. Long poll nebo HPB relay pokračuje od potvrzeného anchoru.
5. UI zobrazuje stale indikaci, dokud server catch-up není potvrzený.

History a future mají samostatné cursory. Response se smí commitnout jen tehdy,
když její request anchor stále odpovídá uloženému scope. Autoritativní hranici
určuje `X-Chat-Last-Given`, nikoli poslední viditelná message; history a future
`304` mají odlišný význam. Podrobný wire a merge model je v
[kontraktu chat zpráv](chat-messages-api.md).

### Odeslání textu

1. Databázová transakce vytvoří temporary message a OutboxOperation se
   stabilním referenceId.
2. Account sync lane operaci označí sending.
3. talk_protocol odešle POST chat.
4. HTTP odpověď nebo relay koreluje pending operaci přes referenceId.
5. Jedna transakce nahradí temporary identitu server message id a dokončí
   outbox.
6. Ztracená odpověď přejde do awaitingConfirmation a spustí catch-up.
7. Bez potvrzení se POST automaticky neopakuje; Talk referenceId není unikátní
   a uživatelský resend může vytvořit druhou serverovou zprávu.

Outbox admission před krokem 1 ověří capability a přesnou revision replay
kontraktu. První povolený kind je pouze `textSend`. Relay může operaci dokončit
dřív než HTTP response; pozdější shodná response je idempotentní. Nula shod v
jednom catch-up okně operaci nevrací do queued a více shod se neslučuje do jedné
serverové identity. Jedna room používá FIFO a single-flight, jiné rooms mohou
běžet souběžně. Cross-room private-reply wire payload umíme normalizovat, ale
nový command admission zůstává bez plného eligibility snapshotu odmítnutý.

### Příchozí push

1. Platformní callback předá opaque envelope.
2. Standardní payload nemá deviceIdentifier. Router ověří podpis proti
   omezené sadě user public keys; gateway route hint smí být jen předvýběr.
3. Pro všechny signature shody zkusí per-account device private key s výchozím
   OAEP a podle podporované matice s legacy PKCS#1 v1.5 paddingem a validuje
   plaintext schema.
4. Právě jeden validní kandidát vybere accountId nezávisle na aktivní
   obrazovce. Nula nebo více shod nesmí spustit account akci; chyba klíče,
   paddingu ani schématu se nesmí stát oracle nebo citlivým logem.
5. Silent delete upraví pouze account-scoped systémovou notifikaci.
6. Ostatní události probudí account sync lane.
7. OCS/chat API dodá autoritativní stav.

### Odhlášení

1. Zastaví se account long poll/websocket a nové outbox claims.
2. Klient zkontroluje queued, ambiguous, failed outbox a upload jobs. Bez
   explicitní volby uživatele je nesmaže.
3. Online odstraní Nextcloud push registraci.
4. Odstraní gateway device mapping.
5. Odvolá app password, pokud to server podporuje a uživatel odstraňuje účet.
6. Až po vzdáleném cleanup smaže secure secrets.
7. V jedné lokální transakci odstraní account partition a notification routing.

Při offline odebrání musí uživatel výslovně zahodit neodeslaná data. Minimální
RevocationTombstone uchová credential reference a podepsaná cleanup data v
secure storage po pevně omezenou dobu. Po úspěchu se smaže. Po vypršení se secret
odstraní a UI přizná nutnost ruční revokace na serveru; nesmí hlásit falešné OK.

## Call-ready hranice

Příprava na hovory znamená reálný návrh, ne prázdné implementace:

- CallCoordinator vlastní stavový automat.
- InternalSignalingTransport a HpbSignalingTransport jsou skutečné dvě varianty.
- MediaEngine se přidá až při WebRTC implementaci.
- CallPlatformBridge odděluje Android/iOS lifecycle.

Minimální stavy:

- idle;
- joining;
- ringing;
- connecting;
- connected;
- reconnecting;
- leaving;
- ended;
- failed.

Signaling contract testy musí ověřit hello, resume, room join/leave, session
ztrátu, reconnect a MCU/no-MCU odlišnosti ještě před zapojením kamery.

## Bezpečnostní hranice

- Server origin se validuje proti HTTPS; explicitní dev výjimka nesmí existovat
  v release buildu.
- Redirect nesmí tiše změnit origin a odnést Authorization na jiný host.
- WebDAV path segmenty se kódují odděleně; nikdy se neskládají prostou
  interpolací uživatelského názvu souboru.
- OCS envelope i HTTP status se validují.
- App password a privátní RSA klíč se neukládají do běžné DB.
- Gateway origin pochází z důvěryhodné konfigurace aplikace, ne z libovolného
  připojeného Nextcloud serveru.
- Logovací kontext smí obsahovat accountId hash, endpoint template, request id a
  status, nikoli URL s uživatelem, token nebo payload.
- Push gateway drží FCM service account pouze v secret store.
- Budoucí APNs provider key zůstává jen v gateway secret store a nikdy na
  Nextcloud serveru nebo v mobilní aplikaci.
- Custom certificate trust je per server/account a vyžaduje zobrazení
  fingerprintu; nesmí se řešit globálním vypnutím TLS.

## Pozorovatelnost

Lokální diagnostika:

- anonymizovaný account scope;
- sync lane a poslední potvrzený anchor;
- počet pending/failed outbox operací;
- poslední capability refresh;
- push registration stav;
- websocket resume/reconnect stav;
- upload fáze bez lokální cesty a názvu souboru.

Gateway metriky:

- accepted/rejected registration;
- FCM latency a status class;
- queue depth a retry age;
- unknown devices a invalid tokens;
- rate-limit rejects;
- žádné labely s tokenem, user id nebo room id.
