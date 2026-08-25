# Kontrakt push gateway

Datum ověření: 23. srpna 2026.

Stav: gateway wire kontrakt, klientský wire kontrakt, pure Dart registrační a
směrovací runtime i Go gateway jsou spustitelně ověřené. PostgreSQL datastore,
Firebase Admin adapter, worker a SSRF runtime existují. Zbývá container smoke,
Firebase projekt vydavatele, platformní crypto adapter a skutečné doručení.

## Přímá odpověď pro veřejný multi-server klient

Každý Nextcloud server nebude mít vlastní Firebase projekt. Jeden veřejný
podepsaný build používá jeden Firebase projekt a gateway vydavatele pro všechny
podporované servery.

Aplikace si z připojeného Nextcloudu načte pouze capabilities. Firebase
konfiguraci, service-account credential ani gateway URL ze serveru nestahuje.
Pevný důvěryhodný gateway origin je součástí konfigurace podepsané aplikace a
klient jej při registraci pošle do Notifications API v2 jako `proxyServer`.
Přidání dalšího serveru proto nevyžaduje rebuild.

Běžný správce Nextcloudu potřebuje aktivní standardní Notifications app,
funkční background jobs a odchozí HTTPS na gateway. Vlastní Nextcloud companion
app může později přidat diagnostiku a volitelné serverové funkce, ale pro tento
push tok není nutná a nesmí vytvářet druhý notification engine.

## Autoritativní kompatibilita

Kontrakt je vázaný na:

