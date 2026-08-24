from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
import uuid
from copy import deepcopy
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlencode, urlsplit, urlunsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from jsonschema import Draft202012Validator, FormatChecker
from openapi_spec_validator import validate_spec


CONTRACT_ROOT = Path(__file__).resolve().parent
FIXTURE_ROOT = CONTRACT_ROOT / "fixtures"
MANIFEST_PATH = FIXTURE_ROOT / "manifest.json"
CHAT_PATH = "/ocs/v2.php/apps/spreed/api/v1/chat"
USER_AGENT = "com.nkshub.nextcloudtalk chat-messages-contract/0.1"
TEXT_SEND_REVISION = "talk-chat-text-send-f2958bb-f9b9e947-r2"
MAX_LIVE_RESPONSE_BYTES = 8 * 1024 * 1024
MAX_RETRY_AFTER_SECONDS = 24 * 60 * 60
BASE_RATE_LIMIT_RETRY_SECONDS = 5
MAX_RATE_LIMIT_BACKOFF_SECONDS = 5 * 60
SEND_CONTEXT_FIELDS = (
    "roomToken",
    "referenceId",
    "replyTo",
    "threadId",
    "replyToToken",
    "parentRoomToken",
)
OUTBOX_SUMMARY_FIELDS = (
    "state",
    "attemptCount",
    "messageIds",
    "duplicateRiskAcknowledged",
    "errorClass",
    "nextAttemptAt",
    "replyTo",
    "threadId",
    "replyToToken",
    "parentRoomToken",
)
DECIMAL_CURSOR = re.compile(r"^(0|[1-9][0-9]*)$")
CONVERSATION_TOKEN = re.compile(r"^[a-z0-9]{4,30}$")
REFERENCE_ID = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-"
    r"[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
)
ENV_NAME = re.compile(r"^[A-Z][A-Z0-9_]{1,127}$")
SCHEMA_PATH_MEMBER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

REQUIRED_FIXTURE_IDS = {
    "common-read-only",
    "chat-rate-limited",
    "chat-unavailable",
    "duplicate-message-id",
    "duplicate-reference-id",
    "future-page",
    "future-timeout",
    "history-exhausted",
    "history-page",
    "invisible-cursor-advance",
    "mark-unread-success",
    "mark-unread-first-message",
    "mark-unread-unauthorized",
    "missing-cursor",
    "ocs-failure",
    "read-marker-success",
    "read-marker-unauthorized",
    "send-bad-request",
    "send-confirmation-page",
    "send-cross-room-reply-request",
    "send-cross-room-reply-success",
    "send-forbidden",
    "send-internal-error",
    "send-invalid-reply",
    "send-named-thread-request",
    "send-named-thread-success",
    "send-plain-thread-mismatch",
    "send-null",
    "send-not-found",
    "send-ocs-statuscode-mismatch",
    "send-rate-limited",
    "send-rate-limited-retry-after",
    "send-reference-mismatch",
    "send-reply-request",
    "send-reply-success",
    "send-success",
    "send-text-request",
    "send-token-mismatch",
    "send-too-large",
    "send-unauthorized",
    "send-unavailable",
    "send-whitespace-request",
    "set-read-marker-request",
    "thread-future-page",
    "thread-not-found",
    "token-mismatch",
    "unauthorized",
}
REQUIRED_QUERY_IDS = {
    "background-catch-up",
    "background-without-keep-notifications-rejected",
    "backward-history",
    "cross-room-private-reply-outside-slice-rejected",
    "federated-private-reply-rejected",
    "federated-thread-rejected",
    "foreground-catch-up",
    "foreground-long-poll",
    "initial-history",
    "leading-zero-cursor-rejected",
    "mark-unread",
    "negative-cursor-rejected",
    "overlong-reference-rejected",
    "oversized-limit-rejected",
    "read-without-explicit-capability-rejected",
    "send-reply",
    "send-mixed-reply-thread-rejected",
    "send-named-thread",
    "send-named-thread-without-capability-rejected",
    "send-text",
    "set-read-marker",
    "thread-catch-up",
    "whitespace-message-rejected",
    "zero-anchor-history",
}
REQUIRED_CAPABILITY_IDS = {
    "all-federated-features",
    "all-local-features",
    "chat-v2-only",
    "duplicate-feature-is-invalid",
    "explicit-read-only",
    "mark-unread-only",
    "missing-chat-v2",
    "release-only-is-unsupported",
    "safe-text-send",
    "same-room-reply-only",
}
REQUIRED_MERGE_IDS = {
    "account-scope-isolated",
    "common-read-only-keeps-cursors",
    "duplicate-id-rolls-back",
    "duplicate-reference-remains-distinct",
    "future-304-confirms-convergence",
    "future-uses-header-cursor",
    "history-304-ends-history",
    "history-and-future-blocks-merge",
    "history-uses-header-cursor",
    "invisible-message-advances-future",
    "missing-cursor-rolls-back",
    "mark-unread-sentinel-is-preserved",
    "ocs-failure-keeps-state",
    "rate-limited-get-keeps-state",
    "read-and-unread-are-explicit",
    "read-unauthorized-pauses-only-target-account",
    "stale-future-anchor-rolls-back",
    "thread-scope-isolated",
    "token-mismatch-rolls-back",
    "transaction-failure-rolls-back",
    "unauthorized-pauses-account",
    "unavailable-get-keeps-state",
    "unread-unauthorized-pauses-only-target-account",
}
REQUIRED_OUTBOX_IDS = {
    "account-scope-isolated",
    "ambiguous-bad-request-enters-awaiting-confirmation",
    "auth-failure-preserves-operation-state-matrix",
    "catch-up-absence-keeps-awaiting",
    "completed-late-multiple-matches-reports-conflict",
    "confirmation-transaction-failure-rolls-back",
    "cross-room-reply-admission-rejected",
    "deterministic-rejection-fails",
    "duplicate-local-reference-rejects-admission",
    "duplicate-reference-stays-ambiguous",
    "http-confirmation-context-mismatch-rejected",
    "manual-resend-requires-duplicate-warning",
    "manual-resend-respects-scheduler",
    "manual-resend-with-server-matches-is-rejected",
    "missing-capability-rejects-admission",
    "missing-reply-token-rejects-admission",
    "named-thread-admission-and-claim",
    "named-thread-admission-guards",
    "named-thread-manual-resend-quarantine-is-atomic",
    "named-thread-r1-replay-rejected",
    "named-thread-reconciliation-is-thread-bound",
    "named-thread-survives-restart",
    "null-response-enters-awaiting-confirmation",
    "per-room-ordering-and-single-flight",
    "possible-send-never-auto-replays",
    "plain-operation-does-not-match-thread-message",
    "pre-body-failure-is-retryable",
    "queued-claim-and-http-confirmation",
    "rate-limit-local-backoff-is-retryable",
    "rate-limit-retry-after-is-retryable",
    "reauth-pauses-only-target-account",
    "reference-mismatch-enters-awaiting-confirmation",
    "relay-before-http-is-idempotent",
    "reply-metadata-survives-restart",
    "restart-sending-needs-reconciliation",
    "revision-mismatch-rejects-admission",
    "server-error-enters-awaiting-confirmation",
    "single-catch-up-message-completes",
    "successful-admission",
    "token-mismatch-enters-awaiting-confirmation",
    "unknown-kind-rejects-admission",
    "whitespace-admission-rejected",
    "zero-message-catch-up-keeps-awaiting",
}


class ContractValidationError(RuntimeError):
    pass


class ResponseSemanticError(ContractValidationError):
    pass


class NoRedirectHandler(HTTPRedirectHandler):
    def redirect_request(
        self,
        request: Request,
        file_pointer: Any,
        code: int,
        message: str,
        headers: Any,
        new_url: str,
    ) -> None:
        return None


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def require_object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ContractValidationError(f"{label} must be an object")
    return value


def require_list(value: Any, label: str) -> list[Any]:
    if not isinstance(value, list):
        raise ContractValidationError(f"{label} must be an array")
    return value


def require_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise ContractValidationError(f"{label} must be a non-empty string")
    return value


def message_text(value: Any, label: str) -> str:
    message = require_string(value, label)
    if not message.strip():
        raise ContractValidationError(
            f"{label} must contain a non-whitespace character"
        )
    return message


def require_integer(value: Any, label: str, minimum: int | None = None) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ContractValidationError(f"{label} must be an integer")
    if minimum is not None and value < minimum:
        raise ContractValidationError(f"{label} must be at least {minimum}")
    return value


def require_boolean(value: Any, label: str) -> bool:
    if not isinstance(value, bool):
        raise ContractValidationError(f"{label} must be boolean")
    return value


def require_unique_ids(
    cases: list[Any],
    required_ids: set[str],
    label: str,
) -> list[dict[str, Any]]:
    values: list[dict[str, Any]] = []
    ids: list[str] = []
    for raw_case in cases:
        case = require_object(raw_case, label)
        case_id = require_string(case.get("id"), f"{label} id")
        ids.append(case_id)
        values.append(case)
    if len(ids) != len(set(ids)):
        raise ContractValidationError(f"{label} ids must be unique")
    if set(ids) != required_ids:
        raise ContractValidationError(
            f"{label} coverage mismatch; "
            f"missing={sorted(required_ids - set(ids))}, "
            f"unexpected={sorted(set(ids) - required_ids)}"
        )
    return values


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


def outbox_summary_mismatch_message(
    case_id: str,
    actual: Any,
    expected: Any,
) -> str:
    mismatched_fields = safe_mapping_mismatch_fields(
        actual,
        expected,
        OUTBOX_SUMMARY_FIELDS,
    )
    return f"Outbox case {case_id} differs in operation fields: " + ", ".join(
        mismatched_fields
    )


def canonical_cursor(value: Any, label: str) -> str:
    if (
        not isinstance(value, str)
        or DECIMAL_CURSOR.fullmatch(value) is None
        or len(value) > 20
    ):
        raise ContractValidationError(
            f"{label} must be a canonical non-negative decimal cursor"
        )
    return value


def conversation_token(value: Any, label: str) -> str:
    if not isinstance(value, str) or CONVERSATION_TOKEN.fullmatch(value) is None:
        raise ContractValidationError(f"{label} must be a canonical room token")
    return value


def reference_id(value: Any, label: str) -> str:
    if not isinstance(value, str) or REFERENCE_ID.fullmatch(value) is None:
        raise ContractValidationError(f"{label} must be a lowercase UUID")
    return value


def operation_id(value: Any, label: str) -> str:
    raw = require_string(value, label)
    try:
        parsed = uuid.UUID(raw)
    except ValueError as error:
        raise ContractValidationError(f"{label} must be a UUID") from error
    if str(parsed) != raw or parsed.version != 4:
        raise ContractValidationError(f"{label} must be a canonical UUIDv4")
    return raw


def resolve_pointer(document: dict[str, Any], reference: str) -> Any:
    if not reference.startswith("#/"):
        raise ContractValidationError(
            f"Only local references are supported: {reference}"
        )
    current: Any = document
    for raw_part in reference[2:].split("/"):
        part = raw_part.replace("~1", "/").replace("~0", "~")
        try:
            current = current[part]
        except (KeyError, TypeError) as error:
            raise ContractValidationError(
                f"Unresolvable reference: {reference}"
            ) from error
    return current


def expand_references(
    value: Any,
    document: dict[str, Any],
    reference_stack: tuple[str, ...] = (),
) -> Any:
    if isinstance(value, list):
        return [expand_references(item, document, reference_stack) for item in value]
    if not isinstance(value, dict):
        return value
    if "$ref" in value:
        reference = require_string(value["$ref"], "$ref")
        if reference in reference_stack:
            raise ContractValidationError(
                f"Circular reference is not supported: {reference}"
            )
        target = deepcopy(resolve_pointer(document, reference))
        siblings = {key: item for key, item in value.items() if key != "$ref"}
        if siblings:
            target_object = require_object(target, f"reference {reference}")
            target_object.update(siblings)
            target = target_object
        return expand_references(
            target,
            document,
            reference_stack + (reference,),
        )
    return {
        key: expand_references(item, document, reference_stack)
        for key, item in value.items()
    }


