from __future__ import annotations

import json
import re
import sys
from copy import deepcopy
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit, urlunsplit

from jsonschema import Draft202012Validator, FormatChecker
from openapi_spec_validator import validate


CONTRACT_ROOT = Path(__file__).resolve().parent
FIXTURE_ROOT = CONTRACT_ROOT / "fixtures"
MANIFEST_PATH = FIXTURE_ROOT / "manifest.json"
EXPECTED_TALK_SHA = "f2958bb25be6604240c58a3faf9a2033a30d20e5"
EXPECTED_HPB_SHA = "e007e2ed972c7322b53926d7da24a2b3faeaeccb"
EXPECTED_OPERATIONS = {
    "getSignalingSettingsV3": ("get", "/signaling/settings"),
    "pullInternalSignalingV3": ("get", "/signaling/{token}"),
    "sendInternalSignalingV3": ("post", "/signaling/{token}"),
}
MAX_JSON_BYTES = 2 * 1024 * 1024
MAX_WIRE_BYTES = 1024 * 1024
MAX_JSON_DEPTH = 64
MAX_JSON_NODES = 20_000
MAX_STRING_LENGTH = 65_536
MAX_FEATURES = 256
MAX_PARTICIPANTS = 4096
MAX_BATCH_MESSAGES = 64
CONVERSATION_TOKEN = re.compile(r"^[a-z0-9]{4,30}$")
SAFE_IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._@+-]{0,511}$")
SAFE_WIRE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:+/-]{0,127}$")
CONTROL = re.compile(r"[\x00-\x1f\x7f]")
SHA = re.compile(r"^[0-9a-f]{40}$")
SECRET_FIELDS = {"ticket", "credential"}
RUNTIME_FIELDS = (
    "mode",
    "phase",
    "connectionEpoch",
    "roomEpoch",
    "hasSession",
    "hasResume",
    "resumeValid",
    "roomConfirmed",
    "localPeers",
    "federatedPeers",
    "allInCall",
    "federationInterrupted",
    "renegotiationRequired",
    "pending",
    "outcome",
)


class ContractValidationError(RuntimeError):
    pass


def _duplicate_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ContractValidationError("JSON object contains a duplicate member")
        result[key] = value
    return result


def _validate_json_budget(value: Any) -> None:
    stack: list[tuple[Any, int]] = [(value, 1)]
    nodes = 0
    while stack:
        current, depth = stack.pop()
        nodes += 1
        if nodes > MAX_JSON_NODES:
            raise ContractValidationError("JSON node budget exceeded")
        if depth > MAX_JSON_DEPTH:
            raise ContractValidationError("JSON depth budget exceeded")
        if isinstance(current, str):
            if len(current) > MAX_STRING_LENGTH:
                raise ContractValidationError("JSON string budget exceeded")
        elif isinstance(current, dict):
            for key, child in current.items():
                if not isinstance(key, str) or len(key) > 256:
                    raise ContractValidationError("JSON member-name budget exceeded")
                stack.append((child, depth + 1))
        elif isinstance(current, list):
            stack.extend((child, depth + 1) for child in current)
        elif current is not None and not isinstance(current, (bool, int, float)):
            raise ContractValidationError("JSON contains an unsupported value")


def decode_json_bytes(raw: bytes, label: str = "JSON") -> Any:
    if len(raw) > MAX_JSON_BYTES:
        raise ContractValidationError(f"{label} byte budget exceeded")
    try:
        text = raw.decode("utf-8", errors="strict")
        value = json.loads(text, object_pairs_hook=_duplicate_object)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ContractValidationError(
            f"{label} is not valid strict UTF-8 JSON"
        ) from error
    _validate_json_budget(value)
    return value


def load_json(path: Path) -> Any:
    return decode_json_bytes(path.read_bytes(), path.name)


def require_object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ContractValidationError(f"{label} must be an object")
    return value


def require_list(value: Any, label: str) -> list[Any]:
    if not isinstance(value, list):
        raise ContractValidationError(f"{label} must be an array")
    return value


def require_string(
    value: Any,
    label: str,
    *,
    minimum: int = 1,
    maximum: int = 4096,
    allow_empty: bool = False,
) -> str:
    if not isinstance(value, str):
        raise ContractValidationError(f"{label} must be a string")
    if (not allow_empty and len(value) < minimum) or len(value) > maximum:
        raise ContractValidationError(f"{label} is outside its string budget")
    if CONTROL.search(value):
        raise ContractValidationError(f"{label} contains a control character")
    return value


def require_integer(
    value: Any,
    label: str,
    *,
    minimum: int = 0,
) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise ContractValidationError(f"{label} must be an integer >= {minimum}")
    return value


def require_boolean(value: Any, label: str) -> bool:
    if not isinstance(value, bool):
        raise ContractValidationError(f"{label} must be boolean")
    return value


def require_unique_cases(
    raw_cases: Any,
    expected_count: int,
    label: str,
) -> list[dict[str, Any]]:
    cases = [require_object(case, label) for case in require_list(raw_cases, label)]
    ids = [require_string(case.get("id"), f"{label} id", maximum=128) for case in cases]
    if len(ids) != len(set(ids)):
        raise ContractValidationError(f"{label} ids must be unique")
    if len(cases) != expected_count:
        raise ContractValidationError(
            f"{label} count mismatch: expected {expected_count}, got {len(cases)}"
        )
    return cases


def _resolve_pointer(document: dict[str, Any], reference: str) -> Any:
    if not reference.startswith("#/"):
        raise ContractValidationError("Only local OpenAPI references are allowed")
    current: Any = document
    for encoded in reference[2:].split("/"):
        member = encoded.replace("~1", "/").replace("~0", "~")
        current = require_object(current, "OpenAPI reference target").get(member)
        if current is None:
            raise ContractValidationError("OpenAPI reference does not resolve")
    return current


def expand_references(
    value: Any,
    document: dict[str, Any],
    active: frozenset[str] = frozenset(),
) -> Any:
    if isinstance(value, dict):
        if "$ref" in value:
            reference = require_string(value["$ref"], "OpenAPI reference")
            if reference in active:
                raise ContractValidationError(
                    "Recursive OpenAPI reference is unsupported"
                )
            target = require_object(
                expand_references(
                    deepcopy(_resolve_pointer(document, reference)),
                    document,
                    active | {reference},
                ),
                "OpenAPI reference target",
            )
            for key, sibling in value.items():
                if key != "$ref":
                    target[key] = expand_references(sibling, document, active)
            return target
        return {
            key: expand_references(child, document, active)
            for key, child in value.items()
        }
    if isinstance(value, list):
        return [expand_references(child, document, active) for child in value]
    return value


