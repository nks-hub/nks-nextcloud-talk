from __future__ import annotations

from copy import deepcopy
from pathlib import Path
from typing import Any

from validator_common import (
    ContractValidationError,
    REQUIRED_STATE_IDS,
    SHA256,
    STATE_SUMMARY_FIELDS,
    _conversation_token,
    _expected_message_type,
    _safe_identifier,
    _uuid,
    _validate_filename,
    load_json,
    normalize_relative_path,
    normalize_server,
    require_boolean,
    require_integer,
    require_list,
    require_object,
    require_string,
    require_unique_ids,
    safe_mapping_mismatch_fields,
)
from validator_transport import ATTACHMENT_PHASES, RETRY_PHASES


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
