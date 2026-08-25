from __future__ import annotations

import json
import re
from typing import Any

from validator_signaling_common import (
    CONVERSATION_TOKEN,
    MAX_BATCH_MESSAGES,
    MAX_PARTICIPANTS,
    MAX_WIRE_BYTES,
    SAFE_IDENTIFIER,
    ContractValidationError,
    duplicate_object,
    find_operation,
    request_schema,
    require_boolean,
    require_integer,
    require_list,
    require_object,
    require_string,
    response_schema,
    schema_errors,
)
from validator_signaling_hpb import validate_peer_message
from validator_signaling_settings import parse_settings


def validate_ocs_meta(response: dict[str, Any], status: int) -> Any:
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


def validate_internal_pull(data: Any) -> None:
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
                message = json.loads(encoded, object_pairs_hook=duplicate_object)
            except json.JSONDecodeError as error:
                raise ContractValidationError(
                    "internal message is invalid JSON"
                ) from error
            validate_peer_message(message, "internal message")
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


def validate_batch_form(value: Any) -> None:
    form = require_object(value, "batch form")
    encoded = require_string(
        form.get("messages"), "batch form messages", maximum=MAX_WIRE_BYTES
    )
    try:
        messages = json.loads(encoded, object_pairs_hook=duplicate_object)
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
            frame = json.loads(encoded_frame, object_pairs_hook=duplicate_object)
        except json.JSONDecodeError as error:
            raise ContractValidationError("batch fn is invalid JSON") from error
        validate_peer_message(frame, f"batch[{index}].fn")
        if "to" not in require_object(frame, "batch peer message"):
            raise ContractValidationError("batch peer message needs a recipient")


def path_matches(template: str, actual: str) -> bool:
    pattern = re.escape(template).replace(re.escape("{token}"), r"[a-z0-9]{4,30}")
    return re.fullmatch(pattern, actual) is not None


def validate_http_case(document: dict[str, Any], case: dict[str, Any]) -> None:
    expected_valid = require_boolean(case.get("valid"), "HTTP valid")
    try:
        operation_id = require_string(case.get("operationId"), "operationId")
        template, method, operation = find_operation(document, operation_id)
        request = require_object(case.get("request"), "HTTP request")
        if request.get("method") != method.upper():
            raise ContractValidationError("HTTP request method mismatch")
        path = require_string(request.get("path"), "HTTP request path")
        if not path_matches(template, path):
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
            errors = schema_errors(form, request_schema(document, operation))
            if errors:
                raise ContractValidationError(f"HTTP form schema failed: {errors[0]}")
            validate_batch_form(form)

        status = require_integer(case.get("status"), "HTTP status", minimum=100)
        response = require_object(case.get("response"), "HTTP response")
        errors = schema_errors(
            response,
            response_schema(document, operation, status),
        )
        if errors:
            raise ContractValidationError(f"HTTP response schema failed: {errors[0]}")
        data = validate_ocs_meta(response, status)
        if status == 200 and operation_id == "getSignalingSettingsV3":
            parse_settings(data)
        elif status == 200 and operation_id == "pullInternalSignalingV3":
            validate_internal_pull(data)
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
