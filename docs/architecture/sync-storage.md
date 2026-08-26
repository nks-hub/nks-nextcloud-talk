# Synchronizace a lokální data

## Databázová volba

Požadované atomické vztahy jsou relační. Autoritativní lokální store proto je
SQLite s foreign keys, transakcemi a verzovanými migracemi. Flutter aplikace
používá Drift; aktuální schema v10 drží účty, konverzace, avatary, chat scope,
zprávy, text-send operace, drafty a durable attachment joby. Otevření databáze
zapíná a kontroluje foreign keys. Novější `user_version` se před jakoukoli
migrací fail-closed odmítne, takže rollback aplikace neoznačí neznámé schema
svou starší verzí.

Hive může zůstat pouze pro jednoduché neautoritativní preference. Není vhodný
jako hlavní Talk store, protože message, parent, thread, room a read marker se
musí měnit v jedné transakci.

## Identita

### Server origin

Před uložením:

- pouze podporované schéma;
- lowercase host;
- normalizovaný port;
- odstraněný trailing slash;
- zachovaný případný Nextcloud subpath;
- žádné credentials v URL.

Redirect a discovery výsledek se ukládá odděleně od uživatelem zadané hodnoty.

### accountId

Lokální náhodné UUID vytvořené po úspěšném loginu. Není odvozené pouze z userId,
protože stejný uživatel může mít více app-password instalací a více serverů.

Každý primární nebo unikátní klíč synchronizačních dat začíná accountId.

## Logický model

<!-- markdownlint-disable MD013 -->

| Entita | Klíč | Účel |
| --- | --- | --- |
| Account | accountId | Server, login identity, credential reference a lifecycle |
| CapabilitySnapshot | accountId + scope + revision | Raw a normalizované feature/config hodnoty |
| Conversation | accountId + roomToken | Room metadata, permission, counters a poslední message |
| Participant | accountId + roomToken + actor key | Účastník, role, session a federation data |
| Message | accountId + roomToken + messageId nebo localId | Autor, text, state, parentMessageId, parentRoomToken a thread vazby |
| MessageParameter | accountId + roomToken + message key + placeholder | Rich Object String parameter bez ztrát |
| ReactionSummary | accountId + roomToken + message key + reaction | Count, self flag a volitelně zvlášť načtení actors |
| Thread | accountId + roomToken + threadId | Original message, title, counts a subscription |
| ChatBlock | accountId + roomToken + thread scope + start/end | Souvislý potvrzený interval historie |
| ReadMarker | accountId + roomToken | lastRead, lastCommonRead a explicit unread state |
| OutboxOperation | accountId + operationId | Perzistentní lokální mutace, korelace a outcome certainty |
| UploadJob | accountId + uploadId | Lokální media, WebDAV a Talk share fáze |
| PushRegistration | accountId + channel | Connector instance, aktuální subscription generation, activation a revocation stav |
| PushEndpoint | accountId + channel + generation | Reference na Android Web Push subscription secrets nebo iOS APNs/PushKit token |
| NotificationRoute | accountId + platform tag/id | Server nid, roomToken, messageId a threadId |
| RevocationTombstone | revocationId | Minimální secure cleanup data po lokálním odebrání účtu |
| CallSession | accountId + call id | Pouze nutný perzistentní recovery stav, ne media objekty |

<!-- markdownlint-enable MD013 -->

Raw server JSON se může uchovat jen jako diagnostická nebo forward-compatible
část modelu s jasnou migrací. Doménová logika nesmí pokaždé číst dynamickou mapu.

## Bootstrap stav účtu

Account po prvním durable commitu začíná jako `capabilitiesPending`. Credentials
už jsou bezpečně uložené, ale room sync, push registrace ani feature UI se ještě
nesmějí spustit. Úspěšný přihlášený capability snapshot jej přepne do `ready`.

Síťová nebo 5xx chyba ponechá `capabilitiesPending` a dovolí bezpečný retry.
HTTP 401 přepne účet do `reauthRequired`; anonymní capabilities jej nikdy
nesmějí přepnout do `ready`.

