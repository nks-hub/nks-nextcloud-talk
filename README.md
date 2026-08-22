# NKS Nextcloud Talk

Výzkumný a implementační repozitář pro nový Flutter klient kompatibilní s
Nextcloud Talk.

Produktové zadání je obecný multi-server klient pro Android a iOS.
Referenční Nextcloud instalace slouží pouze k ověřování kompatibility; nesmí se
promítnout do pevně zakódovaných URL, účtů ani capability předpokladů.

Aktuální stav:

- dokončený zdrojový audit oficiálních Android a iOS klientů;
- zmapované Talk/OCS, WebDAV, signaling a push protokoly;
- ověřený baseline referenčního Nextcloud 34 / Talk 24 serveru;
- doporučená vlastní FCM gateway kompatibilní se standardní Notifications app;
- Flutter implementace ještě nezačala, protože se nejdřív uzavírá licence,
  produktový rozsah a architektura.

Výzkumné podklady jsou v [docs/research/README.md](docs/research/README.md).
