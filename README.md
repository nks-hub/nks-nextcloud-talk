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
- doporučená vlastní FCM gateway kompatibilní se standardní Notifications app;
- Flutter implementace ještě nezačala, protože se nejdřív uzavírá licence,
  produktový rozsah a architektura.

Přesný rozdíl mezi hotovou analýzou a chybějícím produktem vede
[audit dokončení](docs/architecture/completion-audit.md).

Dokumentace začíná v [docs/README.md](docs/README.md).