## Message identity

Serverová zpráva má messageId. Lokální pending zpráva má localId a referenceId.
Upstream dovoluje více serverových zpráv se stejným referenceId. Hodnota je
proto korelace, ne serverová idempotency key.

Pravidla:

- referenceId je UUID a nemění se;
- localId je unikátní pouze lokálně, ale vždy pod accountId;
- server response nebo relay může spojit messageId s právě čekající lokální
  operací přes referenceId;
- dvě různá serverová messageId se stejným referenceId se nesmějí tiše sloučit;
- pokud server nevrátí referenceId ve staré variantě, používá se opatrná
  kombinace response vazby a server id, nikdy text + timestamp;
- update a delete cílí server messageId;
- temporary message se nemaže před atomickým vložením server identity.

Cross-room reply vždy uchovává `replyTo`, `replyToToken` a normalizovaný
`parentRoomToken`. Outbox i UploadJob musí po restartu rekonstruovat stejný
request, ne odvodit parent room z právě otevřené konverzace.

Named-thread text send je samostatná větev: ukládá `threadId`, ale žádné
`replyTo`, `replyToToken` ani `parentRoomToken`. Plain text send nemá ani reply,
ani thread vazbu. Confirmation a restart recovery musí toto rozlišení zachovat,
protože stejné serverové ID nesmí převést reply na named thread nebo naopak.

Nový Giphy send nepoužívá textový outbox. Vybranou URL použije pouze
account-scoped resolver ke stažení validních GIF bajtů. Bajty se před admission
zkopírují do durable app-owned zdroje a attachment job uloží handle, SHA-256,
MIME `image/gif`, stabilní `giphy-<sha16>.gif`, account, room a případný thread.
Další průběh je totožný s obrázkovou přílohou: Draft, WebDAV upload, finalize a
autoritativní chat confirmation. URL se do serverové textové historie neukládá.

Starší zprávy mohou stále obsahovat původní skrytou wire URL. Jejich renderer ji
account-scoped vyřeší a skryje, ale tento compatibility read path se nesmí znovu
použít pro nové odeslání.

## Chat blocks

ChatBlock reprezentuje interval, u kterého klient ví, že je souvislý.

Operace:

- initial page vytvoří první potvrzený interval;
- backward page rozšíří nebo spojí sousední interval;
- lookIntoFuture rozšíří horní hranici;
- delete neznamená automaticky mezeru, pokud server poskytl delete event;
- neplatný/chybějící pagination anchor nebo expirovaný kontext označí gap;
- číselná nespojitost message id sama o sobě gap není, protože id nemusí být v
  jedné room souvislá;
- thread history má vlastní scope, aby se nemíchala s hlavním room streamem.

Pouhý nejvyšší messageId není dostatečný důkaz, že mezi zprávami nic nechybí.

Chat GET navíc nesmí odvozovat hranici intervalu jen z viditelných messages.
`X-Chat-Last-Given` je autoritativní anchor i pro `200 []`, pokud server
zpracoval neviditelnou nebo expirovanou zprávu. History `304` ukončuje starší
historii, future `304` potvrzuje konvergenci. Samostatná změna
`X-Chat-Last-Common-Read` neposouvá žádný message cursor.

Každý HTTP request nese anchor, ze kterého vyšel. Merge jej před commitem
porovná s aktuálním `historyCursor` nebo `futureCursor`; opožděný future výsledek
se starým anchorem se celý odmítne. Přesný executable model je v
[kontraktu chat zpráv](chat-messages-api.md).

## Merge transakce

Každý vstup se nejdřív normalizuje na SyncEvent:

- accountId;
- roomToken;
- source;
- event kind;
- server ids/referenceId;
- payload;
- receivedAt;
- případný anchor/header context.

V jedné DB transakci:

1. Ověřit account a room scope.
2. Deduplikovat event.
3. Upsertnout nebo tombstonovat message.
4. Sloučit message parameters a reactions.
5. Opravit parent a thread original.
6. Aktualizovat thread summary.
7. Aktualizovat room last message a counters.
8. Aplikovat read marker pravidla.
9. Rozšířit nebo označit chat blocks.
10. Potvrdit odpovídající outbox operaci.

