# Kontrakt rich chatu a vláken

Datum ověření: 26. srpna 2026.

Stav: OpenAPI, syntetické fixture, pure Dart request/response model, bezpečný
semantic renderer a account-scoped transakční planner jsou spustitelné. Flutter
aplikace už má cache-first root/thread timeline, text send, GFM/Rich Object
zobrazení, obrázky s interním viewerem, reakce, reply preview a avatary; bohaté
mutation příkazy z tohoto kontraktu zatím do Flutter runtime zapojené nejsou.

Text send do serverového named threadu je implementovaný v samostatném chat
kontraktu revision r2. Využívá `threadId` bez `replyTo` a neznamená, že jsou
implementované rename/notification-level nebo další rich thread mutace níže.

Giphy se podle D-028 odesílá jako textová `resourceUrl` reference a bublina ji
skryje a vykreslí inline přes account-scoped Nextcloud References resolver.
Historická attachment varianta D-028a už není produktový tok. Podrobný kontrakt
je v [Giphy integraci](../research/giphy-integration.md).

## Rozsah

Kontrakt pokrývá 21 existujících Talk operací:

- hledání mentions;
- recent, subscribed a detail vláken, přejmenování a notification level;
- načtení, přidání a odebrání reakcí;
- editaci a smazání zprávy;
- pin, unpin a skrytí pinu pro aktuálního uživatele;
- načtení, vytvoření a smazání reminderu;
- seznam, vytvoření, editaci a smazání naplánované zprávy.

OpenAPI 3.1 je v
[`contracts/rich-chat/openapi.json`](../../contracts/rich-chat/openapi.json).
Schema zachovává neznámá serverová pole, ale vyžaduje identity nutné pro
account, room, message, thread a schedule vazbu.

## Ověřený baseline

Wire a capability chování je vázané na:

- Talk server `f2958bb25be6604240c58a3faf9a2033a30d20e5`;
- stabilní Talk replay reference
  `f9b9e9474e3621b47f74bf8890c4642cb49eed97`;
- Talk Android `5428960f9d1eca708df1b39a0831141dcbba4729`;
- Talk iOS `2d31eda5e2acbf3cef27aa289376942bdf0de25d`.

Jde o vlastní typy nad veřejným wire kontraktem a syntetickými daty. Do tohoto
řezu nebyl převzatý zdrojový kód ani asset oficiálních klientů.

## Capability profil

Resolver vychází jen z unikátních Talk features, nikdy z čísla release.

| Funkce | Nutné podmínky |
| --- | --- |
| Mentions | `chat-v2` |
| Metadata vláken | `chat-v2` + `threads` |
| Zprávy vlákna | metadata vláken |
| Reakce | `chat-v2` + `reactions` |
| Odeslání reakce | reakce a při `react-permission` participant bit 256 |
| Editace | `chat-v2` + `edit-messages` |
| Smazání | `chat-v2` + `delete-messages` |
| Pin | `chat-v2` + `pinned-messages` a moderator |
| Skrytí pinu | `chat-v2` + `pinned-messages` |
| Reminder | `chat-v2` + `remind-me-later` |
| Schedule | lokální `scheduled-messages` a nefederovaná room |

`scheduled-messages` z globálních features se záměrně nepřijímá. Federovaný
profil zachová thread metadata i capability-bound detail zpráv vlákna; odmítne
jen nepodporované lokální schedule operace.

## Request a trust hranice

Každý request nese `accountId`, lokální request ID, kanonický `ServerBase`,
capability profil a dostupný room, message, thread nebo schedule identifikátor.
Account-wide subscribed threads je jediná operace bez room tokenu. Response
uchovává původní request a planner nesmí merge kontext přijmout bokem.

Notification-level request rozlišuje message target a canonical root: wire URL
směřuje na `messageId` vybrané reply nebo root zprávy, zatímco povinný
`threadId` váže response na canonical root. Decoder odmítne chybějící nebo
nulový root i room/root mismatch a zachová původní request. Merge planner před
aplikací odmítne account/server snapshot mismatch.

Request builder vždy používá `format=json`, `OCS-APIRequest: true` a stabilní
`User-Agent`. Query, form body a headers jsou immutable. Diagnostika nevypisuje
room token, message text, hledaný text, emoji, rich parameters ani uživatelský
identifikátor.

Parser před vytvořením modelu:

1. omezí body na 8 MiB;
2. vyžádá validní UTF-8 JSON a bounded strom;
3. ověří HTTP status i OCS `statuscode` pro konkrétní operaci;
4. sváže data s původním account/server/room/message/thread kontextem;
5. hluboce zmrazí všechny zachované wire mapy a seznamy.

HTTP 401 přepne pouze cílový účet do re-auth stavu. Dokumentovaná validační,
permission a not-found odpověď je deterministické odmítnutí. Neočekávaný
status, 5xx nebo výsledek mutace, který mohl dorazit na server, je nejednoznačný
a nesmí vyvolat automatické opakování.