def _find_operation(
    document: dict[str, Any],
    operation_id: str,
) -> tuple[str, str, dict[str, Any]]:
    for path, raw_item in require_object(document.get("paths"), "paths").items():
        item = require_object(raw_item, "path item")
        for method, raw_operation in item.items():
            if method not in {"get", "post", "put", "patch", "delete"}:
                continue
            operation = require_object(raw_operation, "operation")
            if operation.get("operationId") == operation_id:
                return path, method, operation
    raise ContractValidationError(f"Unknown operationId {operation_id}")


def _response_schema(
    document: dict[str, Any],
    operation: dict[str, Any],
    status: int,
) -> dict[str, Any]:
    response = require_object(
        expand_references(
            require_object(operation.get("responses"), "responses").get(str(status)),
            document,
        ),
        "response",
    )
    try:
        schema = response["content"]["application/json"]["schema"]
    except KeyError as error:
        raise ContractValidationError("Response lacks application/json") from error
    return require_object(expand_references(schema, document), "response schema")


def _request_schema(
    document: dict[str, Any],
    operation: dict[str, Any],
) -> dict[str, Any]:
    try:
        schema = operation["requestBody"]["content"][
            "application/x-www-form-urlencoded"
        ]["schema"]
    except KeyError as error:
        raise ContractValidationError(
            "Operation lacks its form request schema"
        ) from error
    return require_object(expand_references(schema, document), "request schema")


def _schema_errors(instance: Any, schema: dict[str, Any]) -> list[str]:
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    return [
        f"{'.'.join(str(member) for member in error.absolute_path)} [{error.validator}]"
        for error in sorted(
            validator.iter_errors(instance),
            key=lambda item: tuple(str(member) for member in item.absolute_path),
        )
    ]


def _normalize_tls_uri(
    value: Any,
    label: str,
    *,
    schemes: set[str],
) -> tuple[str, str, str]:
    raw = require_string(value, label, maximum=4096)
    if raw.strip() != raw or "\\" in raw:
        raise ContractValidationError(f"{label} is ambiguous")
    parsed = urlsplit(raw)
    if (
        parsed.scheme.lower() not in schemes
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or not parsed.hostname
    ):
        suffix = "scheme" if parsed.scheme.lower() not in schemes else "query"
        raise ContractValidationError(f"{label}.{suffix} is not trusted")
    try:
        port = parsed.port
    except ValueError as error:
        raise ContractValidationError(f"{label}.port is invalid") from error
    host = parsed.hostname.lower()
    if CONTROL.search(host) or "%" in host:
        raise ContractValidationError(f"{label}.host is invalid")
    if ":" in host:
        host = f"[{host}]"
    default_ports = {"https": 443, "wss": 443}
    scheme = parsed.scheme.lower()
    authority = host if port in {None, default_ports[scheme]} else f"{host}:{port}"
    path = parsed.path.rstrip("/")
    if path:
        segments = path.split("/")[1:]
        if any(segment in {"", ".", ".."} or "%" in segment for segment in segments):
            raise ContractValidationError(f"{label}.path is ambiguous")
    return scheme, authority, path


def normalize_nextcloud_server(value: Any, label: str = "nextcloudServer") -> str:
    _, authority, path = _normalize_tls_uri(value, label, schemes={"https"})
    return urlunsplit(("https", authority, path, "", ""))


def normalize_hpb_endpoint(value: Any, label: str = "server") -> str:
    scheme, authority, path = _normalize_tls_uri(
        value,
        label,
        schemes={"https", "wss"},
    )
    del scheme
    socket_path = path if path.endswith("/spreed") else f"{path}/spreed"
    return urlunsplit(("wss", authority, socket_path, "", ""))


def _require_synthetic_secret(value: Any, label: str, maximum: int) -> str:
    secret = require_string(value, label, maximum=maximum)
    if not secret.startswith("synthetic-"):
        raise ContractValidationError(f"{label} must be an explicit synthetic fixture")
    return secret


def _validate_feature_list(value: Any, label: str) -> list[str]:
    features = require_list(value, label)
    if len(features) > MAX_FEATURES:
        raise ContractValidationError(f"{label} exceeds its count budget")
    parsed = [
        require_string(feature, f"{label} feature", maximum=128) for feature in features
    ]
    if len(parsed) != len(set(parsed)) or any(
        SAFE_WIRE_NAME.fullmatch(feature) is None for feature in parsed
    ):
        raise ContractValidationError(f"{label} must contain unique safe names")
    return parsed


def _validate_ice_servers(value: Any, label: str, *, turn: bool) -> None:
    servers = require_list(value, label)
    if len(servers) > 32:
        raise ContractValidationError(f"{label} exceeds its count budget")
    for index, raw_server in enumerate(servers):
        server = require_object(raw_server, f"{label}[{index}]")
        urls = require_list(server.get("urls"), f"{label}[{index}].urls")
        if not 1 <= len(urls) <= 16:
            raise ContractValidationError(f"{label}[{index}].urls count is invalid")
        for url in urls:
            parsed = require_string(url, f"{label}[{index}].url", maximum=2048)
            allowed = ("turn:", "turns:") if turn else ("stun:", "stuns:")
            if not parsed.startswith(allowed):
                raise ContractValidationError(f"{label}[{index}].url scheme is invalid")
        if turn:
            require_string(
                server.get("username"),
                f"{label}[{index}].username",
                maximum=4096,
                allow_empty=True,
            )
            _require_synthetic_secret(
                server.get("credential"),
                f"{label}[{index}].credential",
                16384,
            )


