# Audit závislostí a assetů

Datum poslední kontroly: 23. srpna 2026.

Tento dokument je průběžná distribuční brána pro projekt licencovaný pod
`GPL-3.0-or-later`. Evidence vychází z konkrétního lockfilu a licenčního souboru
staženého balíku; popis balíku nebo štítek na webu sám nestačí.

## Přímé runtime závislosti

<!-- markdownlint-disable MD013 -->

| Komponenta | Verze a integrita | Licence a notice | Použití | Stav |
| --- | --- | --- | --- | --- |
| [`punycoder`](https://pub.dev/packages/punycoder) | 0.3.0; SHA-256 `982734df864d9588eb13e28ac1c5a46b57e22117b3696032ac58739966cec190` v `packages/talk_protocol/pubspec.lock` | MIT; Copyright 2025 dropbear-software; notice musí zůstat v distribučních materiálech | RFC 3492/IDNA převod Unicode hostname na kanonický ASCII tvar | Kompatibilní s GPL-3.0-or-later; zdrojový balík a lokální LICENSE ověřeny |
| [`markdown`](https://pub.dev/packages/markdown) | 7.3.1; archive SHA-256 `ee85086ad7698b42522c6ad42fe195f1b9898e4d974a1af4576c1a3a176cada9` v `packages/talk_protocol/pubspec.lock`; lokální LICENSE SHA-256 `0aa335b5e036b9efbb35ad7a35835cd32e4eb656c08bfe040550a9f6fa84fcc7` | BSD-3-Clause; Copyright 2012, the Dart project authors; notice a disclaimer musí zůstat ve zdrojové i binární distribuci | GFM AST pro převod zprávy do vlastního bezpečného Rich Object semantic tree | Kompatibilní s GPL-3.0-or-later; zdrojový balík a lokální LICENSE ověřeny |
| [`xml`](https://pub.dev/packages/xml) | 7.0.1; archive SHA-256 `67f0aff7be013d107995e9b75bf4e7f2c3ef2dfdb2c8e68024bba0a7fd5756a4` v `packages/talk_protocol/pubspec.lock`; lokální LICENSE SHA-256 `0be767174b97278f17da4923a74169e8645631f03ea3d8482ec3523c9b1a0dd3` | MIT; Copyright 2006–2026 Lukas Renggli; notice musí zůstat ve všech podstatných kopiích | Namespace-aware WebDAV multistatus parser za vlastní UTF-8, DTD/entity a resource budget hranicí | Kompatibilní s GPL-3.0-or-later; zdrojový balík a lokální LICENSE ověřeny |

<!-- markdownlint-enable MD013 -->

## Transitivní runtime závislosti

<!-- markdownlint-disable MD013 -->

| Komponenta | Verze a integrita | Licence a notice | Důvod v artefaktu | Stav |
| --- | --- | --- | --- | --- |
| [`petitparser`](https://pub.dev/packages/petitparser) | 7.0.2; archive SHA-256 `91bd59303e9f769f108f8df05e371341b15d59e995e6806aefab827b58336675` v `packages/talk_protocol/pubspec.lock`; lokální LICENSE SHA-256 `d2e8ffdbe89acbc10d5d1f2b03e7dbddf0a9f1742e809176682b62ef3d573b3e` | MIT; Copyright 2006–2024 Lukas Renggli; notice musí zůstat ve všech podstatných kopiích | Parser runtime vyžadovaný balíkem `xml`; projekt jej přímo nevolá | Kompatibilní s GPL-3.0-or-later; zdrojový balík a lokální LICENSE ověřeny |

<!-- markdownlint-enable MD013 -->

## Go push gateway

Přesný distribuovaný graf byl 23. srpna 2026 odvozen přes `go list -deps` pro
`services/push_gateway/cmd/push-gateway`, nikoli ze všech položek v module cache.
Verze a integrita jsou uzamčené v `go.mod` a `go.sum`; plné lokální licenční
texty každého modulu byly přečtené z ověřeného module artefaktu.

<!-- markdownlint-disable MD013 -->

| Přímá závislost | Verze a Go checksum | Licence | Role | Stav |
| --- | --- | --- | --- | --- |
| `firebase.google.com/go/v4` | 4.21.0; `h1:HBZV4jrLtFYj8EwWyqEZOuRLfkfkV2bpnfyyXHOhPxY=` | Apache-2.0 | Produkční FCM Admin adapter přes ADC | GPL-3.0-or-later kompatibilní; zachovat LICENSE/NOTICE |
| `github.com/jackc/pgx/v5` | 5.10.0; `h1:VhSvgU2jSli8o3AqIEOTJr7rZwAEUVo4E4XhR94Zfr0=` | MIT | Produkční PostgreSQL pool a transakce | GPL-3.0-or-later kompatibilní; zachovat notice |
| `golang.org/x/net` | 0.58.0; `h1:ynWG7rqYi4ccpTEuPZ2QGWHktVEM9DMCj9yzDE0Q7To=` | BSD-3-Clause | IDNA a bounded TCP listener | GPL-3.0-or-later kompatibilní; zachovat notice a disclaimer |
| `google.golang.org/api` | 0.279.0; `h1:hsx2M2OaRcaKtVYK6vXEUnQvdjnend7ZYES+lYaot74=` | BSD-3-Clause | Test skutečného Firebase Admin HTTP toku | Test-only přímý import; GPL-3.0-or-later kompatibilní |
| `github.com/fergusstrange/embedded-postgres` | 1.34.0; `h1:c6RKhPKFsLVU+Tdxsx8q0UxCHsvZZ/iShAnljRBXs6s=` | MIT | PostgreSQL 18 integrační test | Test-only; není v produkčním build grafu |

<!-- markdownlint-enable MD013 -->

Produkční build graf obsahuje 55 externích modulů: 37 Apache-2.0, 11
BSD-3-Clause a 7 MIT. Nebyla nalezena GPL-nekompatibilní, neznámá ani chybějící
licence. `google.golang.org/protobuf` 1.36.11 byl navíc ručně ověřený z lokálního
`LICENSE` jako BSD-3-Clause, protože použitý pomocný detektor jej automaticky
neklasifikoval.

Integrační build přidává pouze `embedded-postgres` a `lib/pq` pod MIT a
`github.com/xi2/xz`, jehož lokální `LICENSE` dává zdrojové soubory do public
domain. Tyto tři moduly nejsou součástí produkční binárky. Release third-party
notice musí zahrnout úplné copyright notices všech 55 skutečně linkovaných
runtime modulů; tento audit jejich povinnost neruší.

## Vývojové závislosti

`lints` 6.1.0 a `test` 1.31.2 používají BSD 3-Clause licenci Dart projektu.
Nejsou runtime součástí aplikace. Jejich lokální `LICENSE` byl při přijetí
balíku přečtený; přesné transitive verze jsou uzamčené v lockfilu.

## Nástroje executable kontraktů

`contracts/push-client` znovu používá stejné přesně připnuté Python nástroje
jako existující `contracts/push-gateway`; nepřidává mobilní runtime závislost.
Lokálně nainstalovaná metadata 23. srpna 2026 potvrzují:

- `cryptography` 50.0.0: `Apache-2.0 OR BSD-3-Clause`;
- `jsonschema` 4.26.0: `MIT`;
- `openapi-spec-validator` 0.9.0: `Apache-2.0`.

Tyto balíky slouží pouze lokálnímu a CI generování a ověření syntetických
fixture. Nejsou součástí budoucího Android/iOS artefaktu. Jejich přesné verze
jsou v `contracts/push-client/requirements.txt` a
`contracts/push-gateway/requirements.txt`. Čistá instalace obou shodných sad a
`pip-audit` 23. srpna 2026 nenašly známou zranitelnost. Release notice se bude
tvořit z finálních distribuovaných artefaktů, nikoli z globálního Python
prostředí.

## Assety a převzatý kód

V tomto milníku nebyl přidán žádný obrázek, font, zvuk ani kód převzatý z
oficiálních Talk klientů. Implementace používá vlastní typy nad veřejným wire
kontraktem. Kořenový GPL text se proto nemění a nevznikl nový upstream
copyright notice.

## Brána pro další změny

Každá nová přímá závislost nebo asset musí před commitem doložit:

1. přesnou verzi a integritu z lockfilu;
2. celý licenční text z reálně staženého artefaktu;
3. GPL kompatibilitu a povinný copyright/notice;
4. zda je součástí distribuovaného runtime, pouze build nástroj, nebo dev test;
5. původ assetu a povolené úpravy nebo redistribuci.

Před release se z finálního Android a iOS artefaktu vytvoří úplný third-party
notice. Tento průběžný soubor nenahrazuje kontrolu transitive runtime závislostí
ani výsledného binárního balíku.
