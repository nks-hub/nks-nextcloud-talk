# Kontrakt přidání Nextcloud účtu

Datum ověření: 22. srpna 2026.

Stav: OpenAPI, syntetické fixture, bezpečnostní scénáře, pure Dart parser a
read-only živý smoke jsou spustitelně ověřené. Flutter HTTP/UI vrstva, secure
storage a dokončené přihlášení zatím neexistují.

## Rozsah

Kontrakt popisuje první klientský řez:

1. normalizaci uživatelem zadaného serveru;
2. veřejný `status.php`;
3. browser-mediated Login Flow v2;
4. anonymní a následně přihlášené OCS capabilities;
5. bezpečný vznik lokálního `accountId`.

Nejde o nový serverový endpoint. OpenAPI zachycuje existující Nextcloud wire
chování, zatímco validátor doplňuje klientské trust invarianty, které samotné
JSON Schema neumí vyjádřit.

Autoritativní zdroje:

- Nextcloud server
  [`d7c20b71e219461ff0c677b3846b9d1d723ff17f`](https://github.com/nextcloud/server/tree/d7c20b71e219461ff0c677b3846b9d1d723ff17f),
  zejména `status.php`, `ClientFlowLoginV2Controller.php`,
  `LoginFlowV2Service.php` a `OCSController.php`;
- Talk Android
  [`5428960f9d1eca708df1b39a0831141dcbba4729`](https://github.com/nextcloud/talk-android/tree/5428960f9d1eca708df1b39a0831141dcbba4729),
  zejména `NetworkLoginDataSource.kt` a login response modely;
- runtime baseline referenční instance z 22. srpna 2026; opakovatelný smoke
  načítá jen status a anonymní capabilities, zatímco jednorázové ověření init
  vytvořilo pouze expirovatelný nedokončený Login Flow.

OpenAPI 3.1 je v
[`contracts/client-bootstrap/openapi.json`](../../contracts/client-bootstrap/openapi.json).

## Normalizace serveru

Výstup normalizace je kanonický server base URL, nikoli libovolná webová URL.
Zachovává se legitimní Nextcloud subpath, například `/nextcloud`.

<!-- markdownlint-disable MD013 -->

| Vstup | Výsledek |
| --- | --- |
| `cloud.example.invalid` | `https://cloud.example.invalid` |
| `HTTPS://Cloud.Example.Invalid/nextcloud/` | `https://cloud.example.invalid/nextcloud` |
| `https://cloud.example.invalid:443` | `https://cloud.example.invalid` |
| HTTP | Jen explicitní debug policy; production jej odmítne |
| Userinfo, query, fragment nebo backslash | Odmítnout |
| Control character, dot segment, encoded nebo dvojitý path separator | Odmítnout |
| Neplatný port, trailing-dot host nebo nekanonický IPv4 | Odmítnout |

<!-- markdownlint-enable MD013 -->

Reference validátor používá záměrně konzervativní subpath segmenty. Rozšíření o
další legitimní kódování vyžaduje nový pozitivní i kolizní fixture; nesmí vzniknout
tichým `decode` a opětovným skládáním URL.

## Server readiness

`GET /status.php` je veřejný a bez credentials. Klient nepokračuje, pokud platí
alespoň jedna podmínka:

- `installed` je `false`;
- `maintenance` je `true`;
- `needsDbUpgrade` je `true`.

`version` a `versionstring` slouží pouze diagnostice. O povolení funkcí rozhodují
capabilities po přihlášení.

## Login Flow v2

Inicializace je prázdný `application/x-www-form-urlencoded` POST na
`/index.php/login/v2`. Stabilní `User-Agent` nese lidský název a verzi produktu,
protože správce může Login Flow omezit podle user-agent policy.

Odpověď vrací dva nezávislé opaque tokeny:

- `login` je URL otevřená v systémovém browseru;
- `poll.token` se posílá jako form-urlencoded `token` na `poll.endpoint`.

Před otevřením browseru nebo odesláním poll tokenu klient ověří:

- stejný origin jako ověřený server; v production vždy HTTPS;
- stejný Nextcloud base path;
- přesný poll path `/index.php/login/v2/poll`;
- login path `/index.php/login/v2/flow/{opaque-token}`;
- žádné userinfo, query, fragment, control character ani encoded path úniky.

Cross-origin login URL se nikdy neotevře a cross-origin poll endpoint nikdy
nedostane token. Totéž platí pro URL na stejném hostu, která unikla z ověřeného
subpath. Explicitní debug HTTP policy se musí předat celým tokem; nesmí povolit
jen první normalizaci a potom změnit trust pravidla u Login Flow nebo
credentials.

Nedokončený poll vrací HTTP 404 a JSON `[]`. Stejný výsledek znamená také
neplatný, expirovaný nebo již spotřebovaný token. Klient jej proto nesmí
interpretovat jako jisté „uživatel ještě čeká“. Reaguje bounded pollingem,
stavem browser toku a novou inicializací po skončení lokálního časového okna.

Úspěšný poll vrátí `server`, `loginName` a `appPassword` právě jednou. Serverová
implementace v uvedeném SHA generuje 128znakové login/poll tokeny, 72znakový app
password a záznam po 1 200 sekundách expiruje. Klient s nimi zachází jako s
opaque hodnotami a nespoléhá na konkrétní délku mimo bezpečnostní limity.

## Credential commit a accountId

Pole `server` v úspěšné odpovědi se znovu normalizuje a musí být shodné s
původně ověřeným base URL. Změna originu nebo subpath celý výsledek zneplatní.

Po validaci klient:

1. vytvoří nové náhodné lokální UUID `accountId`;
2. uloží app password pod account-scoped klíčem přímo do Keystore nebo Keychain;
3. v databázové transakci uloží účet, odkaz na secure-storage položku a stav
   `capabilitiesPending`;
4. načte capabilities s novými credentials a v další transakci uloží
   account-scoped snapshot a přepne účet do ready stavu;
5. při selhání prvního DB commitu smaže novou secure-storage položku, případně
   vytvoří bounded lokální cleanup tombstone.

App password se nikdy nezapisuje do běžné databáze, fixture výstupu ani logu.
Když první lokální commit po spotřebování poll odpovědi selže, nelze credentials
získat podruhé; klient bezpečně uklidí lokální secret a vyžádá nový Login Flow.
Síťová chyba při následném capability requestu naopak ponechá zabezpečený účet
ve viditelném `capabilitiesPending` stavu a request lze bezpečně opakovat bez
nového loginu.

## Dvě capability fáze

`GET /ocs/v2.php/cloud/capabilities?format=json` používá hlavičku
`OCS-APIRequest: true`.

Anonymní odpověď je vhodná jen pro onboarding a základní diagnostiku. Na
referenční instanci obsahovala 5 namespace a 105 Spreed features, ale například
Notifications namespace chyběl a account-dependent attachment stav nebyl
autoritativní.

Po získání app passwordu klient endpoint zopakuje s Basic auth. Teprve tato
odpověď je account-scoped capability snapshot. Referenční odpověď měla 26
namespace a Notifications `push` funkce `devices`, `object-data` a `delete`.
Neznámé namespace a pole se bezpečně zachovají nebo ignorují; deserializace kvůli
nové serverové capability nesmí selhat.

Snapshot patří výhradně konkrétnímu `accountId`. Anonymní a přihlášená odpověď
se nesmějí sdílet ani přepsat globální cache.

## Spustitelné ověření

Lokální validace z kořene repozitáře:

```powershell
rtk proxy python contracts\client-bootstrap\validate_contract.py
```

Read-only živý smoke:

```powershell
rtk proxy python contracts\client-bootstrap\validate_contract.py `
  --live-origin https://cloud.example.invalid
```

Validátor provádí:

1. OpenAPI 3.1 validaci.
2. Draft 2020-12 kontrolu pozitivních i negativních fixtures.
3. Skutečný form encode/decode round trip.
4. Dvacet dva origin normalizačních scénářů.
5. Root, subpath, debug HTTP, oba cross-origin směry a oddělené login/poll
   base-path-escape scénáře.
6. Shodu credential serveru včetně subpath a syntetický-secret scan.
7. Oddělenou klasifikaci anonymních a account capabilities.
8. Úplnost manifestu a zákaz nevypsaného fixture.

Aktuální výsledek: 1 OpenAPI dokument, 20 fixtures, 22 origin případů,
2 status klasifikace, 7 login trust scénářů, 5 credential scénářů a 2 capability
snapshoty prošly. Živý smoke navíc potvrdil 5 anonymních namespace a 105 Talk
features bez zápisu na server.

Stejných 20 fixtures a 22 origin případů nyní načítají testy produkčního pure
Dart balíku [`talk_protocol`](../../packages/talk_protocol). Implementace navíc
ověřuje IDN/Punycode host, subpath-aware endpointy, redigované výjimky,
duplicitní feature a zákaz domýšlet význam neznámého poll HTTP statusu.

Ověření z adresáře `packages/talk_protocol`:

```powershell
dart analyze --fatal-infos
dart test
```

Na Flutteru 3.44.4 a Dartu 3.12.2 prošla statická analýza bez nálezu a všech 54
Dart testů. Jeden sestaví a spustí release executable, druhý spustí VM s profile
compile-time příznakem; oba prokazují, že ani volba debug policy nepovolí HTTP.
Další testy omezují neznámé capability JSON na 64 úrovní a 10 000 uzlů. Runtime
závislost `punycoder` je uzamčená lockfilem a její MIT licence je zaznamenaná v
[auditu závislostí](dependency-licenses.md).

## Co důkaz ještě nepokrývá

Pure Dart parser není náhradou produkčního klienta. Zatím neprokazuje HTTP
transport, systémový browser lifecycle, secure storage, restart, dokončený
reálný login, odvolání app passwordu, dva servery v jedné instalaci ani únik
secretu v platformních crash logách. Tyto důkazy patří do implementačního řezu
1 po vytvoření platformního scaffoldingu.
