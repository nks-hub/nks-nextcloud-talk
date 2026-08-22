# Kontrakt seznamu konverzací

Datum ověření: 22. srpna 2026.

Stav: OpenAPI, syntetické response fixture, capability a runtime wire scénáře,
produkční pure Dart parser a merge planner, privacy guard i autentizovaný
read-only live smoke jsou spustitelně ověřené. Flutter store a UI zatím
neexistují.

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
Implementace je v
[`packages/talk_protocol/lib/src/conversations`](../../packages/talk_protocol/lib/src/conversations).

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

Pure Dart request navíc nese neměnný `accountId`, lokální request ID a
kanonický `ServerBase`; URI se odvozuje přímo z tohoto kontextu. Decoder připojí
tentýž request ke každému success i failure výsledku. Merge planner proto
nepřijímá samostatný účet, request ID ani request a nemůže je zaměnit mezi
souběžnými servery.

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

Při prvním profile probe HTTP 401 vrací samostatný re-auth výsledek. HTTP 426,
429, 503 a validní OCS failure potvrzení pouze odloží. Za
`unsupported-wire-profile` se považuje jen strukturálně nekompatibilní HTTP 200
odpověď, například chybějící cursor/hash nebo vadné schema. Dočasná chyba tak
nemůže podporovaný účet trvale vyřadit. HTTP/OCS stav se klasifikuje před
kontrolou full probe režimu, takže 401 zůstává re-auth i po incremental requestu.

## Pure Dart runtime

Balík `talk_protocol` nyní implementuje celou platformně neutrální hranici:

- `ConversationListRequest` vlastní account, request ID, server, explicitní
  full/incremental režim, kanonický query string, OCS hlavičku, User-Agent a
  subpath-aware URI;
- response decoder rozlišuje success, re-auth, OCS failure a podporované
  HTTP 426/429/503 bez domýšlení neznámého statusu a každý výsledek váže na
  původní request;
- hlavičky jsou case-insensitive a jejich case varianty se nesmějí opakovat;
- `ConversationRoom` a `ConversationPreview` typují list, unread, permission,
  call a preview hodnoty a zachovávají hluboce neměnný wire objekt;
- jeden JSON freeze budget platí přes všechny rooms odpovědi, hloubka je
  omezená na 64 a počet rooms na OpenAPI maximum 100 000;
- diagnostické `toString()` nevypisují account ID, token, název ani zprávu;
- capability resolver přijme jen přihlášený `conversation-v4` snapshot a
  aktivuje `cursor-v4` teprve po validním full probe; re-auth, deferred a
  strukturálně unsupported výsledky zůstávají typově odlišné.

HTTP transport zůstává záměrně mimo pure Dart balík. Musí před JSON decode
udržet již navržený limit 8 MiB, zakázat redirecty a použít credentials
konkrétního účtu.

## Account-scoped transakční merge

Primární klíč store je `(accountId, roomToken)`. Pure Dart
`ConversationMergePlanner` vykonává stejný minimální algoritmus, jehož DB
operace později atomicky provede Flutter persistence vrstva:

- inkrementální response pouze upsertuje vrácené rooms;
- validní neprázdný full response může odstranit chybějící rooms;
- cursor a configuration hash se uloží až v téže úspěšné transakci;
- schema, OCS nebo semantická chyba nechají room data i cursor beze změny;
- simulované selhání transakce zahodí candidate plán a ponechá původní stav;
- shodný room token ve dvou účtech zůstává dvěma oddělenými záznamy.
- request účtu nebo serverového originu B nelze aplikovat do snapshotu účtu A.

Planner vrací neměnné upserty, přesné tokeny k odstranění a nový account stav.
Sám netvrdí, že persistence proběhla. Test pádu transakce zahodí celý candidate
plán a ověří původní snapshot i cursor; budoucí Drift adapter musí stejné
operace provést v jedné skutečné transakci.

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

Pure Dart ověření z `packages/talk_protocol`:

```powershell
dart analyze --fatal-infos
dart test
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
prošel 1 live-schema redaction guard a 1 IPv6 origin případ. Stejné conversation
fixtures přímo načítá 71 Dart testů; spolu s bootstrap testy prochází 125 testů.
Patří mezi ně regrese pro account/origin binding i pro re-auth a deferred profile
probe; statická analýza je bez nálezu.

Autentizovaný live smoke provedl přesně dva GET requesty s
`noStatusUpdate=1`, `includeStatus=false` a `includeLastMessage=false`. Full
response obsahovala 17 validních rooms a okamžitá delta 0 změn. Obě odpovědi
obsahovaly cursor i Talk hash. Výstup neobsahoval názvy, room tokeny, zprávy ani
credentials.

## Co důkaz ještě nepokrývá

Pure Dart runtime není produkční Flutter aplikace. Neprokazuje SQLite migrace,
cache-first obrazovku, skutečné odstranění room z jiného zařízení, background
scheduler, room detail, participants, favorite/archive mutace, dva servery v
jedné app instalaci ani měřený UI kontrast. Tyto důkazy zůstávají v řezu 2 po
schválení zbývajících platformních voleb a vytvoření scaffoldingu.
