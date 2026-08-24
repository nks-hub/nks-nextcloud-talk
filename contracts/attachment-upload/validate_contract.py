from __future__ import annotations

import json
import re
import sys
import uuid
import xml.etree.ElementTree as ET
from copy import deepcopy
from pathlib import Path
from typing import Any
from urllib.parse import quote, unquote, urlsplit, urlunsplit

from jsonschema import Draft202012Validator, FormatChecker
from openapi_spec_validator import validate


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


def build_wire_case(kind: str, raw_input: Any) -> dict[str, Any]:
    input_value = require_object(raw_input, "wire case input")
    if kind == "relativePath":
        _, encoded = normalize_relative_path(input_value.get("path"))
        return {"encodedPath": encoded}
    if kind == "responseBinding":
        request = require_object(input_value.get("request"), "request binding")
        response = require_object(input_value.get("response"), "response binding")
        request_binding = _binding(request)
        response_binding = _binding(response)
        if request_binding != response_binding:
            raise ContractValidationError("Response does not match its request binding")
        return {"bound": True}
    if kind not in {"probe", "finalize"}:
        raise ContractValidationError("Unknown wire case kind")
    binding = _binding(input_value)
    server = binding["server"]
    room = binding["roomToken"]
    common = {
        "method": "POST",
        "headers": _api_headers(),
        "binding": binding,
    }
    if kind == "probe":
        raw_names = require_list(input_value.get("fileNames"), "fileNames")
        if not 1 <= len(raw_names) <= 16:
            raise ContractValidationError("fileNames count is outside the contract")
        file_names = [_validate_filename(name, "fileName") for name in raw_names]
        allow_update = require_boolean(input_value.get("allowUpdate"), "allowUpdate")
        return {
            "operationId": "probeAttachmentFolder",
            **common,
            "uri": (
                f"{server}/ocs/v2.php/apps/spreed/api/v1/chat/{room}"
                "/attachment/folder?format=json"
            ),
            "body": {"fileNames": file_names, "allowUpdate": allow_update},
        }
    _, file_path = normalize_relative_path(input_value.get("filePath"))
    del file_path
    metadata = _validate_metadata(input_value.get("metadata", {}))
    expected_message_type = _expected_message_type(
        input_value.get("expectedMessageType")
    )
    if _metadata_message_type(metadata) != expected_message_type:
        raise ContractValidationError(
            "Finalize metadata differs from the job-bound message type"
        )
    encoded_metadata = json.dumps(
        metadata,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    )
    body = {
        "filePath": input_value["filePath"],
        "referenceId": _uuid(input_value.get("referenceId"), "referenceId"),
        "talkMetaData": encoded_metadata,
        "fileName": _validate_filename(input_value.get("fileName"), "fileName"),
        "allowUpdate": require_boolean(input_value.get("allowUpdate"), "allowUpdate"),
    }
    return {
        "operationId": "finalizeAttachment",
        **common,
        "uri": (
            f"{server}/ocs/v2.php/apps/spreed/api/v1/chat/{room}/attachment?format=json"
        ),
        "body": body,
    }


def validate_built_request(document: dict[str, Any], built: dict[str, Any]) -> None:
    operation_id = require_string(built.get("operationId"), "operationId")
    _, _, operation = find_operation(document, operation_id)
    if built.get("method") != "POST":
        raise ContractValidationError("Talk mutation must use POST")
    headers = require_object(built.get("headers"), "request headers")
    if headers != _api_headers():
        raise ContractValidationError("Talk request headers differ from the contract")
    uri = require_string(built.get("uri"), "request URI")
    parsed = urlsplit(uri)
    if parsed.query != "format=json" or parsed.fragment:
        raise ContractValidationError("Talk request query differs from the contract")
    schema = request_schema(document, operation, "application/json")
    errors = validate_json_schema(built.get("body"), schema)
    if errors:
        raise ContractValidationError(
            "Built request violates OpenAPI: " + "; ".join(errors)
        )
    if operation_id == "finalizeAttachment":
        _decode_metadata(require_object(built["body"], "body")["talkMetaData"])


def _normalize_features(value: Any) -> set[str]:
    raw_features = require_list(value, "talkFeatures")
    features = [
        require_string(feature, "Talk feature", maximum=128) for feature in raw_features
    ]
    if len(features) != len(set(features)):
        raise ContractValidationError("Talk features must be unique")
    return set(features)


def resolve_capability_case(raw_case: Any) -> dict[str, Any]:
    case = require_object(raw_case, "capability case")
    snapshot = require_object(case.get("snapshot"), "capability snapshot")
    room = require_object(case.get("room"), "room profile")
    requested = require_object(case.get("requested"), "requested attachment options")
    features = _normalize_features(snapshot.get("talkFeatures"))
    attachments = require_object(snapshot.get("attachments"), "attachment config")
    allowed = require_boolean(attachments.get("allowed"), "attachments.allowed")
    subfolders = require_boolean(
        attachments.get("conversationSubfolders"),
        "attachments.conversationSubfolders",
    )
    federated = require_boolean(room.get("federated"), "room.federated")
    can_post = require_boolean(room.get("canPost"), "room.canPost")
    if snapshot.get("context") != "authenticated":
        return {"supported": False, "reason": "authenticated-capabilities-required"}
    if not allowed:
        return {"supported": False, "reason": "attachments-disabled"}
    if not subfolders:
        return {"supported": False, "reason": "conversation-subfolders-required"}
    if "chat-reference-id" not in features:
        return {"supported": False, "reason": "chat-reference-id-required"}
    if federated:
        return {"supported": False, "reason": "federated-room-unsupported"}
    if not can_post:
        return {"supported": False, "reason": "chat-write-permission-required"}
    allowed_requests = {"caption", "voice", "voiceMime", "reply", "thread", "silent"}
    if set(requested).difference(allowed_requests):
        raise ContractValidationError(
            "Requested attachment options contain an unknown member"
        )
    profile = {
        "caption": "media-caption" in features,
        "voice": "voice-message-sharing" in features,
        "reply": "chat-replies" in features,
        "thread": "threads" in features,
        "silent": "silent-send" in features,
    }
    requirements = (
        ("caption", "media-caption-required"),
        ("voice", "voice-message-sharing-required"),
        ("reply", "chat-replies-required"),
        ("thread", "threads-required"),
        ("silent", "silent-send-required"),
    )
    for option, reason in requirements:
        enabled = requested.get(option, False)
        require_boolean(enabled, f"requested.{option}")
        if enabled and not profile[option]:
            return {"supported": False, "reason": reason}
    if requested.get("voice", False):
        mime = require_string(requested.get("voiceMime"), "voiceMime", maximum=128)
        if mime not in {"audio/mpeg", "audio/wav"}:
            return {"supported": False, "reason": "voice-mime-unsupported"}
    elif "voiceMime" in requested:
        raise ContractValidationError("voiceMime requires requested.voice")
    return {"supported": True, "reason": None, "profile": profile}


