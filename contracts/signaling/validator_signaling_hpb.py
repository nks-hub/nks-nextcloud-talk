from __future__ import annotations

import json
from typing import Any

from validator_signaling_common import (
    CONVERSATION_TOKEN,
    MAX_PARTICIPANTS,
    MAX_WIRE_BYTES,
    SAFE_IDENTIFIER,
    SAFE_WIRE_NAME,
    ContractValidationError,
    normalize_hpb_endpoint,
    normalize_nextcloud_server,
    require_boolean,
    require_integer,
    require_list,
    require_object,
    require_string,
    require_synthetic_secret,
    validate_feature_list,
)


PAYLOAD_FREE_PEER_MESSAGE_TYPES = frozenset({"startedTyping", "stoppedTyping"})


def validate_request_id(value: Any, label: str = "frame.id") -> str:
    request_id = require_string(value, label, maximum=128)
    if SAFE_IDENTIFIER.fullmatch(request_id) is None:
        raise ContractValidationError(f"{label} has an unsafe shape")
    return request_id


def validate_actor(value: Any, label: str) -> None:
    actor = require_object(value, label)
    actor_type = require_string(actor.get("type"), f"{label}.type", maximum=64)
    if SAFE_WIRE_NAME.fullmatch(actor_type) is None:
        raise ContractValidationError(f"{label}.type has an unsafe shape")
    peer = require_string(actor.get("sessionid"), f"{label}.sessionid", maximum=512)
    if SAFE_IDENTIFIER.fullmatch(peer) is None:
        raise ContractValidationError(f"{label}.sessionid has an unsafe shape")


def validate_peer_message(value: Any, label: str) -> None:
    message = require_object(value, label)
    message_type = require_string(message.get("type"), f"{label}.type", maximum=128)
    if SAFE_WIRE_NAME.fullmatch(message_type) is None:
        raise ContractValidationError(f"{label}.type has an unsafe shape")
    if "roomType" in message:
        room_type = require_string(
            message["roomType"],
            f"{label}.roomType",
            maximum=64,
            allow_empty=True,
        )
        if room_type and SAFE_WIRE_NAME.fullmatch(room_type) is None:
            raise ContractValidationError(f"{label}.roomType has an unsafe shape")
    for member in ("to", "from"):
        if member in message:
            peer = require_string(message[member], f"{label}.{member}", maximum=512)
            if SAFE_IDENTIFIER.fullmatch(peer) is None:
                raise ContractValidationError(f"{label}.{member} has an unsafe shape")
    if "payload" in message or message_type not in PAYLOAD_FREE_PEER_MESSAGE_TYPES:
        require_object(message.get("payload"), f"{label}.payload")


def validate_client_hello(frame: dict[str, Any]) -> None:
    validate_request_id(frame.get("id"))
    hello = require_object(frame.get("hello"), "hello")
    version = require_string(hello.get("version"), "hello.version", maximum=3)
    if version not in {"1.0", "2.0"}:
        raise ContractValidationError("hello.version is unsupported")
    if "resumeid" in hello:
        validate_request_id(hello["resumeid"], "hello.resumeid")
        if "auth" in hello:
            raise ContractValidationError("resume hello must not contain auth")
        return
    validate_feature_list(hello.get("features"), "hello.features")
    auth = require_object(hello.get("auth"), "hello.auth")
    backend = normalize_nextcloud_server(auth.get("url"), "hello.auth.url")
    if not backend.endswith("/ocs/v2.php/apps/spreed/api/v3/signaling/backend"):
        raise ContractValidationError("hello.auth.url is not the Talk backend endpoint")
    params = require_object(auth.get("params"), "hello.auth.params")
    if version == "1.0":
        require_string(
            params.get("userid"),
            "hello.auth.params.userid",
            maximum=4096,
            allow_empty=True,
        )
        require_synthetic_secret(
            params.get("ticket"),
            "hello.auth.params.ticket",
            16384,
        )
    else:
        require_synthetic_secret(
            params.get("token"),
            "hello.auth.params.token",
            32768,
        )