def parse_settings(value: Any) -> dict[str, Any]:
    data = require_object(value, "settings")
    mode = require_string(data.get("signalingMode"), "signalingMode", maximum=16)
    require_string(
        data.get("userId"),
        "userId",
        maximum=4096,
        allow_empty=True,
    )
    require_boolean(data.get("hideWarning"), "hideWarning")
    require_string(
        data.get("sipDialinInfo"),
        "sipDialinInfo",
        maximum=16384,
        allow_empty=True,
    )
    _validate_ice_servers(data.get("stunservers"), "stunservers", turn=False)
    _validate_ice_servers(data.get("turnservers"), "turnservers", turn=True)
    federation = data.get("federation")
    federation_socket: str | None = None
    if federation is not None:
        raw_federation = require_object(federation, "federation")
        federation_socket = normalize_hpb_endpoint(
            raw_federation.get("server"),
            "federation.server",
        )
        normalize_nextcloud_server(
            raw_federation.get("nextcloudServer"),
            "federation.nextcloudServer",
        )
        room_id = require_string(
            raw_federation.get("roomId"),
            "federation.roomId",
            maximum=30,
        )
        if CONVERSATION_TOKEN.fullmatch(room_id) is None:
            raise ContractValidationError("federation.roomId has an invalid shape")
        federation_auth = require_object(
            raw_federation.get("helloAuthParams"),
            "federation.helloAuthParams",
        )
        _require_synthetic_secret(
            federation_auth.get("token"),
            "federation.helloAuthParams.token",
            32768,
        )

    if mode == "internal":
        require_string(
            data.get("server"),
            "server",
            maximum=4096,
            allow_empty=True,
        )
        return {
            "mode": mode,
            "federated": federation is not None,
            "helloVersions": [],
            **(
                {"federationSocket": federation_socket}
                if federation_socket is not None
                else {}
            ),
        }
    if mode != "external":
        raise ContractValidationError("signalingMode is unsupported")

    socket = normalize_hpb_endpoint(data.get("server"), "server")
    auth = require_object(data.get("helloAuthParams"), "helloAuthParams")
    versions: list[str] = []
    if "1.0" in auth:
        v1 = require_object(auth["1.0"], "helloAuthParams.1.0")
        require_string(
            v1.get("userid"),
            "helloAuthParams.1.0.userid",
            maximum=4096,
            allow_empty=True,
        )
        _require_synthetic_secret(
            v1.get("ticket"),
            "helloAuthParams.1.0.ticket",
            16384,
        )
        versions.append("1.0")
    if "2.0" in auth:
        v2 = require_object(auth["2.0"], "helloAuthParams.2.0")
        _require_synthetic_secret(
            v2.get("token"),
            "helloAuthParams.2.0.token",
            32768,
        )
        versions.append("2.0")
    if not versions:
        raise ContractValidationError("helloAuthParams has no supported authentication")
    return {
        "mode": mode,
        "socket": socket,
        "federated": federation is not None,
        "helloVersions": versions,
        **(
            {"federationSocket": federation_socket}
            if federation_socket is not None
            else {}
        ),
    }


def validate_settings_case(case: dict[str, Any]) -> None:
    expected_valid = require_boolean(case.get("valid"), "settings valid")
    try:
        actual = parse_settings(case.get("data"))
        if not expected_valid:
            raise ContractValidationError("Invalid settings case was accepted")
        expected = require_object(case.get("expected"), "settings expected")
        if actual != expected:
            raise ContractValidationError(
                f"settings expected summary mismatch for {case.get('id')}"
            )
    except ContractValidationError as error:
        if expected_valid:
            raise
        expected_error = require_string(case.get("error"), "settings error")
        if expected_error not in str(error):
            raise ContractValidationError(
                f"settings case {case.get('id')} failed for the wrong reason: {error}"
            ) from error


def _validate_request_id(value: Any, label: str = "frame.id") -> str:
    request_id = require_string(value, label, maximum=128)
    if SAFE_IDENTIFIER.fullmatch(request_id) is None:
        raise ContractValidationError(f"{label} has an unsafe shape")
    return request_id


def _validate_actor(value: Any, label: str) -> None:
    actor = require_object(value, label)
    actor_type = require_string(actor.get("type"), f"{label}.type", maximum=64)
    if SAFE_WIRE_NAME.fullmatch(actor_type) is None:
        raise ContractValidationError(f"{label}.type has an unsafe shape")
    peer = require_string(actor.get("sessionid"), f"{label}.sessionid", maximum=512)
    if SAFE_IDENTIFIER.fullmatch(peer) is None:
        raise ContractValidationError(f"{label}.sessionid has an unsafe shape")


def _validate_peer_message(value: Any, label: str) -> None:
    message = require_object(value, label)
    message_type = require_string(message.get("type"), f"{label}.type", maximum=128)
    if SAFE_WIRE_NAME.fullmatch(message_type) is None:
        raise ContractValidationError(f"{label}.type has an unsafe shape")
    if "roomType" in message:
        room_type = require_string(
            message["roomType"],
            f"{label}.roomType",
            maximum=64,
            allow_empty=True,
        )
        if room_type and SAFE_WIRE_NAME.fullmatch(room_type) is None:
            raise ContractValidationError(f"{label}.roomType has an unsafe shape")
    for member in ("to", "from"):
        if member in message:
            peer = require_string(message[member], f"{label}.{member}", maximum=512)
            if SAFE_IDENTIFIER.fullmatch(peer) is None:
                raise ContractValidationError(f"{label}.{member} has an unsafe shape")
    require_object(message.get("payload"), f"{label}.payload")


def _validate_client_hello(frame: dict[str, Any]) -> None:
    _validate_request_id(frame.get("id"))
    hello = require_object(frame.get("hello"), "hello")
    version = require_string(hello.get("version"), "hello.version", maximum=3)
    if version not in {"1.0", "2.0"}:
        raise ContractValidationError("hello.version is unsupported")
    if "resumeid" in hello:
        _validate_request_id(hello["resumeid"], "hello.resumeid")
        if "auth" in hello:
            raise ContractValidationError("resume hello must not contain auth")
        return
    _validate_feature_list(hello.get("features"), "hello.features")
    auth = require_object(hello.get("auth"), "hello.auth")
    backend = normalize_nextcloud_server(auth.get("url"), "hello.auth.url")
    if not backend.endswith("/ocs/v2.php/apps/spreed/api/v3/signaling/backend"):
        raise ContractValidationError("hello.auth.url is not the Talk backend endpoint")
    params = require_object(auth.get("params"), "hello.auth.params")
    if version == "1.0":
        require_string(
            params.get("userid"),
            "hello.auth.params.userid",
            maximum=4096,
            allow_empty=True,
        )
        _require_synthetic_secret(
            params.get("ticket"),
            "hello.auth.params.ticket",
            16384,
        )
    else:
        _require_synthetic_secret(
            params.get("token"),
            "hello.auth.params.token",
            32768,
        )


