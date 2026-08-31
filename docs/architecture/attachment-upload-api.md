# Kontrakt uploadu příloh a voice zpráv

Datum poslední aktualizace: 26. srpna 2026.

Stav: OpenAPI, syntetické OCS/WebDAV fixture a pure Dart request, parser i
durable runtime jsou spustitelné. Flutter má OCS/WebDAV transport, account-scoped
Drift job store, restart-safe orchestraci, durable file picker, image progress,
retry/cancel, authenticated image viewer, kameru, obecný file picker a voice
record/preview/submit tok. Same-room reply pro obrázek, obecný soubor a hlasovou
zprávu má automatizovaný test a build, ne sender/recipient live důkaz.
Platformní background transfer a úplná lifecycle matice zůstávají otevřené.

## Rozsah

Kontrakt pokrývá dvoufázový Draft upload:

1. Talk OCS probe založí nebo načte privátní Draft složku.
2. Malý soubor se nahraje jedním WebDAV `PUT`, velký přes chunk v1
   `MKCOL` → `PROPFIND` → chybějící `PUT` → `MOVE`.
3. Talk OCS finalize přesune Draft soubor a vytvoří attachment zprávu.
4. Teprve právě jedna autoritativní `file_shared` chat zpráva se shodným
   účtem, serverem, room, `referenceId`, message typem, file rich objektem a
   očekávaným reply/thread scope dokončí lokální job.

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

`replyTo` a `threadId` jsou vzájemně výlučné. Same-room root reply používá jen
`replyTo`; named thread používá jen `threadId` a jeho canonical root. Kombinace
obou hodnot se odmítne už v modelu, request builderu i fixture validatoru.

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

Composer před prvním asynchronním krokem snapshotuje account, room a metadata
obrázku nebo souboru; voice kontext snapshotuje při stisku Send. Durable
admission tak nepřevezme novější reply vybranou během pickeru, načítání bytes
nebo odesílání. Reply banner se smí odstranit až po úspěšném durable admission
a jen pokud stále ukazuje na právě přijatý parent.

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

## Flutter HTTP transport

`apps/mobile/lib/network/attachment_transport.dart` provádí skutečný OCS i
WebDAV request wire přes `package:http`. Každý request před odesláním ověří
shodu accountu a kanonického originu s autorizací, přidá credentials pouze na
ověřený stejný origin a odmítne redirect. Response body, connect i idle fáze
mají pevný limit a výjimka nese jen typovaný kód, krok a stage bez citlivých
hodnot.

Transport otevře app-owned zdroj jako lease, jednou ověří přesnou délku a
SHA-256 a stejný immutable snapshot používá pro normal i chunk PUT. Range API
musí provést efektivní seek na offset a vydat nejvýše požadovanou délku; pozdní
chunk tedy nesmí znovu lineárně číst a zahazovat předchozí bytes. Upload
kontroluje exact byte count a předčasný konec i bytes navíc klasifikuje jako
změnu zdroje.

Caller cancel, idle/connect timeout a `close()` používají společný odpojitelný
abort signál. Pozdě dokončené otevření zdroje se nesmí přidat mezi ověřené
leases a jeho lease se zavře. Cleanup má jeden bounded budget, ale selhání
zrušení iteratoru nesmí přeskočit zavření request sinku ani další kroky. Testy
používají deterministický HTTP klient a zdroje; neprokazují skutečný socket,
ContentProvider/NSFileCoordinator ani Nextcloud server.

## Flutter orchestrace a UI

`AttachmentRepository` ukládá account, room, immutable source metadata,
capability profil a přesnou durable fázi do Drift. `AttachmentService` obnovuje
rozpracované joby, zachovává room FIFO/single-flight, odděluje bezpečně
opakovatelný upload od nejednoznačného finalize a potvrzuje dokončení pouze
autoritativní chat zprávou. Credential se čte až při konkrétním account-scoped
requestu a v databázi zůstává jen odkaz na účet.

Confirmation join v Drift je omezený na stejný account, server, room a
`referenceId`. Cached payload se znovu dekóduje a musí souhlasit s indexovaným
message ID, room, reference, system message a message typem. Runtime navíc
vyžaduje kladné message ID, prázdný system message, file rich object a přesný
`messageType`; reply job musí mít shodný parent, named-thread job shodný parent
i `threadId` rovný canonical rootu. Nula shod zůstává pending a více shod je
ambiguous.

Ordinary reply smí přijmout compact deleted parent jen při přesném
`parent.id == replyTo`, `parentRoomToken == null`, `parentThreadId == null` a
kladném outer `threadId`. Stejný invariant platí po ambiguous finalize i při
restart reconciliation. Klient finalize POST neopakuje; právě jedna
autoritativní shoda dokončí job a jeho durable source se uvolní právě jednou.

`ChatMediaComposer` používá `file_selector` pro galerii a obecný soubor a
`image_picker` pro kameru, vytvoří app-owned kopii a po durable admission předá
její vlastnictví attachment service. Stavový panel rozlišuje přípravu,
upload, čekání na potvrzení, dokončení, retry, cancel a chybu; krátké potvrzení
se po úspěchu samo uklidí. Zprávový renderer načítá obrázky autentizovaně ze
stejného account originu a tap otevře samostatný viewer, nikoli nový upload
dialog.

Voice větev používá `record` a `audioplayers`. Ověří capability a mikrofonní
oprávnění, drží nahrávku jako durable app-owned zdroj, nabízí lokální preview a
odesílá ji přes stejnou attachment orchestraci s `voice-message` metadaty.
Automatizované testy pokrývají zamítnuté oprávnění, záznam, preview, cancel,
retry, durable admission a cleanup. Nejde ještě o live důkaz mikrofonu,
playbacku a serverového doručení na cílovém zařízení.

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