def validate_client_room(frame: dict[str, Any]) -> None:
    validate_request_id(frame.get("id"))
    room = require_object(frame.get("room"), "room")
    room_id = require_string(
        room.get("roomid"),
        "room.roomid",
        maximum=30,
        allow_empty=True,
    )
    if room_id == "":
        if set(room) != {"roomid"}:
            raise ContractValidationError("room leave contains unexpected state")
        return
    if CONVERSATION_TOKEN.fullmatch(room_id) is None:
        raise ContractValidationError("room.roomid has an invalid shape")
    session_id = require_string(room.get("sessionid"), "room.sessionid", maximum=512)
    if SAFE_IDENTIFIER.fullmatch(session_id) is None:
        raise ContractValidationError("room.sessionid has an invalid shape")
    if "federation" in room:
        federation = require_object(room["federation"], "room.federation")
        socket = normalize_hpb_endpoint(
            federation.get("signaling"),
            "room.federation.signaling",
        )
        if socket != federation.get("signaling"):
            raise ContractValidationError("room.federation.signaling is not canonical")
        normalize_nextcloud_server(federation.get("url"), "room.federation.url")
        remote = require_string(
            federation.get("roomid"),
            "room.federation.roomid",
            maximum=30,
        )
        if CONVERSATION_TOKEN.fullmatch(remote) is None:
            raise ContractValidationError("room.federation.roomid has an invalid shape")
        require_synthetic_secret(
            federation.get("token"),
            "room.federation.token",
            32768,
        )


def validate_client_frame(frame: dict[str, Any]) -> str:
    frame_type = require_string(frame.get("type"), "frame.type", maximum=64)
    if frame_type == "hello":
        validate_client_hello(frame)
    elif frame_type == "room":
        validate_client_room(frame)
    elif frame_type == "message":
        validate_request_id(frame.get("id"))
        message = require_object(frame.get("message"), "message")
        validate_actor(message.get("recipient"), "message.recipient")
        validate_peer_message(message.get("data"), "message.data")
    elif frame_type == "control":
        validate_request_id(frame.get("id"))
        control = require_object(frame.get("control"), "control")
        validate_actor(control.get("recipient"), "control.recipient")
        require_object(control.get("data"), "control.data")
    elif frame_type == "bye":
        validate_request_id(frame.get("id"))
        require_object(frame.get("bye"), "bye")
    else:
        raise ContractValidationError("Unknown client frame type")
    return frame_type


def validate_hpb_participants(
    value: Any,
    label: str,
    *,
    update: bool,
) -> None:
    participants = require_list(value, label)
    if len(participants) > MAX_PARTICIPANTS:
        raise ContractValidationError(f"{label} exceeds its count budget")
    peers: list[str] = []
    for index, raw in enumerate(participants):
        participant = require_object(raw, f"{label}[{index}]")
        member = "sessionId" if update else "sessionid"
        peer = require_string(
            participant.get(member),
            f"{label}[{index}].{member}",
            maximum=512,
        )
        if SAFE_IDENTIFIER.fullmatch(peer) is None:
            raise ContractValidationError(f"{label}[{index}].{member} is unsafe")
        peers.append(peer)
        for integer_member in ("inCall", "participantPermissions"):
            if integer_member in participant:
                require_integer(
                    participant[integer_member],
                    f"{label}[{index}].{integer_member}",
                )
        if "federated" in participant:
            require_boolean(participant["federated"], f"{label}[{index}].federated")
        if "features" in participant:
            validate_feature_list(participant["features"], f"{label}[{index}].features")
    if len(peers) != len(set(peers)):
        raise ContractValidationError(f"{label} contains duplicate sessions")


def validate_server_event(frame: dict[str, Any]) -> None:
    if "id" in frame:
        raise ContractValidationError("event frame must not have an id")
    event = require_object(frame.get("event"), "event")
    target = require_string(event.get("target"), "event.target", maximum=64)
    event_type = require_string(event.get("type"), "event.type", maximum=64)
    if target == "room" and event_type in {"join", "change"}:
        validate_hpb_participants(
            event.get(event_type),
            f"event.{event_type}",
            update=False,
        )
    elif target == "room" and event_type == "leave":
        peers = require_list(event.get("leave"), "event.leave")
        parsed = [
            require_string(peer, "event.leave peer", maximum=512) for peer in peers
        ]
        if len(parsed) != len(set(parsed)):
            raise ContractValidationError("event.leave contains duplicate sessions")
    elif target == "participants" and event_type == "update":
        update = require_object(event.get("update"), "event.update")
        room_id = require_string(
            update.get("roomid"), "event.update.roomid", maximum=30
        )
        if CONVERSATION_TOKEN.fullmatch(room_id) is None:
            raise ContractValidationError("event.update.roomid is invalid")
        if "users" in update:
            validate_hpb_participants(
                update["users"],
                "event.update.users",
                update=True,
            )
        else:
            if require_boolean(update.get("all"), "event.update.all") is not True:
                raise ContractValidationError("event.update.all must be true")
            require_integer(update.get("incall"), "event.update.incall")
    elif target == "room" and event_type == "federation_interrupted":
        return
    elif target == "room" and event_type == "federation_resumed":
        require_boolean(event.get("resumed"), "event.resumed")


