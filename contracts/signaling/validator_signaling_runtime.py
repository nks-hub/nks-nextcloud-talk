from __future__ import annotations

from typing import Any

from validator_signaling_common import (
    ContractValidationError,
    require_boolean,
    require_integer,
    require_list,
    require_object,
    require_string,
)


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


def runtime_default() -> dict[str, Any]:
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


def clear_transient(state: dict[str, Any]) -> None:
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


def apply_runtime_action(state: dict[str, Any], raw_action: Any) -> None:
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
        clear_transient(state)
        state["renegotiationRequired"] = True
        state["outcome"] = "unchanged"
    elif action_type == "helloError":
        if state["phase"] != "helloPending":
            raise ContractValidationError("runtime hello error precondition failed")
        code = require_string(action.get("code"), "hello error code")
        if code == "no_such_session" and state["pending"] == "resume":
            clear_transient(state)
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
            clear_transient(state)
            state["mode"] = None
            state["phase"] = "settingsRefreshRequired"
            state["outcome"] = "settingsRefreshRequired"
        else:
            raise ContractValidationError("runtime hello error is unsupported")
    elif action_type == "roomError":
        if action.get("code") != "no_such_room":
            raise ContractValidationError("runtime room error is unsupported")
        clear_transient(state)
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
            clear_transient(state)
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
        clear_transient(state)
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
    validate_runtime_invariants(state)


def validate_runtime_invariants(state: dict[str, Any]) -> None:
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
    state = runtime_default()
    state.update(initial)
    validate_runtime_invariants(state)
    for action in require_list(case.get("actions"), "runtime actions"):
        apply_runtime_action(state, action)
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
