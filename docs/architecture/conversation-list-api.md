# Kontrakt seznamu konverzací

Datum ověření: 22. srpna 2026.

Stav: OpenAPI, syntetické response fixture, capability a runtime wire scénáře,
transakční merge model, privacy guard i autentizovaný read-only live smoke jsou
spustitelně ověřené. Flutter store a UI zatím neexistují.

## Rozsah

Kontrakt popisuje `GET /ocs/v2.php/apps/spreed/api/v4/room` jako první
read-only část řezu konverzací. Ověřuje:

1. kandidátní API v4 podle account capability `conversation-v4` a jeho
   následné runtime potvrzení přes cursor/hash wire profil;
2. plný a inkrementální request bez background změny presence;
3. OCS obálku, room read model a serverové response hlavičky;
4. account-scoped merge a atomické uložení cursoru;
5. ochranu cache před chybným prázdným plným seznamem;
6. read-only live běh bez výpisu názvů, tokenů nebo zpráv.

Nejde o nový serverový endpoint ani o převzetí upstream modelu. OpenAPI
zachycuje existující wire formát a Python validátor samostatně vyjadřuje
klientské invarianty, které JSON Schema neumí popsat.

OpenAPI 3.1 je v
[`contracts/conversation-list/openapi.json`](../../contracts/conversation-list/openapi.json).
Přijaté mapování kontraktu do pure Dart runtime popisuje
[návrh Dart conversation runtime](../plans/2026-08-22-dart-conversation-runtime-design.md).

## Ověřený serverový kontrakt