def validate_capability_cases(path: Path) -> int:
    root = require_object(load_json(path), path.name)
    cases = require_unique_ids(
        root.get("cases"),
        REQUIRED_CAPABILITY_IDS,
        "capability case",
    )
    for case in cases:
        try:
            actual = resolve_capability_case(case)
        except ContractValidationError:
            if case.get("expectedError") is True:
                continue
            raise
        if case.get("expectedError") is True:
            raise ContractValidationError(
                f"Negative capability case {case['id']} unexpectedly succeeded"
            )
        expected = require_object(case.get("expected"), "capability expectation")
        if actual != expected:
            raise ContractValidationError(
                f"Capability case {case['id']} differs in safe result fields"
            )
    return len(cases)


def validate_wire_cases(document: dict[str, Any], path: Path) -> int:
    root = require_object(load_json(path), path.name)
    cases = require_unique_ids(root.get("cases"), REQUIRED_WIRE_IDS, "wire case")
    for case in cases:
        try:
            actual = build_wire_case(
                require_string(case.get("kind"), "wire case kind"),
                case.get("input"),
            )
            if actual.get("operationId") is not None:
                validate_built_request(document, actual)
        except ContractValidationError:
            if case.get("expectedError") is True:
                continue
            raise
        if case.get("expectedError") is True:
            raise ContractValidationError(
                f"Negative wire case {case['id']} unexpectedly succeeded"
            )
        expected = require_object(case.get("expected"), "wire expectation")
        if actual != expected:
            fields = safe_mapping_mismatch_fields(
                actual,
                expected,
                (
                    "operationId",
                    "method",
                    "uri",
                    "headers",
                    "body",
                    "binding",
                    "encodedPath",
                    "bound",
                ),
            )
            raise ContractValidationError(
                f"Wire case {case['id']} differs in sections: " + ", ".join(fields)
            )
    return len(cases)


def _safe_fixture_path(value: Any, suffix: str) -> Path:
    name = require_string(value, "fixture file", maximum=255)
    path = (FIXTURE_ROOT / name).resolve()
    if path.parent != FIXTURE_ROOT or path.suffix.lower() != suffix:
        raise ContractValidationError("Fixture path escapes its contract folder")
    if not path.is_file():
        raise ContractValidationError("Fixture file does not exist")
    return path


def _ocs_parts(instance: Any) -> tuple[dict[str, Any], Any]:
    root = require_object(instance, "OCS response")
    ocs = require_object(root.get("ocs"), "OCS envelope")
    return require_object(ocs.get("meta"), "OCS metadata"), ocs.get("data")


def _validate_renames(value: Any, maximum: int) -> list[dict[str, str]]:
    raw_entries = require_list(value, "renames")
    if len(raw_entries) > maximum:
        raise ResponseSemanticError("Rename count exceeds its response bound")
    entries: list[dict[str, str]] = []
    for raw_entry in raw_entries:
        entry = require_object(raw_entry, "rename entry")
        if len(entry) != 1:
            raise ResponseSemanticError("Each rename entry must have one mapping")
        source, target = next(iter(entry.items()))
        entries.append(
            {
                _validate_filename(source, "rename source"): _validate_filename(
                    target,
                    "rename target",
                )
            }
        )
    return entries


def classify_fixture(
    fixture: dict[str, Any],
    instance: Any,
) -> dict[str, Any]:
    direction = fixture["direction"]
    operation_id = fixture["operationId"]
    if direction == "request":
        if operation_id == "finalizeAttachment":
            body = require_object(instance, "finalize request")
            normalize_relative_path(body.get("filePath"))
            metadata = _decode_metadata(body.get("talkMetaData"))
            expected_message_type = _expected_message_type(
                fixture.get("expectedMessageType")
            )
            if _metadata_message_type(metadata) != expected_message_type:
                raise ContractValidationError(
                    "Finalize fixture differs from the job-bound message type"
                )
            require_boolean(body.get("allowUpdate"), "allowUpdate")
        elif operation_id == "probeAttachmentFolder":
            body = require_object(instance, "probe request")
            require_boolean(body.get("allowUpdate"), "allowUpdate")
        return {"classification": "request-valid", "renames": []}

    status = require_integer(int(fixture["status"]), "HTTP status", 100, 599)
    meta, data = _ocs_parts(instance)
    ocs_status = require_integer(meta.get("statuscode"), "OCS status", 0, 999)
    ocs_state = require_string(meta.get("status"), "OCS status text", maximum=32)
    if status == 200 and ocs_status == 200 and ocs_state == "ok":
        data_object = require_object(data, "OCS response data")
        if operation_id == "probeAttachmentFolder":
            normalize_relative_path(data_object.get("folder"))
            renames = _validate_renames(data_object.get("renames"), 16)
            return {"classification": "probe-confirmed", "renames": renames}
        renames = _validate_renames(data_object.get("renames"), 1)
        if len(renames) != 1:
            raise ResponseSemanticError("Finalize must return exactly one rename map")
        return {"classification": "finalize-accepted", "renames": renames}

    if status != ocs_status or ocs_state != "failure":
        if operation_id == "finalizeAttachment":
            return {"classification": "ambiguous-finalize", "renames": []}
        raise ResponseSemanticError("HTTP and OCS status disagree")
    require_object(data, "OCS error data")
    if status == 401:
        classification = "reauth"
    elif operation_id == "finalizeAttachment" and status >= 500 and status != 507:
        classification = "ambiguous-finalize"
    elif status in {400, 403, 404, 422, 501, 507}:
        classification = "deterministic-failure"
    else:
        classification = "transient-failure"
    return {"classification": classification, "renames": []}


