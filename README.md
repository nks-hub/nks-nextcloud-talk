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
- spustitelný room v4 kontrakt pro full/delta seznam, serverový cursor a
  account-scoped transakční merge;
- spustitelný chat kontrakt pro history/future cursory, text send, read/unread,
  room/thread merge a restart-safe outbox bez blind replaye;
- doporučená vlastní FCM gateway kompatibilní se standardní Notifications app;
- přijatý směr vlastní clean-room Flutter implementace s Talk-inspirovanou
  vizuální variací;
- přijaté Android `applicationId` `com.nkshub.nextcloudtalk`;
- přijatá licence mobilního klienta
  [`GPL-3.0-or-later`](LICENSE);
- Flutter implementace ještě nezačala, protože zbývá schválit iOS bundle ID,
  minimální platformy a rozsah prvního release.

Přesný rozdíl mezi hotovou analýzou a chybějícím produktem vede
[audit dokončení](docs/architecture/completion-audit.md).

Dokumentace začíná v [docs/README.md](docs/README.md).
