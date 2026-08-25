from __future__ import annotations

import json
import re
import uuid
from copy import deepcopy
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlsplit, urlunsplit

from jsonschema import Draft202012Validator, FormatChecker


CONTRACT_ROOT = Path(__file__).resolve().parent
FIXTURE_ROOT = CONTRACT_ROOT / "fixtures"
MANIFEST_PATH = FIXTURE_ROOT / "manifest.json"
EXPECTED_TALK_SHA = "f2958bb25be6604240c58a3faf9a2033a30d20e5"
EXPECTED_CORE_SHAS = {
    "master": "a0bf541f667e4d891e05a92254b167840066e1a0",
    "stable34": "a599620e9b75dc3c919b39dabd82a4f98b543b74",
}
USER_AGENT = "com.nkshub.nextcloudtalk attachment-contract/0.1"
MAX_JSON_BYTES = 2 * 1024 * 1024
MAX_XML_BYTES = 1024 * 1024
MAX_JSON_DEPTH = 64
MAX_JSON_NODES = 20_000
MAX_XML_DEPTH = 32
MAX_XML_NODES = 4_096
MAX_STRING_LENGTH = 65_536
MAX_METADATA_BYTES = 16_384
DAV_NAMESPACE = "{DAV:}"
CONVERSATION_TOKEN = re.compile(r"^[a-z0-9]{4,30}$")
SAFE_IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._@+-]{0,127}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
CHUNK_NAME = re.compile(r"^([0-9]{16})-([0-9]{16})$")
SCHEMA_PATH_MEMBER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
CONTROL = re.compile(r"[\x00-\x1f\x7f]")
XML_DECLARATION = re.compile(r"^\s*<\?xml\s+(?P<attributes>.*?)\?>", re.IGNORECASE)
XML_DECLARED_ENCODING = re.compile(
    r"\bencoding\s*=\s*(['\"])(?P<encoding>[^'\"]+)\1",
    re.IGNORECASE,
)
REQUIRED_FIXTURE_IDS = {
    "finalize-internal-error",
    "finalize-not-draft",
    "finalize-not-found",
    "finalize-ocs-mismatch",
    "finalize-request",
    "finalize-success",
    "finalize-unauthorized",
    "probe-disabled",
    "probe-quota",
    "probe-renames-must-be-array-of-maps",
    "probe-request",
    "probe-success",
}
REQUIRED_CAPABILITY_IDS = {
    "anonymous-rejected",
    "attachments-disabled",
    "baseline-supported",
    "caption-feature-missing",
    "duplicate-feature-rejected",
    "federated-rejected",
    "optional-features-supported",
    "reference-id-missing",
    "reply-feature-missing",
    "silent-feature-missing",
    "subfolders-disabled",
    "thread-feature-missing",
    "voice-feature-missing",
    "voice-mime-rejected",
    "write-permission-missing",
}
REQUIRED_WIRE_IDS = {
    "absolute-uri-rejected",
    "backslash-rejected",
    "comment-job-rejects-voice-metadata",
    "dot-segment-rejected",
    "empty-segment-rejected",
    "finalize-wire-request",
    "fragment-rejected",
    "http-origin-rejected",
    "leading-slash-rejected",
    "parent-segment-rejected",
    "preencoded-segment-rejected",
    "probe-wire-request",
    "query-rejected",
    "response-account-mismatch-rejected",
    "response-binding-match",
    "response-origin-mismatch-rejected",
    "safe-relative-path-encoded-once",
    "thread-title-requires-thread-id",
    "voice-finalize-wire-request",
    "voice-job-rejects-missing-message-type",
}
REQUIRED_DAV_PLAN_IDS = {
    "chunk-corrupt-server-state",
    "chunk-exact-multiple",
    "chunk-resume-missing-only",
    "chunked-upload",
    "cleanup-chunk-session",
    "cleanup-draft-temp",
    "normal-small-upload",
}
REQUIRED_DAV_STATUS_IDS = {
    "delete-already-absent",
    "delete-removed",
    "mkcol-already-exists",
    "mkcol-created",
    "move-created",
    "move-length-mismatch",
    "move-replaced",
    "propfind-multistatus",
    "put-created",
    "put-replaced",
    "unexpected-dav-status",
}
REQUIRED_DAV_XML_IDS = {
    "propfind-empty",
    "propfind-entity-rejected",
    "propfind-resume",
}
REQUIRED_STATE_IDS = {
    "allow-update-mismatch-rejected",
    "cancel-after-finalize-is-rejected",
    "cancel-before-finalize-cleans",
    "cleanup-failure-can-retry",
    "cross-account-transition-rejected",
    "cross-origin-transition-rejected",
    "deterministic-finalize-status-fails",
    "happy-path-one-confirmation",
    "lost-finalize-response-never-blind-replays",
    "multiple-confirmations-remain-ambiguous",
    "reauth-pauses-only-account-lane",
    "restart-during-finalize-awaits-confirmation",
    "restart-during-upload-preserves-resume",
    "same-reference-wrong-message-type-is-not-confirmation",
    "source-checksum-mismatch-fails",
    "stale-capability-replay-rejected",
    "stale-revision-replay-rejected",
    "transport-before-finalize-body-is-retryable",
    "upload-without-source-check-is-rejected",
    "zero-confirmations-remain-awaiting",
}
STATE_SUMMARY_FIELDS = (
    "phase",
    "lane",
    "resumePhase",
    "finalizationDispatched",
    "cleanupRequired",
    "messageIds",
    "lastOutcome",
)


