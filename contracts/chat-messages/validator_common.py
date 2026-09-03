from __future__ import annotations

import json
import re
import uuid
from pathlib import Path
from typing import Any
from urllib.request import HTTPRedirectHandler, Request


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
    "chat-lobby",
    "chat-rate-limited",
    "chat-unavailable",
    "duplicate-message-id",
    "duplicate-reference-id",
    "future-page",
    "future-timeout",
    "history-exhausted",
    "history-page",
    "federated-history-page",
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
    "open-anchor-history-takes-newest-page",
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