def validate_fixture(
    document: dict[str, Any],
    fixture: dict[str, Any],
) -> dict[str, Any]:
    instance = load_json(_safe_fixture_path(fixture.get("file"), ".json"))
    operation_id = require_string(fixture.get("operationId"), "fixture operationId")
    _, _, operation = find_operation(document, operation_id)
    direction = require_string(fixture.get("direction"), "fixture direction")
    media_type = require_string(fixture.get("mediaType"), "fixture media type")
    schema_valid = fixture.get("schemaValid")
    if not isinstance(schema_valid, bool):
        raise ContractValidationError("Fixture schemaValid must be boolean")
    if direction == "request":
        schema = request_schema(document, operation, media_type)
    elif direction == "response":
        status = require_string(fixture.get("status"), "fixture status", maximum=3)
        schema = response_schema(document, operation, status, media_type)
    else:
        raise ContractValidationError("Fixture direction is unsupported")
    errors = validate_json_schema(instance, schema)
    if schema_valid and errors:
        raise ContractValidationError(
            f"Fixture {fixture['id']} violates its schema: " + "; ".join(errors)
        )
    if not schema_valid and not errors:
        raise ContractValidationError(
            f"Negative fixture {fixture['id']} was accepted by its schema"
        )
    if not schema_valid:
        result = {"classification": "schema-error", "renames": []}
    else:
        try:
            result = classify_fixture(fixture, instance)
        except ResponseSemanticError:
            result = {"classification": "semantic-error", "renames": []}
    expected_classification = require_string(
        fixture.get("expectedClassification"),
        "expected classification",
    )
    if result["classification"] != expected_classification:
        raise ContractValidationError(
            f"Fixture {fixture['id']} has classification "
            f"{result['classification']}, expected {expected_classification}"
        )
    if "expectedRenameCount" in fixture:
        expected_count = require_integer(
            fixture["expectedRenameCount"],
            "expected rename count",
            0,
            16,
        )
        if len(result["renames"]) != expected_count:
            raise ContractValidationError(
                f"Fixture {fixture['id']} has an unexpected rename count"
            )
    return result


def parse_dav_multistatus_bytes(raw: bytes) -> list[dict[str, Any]]:
    if len(raw) > MAX_XML_BYTES:
        raise ContractValidationError("DAV XML byte budget exceeded")
    try:
        text = raw.decode("utf-8-sig", errors="strict")
    except UnicodeDecodeError as error:
        raise ContractValidationError("DAV XML must use UTF-8") from error
    if "\x00" in text:
        raise ContractValidationError("DAV XML must use UTF-8")
    declaration = XML_DECLARATION.match(text)
    if declaration is not None:
        encoding = XML_DECLARED_ENCODING.search(declaration.group("attributes"))
        if encoding is not None and encoding.group("encoding").lower() not in {
            "utf-8",
            "utf8",
        }:
            raise ContractValidationError("DAV XML declaration must use UTF-8")
    upper = text.upper()
    if "<!DOCTYPE" in upper or "<!ENTITY" in upper:
        raise ContractValidationError("DAV XML declarations are forbidden")

    chunks: list[dict[str, Any]] = []
    seen: set[str] = set()
    parser = ET.XMLPullParser(events=("start", "end"))
    tags: list[str] = []
    nodes = 0
    depth = 0
    root_seen = False
    response_hrefs: list[str | None] | None = None
    response_lengths: list[str | None] | None = None

    def process_events() -> None:
        nonlocal depth, nodes, root_seen, response_hrefs, response_lengths
        for event, node in parser.read_events():
            if event == "start":
                parent = tags[-1] if tags else None
                tags.append(node.tag)
                depth += 1
                nodes += 1
                if nodes > MAX_XML_NODES or depth > MAX_XML_DEPTH:
                    raise ContractValidationError("DAV XML structural budget exceeded")
                if not root_seen:
                    root_seen = True
                    if node.tag != f"{DAV_NAMESPACE}multistatus":
                        raise ContractValidationError(
                            "DAV response is not a multistatus"
                        )
                if (
                    node.tag == f"{DAV_NAMESPACE}response"
                    and parent == f"{DAV_NAMESPACE}multistatus"
                ):
                    if response_hrefs is not None:
                        raise ContractValidationError("DAV responses overlap")
                    response_hrefs = []
                    response_lengths = []
                continue

            parent = tags[-2] if len(tags) > 1 else None
            if response_hrefs is not None and response_lengths is not None:
                if node.tag == f"{DAV_NAMESPACE}href" and parent == (
                    f"{DAV_NAMESPACE}response"
                ):
                    response_hrefs.append(node.text)
                elif node.tag == f"{DAV_NAMESPACE}getcontentlength":
                    response_lengths.append(node.text)
                elif node.tag == f"{DAV_NAMESPACE}response" and parent == (
                    f"{DAV_NAMESPACE}multistatus"
                ):
                    if len(response_hrefs) != 1 or response_hrefs[0] is None:
                        raise ContractValidationError("DAV response lacks one href")
                    href = response_hrefs[0]
                    if len(href) > 4096 or CONTROL.search(href):
                        raise ContractValidationError("DAV href exceeds its bound")
                    name = unquote(href.rstrip("/").rsplit("/", 1)[-1])
                    if CHUNK_NAME.fullmatch(name) is not None:
                        if len(response_lengths) != 1 or response_lengths[0] is None:
                            raise ContractValidationError(
                                "DAV chunk lacks one content length"
                            )
                        length_text = response_lengths[0]
                        if not length_text.isascii() or not length_text.isdecimal():
                            raise ContractValidationError(
                                "DAV chunk length is not canonical"
                            )
                        length = require_integer(
                            int(length_text),
                            "DAV chunk length",
                            1,
                        )
                        if name in seen:
                            raise ContractValidationError(
                                "DAV multistatus repeats a chunk"
                            )
                        seen.add(name)
                        chunks.append({"name": name, "length": length})
                    response_hrefs = None
                    response_lengths = None
            node.clear()
            if not tags or tags[-1] != node.tag:
                raise ContractValidationError("DAV multistatus is malformed")
            tags.pop()
            depth -= 1

    try:
        for offset in range(0, len(text), 4096):
            parser.feed(text[offset : offset + 4096])
            process_events()
        parser.close()
        process_events()
    except ET.ParseError as error:
        raise ContractValidationError("DAV multistatus is malformed") from error
    if not root_seen or tags or depth != 0:
        raise ContractValidationError("DAV multistatus is malformed")
    chunks.sort(key=lambda item: item["name"])
    return chunks