class ContractValidationError(RuntimeError):
    pass


class ResponseSemanticError(ContractValidationError):
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
            for child in current:
                stack.append((child, depth + 1))
        elif current is not None and not isinstance(current, (bool, int, float)):
            raise ContractValidationError("JSON contains an unsupported value")


def decode_json_bytes(raw: bytes, label: str = "JSON") -> Any:
    if len(raw) > MAX_JSON_BYTES:
        raise ContractValidationError(f"{label} byte budget exceeded")
    try:
        text = raw.decode("utf-8", errors="strict")
        value = json.loads(text, object_pairs_hook=_duplicate_object)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ContractValidationError(f"{label} is not valid UTF-8 JSON") from error
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
    maximum: int = 4096,
) -> str:
    if not isinstance(value, str) or not value or len(value) > maximum:
        raise ContractValidationError(f"{label} must be a bounded non-empty string")
    if CONTROL.search(value):
        raise ContractValidationError(f"{label} contains a control character")
    return value


def require_integer(
    value: Any,
    label: str,
    minimum: int | None = None,
    maximum: int | None = None,
) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ContractValidationError(f"{label} must be an integer")
    if minimum is not None and value < minimum:
        raise ContractValidationError(f"{label} is below its minimum")
    if maximum is not None and value > maximum:
        raise ContractValidationError(f"{label} exceeds its maximum")
    return value


def require_boolean(value: Any, label: str) -> bool:
    if not isinstance(value, bool):
        raise ContractValidationError(f"{label} must be boolean")
    return value


def require_unique_ids(
    raw_cases: Any,
    required_ids: set[str],
    label: str,
) -> list[dict[str, Any]]:
    cases: list[dict[str, Any]] = []
    ids: list[str] = []
    for raw_case in require_list(raw_cases, label):
        case = require_object(raw_case, label)
        case_id = require_string(case.get("id"), f"{label} id", maximum=128)
        cases.append(case)
        ids.append(case_id)
    if len(ids) != len(set(ids)):
        raise ContractValidationError(f"{label} ids must be unique")
    if set(ids) != required_ids:
        raise ContractValidationError(
            f"{label} coverage mismatch; "
            f"missing={sorted(required_ids - set(ids))}, "
            f"unexpected={sorted(set(ids) - required_ids)}"
        )
    return cases


def safe_mapping_mismatch_fields(
    actual: Any,
    expected: Any,
    allowed_fields: tuple[str, ...],
) -> list[str]:
    if not isinstance(actual, dict) or not isinstance(expected, dict):
        return ["shape"]
    allowed = set(allowed_fields)
    mismatched = [
        field
        for field in allowed_fields
        if (field in actual) != (field in expected)
        or actual.get(field) != expected.get(field)
    ]
    if set(actual).difference(allowed) or set(expected).difference(allowed):
        mismatched.append("shape")
    return mismatched or ["shape"]


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
            target = expand_references(
                deepcopy(_resolve_pointer(document, reference)),
                document,
                active | {reference},
            )
            expanded = require_object(target, "OpenAPI reference target")
            for key, sibling in value.items():
                if key != "$ref":
                    expanded[key] = expand_references(sibling, document, active)
            return expanded
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
) -> tuple[str, dict[str, Any], dict[str, Any]]:
    paths = require_object(document.get("paths"), "OpenAPI paths")
    for path, raw_item in paths.items():
        item = require_object(raw_item, "OpenAPI path item")
        for method, raw_operation in item.items():
            if method.lower() not in {"get", "post", "put", "patch", "delete"}:
                continue
            operation = require_object(raw_operation, "OpenAPI operation")
            if operation.get("operationId") == operation_id:
                return path, item, operation
    raise ContractValidationError("Unknown OpenAPI operationId")