UI notification se publikuje až po commitu.

## Outbox

### Stavy

<!-- markdownlint-disable MD013 -->

| Stav | Význam | Povolený další stav |
| --- | --- | --- |
| queued | Bezpečně uložené, ještě neclaimnuté | sending, cancelled |
| sending | Jedna account lane operaci provádí | awaitingConfirmation, retryable, failed |
| awaitingConfirmation | Odpověď je nejednoznačná; čeká se na catch-up/relay | completed, retryable, failed |
| retryable | Přechodná chyba a vypočtený nextAttemptAt | sending, cancelled |
| failed | Automatický retry skončil nebo server operaci odmítl | queued po ručním retry, cancelled |
| completed | Serverový stav atomicky potvrzen | terminální a následně retence/cleanup |
| cancelled | Uživatel operaci zrušil, pokud to fáze dovoluje | terminální |

<!-- markdownlint-enable MD013 -->

Retry policy je data, ne Timer v UI:

- operationKind a payload schema version;
- replayContractRevision vázaná na capabilities a ověřený upstream contract;
- attemptCount;
- nextAttemptAt;
- errorClass;
- poslední redigovaný status;
- server Retry-After;
- závislost na jiné operaci.

Po pádu procesu se operace nalezená ve `sending` přesune do
`awaitingConfirmation`, nikoli do `queued`. Klient neví, zda server request
přijal. Automaticky se znovu odešle pouze operace s důkazem, že request
neopustil klienta.

Permanentní chyba se nemaže. Uživatel musí vidět, co nebylo odeslané.

### Replay contract gate

Durable outbox přijímá pouze operationKind z verzovaného registru. Lokální
operationId slouží pro plánování a deduplikaci workeru; nedělá serverový request
idempotentní. Totéž platí pro referenceId.

Každý replay contract musí být vázaný na požadované capabilities, ověřený
upstream SHA nebo contract fixture a musí definovat:

- kanonický serverový cíl a požadovaný výsledný stav;
- důkaz, že request neopustil klienta a lze jej bezpečně poslat;
- autoritativní dotaz nebo event pro reconciliation po nejednoznačném výsledku;
- jednoznačný důkaz completed, permanent failure a případné compensation;
- zacházení s 401, 403, 404, 409, 429, 5xx, timeoutem a ztracenou odpovědí;
- ruční akci uživatele včetně varování před duplicitou nebo přepsáním stavu;
- verzi a redakční pravidla uloženého payloadu.

První admission matice je ověřená proti Talk master
`f2958bb25be6604240c58a3faf9a2033a30d20e5` a stable v24.0.4
`f9b9e9474e3621b47f74bf8890c4642cb49eed97`. Posuzované implementace jsou mezi
těmito SHA shodné. Nová podporovaná řada přesto vyžaduje nový contract fixture.

<!-- markdownlint-disable MD013 -->

