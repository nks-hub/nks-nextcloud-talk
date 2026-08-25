from __future__ import annotations

# ruff: noqa: E402

import sys
import uuid as uuid
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs


_MODULE_ROOT = Path(__file__).resolve().parent
if str(_MODULE_ROOT) not in sys.path:
    sys.path.insert(0, str(_MODULE_ROOT))

import validator_requests as _validator_requests
import validator_runner as _validator_runner
from validator_common import *  # noqa: F403
from validator_merge import *  # noqa: F403
from validator_outbox import *  # noqa: F403
from validator_requests import *  # noqa: F403
from validator_runner import *  # noqa: F403
from validator_schema import *  # noqa: F403


fetch_live_response = _validator_runner.fetch_live_response


def validate_request_against_openapi(
    document: dict[str, Any],
    built: dict[str, Any],
) -> None:
    _validator_requests.validate_request_against_openapi(
        document,
        built,
        _parse_query=parse_qs,
    )


def live_write_smoke(
    document: dict[str, Any],
    origin: str,
    room_token: str,
    authorization: str,
    anchor: str,
    common_read: str,
) -> int:
    return _validator_runner.live_write_smoke(
        document,
        origin,
        room_token,
        authorization,
        anchor,
        common_read,
        _fetch_response=fetch_live_response,
    )


if __name__ == "__main__":
    sys.exit(_validator_runner.main())