- Nextcloud Notifications
  [`f15413203a73eea7a42f454f6310ec5eca2735a0`](https://github.com/nextcloud/notifications/tree/f15413203a73eea7a42f454f6310ec5eca2735a0);
- serverový push-v2 popis a `Push::sendNotificationsToProxies()` ze stejného
  SHA;
- Nextcloud server
  [`d7c20b71e219461ff0c677b3846b9d1d723ff17f`](https://github.com/nextcloud/server/tree/d7c20b71e219461ff0c677b3846b9d1d723ff17f),
  zejména převod pole `body` na URL-encoded `form_params` a veřejný
  identity-proof endpoint;
- Talk Android
  [`5428960f9d1eca708df1b39a0831141dcbba4729`](https://github.com/nextcloud/talk-android/tree/5428960f9d1eca708df1b39a0831141dcbba4729),
  `NcApi.java` a `PushUtils.kt`;
- Talk iOS
  [`2d31eda5e2acbf3cef27aa289376942bdf0de25d`](https://github.com/nextcloud/talk-ios/tree/2d31eda5e2acbf3cef27aa289376942bdf0de25d),
  `NCAPIController.swift`.

OpenAPI 3.1 je v
[`contracts/push-gateway/openapi.json`](../../contracts/push-gateway/openapi.json).
Klientská OCS/envelope hranice je v
[`contracts/push-client`](../../contracts/push-client/README.md).

## Skutečný wire formát

<!-- markdownlint-disable MD013 -->

| Operace | Primární formát | Důvod |
| --- | --- | --- |
| `POST /devices` | `application/x-www-form-urlencoded` | Oficiální Android používá Retrofit `@FormUrlEncoded`; iOS používá form serializer |
| `DELETE /devices` | Úplná trojice v query; přijme se i form body | Android používá `@QueryMap`, iOS posílá parametry DELETE; push-v2 dokument ukazuje tělo |
| `POST /notifications` | URL-encoded `notifications[0]`, `notifications[1]`, … | Nextcloud předává pole JSON řetězců přes HTTP klienta, který pole `body` převádí na `form_params` |
| Odpověď `/notifications` | JSON `unknown` + celočíselné `failed` | `Push::handleProxyResponse()` podle těchto dvou klíčů odstraňuje neznámé registrace a hlásí dílčí chybu |

<!-- markdownlint-enable MD013 -->

JSON-only `/devices` nebo `/notifications` by vypadal čistěji, ale nebyl by
kompatibilní se skutečnými klienty a Nextcloud serverem. Každá položka
`notifications[N]` je samostatný JSON string s poli `deviceIdentifier`,
`pushTokenHash`, `subject`, `signature`, `priority` a `type`.

## Význam odpovědí

`POST /devices` ověří RSA/SHA-512 podpis a idempotentně zapíše registraci.
Úspěch vrací `200` s prázdným tělem, protože právě to očekávají současní
klienti.

Server nejprve podepíše privátní JSON preimage pomocí SHA-512 a potom zveřejní
`deviceIdentifier` jako Base64 SHA-512 digestu stejného preimage. Gateway
preimage nezná, proto ověřuje podpis proti Base64-dekódovanému digestu v
prehashed režimu. Druhé SHA-512 hashování `deviceIdentifier` by platnou
registraci chybně odmítlo. Naproti tomu podpis notification `subject` se
ověřuje jako běžný SHA-512 podpis nad dekódovaným ciphertextem.

`DELETE /devices` odstraní pouze přesnou kryptografickou identitu. Stejný
fyzický FCM token smí zůstat navázaný na jiné accountId. Pokud query i body
existují současně, musí být shodné; jinak gateway vrátí `400`.

`POST /notifications` klasifikuje každou položku zvlášť:

- neznámý deviceIdentifier se přidá do `unknown` a nezvyšuje `failed`;
- chybný token hash, podpis, formát nebo durable enqueue zvýší `failed`;
- validní položka se před odpovědí zapíše do durable queue;
- dílčí chyba stále vrací `200` s přesnými počty.

Gateway nikdy nedešifruje `subject`. Ověří podpis ciphertextu a shodu SHA-512
uloženého tokenu s `pushTokenHash`; plaintext doplní až mobil po dešifrování a
následném OCS catch-up.

## Konflikt 409 a cloudId

Stejný provider token se běžně objeví u více účtů jedné instalace. Gateway proto
nesmí při konfliktu přepsat nebo smazat první účet. Vrátí `409`; klient může
registraci opakovat s `cloudId`.

Nextcloud `IUser::getCloudId()` pro HTTPS server běžně vrací tvar
`userid@host[/subpath]` bez schématu. Gateway použije ekvivalent přesného
Nextcloud parseru, chybějící schéma doplní pouze jako HTTPS a explicitní HTTP
odmítne. Uživatelské jméno může obsahovat `@`, takže prosté rozdělení na prvním
zavináči není správně.

Po bezpečném rozdělení gateway načte bez credentials veřejný endpoint
`/ocs/v2.php/identityproof/key/{url-encoded-user-id}` a porovná vrácený public
key. Remote část je SSRF hranice:

- pouze HTTPS, bez userinfo a fragmentu;
- žádný loopback, private, link-local, reserved ani IPv4-mapped IPv6 cíl;
- A/AAAA kontrola před requestem i při spojení;
- žádné redirecty;
- krátký timeout a omezené tělo i content type;
- žádný app password, FCM token nebo interní header v requestu.

LAN-only server proto nemusí 409 recovery na veřejné gateway dokončit. Vlastní
interní gateway jej může povolit jen explicitní egress politikou.

## Spustitelné fixture

Fixture obsahují syntetický veřejný RSA klíč, validní podpisy, registraci,
odhlášení, negativní request, 409 problem response a úplný i částečně chybný
batch. Neobsahují privátní klíč, skutečný FCM token ani uživatelská data.

Ověření z kořene repozitáře:

```powershell
python contracts\push-gateway\validate_contract.py
```

Validátor provádí:

1. OpenAPI 3.1 validaci.
2. Draft 2020-12 validaci všech pozitivních i negativních fixtures.
3. Reálný form/query/indexed-form encode-decode round trip.
4. RSA-2048/SHA-512 ověření registračních a notification podpisů.
5. SHA-512 token-hash kontrolu a deterministickou klasifikaci partial batch.

Aktuální výsledek: 1 OpenAPI dokument, 10 fixtures, 3 registrační podpisy,
4 notification obálky a 2 batch scénáře prošly.

## Klientský kontrakt a pure Dart runtime

Samostatný [`push-client` kontrakt](../../contracts/push-client/README.md)
obsahuje 1 OpenAPI dokument a 8 fixtures: OCS request/response, mobilní obálku,
normální wake-up, tři silent-delete varianty a jeden neplatný ambiguous payload.
Python validátor při každém běhu vygeneruje RSA-2048 klíče jen v paměti a reálně
ověří SHA512withRSA, OAEP SHA-1/MGF1 SHA-1 i PKCS#1 v1.5. Vygenerované obálky
přímo projdou `MobilePushEnvelope`; uložená wire fixture není vydávána za
encrypt/decrypt důkaz. Dart contract test načítá přímo stejný manifest a fixture.

`packages/talk_protocol/lib/src/push` implementuje jeden provider token pro více
účtů, samostatný key handle pro každý `accountId`, deterministickou single-flight
registrační frontu, přesný retry od selhané fáze, 409 recovery a exactly-one
decrypt routing. Capability disable zachová account key. Logout provede
Nextcloud unregister, gateway unregister a teprve potom zničení key handle;
transientní cleanup zůstává jako retryable revocation tombstone. Starý effect
po token nebo authority rotaci nemůže commitnout nový stav ani doroutovat push;
crypto dokončení se znovu váže na aktuální account snapshot.

Klientský řez prochází 42 Dart testy: 20 contract, 13 runtime, 8 security a 1
skutečný release AOT test. Celý `talk_protocol` po jeho doplnění prochází 527
testy.

## Co tento důkaz ještě nepokrývá

Samotný kontrakt neprokazuje datastore concurrency, skutečný cloudId request,
FCM HTTP v1, retry queue, invalid-token cleanup ani rate limit. Tyto části nyní
prokazují testy v `services/push_gateway`, včetně PostgreSQL 18, skutečného
Firebase Admin HTTP toku a loopback serveru. OpenAPI a fixture zůstávají jejich
neměnnou vstupní bránou, ne náhradou runtime testu.

Stále není prokázaný container health/restart smoke ani doručení na skutečné
zařízení přes publisher Firebase projekt. Recording provider ani úspěšný build
tyto dvě brány nenahrazují.