| operationKind | Identita a autoritativní reconciliation | Politika po ambiguous výsledku |
| --- | --- | --- |
| textSend | roomToken + referenceId; chat catch-up/relay a konkrétní messageId | `awaitingConfirmation`; žádný blind POST, ruční resend varuje před duplicitou |
| messageEdit | roomToken + messageId + cílový text; message context/chat refresh | Potvrdit viditelný cílový text, jinak čekat; replay může zdvojit system message |
| messageDelete | roomToken + messageId; ověřený deleted verb/tombstone | Reconcile před retry; 404/405 samy neprokazují výsledek a souběh není bezpečný |
| reactionAdd / reactionRemove | roomToken + messageId + actor + emoji; GET reaction/message | Sériově konvergentní, souběh neprokázaný; nejdřív reconcile, jinak čekat |
| read | roomToken + explicitní lastReadMessage; refetch room/read marker | Retry-safe pouze s uloženým explicitním messageId, nikdy s „aktuálně poslední“ |
| markUnread | roomToken + explicitně odvozený cílový marker; refetch room/read marker | DELETE znovu počítá předchozí zprávu, proto se blind replay zakazuje |
| favorite / archive / notificationLevel | roomToken + absolutní hodnota; refetch conversation | Retry-safe setter; archive navíc vyžaduje `archived-conversations-v2` |
| reminderSet / reminderDelete | user + roomToken + messageId; GET reminder | Retry-safe update-or-insert/delete, po unique race rozhodne autoritativní GET |
| scheduledCreate | obsah + sendAt bez klientského/serverového id; schedule list | `awaitingConfirmation`; replay by vytvořil druhý řádek |
| scheduledEdit | scheduledMessageId + absolutní hodnoty; schedule list | Retry-safe jen dokud položka existuje a ještě nebyla odeslaná |
| scheduledDelete | scheduledMessageId; schedule list | Retry-safe jen před sendAt; po něm absence nerozliší delete od send |
| draftFolderProbe | user + room + folder; WebDAV PROPFIND | Retry-safe get-or-create; rename návrh se po každém běhu znovu ověří |
| uploadBytes | náhodná temp URI + checksum/session; WebDAV remote state | Resume z ověřeného offsetu jen před finalize; poté by PUT vytvořil nový draft |
| attachmentFinalize | draft file + room + referenceId; chat scan a WebDAV draft/final stav | `awaitingConfirmation`; move může uspět před selháním chat message |
| classicShare | WebDAV node + OCS share + chat scan | Zakázaný automatic replay, dokud samostatný Nextcloud core audit neprokáže kontrakt |
| unknown | žádná | Odmítnout na command hranici; nequeueovat ani fake replayovat |

<!-- markdownlint-enable MD013 -->