def request_schema(
    document: dict[str, Any],
    operation: dict[str, Any],
    media_type: str,
) -> dict[str, Any]:
    try:
        raw = operation["requestBody"]["content"][media_type]["schema"]
    except KeyError as error:
        raise ContractValidationError(
            "Operation lacks the declared request schema"
        ) from error
    return require_object(expand_references(raw, document), "request schema")


def response_schema(
    document: dict[str, Any],
    operation: dict[str, Any],
    status: str,
    media_type: str,
) -> dict[str, Any]:
    try:
        raw_response = operation["responses"][status]
    except KeyError as error:
        raise ContractValidationError(
            "Operation lacks the declared response status"
        ) from error
    response = require_object(
        expand_references(raw_response, document),
        "response definition",
    )
    try:
        return require_object(
            response["content"][media_type]["schema"], "response schema"
        )
    except KeyError as error:
        raise ContractValidationError(
            "Response lacks the declared media type"
        ) from error


def _schema_property_names(schema: dict[str, Any]) -> set[str]:
    names: set[str] = set()
    stack: list[Any] = [schema]
    while stack:
        value = stack.pop()
        if isinstance(value, dict):
            properties = value.get("properties")
            if isinstance(properties, dict):
                names.update(
                    key
                    for key in properties
                    if SCHEMA_PATH_MEMBER.fullmatch(key) is not None
                )
            stack.extend(value.values())
        elif isinstance(value, list):
            stack.extend(value)
    return names


def _summarize_schema_error(error: Any, safe_members: set[str]) -> str:
    path = "$"
    for member in error.absolute_path:
        if isinstance(member, int):
            path += f"[{member}]"
        elif isinstance(member, str) and member in safe_members:
            path += f".{member}"
        else:
            path += "[<member>]"
    validator = error.validator
    if (
        not isinstance(validator, str)
        or SCHEMA_PATH_MEMBER.fullmatch(validator) is None
    ):
        validator = "unknown"
    return f"{path} [{validator}]"


def validate_json_schema(instance: Any, schema: dict[str, Any]) -> list[str]:
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    safe_members = _schema_property_names(schema)
    return [
        _summarize_schema_error(error, safe_members)
        for error in sorted(
            validator.iter_errors(instance),
            key=lambda item: tuple(str(member) for member in item.absolute_path),
        )
    ]


def normalize_server(value: Any) -> str:
    raw = require_string(value, "server", maximum=4096)
    parsed = urlsplit(raw)
    if (
        parsed.scheme.lower() != "https"
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or not parsed.hostname
    ):
        raise ContractValidationError("Server must be an unambiguous HTTPS base")
    try:
        port = parsed.port
    except ValueError as error:
        raise ContractValidationError("Server port is invalid") from error
    host = parsed.hostname.lower()
    if CONTROL.search(host) or "%" in host:
        raise ContractValidationError("Server host is invalid")
    if ":" in host:
        host = f"[{host}]"
    authority = host if port in {None, 443} else f"{host}:{port}"
    path = parsed.path.rstrip("/")
    if path:
        if "//" in path or "\\" in path or "%" in path:
            raise ContractValidationError("Server subpath is ambiguous")
        segments = path.split("/")[1:]
        if any(
            segment in {"", ".", ".."} or CONTROL.search(segment)
            for segment in segments
        ):
            raise ContractValidationError("Server subpath is ambiguous")
    return urlunsplit(("https", authority, path, "", ""))


