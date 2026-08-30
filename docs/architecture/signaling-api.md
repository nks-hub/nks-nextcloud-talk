# Signaling preparation kontrakt a runtime

Datum ověření: 23. srpna 2026.

Tento řez připravuje skutečný internal a HPB signaling transport bez
předstírání WebRTC médií. Pure Dart balík vytváří jednorázové HTTP a WebSocket
plány, přijímá odpovědi svázané se stejným účtem a epochou a vrací neměnný
candidate stav. Síťový klient, socket lifecycle a atomický persistence commit
zůstávají vlastnictvím budoucí Flutter aplikace.

## Ověřený upstream

- Talk server `f2958bb25be6604240c58a3faf9a2033a30d20e5`;
- stabilní Talk `f9b9e9474e3621b47f74bf8890c4642cb49eed97`;
- Talk Android `5428960f9d1eca708df1b39a0831141dcbba4729`;
- Talk iOS `2d31eda5e2acbf3cef27aa289376942bdf0de25d`;
- High-performance backend
  `e007e2ed972c7322b53926d7da24a2b3faeaeccb`.

Executable kontrakt je v `contracts/signaling`. OpenAPI 3.1 popisuje pouze
HTTP část, protože OpenAPI není wire schéma WebSocket zpráv. Samostatný
validátor proto kontroluje také HPB client/server frames a runtime scénáře.

## HTTP profil

Kontrakt obsahuje tři operace:

<!-- markdownlint-disable MD013 -->

| Operace | Wire | Účel |
| --- | --- | --- |
| `getSignalingSettingsV3` | `GET /ocs/v2.php/apps/spreed/api/v3/signaling/settings` | Autentizovaný výběr internal nebo external profilu |
| `pullInternalSignalingV3` | `GET /ocs/v2.php/apps/spreed/api/v3/signaling/{token}` | Jeden account/room long poll |
| `sendInternalSignalingV3` | `POST /ocs/v2.php/apps/spreed/api/v3/signaling/{token}` | Bounded batch ephemeral peer zpráv |

<!-- markdownlint-enable MD013 -->

Internal pull přijme při HTTP 200 pouze zprávy následované právě jedním
závěrečným `usersInRoom` snapshotem. Snapshot před další zprávou, duplicitní
snapshot nebo chybějící snapshot jsou malformed response bez částečného
commitu. HTTP 400 vyžaduje nový settings/capability profil, 401 pozastaví pouze
daný účet, 404 vyžádá autoritativní room session refresh a 409 ukončí aktuální
session epoch.

Transportní chyba settings GET uvolní přesně odpovídající pending request a
přejde do `settingsRefreshRequired`, takže lze naplánovat nový bounded pokus.
Nejednoznačnost GET nikdy sama nevyžádá media renegotiation. Settings, HPB a
embedded internal JSON odmítají duplicitní členy objektu včetně escaped klíčů.

Batch POST obsahuje URL-encoded pole `messages`. Každá položka musí mít
`ev=message`, JSON string `fn`, aktuální Nextcloud session ID a konkrétního
příjemce. Transportní chyba před body dovoluje nový plán. Možná odeslané body
se automaticky neopakují a vyžadují nové vyjednání.

## Settings a endpoint trust

Internal profil přijme jen `signalingMode=internal`. External profil vyžaduje
TLS HPB endpoint a alespoň jeden kompletní hello credential profil. Production
endpoint smí používat pouze `https` nebo `wss`, nesmí mít userinfo, query ani
fragment a kanonický socket končí `/spreed`.

Nextcloud app password, cookie ani Basic auth se na HPB neposílají. Full hello
1.0 nese pouze serverem vydaný ticket, user ID a backend URL odvozené ze stejné
Nextcloud identity. Hello 2.0 nese serverem vydaný token. Federation endpoint,
vzdálený Nextcloud origin, room token a hello token tvoří samostatnou trust
hranici; lokální credentials se na vzdálený server nepřeposílají.

Ticket, JWT, TURN credential, federation token, resume ID, SDP a ICE candidate
nejsou součástí `toString()`, výjimky ani durable snapshotu.

Settings response navíc nese bounded `sipDialinInfo` s room-specific
telefonními instrukcemi. Flutter jej používá jen transientně v detailu
konverzace; hodnota může obsahovat telefonní čísla, proto se neloguje ani
neukládá do durable call snapshotu.

## HPB handshake a epochy

Po otevření socketu runtime čeká nejvýše jednu sekundu na volitelný `welcome`,
aby zůstal čas do dvousekundového serverového hello limitu. `hello-v2` z
`welcome` povolí hello 2.0 pouze s dostupným V2 tokenem; jinak se použije plný
V1 profil. Chybějící bezpečný fallback je `unsupported`.

Úspěšný full hello:

1. vytvoří novou signaling session a room epoch;
2. zahodí participant snapshot a všechny staré ephemeral peer frame;
3. odešle room join s aktuálním Nextcloud session ID;
4. označí signaling jako ready až po room potvrzení.