Podrobný zdrojový důkaz je v
[protokolové matici](../research/protocol-parity.md#ověřená-replay-semantika).
Contract registry musí vedle kind ukládat i revision; změna capability nebo
podporované serverové řady nesmí starou queued operaci tiše přehrát podle nové
semantiky.

### Pořadí

- Operace v jedné room se provádějí deterministicky podle dependencies a času.
- Edit/delete pending message závisí na potvrzení jejího send.
- Attachment share závisí na úspěšném WebDAV uploadu.
- Různé rooms lze zpracovávat souběžně s per-server limitem.
- Scheduler musí být férový mezi účty; jeden nedostupný server nesmí blokovat
  ostatní.

## Text send failure matrix

<!-- markdownlint-disable MD013 -->

| Situace | Akce |
| --- | --- |
| Offline, DNS nebo connect chyba před odesláním body | retryable se stejným referenceId |
| Timeout/reset po možném odeslání body | awaitingConfirmation a autoritativní catch-up/relay; žádný blind POST |
| HTTP 400 `error=message` | awaitingConfirmation; stejný kód může vzniknout i po uložení commentu |
| HTTP 400/403 `error=reply-to`, 404 `error=actor`, 413 `error=message` | failed; jde o doložené pre-save rejection větve |
| HTTP 429 `error=mentions` | retryable podle Retry-After nebo lokálního bounded backoff; větev je před save |
| HTTP 5xx | awaitingConfirmation, pokud contract důkaz neprokáže, že request nebyl commitnutý |
| HTTP/OCS 401 | pozastavit account lane a ověřit revokovaný app password; stav operace zachovat nebo bezpečně vrátit do retryable podle zdroje eventu |
| Jiná OCS business chyba | awaitingConfirmation, dokud není doložená pre-save větev |
| Relay dorazí dřív než HTTP response | pending operace se koreluje přes referenceId; HTTP potvrdí konkrétní messageId |

<!-- markdownlint-enable MD013 -->

Pokud catch-up zprávu najde, operace se dokončí bez dalšího POST. Pokud ji
nenajde, samotná absence ještě nedokazuje, že server request nepřijal. Operace
zůstane `awaitingConfirmation`. Uživatel může zvolit explicitní resend s
upozorněním, že Talk nevynucuje unikátní referenceId a server může vytvořit
duplicitu, ale pouze dokud není známá žádná serverová shoda.

První executable registry položka je pouze `textSend` revision
`talk-chat-text-send-f2958bb-f9b9e947-r2`. Admission, claim, chyba před body,
ambiguous transport, restart, autoritativní nula/jedna/více shod, relay před
HTTP response, transakční rollback, re-auth, per-room FIFO/single-flight a
account izolace mají executable fixture. R2 přidává named-thread `threadId` a
vyžaduje pro něj aktuální lokální `threads` capability; r1 operace se pod r2
autoritou nereplayuje. Flutter schema v5 zavedlo nullable `threadId`; aktuální
schema v7 jej zachovává. File-backed reopen zachová queued i sending operaci a
restart recovery převádí přerušený `sending` na `awaitingConfirmation`. Chat
message/scope/outbox confirmation se commitují jednou Drift transakcí. Ostatní
operation kinds v tabulce zůstávají návrhem a nesmějí se queueovat, dokud
nedostanou vlastní stejně silný kontrakt.

## Read marker

Běžné čtení posouvá lastRead dopředu. Explicitní mark-unread je jiný příkaz a
vrací marker na předchozí message id; pokud žádná předchozí zpráva není, Talk
používá `ChatManager::UNREAD_FIRST_MESSAGE`, tedy sentinel -2.

Proto:

- obecný merge nesmí mechanicky použít max pro explicit unread event;
- lokální pending marker má operation kind read nebo markUnread;
- serverový lastCommonRead se neodvozuje z lokálního lastRead;
- odchozí `read` projekce je povolená pouze pro vlastní dokončenou operaci se
  skutečnou cached server confirmation a `messageId <= lastCommonRead` ve
  stejném account/room/thread scope;
- nepotvrzený nebo ambiguous send zůstává `sending` a lokální model nevytváří
  nedoložený stav `delivered`;
- notification clear se provede až po serverem potvrzeném nebo bezpečně
  odvozeném read stavu.

## Attachment job

### Fáze

1. selected nebo recorded;
2. localPrepared;
3. draftResolved;
4. uploading;
5. uploaded;
6. sharing;
7. completed;
8. retryable nebo failed;
9. cancelled a cleanup.

UploadJob uchovává:

- accountId a roomToken;
- lokální app-owned sandbox cestu nebo content URI s ověřeným persistable
  grantem;
- MIME, velikost, checksum a bezpečný display name;
- Draft folder a remote path;
- upload session/chunk state;
- referenceId;
- caption, replyTo, replyToToken, parentRoomToken a thread metadata;
- server file/share identity;
- cleanup state.

Pokud upload uspěje a share selže, job nesmí nahrávat stejný soubor znovu.
Pokud uživatel zruší chunk upload, klient uklidí dočasnou serverovou session
podle podporovaného WebDAV toku.

Voice message používá stejný job s messageType=voice-message. Recorder lifecycle
a dočasný soubor jsou platformní zdroj, nikoli zvláštní chat transport.

Přechod do `localPrepared` je povolen jen po durable app-owned kopii nebo po
úspěšném získání persistable URI oprávnění. Před resume po restartu klient znovu
otevře zdroj a ověří velikost i checksum. Picker temp path nebo dočasný grant
nesmí být jediným zdrojem pending uploadu.

Flutter HTTP transport je napojený na account-scoped `AttachmentRepository`,
`AttachmentService` a Drift joby. Chunk používá efektivní bounded seek, nikoli
nové čtení od byte nula; cancel/timeout/close zavřou i pozdě získaný lease a
cleanup pokračuje dalšími akcemi v jednom bounded budgetu. Restart obnoví
rozpracované uploady a nejednoznačné finalize zůstane viditelné pro
reconciliation. Obrázková příloha s validním preview se od commitu `8724281`
otevírá v interním autentizovaném vieweru ve success, loading i error stavu;
externí fallback zůstává jen pro non-image nebo chybějící preview. Automatizace
neprokazuje aktuální live Nextcloud upload ani tap vieweru na zařízení.

## Multi-account concurrency

- Každý account má vlastní sync lane a cancellation scope.
- Globální scheduler omezuje souběžné HTTP/upload operace.
- DB transakce vždy filtruje accountId i při znalosti globálně vypadajícího
  messageId.
- Android Web Push callback se routuje přes aplikací zvolenou connector instance
  svázanou s `accountId` a právě aktuální subscription generation. Neznámá nebo
  nahrazená instance/generation se odmítne; payload pouze probudí account-scoped
  OCS catch-up.
- Budoucí iOS relay callback nemá důvěryhodný `deviceIdentifier`. Account router
  nejdřív ověří signature proti omezené sadě user public keys a poté zkusí
  decrypt odpovídajícími per-account device keys s výchozím OAEP a doloženým
  legacy PKCS#1 v1.5 paddingem. Právě jeden validní kandidát určí `accountId`;
  route hint je pouze předvýběr a chyby nesmějí tvořit oracle ani citlivé logy.
- Deep link nese accountId.
- Logout nejdřív zastaví lane, aby po smazání partition nepřišel opožděný write.

NotificationRoute se vždy klíčuje přes accountId. Stejné serverové `nid` nebo
platformní notification id na dvou serverech nesmí kolidovat. `delete-all`
maže pouze systémové notifikace vybraného accountId.

## Odebrání účtu a revokace

Odebrání účtu nesmí tiše smazat queued, retryable, awaitingConfirmation,
failed outbox ani rozpracovaný upload. UI nabídne:

1. odebrání odložit a operace dokončit;
2. exportovat diagnostický seznam bez secretů a explicitně operace zahodit;
3. zrušit odebrání.

Online tok nejprve zastaví lane, odstraní per-account Web Push nebo APNs
registraci z Nextcloudu a případný iOS relay mapping, odvolá app password a
teprve potom odstraní secret a account partition.

Při offline odebrání může UI účet skrýt až po explicitním zahození lokálních
operací. Samostatný RevocationTombstone v secure storage drží jen credential
reference a podepsaná data nutná pro cleanup. Má pevnou retenční lhůtu,
viditelný stav a retry. Po vypršení se secret odstraní a uživatel dostane
konkrétní pokyn k ručnímu odvolání app passwordu na serveru; neúspěch se nesmí
vydávat za dokončenou revokaci.

## Migrace

Každá DB verze obsahuje:

- forward migraci;
- validaci foreign keys a unikátních indexů;
- restart-safe postup pro velké tabulky;
- test upgradu z každé podporované release verze;
- export diagnostiky bez message contentu;
- rollback aplikace nesmí otevřít novější schema a tiše poškodit data.

Secret-store migrace je oddělená od DB migrace. Starý secret se odstraní až po
ověřeném zápisu nového a aktualizaci credential reference.

## Povinné testy

- dvě zprávy vytvořené ve stejné milisekundě;
- ztracená HTTP odpověď a následný relay;
- ztracená odpověď bez relay zůstane awaitingConfirmation a neprovede blind
  resend;
- dvě serverové zprávy se stejným referenceId zůstanou dvě zprávy;
- relay před HTTP odpovědí;
- dvě souběžná catch-up volání;
- mezera mezi dvěma chat blocks;
- message edit/delete/reaction během otevřeného threadu;
- mark-unread po nově přečtené zprávě;
- restart v každé outbox a upload fázi;
- restart/reboot otevře durable sandbox copy nebo persistable URI grant;
- dva účty se stejným server userId;
- stejný roomToken na dvou serverech;
- logout během long pollu a uploadu;
- offline odebrání účtu s pending/failed daty a revocation tombstone;
- push pro neaktivní účet;
- push pro stejný server/user ve dvou accountId s různými device keys;
- push decrypt s výchozím OAEP i legacy PKCS#1 v1.5 paddingem a bez oracle;
- kolidující platform notification id a `delete-all` na dvou účtech;
- DB upgrade s pending outboxem;
- prázdné pole versus objekt u známých upstream JSON variant.