def _validate_client_room(frame: dict[str, Any]) -> None:
    _validate_request_id(frame.get("id"))
    room = require_object(frame.get("room"), "room")
    room_id = require_string(
        room.get("roomid"),
        "room.roomid",
        maximum=30,
        allow_empty=True,
    )
    if room_id == "":
        if set(room) != {"roomid"}:
            raise ContractValidationError("room leave contains unexpected state")
        return
    if CONVERSATION_TOKEN.fullmatch(room_id) is None:
        raise ContractValidationError("room.roomid has an invalid shape")
    session_id = require_string(room.get("sessionid"), "room.sessionid", maximum=512)
    if SAFE_IDENTIFIER.fullmatch(session_id) is None:
        raise ContractValidationError("room.sessionid has an invalid shape")
    if "federation" in room:
        federation = require_object(room["federation"], "room.federation")
        socket = normalize_hpb_endpoint(
            federation.get("signaling"),
            "room.federation.signaling",
        )
        if socket != federation.get("signaling"):
            raise ContractValidationError("room.federation.signaling is not canonical")
        normalize_nextcloud_server(federation.get("url"), "room.federation.url")
        remote = require_string(
            federation.get("roomid"),
            "room.federation.roomid",
            maximum=30,
        )
        if CONVERSATION_TOKEN.fullmatch(remote) is None:
            raise ContractValidationError("room.federation.roomid has an invalid shape")
        _require_synthetic_secret(
            federation.get("token"),
            "room.federation.token",
            32768,
        )


def _validate_client_frame(frame: dict[str, Any]) -> str:
    frame_type = require_string(frame.get("type"), "frame.type", maximum=64)
    if frame_type == "hello":
        _validate_client_hello(frame)
    elif frame_type == "room":
        _validate_client_room(frame)
    elif frame_type == "message":
        _validate_request_id(frame.get("id"))
        message = require_object(frame.get("message"), "message")
        _validate_actor(message.get("recipient"), "message.recipient")
        _validate_peer_message(message.get("data"), "message.data")
    elif frame_type == "control":
        _validate_request_id(frame.get("id"))
        control = require_object(frame.get("control"), "control")
        _validate_actor(control.get("recipient"), "control.recipient")
        require_object(control.get("data"), "control.data")
    elif frame_type == "bye":
        _validate_request_id(frame.get("id"))
        require_object(frame.get("bye"), "bye")
    else:
        raise ContractValidationError("Unknown client frame type")
    return frame_type


def _validate_hpb_participants(
    value: Any,
    label: str,
    *,
    update: bool,
) -> None:
    participants = require_list(value, label)
    if len(participants) > MAX_PARTICIPANTS:
        raise ContractValidationError(f"{label} exceeds its count budget")
    peers: list[str] = []
    for index, raw in enumerate(participants):
        participant = require_object(raw, f"{label}[{index}]")
        member = "sessionId" if update else "sessionid"
        peer = require_string(
            participant.get(member),
            f"{label}[{index}].{member}",
            maximum=512,
        )
        if SAFE_IDENTIFIER.fullmatch(peer) is None:
            raise ContractValidationError(f"{label}[{index}].{member} is unsafe")
        peers.append(peer)
        for integer_member in ("inCall", "participantPermissions"):
            if integer_member in participant:
                require_integer(
                    participant[integer_member],
                    f"{label}[{index}].{integer_member}",
                )
        if "federated" in participant:
            require_boolean(participant["federated"], f"{label}[{index}].federated")
        if "features" in participant:
            _validate_feature_list(
                participant["features"], f"{label}[{index}].features"
            )
    if len(peers) != len(set(peers)):
        raise ContractValidationError(f"{label} contains duplicate sessions")


def _validate_server_event(frame: dict[str, Any]) -> None:
    if "id" in frame:
        raise ContractValidationError("event frame must not have an id")
    event = require_object(frame.get("event"), "event")
    target = require_string(event.get("target"), "event.target", maximum=64)
    event_type = require_string(event.get("type"), "event.type", maximum=64)
    if target == "room" and event_type in {"join", "change"}:
        _validate_hpb_participants(
            event.get(event_type),
            f"event.{event_type}",
            update=False,
        )
    elif target == "room" and event_type == "leave":
        peers = require_list(event.get("leave"), "event.leave")
        parsed = [
            require_string(peer, "event.leave peer", maximum=512) for peer in peers
        ]
        if len(parsed) != len(set(parsed)):
            raise ContractValidationError("event.leave contains duplicate sessions")
    elif target == "participants" and event_type == "update":
        update = require_object(event.get("update"), "event.update")
        room_id = require_string(
            update.get("roomid"), "event.update.roomid", maximum=30
        )
        if CONVERSATION_TOKEN.fullmatch(room_id) is None:
            raise ContractValidationError("event.update.roomid is invalid")
        if "users" in update:
            _validate_hpb_participants(
                update["users"],
                "event.update.users",
                update=True,
            )
        else:
            if require_boolean(update.get("all"), "event.update.all") is not True:
                raise ContractValidationError("event.update.all must be true")
            require_integer(update.get("incall"), "event.update.incall")
    elif target == "room" and event_type == "federation_interrupted":
        return
    elif target == "room" and event_type == "federation_resumed":
        require_boolean(event.get("resumed"), "event.resumed")


