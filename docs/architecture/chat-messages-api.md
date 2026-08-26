# Kontrakt chat zpráv

Datum aktualizace: 25. srpna 2026.

Stav: OpenAPI, syntetické request/response fixture, capability resolver,
transakční merge, durable text-send outbox a bezpečné live režimy jsou
spustitelné. Flutter klient má cache-first chat/thread UI a automatizovaný
foreground HTTP-adapter/Drift/UI bridge, persistentní text-send outbox a
named-thread send. Historický Android build má ověřený build, update install,
přihlášení, otevření room a Giphy wire-reference tok včetně návratu po ukončení
procesu. Nový Giphy attachment tok tento důkaz nahrazuje a zatím nemá live
server round trip. Skutečný příchozí thread smoke patří předchozímu APK a
obousměrný E2E ještě staršímu. Named-thread send, root/history, read-unread a
restart/outbox matice zatím nemají aktuální zařízení E2E.

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
Odvození `threadId` je ověřené v `Message.php` na
[`f2958bb`](https://github.com/nextcloud/spreed/blob/f2958bb25be6604240c58a3faf9a2033a30d20e5/lib/Model/Message.php#L197-L216)
i
[`f9b9e94`](https://github.com/nextcloud/spreed/blob/f9b9e9474e3621b47f74bf8890c4642cb49eed97/lib/Model/Message.php#L197-L216).

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

## Foreground long-poll runtime

Pure Dart runtime je od 23. srpna 2026 implementovaný v commitu
`d90a66f5ed9bd79eb6585ccbff903e48d3da580f`. Tvoří protokolový a stavový
kontrakt, na který nyní navazuje Flutter foreground integrace popsaná níže.

Poll session je neměnně svázaná s `accountId`, server originem,
`(roomToken, threadId|null)`, credential generation a capability generation.
Pro každý scope smí běžet nejvýše jeden request. Completion se přijme pouze pro
přesně pending request, nezměněnou session, aktuální future cursor a stejné
generace účtu. Stale completion se nesmí promítnout do cache.

Stavový tok dodržuje tyto invarianty:

- první foreground future catch-up použije `timeout=0` a aktuální commitnutý
  future cursor;
- po validní response, včetně `304`, další request použije `timeout=30` a znovu
  načtený commitnutý future cursor stejného room/thread scope;
- `304` potvrzuje catch-up, ale samo neposune cursor;
- `401` atomicky přepne účet i poll session do re-auth stavu bez retry;
- HTTP transientní chyba a transportní selhání zachovají režim catch-up nebo
  long poll a použijí exponenciální backoff s jitterem 0,8 až 1,2, základním
  stropem 30 sekund a absolutním stropem 36 sekund;
- lifecycle cancellation přepne session do `stopped`, odstraní pending request
  a nevytvoří chybu ani retry.

Pozorované chování je porovnané s Talk Android SHA
[`5428960f9d1eca708df1b39a0831141dcbba4729`](https://github.com/nextcloud/talk-android/tree/5428960f9d1eca708df1b39a0831141dcbba4729):

- [`OfflineFirstChatRepository.kt` řádky 285 až 324](https://github.com/nextcloud/talk-android/blob/5428960f9d1eca708df1b39a0831141dcbba4729/app/src/main/java/com/nextcloud/talk/chat/data/network/OfflineFirstChatRepository.kt#L285-L324)
  načítají newest message pro room/thread, první request posílají s
  `timeout=0` a další s `timeout=30` z nově načteného newest ID;
- [`OfflineFirstChatRepository.kt` řádky 554 až 559](https://github.com/nextcloud/talk-android/blob/5428960f9d1eca708df1b39a0831141dcbba4729/app/src/main/java/com/nextcloud/talk/chat/data/network/OfflineFirstChatRepository.kt#L554-L559)
  zastavují plánování dalších requestů při pause a obnovují je při resume;
- [`ChatMessageSyncer.kt` řádky 117 až 149](https://github.com/nextcloud/talk-android/blob/5428960f9d1eca708df1b39a0831141dcbba4729/app/src/main/java/com/nextcloud/talk/chat/data/network/ChatMessageSyncer.kt#L117-L149)
  skládají future, timeout, last-known, thread, limit a nulový read marker;
- [`ChatMessageSyncer.kt` řádky 577 až 659](https://github.com/nextcloud/talk-android/blob/5428960f9d1eca708df1b39a0831141dcbba4729/app/src/main/java/com/nextcloud/talk/chat/data/network/ChatMessageSyncer.kt#L577-L659)
  rozlišují `200`, `304`, `412` a chybu. Dart kontrakt záměrně nepřebírá
  obecný `runCatching` retry: cancellation je terminální lifecycle přechod;
- [`NcApiCoroutines.kt` řádky 497 až 502](https://github.com/nextcloud/talk-android/blob/5428960f9d1eca708df1b39a0831141dcbba4729/app/src/main/java/com/nextcloud/talk/api/NcApiCoroutines.kt#L497-L502)
  potvrzují account credential v `Authorization` a typovaný query map GET.

### Flutter foreground bridge

`ChatRoomPane` vytváří přes Riverpod account/room/thread-bound live binding.
`ChatService` připraví capability profil a request, produkční
`HttpNextcloudApi` provede HTTP adapter tok a `ChatRepository` commitne message,
future cursor, konvergenci a bezpečný error stav do Drift. UI změnu publikuje až
pozorování commitnuté databáze; protilehlý root nebo thread scope se nezmění.

Dva widget-integration testy vykonávají celý řetězec
`ChatRoomPane → ChatService → HTTP adapter → Drift → Riverpod → UI` zvlášť pro
root a thread. V obou případech ověřují timeouty `0 → 30 → 0`, přechod cursoru
109 → 120, zobrazení externí zprávy, následnou konvergenci po `304`, prázdný
opačný scope a nulovou UI výjimku. HTTP adapter v testu používá deterministický
`MockClient`; test proto neprokazuje skutečný socket ani Nextcloud server.

Thread response může nést úplný embedded parent. Flutter repository jím
aktualizuje cached thread original jen při shodě accountu, room tokenu,
message ID a thread ID. Serverové `threadReplies` je autoritativní. Pokud pole
chybí, klient odvodí počet z množiny unikátních message ID v daném thread scope
a právě přijímaných replies, vynechá original a zachová vyšší dříve uložený
počet. Replay stejného reply ID se proto nezapočítá znovu, batch se přičte
právě jednou a neshodný embedded parent nesmí přepsat cached original. Celý
merge proběhne ve stejné Drift transakci a reply dál neunikne do root scope.

Cílená sada `chat_service_integration_test.dart`,
`chat_scope_isolation_test.dart` a `chat_room_live_sync_test.dart` prošla 24.
srpna 2026 výsledkem 22/22. Samotný thread repository řez prošel 7/7 včetně
explicitního serverového počtu, chybějícího počtu, replay/batch odvození a
neshodného parentu. Samostatné UI sady zahrnují izolovaný thread pane, otevření
platného vlákna bez replies, bezpečný inline link a interní viewer obrázkových
příloh. Čerstvý výběr sedmi chat/Giphy testovacích souborů po commitu `8724281`
prošel 63/63 a `flutter analyze` skončil bez nálezu.

### Historický Android Giphy wire-reference runtime

Commit `5f6e2f4` má debug APK SHA-256
`0d38d4ab2a665883d0ee0de7426f201c107cefc6b5f7e701b1c856255f6195cf` a
velikost 203 683 536 B. Update instalace přes `adb install -r` prošla a
nainstalovaný `base.apk` měl stejný hash. Na tomto APK proběhl skutečný Login
Flow, seznam konverzací, otevření room, výběr a odeslání Giphy zprávy i návrat
po ukončení procesu. Dva cold starty trvaly 5 094 ms a 4 587 ms.

Tehdejší implementace posílala Giphy `resourceUrl` jako interní Talk wire
reference. Potvrzená message bublina i lokální pending bublina ji přes
account-scoped References resolver vykreslily jako animovaný inline GIF; URL se
nezobrazila ani nebyla klikací. Reply preview a náhled konverzace používaly text
`GIF`. To platilo i pro přesný URL wire tvar s `markdown=false` nebo chybějícím
polem `markdown`.

Cílená regrese opravy prošla 11/11 a širší chat/Giphy sada 75/75; analyzer byl
bez nálezu. Dva rozdílné crop hashe stejné bubliny prokázaly změnu snímku
animace. Po ukončení procesu se stejná zpráva znovu načetla a vykreslila bez
viditelné URL. První načtení GIFů po cold startu trvalo přibližně osm sekund;
krátký stav `Chat is temporarily unavailable` zmizel po retry. Tento scénář
neopakoval celý root/thread/read-unread/outbox runtime.

Tento wire-reference tok je nyní nahrazený a zůstává pouze pro čtení historie.
Nový výběr nesmí URL vložit do textové zprávy. Resolver dodá validované
`image/gif` bajty do durable app-owned zdroje a standardního Talk
Draft/WebDAV/finalize attachment toku. Commity `5d49cbb`, `9de5727` a `7ca580e`
tento tok propojují od pickeru po finalize. Composer integration prošel 4/4,
loader/media composer 15/15 a scoped analyze bez nálezu. Výše uvedený historický
live běh nový upload/finalize tok stále neprokazuje.

### Historický reálný thread smoke

Předchozí debug APK SHA-256
`<fingerprint>`
bylo aktualizačně nainstalované přes `adb install -r`; cold start zachoval účet.
Z root timeline se přes `Open thread` otevřel existující thread. Jedna nová
webová thread reply se ve foreground Flutteru zobrazila za 2,3 s. Thread root
byl vykreslen právě jednou, redundantní parent preview ani jednou, příchozí
reply nebyla v root timeline a počítadlo odpovědí u kořene se aktualizovalo na
4.

Scénář historicky prokazuje příchozí Nextcloud transport, foreground poll,
Drift/UI aktualizaci a root/thread scope i presentation izolaci. Neprokazuje
stejné chování na novém post-review APK ani opačný směr z tohoto Flutter
composeru do webového Talk.

Installed `base.apk` má podle `sha256sum` stejný SHA-256 jako tehdejší lokální
build. Light, dark a light-200-percent capture zobrazují thread, datum, root,
4 odpovědi a composer bez layout vady. Explicitní pixelový report prošel 24/24
s minimem textu 7,2725:1 a UI 3,252078:1. Redigovaný process-scoped logcat nemá
warning, error, fatal ani známou UI diagnostiku. Po capture se obnovily původní
hodnoty `night=yes`, `font_scale` unset/null a běžící proces aplikace.

Runtime seznam konverzací ukázal 9 tiles a 9 avatarů: 3 síťové obrázky,
4 fallback ikony a 2 iniciály. Příchozí skupinová zpráva měla participant
avatar; outgoing-only testovací thread správně avatary nezobrazil. Avatar
pixelový report prošel 4/4 s minimem UI ikony 7,2725:1 a textu iniciály
7,2739:1.

### Historický obousměrný baseline

Starší APK SHA-256
`1c4372cad3bbf3f7b1d56664c5da9f353be24bb2b456a919b2393cd6879ba861`
prokázalo dvě webové replies v různých polling cyklech, jejich nepřítomnost v
root timeline a reply z Flutter thread composeru doručenou do webového Talk.
Jde o historický transportní baseline, ne o opakování obousměrného scénáře na
předchozím runtime APK ani aktuálním buildu. Room token a texty zpráv zůstávají
pouze v ignorovaných lokálních artefaktech. Dočasná room byla 2026-08-24
odstraněná přes trvalou webovou E2E
relaci a následný snapshot ověřil její nepřítomnost.

Na tomto starším APK prošly reálné light/dark screenshoty threadu PIL kontrastem
s minimem 5,03:1 pro text a 3,25:1 pro UI. Při font scale 2,0 se zprávy
zalomily, header a composer zůstaly viditelné a logcat neměl layout chybu.
Flutter semantics test potvrzuje právě jeden pojmenovaný editovatelný composer
node se `setText` a tap akcí. Android AccessibilityBridge mapuje label/hint do
`AccessibilityNodeInfo.hintText`. Přímá Android runtime sonda našla právě jeden
editor, vrátila očekávaný hint `Write a message` o délce 15 a potvrdila
`editable=true` i click akci; text a `contentDescription` zůstaly podle bridge
prázdné. Runner prošel 1/1. Uiautomator XML `hintText` neserializuje, takže
`NAF=true` je false positive. Zvukové vyslovení TalkBack nebylo odposlechnuté.

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
- u same-room reply přesný immediate parent a shodný kladný topmost
  `threadId` na parentu i nové zprávě;
- u cross-room private reply původní reply metadata, lokální copied-parent ID
  jako `threadId` nové zprávy a `parent.threadId == 0`;
- u named-thread sendu v přímé POST response parentless zprávu se shodným
  požadovaným `threadId`;
- u plain sendu parentless zprávu s `threadId == messageId`;
- platné serverové `messageId`.

`threadId` v plain response tedy není kopií nullable request pole. Server jej
odvozuje jako ID nového thread rootu. `201 null`, jiný token nebo jiná reference
jsou nejednoznačné výsledky. Stejná pravidla platí pro ztracenou response po
možném odeslání body.

Same-room reply posílá `replyTo`. Ověřený cross-room wire formát posílá také
`replyToToken`; normalizace již uloženého payloadu zachová i
`parentRoomToken`. V analyzovaných serverech se do parent snapshotu promítne
původní message ID a conversation token. Nový cross-room command admission je
v tomto řezu záměrně nepodporovaný a federovaný private reply je nepodporovaný
vždy.

Named-thread send je jiná wire větev než obyčejný reply: posílá `threadId`, ale
žádné `replyTo`, `replyToToken` ani `parentRoomToken`. Vyžaduje `chat-v2`,
`chat-reference-id`, lokální `threads` profil a nefederovanou room. Response
musí zachovat stejný `threadId` a nesmí přidat parent. Flutter před admission
rozliší cached named-thread root od reply rootu; neznámou klasifikaci nejprve
dosynchronizuje. Potvrzená zpráva se uloží do thread scope a ve stejné Drift
transakci aktualizuje cached root `threadId`, `isThread` a `threadReplies`.

## Read a mark-unread

Explicitní read je POST s konkrétním `lastReadMessage`. Mark-unread je DELETE na
stejné cestě a server znovu odvodí předchozí relevantní zprávu. Response vrací
room snapshot, ze kterého se atomicky uloží `lastReadMessage`,
`lastCommonReadMessage` a `unreadMessages`.

Read je monotónní use case; mark-unread záměrně není. Tyto operation kinds se
nesmějí sloučit do jednoho obecného `max(lastRead)` pravidla ani blind replaye.

Commity `67026a0` a `df9d608` serializují obě mutace pouze v lane
`(accountId, roomToken)`. Read → unread i unread → read proto zachovají pořadí
v jedné room, zatímco jiná room nebo účet pokračují souběžně. DB a jiné
očekávané runtime výjimky se mapují na `RoomSettingsError.invalidResponse`, ale
programátorský `StateError` se propaguje; lane se po obou druzích chyby uvolní.
Čerstvý společný běh `room_settings_read_marker_test.dart` a
`chat_room_live_sync_test.dart` na `df9d608` prošel 21/21.

Commit `e4840e5` přidává pravdivou Flutter projekci read stavu pro vlastní
odchozí zprávy. `ChatRepository` joinuje outbox confirmation s přesným
`(accountId, roomToken, scopeKey)` a reaktivně čte `lastCommonRead`. Stav `read`
vznikne pouze pro dokončenou outbox operaci se skutečně uloženou serverovou
zprávou a `messageId <= lastCommonRead`. Nepotvrzená nebo ambiguous operace
zůstává `sending`; `delivered` se bez serverové semantiky vůbec nevytváří.

Commit `02b79eb` zároveň vynucuje neinteraktivní background catch-up. Profil s
`backgroundCatchUp` posílá `noStatusUpdate=1` a
`markNotificationsAsRead=0`; foreground request zůstává interaktivní. Společný
běh `outgoing_message_status_test.dart` a `chat_room_live_sync_test.dart` prošel
11/11 a scoped analyze pěti změněných souborů byl bez nálezu. Jde o
automatizovaný HTTP/Drift/UI důkaz, nikoli reálný serverový read přechod nebo
background lifecycle.

## Durable text-send outbox

První povolený registry záznam:

```text
operationKind: textSend
revision: talk-chat-text-send-f2958bb-f9b9e947-r2
requires: chat-v2, chat-reference-id
```

Admission odmítne neznámý kind, jinou revision nebo chybějící capability.
`operationId` je lokální UUID workeru a neposkytuje serverovou idempotenci.
Named-thread operace navíc ukládá `threadId` a vyžaduje `threads`; předchozí
revision r1 se pod r2 autoritou odmítne místo nebezpečného replaye.

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

Ordinary same-room reply může autoritativní history/future potvrdit také přes
compact deleted parent. Ten musí mít přesně `parent.id == replyTo`, nesmí nést
`parentRoomToken` ani `parentThreadId` a outer `threadId` musí být kladný. Tato
výjimka platí po ambiguous POST i po restartu; nespouští nový POST a právě jedna
shoda dokončí operaci. Jiný parent, doplněná parent metadata nebo nulový outer
thread zůstávají bez shody.

Named-thread přímá POST response a autoritativní catch-up nemají stejný shape.
Při shodném outer `threadId == T` smí být přímá POST response bez parentu.
Autoritativní history/future položka bez parentu se odmítne; musí nést právě
jednu z těchto podob:

- full root parent s `id == T`, room tokenem operace a `threadId == T`;
- compact nedostupný parent právě ve tvaru `{id: T, deleted: true}`.

Jiné parent ID, cizí room token nebo jiný parent thread confirmation odmítnou.
U quoted reply zůstává `parent.id` bezprostřední quoted message `P`, která se
může lišit od rootu `T`; outer i full-parent `threadId` musí být `T`.

Flutter schema v5 přidalo do `text_send_operations` nullable `threadId` a
aktuální schema v7 jej zachovává.
File-backed reopen test zachová queued i sending named-thread operaci a
`recoverInterruptedTextSends` bezpečně převede přerušený `sending` na
`awaitingConfirmation` bez ztráty thread vazby. Jde o DB/repository důkaz, ne o
hotový live process-death nebo background scheduler scénář.

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

Aktuální contract výsledek 24. srpna 2026: 1 OpenAPI dokument, 47 fixtures, z
toho 46 schema-validních a 14 přijatých syntetických messages, 24 query
případů, 10 capability případů, 23 merge případů s 25 kroky, 43 outbox případů
s 83 kroky, 17 unit testů, 1 redaction guard a 1 origin případ prošly. Stejné
fixtures vykonává pure Dart chat doména. Cílená named-thread/outbox brána prošla
158/158, celá chat-only sada 194/194 a samostatný foreground polling soubor 10
testy. Celý `talk_protocol` prošel 569/569 a `dart analyze` skončil bez nálezu.

Čistý Flutter commit `8374f20` obsahuje 354 funkčních testů a jeden live skip
pouze bez environment credentials; pozdější plný běh stejného funkčního zdroje
25. srpna 2026 skončil bez selhání. Named-thread service/integration testy a
file-backed schema v5→v7 reopen/migration jsou součástí této sady. Flutter analyze
je bez nálezu a celý `talk_protocol` prošel 569/569.

Historický `chatujmePixel` běh prokázal build/install/hash, přihlášení, otevření
room a výše popsaný Giphy wire-reference tok včetně návratu po ukončení procesu,
ne však nový GIF attachment upload/finalize, thread, read/unread ani outbox
restart. Předchozí běh prokázal příchozí thread smoke, UI invarianty,
light/dark/200% WCAG 24/24 a avatar WCAG 4/4.
Obousměrný thread E2E
a přímý Android runtime `getHintText` test jsou historické důkazy ještě staršího
APK. Zvukové vyslovení TalkBack ještě nebylo ověřené.

## Co důkaz nepokrývá

Historický serverový důkaz pokrývá jen jednu příchozí thread future reply.
Historické Giphy APK celý thread scénář neopakovalo a opačný směr je doložený
pouze ještě starším APK. Neprokazuje ani nový Giphy attachment tok.
Named-thread request/response/outbox a DB reopen mají automatizovaný důkaz, ale
ne skutečný serverový ani zařízení round trip. Důkaz neprokazuje root live tok,
history stránkování, read/unread, queued ani ambiguous outbox přes skutečný
procesní restart, HPB relay, background scheduler nebo multi-server izolaci.
Ani čerstvá read/unread brána 21/21 a deleted-parent reconciliation testy nejsou
kombinovaným live-server + process-death důkazem.
Chybí zvukově ověřené vyslovení a širší TalkBack navigace. Dočasná room byla
odstraněná a její nepřítomnost ověřená; ostatní části zůstávají otevřenou bránou
řezu 3.
