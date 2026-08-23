# Kontrakt chat zpráv

Datum ověření: 22. srpna 2026.

Stav: OpenAPI, syntetické request/response fixture, capability resolver,
transakční merge, durable text-send outbox a bezpečné live režimy jsou
spustitelné. Produkční Flutter klient zatím neexistuje.

## Rozsah

Kontrakt pokrývá čtyři existující Talk operace:

- `GET /ocs/v2.php/apps/spreed/api/v1/chat/{token}`;
- `POST /ocs/v2.php/apps/spreed/api/v1/chat/{token}`;
- `POST /ocs/v2.php/apps/spreed/api/v1/chat/{token}/read`;
- `DELETE /ocs/v2.php/apps/spreed/api/v1/chat/{token}/read`.

OpenAPI 3.1 je v
[`contracts/chat-messages/openapi.json`](../../contracts/chat-messages/openapi.json).
Schema zachovává neznámá serverová pole, ale vyžaduje identity a hodnoty nutné
pro bezpečný merge.

## Serverový a klientský baseline

Serverový POST tok je ověřený na Talk master
[`f2958bb25be6604240c58a3faf9a2033a30d20e5`](https://github.com/nextcloud/spreed/blob/f2958bb25be6604240c58a3faf9a2033a30d20e5/lib/Controller/ChatController.php#L381-L463)
a stable v24.0.4
[`f9b9e9474e3621b47f74bf8890c4642cb49eed97`](https://github.com/nextcloud/spreed/blob/f9b9e9474e3621b47f74bf8890c4642cb49eed97/lib/Controller/ChatController.php#L376-L458).
GET tok je ověřený na master
[`f2958bb`](https://github.com/nextcloud/spreed/blob/f2958bb25be6604240c58a3faf9a2033a30d20e5/lib/Controller/ChatController.php#L873-L964)
a stable
[`f9b9e94`](https://github.com/nextcloud/spreed/blob/f9b9e9474e3621b47f74bf8890c4642cb49eed97/lib/Controller/ChatController.php#L868-L959).
Read/unread tok je ověřený na master
[`f2958bb`](https://github.com/nextcloud/spreed/blob/f2958bb25be6604240c58a3faf9a2033a30d20e5/lib/Controller/ChatController.php#L1907-L2007)
a stable
[`f9b9e94`](https://github.com/nextcloud/spreed/blob/f9b9e9474e3621b47f74bf8890c4642cb49eed97/lib/Controller/ChatController.php#L1889-L1989).
Ukládání `referenceId` je ověřené v
[`ChatManager`](https://github.com/nextcloud/spreed/blob/f2958bb25be6604240c58a3faf9a2033a30d20e5/lib/Chat/ChatManager.php#L383-L524).

Klientské intervaly, catch-up a optimistic-send chování jsou porovnané s iOS
SHA
[`2d31eda5e2acbf3cef27aa289376942bdf0de25d`](https://github.com/nextcloud/talk-ios/blob/2d31eda5e2acbf3cef27aa289376942bdf0de25d/NextcloudTalk/Chat/NCChatController.swift#L92-L398)
a Android SHA
[`5428960f9d1eca708df1b39a0831141dcbba4729`](https://github.com/nextcloud/talk-android/blob/5428960f9d1eca708df1b39a0831141dcbba4729/app/src/main/java/com/nextcloud/talk/chat/data/network/ChatMessageSyncer.kt#L39).
Jde o clean-room specifikaci pozorovaného chování, ne překlad upstream kódu.

## Capability profil

Resolver používá přesné feature hodnoty, nikdy samotné číslo release:

| Funkce | Nutné podmínky |
| --- | --- |
| Read | `chat-v2` |
| Text send | `chat-v2` + `chat-reference-id` |
| Reply | text send + `chat-replies` |
| Cross-room private reply wire | reply + `private-reply`; viz omezení níže |
| Background catch-up | read + `chat-keep-notifications` |
| Thread fetch | read + `threads`, pouze nefederovaná room |
| Explicit read | read + `chat-read-marker` + `chat-read-last` |
| Mark unread | read + `chat-read-marker` + `chat-unread` |

Federovaný serverový proxy tok v analyzovaných SHA nepřenáší `threadId` ani
`replyToToken`. Klient proto nesmí tyto funkce zobrazit jako podporované jen
podle globálního feature seznamu.

Capability resolver u cross-room private reply určuje jen možný serverový wire
profil. Bez autoritativního snapshotu přesné 1:1 room, user actorů, členství,
replyable parentu, cizího autora a na master také neklasifikované zdrojové room
nelze bezpečně rozhodnout command eligibility. Současný request builder i nový
outbox admission proto cross-room příkaz odmítají.

## GET request

Request builder vždy posílá `format=json`, `OCS-APIRequest: true` a stabilní
`User-Agent` s Android identitou `com.nkshub.nextcloudtalk`.

History používá:

- `lookIntoFuture=0`;
- `timeout=0`;
- explicitní `lastKnownMessageId`, `lastCommonReadId` a limit 1 až 200;
- `includeLastKnown=1` jen tam, kde algoritmus potřebuje anchor zahrnout.

Future používá `lookIntoFuture=1`, okamžitý catch-up s `timeout=0` a až po
konvergenci long poll s `timeout=30`.

Interaktivní fetch smí aktualizovat presence/notifikace, ale read marker v tomto
kontraktu nastavuje výhradně explicitní read operace. Background fetch vždy
posílá:

- `setReadMarker=0`;
- `noStatusUpdate=1`;
- `markNotificationsAsRead=0`.

## GET response

HTTP a OCS vrstva se vyhodnocují odděleně. HTTP 200 s OCS failure není prázdný
úspěch. Před commitem se ověřuje:

- room token každé zprávy;
- případný `threadId` proti request scope;
- unikátní serverové `messageId` v jedné response;
- striktně sestupné pořadí historie a vzestupné pořadí future;
- kanonické response cursory;
- směr cursoru vůči vráceným ID a request anchoru.

`X-Chat-Last-Given` je autoritativní i při `200 []`, pokud server zpracoval
neviditelnou nebo expirovanou zprávu. Klient musí posunout interval až k této
hlavičce, ne jen k nejvyššímu viditelnému ID.

`304` má dva významy:

- history: starší historie je vyčerpaná;
- future: daný anchor je konvergentní a lze přejít na long poll nebo relay.

Samostatná změna `X-Chat-Last-Common-Read` nesmí posunout history/future cursor.

## ChatBlock a atomický merge

Scope klíč je `(accountId, roomToken, threadId|null)`. Interval znamená serverem
potvrzený rozsah, ne souvislou číselnou řadu viditelných message ID. Skryté
zprávy a ID z jiných rooms mohou uvnitř vytvořit číselné mezery bez lokální
datové mezery.

Každý sync krok:

1. ověří account, room/thread scope a přesnou shodu request anchoru s uloženým
   směrovým cursorem;
2. validuje HTTP, OCS, schema, hlavičky a message semantiku;
3. vytvoří candidate stav;
4. upsertne serverové identity a spojí překrývající se intervaly;
5. aplikuje common-read nebo explicitní read/unread room snapshot;
6. v produkčním runtime uloží cursor, intervaly, messages, marker a případnou
   outbox reconciliation v jedné DB transakci;
7. publikuje UI změnu až po commitu.

Chyba validace, stale anchor nebo simulované DB selhání vrací celý candidate
stav. Stejný room token, thread ID nebo message ID u jiného účtu se nesmí změnit.
Python harness nyní dokládá rollback merge a outbox confirmation odděleně.
Společnou SQLite transakci pro oba subsystémy prokáže až Dart runtime test.

## POST send a replies

Klient před admission vytvoří lowercase UUID `referenceId`. Talk jej serverově
ořízne na 64 znaků, ale před save podle něj nevyhledává existující comment.
Hodnota proto koreluje lokální operaci, není idempotency key.

Potvrzená response musí mít:

- HTTP 201 a úspěšnou OCS obálku;
- neprázdnou message;
- shodný cílový room token;
- přesně shodný `referenceId`;
- u reply shodný `replyTo`, `replyToToken` a `parentRoomToken` z durable operace;
- platné serverové `messageId`.

`201 null`, jiný token nebo jiná reference jsou nejednoznačné výsledky. Stejná
pravidla platí pro ztracenou response po možném odeslání body.

Same-room reply posílá `replyTo`. Ověřený cross-room wire formát posílá také
`replyToToken`; normalizace již uloženého payloadu zachová i
`parentRoomToken`. V analyzovaných serverech se do parent snapshotu promítne
původní message ID a conversation token. Nový cross-room command admission je
v tomto řezu záměrně nepodporovaný a federovaný private reply je nepodporovaný
vždy.

## Read a mark-unread

Explicitní read je POST s konkrétním `lastReadMessage`. Mark-unread je DELETE na
stejné cestě a server znovu odvodí předchozí relevantní zprávu. Response vrací
room snapshot, ze kterého se atomicky uloží `lastReadMessage`,
`lastCommonReadMessage` a `unreadMessages`.

Read je monotónní use case; mark-unread záměrně není. Tyto operation kinds se
nesmějí sloučit do jednoho obecného `max(lastRead)` pravidla ani blind replaye.

## Durable text-send outbox

První povolený registry záznam:

```text
operationKind: textSend
revision: talk-chat-text-send-f2958bb-f9b9e947-r1
requires: chat-v2, chat-reference-id
```

Admission odmítne neznámý kind, jinou revision nebo chybějící capability.
`operationId` je lokální UUID workeru a neposkytuje serverovou idempotenci.

<!-- markdownlint-disable MD013 -->

| Událost | Nový stav | Pravidlo |
| --- | --- | --- |
| Durable admission | queued | Payload, reply metadata a revision jsou uložené |
| Claim | sending | Jen jedna account lane, attempt se zvýší |
| Chyba před body | retryable | Stejný payload lze bezpečně zopakovat po nextAttemptAt |
| Možná odeslané body | awaitingConfirmation | Žádný automatický POST |
| Restart v sending | awaitingConfirmation | Proces nezná serverový výsledek |
| HTTP 400 `error=message` | awaitingConfirmation | Stejný kód může vzniknout i po uložení commentu |
| HTTP 429 `error=mentions` | retryable | Chyba vzniká před save; použije se Retry-After nebo lokální bounded backoff |
| HTTP 5xx nebo jiná nejasná OCS chyba | awaitingConfirmation | Neprokazuje, že save neproběhl |
| Jedna autoritativní shoda | completed | Uloží se konkrétní messageId |
| Více shod referenceId | awaitingConfirmation | Zachovají se všechna ID a ambiguity |
| Deterministické odmítnutí | failed | Operace zůstává viditelná |
| HTTP 401 | retryable + reauthRequired | Pozastaví se jen daný účet |

<!-- markdownlint-enable MD013 -->

Nula shod v jednom catch-up okně neprokazuje neprovedení. Ruční resend je možný
jen po potvrzení rizika duplicity a pouze dokud není známá žádná serverová
shoda. Relay, který dorazí před HTTP response, dokončí operaci; pozdější shodná
HTTP response je idempotentní. V jedné room se claimuje FIFO a běží nejvýše
jeden send, zatímco jiná room může pokračovat souběžně. Stejným lane, FIFO a
single-flight guardem prochází i ruční resend. HTTP výsledek se smí aplikovat
jen na operaci se shodným room, reference a reply kontextem. Prázdný úspěšný
future výsledek (`200` s cursorem/common-read nebo `304`) ponechá operaci v
`awaitingConfirmation`.

## Diagnostika a bezpečnost

- Authorization, app password, room token, message text, referenceId a raw
  payload se nelogují.
- Schema chyba vrací pouze bezpečný JSON path a typ validatoru.
- Dynamic `messageParameters` klíč se v cestě rediguje na `<member>`.
- Query/form mismatch vypíše pouze názvy rozdílných wire sekcí, ne jejich
  hodnoty.
- Live origin je striktní HTTPS origin bez credentials, query a fragmentu;
  subpath i bracketovaný IPv6 host se zachovají.
- Redirecty jsou v live validátoru zakázané a response má pevný byte limit.
- Všechny live credentials i room tokeny se čtou pouze z environment
  proměnných a nevypisují se.

## Spustitelné ověření

Lokální fixture:

```powershell
rtk proxy python contracts\chat-messages\validate_contract.py
rtk proxy python contracts\chat-messages\test_validate_contract.py
```

Read-only live smoke provede právě dva GET requesty bez read/presence side
effectu:

```powershell
$env:NEXTCLOUD_TALK_TEST_ROOM_TOKEN = '<dedicated-read-room-token>'
rtk proxy python contracts\chat-messages\validate_contract.py `
  --live-origin https://nextcloud.example.com
```

Explicitní mutable smoke použije jinou environment proměnnou, odešle jednu
syntetickou zprávu a bounded catch-up ji musí najít:

```powershell
$env:NEXTCLOUD_TALK_WRITE_TEST_ROOM_TOKEN = '<dedicated-write-room-token>'
rtk proxy python contracts\chat-messages\validate_contract.py `
  --live-origin https://nextcloud.example.com `
  --live-write
```

Credentials jsou v obou případech pouze v `NEXTCLOUD_TALK_USERNAME` a
`NEXTCLOUD_TALK_APP_PASSWORD`. Mutable příkaz se nesmí spustit v cizí room.

Aktuální lokální výsledek: 1 OpenAPI dokument, 44 fixtures, z toho 43
schema-validních a 13 přijatých syntetických messages, 21 query případů, 10
capability případů, 23 merge případů s 25 kroky, 36 outbox případů s 60 kroky,
4 unit testy, 1 redaction guard a 1 origin případ prošly. Stejné fixtures
vykonává pure Dart chat doména ve 155 testech; celý `talk_protocol` po
navazujícím rich-chat řezu prochází 375 testy včetně skutečných release AOT
executable a analyzer je bez nálezu.

## Co důkaz nepokrývá

Live read/write nebyl v tomto milníku spuštěný bez potvrzených environment
proměnných a vyhrazené mutable room. Pure Dart model a společný candidate plán
pro message merge plus outbox reconciliation existují, ale neprokazují SQLite
migrace ani skutečný společný DB commit, restart mobilního procesu, HPB relay,
background scheduler, UI pending/error stavy, multi-server izolaci v jednom
procesu ani WCAG kontrast. Tyto části zůstávají v implementačním řezu 3.
