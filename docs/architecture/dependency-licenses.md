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

## Vývojové závislosti

`lints` 6.1.0 a `test` 1.31.2 používají BSD 3-Clause licenci Dart projektu.
Nejsou runtime součástí aplikace. Jejich lokální `LICENSE` byl při přijetí
balíku přečtený; přesné transitive verze jsou uzamčené v lockfilu.

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