def _validate_server_frame(frame: dict[str, Any]) -> str:
    frame_type = require_string(frame.get("type"), "frame.type", maximum=64)
    if frame_type == "welcome":
        if "id" in frame:
            raise ContractValidationError("welcome frame must not have an id")
        welcome = require_object(frame.get("welcome"), "welcome")
        _validate_feature_list(welcome.get("features"), "welcome.features")
    elif frame_type == "hello":
        _validate_request_id(frame.get("id"))
        hello = require_object(frame.get("hello"), "hello")
        version = require_string(hello.get("version"), "hello.version", maximum=3)
        if version not in {"1.0", "2.0"}:
            raise ContractValidationError("hello.version is unsupported")
        _validate_request_id(hello.get("sessionid"), "hello.sessionid")
        if "resumeid" in hello:
            _validate_request_id(hello["resumeid"], "hello.resumeid")
        if "server" in hello:
            server = require_object(hello["server"], "hello.server")
            _validate_feature_list(server.get("features"), "hello.server.features")
    elif frame_type == "room":
        if "id" in frame:
            _validate_request_id(frame["id"])
        room = require_object(frame.get("room"), "room")
        room_id = require_string(
            room.get("roomid"),
            "room.roomid",
            maximum=30,
            allow_empty=True,
        )
        if room_id and CONVERSATION_TOKEN.fullmatch(room_id) is None:
            raise ContractValidationError("room.roomid has an invalid shape")
        if "bandwidth" in room:
            bandwidth = require_object(room["bandwidth"], "room.bandwidth")
            require_integer(
                bandwidth.get("maxstreambitrate"),
                "room.bandwidth.maxstreambitrate",
            )
            require_integer(
                bandwidth.get("maxscreenbitrate"),
                "room.bandwidth.maxscreenbitrate",
            )
    elif frame_type == "error":
        _validate_request_id(frame.get("id"))
        error = require_object(frame.get("error"), "error")
        require_string(error.get("code"), "error.code", maximum=128)
        require_string(error.get("message"), "error.message", maximum=4096)
    elif frame_type == "event":
        _validate_server_event(frame)
    elif frame_type == "message":
        message = require_object(frame.get("message"), "message")
        _validate_actor(message.get("sender"), "message.sender")
        _validate_peer_message(message.get("data"), "message.data")
    elif frame_type == "control":
        control = require_object(frame.get("control"), "control")
        _validate_actor(control.get("sender"), "control.sender")
        require_object(control.get("data"), "control.data")
    elif frame_type == "bye":
        require_object(frame.get("bye"), "bye")
    else:
        return "unsupported"
    return frame_type


def validate_hpb_case(case: dict[str, Any]) -> None:
    expected_valid = require_boolean(case.get("valid"), "HPB valid")
    try:
        frame = require_object(case.get("frame"), "HPB frame")
        encoded = json.dumps(frame, ensure_ascii=False, separators=(",", ":"))
        if len(encoded.encode("utf-8")) > MAX_WIRE_BYTES:
            raise ContractValidationError("HPB frame byte budget exceeded")
        direction = require_string(case.get("direction"), "HPB direction", maximum=16)
        if direction == "client":
            actual_type = _validate_client_frame(frame)
        elif direction == "server":
            actual_type = _validate_server_frame(frame)
        else:
            raise ContractValidationError("HPB direction is unsupported")
        if not expected_valid:
            raise ContractValidationError("Invalid HPB case was accepted")
        expected_type = require_string(case.get("expectedType"), "expectedType")
        if actual_type != expected_type:
            raise ContractValidationError("HPB frame classification mismatch")
    except ContractValidationError as error:
        if expected_valid:
            raise
        expected_error = require_string(case.get("error"), "HPB error")
        if expected_error not in str(error):
            raise ContractValidationError(
                f"HPB case {case.get('id')} failed for the wrong reason: {error}"
            ) from error


def _validate_ocs_meta(response: dict[str, Any], status: int) -> Any:
    ocs = require_object(response.get("ocs"), "response.ocs")
    meta = require_object(ocs.get("meta"), "response.ocs.meta")
    meta_status = require_string(meta.get("status"), "response.ocs.meta.status")
    status_code = require_integer(
        meta.get("statuscode"), "response.ocs.meta.statuscode"
    )
    if status_code != status:
        raise ContractValidationError("OCS statuscode does not match HTTP status")
    if (status == 200 and meta_status != "ok") or (
        status != 200 and meta_status != "failure"
    ):
        raise ContractValidationError("OCS status does not match HTTP status")
    if "data" not in ocs:
        raise ContractValidationError("response.ocs.data is missing")
    return ocs["data"]


def _validate_internal_pull(data: Any) -> None:
    items = require_list(data, "internal pull data")
    if not items or len(items) > MAX_PARTICIPANTS + 1:
        raise ContractValidationError("internal pull item count is invalid")
    snapshot_count = 0
    for index, raw_item in enumerate(items):
        item = require_object(raw_item, f"internal pull data[{index}]")
        item_type = require_string(item.get("type"), "internal pull type", maximum=64)
        if item_type == "message":
            if snapshot_count:
                raise ContractValidationError("terminal usersInRoom must be final")
            encoded = require_string(
                item.get("data"),
                "internal message data",
                maximum=MAX_WIRE_BYTES,
            )
            try:
                message = json.loads(encoded, object_pairs_hook=_duplicate_object)
            except json.JSONDecodeError as error:
                raise ContractValidationError(
                    "internal message is invalid JSON"
                ) from error
            _validate_peer_message(message, "internal message")
        elif item_type == "usersInRoom":
            snapshot_count += 1
            if snapshot_count != 1 or index != len(items) - 1:
                raise ContractValidationError("terminal usersInRoom must be final")
            participants = require_list(item.get("data"), "usersInRoom data")
            if len(participants) > MAX_PARTICIPANTS:
                raise ContractValidationError("usersInRoom exceeds its count budget")
            peers: list[str] = []
            for participant_index, raw_participant in enumerate(participants):
                participant = require_object(
                    raw_participant,
                    f"usersInRoom[{participant_index}]",
                )
                peer = require_string(
                    participant.get("sessionId"),
                    "usersInRoom sessionId",
                    maximum=512,
                )
                peers.append(peer)
                require_integer(
                    participant.get("roomId"), "usersInRoom roomId", minimum=1
                )
                require_integer(participant.get("lastPing"), "usersInRoom lastPing")
                require_integer(participant.get("inCall"), "usersInRoom inCall")
                require_integer(
                    participant.get("participantPermissions"),
                    "usersInRoom participantPermissions",
                )
            if len(peers) != len(set(peers)):
                raise ContractValidationError("usersInRoom has duplicate sessions")
        else:
            raise ContractValidationError("internal pull contains an unknown item")
    if snapshot_count != 1:
        raise ContractValidationError("terminal usersInRoom is missing")