def validate_dav_xml_fixtures(manifest: dict[str, Any]) -> int:
    fixtures = require_unique_ids(
        manifest.get("davXmlFixtures"),
        REQUIRED_DAV_XML_IDS,
        "DAV XML fixture",
    )
    for fixture in fixtures:
        raw = _safe_fixture_path(fixture.get("file"), ".xml").read_bytes()
        try:
            actual = parse_dav_multistatus_bytes(raw)
        except ContractValidationError:
            if fixture.get("expectedError") is True:
                continue
            raise
        if fixture.get("expectedError") is True:
            raise ContractValidationError(
                f"Negative DAV XML fixture {fixture['id']} unexpectedly succeeded"
            )
        expected = require_list(fixture.get("expectedChunks"), "expected chunks")
        if actual != expected:
            raise ContractValidationError(
                f"DAV XML fixture {fixture['id']} differs in chunk summary"
            )
    return len(fixtures)


def _dav_user_segment(value: Any) -> str:
    user_id = _safe_identifier(value, "DAV userId")
    return quote(user_id, safe="-._~@+")


def _dav_upload_id(value: Any) -> str:
    return _uuid(value, "DAV uploadId")


def _chunk_ranges(file_size: int, chunk_size: int) -> list[tuple[int, int]]:
    ranges: list[tuple[int, int]] = []
    start = 0
    while start < file_size:
        end = min(start + chunk_size, file_size) - 1
        ranges.append((start, end))
        start = end + 1
    return ranges


def _chunk_name(start: int, end: int) -> str:
    return f"{start:016d}-{end:016d}"


def _dav_upload_base(server: str, user: str, upload_id: str) -> str:
    return f"{server}/remote.php/dav/uploads/{user}/{upload_id}"


def _dav_file_uri(server: str, user: str, encoded_path: str) -> str:
    return f"{server}/remote.php/dav/files/{user}/{encoded_path}"


def build_dav_plan(kind: str, raw_input: Any) -> dict[str, Any]:
    input_value = require_object(raw_input, "DAV plan input")
    account_id = _safe_identifier(input_value.get("accountId"), "DAV accountId")
    server = normalize_server(input_value.get("server"))
    user = _dav_user_segment(input_value.get("userId"))
    binding = {"accountId": account_id, "server": server}
    if kind == "cleanupChunk":
        upload_id = _dav_upload_id(input_value.get("uploadId"))
        return {
            "binding": binding,
            "method": "DELETE",
            "uri": _dav_upload_base(server, user, upload_id),
            "headers": {},
            "successStatuses": [204, 404],
        }
    if kind == "cleanupDraft":
        _, encoded_path = normalize_relative_path(input_value.get("draftPath"))
        return {
            "binding": binding,
            "method": "DELETE",
            "uri": _dav_file_uri(server, user, encoded_path),
            "headers": {},
            "successStatuses": [204, 404],
        }
    if kind != "upload":
        raise ContractValidationError("Unknown DAV plan kind")
    _, encoded_path = normalize_relative_path(input_value.get("draftPath"))
    upload_id = _dav_upload_id(input_value.get("uploadId"))
    file_size = require_integer(input_value.get("fileSize"), "fileSize", 1)
    threshold = require_integer(
        input_value.get("chunkThreshold"),
        "chunkThreshold",
        1,
    )
    chunk_size = require_integer(input_value.get("chunkSize"), "chunkSize", 1)
    existing = require_list(input_value.get("existingChunks"), "existingChunks")
    destination = _dav_file_uri(server, user, encoded_path)
    if file_size <= threshold:
        if existing:
            raise ContractValidationError("Normal upload cannot carry chunk state")
        return {
            "binding": binding,
            "mode": "normal",
            "steps": [
                {
                    "method": "PUT",
                    "uri": destination,
                    "headers": {
                        "Content-Length": str(file_size),
                        "Content-Type": "application/octet-stream",
                    },
                    "contentStart": 0,
                    "contentLength": file_size,
                    "successStatuses": [201, 204],
                }
            ],
        }

    ranges = _chunk_ranges(file_size, chunk_size)
    expected_ranges = {
        _chunk_name(start, end): end - start + 1 for start, end in ranges
    }
    existing_names: set[str] = set()
    for raw_chunk in existing:
        chunk = require_object(raw_chunk, "existing chunk")
        if set(chunk) != {"name", "length"}:
            raise ContractValidationError("Existing chunk has an unknown member")
        name = require_string(chunk.get("name"), "existing chunk name", maximum=33)
        length = require_integer(chunk.get("length"), "existing chunk length", 1)
        if name not in expected_ranges or expected_ranges[name] != length:
            raise ContractValidationError("Existing chunk does not match the byte plan")
        if name in existing_names:
            raise ContractValidationError("Existing chunk is duplicated")
        existing_names.add(name)

    upload_base = _dav_upload_base(server, user, upload_id)
    steps: list[dict[str, Any]] = [
        {
            "method": "MKCOL",
            "uri": upload_base,
            "headers": {},
            "successStatuses": [201, 405],
        },
        {
            "method": "PROPFIND",
            "uri": upload_base,
            "headers": {"Depth": "1"},
            "successStatuses": [207],
        },
    ]
    for start, end in ranges:
        name = _chunk_name(start, end)
        if name in existing_names:
            continue
        length = end - start + 1
        steps.append(
            {
                "method": "PUT",
                "uri": f"{upload_base}/{name}",
                "headers": {"Content-Length": str(length)},
                "contentStart": start,
                "contentLength": length,
                "successStatuses": [201, 204],
            }
        )
    steps.append(
        {
            "method": "MOVE",
            "uri": f"{upload_base}/.file",
            "headers": {
                "Destination": destination,
                "OC-Total-Length": str(file_size),
            },
            "successStatuses": [201, 204],
        }
    )
    for step in steps:
        headers = require_object(step["headers"], "DAV step headers")
        if "Range" in headers or "Content-Range" in headers:
            raise ContractValidationError(
                "Chunk PUT must not emit an HTTP range header"
            )
        if step["method"] == "MOVE":
            source = urlsplit(step["uri"])
            target = urlsplit(headers["Destination"])
            if (source.scheme, source.netloc) != (target.scheme, target.netloc):
                raise ContractValidationError("MOVE Destination crosses server origin")
            if headers.get("OC-Total-Length") != str(file_size):
                raise ContractValidationError("MOVE lacks OC-Total-Length")
    return {"binding": binding, "mode": "chunked", "steps": steps}


