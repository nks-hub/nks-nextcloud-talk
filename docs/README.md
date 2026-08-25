# Dokumentace

Dokumentace je rozdělená podle stavu poznání:

- [Výzkum](research/README.md) obsahuje ověřená upstream a runtime fakta.
- [Architektura](architecture/README.md) obsahuje návrh systému, požadavky,
  synchronizační invarianty a implementační brány.
- [Návrhy](plans/README.md) rozpracovávají doporučené nebo přijaté provozní
  toky a jejich hranice.
- [Audit dokončení](architecture/completion-audit.md) odděluje spustitelný
  Flutter základ od stále nedokončené produktové parity.
- [Stav vývoje k 25. srpnu 2026](architecture/development-status-2026-08-25.md)
  je aktuální funkční matice, Android how-to, push topologie a prioritní fronta.
  Snapshot odděluje 354 úspěšných Flutter testů a jeden credential-gated skip,
  569/569 testů `talk_protocol`, Android push unit 16/16 a emulator connected
  15/15, skutečné live důkazy a dosud neověřené řezy.
- [Flutter aplikační základ](architecture/flutter-foundation.md) popisuje
  implementovaný login, secure storage, Drift, adaptivní layout a runtime
  důkazy pro Android a Windows.
- [Push a FCM](research/push-fcm.md) popisuje přímý Android Notifications Web
  Push bez vlastní gateway a samostatnou APNs/PushKit hranici pro iOS.
- [Giphy integrace](research/giphy-integration.md) popisuje serverové
  search/trending, skrytou Talk wire reference a skutečný inline animovaný GIF.
  Wire URL se nesmí zobrazit jako zpráva a není attachment; jediným viditelným
  externím odkazem je GIPHY attribution v pickeru.
- [Historický push-v2 gateway kontrakt](architecture/push-gateway-api.md)
  zůstává spustitelným protokolovým důkazem, ale není zvolenou Android
  produktovou topologií.
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
