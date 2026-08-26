from __future__ import annotations

from collections.abc import Sequence
from copy import deepcopy
from pathlib import Path
from typing import Any

from validator_common import (
    BASE_RATE_LIMIT_RETRY_SECONDS,
    ContractValidationError,
    MAX_RATE_LIMIT_BACKOFF_SECONDS,
    REQUIRED_OUTBOX_IDS,
    SEND_CONTEXT_FIELDS,
    TEXT_SEND_REVISION,
    conversation_token,
    load_json,
    message_text,
    operation_id,
    outbox_summary_mismatch_message,
    reference_id,
    require_boolean,
    require_integer,
    require_list,
    require_object,
    require_string,
    require_unique_ids,
)
from validator_merge import fixture_record
from validator_requests import normalize_features


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
    paths: Sequence[Path],
    records: dict[str, dict[str, Any]],
) -> tuple[int, int]:
    raw_cases: list[Any] = []
    for path in paths:
        root = require_object(load_json(path), path.name)
        raw_cases.extend(require_list(root.get("cases"), "outbox cases"))
    cases = require_unique_ids(
        raw_cases,
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
