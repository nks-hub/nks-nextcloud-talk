# Kontrakt uploadu příloh a voice zpráv

Datum ověření: 23. srpna 2026.

Stav: OpenAPI, syntetické OCS/WebDAV fixture a pure Dart request, parser i
durable runtime jsou spustitelné. Flutter picker, kamera, recorder, playback,
HTTP transport, Drift store a platformní background transfer zatím neexistují.

## Rozsah

Kontrakt pokrývá dvoufázový Draft upload:

1. Talk OCS probe založí nebo načte privátní Draft složku.
2. Malý soubor se nahraje jedním WebDAV `PUT`, velký přes chunk v1
   `MKCOL` → `PROPFIND` → chybějící `PUT` → `MOVE`.
3. Talk OCS finalize přesune Draft soubor a vytvoří attachment zprávu.
4. Teprve právě jedna autoritativní `file_shared` chat zpráva se shodným
   účtem, serverem, room, `referenceId`, message typem a file rich objektem
   dokončí lokální job.

OpenAPI 3.1 pro dva Talk OCS endpointy je v
[`contracts/attachment-upload/openapi.json`](../../contracts/attachment-upload/openapi.json).
WebDAV metody a stavové kódy jsou samostatné wire fixture, protože jejich cesty
závisí na ověřeném DAV user ID, serverem vrácené Draft cestě a náhodné upload
session.

Classic Files share není v tomto řezu podporovaný. Vyžaduje samostatný
Nextcloud core kontrakt a vlastní bezpečnou replay semantiku.

## Ověřený baseline

Wire a capability chování je vázané na:

- Talk server `f2958bb25be6604240c58a3faf9a2033a30d20e5`;
- stabilní Talk `f9b9e9474e3621b47f74bf8890c4642cb49eed97`;
- Talk Android `5428960f9d1eca708df1b39a0831141dcbba4729`;
- Talk iOS `2d31eda5e2acbf3cef27aa289376942bdf0de25d`;
- Nextcloud core master `a0bf541f667e4d891e05a92254b167840066e1a0`;
- Nextcloud core stable34 `a599620e9b75dc3c919b39dabd82a4f98b543b74`.

Implementace používá vlastní typy nad veřejným wire kontraktem a syntetickými
daty. Nebyl převzatý zdrojový kód ani asset oficiálních klientů.

## Capability a command hranice

Profil vznikne pouze z autentizovaného capability snapshotu. Draft upload
vyžaduje `attachments.allowed`, `attachments.conversation-subfolders` a
`chat-reference-id`. Room musí být nefederovaná a účet musí mít aktuální právo
psát.

Další metadata se povolí jen při přesné feature:

| Funkce | Nutná feature |
| --- | --- |
| Caption | `media-caption` |
| Voice | `voice-message-sharing`; `audio/mpeg` nebo `audio/wav` |
| Same-room reply | `chat-replies` |
| Thread metadata | `threads` |
| Silent send | `silent-send` |

Číslo serverové verze není fallback. Každý příkaz je fail-closed svázaný s
`accountId`, kanonickým serverem, capability generation, room oprávněním a
revision attachment replay kontraktu. Změna účtu, originu, generace nebo
revision zneplatní starou autoritu.

## Durable zdroj a metadata

Job přijme jen app-owned kopii nebo persistable URI grant. Ukládá neprůhledný
source handle, velikost, SHA-256, MIME a bezpečný display name; neukládá raw
bytes ani dočasnou picker cestu do diagnostiky.

Před každým uploadem nebo resume musí platformní transport zdroj znovu otevřít
a dodat aktuální velikost i SHA-256. Neshoda ukončí job jako source mismatch,
aby se pod původním `referenceId` neposlal jiný obsah.

Běžná příloha očekává `messageType=comment`, voice přesně
`messageType=voice-message`. Hodnota je odvozená z neměnných metadata jobu a
finalize builder ji nemůže přepsat samostatným parametrem.

## Talk OCS wire

Probe i finalize používají `format=json`, `OCS-APIRequest: true`, explicitní
`allowUpdate: false` a stabilní `User-Agent`. Rename z probe je jen advisory;
finalize znovu odešle původní jméno a autoritativní rename převezme až z jeho
response.

Finalize není atomický. Server nejdřív přesune Draft soubor a potom vytvoří
chat zprávu. Úspěšný HTTP/OCS výsledek proto znamená pouze přijatou finalizaci
a vede do `awaitingConfirmation`. Totéž platí pro 5xx, OCS mismatch, ztracenou
response, možná odeslané body a restart ve fázi `finalizing`. Žádná z těchto
větví nesmí vyvolat blind opakování finalize POSTu.

