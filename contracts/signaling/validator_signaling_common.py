from __future__ import annotations

import json
import re
from copy import deepcopy
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit, urlunsplit

from jsonschema import Draft202012Validator, FormatChecker


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


class ContractValidationError(RuntimeError):
    pass


def duplicate_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ContractValidationError("JSON object contains a duplicate member")
        result[key] = value
    return result


def validate_json_budget(value: Any) -> None:
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
        value = json.loads(text, object_pairs_hook=duplicate_object)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ContractValidationError(
            f"{label} is not valid strict UTF-8 JSON"
        ) from error
    validate_json_budget(value)
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


def resolve_pointer(document: dict[str, Any], reference: str) -> Any:
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
                    deepcopy(resolve_pointer(document, reference)),
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


def find_operation(
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


def response_schema(
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


def request_schema(
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


def schema_errors(instance: Any, schema: dict[str, Any]) -> list[str]:
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    return [
        f"{'.'.join(str(member) for member in error.absolute_path)} [{error.validator}]"
        for error in sorted(
            validator.iter_errors(instance),
            key=lambda item: tuple(str(member) for member in item.absolute_path),
        )
    ]


def normalize_tls_uri(
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
    _, authority, path = normalize_tls_uri(value, label, schemes={"https"})
    return urlunsplit(("https", authority, path, "", ""))


def normalize_hpb_endpoint(value: Any, label: str = "server") -> str:
    _, authority, path = normalize_tls_uri(
        value,
        label,
        schemes={"https", "wss"},
    )
    socket_path = path if path.endswith("/spreed") else f"{path}/spreed"
    return urlunsplit(("wss", authority, socket_path, "", ""))


def require_synthetic_secret(value: Any, label: str, maximum: int) -> str:
    secret = require_string(value, label, maximum=maximum)
    if not secret.startswith("synthetic-"):
        raise ContractValidationError(f"{label} must be an explicit synthetic fixture")
    return secret


def validate_feature_list(value: Any, label: str) -> list[str]:
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
