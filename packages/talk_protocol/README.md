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
- oddělené active, re-auth, deferred a unsupported výsledky profile probe;
- capability-first chat history, future, long poll, text send, reply,
  read a mark-unread requesty svázané s účtem, originem, room a thread scope;
- bounded UTF-8/JSON parser, hluboce neměnné message modely, desetinné cursory
  bez omezeného integer převodu a redigovanou diagnostiku;
- atomický single-use chat merge plán, ChatBlock konvergenci a text-send outbox
  s per-room FIFO/single-flight, restartem a ambiguous-send reconciliation.

Balík načítá přímo všechny fixtures z `contracts/client-bootstrap` a
`contracts/conversation-list` i `contracts/chat-messages`. Aktuálně prochází
`dart analyze --fatal-infos` bez nálezu a 280 Dart testů včetně skutečného
release AOT executable. Planner připravuje úplný candidate account snapshot;
skutečnou SQLite transakci, síťový transport a background scheduler bude
vlastnit budoucí Flutter/Drift vrstva.

Balík je součástí projektu licencovaného pod `GPL-3.0-or-later`; kanonický text
je v kořenovém souboru `LICENSE`.
