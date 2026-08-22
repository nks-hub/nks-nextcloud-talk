# Dokumentace

Dokumentace je rozdělená podle stavu poznání:

- [Výzkum](research/README.md) obsahuje ověřená upstream a runtime fakta.
- [Architektura](architecture/README.md) obsahuje návrh systému, požadavky,
  synchronizační invarianty a implementační brány.
- [Návrhy](plans/README.md) rozpracovávají doporučené nebo přijaté provozní
  toky a jejich hranice.
- [Audit dokončení](architecture/completion-audit.md) odděluje doloženou
  analýzu od dosud neexistující aplikace, gateway a runtime důkazů.
- [Push gateway API](architecture/push-gateway-api.md) váže skutečný
  Notifications wire formát na OpenAPI, kryptografické fixture a spustitelnou
  validaci.
- [Vlastní Flutter klient](plans/2026-08-22-original-flutter-client-design.md)
  vymezuje Talk-inspirovaný vzhled, zlepšení a clean-room hranici.

Výzkumné tvrzení musí být vázané na konkrétní SHA, verzi nebo skutečný runtime
test. Architektonický návrh musí jasně rozlišovat přijaté rozhodnutí, doporučení
a dosud otevřenou volbu.