def normalize_relative_path(value: Any) -> tuple[str, str]:
    raw = require_string(value, "relative DAV path", maximum=4096)
    if (
        raw.startswith("/")
        or raw.endswith("/")
        or "\\" in raw
        or "?" in raw
        or "#" in raw
        or "%" in raw
        or urlsplit(raw).scheme
    ):
        raise ContractValidationError("DAV path is not a safe relative path")
    segments = raw.split("/")
    if any(
        segment in {"", ".", ".."} or len(segment) > 255 or CONTROL.search(segment)
        for segment in segments
    ):
        raise ContractValidationError("DAV path contains an unsafe segment")
    encoded = "/".join(quote(segment, safe="-._~()") for segment in segments)
    return raw, encoded


def _safe_identifier(value: Any, label: str) -> str:
    result = require_string(value, label, maximum=128)
    if SAFE_IDENTIFIER.fullmatch(result) is None:
        raise ContractValidationError(f"{label} has an unsafe shape")
    return result


def _conversation_token(value: Any) -> str:
    token = require_string(value, "room token", maximum=30)
    if CONVERSATION_TOKEN.fullmatch(token) is None:
        raise ContractValidationError("Room token has an invalid shape")
    return token


def _uuid(value: Any, label: str) -> str:
    raw = require_string(value, label, maximum=64)
    try:
        parsed = uuid.UUID(raw)
    except ValueError as error:
        raise ContractValidationError(f"{label} is not a UUID") from error
    if str(parsed) != raw.lower() or parsed.variant != uuid.RFC_4122:
        raise ContractValidationError(f"{label} is not canonical")
    return raw.lower()


def _validate_filename(value: Any, label: str) -> str:
    name = require_string(value, label, maximum=255)
    if "/" in name or "\\" in name:
        raise ContractValidationError(f"{label} contains a path separator")
    return name


def _validate_metadata(value: Any) -> dict[str, Any]:
    metadata = require_object(value, "attachment metadata")
    allowed = {
        "caption",
        "messageType",
        "silent",
        "replyTo",
        "threadId",
        "threadTitle",
    }
    if set(metadata).difference(allowed):
        raise ContractValidationError("Attachment metadata contains an unknown member")
    if "caption" in metadata:
        caption = require_string(metadata["caption"], "caption", maximum=4096)
        if caption != caption.strip():
            raise ContractValidationError("Caption must already be trimmed")
    if "messageType" in metadata and metadata["messageType"] != "voice-message":
        raise ContractValidationError("Unsupported attachment message type")
    if "silent" in metadata:
        require_boolean(metadata["silent"], "silent")
    for name in ("replyTo", "threadId"):
        if name in metadata:
            require_integer(metadata[name], name, 1)
    if "threadTitle" in metadata:
        title = require_string(metadata["threadTitle"], "threadTitle", maximum=200)
        if title != title.strip():
            raise ContractValidationError("Thread title must already be trimmed")
        if "threadId" not in metadata:
            raise ContractValidationError("Thread title requires threadId")
    encoded = json.dumps(
        metadata,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    )
    if len(encoded.encode("utf-8")) > MAX_METADATA_BYTES:
        raise ContractValidationError("Attachment metadata byte budget exceeded")
    return metadata


def _expected_message_type(value: Any) -> str:
    message_type = require_string(value, "expectedMessageType", maximum=64)
    if message_type not in {"comment", "voice-message"}:
        raise ContractValidationError("Expected attachment message type is unsupported")
    return message_type


def _metadata_message_type(metadata: dict[str, Any]) -> str:
    return (
        "voice-message" if metadata.get("messageType") == "voice-message" else "comment"
    )


def _decode_metadata(value: Any) -> dict[str, Any]:
    raw = require_string(value, "talkMetaData", maximum=MAX_METADATA_BYTES)
    try:
        decoded = json.loads(raw, object_pairs_hook=_duplicate_object)
    except json.JSONDecodeError as error:
        raise ContractValidationError("talkMetaData is not valid JSON") from error
    _validate_json_budget(decoded)
    return _validate_metadata(decoded)


def _binding(input_value: dict[str, Any]) -> dict[str, str]:
    return {
        "accountId": _safe_identifier(input_value.get("accountId"), "accountId"),
        "requestId": _safe_identifier(input_value.get("requestId"), "requestId"),
        "server": normalize_server(input_value.get("server")),
        "roomToken": _conversation_token(input_value.get("roomToken")),
    }


def _api_headers() -> dict[str, str]:
    return {
        "Accept": "application/json",
        "Content-Type": "application/json",
        "OCS-APIRequest": "true",
        "User-Agent": USER_AGENT,
    }