def classify_dav_status(method: Any, status: Any) -> str:
    normalized_method = require_string(method, "DAV method", maximum=16).upper()
    normalized_status = require_integer(status, "DAV status", 100, 599)
    success = {
        "MKCOL": {201, 405},
        "PROPFIND": {207},
        "PUT": {201, 204},
        "MOVE": {201, 204},
        "DELETE": {204, 404},
    }
    if normalized_method not in success:
        raise ContractValidationError("Unsupported DAV method")
    if normalized_status in success[normalized_method]:
        return "success"
    if normalized_method == "MOVE" and normalized_status == 400:
        return "deterministic-failure"
    if normalized_status in {401, 403, 409, 412, 413, 422, 507}:
        return "deterministic-failure"
    return "transient-failure"


def validate_dav_cases(path: Path) -> tuple[int, int]:
    root = require_object(load_json(path), path.name)
    if root.get("upstreamCoreShas") != EXPECTED_CORE_SHAS:
        raise ContractValidationError(
            "DAV cases are not bound to the approved core SHAs"
        )
    plans = require_unique_ids(root.get("plans"), REQUIRED_DAV_PLAN_IDS, "DAV plan")
    for case in plans:
        try:
            actual = build_dav_plan(
                require_string(case.get("kind"), "DAV plan kind"),
                case.get("input"),
            )
        except ContractValidationError:
            if case.get("expectedError") is True:
                continue
            raise
        if case.get("expectedError") is True:
            raise ContractValidationError(
                f"Negative DAV plan {case['id']} unexpectedly succeeded"
            )
        expected = require_object(case.get("expected"), "DAV plan expectation")
        if actual != expected:
            raise ContractValidationError(
                f"DAV plan {case['id']} differs in bounded wire output"
            )

    statuses = require_unique_ids(
        root.get("statusCases"),
        REQUIRED_DAV_STATUS_IDS,
        "DAV status case",
    )
    for case in statuses:
        actual = classify_dav_status(case.get("method"), case.get("status"))
        expected = require_string(case.get("expected"), "DAV status expectation")
        if actual != expected:
            raise ContractValidationError(
                f"DAV status case {case['id']} has an unexpected classification"
            )
    return len(plans), len(statuses)


ATTACHMENT_PHASES = {
    "cancelled",
    "cancelling",
    "cleanupFailed",
    "completed",
    "draftResolved",
    "failed",
    "finalizing",
    "localPrepared",
    "probing",
    "retryable",
    "uploaded",
    "uploading",
    "awaitingConfirmation",
}
RETRY_PHASES = {"localPrepared", "probing", "draftResolved", "uploading", "uploaded"}


def _validate_source(value: Any) -> dict[str, Any]:
    source = require_object(value, "durable source")
    if set(source) != {"handle", "size", "sha256", "mime", "displayName"}:
        raise ContractValidationError("Durable source has an unknown member")
    _safe_identifier(source.get("handle"), "source handle")
    require_integer(source.get("size"), "source size", 1)
    checksum = require_string(source.get("sha256"), "source checksum", maximum=64)
    if SHA256.fullmatch(checksum) is None:
        raise ContractValidationError("Source checksum is not canonical SHA-256")
    mime = require_string(source.get("mime"), "source MIME", maximum=128)
    if "/" not in mime or mime.startswith("/") or mime.endswith("/"):
        raise ContractValidationError("Source MIME is invalid")
    _validate_filename(source.get("displayName"), "source display name")
    return source


def validate_operation(value: Any) -> dict[str, Any]:
    operation = require_object(value, "attachment operation")
    required = {
        "accountId",
        "allowUpdate",
        "attemptCount",
        "capabilityGeneration",
        "cleanupRequired",
        "expectedMessageType",
        "finalizationDispatched",
        "jobId",
        "lane",
        "lastOutcome",
        "messageIds",
        "phase",
        "referenceId",
        "remoteTempPath",
        "replayContractRevision",
        "resumePhase",
        "roomToken",
        "server",
        "source",
        "sourceVerified",
    }
    if set(operation) != required:
        raise ContractValidationError(
            "Attachment operation shape differs from contract"
        )
    _safe_identifier(operation.get("accountId"), "operation accountId")
    operation["server"] = normalize_server(operation.get("server"))
    require_integer(
        operation.get("capabilityGeneration"),
        "capabilityGeneration",
        1,
    )
    revision = require_string(
        operation.get("replayContractRevision"),
        "replayContractRevision",
        maximum=128,
    )
    if revision != "talk-attachment-f2958bb-core-a0bf541-a599620-r1":
        raise ContractValidationError(
            "Operation replay contract revision is unsupported"
        )
    _uuid(operation.get("jobId"), "jobId")
    _conversation_token(operation.get("roomToken"))
    _uuid(operation.get("referenceId"), "referenceId")
    expected_message_type = _expected_message_type(operation.get("expectedMessageType"))
    allow_update = require_boolean(operation.get("allowUpdate"), "allowUpdate")
    if allow_update:
        raise ContractValidationError(
            "This contract revision requires allowUpdate=false"
        )
    phase = require_string(operation.get("phase"), "operation phase", maximum=32)
    if phase not in ATTACHMENT_PHASES:
        raise ContractValidationError("Attachment operation phase is unknown")
    lane = require_string(operation.get("lane"), "account lane", maximum=32)
    if lane not in {"ready", "reauthRequired"}:
        raise ContractValidationError("Attachment account lane is unknown")
    require_integer(operation.get("attemptCount"), "attemptCount", 0)
    finalization_dispatched = require_boolean(
        operation.get("finalizationDispatched"),
        "finalizationDispatched",
    )
    cleanup_required = require_boolean(
        operation.get("cleanupRequired"),
        "cleanupRequired",
    )
    source_verified = require_boolean(
        operation.get("sourceVerified"),
        "sourceVerified",
    )
    remote_path = operation.get("remoteTempPath")
    if remote_path is not None:
        normalize_relative_path(remote_path)
    resume_phase = operation.get("resumePhase")
    if phase == "retryable":
        if resume_phase not in RETRY_PHASES:
            raise ContractValidationError(
                "Retryable operation lacks a valid resume phase"
            )
    elif resume_phase is not None:
        raise ContractValidationError(
            "Only retryable operation may have a resume phase"
        )
    if finalization_dispatched and phase not in {"awaitingConfirmation", "completed"}:
        raise ContractValidationError(
            "Finalization dispatch flag contradicts operation phase"
        )
    if (
        phase
        in {
            "draftResolved",
            "uploading",
            "uploaded",
            "finalizing",
            "awaitingConfirmation",
            "completed",
            "cancelling",
            "cleanupFailed",
        }
        and remote_path is None
    ):
        raise ContractValidationError("Attachment phase requires a remote temp path")
    if phase in {"cancelling", "cleanupFailed"} and not cleanup_required:
        raise ContractValidationError("Cleanup phase lacks cleanupRequired")
    if phase == "cancelled" and (cleanup_required or remote_path is not None):
        raise ContractValidationError(
            "Cancelled operation retained remote cleanup state"
        )
    if source_verified and not (
        phase == "draftResolved"
        or (phase == "retryable" and resume_phase == "uploading")
    ):
        raise ContractValidationError("Source verification is stale for this phase")
    raw_message_ids = require_list(operation.get("messageIds"), "messageIds")
    message_ids = [
        require_integer(message_id, "messageId", 1) for message_id in raw_message_ids
    ]
    if len(message_ids) != len(set(message_ids)):
        raise ContractValidationError("Attachment confirmation ids must be unique")
    if phase == "completed" and len(message_ids) != 1:
        raise ContractValidationError("Completed attachment needs one confirmation")
    if phase != "completed" and len(message_ids) == 1:
        raise ContractValidationError(
            "Single confirmation must complete the attachment"
        )
    require_string(operation.get("lastOutcome"), "lastOutcome", maximum=64)
    source = _validate_source(operation.get("source"))
    if expected_message_type == "voice-message" and not source[
        "mime"
    ].lower().startswith("audio/"):
        raise ContractValidationError("Voice attachment source must use an audio MIME")
    return operation