Pure Dart změna vrací jednorázový candidate plán vázaný na identitu source
snapshotu. Flutter `AttachmentRepository` jej commitne atomicky do Drift, nebo
celý zahodí.

## Bezpečnost a diagnostika

Request nese account, request ID, server, room, job ID, capability generation a
contract revision. Response zachová přesný původní request; merge kontext se
nedodává bokem. JSON, XML, mapy a seznamy jsou bounded a immutable.

`toString()` ani protokolová výjimka nesmí obsahovat account ID, DAV user ID,
room token, filename, Draft cestu, source handle, reference ID, checksum,
caption, message text ani XML obsah.

### Přijatý kontakt jako vCard příloha

Talk Android `5428960` exportuje vybraný systémový kontakt do `.vcf` souboru a
odesílá jej stejným uploadem jako jinou file attachment. Nejde o samostatný
rich object wire typ. `9d6b0fe` proto rozšiřuje pouze příjem obecné přílohy,
nikoli transport nebo oprávnění adresáře.

Contact karta se použije pro strong MIME `text/vcard`, `text/x-vcard` a
`text/directory`. Fallback pro `application/octet-stream` nebo
`binary/octet-stream` vyžaduje `.vcf` na posledním segmentu už validovaného
`DavRelativePath`; zobrazované jméno nesmí typ zfalšovat. Nepovolený MIME
zůstává obecným souborem i s `.vcf` cestou. Bez validní account-bound DAV cesty
se žádná open akce nevykreslí.

Otevření používá beze změny existující autentizované stažení, kontrolu content
type, app-owned dočasný soubor a platformní opener. Karta má samostatný button
semantics uzel s tap akcí, 48dp minimum a bounded text při 200 %.

Živý test na iOS 18.6 provedl WebDAV PUT generického vCardu, Files share
`shareType=10`, příjem v druhém účtu, render, autentizované stažení a nativní
contact preview. Light/dark/accessibility-large layout nepřetekl; kontrast je
6,4986:1 a 11,6343:1. Zpráva i soubor byly smazané a následná kontrola vrátila
0 zpráv a 0 souborů.

## Spustitelné ověření

```powershell
rtk proxy python contracts\attachment-upload\validate_contract.py
rtk proxy python contracts\attachment-upload\test_validate_contract.py
rtk C:\work\sources\flutter-sdk\flutter\bin\dart.bat analyze --fatal-infos
rtk C:\work\sources\flutter-sdk\flutter\bin\dart.bat test
rtk C:\work\sources\flutter-sdk\flutter\bin\flutter.bat test `
  test\attachment_transport_test.dart `
  test\attachment_repository_test.dart `
  test\attachment_service_test.dart `
  test\attachment_submission_test.dart `
  test\image_attachment_upload_controller_test.dart `
  test\image_attachment_upload_panel_test.dart `
  test\authenticated_image_viewer_test.dart `
  test\chat_composer_voice_test.dart `
  test\chat_media_composer_test.dart `
  test\chat_composer_integration_test.dart `
  test\chat_attachment_context_test.dart
```

Kontrakt obsahuje 12 OCS fixture, 15 capability případů, 20 wire případů,
7 DAV plánů s 11 stavovými výsledky, 3 XML fixture a 25 stavových scénářů.
Python validator má 18 unit testů. Dne 26. srpna 2026 prošla aktuální kombinovaná
pure Dart attachment sada contract, DAV, runtime, security a release AOT
58/58. Aktuální počet celého `talk_protocol` je vedený v požadavkové matici,
aby zde nezůstal historický součet z dřívějšího attachment milníku.

Čerstvý scoped běh na aktuálním HEAD prošel 22/22 v
`attachment_runtime_test.dart` a 27/27 v `attachment_service_test.dart`.
Deleted ordinary-reply parent je pokrytý také po catch-upu/restartu včetně
jediného uvolnění durable source.

Původní Flutter `attachment_transport_test.dart` milník prošel 24. srpna 2026
25/25. Dne 25. srpna prošla společná cílená sada transportu, repository,
service, submission, image controller/panel/vieweru a voice controlleru 91/91.
Aktuální plný počet a APK hash je vedený v
[průběžném stavu vývoje](development-status-2026-08-25.md), aby se zde nemíchal
historický transportní milník s pozdějšími řezy.

Scope binding je doložený commity `d518694`, `4b4e61b` a `cd22bdb`.
Repository recovery test zachová oddělený reply a named-thread scope; runtime
testy odmítnou chybný parent nebo thread root. Integrační widget test vede
media reply z produkčního pane přes durable enqueue až do finalize s
`replyTo=109` a bez `threadId`; focused media/composer sada prošla 49/49.
Tento důkaz je automatizovaný a buildový, nikoli live běh proti serveru.

## Co důkaz nepokrývá

Automatizované testy používají deterministický HTTP klient a testovací platformní
backendy. Neprokazují aktuální live upload do Nextcloudu, skutečný mikrofon a
playback, ztrátu procesu během každé durable fáze ani dva účty na dvou serverech.
Zvlášť chybí kombinovaný live Nextcloud + process-death průchod pro ambiguous
finalize a deleted-parent confirmation; automatizované restart testy jej
nenahrazují.
`chatujmePixel` proto ještě musí projít malý i chunked soubor, obrázek, kolizi
jména, oprávnění a kvótu, restart mezi každými dvěma fázemi, cancel/cleanup a
celý voice lifecycle včetně media reply sender/recipient toku. Kamera a obecné
soubory mají automatizované pokrytí, ale ne aktuální live důkaz. Skutečný
background transfer, background recorder a výkon se navíc prokážou na fyzickém
Android zařízení.