def _validate_batch_form(value: Any) -> None:
    form = require_object(value, "batch form")
    encoded = require_string(
        form.get("messages"), "batch form messages", maximum=MAX_WIRE_BYTES
    )
    try:
        messages = json.loads(encoded, object_pairs_hook=_duplicate_object)
    except json.JSONDecodeError as error:
        raise ContractValidationError("batch messages is invalid JSON") from error
    envelopes = require_list(messages, "batch messages")
    if not 1 <= len(envelopes) <= MAX_BATCH_MESSAGES:
        raise ContractValidationError("batch message count is invalid")
    for index, raw_envelope in enumerate(envelopes):
        envelope = require_object(raw_envelope, f"batch[{index}]")
        if envelope.get("ev") != "message":
            raise ContractValidationError("batch event is unsupported")
        session = require_string(
            envelope.get("sessionId"),
            f"batch[{index}].sessionId",
            maximum=512,
        )
        if SAFE_IDENTIFIER.fullmatch(session) is None:
            raise ContractValidationError("batch sessionId is unsafe")
        encoded_frame = require_string(
            envelope.get("fn"),
            f"batch[{index}].fn",
            maximum=MAX_WIRE_BYTES,
        )
        try:
            frame = json.loads(encoded_frame, object_pairs_hook=_duplicate_object)
        except json.JSONDecodeError as error:
            raise ContractValidationError("batch fn is invalid JSON") from error
        _validate_peer_message(frame, f"batch[{index}].fn")
        if "to" not in require_object(frame, "batch peer message"):
            raise ContractValidationError("batch peer message needs a recipient")


def _path_matches(template: str, actual: str) -> bool:
    pattern = re.escape(template).replace(re.escape("{token}"), r"[a-z0-9]{4,30}")
    return re.fullmatch(pattern, actual) is not None


def validate_http_case(document: dict[str, Any], case: dict[str, Any]) -> None:
    expected_valid = require_boolean(case.get("valid"), "HTTP valid")
    try:
        operation_id = require_string(case.get("operationId"), "operationId")
        template, method, operation = _find_operation(document, operation_id)
        request = require_object(case.get("request"), "HTTP request")
        if request.get("method") != method.upper():
            raise ContractValidationError("HTTP request method mismatch")
        path = require_string(request.get("path"), "HTTP request path")
        if not _path_matches(template, path):
            raise ContractValidationError("HTTP request path mismatch")
        query = require_object(request.get("query"), "HTTP query")
        if query.get("format") != "json":
            raise ContractValidationError("HTTP format query is missing")
        if operation_id == "getSignalingSettingsV3":
            token = require_string(query.get("token"), "HTTP token", maximum=30)
            if CONVERSATION_TOKEN.fullmatch(token) is None:
                raise ContractValidationError("HTTP token is invalid")
        headers = require_object(request.get("headers"), "HTTP headers")
        if headers.get("OCS-APIRequest") != "true":
            raise ContractValidationError("OCS-APIRequest header is missing")
        if method == "post":
            form = require_object(request.get("form"), "HTTP form")
            schema_errors = _schema_errors(form, _request_schema(document, operation))
            if schema_errors:
                raise ContractValidationError(
                    f"HTTP form schema failed: {schema_errors[0]}"
                )
            _validate_batch_form(form)

        status = require_integer(case.get("status"), "HTTP status", minimum=100)
        response = require_object(case.get("response"), "HTTP response")
        schema_errors = _schema_errors(
            response,
            _response_schema(document, operation, status),
        )
        if schema_errors:
            raise ContractValidationError(
                f"HTTP response schema failed: {schema_errors[0]}"
            )
        data = _validate_ocs_meta(response, status)
        if status == 200 and operation_id == "getSignalingSettingsV3":
            parse_settings(data)
        elif status == 200 and operation_id == "pullInternalSignalingV3":
            _validate_internal_pull(data)
        elif status == 200 and operation_id == "sendInternalSignalingV3":
            if data is not None and data != []:
                raise ContractValidationError("empty batch response is required")
        if not expected_valid:
            raise ContractValidationError("Invalid HTTP case was accepted")
    except ContractValidationError as error:
        if expected_valid:
            raise
        expected_error = require_string(case.get("error"), "HTTP error")
        if expected_error not in str(error):
            raise ContractValidationError(
                f"HTTP case {case.get('id')} failed for the wrong reason: {error}"
            ) from error


def _runtime_default() -> dict[str, Any]:
    return {
        "mode": None,
        "phase": "idle",
        "connectionEpoch": 0,
        "roomEpoch": 1,
        "hasSession": False,
        "hasResume": False,
        "resumeValid": False,
        "roomConfirmed": False,
        "localPeers": 0,
        "federatedPeers": 0,
        "allInCall": None,
        "federationInterrupted": False,
        "renegotiationRequired": False,
        "pending": None,
        "outcome": "unchanged",
    }


def _clear_transient(state: dict[str, Any]) -> None:
    state.update(
        {
            "hasSession": False,
            "hasResume": False,
            "resumeValid": False,
            "roomConfirmed": False,
            "localPeers": 0,
            "federatedPeers": 0,
            "allInCall": None,
            "federationInterrupted": False,
            "pending": None,
        }
    )