def _transition_binding_matches(
    operation: dict[str, Any],
    step: dict[str, Any],
) -> bool:
    if "binding" not in step:
        return False
    binding = require_object(step.get("binding"), "transition binding")
    if set(binding) != {"accountId", "server", "roomToken"}:
        raise ContractValidationError("Transition binding shape differs from contract")
    return (
        _safe_identifier(binding.get("accountId"), "binding accountId")
        == operation["accountId"]
        and normalize_server(binding.get("server")) == operation["server"]
        and _conversation_token(binding.get("roomToken")) == operation["roomToken"]
    )


def _authority_matches(operation: dict[str, Any], value: Any) -> bool:
    authority = require_object(value, "replay authority")
    if set(authority) != {
        "accountId",
        "server",
        "capabilityGeneration",
        "replayContractRevision",
    }:
        raise ContractValidationError("Replay authority shape differs from contract")
    return (
        _safe_identifier(authority.get("accountId"), "authority accountId")
        == operation["accountId"]
        and normalize_server(authority.get("server")) == operation["server"]
        and require_integer(
            authority.get("capabilityGeneration"),
            "authority capabilityGeneration",
            1,
        )
        == operation["capabilityGeneration"]
        and require_string(
            authority.get("replayContractRevision"),
            "authority replayContractRevision",
            maximum=128,
        )
        == operation["replayContractRevision"]
    )


def _confirmation_ids(
    operation: dict[str, Any],
    value: Any,
) -> list[int]:
    raw_confirmations = require_list(value, "attachment confirmations")
    all_ids: set[int] = set()
    matches: list[int] = []
    for raw_confirmation in raw_confirmations:
        confirmation = require_object(raw_confirmation, "attachment confirmation")
        if set(confirmation) != {
            "accountId",
            "server",
            "roomToken",
            "referenceId",
            "systemMessage",
            "messageType",
            "messageId",
        }:
            raise ContractValidationError("Attachment confirmation shape differs")
        message_id = require_integer(
            confirmation.get("messageId"),
            "confirmation messageId",
            1,
        )
        if message_id in all_ids:
            raise ContractValidationError("Confirmation input repeats a message id")
        all_ids.add(message_id)
        if (
            _safe_identifier(confirmation.get("accountId"), "confirmation accountId")
            == operation["accountId"]
            and normalize_server(confirmation.get("server")) == operation["server"]
            and _conversation_token(confirmation.get("roomToken"))
            == operation["roomToken"]
            and _uuid(confirmation.get("referenceId"), "confirmation referenceId")
            == operation["referenceId"]
            and confirmation.get("systemMessage") == "file_shared"
            and require_string(
                confirmation.get("messageType"),
                "confirmation messageType",
                maximum=64,
            )
            == operation["expectedMessageType"]
        ):
            matches.append(message_id)
    return matches