Serverové chování bylo porovnané na Talk master
[`f2958bb25be6604240c58a3faf9a2033a30d20e5`](https://github.com/nextcloud/spreed/blob/f2958bb25be6604240c58a3faf9a2033a30d20e5/lib/Controller/RoomController.php#L243)
a stable v24.0.4
[`f9b9e9474e3621b47f74bf8890c4642cb49eed97`](https://github.com/nextcloud/spreed/blob/f9b9e9474e3621b47f74bf8890c4642cb49eed97/lib/Controller/RoomController.php#L239).
Tělo `getRooms()` je shodné; liší se jen posun řádků.

Samotný feature flag však existoval dřív než cursor varianta. Talk v15.0.8 na
SHA
[`9c12a6414fc12d6bb81cea387efded16f0301fc5`](https://github.com/nextcloud/spreed/blob/9c12a6414fc12d6bb81cea387efded16f0301fc5/lib/Capabilities.php#L66)
inzeruje `conversation-v4`, ale jeho
[`getRooms()`](https://github.com/nextcloud/spreed/blob/9c12a6414fc12d6bb81cea387efded16f0301fc5/lib/Controller/RoomController.php#L176-L238)
nemá `modifiedSince` a vrací Talk hash bez
`X-Nextcloud-Talk-Modified-Before`. Proto flag určuje pouze kandidáta a cursor
profil se potvrzuje z první full response.

Talk v16.0.0 na SHA
[`a0ebfedbce625d43d0a05d72e96df3b0e5a3ef9e`](https://github.com/nextcloud/spreed/blob/a0ebfedbce625d43d0a05d72e96df3b0e5a3ef9e/lib/Controller/RoomController.php#L176-L247)
už cursor profil má, ale ještě nezná `includeLastMessage`. Jde proto o optimalizační
hint, ne podmínku korektnosti: klient musí bezpečně přijmout `lastMessage`, i
když poslal `includeLastMessage=false`.

Parametry endpointu:

- `noStatusUpdate`: `0` nebo `1`; background fetch vždy posílá `1`;
- `includeStatus`: boolean; běžný kompaktní refresh posílá `false`;
- `modifiedSince`: nezáporný timestamp; jeho absence znamená plný fetch;
- `includeLastMessage`: boolean; kompaktní refresh posílá `false`;
- `format=json` a `OCS-APIRequest: true` vynucují JSON OCS odpověď.

Při `includeStatus=true` vrací inkrementální fetch všechny 1:1 rooms, aby mohl
obnovit presence. `includeLastMessage=false` šetří načtení posledních zpráv,
share a thread preload; plný chat preview bude mít vlastní chat kontrakt.

Server zachytí hodnotu `X-Nextcloud-Talk-Modified-Before` jako první operaci
metody, tedy před eventem, status update i načtením rooms. Další request s tímto
cursorem proto nevytváří časovou mezeru. Delta zahrnuje nejen novou aktivitu,
ale také změny attendee stavu a aktivní hovory.

## Response hlavičky

Úspěšná odpověď obsahuje:

- `X-Nextcloud-Talk-Modified-Before`: cursor dalšího delta requestu;
- `X-Nextcloud-Talk-Hash`: configuration hash relevantního serverového,
  Talk, signaling, federation, theming a user nastavení;
- volitelně `X-Nextcloud-Talk-Federation-Invites`, když existuje nenulový počet
  čekajících federovaných pozvánek.

Změna Talk hash pouze nastaví account-scoped požadavek na nové capabilities a
settings. Není důvodem pro smazání rooms.

## Capability, wire profil a request builder

Přesný feature flag `conversation-v4` v přihlášeném capability snapshotu
konkrétního účtu povolí pouze kandidátní v4 cestu. Neaktivuje tento kontrakt
sám. První validní full response musí před merge obsahovat úspěšnou OCS obálku,
schema-validní rooms, kanonický cursor
`X-Nextcloud-Talk-Modified-Before` a neprázdný
`X-Nextcloud-Talk-Hash`. Teprve potom účet uloží aktivní profil `cursor-v4`.

Chybějící cursor, chybějící hash nebo nekanonický cursor ponechá aktivní cestu
prázdnou a profil označí jako `unsupported-wire-profile`. Cache ani cursor se
nesmějí změnit. Legacy conversation-v4 bez tohoto profilu zůstává explicitně
nepodporovaná, dokud pro něj nevznikne samostatný adapter. Ani vysoké číslo Talk
release, ani samotné `conversation-v3` nejsou náhradní feature flag.

Request builder nese explicitní režim `full` nebo `incremental`. O mazání
lokálních dat rozhoduje tento režim, nikoli hodnota cursoru. To je podstatné i
pro bezpečný případ `incremental + modifiedSince=0`, který stále nesmí mazat.
Full request cursor neposílá; serverový default je `0`.

Každý request používá Basic auth a origin konkrétního `accountId`, stabilní
`User-Agent` s Android identitou `com.nkshub.nextcloudtalk` a hlavičku
`OCS-APIRequest: true`. Authorization se neloguje.

## Response a typové invarianty

Schema zachovává neznámá budoucí pole, ale vyžaduje stabilní room hodnoty
potřebné pro seznam, unread stav, permissions a budoucí call indikaci.
`lastMessage` je volitelná pro kompaktní response.

Před merge se navíc kontroluje:

- OCS `status=ok` a `statuscode=200`; failure uvnitř HTTP 200 není prázdný
  seznam;
- každý room má platný token;
- tokeny v jedné response jsou unikátní;
- token přítomného `lastMessage` se shoduje s tokenem jeho room;
- cursor, hash a volitelný federation counter odpovídají deklarovanému formátu.

Schema diagnostika obsahuje pouze strukturální JSON path a typ validatoru.
Nikdy nepřebírá `jsonschema` text s konkrétní chybnou hodnotou, takže live schema
drift nemůže vypsat room token, název ani obsah zprávy.

HTTP 401 přesune pouze dotčený účet do re-auth stavu. HTTP 426, 429, 503,
transportní chyba nebo neplatná OCS odpověď nesmějí smazat cache ani posunout
cursor.

## Account-scoped transakční merge

Primární klíč store je `(accountId, roomToken)`. Validátor vykonává stejný
minimální algoritmus, který musí později vlastnit Flutter persistence vrstva:

- inkrementální response pouze upsertuje vrácené rooms;
- validní neprázdný full response může odstranit chybějící rooms;
- cursor a configuration hash se uloží až v téže úspěšné transakci;
- schema, OCS nebo semantická chyba nechají room data i cursor beze změny;
- simulované selhání transakce vrátí celý candidate stav;
- shodný room token ve dvou účtech zůstává dvěma oddělenými záznamy.

Toto pravidlo odpovídá ověřenému iOS chování na SHA
[`2d31eda5e2acbf3cef27aa289376942bdf0de25d`](https://github.com/nextcloud/talk-ios/blob/2d31eda5e2acbf3cef27aa289376942bdf0de25d/NextcloudTalk/Rooms/NCRoomsManager.swift#L178-L229):
incrementální merge nemaže chybějící rooms a full merge mění room, messages,
chat blocks, threads a federated capabilities v jedné Realm transakci. Cursor
je uložený per account v
[`TalkAccount.lastReceivedModifiedSince`](https://github.com/nextcloud/talk-ios/blob/2d31eda5e2acbf3cef27aa289376942bdf0de25d/NextcloudTalk/Database/TalkAccount.h#L41).

## Dvoufázové potvrzení prázdného full seznamu

První validní full-empty response při existující cache je destruktivně
nejednoznačná. Store proto pouze uloží lokální ID a čas potvrzovacího requestu a
nepohne cursorem. Až druhý samostatný validní full fetch do 300 sekund může
odstranit všechny rooms a commitnout nový cursor.

Opakované zpracování stejného request ID není nezávislý důkaz. Účet, který už
žádné rooms nemá, může full-empty response přijmout hned. Tato ochrana neignoruje
legitimní smazání všech rooms natrvalo, ale zabrání jediné transientní nebo
vadné odpovědi zničit lokální historii.

Po překročení 300 sekund starý důkaz expiruje a nový full-empty jej pouze
nahradí. Jakákoli mezilehlá neprázdná inkrementální response jej vyvrátí a
zruší; další full-empty je proto znovu prvním důkazem, ne potvrzením smazání.

## Spustitelné ověření

Lokální validace z kořene repozitáře:

```powershell
rtk proxy python contracts\conversation-list\validate_contract.py
```

Volitelný live smoke načítá credentials pouze z proměnných
`NEXTCLOUD_TALK_USERNAME` a `NEXTCLOUD_TALK_APP_PASSWORD`:

```powershell
rtk proxy python contracts\conversation-list\validate_contract.py `
  --live-origin https://cloud.example.invalid
```

Validátor provádí:

1. OpenAPI 3.1 a Draft 2020-12 validaci.
2. Devět raw response fixtures včetně compact, empty, 401 a chyb.
3. Sedm přesných query-builder scénářů a wire round trip.
4. Dvanáct capability scénářů včetně candidate/active stavu, HTTP/OCS/schema
   chyby, chybějícího cursoru, chybějícího hashe a nekanonického cursoru.
5. Čtrnáct merge scénářů s devatenácti transakčními kroky.
6. Rejekci duplicate tokenu, preview mismatch a chybějícího tokenu.
7. Cursor rollback, account izolaci, hash refresh, expiraci a zrušení empty
   důkazu neprázdnou deltou.
8. Live-schema redaction guard s privátní marker hodnotou a IPv6 origin případ.
9. Úplnost manifestu a secret scan všech fixtures.

Aktuální lokální výsledek: 1 OpenAPI dokument, 9 response fixtures, 7 query
případů, 12 capability případů a 14 merge případů s 19 kroky prošlo. Navíc
prošel 1 live-schema redaction guard a 1 IPv6 origin případ.

Autentizovaný live smoke provedl přesně dva GET requesty s
`noStatusUpdate=1`, `includeStatus=false` a `includeLastMessage=false`. Full
response obsahovala 17 validních rooms a okamžitá delta 0 změn. Obě odpovědi
obsahovaly cursor i Talk hash. Výstup neobsahoval názvy, room tokeny, zprávy ani
credentials.

## Co důkaz ještě nepokrývá

Kontrakt není produkční Flutter implementace. Neprokazuje SQLite migrace,
cache-first obrazovku, skutečné odstranění room z jiného zařízení, background
scheduler, room detail, participants, favorite/archive mutace, dva servery v
jedné app instalaci ani měřený UI kontrast. Tyto důkazy zůstávají v řezu 2 po
schválení zbývajících platformních voleb a vytvoření scaffoldingu.