def validate_server_frame(frame: dict[str, Any]) -> str:
    frame_type = require_string(frame.get("type"), "frame.type", maximum=64)
    if frame_type == "welcome":
        if "id" in frame:
            raise ContractValidationError("welcome frame must not have an id")
        welcome = require_object(frame.get("welcome"), "welcome")
        validate_feature_list(welcome.get("features"), "welcome.features")
    elif frame_type == "hello":
        validate_request_id(frame.get("id"))
        hello = require_object(frame.get("hello"), "hello")
        version = require_string(hello.get("version"), "hello.version", maximum=3)
        if version not in {"1.0", "2.0"}:
            raise ContractValidationError("hello.version is unsupported")
        validate_request_id(hello.get("sessionid"), "hello.sessionid")
        if "resumeid" in hello:
            validate_request_id(hello["resumeid"], "hello.resumeid")
        if "server" in hello:
            server = require_object(hello["server"], "hello.server")
            validate_feature_list(server.get("features"), "hello.server.features")
    elif frame_type == "room":
        if "id" in frame:
            validate_request_id(frame["id"])
        room = require_object(frame.get("room"), "room")
        room_id = require_string(
            room.get("roomid"),
            "room.roomid",
            maximum=30,
            allow_empty=True,
        )
        if room_id and CONVERSATION_TOKEN.fullmatch(room_id) is None:
            raise ContractValidationError("room.roomid has an invalid shape")
        if "bandwidth" in room:
            bandwidth = require_object(room["bandwidth"], "room.bandwidth")
            require_integer(
                bandwidth.get("maxstreambitrate"),
                "room.bandwidth.maxstreambitrate",
            )
            require_integer(
                bandwidth.get("maxscreenbitrate"),
                "room.bandwidth.maxscreenbitrate",
            )
    elif frame_type == "error":
        validate_request_id(frame.get("id"))
        error = require_object(frame.get("error"), "error")
        require_string(error.get("code"), "error.code", maximum=128)
        require_string(error.get("message"), "error.message", maximum=4096)
    elif frame_type == "event":
        validate_server_event(frame)
    elif frame_type == "message":
        message = require_object(frame.get("message"), "message")
        validate_actor(message.get("sender"), "message.sender")
        validate_peer_message(message.get("data"), "message.data")
    elif frame_type == "control":
        control = require_object(frame.get("control"), "control")
        validate_actor(control.get("sender"), "control.sender")
        require_object(control.get("data"), "control.data")
    elif frame_type == "bye":
        require_object(frame.get("bye"), "bye")
    else:
        return "unsupported"
    return frame_type


def validate_hpb_case(case: dict[str, Any]) -> None:
    expected_valid = require_boolean(case.get("valid"), "HPB valid")
    try:
        frame = require_object(case.get("frame"), "HPB frame")
        encoded = json.dumps(frame, ensure_ascii=False, separators=(",", ":"))
        if len(encoded.encode("utf-8")) > MAX_WIRE_BYTES:
            raise ContractValidationError("HPB frame byte budget exceeded")
        direction = require_string(case.get("direction"), "HPB direction", maximum=16)
        if direction == "client":
            actual_type = validate_client_frame(frame)
        elif direction == "server":
            actual_type = validate_server_frame(frame)
        else:
            raise ContractValidationError("HPB direction is unsupported")
        if not expected_valid:
            raise ContractValidationError("Invalid HPB case was accepted")
        expected_type = require_string(case.get("expectedType"), "expectedType")
        if actual_type != expected_type:
            raise ContractValidationError("HPB frame classification mismatch")
    except ContractValidationError as error:
        if expected_valid:
            raise
        expected_error = require_string(case.get("error"), "HPB error")
        if expected_error not in str(error):
            raise ContractValidationError(
                f"HPB case {case.get('id')} failed for the wrong reason: {error}"
            ) from error