def apply_state_step(operation: dict[str, Any], raw_step: Any) -> str:
    step = require_object(raw_step, "state step")
    action = require_string(step.get("action"), "state action", maximum=64)
    if not _transition_binding_matches(operation, step):
        return "rejected"
    phase = operation["phase"]

    if action == "probeStart":
        allow_update = require_boolean(step.get("allowUpdate"), "probe allowUpdate")
        if phase != "localPrepared" or allow_update != operation["allowUpdate"]:
            return "rejected"
        operation["phase"] = "probing"
        operation["lastOutcome"] = "probing"
        return "probing"
    if action == "probeSuccess":
        if phase != "probing":
            return "rejected"
        folder, _ = normalize_relative_path(step.get("folder"))
        operation["remoteTempPath"] = f"{folder}/{operation['jobId']}.upload"
        normalize_relative_path(operation["remoteTempPath"])
        operation["phase"] = "draftResolved"
        operation["lastOutcome"] = "draft-resolved"
        return "draft-resolved"
    if action == "uploadStart":
        if phase != "draftResolved" or not operation["sourceVerified"]:
            return "rejected"
        operation["sourceVerified"] = False
        operation["phase"] = "uploading"
        operation["attemptCount"] += 1
        operation["lastOutcome"] = "uploading"
        return "uploading"
    if action == "uploadSuccess":
        if phase != "uploading":
            return "rejected"
        operation["phase"] = "uploaded"
        operation["lastOutcome"] = "uploaded"
        return "uploaded"
    if action == "finalizeStart":
        allow_update = require_boolean(step.get("allowUpdate"), "finalize allowUpdate")
        if phase != "uploaded" or allow_update != operation["allowUpdate"]:
            return "rejected"
        operation["phase"] = "finalizing"
        operation["attemptCount"] += 1
        operation["lastOutcome"] = "finalizing"
        return "finalizing"
    if action == "finalizeTransportFailure":
        if phase != "finalizing":
            return "rejected"
        body_state = require_string(step.get("bodyState"), "bodyState", maximum=32)
        if body_state == "not-sent":
            operation["phase"] = "retryable"
            operation["resumePhase"] = "uploaded"
            operation["lastOutcome"] = "retryable"
            return "retryable"
        if body_state == "possibly-sent":
            operation["phase"] = "awaitingConfirmation"
            operation["finalizationDispatched"] = True
            operation["lastOutcome"] = "awaiting-confirmation"
            return "awaiting-confirmation"
        raise ContractValidationError("Unknown finalize transport body state")
    if action == "finalizeHttp":
        if phase != "finalizing":
            return "rejected"
        status = require_integer(step.get("status"), "finalize HTTP status", 100, 599)
        ocs_status = require_integer(
            step.get("ocsStatus"), "finalize OCS status", 0, 999
        )
        if status == 200 and ocs_status == 200:
            operation["phase"] = "awaitingConfirmation"
            operation["finalizationDispatched"] = True
            operation["lastOutcome"] = "awaiting-confirmation"
            return "awaiting-confirmation"
        if status == 401 and ocs_status == 401:
            operation["phase"] = "retryable"
            operation["resumePhase"] = "uploaded"
            operation["lane"] = "reauthRequired"
            operation["lastOutcome"] = "reauth-required"
            return "reauth-required"
        if status == ocs_status and status in {400, 403, 404, 422, 501, 507}:
            operation["phase"] = "failed"
            operation["cleanupRequired"] = True
            operation["lastOutcome"] = "failed"
            return "failed"
        operation["phase"] = "awaitingConfirmation"
        operation["finalizationDispatched"] = True
        operation["lastOutcome"] = "awaiting-confirmation"
        return "awaiting-confirmation"
    if action == "restart":
        if phase == "finalizing":
            operation["phase"] = "awaitingConfirmation"
            operation["finalizationDispatched"] = True
            operation["lastOutcome"] = "awaiting-confirmation"
            return "awaiting-confirmation"
        if phase == "uploading":
            operation["phase"] = "retryable"
            operation["resumePhase"] = "uploading"
            operation["lastOutcome"] = "retryable"
            return "retryable"
        if phase == "probing":
            operation["phase"] = "retryable"
            operation["resumePhase"] = "localPrepared"
            operation["lastOutcome"] = "retryable"
            return "retryable"
        return "unchanged"
    if action == "retry":
        if (
            phase != "retryable"
            or operation["lane"] != "ready"
            or not _authority_matches(operation, step.get("authority"))
        ):
            return "rejected"
        resume_phase = operation["resumePhase"]
        if resume_phase == "uploading" and not operation["sourceVerified"]:
            return "rejected"
        operation["sourceVerified"] = False
        operation["phase"] = resume_phase
        operation["resumePhase"] = None
        operation["lastOutcome"] = resume_phase
        return resume_phase
    if action == "confirm":
        if phase != "awaitingConfirmation":
            return "rejected"
        matches = _confirmation_ids(operation, step.get("matches"))
        operation["messageIds"] = matches
        if not matches:
            operation["lastOutcome"] = "no-match"
            return "no-match"
        if len(matches) == 1:
            operation["phase"] = "completed"
            operation["lastOutcome"] = "completed"
            return "completed"
        operation["lastOutcome"] = "ambiguous-match"
        return "ambiguous-match"
    if action == "blindFinalizeReplay":
        return "rejected"
    if action == "cancel":
        if phase in {"finalizing", "awaitingConfirmation", "completed"}:
            return "rejected"
        if phase in {"cancelled", "cancelling", "cleanupFailed"}:
            return "unchanged"
        operation["phase"] = "cancelling"
        operation["resumePhase"] = None
        operation["cleanupRequired"] = True
        operation["lastOutcome"] = "cleanup-required"
        return "cleanup-required"
    if action == "cleanupSuccess":
        if phase != "cancelling":
            return "rejected"
        operation["phase"] = "cancelled"
        operation["remoteTempPath"] = None
        operation["cleanupRequired"] = False
        operation["lastOutcome"] = "cancelled"
        return "cancelled"
    if action == "cleanupFailure":
        if phase != "cancelling":
            return "rejected"
        operation["phase"] = "cleanupFailed"
        operation["lastOutcome"] = "cleanup-failed"
        return "cleanup-failed"
    if action == "cleanupRetry":
        if phase != "cleanupFailed":
            return "rejected"
        operation["phase"] = "cancelling"
        operation["lastOutcome"] = "cleanup-required"
        return "cleanup-required"
    if action == "sourceCheck":
        if not (
            phase == "draftResolved"
            or (phase == "retryable" and operation["resumePhase"] == "uploading")
        ):
            return "rejected"
        size = require_integer(step.get("size"), "observed source size", 1)
        checksum = require_string(
            step.get("sha256"),
            "observed source checksum",
            maximum=64,
        )
        if SHA256.fullmatch(checksum) is None:
            raise ContractValidationError("Observed checksum is not SHA-256")
        source = require_object(operation["source"], "durable source")
        if size == source["size"] and checksum == source["sha256"]:
            operation["sourceVerified"] = True
            operation["lastOutcome"] = "source-valid"
            return "source-valid"
        operation["sourceVerified"] = False
        operation["phase"] = "failed"
        operation["cleanupRequired"] = operation["remoteTempPath"] is not None
        operation["lastOutcome"] = "source-mismatch"
        return "failed"
    raise ContractValidationError("Unknown attachment state action")


def _operation_summary(operation: dict[str, Any]) -> dict[str, Any]:
    return {field: deepcopy(operation[field]) for field in STATE_SUMMARY_FIELDS}


def state_summary_mismatch_message(
    case_id: str,
    actual: Any,
    expected: Any,
) -> str:
    fields = safe_mapping_mismatch_fields(
        actual,
        expected,
        STATE_SUMMARY_FIELDS,
    )
    return f"State case {case_id} differs in operation fields: " + ", ".join(fields)


