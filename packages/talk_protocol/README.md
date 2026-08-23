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
- capability-bound mentions, threads, reactions, edit/delete, pin, reminder a
  scheduled-message requesty pro 21 rich-chat operací;
- bounded immutable rich-chat response parser a account-scoped single-use plán
  pro messages, thread first/last, room preview, reactions, reminders a schedule;
- GFM a Rich Object String renderer do bezpečného semantic tree bez
  vykonatelného raw HTML nebo nebezpečných aktivních odkazů;
- capability-bound attachment probe a finalize requesty se stabilním
  `referenceId`, pevným `allowUpdate: false` a typovaným file/voice kontraktem;
- normální WebDAV PUT i resumable chunked MKCOL/PROPFIND/PUT/MOVE s přesnými
  délkami, bezpečnými relativními cestami a bounded DAV XML parserem;
- neměnný account-scoped attachment runtime s kontrolou zdroje, FIFO
  finalizací, re-auth, cancel/cleanup a bez slepého opakování nejasného finalize.
- internal OCS long poll a bounded batch plány s přesnou klasifikací
  200/400/401/404/409 a ochranou před replayem možná odeslaného body;
- external HPB settings, TLS endpoint trust, welcome, full hello 1.0/2.0,
  30sekundový resume, room join, reconnect/backoff a session loss;
- account/connection/room-scoped signaling runtime, participant/federation
  snapshot, MCU/no-MCU topologie a explicitní zákaz fake media admission.
- jeden provider-token handle pro více účtů, per-account RSA key handle,
  deterministickou single-flight registraci, přesný retry, 409 recovery a
  capability/logout cleanup se zachováním bezpečného pořadí revokace;
- ephemeral push routing svázaný s ciphertextem, signature, account/key/token
  generací, aktuálním runtime snapshotem a právě jedním validním OAEP nebo
  PKCS#1 v1.5 decrypt výsledkem.

Balík načítá přímo všechny fixtures z `contracts/client-bootstrap` a
`contracts/conversation-list`, `contracts/chat-messages` i
`contracts/rich-chat` a implementuje stejný attachment kontrakt jako
`contracts/attachment-upload` a stejný settings/server-frame kontrakt jako
`contracts/signaling`. Push contract test navíc načítá všech 8 fixtures přímo z
`contracts/push-client`. Aktuálně prochází `dart analyze --fatal-infos` bez
nálezu a 527 Dart testů včetně skutečných release AOT executable a signaling
loopback HTTP/WebSocket testů. Planner připravuje úplný candidate account
snapshot; skutečnou SQLite transakci, platformní síťový a crypto transport a
background scheduler bude vlastnit budoucí Flutter/Drift vrstva.

Balík je součástí projektu licencovaného pod `GPL-3.0-or-later`; kanonický text
je v kořenovém souboru `LICENSE`.
