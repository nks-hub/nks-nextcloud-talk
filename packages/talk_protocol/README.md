# talk_protocol

Pure Dart typy a validační logika pro veřejné Nextcloud a Talk wire kontrakty.
Balík neprovádí síťové požadavky ani neukládá credentials. HTTP transport,
secure storage a account-scoped persistence vlastní mobilní aplikace.

První implementovaný řez pokrývá:

- kanonizaci a trust validaci Nextcloud server originu;
- endpointy `status.php`, Login Flow v2 a OCS capabilities;
- bezpečnou klasifikaci server statusu a Login Flow poll odpovědi;
- typovaný capability snapshot bez ztráty neznámých namespaces;
- stejné fixture kontrakty jako `contracts/client-bootstrap`.

Balík je součástí projektu licencovaného pod `GPL-3.0-or-later`; kanonický text
je v kořenovém souboru `LICENSE`.