## Markdown a Rich Object Strings

Renderer používá `markdown` 7.3.1 s GFM extension setem a převádí AST do
vlastního immutable semantic tree. Raw HTML se nikdy nevrací jako vykonatelný
widget obsah. Rich Object placeholder se nahrazuje pouze v textových uzlech;
inline a block code zůstávají doslovné. Známý placeholder se vždy změní na
typovaný uzel, neznámý zůstane textem.

Společný budget pro plaintext i Markdown dovolí nejvýše 1 Mi znaků, 10 000
parametrů, hloubku 64 a 200 000 semantic uzlů včetně kořene dokumentu. Každý
uzel spotřebuje budget před konstrukcí a před lookupem parametru; přetečení se
proto odmítne bez materializace zbytku útočného vstupu.

Aktivní odkazy povolují pouze `https`, `mailto` a `tel`. Relativní odkaz se
přijme až po resolve na stejný server origin. Userinfo, řídicí znaky,
`javascript:`, `data:`, `file:`, `intent:` a cross-origin relativní výsledek se
nikdy nevrátí jako aktivní odkaz.

Mention typy user, guest, email, user-group, circle, call a federated user mají
vlastní semantic kind. Ostatní Rich Object Strings zůstávají typované generic
objekty s immutable metadata, aby je pozdější Flutter widget nemusel znovu
parsovat z raw textu.

## Account-scoped stav a atomický merge

`RichChatRuntimeSnapshot` vrství rich stav nad existující
`ChatRuntimeSnapshot`. Každý účet drží vlastní server a rooms; room drží
messages, threads, reminders, scheduled messages a odkaz na poslední zprávu.
Globální message ani thread registr neexistuje.

Jednorázový plán je vázaný na identitu přesného source snapshotu. Opakované
použití nebo aplikace na novější snapshot se odmítne. Simulovaný DB neúspěch
zahodí celý candidate.

- Reaction response nahradí celý aggregate a `reactionsSelf` odvodí z actor
  identity; stejná response je idempotentní.
- Reaction, edit i delete nahradí autoritativní message a v témže candidate
  opraví každou full-parent kopii v room messages, scheduled reply parent,
  thread first/last i room preview. Aktualizuje se také immutable `wire` parenta.
- Metadata vlákna s novým `lastMessageId`, ale bez těla nové zprávy, nezachová
  staré `lastMessage` pod nesprávným ID.
- Reminder a schedule stav je klíčovaný uvnitř účtu a room.
- Ambiguous schedule response stav nemění a nevytváří replay.

Online rich mutace nejsou v tomto řezu v durable outboxu. Každý budoucí
operation kind musí nejdřív získat vlastní SHA/capability-bound replay kontrakt
podle D-006.

## Spustitelné ověření

```powershell
rtk proxy python contracts\rich-chat\validate_contract.py
rtk proxy python contracts\rich-chat\test_validate_contract.py
rtk C:\work\sources\flutter-sdk\flutter\bin\dart.bat analyze --fatal-infos
rtk C:\work\sources\flutter-sdk\flutter\bin\dart.bat test
```

Aktuální lokální výsledek:

- 1 OpenAPI dokument a 21 operací;
- 23 response, 28 request, 8 capability, 9 render a 7 state fixture s
  8 transakčními kroky;
- 10 Python validator unit testů;
- 98 Dart rich-chat testů: 69 contract, 13 state, 15 security a 1 skutečný
  release AOT executable;
- celý `talk_protocol` po thread binding opravě prochází 774 testy a analyzer
  je bez nálezu.

Historická attachment větev vznikla v `5d49cbb`, `9de5727` a `7ca580e`, ale
uživatelské rozhodnutí D-028 ji nahradilo. Commit `2af2430` přepnul picker na
renderovanou `resourceUrl` přes text-send/outbox a zachoval account-scoped
References validaci i inline renderer; pozdější `4cc3594` a `236e3c4` změnu
pouze atomizovaly. Jde o automatizovaný adapter důkaz, ne aktuální živý
sender/recipient round trip.

## Co důkaz nepokrývá

Flutter HTTP/Drift/UI základ existuje. Historické Android APK SHA-256
`0d38d4ab2a665883d0ee0de7426f201c107cefc6b5f7e701b1c856255f6195cf`
prošlo přihlášením, otevřením room a Giphy wire-reference
send/inline/process-death scénářem. Neprokazuje aktuální source, samostatný
sender/recipient round trip ani rich mutation round trip. Ještě starší Android
APK SHA-256
`<fingerprint>`
prošlo příchozím thread smokem, screenshoty a pixelovým WCAG měřením; tento
důkaz se nepřenáší na novější build. Nebyl spuštěný live round trip pro
edit/delete, reaction mutation, pin, reminder nebo schedule ani jejich
restart/reconciliation tok. Celý rich-chat mutation checklist musí ještě projít
na `chatujmePixel`; background/killed Web Push a výkon navíc vyžadují fyzické
Android zařízení.