def _apply_runtime_action(state: dict[str, Any], raw_action: Any) -> None:
    action = require_object(raw_action, "runtime action")
    action_type = require_string(action.get("type"), "runtime action type")
    if action_type == "settings":
        mode = require_string(action.get("mode"), "runtime settings mode")
        if mode not in {"internal", "external"}:
            raise ContractValidationError("runtime settings mode is unsupported")
        state["mode"] = mode
        state["phase"] = "internalReady" if mode == "internal" else "idle"
        if mode == "internal":
            state["connectionEpoch"] = max(1, state["connectionEpoch"])
            state["roomConfirmed"] = True
        state["outcome"] = "settingsConfigured"
    elif action_type == "settingsTransportFailure":
        if state["phase"] != "fetchingSettings" or state["pending"] != "settingsFetch":
            raise ContractValidationError(
                "runtime settings transport failure precondition failed"
            )
        state["phase"] = "settingsRefreshRequired"
        state["pending"] = None
        state["outcome"] = "settingsRefreshRequired"
    elif action_type == "connect":
        if state["mode"] != "external" or state["phase"] not in {
            "idle",
            "reconnectWaiting",
        }:
            raise ContractValidationError("runtime connect precondition failed")
        state["connectionEpoch"] += 1
        state["phase"] = "awaitingWelcome"
        state["pending"] = None
        state["outcome"] = "awaitingWelcome"
    elif action_type == "welcome":
        if state["phase"] != "awaitingWelcome":
            raise ContractValidationError("runtime welcome precondition failed")
        can_resume = state["hasSession"] and state["hasResume"] and state["resumeValid"]
        state["phase"] = "helloPending"
        state["pending"] = "resume" if can_resume else "fullV2"
        if not can_resume:
            state["roomConfirmed"] = False
            state["localPeers"] = 0
            state["federatedPeers"] = 0
        state["outcome"] = "helloSending"
    elif action_type == "helloOk":
        if state["phase"] != "helloPending":
            raise ContractValidationError("runtime hello precondition failed")
        same_session = require_boolean(action.get("sameSession"), "sameSession")
        if state["pending"] == "resume":
            if not same_session:
                raise ContractValidationError("resume changed the signaling session")
            state["phase"] = "signalingReady"
            state["resumeValid"] = False
            state["roomConfirmed"] = True
            state["pending"] = None
            state["outcome"] = "resumed"
        elif state["pending"] == "fullV2":
            if same_session:
                raise ContractValidationError("full hello reused a stale session")
            state["hasSession"] = True
            state["hasResume"] = True
            state["resumeValid"] = False
            state["roomEpoch"] += 1
            state["roomConfirmed"] = False
            state["localPeers"] = 0
            state["federatedPeers"] = 0
            state["phase"] = "roomPending"
            state["pending"] = "roomJoin"
            state["outcome"] = "roomJoining"
        else:
            raise ContractValidationError("runtime hello has no pending frame")
    elif action_type == "roomOk":
        if state["phase"] != "roomPending" or state["pending"] != "roomJoin":
            raise ContractValidationError("runtime room precondition failed")
        state["phase"] = "signalingReady"
        state["roomConfirmed"] = True
        state["pending"] = None
        state["federationInterrupted"] = False
        state["outcome"] = "signalingReady"
    elif action_type == "disconnect":
        possibly_sent = require_boolean(
            action.get("bodyPossiblySent"),
            "bodyPossiblySent",
        )
        state["phase"] = "reconnectWaiting"
        state["resumeValid"] = state["hasSession"] and state["hasResume"]
        state["pending"] = None
        state["renegotiationRequired"] |= possibly_sent
        state["outcome"] = (
            "renegotiationRequired" if possibly_sent else "reconnectScheduled"
        )
    elif action_type == "expireResume":
        if not state["resumeValid"]:
            raise ContractValidationError("runtime resume was not active")
        _clear_transient(state)
        state["renegotiationRequired"] = True
        state["outcome"] = "unchanged"
    elif action_type == "helloError":
        if state["phase"] != "helloPending":
            raise ContractValidationError("runtime hello error precondition failed")
        code = require_string(action.get("code"), "hello error code")
        if code == "no_such_session" and state["pending"] == "resume":
            _clear_transient(state)
            state["phase"] = "helloPending"
            state["pending"] = "fullV2"
            state["renegotiationRequired"] = True
            state["outcome"] = "helloSending"
        elif code == "too_many_requests":
            state["phase"] = "reconnectWaiting"
            state["pending"] = "backoff"
            state["outcome"] = "reconnectScheduled"
        elif code in {
            "invalid_token",
            "token_not_valid_yet",
            "token_expired",
            "invalid_ticket",
            "auth_failed",
        }:
            _clear_transient(state)
            state["mode"] = None
            state["phase"] = "settingsRefreshRequired"
            state["outcome"] = "settingsRefreshRequired"
        else:
            raise ContractValidationError("runtime hello error is unsupported")
    elif action_type == "roomError":
        if action.get("code") != "no_such_room":
            raise ContractValidationError("runtime room error is unsupported")
        _clear_transient(state)
        state["phase"] = "roomSessionRefreshRequired"
        state["outcome"] = "roomSessionRefreshRequired"
    elif action_type == "internalPull":
        status = require_integer(action.get("status"), "internal status", minimum=100)
        if status == 200:
            state["phase"] = "internalReady"
            state["roomConfirmed"] = True
            state["localPeers"] = require_integer(
                action.get("localPeers"),
                "localPeers",
            )
            messages = require_integer(action.get("messages"), "messages")
            state["pending"] = None
            state["outcome"] = "messagesReceived" if messages else "signalingReady"
        elif status in {400, 401, 404, 409}:
            _clear_transient(state)
            if status == 400:
                state["mode"] = None
                state["phase"] = "settingsRefreshRequired"
                state["outcome"] = "settingsRefreshRequired"
            elif status == 401:
                state["phase"] = "reauthenticationRequired"
                state["outcome"] = "reauthenticationRequired"
            elif status == 404:
                state["phase"] = "roomSessionRefreshRequired"
                state["outcome"] = "roomSessionRefreshRequired"
            else:
                state["phase"] = "terminated"
                state["outcome"] = "terminated"
        else:
            raise ContractValidationError("runtime internal status is unsupported")
    elif action_type == "internalBatchTransportFailure":
        if state["pending"] != "internalBatch":
            raise ContractValidationError("runtime internal batch is not pending")
        body_state = require_string(action.get("bodyState"), "bodyState")
        if body_state not in {"notSent", "possiblySent"}:
            raise ContractValidationError("runtime bodyState is unsupported")
        state["pending"] = None
        if body_state == "possiblySent":
            state["renegotiationRequired"] = True
            state["outcome"] = "renegotiationRequired"
        else:
            state["outcome"] = "unchanged"
    elif action_type in {
        "crossAccountFrame",
        "staleEpochFrame",
        "staleRoomEpochFrame",
    }:
        state["outcome"] = "rejected"
    elif action_type == "restart":
        _clear_transient(state)
        state["mode"] = None
        state["phase"] = "idle"
        state["connectionEpoch"] += 1
        state["roomEpoch"] += 1
        state["renegotiationRequired"] = True
        state["outcome"] = "restartRecovered"
    elif action_type == "federationInterrupted":
        state["federationInterrupted"] = True
        state["outcome"] = "frameAccepted"
    elif action_type == "federationResumed":
        resumed = require_boolean(action.get("resumed"), "federation resumed")
        state["federationInterrupted"] = False
        if resumed:
            state["outcome"] = "frameAccepted"
        else:
            state["federatedPeers"] = 0
            state["renegotiationRequired"] = True
            state["outcome"] = "renegotiationRequired"
    elif action_type == "participantsUpdateAll":
        state["allInCall"] = require_integer(action.get("inCall"), "inCall")
        state["outcome"] = "frameAccepted"
    else:
        raise ContractValidationError(f"Unknown runtime action {action_type}")
    _validate_runtime_invariants(state)


