from __future__ import annotations

from collections.abc import Sequence
from copy import deepcopy
from pathlib import Path
from typing import Any

from validator_common import (
    ContractValidationError,
    REQUIRED_MERGE_IDS,
    canonical_cursor,
    conversation_token,
    load_json,
    require_boolean,
    require_integer,
    require_list,
    require_object,
    require_string,
    require_unique_ids,
)


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
        return "stale"
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
    paths: Sequence[Path],
    records: dict[str, dict[str, Any]],
) -> tuple[int, int]:
    raw_cases: list[Any] = []
    for path in paths:
        root = require_object(load_json(path), path.name)
        raw_cases.extend(require_list(root.get("cases"), "merge cases"))
    cases = require_unique_ids(
        raw_cases,
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