Odpojení zachová resume pouze 30 sekund. Úspěšný resume musí vrátit stejný HPB
session ID a zachová room epoch. Expirované resume nebo autoritativní
`no_such_session` přejdou na nový full hello. `too_many_requests` vytvoří
samostatný backoff deadline a nesmí způsobit okamžitou reconnect smyčku.
Příznak požadované renegotiation je sticky: settings refresh, resume ani room
potvrzení jej nesmějí samy vymazat. Opakovaný reconnect nesmí prodloužit původní
30sekundový resume deadline.

Socket callback se aplikuje jen při shodě account ID, serveru, credential a
capability generace, settings revision, room tokenu, connection epoch a room
epoch. Autoritativní re-auth/settings/room refresh explicitně zavře starý socket
a zahodí jeho pending requesty.

## Participant a federation stav

Join, change, leave a participant update se slučují podle HPB session ID.
`participants/update` používá upstream camel-case `userId` a
`nextcloudSessionId`; varianta `all=true` atomicky nastaví `inCall` celému
aktuálnímu snapshotu.

Inbound `message` a `control` přijmou sendera pouze tehdy, když je stále v
aktuálním participant snapshotu. Během `federation_interrupted` se federované
sendery odmítnou, zatímco aktuální lokální sender zůstává povolený.

`federation_interrupted` pozastaví media admission. Při
`federation_resumed=false` se zahodí pouze federované peers, lokální peers
zůstanou a runtime vyžádá renegotiation. Feature `mcu` vybírá external MCU
topologii; bez ní zůstává external peer-to-peer. Neznámé top-level server frame
je bounded `unsupported`, ale malformed známé frame je chyba.

## Flutter typing projekce

Commit `9499288` zapojuje signaling do otevřeného root i thread chatu.
Room-scoped provider vznikne jen pro autentizovaný účet s `signaling-v3`,
feature `typing-privacy` a veřejnou `config.chat.typing-privacy=0`. Chybějící,
privátní nebo nevalidní policy a internal transport končí bez banneru i bez
outbound frame.

Příchozí stav se drží podle HPB peer ID v přesném account/room scope. Opakovaný
`startedTyping` obnoví 15sekundový timeout, `stoppedTyping`, odchod peeru,
ztráta ready transportu nebo zavření roomu stav odstraní. Lokální composer
pošle start konkrétním příjemcům, při souvislém psaní ho obnoví po 10 sekundách
a po pěti sekundách nečinnosti pošle stop. Root a thread sdílejí jednu room
session, ale každý composer má vlastní source identitu; neaktivní root proto
nesmí zastavit člověka píšícího ve vedlejším threadu.

Návrh odpovídá upstream klientům `talk-android@5428960` a
`talk-ios@2d31eda`. Live web → iOS round trip na referenční instanci ověřil
start i stop bez odeslání zprávy. Screenshot iOS 18.6 měl pixelový kontrast
4,72:1 ve světlém a 11,15:1 v tmavém režimu.

## Executable důkaz

Aktuální contract sada obsahuje:

- 3 OpenAPI HTTP operace;
- 15 HTTP případů;
- 9 settings případů;
- 28 HPB client/server frame;
- 21 runtime scénářů s 33 stavovými přechody;
- 9 Python unit testů validátoru.

Signaling část má 58 Dart testů: 9 contract, 18 runtime, 14 security,
13 lifecycle, 3 skutečné loopback network a 1 release AOT test.

Dart testy navíc načítají settings a server HPB fixtures přímo. Reálný loopback
test používá `dart:io HttpServer`, skutečný GET pull, skutečný form POST a
skutečný WebSocket upgrade. Ověřuje:

- `welcome` → hello 2.0 → room join;
- odpojení → reconnect → úspěšný resume stejné session;
- reconnect po expiraci resume → nový full hello → room rejoin.

Release probe sestaví a spustí signaling scénář jako skutečný AOT executable.
Validace kontraktu běží příkazem:

```powershell
rtk proxy python contracts\signaling\validate_contract.py
rtk proxy python -m unittest discover -s contracts\signaling -p "test_*.py" -v
```

## Co tento řez nedokazuje

- Flutter HTTP/WebSocket adapter a Drift signaling persistence existují;
  tento řez stále nedokazuje call media engine ani celý call lifecycle.
- Neexistuje spustitelné APK, call UI ani WebRTC media engine.
- Nebyl provedený write test proti cizí nebo produkční room.
- Lokální HPB server nedokazuje TURN, MCU media ani reálný internetový reconnect.
- `chatujmePixel` signaling checklist zůstává nezaškrtnutý do vzniku skutečného
  release/profile APK. Musí ověřit změnu sítě, resume pod i nad 30 sekund,
  internal fallback, room rejoin, process death a dva účty na dvou serverech.
- Background/killed FCM, dlouhodobý výkon a skutečné radio/network přechody
  navíc vyžadují fyzické Android zařízení. Call parity vyžaduje také fyzické
  Android/iOS testy v budoucím media řezu.

Signaling ready tedy znamená pouze připravený signaling transport. Neznamená
`mediaReady`, `inCall` ani dokončenou mobilní aplikaci.