def _validate_runtime_invariants(state: dict[str, Any]) -> None:
    for field in ("connectionEpoch", "roomEpoch", "localPeers", "federatedPeers"):
        require_integer(state[field], f"runtime {field}")
    if state["resumeValid"] and not (state["hasSession"] and state["hasResume"]):
        raise ContractValidationError("runtime resume lacks its session binding")
    if (
        state["mode"] == "external"
        and state["roomConfirmed"]
        and not state["hasSession"]
    ):
        raise ContractValidationError("runtime external room lacks a signaling session")
    if state["phase"] == "signalingReady" and not state["roomConfirmed"]:
        raise ContractValidationError("runtime ready phase lacks room confirmation")
    if state["federationInterrupted"] and state["mode"] != "external":
        raise ContractValidationError(
            "runtime federation state belongs to external mode"
        )


def simulate_runtime(case: dict[str, Any]) -> dict[str, Any]:
    initial = require_object(case.get("initial"), "runtime initial")
    if set(initial).difference(RUNTIME_FIELDS):
        raise ContractValidationError("runtime initial contains an unknown field")
    state = _runtime_default()
    state.update(initial)
    _validate_runtime_invariants(state)
    for action in require_list(case.get("actions"), "runtime actions"):
        _apply_runtime_action(state, action)
    return state


def validate_runtime_case(case: dict[str, Any]) -> int:
    actual = simulate_runtime(case)
    expected = require_object(case.get("expected"), "runtime expected")
    if set(expected) != set(RUNTIME_FIELDS):
        raise ContractValidationError("runtime expected summary has the wrong shape")
    if actual != expected:
        mismatches = [
            field
            for field in RUNTIME_FIELDS
            if actual.get(field) != expected.get(field)
        ]
        raise ContractValidationError(
            f"runtime case {case.get('id')} mismatch in {','.join(mismatches)}"
        )
    return len(require_list(case.get("actions"), "runtime actions"))


def _scan_fixture_secrets(value: Any, path: str = "$") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            child_path = f"{path}.{key}"
            secret_token = key == "token" and any(
                marker in path
                for marker in ("helloAuthParams", ".auth.params", ".federation")
            )
            if (key in SECRET_FIELDS or secret_token) and isinstance(child, str):
                if not child.startswith("synthetic-"):
                    raise ContractValidationError(
                        f"Non-synthetic secret-shaped fixture at {child_path}"
                    )
            _scan_fixture_secrets(child, child_path)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            _scan_fixture_secrets(child, f"{path}[{index}]")


def _scan_repository_text(paths: set[Path]) -> None:
    forbidden = (
        "BEGIN " + "PRIVATE KEY",
        "Authorization" + ": Basic",
        "Co-Authored" + "-By:",
        "Generated " + "with " + "Clau" + "de",
        "Generated by " + "Chat" + "GPT",
    )
    for path in paths:
        text = path.read_text(encoding="utf-8")
        for marker in forbidden:
            if marker in text:
                raise ContractValidationError(
                    f"Forbidden repository marker in {path.name}"
                )


def validate_contract() -> dict[str, int]:
    manifest = require_object(load_json(MANIFEST_PATH), "manifest")
    if manifest.get("talkSha") != EXPECTED_TALK_SHA or not SHA.fullmatch(
        str(manifest.get("talkSha", ""))
    ):
        raise ContractValidationError("Talk SHA is not pinned to the accepted revision")
    if manifest.get("hpbSha") != EXPECTED_HPB_SHA or not SHA.fullmatch(
        str(manifest.get("hpbSha", ""))
    ):
        raise ContractValidationError("HPB SHA is not pinned to the accepted revision")
    expected_counts = require_object(manifest.get("expectedCounts"), "expectedCounts")

    contract_path = (
        FIXTURE_ROOT / require_string(manifest.get("contract"), "contract")
    ).resolve()
    document = require_object(load_json(contract_path), "OpenAPI document")
    validate(document)
    operations = {
        operation_id: _find_operation(document, operation_id)
        for operation_id in EXPECTED_OPERATIONS
    }
    for operation_id, (method, suffix) in EXPECTED_OPERATIONS.items():
        path, actual_method, _ = operations[operation_id]
        if actual_method != method or not path.endswith(suffix):
            raise ContractValidationError(f"OpenAPI operation {operation_id} drifted")

    fixture_specs = (
        ("httpFile", "http", validate_http_case),
        ("settingsFile", "settings", validate_settings_case),
        ("hpbFile", "hpb", validate_hpb_case),
        ("runtimeFile", "runtime", validate_runtime_case),
    )
    listed_paths: set[Path] = set()
    counts: dict[str, int] = {"operations": len(operations), "runtimeSteps": 0}
    for manifest_key, label, validator in fixture_specs:
        path = (
            FIXTURE_ROOT / require_string(manifest.get(manifest_key), manifest_key)
        ).resolve()
        listed_paths.add(path)
        expected_count = require_integer(expected_counts.get(label), f"{label} count")
        cases = require_unique_cases(load_json(path), expected_count, label)
        for case in cases:
            _scan_fixture_secrets(case)
            if label == "http":
                validate_http_case(document, case)
            elif label == "runtime":
                counts["runtimeSteps"] += validate_runtime_case(case)
            else:
                validator(case)
        counts[label] = len(cases)

    actual_paths = {
        path.resolve()
        for path in FIXTURE_ROOT.glob("*.json")
        if path.name != MANIFEST_PATH.name
    }
    if listed_paths != actual_paths:
        raise ContractValidationError("Signaling manifest does not cover every fixture")
    _scan_repository_text(
        listed_paths
        | {
            MANIFEST_PATH.resolve(),
            contract_path,
            Path(__file__).resolve(),
            (CONTRACT_ROOT / "test_validate_contract.py").resolve(),
            (CONTRACT_ROOT / "requirements.txt").resolve(),
        }
    )
    return counts


def main() -> int:
    try:
        counts = validate_contract()
        print(
            "Validated 1 OpenAPI document, "
            f"{counts['operations']} HTTP operations, "
            f"{counts['http']} HTTP cases, "
            f"{counts['settings']} settings cases, "
            f"{counts['hpb']} HPB frames and "
            f"{counts['runtime']} runtime cases with "
            f"{counts['runtimeSteps']} state transitions."
        )
        return 0
    except (
        ContractValidationError,
        KeyError,
        OSError,
        TypeError,
        ValueError,
        json.JSONDecodeError,
    ) as error:
        print(f"Contract validation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
