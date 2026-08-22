# Architektura

Stav: návrh před implementací. Dokument je licenčně neutrální a nevytváří
Flutter scaffold ani package identity.

## Výsledek návrhu

Doporučená nejmenší úplná architektura má tři deployovatelné nebo samostatně
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
- [Implementační řezy a testovací brány](delivery-plan.md)
- [Rozhodnutí a otevřené volby](decisions.md)
- [Veřejný multi-server push](../plans/2026-08-22-public-multi-server-push-design.md)
- [Vlastní Talk-inspirovaný Flutter klient](../plans/2026-08-22-original-flutter-client-design.md)

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
