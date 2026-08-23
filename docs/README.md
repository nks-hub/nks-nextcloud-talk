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
- [Přidání Nextcloud účtu](architecture/client-bootstrap-api.md) popisuje
  normalizaci serveru, Login Flow v2, capabilities, spustitelné trust fixture a
  první pure Dart implementaci.
- [Seznam konverzací](architecture/conversation-list-api.md) popisuje room v4,
  serverový cursor, account-scoped merge a spustitelné full/delta fixture.
- [Chat zprávy](architecture/chat-messages-api.md) popisují history/future
  cursory, text send, reply, read/unread a executable durable outbox.
- [Rich chat a vlákna](architecture/rich-chat-api.md) popisují mentions,
  reactions, edit/delete, pin, reminders, schedule, bezpečný renderer a
  account-scoped transakční stav.
- [Upload příloh a voice zpráv](architecture/attachment-upload-api.md) popisuje
  Talk OCS, WebDAV normal/chunk upload, bezpečný resume a chat confirmation.
- [Signaling preparation](architecture/signaling-api.md) popisuje internal OCS,
  HPB WebSocket hello/resume/room, session epochy a reálné loopback testy bez
  předstíraných WebRTC médií.
- [Vlastní Flutter klient](plans/2026-08-22-original-flutter-client-design.md)
  vymezuje Talk-inspirovaný vzhled, zlepšení a clean-room hranici.
- [Audit závislostí a assetů](architecture/dependency-licenses.md) průběžně
  eviduje původ, licenci a distribuční podmínky každé přidané závislosti.

Výzkumné tvrzení musí být vázané na konkrétní SHA, verzi nebo skutečný runtime
test. Architektonický návrh musí jasně rozlišovat přijaté rozhodnutí, doporučení
a dosud otevřenou volbu.