Dokumentované 400, 404, 422, 501 a 507 jsou deterministické odmítnutí před
úspěšným dokončením. HTTP 401 pozastaví pouze cílový account lane a job uchová
resume point.

## WebDAV wire a XML parser

Serverem vrácená Draft cesta se přijme jen jako bezpečný relativní path.
Odmítnou se absolutní URI, query, fragment, backslash, prázdný segment, `.` a
`..`; segmenty se před sestavením URI znovu percent-encodují. Redirect není
povolený a `Destination` u `MOVE` musí mít stejný scheme, host a port.

Chunk session je náhodné UUID, ne hash souboru. Chunk jméno je šestnáctimístný
inkluzivní byte rozsah. Chunk v1 neposílá HTTP `Range` ani `Content-Range`;
rozsah je pouze v názvu. `MOVE` vždy posílá přesný `OC-Total-Length`.

Resume přijme jen seřazené nepřekrývající se chunky se správnou délkou a
souvislost ověří klient před sestavením. XML parser přijímá pouze UTF-8, před
parse odmítne DTD i entity a průběžně vynucuje byte, depth a node limit.

## Stav, retry a cleanup

Durable fáze jsou `localPrepared`, `probing`, `draftResolved`, `uploading`,
`uploaded`, `finalizing`, `awaitingConfirmation`, `completed`, `retryable`,
`failed`, `cancelling`, `cancelled` a `cleanupFailed`.

- Probe a stabilní privátní upload lze před finalizací bezpečně obnovit.
- Po uploadu a chybě share se bytes znovu nenahrávají.
- Každý restart obnoví konkrétní resume point; nerozběhne job slepě od začátku.
- V jedné room platí FIFO a single-flight pro finalizaci. Jiné rooms a účty se
  navzájem neblokují.
- Cancel před finalize maže pouze jobem vlastněnou chunk session a Draft temp
  soubor. Po zahájení finalize už klient nesmí tvrdit, že zprávu zrušil, ani
  mazat možný finální soubor.
- Nula potvrzujících zpráv není důkaz neprovedení. Více shod zůstane explicitně
  ambiguous; jediná shoda dokončí job.

Každá změna vrací jednorázový candidate plán vázaný na identitu source
snapshotu. Budoucí Drift vrstva jej musí commitnout atomicky, nebo celý zahodit.

## Bezpečnost a diagnostika

Request nese account, request ID, server, room, job ID, capability generation a
contract revision. Response zachová přesný původní request; merge kontext se
nedodává bokem. JSON, XML, mapy a seznamy jsou bounded a immutable.

`toString()` ani protokolová výjimka nesmí obsahovat account ID, DAV user ID,
room token, filename, Draft cestu, source handle, reference ID, checksum,
caption, message text ani XML obsah.

## Spustitelné ověření

```powershell
rtk proxy python contracts\attachment-upload\validate_contract.py
rtk proxy python contracts\attachment-upload\test_validate_contract.py
rtk proxy C:\work\sources\flutter-sdk\flutter\bin\dart.bat analyze --fatal-infos
rtk proxy C:\work\sources\flutter-sdk\flutter\bin\dart.bat test
```

Kontrakt obsahuje 12 OCS fixture, 15 capability případů, 20 wire případů,
7 DAV plánů s 11 stavovými výsledky, 3 XML fixture a 20 stavových scénářů.
Python validator má 16 unit testů. Attachment doména prochází 52 Dart testy:
15 contract, 7 DAV, 17 runtime, 12 security a 1 skutečný release AOT
executable. Po doplnění signaling řezu celý `talk_protocol` prochází 485 testy
a analyzer je bez nálezu.

## Co důkaz nepokrývá

Nebyl spuštěný HTTP/WebDAV transport, Drift commit, skutečný procesní restart,
picker, kamera, recorder, playback ani live upload na referenční server.
Repozitář stále nemá Flutter/Android scaffold, takže zatím nelze poctivě
spustit povinný `chatujmePixel` E2E checklist ani screenshoty a pixelové WCAG
měření.

Po vzniku APK musí `chatujmePixel` projít malý i chunked soubor, obrázek, kolizi
jména, oprávnění a kvótu, restart mezi každými dvěma fázemi, cancel/cleanup a
celý voice lifecycle. Skutečné background/killed FCM doručení, background
recorder a výkon se navíc prokážou na fyzickém Android zařízení.