def find_operation(
    document: dict[str, Any],
    operation_id_value: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    for raw_path_item in document.get("paths", {}).values():
        path_item = require_object(raw_path_item, "OpenAPI path item")
        for method, raw_operation in path_item.items():
            if method.lower() not in {"get", "post", "put", "patch", "delete"}:
                continue
            operation = require_object(raw_operation, "OpenAPI operation")
            if operation.get("operationId") == operation_id_value:
                return path_item, operation
    raise ContractValidationError(f"Unknown operationId: {operation_id_value}")


def response_definition(
    document: dict[str, Any],
    operation: dict[str, Any],
    status: str,
) -> dict[str, Any]:
    response = operation.get("responses", {}).get(status)
    if not isinstance(response, dict):
        raise ContractValidationError(f"Operation has no response status {status}")
    return require_object(
        expand_references(response, document),
        f"response {status}",
    )


def response_schema(
    document: dict[str, Any],
    operation: dict[str, Any],
    status: str,
    media_type: str,
) -> dict[str, Any]:
    response = response_definition(document, operation, status)
    try:
        schema = response["content"][media_type]["schema"]
    except KeyError as error:
        raise ContractValidationError(
            f"Response {status} has no {media_type} schema"
        ) from error
    return require_object(schema, f"response {status} schema")


def request_body_schema(
    document: dict[str, Any],
    operation: dict[str, Any],
    media_type: str,
) -> dict[str, Any]:
    try:
        schema = operation["requestBody"]["content"][media_type]["schema"]
    except KeyError as error:
        raise ContractValidationError(
            f"Operation has no {media_type} request schema"
        ) from error
    return require_object(
        expand_references(schema, document),
        "request body schema",
    )


def schema_property_names(schema: dict[str, Any]) -> set[str]:
    names: set[str] = set()

    def visit(value: Any) -> None:
        if isinstance(value, dict):
            properties = value.get("properties")
            if isinstance(properties, dict):
                names.update(
                    name
                    for name in properties
                    if isinstance(name, str)
                    and SCHEMA_PATH_MEMBER.fullmatch(name) is not None
                )
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(schema)
    return names


def summarize_schema_error(error: Any, safe_members: set[str]) -> str:
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
    safe_members = schema_property_names(schema)
    return [
        summarize_schema_error(error, safe_members)
        for error in sorted(
            validator.iter_errors(instance),
            key=lambda item: tuple(str(member) for member in item.absolute_path),
        )
    ]


def lookup_header(headers: dict[str, str], name: str) -> str | None:
    matching = [value for key, value in headers.items() if key.lower() == name.lower()]
    if len(matching) > 1:
        raise ContractValidationError(f"Header {name} is present more than once")
    return matching[0] if matching else None


def validate_response_headers(
    document: dict[str, Any],
    operation: dict[str, Any],
    status: str,
    headers: dict[str, str],
) -> None:
    response = response_definition(document, operation, status)
    declared = require_object(response.get("headers", {}), "response headers")
    for name, raw_definition in declared.items():
        definition = require_object(raw_definition, f"header {name}")
        value = lookup_header(headers, name)
        if definition.get("required", False) and value is None:
            raise ContractValidationError(f"Required response header {name} is absent")
        if value is None:
            continue
        schema = require_object(definition.get("schema"), f"header {name} schema")
        errors = validate_json_schema(value, schema)
        if errors:
            raise ContractValidationError(
                f"Header {name} violates its schema: " + "; ".join(errors)
            )


def header_sets(manifest: dict[str, Any]) -> dict[str, dict[str, str]]:
    raw_sets = require_object(manifest.get("headerSets"), "header sets")
    result: dict[str, dict[str, str]] = {}
    for set_id, raw_headers in raw_sets.items():
        headers = require_object(raw_headers, f"header set {set_id}")
        if any(
            not isinstance(key, str) or not isinstance(value, str)
            for key, value in headers.items()
        ):
            raise ContractValidationError(
                f"Header set {set_id} must contain string names and values"
            )
        result[set_id] = headers
    return result


def ocs_parts(instance: Any) -> tuple[dict[str, Any], Any]:
    root = require_object(instance, "OCS response")
    ocs = require_object(root.get("ocs"), "OCS envelope")
    meta = require_object(ocs.get("meta"), "OCS metadata")
    return meta, ocs.get("data")


def validate_message_list(
    raw_messages: Any,
    context: dict[str, Any],
) -> list[dict[str, Any]]:
    messages = require_list(raw_messages, "chat message data")
    room_token = conversation_token(context.get("roomToken"), "fixture roomToken")
    direction = require_string(context.get("direction"), "fixture direction")
    if direction not in {"history", "future"}:
        raise ResponseSemanticError(f"Unknown chat direction {direction}")
    thread_id = context.get("threadId")
    if thread_id is not None:
        thread_id = require_integer(thread_id, "fixture threadId", 1)

    typed: list[dict[str, Any]] = []
    ids: list[int] = []
    for index, raw_message in enumerate(messages):
        message = require_object(raw_message, f"message {index}")
        message_id = require_integer(message.get("id"), f"message {index} id", 1)
        if message.get("token") != room_token:
            raise ResponseSemanticError(
                f"Message {index} token does not match its room"
            )
        if thread_id is not None and message.get("threadId") != thread_id:
            raise ResponseSemanticError(
                f"Message {index} does not belong to the requested thread"
            )
        ids.append(message_id)
        typed.append(message)
    if len(ids) != len(set(ids)):
        raise ResponseSemanticError("Chat response contains duplicate message ids")
    if direction == "history" and ids != sorted(ids, reverse=True):
        raise ResponseSemanticError("History response is not strictly descending")
    if direction == "future" and ids != sorted(ids):
        raise ResponseSemanticError("Future response is not strictly ascending")
    return typed


def classify_get_response(
    instance: Any,
    status: str,
    headers: dict[str, str],
    context: dict[str, Any],
) -> dict[str, Any]:
    if status == "304":
        if instance is not None:
            raise ResponseSemanticError("HTTP 304 must not carry a JSON body")
        return {
            "classification": "not-modified",
            "messages": [],
            "cursor": None,
            "commonRead": None,
        }
    if status == "401":
        return {
            "classification": "reauth",
            "messages": [],
            "cursor": None,
            "commonRead": None,
        }
    if status == "404":
        return {
            "classification": "thread-not-found",
            "messages": [],
            "cursor": None,
            "commonRead": None,
        }
    if status in {"429", "503"}:
        return {
            "classification": "transient-error",
            "messages": [],
            "cursor": None,
            "commonRead": None,
        }
    if status != "200":
        raise ResponseSemanticError(f"Unsupported GET fixture status {status}")

    meta, raw_data = ocs_parts(instance)
    if meta.get("status") != "ok" or meta.get("statuscode") != 200:
        return {
            "classification": "ocs-error",
            "messages": [],
            "cursor": None,
            "commonRead": None,
        }
    messages = validate_message_list(raw_data, context)
    raw_cursor = lookup_header(headers, "X-Chat-Last-Given")
    cursor = canonical_cursor(raw_cursor, "X-Chat-Last-Given") if raw_cursor else None
    raw_common_read = lookup_header(headers, "X-Chat-Last-Common-Read")
    common_read = (
        canonical_cursor(raw_common_read, "X-Chat-Last-Common-Read")
        if raw_common_read
        else None
    )
    direction = context["direction"]
    if messages and cursor is None:
        raise ResponseSemanticError("Visible chat messages require a response cursor")
    if messages:
        ids = [message["id"] for message in messages]
        if direction == "history" and int(cursor) > min(ids):
            raise ResponseSemanticError("History cursor moved in the wrong direction")
        if direction == "future" and int(cursor) < max(ids):
            raise ResponseSemanticError("Future cursor moved in the wrong direction")
        classification = "messages"
    elif cursor is not None:
        classification = "invisible-cursor-advance"
    elif common_read is not None:
        classification = "common-read-only"
    else:
        raise ResponseSemanticError(
            "HTTP 200 empty chat response has neither cursor nor common-read change"
        )
    return {
        "classification": classification,
        "messages": messages,
        "cursor": cursor,
        "commonRead": common_read,
    }


def classify_send_response(
    instance: Any,
    status: str,
    context: dict[str, Any],
    headers: dict[str, str],
) -> dict[str, Any]:
    meta, raw_data = ocs_parts(instance)
    error_code = raw_data.get("error") if isinstance(raw_data, dict) else None
    if status == "401":
        return {"classification": "reauth", "messages": [], "messageId": None}
    if status == "429" and error_code == "mentions":
        raw_retry_after = lookup_header(headers, "Retry-After")
        retry_after_seconds = None
        if raw_retry_after is not None and DECIMAL_CURSOR.fullmatch(raw_retry_after):
            retry_after_seconds = min(
                int(raw_retry_after),
                MAX_RETRY_AFTER_SECONDS,
            )
        return {
            "classification": "rate-limited",
            "messages": [],
            "messageId": None,
            "retryAfterSeconds": retry_after_seconds,
        }
    if (
        (status in {"400", "403"} and error_code == "reply-to")
        or (status == "404" and error_code == "actor")
        or (status == "413" and error_code == "message")
    ):
        return {
            "classification": "deterministic-failure",
            "messages": [],
            "messageId": None,
        }
    if status == "400" and error_code == "message":
        return {
            "classification": "send-ambiguous",
            "messages": [],
            "messageId": None,
        }
    if status != "201" or meta.get("status") != "ok" or meta.get("statuscode") != 201:
        return {"classification": "server-error", "messages": [], "messageId": None}
    if raw_data is None:
        return {
            "classification": "send-unconfirmed",
            "messages": [],
            "messageId": None,
        }
    message = require_object(raw_data, "send response message")
    expected_token = conversation_token(context.get("roomToken"), "send roomToken")
    expected_reference = reference_id(
        context.get("referenceId"),
        "send referenceId",
    )
    if (
        message.get("token") != expected_token
        or message.get("referenceId") != expected_reference
    ):
        return {
            "classification": "send-unconfirmed",
            "messages": [message],
            "messageId": None,
        }
    message_id = require_integer(message.get("id"), "send message id", 1)

    reply_to = context.get("replyTo")
    thread_id = context.get("threadId")
    if thread_id is not None:
        thread_id = require_integer(thread_id, "send threadId", 1)
        if reply_to is not None:
            raise ResponseSemanticError("Send context mixes replyTo and threadId")
    if thread_id is not None:
        if message.get("parent") is not None:
            raise ResponseSemanticError("Named-thread response does not match context")
    elif reply_to is not None:
        reply_to = require_integer(reply_to, "send replyTo", 1)
        parent = require_object(message.get("parent"), "send reply parent")
        parent_token = conversation_token(
            context.get("parentRoomToken"),
            "send parentRoomToken",
        )
        if parent.get("token") != parent_token:
            raise ResponseSemanticError("Reply parent token does not match context")
        reply_to_token = context.get("replyToToken")
        if reply_to_token is None:
            if parent.get("id") != reply_to:
                raise ResponseSemanticError("Same-room reply parent id is wrong")
        else:
            reply_to_token = conversation_token(reply_to_token, "send replyToToken")
            metadata = require_object(parent.get("metaData"), "private reply metadata")
            if (
                metadata.get("replyToMessageId") != reply_to
                or metadata.get("replyToConversationToken") != reply_to_token
            ):
                raise ResponseSemanticError("Private reply metadata is incomplete")
    elif message.get("parent") is not None:
        raise ResponseSemanticError("Plain send unexpectedly returned a reply parent")
    if not direct_send_message_has_expected_thread_semantics(
        message,
        requested_thread_id=thread_id,
        reply_to=reply_to,
        private_reply=context.get("replyToToken") is not None,
    ):
        raise ResponseSemanticError("Send response thread does not match context")
    return {
        "classification": "send-confirmed",
        "messages": [message],
        "messageId": message_id,
    }


def classify_read_response(
    instance: Any,
    status: str,
    operation_id_value: str,
    context: dict[str, Any],
    headers: dict[str, str],
) -> dict[str, Any]:
    if status == "401":
        return {"classification": "reauth", "room": None, "messages": []}
    if status != "200":
        return {"classification": "ocs-error", "room": None, "messages": []}
    meta, raw_data = ocs_parts(instance)
    if meta.get("status") != "ok" or meta.get("statuscode") != 200:
        return {"classification": "ocs-error", "room": None, "messages": []}
    room = require_object(raw_data, "read marker room")
    expected_token = conversation_token(context.get("roomToken"), "read roomToken")
    if room.get("token") != expected_token:
        raise ResponseSemanticError("Read marker room token does not match context")
    if operation_id_value == "setChatReadMarker":
        expected_last_read = require_integer(
            context.get("lastReadMessage"),
            "read lastReadMessage",
            1,
        )
        if room.get("lastReadMessage") != expected_last_read:
            raise ResponseSemanticError(
                "Read marker did not confirm its explicit target"
            )
        classification = "read-confirmed"
    else:
        classification = "unread-confirmed"
    common_read = lookup_header(headers, "X-Chat-Last-Common-Read")
    if common_read is not None:
        canonical_cursor(common_read, "X-Chat-Last-Common-Read")
        if int(common_read) != room.get("lastCommonReadMessage"):
            raise ResponseSemanticError("Read response header and room disagree")
    return {"classification": classification, "room": room, "messages": []}


def classify_fixture(
    fixture: dict[str, Any],
    instance: Any,
    headers: dict[str, str],
) -> dict[str, Any]:
    direction = require_string(fixture.get("direction"), "fixture direction")
    if direction == "request":
        return {"classification": "request-valid", "messages": []}
    operation_id_value = require_string(
        fixture.get("operationId"),
        "fixture operationId",
    )
    status = require_string(fixture.get("status"), "fixture status")
    context = require_object(fixture.get("context", {}), "fixture context")
    if operation_id_value == "getChatMessages":
        return classify_get_response(instance, status, headers, context)
    if operation_id_value == "sendChatMessage":
        return classify_send_response(instance, status, context, headers)
    if operation_id_value in {"setChatReadMarker", "markChatUnread"}:
        return classify_read_response(
            instance,
            status,
            operation_id_value,
            context,
            headers,
        )
    raise ContractValidationError(
        f"Fixture uses unsupported operation {operation_id_value}"
    )


def validate_fixture(
    document: dict[str, Any],
    fixture: dict[str, Any],
    sets: dict[str, dict[str, str]],
) -> dict[str, Any]:
    fixture_path = (
        FIXTURE_ROOT / require_string(fixture.get("file"), "fixture file")
    ).resolve()
    if fixture_path.parent != FIXTURE_ROOT or fixture_path.suffix != ".json":
        raise ContractValidationError(f"Invalid fixture path {fixture_path.name}")
    instance = load_json(fixture_path)
    _, operation = find_operation(
        document,
        require_string(fixture.get("operationId"), "fixture operationId"),
    )
    direction = require_string(fixture.get("direction"), "fixture direction")
    media_type = fixture.get("mediaType")
    expected_schema_valid = fixture.get("schemaValid")
    if not isinstance(expected_schema_valid, bool):
        raise ContractValidationError(
            f"Fixture {fixture['id']} needs a boolean schemaValid"
        )

    if direction == "request":
        schema = request_body_schema(
            document,
            operation,
            require_string(media_type, "fixture media type"),
        )
        errors = validate_json_schema(instance, schema)
        headers: dict[str, str] = {}
    elif direction == "response":
        status = require_string(fixture.get("status"), "fixture status")
        if status == "304":
            errors = [] if instance is None else ["$ [null-body]"]
        else:
            schema = response_schema(
                document,
                operation,
                status,
                require_string(media_type, "fixture media type"),
            )
            errors = validate_json_schema(instance, schema)
        header_set_id = require_string(fixture.get("headerSet"), "fixture header set")
        try:
            headers = sets[header_set_id]
        except KeyError as error:
            raise ContractValidationError(
                f"Unknown header set {header_set_id}"
            ) from error
        validate_response_headers(document, operation, status, headers)
    else:
        raise ContractValidationError(f"Unknown fixture direction {direction}")

    if expected_schema_valid and errors:
        raise ContractValidationError(
            f"Fixture {fixture['id']} violates its schema: " + "; ".join(errors)
        )
    if not expected_schema_valid and not errors:
        raise ContractValidationError(
            f"Negative fixture {fixture['id']} was accepted by its schema"
        )
    if not expected_schema_valid:
        return {"classification": "schema-error", "messages": []}

    try:
        result = classify_fixture(fixture, instance, headers)
    except ResponseSemanticError:
        result = {"classification": "semantic-error", "messages": []}
    expected_classification = require_string(
        fixture.get("expectedClassification"),
        "fixture expected classification",
    )
    if result["classification"] != expected_classification:
        raise ContractValidationError(
            f"Fixture {fixture['id']} classified as {result['classification']}, "
            f"expected {expected_classification}"
        )
    if "expectedMessageCount" in fixture:
        expected_count = require_integer(
            fixture["expectedMessageCount"],
            "expectedMessageCount",
            0,
        )
        if len(result.get("messages", [])) != expected_count:
            raise ContractValidationError(
                f"Fixture {fixture['id']} returned "
                f"{len(result.get('messages', []))} messages, expected {expected_count}"
            )
    if (
        "expectedCursor" in fixture
        and result.get("cursor") != fixture["expectedCursor"]
    ):
        raise ContractValidationError(
            f"Fixture {fixture['id']} cursor is {result.get('cursor')}, "
            f"expected {fixture['expectedCursor']}"
        )
    if (
        "expectedMessageId" in fixture
        and result.get("messageId") != fixture["expectedMessageId"]
    ):
        raise ContractValidationError(
            f"Fixture {fixture['id']} message id is {result.get('messageId')}, "
            f"expected {fixture['expectedMessageId']}"
        )
    result["instance"] = instance
    result["headers"] = headers
    return result


def normalize_features(value: Any, label: str) -> set[str]:
    features = require_list(value, label)
    if any(not isinstance(feature, str) or not feature for feature in features):
        raise ContractValidationError(f"{label} must contain non-empty strings")
    if len(features) != len(set(features)):
        raise ContractValidationError(f"{label} must not contain duplicates")
    return set(features)


def resolve_capabilities(features: set[str], federated: bool) -> dict[str, bool]:
    read = "chat-v2" in features
    send_text = read and "chat-reference-id" in features
    reply = send_text and "chat-replies" in features
    return {
        "read": read,
        "sendText": send_text,
        "reply": reply,
        "privateReply": reply and "private-reply" in features and not federated,
        "backgroundCatchUp": read and "chat-keep-notifications" in features,
        "threadFetch": read and "threads" in features and not federated,
        "setReadMarker": (
            read and "chat-read-marker" in features and "chat-read-last" in features
        ),
        "markUnread": (
            read and "chat-read-marker" in features and "chat-unread" in features
        ),
    }


def build_wire_request(
    kind: str,
    raw_input: Any,
    raw_capabilities: Any,
) -> dict[str, Any]:
    input_value = require_object(raw_input, "query case input")
    features = normalize_features(raw_capabilities, "query case capabilities")
    headers = {"OCS-APIRequest": "true", "User-Agent": USER_AGENT}
    query: dict[str, str] = {"format": "json"}
    body: dict[str, Any] | None = None

    if kind == "fetch":
        if "chat-v2" not in features:
            raise ContractValidationError("Chat read requires chat-v2")
        direction = require_string(input_value.get("direction"), "fetch direction")
        if direction not in {"history", "future"}:
            raise ContractValidationError(f"Unknown fetch direction {direction}")
        cursor = canonical_cursor(input_value.get("cursor"), "fetch cursor")
        common_read = canonical_cursor(
            input_value.get("lastCommonRead"),
            "fetch lastCommonRead",
        )
        limit = require_integer(input_value.get("limit"), "fetch limit", 1)
        if limit > 200:
            raise ContractValidationError("Fetch limit exceeds 200")
        interactive = require_boolean(
            input_value.get("interactive"),
            "fetch interactive",
        )
        include_last_known = input_value.get("includeLastKnown", False)
        require_boolean(include_last_known, "fetch includeLastKnown")
        timeout = input_value.get("timeout", 0)
        timeout = require_integer(timeout, "fetch timeout", 0)
        if timeout > 30 or (direction == "history" and timeout != 0):
            raise ContractValidationError("Fetch timeout is invalid")
        if not interactive and "chat-keep-notifications" not in features:
            raise ContractValidationError(
                "Background catch-up requires chat-keep-notifications"
            )
        query.update(
            {
                "lookIntoFuture": "1" if direction == "future" else "0",
                "limit": str(limit),
                "lastKnownMessageId": cursor,
                "lastCommonReadId": common_read,
                "timeout": str(timeout),
                "setReadMarker": "0",
                "includeLastKnown": "1" if include_last_known else "0",
                "noStatusUpdate": "0" if interactive else "1",
                "markNotificationsAsRead": "1" if interactive else "0",
            }
        )
        thread_id = input_value.get("threadId")
        if thread_id is not None:
            thread_id = require_integer(thread_id, "fetch threadId", 1)
            federated = require_boolean(
                input_value.get("federated", False),
                "fetch federated",
            )
            if federated or "threads" not in features:
                raise ContractValidationError(
                    "Thread fetch is unsupported for this conversation"
                )
            query["threadId"] = str(thread_id)
        return {
            "method": "GET",
            "query": query,
            "headers": headers,
            "body": None,
            "operationId": "getChatMessages",
        }

    if kind == "send":
        if not {"chat-v2", "chat-reference-id"}.issubset(features):
            raise ContractValidationError(
                "Text send requires chat-v2 and chat-reference-id"
            )
        message = message_text(input_value.get("message"), "send message")
        send_reference = reference_id(
            input_value.get("referenceId"), "send referenceId"
        )
        federated = require_boolean(
            input_value.get("federated", False),
            "send federated",
        )
        body = {"message": message, "referenceId": send_reference}
        reply_to = input_value.get("replyTo")
        thread_id = input_value.get("threadId")
        if thread_id is not None:
            thread_id = require_integer(thread_id, "send threadId", 1)
            if reply_to is not None:
                raise ContractValidationError("Send cannot mix replyTo and threadId")
            if federated or "threads" not in features:
                raise ContractValidationError(
                    "Named-thread send requires local threads capability"
                )
            body["threadId"] = thread_id
        if reply_to is not None:
            reply_to = require_integer(reply_to, "send replyTo", 1)
            if "chat-replies" not in features:
                raise ContractValidationError("Reply requires chat-replies")
            parent_token = conversation_token(
                input_value.get("parentRoomToken"),
                "send parentRoomToken",
            )
            target_token = conversation_token(
                input_value.get("targetRoomToken"),
                "send targetRoomToken",
            )
            body["replyTo"] = reply_to
            if parent_token != target_token:
                if federated:
                    raise ContractValidationError(
                        "Federated cross-room private reply is unsupported"
                    )
                raise ContractValidationError(
                    "Cross-room private reply needs a separate eligibility contract"
                )
        elif any(
            key in input_value
            for key in ("parentRoomToken", "targetRoomToken", "replyToToken")
        ):
            raise ContractValidationError("Reply metadata requires replyTo")
        return {
            "method": "POST",
            "query": query,
            "headers": headers,
            "body": body,
            "operationId": "sendChatMessage",
        }

    if kind == "read":
        resolved = resolve_capabilities(features, False)
        if not resolved["setReadMarker"]:
            raise ContractValidationError(
                "Explicit read requires chat-read-marker and chat-read-last"
            )
        body = {
            "lastReadMessage": require_integer(
                input_value.get("lastReadMessage"),
                "read lastReadMessage",
                1,
            )
        }
        return {
            "method": "POST",
            "query": query,
            "headers": headers,
            "body": body,
            "operationId": "setChatReadMarker",
        }

    if kind == "unread":
        resolved = resolve_capabilities(features, False)
        if not resolved["markUnread"]:
            raise ContractValidationError(
                "Mark unread requires chat-read-marker and chat-unread"
            )
        if input_value:
            raise ContractValidationError("Mark unread does not accept a request body")
        return {
            "method": "DELETE",
            "query": query,
            "headers": headers,
            "body": None,
            "operationId": "markChatUnread",
        }
    raise ContractValidationError(f"Unknown request kind {kind}")


def request_parameters(
    document: dict[str, Any],
    operation: dict[str, Any],
) -> dict[tuple[str, str], dict[str, Any]]:
    result: dict[tuple[str, str], dict[str, Any]] = {}
    for raw_parameter in operation.get("parameters", []):
        parameter = require_object(
            expand_references(raw_parameter, document),
            "operation parameter",
        )
        key = (
            require_string(parameter.get("in"), "parameter location"),
            require_string(parameter.get("name"), "parameter name"),
        )
        if key in result:
            raise ContractValidationError(f"Duplicate OpenAPI parameter {key}")
        result[key] = parameter
    return result


def coerce_wire_value(value: str, schema: dict[str, Any], label: str) -> Any:
    value_type = schema.get("type")
    if value_type == "integer":
        if re.fullmatch(r"-?[0-9]+", value) is None:
            raise ContractValidationError(f"{label} is not an integer")
        return int(value)
    if value_type == "boolean":
        if value not in {"true", "false"}:
            raise ContractValidationError(f"{label} is not a lowercase boolean")
        return value == "true"
    if value_type == "string":
        return value
    raise ContractValidationError(f"Unsupported wire type {value_type} for {label}")


def validate_request_against_openapi(
    document: dict[str, Any],
    built: dict[str, Any],
) -> None:
    _, operation = find_operation(document, built["operationId"])
    parameters = request_parameters(document, operation)
    for location, actual in (
        ("query", require_object(built["query"], "built query")),
        ("header", require_object(built["headers"], "built headers")),
    ):
        declared = {
            name: parameter
            for (parameter_location, name), parameter in parameters.items()
            if parameter_location == location
        }
        normalized_actual = (
            actual
            if location == "query"
            else {key.lower(): value for key, value in actual.items()}
        )
        declared_lookup = (
            declared
            if location == "query"
            else {key.lower(): value for key, value in declared.items()}
        )
        if unexpected := sorted(set(normalized_actual) - set(declared_lookup)):
            if location == "header" and unexpected == ["user-agent"]:
                unexpected = []
            if unexpected:
                raise ContractValidationError(
                    f"Request emitted undeclared {location} values: {unexpected}"
                )
        for name, parameter in declared_lookup.items():
            if parameter.get("required") and name not in normalized_actual:
                raise ContractValidationError(
                    f"Request omitted required {location} value {name}"
                )
            if name not in normalized_actual:
                continue
            schema = require_object(
                expand_references(parameter.get("schema"), document),
                f"{location} {name} schema",
            )
            coerced = coerce_wire_value(
                normalized_actual[name],
                schema,
                f"{location} {name}",
            )
            errors = validate_json_schema(coerced, schema)
            if errors:
                raise ContractValidationError(
                    f"{location} {name} violates OpenAPI: " + "; ".join(errors)
                )

    body = built["body"]
    if body is None:
        if "requestBody" in operation:
            raise ContractValidationError("Request builder omitted a required body")
        return
    schema = request_body_schema(
        document,
        operation,
        "application/x-www-form-urlencoded",
    )
    errors = validate_json_schema(body, schema)
    if errors:
        raise ContractValidationError(
            "Request body violates OpenAPI: " + "; ".join(errors)
        )
    encoded = urlencode(body)
    parsed = parse_qs(encoded, keep_blank_values=True, strict_parsing=True)
    properties = require_object(schema.get("properties"), "request body properties")
    round_trip: dict[str, Any] = {}
    for name, values in parsed.items():
        if len(values) != 1:
            raise ContractValidationError(f"Form field {name} is repeated")
        property_schema = require_object(properties.get(name), f"form field {name}")
        round_trip[name] = coerce_wire_value(values[0], property_schema, name)
    if round_trip != body:
        raise ContractValidationError("Form round trip changed wire section: body")


def validate_query_cases(document: dict[str, Any], path: Path) -> int:
    root = require_object(load_json(path), path.name)
    cases = require_unique_ids(
        require_list(root.get("cases"), "query cases"),
        REQUIRED_QUERY_IDS,
        "query case",
    )
    for case in cases:
        try:
            built = build_wire_request(
                require_string(case.get("kind"), "query case kind"),
                case.get("input"),
                case.get("capabilities"),
            )
            validate_request_against_openapi(document, built)
        except ContractValidationError:
            if case.get("expectedError") is True:
                continue
            raise
        if case.get("expectedError") is True:
            raise ContractValidationError(
                f"Negative query case {case['id']} unexpectedly succeeded"
            )
        expected = require_object(case.get("expected"), "expected wire request")
        actual = {key: built[key] for key in ("method", "query", "headers", "body")}
        if actual != expected:
            mismatched_sections = safe_mapping_mismatch_fields(
                actual,
                expected,
                ("method", "query", "headers", "body"),
            )
            raise ContractValidationError(
                f"Query case {case['id']} differs in wire sections: "
                + ", ".join(mismatched_sections)
            )
    return len(cases)


def validate_capability_cases(path: Path) -> int:
    root = require_object(load_json(path), path.name)
    cases = require_unique_ids(
        require_list(root.get("cases"), "capability cases"),
        REQUIRED_CAPABILITY_IDS,
        "capability case",
    )
    for case in cases:
        try:
            features = normalize_features(
                case.get("talkFeatures"),
                "capability talkFeatures",
            )
            federated = require_boolean(
                case.get("federated"),
                "capability federated",
            )
            actual = resolve_capabilities(features, federated)
        except ContractValidationError:
            if case.get("expectedError") is True:
                continue
            raise
        if case.get("expectedError") is True:
            raise ContractValidationError(
                f"Negative capability case {case['id']} unexpectedly succeeded"
            )
        expected = require_object(case.get("expected"), "expected capabilities")
        if actual != expected:
            raise ContractValidationError(
                f"Capability case {case['id']} produced {actual}, expected {expected}"
            )
    return len(cases)


def scope_key(room_token: Any, thread_id: Any) -> str:
    token = conversation_token(room_token, "scope roomToken")
    if thread_id is None:
        return f"{token}#root"
    return f"{token}#{require_integer(thread_id, 'scope threadId', 1)}"


def normalize_blocks(value: Any, label: str) -> list[list[str]]:
    raw_blocks = require_list(value, label)
    blocks: list[list[str]] = []
    previous_end: int | None = None
    for index, raw_block in enumerate(raw_blocks):
        block = require_list(raw_block, f"{label} block {index}")
        if len(block) != 2:
            raise ContractValidationError(f"{label} block {index} needs two cursors")
        start = canonical_cursor(block[0], f"{label} block {index} start")
        end = canonical_cursor(block[1], f"{label} block {index} end")
        if int(start) > int(end):
            raise ContractValidationError(f"{label} block {index} is reversed")
        if previous_end is not None and int(start) <= previous_end:
            raise ContractValidationError(f"{label} blocks overlap")
        blocks.append([start, end])
        previous_end = int(end)
    if not blocks:
        raise ContractValidationError(f"{label} must not be empty")
    return blocks


def add_block(
    blocks: list[list[str]],
    start: str,
    end: str,
) -> list[list[str]]:
    intervals = [(int(block[0]), int(block[1])) for block in blocks]
    intervals.append((int(start), int(end)))
    intervals.sort()
    merged: list[list[int]] = []
    for interval_start, interval_end in intervals:
        if not merged or interval_start > merged[-1][1] + 1:
            merged.append([interval_start, interval_end])
        else:
            merged[-1][1] = max(merged[-1][1], interval_end)
    return [[str(block_start), str(block_end)] for block_start, block_end in merged]


def normalize_scope(value: Any, label: str) -> dict[str, Any]:
    raw_scope = require_object(value, label)
    raw_message_ids = require_list(raw_scope.get("messageIds"), f"{label} messageIds")
    message_ids = [
        require_integer(message_id, f"{label} message id", 1)
        for message_id in raw_message_ids
    ]
    if message_ids != sorted(set(message_ids)):
        raise ContractValidationError(
            f"{label} messageIds must be unique and ascending"
        )
    history_cursor = canonical_cursor(
        raw_scope.get("historyCursor"),
        f"{label} historyCursor",
    )
    future_cursor = canonical_cursor(
        raw_scope.get("futureCursor"),
        f"{label} futureCursor",
    )
    if int(history_cursor) > int(future_cursor):
        raise ContractValidationError(f"{label} cursors are reversed")
    blocks = normalize_blocks(raw_scope.get("blocks"), f"{label} blocks")
    if blocks[0][0] != history_cursor or blocks[-1][1] != future_cursor:
        raise ContractValidationError(f"{label} block boundaries disagree with cursors")
    for message_id in message_ids:
        if not any(
            int(block_start) <= message_id <= int(block_end)
            for block_start, block_end in blocks
        ):
            raise ContractValidationError(
                f"{label} message id is outside all authoritative blocks"
            )
    return {
        "messageIds": message_ids,
        "historyCursor": history_cursor,
        "futureCursor": future_cursor,
        "lastCommonRead": canonical_cursor(
            raw_scope.get("lastCommonRead"),
            f"{label} lastCommonRead",
        ),
        "lastReadMessage": require_integer(
            raw_scope.get("lastReadMessage"),
            f"{label} lastReadMessage",
            -2,
        ),
        "unreadMessages": require_integer(
            raw_scope.get("unreadMessages"),
            f"{label} unreadMessages",
            0,
        ),
        "hasHistory": require_boolean(
            raw_scope.get("hasHistory"),
            f"{label} hasHistory",
        ),
        "futureConverged": require_boolean(
            raw_scope.get("futureConverged"),
            f"{label} futureConverged",
        ),
        "blocks": blocks,
    }


def initialize_merge_state(raw_accounts: Any) -> dict[str, Any]:
    accounts = require_object(raw_accounts, "initial merge accounts")
    state: dict[str, Any] = {"accounts": {}}
    for account_id, raw_account in accounts.items():
        require_string(account_id, "merge accountId")
        account = require_object(raw_account, f"merge account {account_id}")
        lane_state = require_string(
            account.get("laneState"),
            f"merge account {account_id} laneState",
        )
        if lane_state not in {"ready", "reauthRequired"}:
            raise ContractValidationError(f"Unknown account lane {lane_state}")
        raw_scopes = require_object(
            account.get("scopes"),
            f"merge account {account_id} scopes",
        )
        scopes: dict[str, dict[str, Any]] = {}
        for raw_key, raw_scope in raw_scopes.items():
            key = require_string(raw_key, "merge scope key")
            try:
                raw_token, raw_thread = key.split("#", 1)
            except ValueError as error:
                raise ContractValidationError("Invalid merge scope key") from error
            expected_key = scope_key(
                raw_token,
                None
                if raw_thread == "root"
                else require_integer(
                    int(raw_thread),
                    "merge scope threadId",
                    1,
                ),
            )
            if expected_key != key:
                raise ContractValidationError("Non-canonical merge scope key")
            scopes[key] = normalize_scope(raw_scope, f"merge scope {key}")
        if not scopes:
            raise ContractValidationError(
                f"Merge account {account_id} must contain at least one scope"
            )
        state["accounts"][account_id] = {
            "laneState": lane_state,
            "scopes": scopes,
        }
    if not state["accounts"]:
        raise ContractValidationError("Merge state must contain an account")
    return state


def fixture_record(
    records: dict[str, dict[str, Any]],
    fixture_id: Any,
    label: str,
) -> dict[str, Any]:
    fixture_name = require_string(fixture_id, label)
    try:
        return records[fixture_name]
    except KeyError as error:
        raise ContractValidationError(
            f"{label} references unknown fixture {fixture_name}"
        ) from error


def update_common_read(scope: dict[str, Any], raw_value: Any) -> None:
    if raw_value is None:
        return
    value = canonical_cursor(raw_value, "merge common-read cursor")
    scope["lastCommonRead"] = value


def apply_sync_step(
    account: dict[str, Any],
    scope: dict[str, Any],
    step: dict[str, Any],
    record: dict[str, Any],
) -> str:
    metadata = record["metadata"]
    result = record["result"]
    if metadata.get("operationId") != "getChatMessages":
        raise ContractValidationError("Sync step needs a chat GET fixture")
    direction = require_string(step.get("direction"), "merge direction")
    if direction not in {"history", "future"}:
        raise ContractValidationError(f"Unknown merge direction {direction}")
    anchor = canonical_cursor(step.get("anchor"), "merge anchor")
    expected_anchor = scope[f"{direction}Cursor"]
    if anchor != expected_anchor:
        return "rejected"
    context = require_object(metadata.get("context"), "merge fixture context")
    if (
        context.get("roomToken") != step.get("roomToken")
        or context.get("direction") != direction
        or context.get("threadId") != step.get("threadId")
    ):
        raise ContractValidationError("Sync fixture context does not match its step")

    classification = result["classification"]
    if classification == "reauth":
        account["laneState"] = "reauthRequired"
        return "reauth-required"
    if account["laneState"] != "ready":
        return "rejected"
    if classification in {"ocs-error", "semantic-error", "thread-not-found"}:
        return "rejected"
    if classification == "not-modified":
        if direction == "history":
            scope["hasHistory"] = False
            return "history-exhausted"
        scope["futureConverged"] = True
        return "converged"
    if classification == "common-read-only":
        update_common_read(scope, result.get("commonRead"))
        return "common-read-updated"
    if classification not in {"messages", "invisible-cursor-advance"}:
        return "rejected"

    cursor = result.get("cursor")
    if cursor is None:
        return "rejected"
    cursor = canonical_cursor(cursor, "merge response cursor")
    if direction == "history" and int(cursor) > int(anchor):
        return "rejected"
    if direction == "future" and int(cursor) < int(anchor):
        return "rejected"
    message_ids = [message["id"] for message in result.get("messages", [])]
    scope["messageIds"] = sorted(set(scope["messageIds"]) | set(message_ids))
    if direction == "history":
        scope["historyCursor"] = cursor
        scope["blocks"] = add_block(scope["blocks"], cursor, anchor)
    else:
        scope["futureCursor"] = cursor
        scope["futureConverged"] = False
        scope["blocks"] = add_block(scope["blocks"], anchor, cursor)
    update_common_read(scope, result.get("commonRead"))
    return "applied"


def apply_read_step(
    account: dict[str, Any],
    scope: dict[str, Any],
    step_kind: str,
    step: dict[str, Any],
    record: dict[str, Any],
) -> str:
    expected_operation = (
        "setChatReadMarker" if step_kind == "read" else "markChatUnread"
    )
    metadata = record["metadata"]
    result = record["result"]
    if metadata.get("operationId") != expected_operation:
        raise ContractValidationError("Read fixture operation does not match its step")
    context = require_object(metadata.get("context"), "read fixture context")
    if context.get("roomToken") != step.get("roomToken"):
        raise ContractValidationError("Read fixture context does not match its step")
    expected_classification = (
        "read-confirmed" if step_kind == "read" else "unread-confirmed"
    )
    if result["classification"] == "reauth":
        account["laneState"] = "reauthRequired"
        return "reauth-required"
    if account["laneState"] != "ready":
        return "rejected"
    if result["classification"] != expected_classification:
        return "rejected"
    room = require_object(result.get("room"), "read result room")
    if room.get("token") != step.get("roomToken"):
        raise ContractValidationError("Read result targets another room")
    scope["lastReadMessage"] = require_integer(
        room.get("lastReadMessage"),
        "read result lastReadMessage",
        -2,
    )
    scope["unreadMessages"] = require_integer(
        room.get("unreadMessages"),
        "read result unreadMessages",
        0,
    )
    update_common_read(
        scope,
        str(
            require_integer(
                room.get("lastCommonReadMessage"),
                "read result lastCommonReadMessage",
                0,
            )
        ),
    )
    return "read-applied" if step_kind == "read" else "unread-applied"


def apply_merge_step(
    state: dict[str, Any],
    step: dict[str, Any],
    records: dict[str, dict[str, Any]],
) -> tuple[dict[str, Any], str]:
    account_id = require_string(step.get("accountId"), "merge accountId")
    if account_id not in state["accounts"]:
        raise ContractValidationError(f"Unknown merge account {account_id}")
    key = scope_key(step.get("roomToken"), step.get("threadId"))
    if key not in state["accounts"][account_id]["scopes"]:
        raise ContractValidationError("Unknown merge scope")
    transaction = require_string(step.get("transaction"), "merge transaction")
    if transaction not in {"commit", "fail"}:
        raise ContractValidationError(f"Unknown merge transaction {transaction}")
    record = fixture_record(records, step.get("fixture"), "merge fixture")
    before = deepcopy(state)
    candidate = deepcopy(state)
    account = candidate["accounts"][account_id]
    target_scope = account["scopes"][key]
    kind = require_string(step.get("kind"), "merge step kind")
    if kind == "sync":
        outcome = apply_sync_step(account, target_scope, step, record)
    elif kind in {"read", "unread"}:
        if step.get("threadId") is not None:
            raise ContractValidationError("Room read operations cannot target a thread")
        outcome = apply_read_step(account, target_scope, kind, step, record)
    else:
        raise ContractValidationError(f"Unknown merge step kind {kind}")

    if transaction == "fail" and outcome != "rejected":
        return before, "transaction-error"
    for other_account_id, other_account in before["accounts"].items():
        if other_account_id != account_id:
            if candidate["accounts"][other_account_id] != other_account:
                raise ContractValidationError("Merge crossed an account boundary")
            continue
        for other_key, other_scope in other_account["scopes"].items():
            if other_key != key and account["scopes"][other_key] != other_scope:
                raise ContractValidationError("Merge crossed a room/thread boundary")
    return candidate, outcome


def validate_merge_cases(
    path: Path,
    records: dict[str, dict[str, Any]],
) -> tuple[int, int]:
    root = require_object(load_json(path), path.name)
    cases = require_unique_ids(
        require_list(root.get("cases"), "merge cases"),
        REQUIRED_MERGE_IDS,
        "merge case",
    )
    step_count = 0
    for case in cases:
        state = initialize_merge_state(case.get("initialAccounts"))
        steps = require_list(case.get("steps"), f"merge case {case['id']} steps")
        if not steps:
            raise ContractValidationError(f"Merge case {case['id']} has no steps")
        for raw_step in steps:
            step = require_object(raw_step, "merge step")
            state, outcome = apply_merge_step(state, step, records)
            expected_outcome = require_string(
                step.get("expectedOutcome"),
                "expected merge outcome",
            )
            if outcome != expected_outcome:
                raise ContractValidationError(
                    f"Merge case {case['id']} returned {outcome}, "
                    f"expected {expected_outcome}"
                )
            account = state["accounts"][step["accountId"]]
            if account["laneState"] != step.get("expectedAccountLane"):
                raise ContractValidationError(
                    f"Merge case {case['id']} lane is {account['laneState']}, "
                    f"expected {step.get('expectedAccountLane')}"
                )
            key = scope_key(step.get("roomToken"), step.get("threadId"))
            expected_scope = normalize_scope(
                step.get("expectedScope"),
                "expected merge scope",
            )
            if account["scopes"][key] != expected_scope:
                raise ContractValidationError(
                    f"Merge case {case['id']} scope is {account['scopes'][key]}, "
                    f"expected {expected_scope}"
                )
            step_count += 1
    return len(cases), step_count


def normalize_outbox_operation(
    value: Any,
    label: str,
    require_state: bool,
) -> dict[str, Any]:
    raw_operation = require_object(value, label)
    normalized: dict[str, Any] = {
        "operationId": operation_id(raw_operation.get("operationId"), f"{label} id"),
        "operationKind": require_string(
            raw_operation.get("operationKind"),
            f"{label} kind",
        ),
        "roomToken": conversation_token(
            raw_operation.get("roomToken"),
            f"{label} roomToken",
        ),
        "referenceId": reference_id(
            raw_operation.get("referenceId"),
            f"{label} referenceId",
        ),
        "message": message_text(raw_operation.get("message"), f"{label} message"),
        "enqueueSequence": require_integer(
            raw_operation.get("enqueueSequence"),
            f"{label} enqueueSequence",
            1,
        ),
        "replayContractRevision": require_string(
            raw_operation.get("replayContractRevision"),
            f"{label} replayContractRevision",
        ),
    }
    reply_to = raw_operation.get("replyTo")
    thread_id = raw_operation.get("threadId")
    normalized["threadId"] = (
        require_integer(thread_id, f"{label} threadId", 1)
        if thread_id is not None
        else None
    )
    if reply_to is not None and normalized["threadId"] is not None:
        raise ContractValidationError(f"{label} cannot mix replyTo and threadId")
    parent_token = raw_operation.get("parentRoomToken")
    reply_token = raw_operation.get("replyToToken")
    if reply_to is None:
        if parent_token is not None or reply_token is not None:
            raise ContractValidationError(f"{label} reply metadata needs replyTo")
        normalized.update(
            {"replyTo": None, "replyToToken": None, "parentRoomToken": None}
        )
    else:
        normalized["replyTo"] = require_integer(reply_to, f"{label} replyTo", 1)
        normalized["parentRoomToken"] = conversation_token(
            parent_token,
            f"{label} parentRoomToken",
        )
        normalized["replyToToken"] = (
            conversation_token(reply_token, f"{label} replyToToken")
            if reply_token is not None
            else None
        )
        if (
            normalized["replyToToken"] is not None
            and normalized["replyToToken"] != normalized["parentRoomToken"]
        ):
            raise ContractValidationError(
                f"{label} replyToToken must preserve the parent room token"
            )
        is_cross_room = normalized["parentRoomToken"] != normalized["roomToken"]
        if is_cross_room != (normalized["replyToToken"] is not None):
            raise ContractValidationError(
                f"{label} cross-room reply needs replyToToken and same-room reply forbids it"
            )
    if not require_state:
        return normalized

    state = require_string(raw_operation.get("state"), f"{label} state")
    if state not in {
        "queued",
        "sending",
        "retryable",
        "awaitingConfirmation",
        "completed",
        "failed",
    }:
        raise ContractValidationError(f"Unknown outbox state {state}")
    attempt_count = require_integer(
        raw_operation.get("attemptCount"),
        f"{label} attemptCount",
        0,
    )
    raw_message_ids = raw_operation.get("messageIds", [])
    message_ids = [
        require_integer(message_id, f"{label} messageId", 1)
        for message_id in require_list(raw_message_ids, f"{label} messageIds")
    ]
    if message_ids != sorted(set(message_ids)):
        raise ContractValidationError(
            f"{label} messageIds must be unique and ascending"
        )
    error_class = raw_operation.get("errorClass")
    if error_class is not None and not isinstance(error_class, str):
        raise ContractValidationError(f"{label} errorClass must be string or null")
    next_attempt = raw_operation.get("nextAttemptAt")
    if next_attempt is not None:
        next_attempt = require_integer(
            next_attempt,
            f"{label} nextAttemptAt",
            0,
        )
    normalized.update(
        {
            "state": state,
            "attemptCount": attempt_count,
            "messageIds": message_ids,
            "duplicateRiskAcknowledged": require_boolean(
                raw_operation.get("duplicateRiskAcknowledged", False),
                f"{label} duplicateRiskAcknowledged",
            ),
            "errorClass": error_class,
            "nextAttemptAt": next_attempt,
        }
    )
    if state in {"sending", "retryable", "awaitingConfirmation"} and attempt_count < 1:
        raise ContractValidationError(f"{label} active state needs an attempt")
    if state == "completed" and not message_ids:
        raise ContractValidationError(f"{label} completed state needs a message id")
    if next_attempt is not None and state != "retryable":
        raise ContractValidationError(f"{label} retry time belongs only to retryable")
    return normalized


def initialize_outbox_state(raw_accounts: Any) -> dict[str, Any]:
    accounts = require_object(raw_accounts, "initial outbox accounts")
    state: dict[str, Any] = {"accounts": {}}
    for account_id, raw_account in accounts.items():
        require_string(account_id, "outbox accountId")
        account = require_object(raw_account, f"outbox account {account_id}")
        lane_state = require_string(
            account.get("laneState"),
            f"outbox account {account_id} laneState",
        )
        if lane_state not in {"ready", "reauthRequired"}:
            raise ContractValidationError(f"Unknown outbox lane {lane_state}")
        operations: dict[str, dict[str, Any]] = {}
        reference_ids: set[str] = set()
        room_sequences: set[tuple[str, int]] = set()
        for raw_operation in require_list(
            account.get("operations"),
            f"outbox account {account_id} operations",
        ):
            operation = normalize_outbox_operation(
                raw_operation,
                f"outbox account {account_id} operation",
                True,
            )
            if operation["operationId"] in operations:
                raise ContractValidationError(
                    f"Duplicate outbox operation {operation['operationId']}"
                )
            if operation["referenceId"] in reference_ids:
                raise ContractValidationError("Duplicate local outbox reference")
            room_sequence = (operation["roomToken"], operation["enqueueSequence"])
            if room_sequence in room_sequences:
                raise ContractValidationError("Duplicate outbox room sequence")
            operations[operation["operationId"]] = operation
            reference_ids.add(operation["referenceId"])
            room_sequences.add(room_sequence)
        state["accounts"][account_id] = {
            "laneState": lane_state,
            "credentialGeneration": require_integer(
                account.get("credentialGeneration", 1),
                f"outbox account {account_id} credentialGeneration",
                1,
            ),
            "operations": operations,
        }
    if not state["accounts"]:
        raise ContractValidationError("Outbox state must contain an account")
    return state


def outbox_operation_summary(operation: dict[str, Any]) -> dict[str, Any]:
    return {
        "state": operation["state"],
        "attemptCount": operation["attemptCount"],
        "messageIds": operation["messageIds"],
        "duplicateRiskAcknowledged": operation["duplicateRiskAcknowledged"],
        "errorClass": operation["errorClass"],
        "nextAttemptAt": operation["nextAttemptAt"],
        "replyTo": operation["replyTo"],
        "threadId": operation["threadId"],
        "replyToToken": operation["replyToToken"],
        "parentRoomToken": operation["parentRoomToken"],
    }


def admit_outbox_operation(
    account: dict[str, Any],
    step: dict[str, Any],
) -> tuple[str, str | None]:
    try:
        operation = normalize_outbox_operation(
            step.get("operation"),
            "admitted outbox operation",
            False,
        )
    except ContractValidationError:
        return "rejected", None
    features = normalize_features(step.get("capabilities"), "outbox capabilities")
    operation_id_value = operation["operationId"]
    if (
        account["laneState"] != "ready"
        or operation_id_value in account["operations"]
        or any(
            existing["referenceId"] == operation["referenceId"]
            for existing in account["operations"].values()
        )
        or any(
            existing["roomToken"] == operation["roomToken"]
            and existing["enqueueSequence"] >= operation["enqueueSequence"]
            for existing in account["operations"].values()
        )
        or operation["operationKind"] != "textSend"
        or operation["replayContractRevision"] != TEXT_SEND_REVISION
        or not {"chat-v2", "chat-reference-id"}.issubset(features)
    ):
        return "rejected", None
    if operation["replyTo"] is not None:
        if "chat-replies" not in features:
            return "rejected", None
        if operation["parentRoomToken"] != operation["roomToken"]:
            return "rejected", None
    if operation["threadId"] is not None:
        federated = require_boolean(
            step.get("federated", False),
            "outbox federated flag",
        )
        if federated or "threads" not in features:
            return "rejected", None
    operation.update(
        {
            "state": "queued",
            "attemptCount": 0,
            "messageIds": [],
            "duplicateRiskAcknowledged": False,
            "errorClass": None,
            "nextAttemptAt": None,
        }
    )
    account["operations"][operation_id_value] = operation
    return "queued", operation_id_value


def find_outbox_operation(
    account: dict[str, Any],
    raw_operation_id: Any,
) -> tuple[str, dict[str, Any]]:
    operation_id_value = operation_id(raw_operation_id, "outbox step operationId")
    try:
        return operation_id_value, account["operations"][operation_id_value]
    except KeyError as error:
        raise ContractValidationError(
            f"Unknown outbox operation {operation_id_value}"
        ) from error


def apply_authoritative_messages(
    operation: dict[str, Any],
    messages: list[dict[str, Any]],
) -> str:
    matches = sorted(
        message["id"]
        for message in messages
        if authoritative_message_matches_operation(message, operation)
    )
    if operation["state"] == "completed":
        if not matches or operation["messageIds"] == matches:
            return "unchanged"
        return "conflict-after-completion"
    if len(matches) == 0:
        return "unchanged"
    if len(matches) > 1:
        operation["state"] = "awaitingConfirmation"
        operation["messageIds"] = matches
        operation["errorClass"] = "multiple-reference-matches"
        operation["nextAttemptAt"] = None
        return "ambiguous-match"
    operation["state"] = "completed"
    operation["messageIds"] = matches
    operation["errorClass"] = None
    operation["nextAttemptAt"] = None
    return "completed"


def authoritative_message_matches_operation(
    message: dict[str, Any],
    operation: dict[str, Any],
) -> bool:
    if (
        message.get("token") != operation["roomToken"]
        or message.get("referenceId") != operation["referenceId"]
    ):
        return False
    if operation["threadId"] is not None:
        return authoritative_named_message_matches_operation(
            message,
            operation,
        )
    if operation["replyTo"] is None:
        return (
            message.get("threadId") == message.get("id")
            and message.get("parent") is None
        )

    parent = message.get("parent")
    if not isinstance(parent, dict):
        return False
    if operation["replyToToken"] is None:
        return (
            parent.get("id") == operation["replyTo"]
            and parent.get("token") == operation["parentRoomToken"]
            and isinstance(parent.get("threadId"), int)
            and not isinstance(parent.get("threadId"), bool)
            and parent["threadId"] > 0
            and message.get("threadId") == parent["threadId"]
        )
    metadata = parent.get("metaData")
    return (
        isinstance(metadata, dict)
        and metadata.get("replyToMessageId") == operation["replyTo"]
        and metadata.get("replyToConversationToken") == operation["replyToToken"]
        and parent.get("token") == operation["parentRoomToken"]
        and parent.get("threadId") == 0
        and message.get("threadId") == parent.get("id")
    )


def authoritative_named_message_matches_operation(
    message: dict[str, Any],
    operation: dict[str, Any],
) -> bool:
    thread_id = operation["threadId"]
    if message.get("threadId") != thread_id:
        return False
    parent = message.get("parent")
    if parent is None:
        return False
    if not isinstance(parent, dict) or parent.get("id") != thread_id:
        return False
    if parent.get("deleted") is True:
        compact = parent.get("token") is None and parent.get("threadId") is None
        full = (
            parent.get("token") == operation["roomToken"]
            and parent.get("threadId") == thread_id
        )
        return compact or full
    return (
        parent.get("token") == operation["roomToken"]
        and parent.get("threadId") == thread_id
    )


def direct_send_message_has_expected_thread_semantics(
    message: dict[str, Any],
    *,
    requested_thread_id: int | None,
    reply_to: int | None,
    private_reply: bool,
) -> bool:
    thread_id = message.get("threadId")
    parent = message.get("parent")
    if requested_thread_id is not None:
        return thread_id == requested_thread_id and parent is None
    if reply_to is None:
        return thread_id == message.get("id") and parent is None
    if not isinstance(parent, dict):
        return False
    if private_reply:
        return thread_id == parent.get("id") and parent.get("threadId") == 0
    parent_thread_id = parent.get("threadId")
    return (
        isinstance(parent_thread_id, int)
        and not isinstance(parent_thread_id, bool)
        and parent_thread_id > 0
        and thread_id == parent_thread_id
    )


def authoritative_get_messages(
    record: dict[str, Any],
    operation: dict[str, Any],
) -> list[dict[str, Any]]:
    metadata = record["metadata"]
    result = record["result"]
    context = require_object(metadata.get("context"), "authoritative GET context")
    status = metadata.get("status")
    classification = result.get("classification")
    if (
        metadata.get("direction") != "response"
        or metadata.get("operationId") != "getChatMessages"
        or context.get("direction") != "future"
        or context.get("roomToken") != operation["roomToken"]
        or context.get("threadId") != operation["threadId"]
    ):
        raise ContractValidationError(
            "Authoritative catch-up requires a future GET for the operation room"
        )
    if status == "200":
        allowed = {
            "messages",
            "invisible-cursor-advance",
            "common-read-only",
        }
    elif status == "304":
        allowed = {"not-modified"}
    else:
        allowed = set()
    if classification not in allowed:
        raise ContractValidationError(
            "Authoritative catch-up requires a successful future GET result"
        )
    return require_list(result.get("messages"), "authoritative GET messages")


def authoritative_relay_messages(step: dict[str, Any]) -> list[dict[str, Any]]:
    message = require_object(step.get("message"), "authoritative relay message")
    require_integer(message.get("id"), "authoritative relay message id", 1)
    conversation_token(
        message.get("token"),
        "authoritative relay room token",
    )
    reference_id(
        message.get("referenceId"),
        "authoritative relay referenceId",
    )
    if message.get("threadId") is not None:
        require_integer(
            message.get("threadId"),
            "authoritative relay threadId",
            1,
        )
    return [message]


def outbox_replay_is_allowed(
    operation: dict[str, Any],
    step: dict[str, Any],
) -> bool:
    if operation["replayContractRevision"] != TEXT_SEND_REVISION:
        return False
    if operation["threadId"] is None:
        return True
    try:
        features = normalize_features(
            step.get("capabilities"),
            "outbox replay capabilities",
        )
        federated = require_boolean(
            step.get("federated", False),
            "outbox replay federated flag",
        )
    except ContractValidationError:
        return False
    return {"chat-v2", "chat-reference-id", "threads"}.issubset(
        features
    ) and not federated


def rate_limit_retry_delay(
    operation: dict[str, Any],
    retry_after_seconds: Any,
) -> int:
    if retry_after_seconds is not None:
        return require_integer(
            retry_after_seconds,
            "rate-limit Retry-After",
            0,
        )
    exponent = max(operation["attemptCount"] - 1, 0)
    return min(
        BASE_RATE_LIMIT_RETRY_SECONDS * (2**exponent),
        MAX_RATE_LIMIT_BACKOFF_SECONDS,
    )


def send_start_is_blocked(
    account: dict[str, Any],
    operation_id_value: str,
    operation: dict[str, Any],
    ignored_operation_ids: set[str] | None = None,
) -> bool:
    ignored_operation_ids = ignored_operation_ids or set()
    if account["laneState"] != "ready":
        return True
    for other_id, other in account["operations"].items():
        if (
            other_id == operation_id_value
            or other_id in ignored_operation_ids
            or other["roomToken"] != operation["roomToken"]
        ):
            continue
        if other["state"] == "sending":
            return True
        if other["enqueueSequence"] < operation["enqueueSequence"] and other[
            "state"
        ] in {"queued", "retryable", "awaitingConfirmation"}:
            return True
    return False


def obsolete_replay_predecessors(
    account: dict[str, Any],
    operation_id_value: str,
    operation: dict[str, Any],
) -> set[str]:
    return {
        other_id
        for other_id, other in account["operations"].items()
        if (
            other_id != operation_id_value
            and other["roomToken"] == operation["roomToken"]
            and other["enqueueSequence"] < operation["enqueueSequence"]
            and other["replayContractRevision"] != TEXT_SEND_REVISION
            and other["state"] in {"queued", "retryable", "awaitingConfirmation"}
        )
    }


def quarantine_obsolete_replay_predecessors(
    account: dict[str, Any],
    operation_ids: set[str],
) -> None:
    for operation_id_value in operation_ids:
        operation = account["operations"][operation_id_value]
        operation["state"] = "failed"
        operation["errorClass"] = "obsolete-replay-contract"
        operation["nextAttemptAt"] = None


def send_response_matches_operation(
    record: dict[str, Any],
    operation: dict[str, Any],
) -> bool:
    metadata = record["metadata"]
    if (
        metadata.get("direction") != "response"
        or metadata.get("operationId") != "sendChatMessage"
    ):
        raise ContractValidationError("Outbox HTTP response needs a send fixture")
    context = require_object(metadata.get("context"), "send fixture context")
    return all(context.get(field) == operation[field] for field in SEND_CONTEXT_FIELDS)


def apply_outbox_action(
    account: dict[str, Any],
    step: dict[str, Any],
    records: dict[str, dict[str, Any]],
) -> tuple[str, str | None]:
    action = require_string(step.get("action"), "outbox action")
    if action == "admit":
        return admit_outbox_operation(account, step)
    if action == "reauthSucceeded":
        generation = require_integer(
            step.get("credentialGeneration"),
            "reauth credential generation",
            1,
        )
        if (
            account["laneState"] != "reauthRequired"
            or generation <= account["credentialGeneration"]
        ):
            return "rejected", None
        account["laneState"] = "ready"
        account["credentialGeneration"] = generation
        return "reauth-succeeded", None

    operation_id_value, operation = find_outbox_operation(
        account,
        step.get("operationId"),
    )
    if action == "claim":
        now = require_integer(step.get("now"), "outbox claim time", 0)
        if operation["state"] not in {
            "queued",
            "retryable",
        }:
            return "rejected", operation_id_value
        if operation["nextAttemptAt"] is not None and now < operation["nextAttemptAt"]:
            return "rejected", operation_id_value
        if not outbox_replay_is_allowed(operation, step):
            return "rejected", operation_id_value
        obsolete = obsolete_replay_predecessors(
            account,
            operation_id_value,
            operation,
        )
        if send_start_is_blocked(
            account,
            operation_id_value,
            operation,
            obsolete,
        ):
            return "rejected", operation_id_value
        quarantine_obsolete_replay_predecessors(account, obsolete)
        operation["state"] = "sending"
        operation["attemptCount"] += 1
        operation["errorClass"] = None
        operation["nextAttemptAt"] = None
        return "sending", operation_id_value

    if action == "httpResponse":
        record = fixture_record(records, step.get("fixture"), "outbox response fixture")
        if not send_response_matches_operation(record, operation):
            return "rejected", operation_id_value
        classification = record["result"]["classification"]
        if operation["state"] == "completed" and classification == "send-confirmed":
            message_id_value = record["result"].get("messageId")
            if operation["messageIds"] != [message_id_value]:
                raise ContractValidationError(
                    "Late HTTP confirmation contradicts relay"
                )
            return "unchanged", operation_id_value
        if operation["state"] != "sending":
            return "rejected", operation_id_value
        if classification == "send-confirmed":
            operation["state"] = "completed"
            operation["messageIds"] = [record["result"]["messageId"]]
            operation["errorClass"] = None
            outcome = "completed"
        elif classification == "send-unconfirmed":
            operation["state"] = "awaitingConfirmation"
            operation["messageIds"] = []
            operation["errorClass"] = "unconfirmed-response"
            outcome = "awaiting-confirmation"
        elif classification == "deterministic-failure":
            operation["state"] = "failed"
            operation["messageIds"] = []
            operation["errorClass"] = "deterministic-rejection"
            outcome = "failed"
        elif classification == "rate-limited":
            now = require_integer(step.get("now"), "rate-limit response time", 0)
            retry_delay = rate_limit_retry_delay(
                operation,
                record["result"].get("retryAfterSeconds"),
            )
            operation["state"] = "retryable"
            operation["messageIds"] = []
            operation["errorClass"] = "rate-limited"
            operation["nextAttemptAt"] = now + retry_delay
            return "retryable", operation_id_value
        elif classification == "reauth":
            account["laneState"] = "reauthRequired"
            operation["state"] = "retryable"
            operation["errorClass"] = "reauth"
            outcome = "reauth-required"
        else:
            operation["state"] = "awaitingConfirmation"
            operation["messageIds"] = []
            operation["errorClass"] = "ambiguous-response"
            outcome = "awaiting-confirmation"
        operation["nextAttemptAt"] = None
        return outcome, operation_id_value

    if action == "transportError":
        if operation["state"] != "sending":
            return "rejected", operation_id_value
        body_state = require_string(step.get("bodyState"), "transport body state")
        if body_state == "not-sent":
            operation["state"] = "retryable"
            operation["errorClass"] = "transport-before-send"
            operation["nextAttemptAt"] = require_integer(
                step.get("nextAttemptAt"),
                "transport retry time",
                0,
            )
            return "retryable", operation_id_value
        if body_state == "possibly-sent":
            operation["state"] = "awaitingConfirmation"
            operation["errorClass"] = "ambiguous-transport"
            operation["nextAttemptAt"] = None
            return "awaiting-confirmation", operation_id_value
        raise ContractValidationError(f"Unknown transport body state {body_state}")

    if action == "restart":
        if operation["state"] != "sending":
            return "unchanged", operation_id_value
        operation["state"] = "awaitingConfirmation"
        operation["errorClass"] = "process-interrupted"
        operation["nextAttemptAt"] = None
        return "awaiting-confirmation", operation_id_value

    if action == "authoritativeMessages":
        record = fixture_record(
            records,
            step.get("fixture"),
            "authoritative message fixture",
        )
        messages = authoritative_get_messages(record, operation)
        return apply_authoritative_messages(operation, messages), operation_id_value

    if action == "authoritativeRelay":
        messages = authoritative_relay_messages(step)
        return apply_authoritative_messages(operation, messages), operation_id_value

    if action == "manualResend":
        acknowledged = require_boolean(
            step.get("duplicateRiskAcknowledged"),
            "manual resend acknowledgement",
        )
        if (
            operation["state"] != "awaitingConfirmation"
            or operation["messageIds"]
            or not acknowledged
            or not outbox_replay_is_allowed(operation, step)
        ):
            return "rejected", operation_id_value
        obsolete = obsolete_replay_predecessors(
            account,
            operation_id_value,
            operation,
        )
        if send_start_is_blocked(
            account,
            operation_id_value,
            operation,
            obsolete,
        ):
            return "rejected", operation_id_value
        quarantine_obsolete_replay_predecessors(account, obsolete)
        operation["state"] = "sending"
        operation["attemptCount"] += 1
        operation["duplicateRiskAcknowledged"] = True
        operation["messageIds"] = []
        operation["errorClass"] = None
        operation["nextAttemptAt"] = None
        return "sending", operation_id_value

    if action == "authFailure":
        account["laneState"] = "reauthRequired"
        return "reauth-required", operation_id_value
    raise ContractValidationError(f"Unknown outbox action {action}")


def apply_outbox_step(
    state: dict[str, Any],
    step: dict[str, Any],
    records: dict[str, dict[str, Any]],
) -> tuple[dict[str, Any], str, str | None]:
    account_id = require_string(step.get("accountId"), "outbox accountId")
    if account_id not in state["accounts"]:
        raise ContractValidationError(f"Unknown outbox account {account_id}")
    before = deepcopy(state)
    candidate = deepcopy(state)
    account = candidate["accounts"][account_id]
    outcome, operation_id_value = apply_outbox_action(account, step, records)
    transaction = step.get("transaction")
    if transaction is not None:
        transaction = require_string(transaction, "outbox transaction")
        if transaction == "fail":
            return before, "transaction-error", operation_id_value
        if transaction != "commit":
            raise ContractValidationError(f"Unknown outbox transaction {transaction}")
    for other_account_id, other_account in before["accounts"].items():
        if (
            other_account_id != account_id
            and candidate["accounts"][other_account_id] != other_account
        ):
            raise ContractValidationError("Outbox action crossed an account boundary")
    return candidate, outcome, operation_id_value


def validate_outbox_cases(
    path: Path,
    records: dict[str, dict[str, Any]],
) -> tuple[int, int]:
    root = require_object(load_json(path), path.name)
    cases = require_unique_ids(
        require_list(root.get("cases"), "outbox cases"),
        REQUIRED_OUTBOX_IDS,
        "outbox case",
    )
    step_count = 0
    for case in cases:
        state = initialize_outbox_state(case.get("initialAccounts"))
        steps = require_list(case.get("steps"), f"outbox case {case['id']} steps")
        if not steps:
            raise ContractValidationError(f"Outbox case {case['id']} has no steps")
        for raw_step in steps:
            step = require_object(raw_step, "outbox step")
            state, outcome, operation_id_value = apply_outbox_step(
                state,
                step,
                records,
            )
            expected_outcome = require_string(
                step.get("expectedOutcome"),
                "expected outbox outcome",
            )
            if outcome != expected_outcome:
                raise ContractValidationError(
                    f"Outbox case {case['id']} returned {outcome}, "
                    f"expected {expected_outcome}"
                )
            account = state["accounts"][step["accountId"]]
            if account["laneState"] != step.get("expectedAccountLane"):
                raise ContractValidationError(
                    f"Outbox case {case['id']} lane is {account['laneState']}, "
                    f"expected {step.get('expectedAccountLane')}"
                )
            if (
                "expectedCredentialGeneration" in step
                and account["credentialGeneration"]
                != step["expectedCredentialGeneration"]
            ):
                raise ContractValidationError(
                    f"Outbox case {case['id']} credential generation is "
                    f"{account['credentialGeneration']}, expected "
                    f"{step['expectedCredentialGeneration']}"
                )
            expected_operation = step.get("expectedOperation")
            actual_operation = (
                outbox_operation_summary(account["operations"][operation_id_value])
                if operation_id_value is not None
                and operation_id_value in account["operations"]
                else None
            )
            if actual_operation != expected_operation:
                raise ContractValidationError(
                    outbox_summary_mismatch_message(
                        case["id"],
                        actual_operation,
                        expected_operation,
                    )
                )
            step_count += 1
    return len(cases), step_count


def scan_fixture_secrets(paths: set[Path]) -> None:
    forbidden = [
        re.compile(r"nks-garage", re.IGNORECASE),
        re.compile(r"-----BEGIN (?:RSA |EC )?PRIVATE KEY-----"),
        re.compile(
            r"\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\."
            r"[A-Za-z0-9_-]{10,}\b"
        ),
        re.compile(
            r'"(?:authorization|appPassword|private_key|refresh_token|access_token)"\s*:',
            re.IGNORECASE,
        ),
    ]
    for path in paths:
        raw = path.read_text(encoding="utf-8")
        for pattern in forbidden:
            if pattern.search(raw):
                raise ContractValidationError(
                    f"Fixture secret scan rejected {path.name}: {pattern.pattern}"
                )


def validate_schema_redaction(
    document: dict[str, Any],
    fixture: dict[str, Any],
    headers: dict[str, str],
) -> int:
    private_marker = "PRIVATE_MESSAGE_VALUE_REDACTION_GUARD"
    instance = load_json(FIXTURE_ROOT / fixture["file"])
    _, raw_messages = ocs_parts(instance)
    messages = require_list(raw_messages, "redaction guard messages")
    message = require_object(messages[0], "redaction guard message")
    message["token"] = private_marker
    message["message"] = private_marker
    message["messageParameters"] = {private_marker: {"type": 7}}
    _, operation = find_operation(document, "getChatMessages")
    schema = response_schema(
        document,
        operation,
        "200",
        "application/json",
    )
    rendered = "; ".join(validate_json_schema(instance, schema))
    if not rendered:
        raise ContractValidationError("Schema redaction guard unexpectedly succeeded")
    if private_marker in rendered:
        raise ContractValidationError("Schema diagnostics exposed a payload value")
    if "$.ocs.data[0].token [pattern]" not in rendered:
        raise ContractValidationError(
            "Schema diagnostics lack a sanitized token path and validator"
        )
    if "$.ocs.data[0].messageParameters [oneOf]" not in rendered:
        raise ContractValidationError(
            "Schema diagnostics lost the malformed dynamic-object path"
        )
    validate_response_headers(document, operation, "200", headers)
    return 1


def normalize_live_origin(raw_origin: str) -> str:
    try:
        parsed = urlsplit(raw_origin)
        port = parsed.port
    except ValueError as error:
        raise ContractValidationError("Live origin is malformed") from error
    if parsed.scheme.lower() != "https":
        raise ContractValidationError("Live smoke requires an HTTPS origin")
    if not parsed.hostname or parsed.username or parsed.password:
        raise ContractValidationError("Live origin has an invalid authority")
    if parsed.query or parsed.fragment:
        raise ContractValidationError("Live origin must not contain query or fragment")
    hostname = parsed.hostname.encode("idna").decode("ascii").lower()
    authority_hostname = f"[{hostname}]" if ":" in hostname else hostname
    netloc = authority_hostname if port is None else f"{authority_hostname}:{port}"
    path = parsed.path.rstrip("/")
    if "//" in path or "/../" in f"{path}/" or "/./" in f"{path}/":
        raise ContractValidationError("Live origin has a non-canonical base path")
    return urlunsplit(("https", netloc, path, "", ""))


def validate_origin_normalization() -> int:
    raw_origin = "https://[2001:db8::1]:8443/nextcloud/"
    expected = "https://[2001:db8::1]:8443/nextcloud"
    actual = normalize_live_origin(raw_origin)
    if actual != expected:
        raise ContractValidationError(
            f"Live origin normalization returned {actual}, expected {expected}"
        )
    return 1


def chat_url(origin: str, room_token: str, query: dict[str, str]) -> str:
    parsed = urlsplit(origin)
    path = f"{parsed.path}{CHAT_PATH}/{room_token}"
    return urlunsplit((parsed.scheme, parsed.netloc, path, urlencode(query), ""))


def read_live_body(response: Any) -> bytes:
    content_length = response.headers.get("Content-Length")
    if content_length is not None and int(content_length) > MAX_LIVE_RESPONSE_BYTES:
        raise ContractValidationError("Live response exceeds the byte limit")
    payload = response.read(MAX_LIVE_RESPONSE_BYTES + 1)
    if len(payload) > MAX_LIVE_RESPONSE_BYTES:
        raise ContractValidationError("Live response exceeds the byte limit")
    return payload


def live_response_headers(headers: Any) -> dict[str, str]:
    return {
        name: value
        for name in ("X-Chat-Last-Given", "X-Chat-Last-Common-Read")
        if (value := headers.get(name)) is not None
    }


def fetch_live_response(
    method: str,
    url: str,
    headers: dict[str, str],
    body: dict[str, Any] | None = None,
) -> tuple[str, Any, dict[str, str]]:
    encoded_body = urlencode(body).encode("utf-8") if body is not None else None
    request_headers = {"Accept": "application/json", **headers}
    if encoded_body is not None:
        request_headers["Content-Type"] = "application/x-www-form-urlencoded"
    request = Request(
        url,
        method=method,
        headers=request_headers,
        data=encoded_body,
    )
    opener = build_opener(NoRedirectHandler())
    try:
        with opener.open(request, timeout=20) as response:
            payload = read_live_body(response)
            status = str(response.status)
            response_headers = live_response_headers(response.headers)
    except HTTPError as error:
        if method == "GET" and error.code == 304:
            return "304", None, live_response_headers(error.headers)
        raise ContractValidationError(
            f"Live chat endpoint returned HTTP {error.code}"
        ) from error
    except (URLError, TimeoutError, ValueError) as error:
        raise ContractValidationError("Live chat request failed") from error
    try:
        instance = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ContractValidationError(
            "Live chat endpoint did not return UTF-8 JSON"
        ) from error
    return status, instance, response_headers


def validate_live_get(
    document: dict[str, Any],
    status: str,
    instance: Any,
    headers: dict[str, str],
    room_token: str,
    direction: str,
) -> dict[str, Any]:
    _, operation = find_operation(document, "getChatMessages")
    if status != "304":
        schema = response_schema(document, operation, status, "application/json")
        errors = validate_json_schema(instance, schema)
        if errors:
            raise ContractValidationError(
                "Live chat response violates the schema: " + "; ".join(errors)
            )
    validate_response_headers(document, operation, status, headers)
    result = classify_get_response(
        instance,
        status,
        headers,
        {"roomToken": room_token, "direction": direction},
    )
    if result["classification"] in {"reauth", "ocs-error", "thread-not-found"}:
        raise ContractValidationError(
            f"Live chat GET classified as {result['classification']}"
        )
    return result


def live_credentials(
    username_env: str,
    password_env: str,
    room_token_env: str,
) -> tuple[str, str]:
    if any(
        ENV_NAME.fullmatch(name) is None
        for name in (username_env, password_env, room_token_env)
    ):
        raise ContractValidationError("Live environment variable name is invalid")
    username = os.environ.get(username_env)
    app_password = os.environ.get(password_env)
    room_token = os.environ.get(room_token_env)
    if not username or not app_password or not room_token:
        raise ContractValidationError(
            "Live smoke needs username, app password and test-room token in "
            "the configured environment variables"
        )
    token = conversation_token(room_token, "live test-room token")
    authorization = base64.b64encode(
        f"{username}:{app_password}".encode("utf-8")
    ).decode("ascii")
    return token, f"Basic {authorization}"


def live_read_smoke(
    document: dict[str, Any],
    origin: str,
    room_token: str,
    authorization: str,
) -> tuple[int, str, str]:
    features = ["chat-v2", "chat-keep-notifications"]
    history_request = build_wire_request(
        "fetch",
        {
            "direction": "history",
            "cursor": "0",
            "lastCommonRead": "0",
            "limit": 1,
            "includeLastKnown": True,
            "interactive": False,
        },
        features,
    )
    validate_request_against_openapi(document, history_request)
    status, instance, headers = fetch_live_response(
        "GET",
        chat_url(origin, room_token, history_request["query"]),
        {**history_request["headers"], "Authorization": authorization},
    )
    history_result = validate_live_get(
        document,
        status,
        instance,
        headers,
        room_token,
        "history",
    )
    anchor = history_result.get("cursor") or "0"
    common_read = history_result.get("commonRead") or "0"

    future_request = build_wire_request(
        "fetch",
        {
            "direction": "future",
            "cursor": anchor,
            "lastCommonRead": common_read,
            "limit": 200,
            "timeout": 0,
            "interactive": False,
        },
        features,
    )
    validate_request_against_openapi(document, future_request)
    status, instance, headers = fetch_live_response(
        "GET",
        chat_url(origin, room_token, future_request["query"]),
        {**future_request["headers"], "Authorization": authorization},
    )
    future_result = validate_live_get(
        document,
        status,
        instance,
        headers,
        room_token,
        "future",
    )
    latest_cursor = future_result.get("cursor") or anchor
    latest_common_read = future_result.get("commonRead") or common_read
    return (
        len(history_result.get("messages", []))
        + len(future_result.get("messages", [])),
        latest_cursor,
        latest_common_read,
    )


def live_write_smoke(
    document: dict[str, Any],
    origin: str,
    room_token: str,
    authorization: str,
    anchor: str,
    common_read: str,
) -> int:
    send_reference = str(uuid.uuid4())
    send_request = build_wire_request(
        "send",
        {
            "message": f"Synthetic contract smoke {send_reference}",
            "referenceId": send_reference,
            "federated": False,
        },
        ["chat-v2", "chat-reference-id"],
    )
    validate_request_against_openapi(document, send_request)
    status, instance, headers = fetch_live_response(
        "POST",
        chat_url(origin, room_token, send_request["query"]),
        {**send_request["headers"], "Authorization": authorization},
        send_request["body"],
    )
    _, operation = find_operation(document, "sendChatMessage")
    schema = response_schema(document, operation, status, "application/json")
    errors = validate_json_schema(instance, schema)
    if errors:
        raise ContractValidationError(
            "Live send response violates the schema: " + "; ".join(errors)
        )
    validate_response_headers(document, operation, status, headers)
    send_result = classify_send_response(
        instance,
        status,
        {"roomToken": room_token, "referenceId": send_reference},
        headers,
    )
    if send_result["classification"] not in {"send-confirmed", "send-unconfirmed"}:
        raise ContractValidationError(
            f"Live send classified as {send_result['classification']}"
        )

    cursor = anchor
    features = ["chat-v2", "chat-keep-notifications"]
    for _ in range(3):
        request = build_wire_request(
            "fetch",
            {
                "direction": "future",
                "cursor": cursor,
                "lastCommonRead": common_read,
                "limit": 200,
                "timeout": 0,
                "interactive": False,
            },
            features,
        )
        validate_request_against_openapi(document, request)
        status, instance, response_headers = fetch_live_response(
            "GET",
            chat_url(origin, room_token, request["query"]),
            {**request["headers"], "Authorization": authorization},
        )
        result = validate_live_get(
            document,
            status,
            instance,
            response_headers,
            room_token,
            "future",
        )
        matches = [
            message
            for message in result.get("messages", [])
            if message.get("referenceId") == send_reference
            and message.get("token") == room_token
        ]
        if len(matches) == 1:
            return 1
        if len(matches) > 1:
            raise ContractValidationError(
                "Live catch-up found duplicate messages for one referenceId"
            )
        next_cursor = result.get("cursor")
        if next_cursor is None or next_cursor == cursor:
            break
        cursor = next_cursor
        common_read = result.get("commonRead") or common_read
    raise ContractValidationError(
        "Live send was not confirmed by bounded authoritative catch-up"
    )


def resolve_case_path(manifest: dict[str, Any], field: str) -> Path:
    filename = require_string(manifest.get(field), field)
    path = (FIXTURE_ROOT / filename).resolve()
    if path.parent != FIXTURE_ROOT or path.suffix != ".json":
        raise ContractValidationError(f"{field} must stay in the fixtures directory")
    return path


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate the Nextcloud Talk chat messages contract."
    )
    parser.add_argument(
        "--live-origin",
        help="Run two authenticated chat GET requests without read side effects.",
    )
    parser.add_argument(
        "--live-write",
        action="store_true",
        help="Also send one synthetic message and confirm it in a dedicated test room.",
    )
    parser.add_argument(
        "--live-username-env",
        default="NEXTCLOUD_TALK_USERNAME",
        help="Environment variable containing the live login name.",
    )
    parser.add_argument(
        "--live-app-password-env",
        default="NEXTCLOUD_TALK_APP_PASSWORD",
        help="Environment variable containing the live app password.",
    )
    parser.add_argument(
        "--live-room-token-env",
        default="NEXTCLOUD_TALK_TEST_ROOM_TOKEN",
        help="Environment variable containing a read-only test-room token.",
    )
    parser.add_argument(
        "--live-write-room-token-env",
        default="NEXTCLOUD_TALK_WRITE_TEST_ROOM_TOKEN",
        help="Environment variable containing the dedicated mutable test-room token.",
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        if arguments.live_write and not arguments.live_origin:
            raise ContractValidationError("--live-write requires --live-origin")
        manifest = require_object(load_json(MANIFEST_PATH), MANIFEST_PATH.name)
        contract_path = (FIXTURE_ROOT / manifest["contract"]).resolve()
        if (
            contract_path.parent != CONTRACT_ROOT
            or contract_path.name != "openapi.json"
        ):
            raise ContractValidationError(
                "Manifest contract must resolve to openapi.json"
            )
        document = require_object(load_json(contract_path), contract_path.name)
        validate_spec(document)

        sets = header_sets(manifest)
        fixtures = require_unique_ids(
            require_list(manifest.get("fixtures"), "fixtures"),
            REQUIRED_FIXTURE_IDS,
            "fixture",
        )
        records: dict[str, dict[str, Any]] = {}
        listed_fixture_paths: set[Path] = set()
        schema_valid_count = 0
        accepted_message_count = 0
        for fixture in fixtures:
            result = validate_fixture(document, fixture, sets)
            records[fixture["id"]] = {"metadata": fixture, "result": result}
            listed_fixture_paths.add((FIXTURE_ROOT / fixture["file"]).resolve())
            schema_valid_count += int(fixture["schemaValid"])
            accepted_message_count += len(result.get("messages", []))

        query_path = resolve_case_path(manifest, "queryCasesFile")
        capability_path = resolve_case_path(manifest, "capabilityCasesFile")
        merge_path = resolve_case_path(manifest, "mergeCasesFile")
        outbox_path = resolve_case_path(manifest, "outboxCasesFile")
        query_count = validate_query_cases(document, query_path)
        capability_count = validate_capability_cases(capability_path)
        merge_count, merge_steps = validate_merge_cases(merge_path, records)
        outbox_count, outbox_steps = validate_outbox_cases(outbox_path, records)
        redaction_fixture = next(
            fixture for fixture in fixtures if fixture["id"] == "history-page"
        )
        redaction_count = validate_schema_redaction(
            document,
            redaction_fixture,
            sets[redaction_fixture["headerSet"]],
        )
        origin_count = validate_origin_normalization()

        case_paths = {query_path, capability_path, merge_path, outbox_path}
        listed_paths = listed_fixture_paths | case_paths
        actual_paths = {
            path.resolve()
            for path in FIXTURE_ROOT.glob("*.json")
            if path.name != MANIFEST_PATH.name
        }
        if actual_paths != listed_paths:
            raise ContractValidationError(
                "Fixture manifest mismatch; "
                f"unlisted={sorted(path.name for path in actual_paths - listed_paths)}, "
                f"missing={sorted(path.name for path in listed_paths - actual_paths)}"
            )
        scan_fixture_secrets(
            listed_paths | {MANIFEST_PATH.resolve(), contract_path.resolve()}
        )

        live_summary = ""
        if arguments.live_origin:
            room_env = (
                arguments.live_write_room_token_env
                if arguments.live_write
                else arguments.live_room_token_env
            )
            room_token, authorization = live_credentials(
                arguments.live_username_env,
                arguments.live_app_password_env,
                room_env,
            )
            origin = normalize_live_origin(arguments.live_origin)
            read_messages, cursor, common_read = live_read_smoke(
                document,
                origin,
                room_token,
                authorization,
            )
            live_summary = (
                f" Live read smoke accepted {read_messages} messages across two "
                "side-effect-free GET requests without printing payload data."
            )
            if arguments.live_write:
                confirmations = live_write_smoke(
                    document,
                    origin,
                    room_token,
                    authorization,
                    cursor,
                    common_read,
                )
                live_summary += (
                    f" Live write smoke confirmed {confirmations} synthetic message "
                    "through authoritative catch-up."
                )

        print(
            "Validated 1 OpenAPI document, "
            f"{len(fixtures)} fixtures ({schema_valid_count} schema-valid, "
            f"{accepted_message_count} accepted messages), {query_count} query cases, "
            f"{capability_count} capability cases, {merge_count} merge cases with "
            f"{merge_steps} transactional steps, {outbox_count} outbox cases with "
            f"{outbox_steps} lifecycle steps, {redaction_count} schema-redaction guard "
            f"and {origin_count} origin case.{live_summary}"
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
