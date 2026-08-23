# Architektura

Stav: návrh a produkční pure Dart bootstrap, conversation, chat, rich-chat i
attachment runtime. Protokolové kontrakty vznikly licenčně neutrálně; nový
mobilní klient je licencovaný pod `GPL-3.0-or-later`. Flutter scaffold dosud
nevznikl. Android `applicationId` je
přijaté jako
`com.nkshub.nextcloudtalk`; iOS bundle ID zůstává otevřené.

## Výsledek návrhu

Přijatá nejmenší úplná architektura má tři deployovatelné nebo samostatně
testovatelné části:

1. Flutter mobilní aplikaci.
2. Pure Dart Talk protokolový balík bez Flutter závislostí.
3. Samostatnou Notifications-compatible push gateway.

Uvnitř mobilní aplikace zůstávají storage, sync a feature moduly, dokud reálná
druhá implementace neodůvodní další package. Call subsystem má od začátku
hranice pro dva signaling transporty a dvě platformy, ale media implementace se
nevytváří jako prázdný stub.

## Dokumenty

- [Požadavky a důkaz dokončení](requirements.md)
- [Audit dokončení celého cíle](completion-audit.md)
- [Systémový návrh](system-design.md)
- [Synchronizace a lokální data](sync-storage.md)
- [OpenAPI a fixture push gateway](push-gateway-api.md)
- [OpenAPI a fixture klientského bootstrapu](client-bootstrap-api.md)
- [OpenAPI, fixture a merge kontrakt seznamu konverzací](conversation-list-api.md)
- [OpenAPI, merge a outbox kontrakt chat zpráv](chat-messages-api.md)
- [OpenAPI, renderer a stavový kontrakt rich chatu](rich-chat-api.md)
- [Talk OCS, WebDAV a stavový kontrakt příloh](attachment-upload-api.md)
- [Implementační řezy a testovací brány](delivery-plan.md)
- [Rozhodnutí a otevřené volby](decisions.md)
- [Audit závislostí a assetů](dependency-licenses.md)
- [Pure Dart talk_protocol](../../packages/talk_protocol/README.md)
- [Veřejný multi-server push](../plans/2026-08-22-public-multi-server-push-design.md)
- [Vlastní Talk-inspirovaný Flutter klient](../plans/2026-08-22-original-flutter-client-design.md)
- [Návrh klientského bootstrap kontraktu](../plans/2026-08-22-client-bootstrap-contract-design.md)
- [Návrh conversation-list kontraktu](../plans/2026-08-22-conversation-list-contract-design.md)
- [Implementace Dart conversation runtime](../plans/2026-08-22-dart-conversation-runtime-design.md)
- [Návrh chat-messages kontraktu](../plans/2026-08-22-chat-messages-contract-design.md)
- [Implementace Dart chat runtime](../plans/2026-08-23-dart-chat-runtime-design.md)
- [Rich chat a vlákna](../plans/2026-08-23-rich-chat-threads-design.md)
- [Implementace attachment upload runtime](../plans/2026-08-23-attachment-upload-runtime-design.md)

## Principy

- Capability-first místo verzí zakódovaných v klientu.
- Account scope na každé datové a background hranici.
- Jeden autoritativní merge tok pro HTTP, HPB, push i outbox.
- Stabilní referenceId jako korelace; Talk server jej nevynucuje jako
  idempotency key.
- OCS a databázové transakce určují úspěch, ne optimistický UI stav.
- Push přenáší opaque šifrované probuzení, ne zdroj pravdy.
- Platformní lifecycle zůstává v Kotlin/Swift vrstvě.
- Každý vertikální řez končí reálným během, ne pouze buildem nebo mockem.
