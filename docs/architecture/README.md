# Architektura

Stav: spustitelný Flutter základ a produkční pure Dart bootstrap, conversation,
chat, rich-chat, attachment, signaling preparation i historický push-v2
runtime. Klient je licencovaný pod `GPL-3.0-or-later` a používá identitu
`com.nkshub.nextcloudtalk` na Androidu, iOS a macOS. Jedna Flutter codebase cílí
také na Windows a Linux. Platformní runnery uzavírá commit `cf13cce`; jejich
existence sama neprokazuje podepsaný build ani live lifecycle všech platforem.

Čerstvá automatizovaná brána má `flutter analyze` bez nálezu, 354 úspěšných
Flutter testů s jedním credential-gated live skipem a 569/569 testů
`talk_protocol` po opravě `d0660cc`. Android push v `3c74165` navíc prošel 16/16
Kotlin unit a 15/15 connected testy na `chatujmePixel`. Přesné rozlišení kódu,
automatizace, live důkazů a otevřených částí vede
[aktuální stav vývoje](development-status-2026-08-25.md).

## Výsledek návrhu

Přijatá nejmenší úplná architektura má dvě povinné samostatně testovatelné
části:

1. Flutter aplikaci pro mobil i desktop.
2. Pure Dart Talk protokolový balík bez Flutter závislostí.

Výchozí transport na Androidu i na Apple platformách je podle D-038 vlastní
proxy `nks-talk-notify`, která drží odesílací větev na FCM v1 a na APNs.
Notifications Web Push přes UnifiedPush connector a vestavěný FCM distributor
zůstává na Androidu jako přepínatelná záloha; jen ta se obejde bez vlastní
gateway. Nextcloud addon není v žádné z obou větví součástí instalace.

Nextcloud → proxy → FCM/APNs → ukončená aplikace je od 28. srpna 2026 živě
prokázané na Androidu i na iOS nad `140b0a9`, včetně dešifrovaného obsahu,
akcí notifikace a delete payloadů. Otevřenou branou zůstává fyzické zařízení
a dva skutečné servery současně.

Uvnitř mobilní aplikace zůstávají storage, sync a feature moduly, dokud reálná
druhá implementace neodůvodní další package. Call subsystem má od začátku
hranice pro dva signaling transporty a dvě platformy, ale media implementace se
nevytváří jako prázdný stub.

## Dokumenty

- [Požadavky a důkaz dokončení](requirements.md)
- [Stav vývoje k 25. srpnu 2026](development-status-2026-08-25.md)
- [Audit dokončení celého cíle](completion-audit.md)
- [Systémový návrh](system-design.md)
- [Synchronizace a lokální data](sync-storage.md)
- [Flutter aplikační základ](flutter-foundation.md)
- [Historický OpenAPI a klientský push-v2 runtime](push-gateway-api.md)
- [OpenAPI a fixture klientského bootstrapu](client-bootstrap-api.md)
- [OpenAPI, fixture a merge kontrakt seznamu konverzací](conversation-list-api.md)
- [OpenAPI, merge a outbox kontrakt chat zpráv](chat-messages-api.md)
- [OpenAPI, renderer a stavový kontrakt rich chatu](rich-chat-api.md)
- [Talk OCS, WebDAV a stavový kontrakt příloh](attachment-upload-api.md)
- [Internal/HPB signaling kontrakt a runtime](signaling-api.md)
- [Implementační řezy a testovací brány](delivery-plan.md)
- [Rozhodnutí a otevřené volby](decisions.md)
- [Technická rozhodnutí](decisions-technical.md)
- [Audit závislostí a assetů](dependency-licenses.md)
- [Pure Dart talk_protocol](../../packages/talk_protocol/README.md)
- [Historický veřejný multi-server push-v2 návrh](../plans/2026-08-22-public-multi-server-push-design.md)
- [Vlastní Talk-inspirovaný Flutter klient](../plans/2026-08-22-original-flutter-client-design.md)
- [Návrh klientského bootstrap kontraktu](../plans/2026-08-22-client-bootstrap-contract-design.md)
- [Návrh conversation-list kontraktu](../plans/2026-08-22-conversation-list-contract-design.md)
- [Implementace Dart conversation runtime](../plans/2026-08-22-dart-conversation-runtime-design.md)
- [Návrh chat-messages kontraktu](../plans/2026-08-22-chat-messages-contract-design.md)
- [Implementace Dart chat runtime](../plans/2026-08-23-dart-chat-runtime-design.md)
- [Rich chat a vlákna](../plans/2026-08-23-rich-chat-threads-design.md)
- [Implementace attachment upload runtime](../plans/2026-08-23-attachment-upload-runtime-design.md)
- [Návrh signaling preparation runtime](../plans/2026-08-23-signaling-preparation-runtime-design.md)
- [Historický Dart push-v2 client runtime](../plans/2026-08-23-dart-push-client-runtime-design.md)

## Principy

- Capability-first místo verzí zakódovaných v klientu.
- Account scope na každé datové a background hranici.
- Jeden autoritativní merge tok pro HTTP, HPB, push i outbox.
- Stabilní referenceId jako korelace; Talk server jej nevynucuje jako
  idempotency key.
- OCS a databázové transakce určují úspěch, ne optimistický UI stav.
- Push přenáší opaque šifrované probuzení, ne zdroj pravdy.
- Platformní lifecycle zůstává v Kotlin/Swift nebo desktop runner vrstvě.
- Rozložení se adaptuje podle okna; desktop není samostatný klient ani
  roztažená telefonní obrazovka.
- Každý vertikální řez končí reálným během, ne pouze buildem nebo mockem.
