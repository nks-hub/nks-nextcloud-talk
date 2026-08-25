from __future__ import annotations

# ruff: noqa: E402

import sys
from pathlib import Path


_MODULE_ROOT = Path(__file__).resolve().parent
if str(_MODULE_ROOT) not in sys.path:
    sys.path.insert(0, str(_MODULE_ROOT))

from validator_common import *  # noqa: F403
from validator_runner import *  # noqa: F403
from validator_state import *  # noqa: F403
from validator_transport import *  # noqa: F403


if __name__ == "__main__":
    sys.exit(main())  # noqa: F405
