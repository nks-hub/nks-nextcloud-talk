from __future__ import annotations

from typing import Any

from validator_signaling_common import (
    CONVERSATION_TOKEN,
    ContractValidationError,
    normalize_hpb_endpoint,
    normalize_nextcloud_server,
    require_boolean,
    require_list,
    require_object,
    require_string,
    require_synthetic_secret,
)


def validate_ice_servers(value: Any, label: str, *, turn: bool) -> None:
    servers = require_list(value, label)
    if len(servers) > 32:
        raise ContractValidationError(f"{label} exceeds its count budget")
    for index, raw_server in enumerate(servers):
        server = require_object(raw_server, f"{label}[{index}]")
        urls = require_list(server.get("urls"), f"{label}[{index}].urls")
        if not 1 <= len(urls) <= 16:
            raise ContractValidationError(f"{label}[{index}].urls count is invalid")
        for url in urls:
            parsed = require_string(url, f"{label}[{index}].url", maximum=2048)
            allowed = ("turn:", "turns:") if turn else ("stun:", "stuns:")
            if not parsed.startswith(allowed):
                raise ContractValidationError(f"{label}[{index}].url scheme is invalid")
        if turn:
            require_string(
                server.get("username"),
                f"{label}[{index}].username",
                maximum=4096,
                allow_empty=True,
            )
            require_synthetic_secret(
                server.get("credential"),
                f"{label}[{index}].credential",
                16384,
            )


def parse_settings(value: Any) -> dict[str, Any]:
    data = require_object(value, "settings")
    mode = require_string(data.get("signalingMode"), "signalingMode", maximum=16)
    require_string(
        data.get("userId"),
        "userId",
        maximum=4096,
        allow_empty=True,
    )
    require_boolean(data.get("hideWarning"), "hideWarning")
    require_string(
        data.get("sipDialinInfo"),
        "sipDialinInfo",
        maximum=16384,
        allow_empty=True,
    )
    validate_ice_servers(data.get("stunservers"), "stunservers", turn=False)
    validate_ice_servers(data.get("turnservers"), "turnservers", turn=True)
    federation = data.get("federation")
    federation_socket: str | None = None
    if federation is not None:
        raw_federation = require_object(federation, "federation")
        federation_socket = normalize_hpb_endpoint(
            raw_federation.get("server"),
            "federation.server",
        )
        normalize_nextcloud_server(
            raw_federation.get("nextcloudServer"),
            "federation.nextcloudServer",
        )
        room_id = require_string(
            raw_federation.get("roomId"),
            "federation.roomId",
            maximum=30,
        )
        if CONVERSATION_TOKEN.fullmatch(room_id) is None:
            raise ContractValidationError("federation.roomId has an invalid shape")
        federation_auth = require_object(
            raw_federation.get("helloAuthParams"),
            "federation.helloAuthParams",
        )
        require_synthetic_secret(
            federation_auth.get("token"),
            "federation.helloAuthParams.token",
            32768,
        )

    if mode == "internal":
        require_string(
            data.get("server"),
            "server",
            maximum=4096,
            allow_empty=True,
        )
        return {
            "mode": mode,
            "federated": federation is not None,
            "helloVersions": [],
            **(
                {"federationSocket": federation_socket}
                if federation_socket is not None
                else {}
            ),
        }
    if mode != "external":
        raise ContractValidationError("signalingMode is unsupported")

    socket = normalize_hpb_endpoint(data.get("server"), "server")
    auth = require_object(data.get("helloAuthParams"), "helloAuthParams")
    versions: list[str] = []
    if "1.0" in auth:
        v1 = require_object(auth["1.0"], "helloAuthParams.1.0")
        require_string(
            v1.get("userid"),
            "helloAuthParams.1.0.userid",
            maximum=4096,
            allow_empty=True,
        )
        require_synthetic_secret(
            v1.get("ticket"),
            "helloAuthParams.1.0.ticket",
            16384,
        )
        versions.append("1.0")
    if "2.0" in auth:
        v2 = require_object(auth["2.0"], "helloAuthParams.2.0")
        require_synthetic_secret(
            v2.get("token"),
            "helloAuthParams.2.0.token",
            32768,
        )
        versions.append("2.0")
    if not versions:
        raise ContractValidationError("helloAuthParams has no supported authentication")
    return {
        "mode": mode,
        "socket": socket,
        "federated": federation is not None,
        "helloVersions": versions,
        **(
            {"federationSocket": federation_socket}
            if federation_socket is not None
            else {}
        ),
    }


def validate_settings_case(case: dict[str, Any]) -> None:
    expected_valid = require_boolean(case.get("valid"), "settings valid")
    try:
        actual = parse_settings(case.get("data"))
        if not expected_valid:
            raise ContractValidationError("Invalid settings case was accepted")
        expected = require_object(case.get("expected"), "settings expected")
        if actual != expected:
            raise ContractValidationError(
                f"settings expected summary mismatch for {case.get('id')}"
            )
    except ContractValidationError as error:
        if expected_valid:
            raise
        expected_error = require_string(case.get("error"), "settings error")
        if expected_error not in str(error):
            raise ContractValidationError(
                f"settings case {case.get('id')} failed for the wrong reason: {error}"
            ) from error
