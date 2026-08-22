# talk_protocol

Pure Dart typy a validační logika pro veřejné Nextcloud a Talk wire kontrakty.
Balík neprovádí síťové požadavky ani neukládá credentials. HTTP transport,
secure storage a account-scoped persistence vlastní mobilní aplikace.

Implementované řezy pokrývají:

- kanonizaci a trust validaci Nextcloud server originu;
- endpointy `status.php`, Login Flow v2 a OCS capabilities;
- bezpečnou klasifikaci server statusu a Login Flow poll odpovědi;
- typovaný capability snapshot bez ztráty neznámých namespaces;
- stejné fixture kontrakty jako `contracts/client-bootstrap`;
- přesný full/incremental conversation v4 request builder svázaný s účtem,
  request ID a serverovým originem;
- klasifikaci success, re-auth, OCS failure a HTTP 426/429/503;
- striktní cursor/hash hlavičky, typované neměnné room a preview modely;
- aktivaci cursor-v4 profilu až po validním full probe;
- čistý account-scoped merge plán s kontrolou originu a dvoufázovým full-empty
  potvrzením;
- oddělené active, re-auth, deferred a unsupported výsledky profile probe.

Balík načítá přímo všechny fixtures z `contracts/client-bootstrap` a
`contracts/conversation-list`. Aktuálně prochází `dart analyze` bez nálezu a
125 Dart testů. Planner pouze připravuje atomické upserty, mazání a nový
account stav; skutečnou transakci bude vlastnit budoucí Drift adapter.

Balík je součástí projektu licencovaného pod `GPL-3.0-or-later`; kanonický text
je v kořenovém souboru `LICENSE`.