def validate_state_cases(path: Path) -> int:
    root = require_object(load_json(path), path.name)
    base = validate_operation(deepcopy(root.get("baseOperation")))
    default_binding = require_object(root.get("defaultBinding"), "default binding")
    if not _transition_binding_matches(base, {"binding": default_binding}):
        raise ContractValidationError(
            "Default state binding differs from base operation"
        )
    cases = require_unique_ids(root.get("cases"), REQUIRED_STATE_IDS, "state case")
    for case in cases:
        operation = deepcopy(base)
        if "initial" in case:
            initial = require_object(case.get("initial"), "initial state overrides")
            if set(initial).difference(operation):
                raise ContractValidationError(
                    "Initial state override has an unknown member"
                )
            operation.update(deepcopy(initial))
        validate_operation(operation)
        for raw_step in require_list(case.get("steps"), "state steps"):
            step = deepcopy(require_object(raw_step, "state step"))
            step.setdefault("binding", deepcopy(default_binding))
            before = deepcopy(operation)
            actual_outcome = apply_state_step(operation, step)
            expected_outcome = require_string(
                step.get("expectedOutcome"),
                "expected state outcome",
                maximum=64,
            )
            if actual_outcome != expected_outcome:
                raise ContractValidationError(
                    f"State case {case['id']} has an unexpected step outcome"
                )
            if actual_outcome == "rejected" and operation != before:
                raise ContractValidationError(
                    "Rejected state transition changed operation"
                )
            validate_operation(operation)
        expected = require_object(case.get("expected"), "state expectation")
        actual = _operation_summary(operation)
        if actual != expected:
            raise ContractValidationError(
                state_summary_mismatch_message(case["id"], actual, expected)
            )
    return len(cases)


def _case_file(manifest: dict[str, Any], field: str) -> Path:
    return _safe_fixture_path(manifest.get(field), ".json")


def _validate_manifest_files(manifest: dict[str, Any]) -> None:
    referenced = {
        "manifest.json",
        "capability.cases.json",
        "dav.cases.json",
        "state.cases.json",
        "wire.cases.json",
    }
    for fixture in require_list(manifest.get("fixtures"), "manifest fixtures"):
        entry = require_object(fixture, "manifest fixture")
        referenced.add(require_string(entry.get("file"), "fixture file", maximum=255))
    for fixture in require_list(manifest.get("davXmlFixtures"), "DAV XML fixtures"):
        entry = require_object(fixture, "DAV XML fixture")
        referenced.add(require_string(entry.get("file"), "DAV XML file", maximum=255))
    actual = {
        path.name
        for path in FIXTURE_ROOT.iterdir()
        if path.is_file() and path.suffix.lower() in {".json", ".xml"}
    }
    if actual != referenced:
        raise ContractValidationError(
            "Fixture inventory mismatch; "
            f"missing={sorted(referenced - actual)}, "
            f"unreferenced={sorted(actual - referenced)}"
        )


def validate_contract() -> dict[str, int]:
    document = require_object(load_json(CONTRACT_ROOT / "openapi.json"), "OpenAPI")
    validate(document)
    if document.get("openapi") != "3.1.0":
        raise ContractValidationError("Contract must remain OpenAPI 3.1.0")
    if document.get("x-upstream-talk-sha") != EXPECTED_TALK_SHA:
        raise ContractValidationError("OpenAPI is not bound to the approved Talk SHA")
    if document.get("x-upstream-core-shas") != EXPECTED_CORE_SHAS:
        raise ContractValidationError("OpenAPI is not bound to the approved core SHAs")

    manifest = require_object(load_json(MANIFEST_PATH), "manifest")
    if manifest.get("upstreamTalkSha") != EXPECTED_TALK_SHA:
        raise ContractValidationError("Manifest Talk SHA differs from the contract")
    if manifest.get("upstreamCoreShas") != EXPECTED_CORE_SHAS:
        raise ContractValidationError("Manifest core SHAs differ from the contract")
    contract_path = (
        FIXTURE_ROOT / require_string(manifest.get("contract"), "contract path")
    ).resolve()
    if contract_path != (CONTRACT_ROOT / "openapi.json").resolve():
        raise ContractValidationError("Manifest must resolve to the local openapi.json")

    fixtures = require_unique_ids(
        manifest.get("fixtures"),
        REQUIRED_FIXTURE_IDS,
        "manifest fixture",
    )
    fixture_results = [validate_fixture(document, fixture) for fixture in fixtures]
    probe_request = next(
        fixture for fixture in fixtures if fixture["id"] == "probe-request"
    )
    finalize_request = next(
        fixture for fixture in fixtures if fixture["id"] == "finalize-request"
    )
    probe_body = require_object(
        load_json(_safe_fixture_path(probe_request["file"], ".json")),
        "probe request",
    )
    finalize_body = require_object(
        load_json(_safe_fixture_path(finalize_request["file"], ".json")),
        "finalize request",
    )
    if (
        probe_body.get("allowUpdate") is not False
        or finalize_body.get("allowUpdate") is not False
    ):
        raise ContractValidationError("Both Talk requests must carry allowUpdate=false")
    if probe_body["allowUpdate"] != finalize_body["allowUpdate"]:
        raise ContractValidationError("allowUpdate changed across the attachment job")

    capability_count = validate_capability_cases(
        _case_file(manifest, "capabilityCasesFile")
    )
    wire_count = validate_wire_cases(document, _case_file(manifest, "wireCasesFile"))
    dav_plan_count, dav_status_count = validate_dav_cases(
        _case_file(manifest, "davCasesFile")
    )
    state_count = validate_state_cases(_case_file(manifest, "stateCasesFile"))
    dav_xml_count = validate_dav_xml_fixtures(manifest)
    _validate_manifest_files(manifest)
    return {
        "fixtures": len(fixture_results),
        "capabilityCases": capability_count,
        "wireCases": wire_count,
        "davPlans": dav_plan_count,
        "davStatuses": dav_status_count,
        "davXmlFixtures": dav_xml_count,
        "stateCases": state_count,
    }


def main() -> int:
    try:
        counts = validate_contract()
    except Exception as error:  # noqa: BLE001 - command boundary reports one safe line
        print(f"attachment-upload contract: FAILED ({type(error).__name__}: {error})")
        return 1
    summary = ", ".join(f"{name}={count}" for name, count in counts.items())
    print(f"attachment-upload contract: OK ({summary})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
