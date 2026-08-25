from __future__ import annotations

# ruff: noqa: E402, F403

import sys
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs


_MODULE_ROOT = Path(__file__).resolve().parent
if str(_MODULE_ROOT) not in sys.path:
    sys.path.insert(0, str(_MODULE_ROOT))

import validator_rich_requests as _validator_requests
import validator_rich_runner as _validator_runner
from validator_rich_projection import *
from validator_rich_protocol import *
from validator_rich_requests import *
from validator_rich_runner import *


def validate_request_against_openapi(
    document: dict[str, Any],
    request: dict[str, Any],
) -> None:
    _validator_requests.validate_request_against_openapi(
        document,
        request,
        _parse_query=parse_qs,
    )


if __name__ == "__main__":
    raise SystemExit(_validator_runner.main())
