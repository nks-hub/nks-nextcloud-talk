# NKS Nextcloud Talk

Výzkumný a implementační repozitář pro nový Flutter klient kompatibilní s
Nextcloud Talk.

Produktové zadání je obecný multi-server klient pro Android a iOS.
Referenční Nextcloud instalace slouží pouze k ověřování kompatibility; nesmí se
promítnout do pevně zakódovaných URL, účtů ani capability předpokladů.

Aktuální stav:

- dokončený zdrojový audit oficiálních Android a iOS klientů;
- úplný katalog funkčních skupin, parity rozdílů a cílových důkazů;
- zmapované Talk/OCS, WebDAV, signaling a push protokoly;
- ověřený baseline referenčního Nextcloud 34 / Talk 24 serveru;
- spustitelný OpenAPI a fixture kontrakt pro status, Login Flow v2,
  capabilities a bezpečnou multi-server normalizaci;
- první produkční pure Dart implementace stejného bootstrap kontraktu v
  [`packages/talk_protocol`](packages/talk_protocol), ověřená všemi 20 wire
  fixtures a 22 origin případy;
- spustitelný room v4 kontrakt pro full/delta seznam, serverový cursor a
  account-scoped transakční merge;
- produkční pure Dart conversation runtime se striktním response parserem,
  capability probe, neměnnými room modely a account-scoped merge plannerem;
- spustitelný chat kontrakt pro history/future cursory, text send, read/unread,
  room/thread merge a restart-safe outbox bez blind replaye;
- produkční pure Dart chat runtime s bounded immutable parserem, account-scoped
  atomickým merge plánem a durable text-send outbox lifecycle;
- spustitelný attachment kontrakt pro Talk OCS probe/finalize, WebDAV normal a
  chunk upload, XML multistatus a autoritativní chat confirmation;
- produkční pure Dart attachment runtime s durable zdrojem, restart-safe
  resume, room FIFO/single-flight a bezpečným ambiguous-finalize stavem;
- spustitelný signaling kontrakt pro settings/internal HTTP, HPB frames,
  hello/resume/room, federation a session epochy;
- produkční pure Dart signaling preparation runtime ověřený skutečným lokálním
  HTTP/WebSocket během a release AOT bez fake WebRTC médií;
- doporučená vlastní FCM gateway kompatibilní se standardní Notifications app;
- přijatý směr vlastní clean-room Flutter implementace s Talk-inspirovanou
  vizuální variací;
- přijaté Android `applicationId` `com.nkshub.nextcloudtalk`;
- přijatá licence mobilního klienta
  [`GPL-3.0-or-later`](LICENSE);
- Flutter mobilní scaffold ještě nezačal, protože zbývá schválit iOS bundle ID
  a minimální platformy. Platformně nezávislý bootstrap, conversation, chat,
  attachment a signaling preparation runtime už jsou implementované a
  testované.

Přesný rozdíl mezi hotovou analýzou a chybějícím produktem vede
[audit dokončení](docs/architecture/completion-audit.md).

Dokumentace začíná v [docs/README.md](docs/README.md).
