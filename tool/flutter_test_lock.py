#!/usr/bin/env python3
"""Serialises `flutter test` in one checkout, and says so when it waits.

Two concurrent runs in `apps/mobile` fight over
`build/native_assets/windows/sqlite3.dll`. The loser dies before a single test
executes with "Flutter failed to delete file ... does not have read/write
permissions", which names the wrong problem: it is a lock, not a permission,
and a `flutter_tester` that hangs keeps holding the file long after its own run
is over. That message cost several workers most of an afternoon between them on
9 September 2026.

`flutter test` has no per-run build directory (`FLUTTER_BUILD_DIR` is ignored
and `flutter config --build-dir` is a global user setting), so the fix is to
queue the runs and to be honest about the wait:

    python tool/flutter_test_lock.py -- test/reminder_inbox_test.dart

A lock whose holder is gone is broken automatically - a killed run must not
block the checkout forever.
"""
import argparse
import os
import subprocess
import sys
import time

LOCK_NAME = "flutter-test.lock"


def _process_alive(pid):
    """Whether the recorded holder still exists."""
    if pid <= 0:
        return False
    if os.name == "nt":
        probe = subprocess.run(
            ["tasklist", "/FI", f"PID eq {pid}", "/NH"],
            capture_output=True,
            text=True,
        )
        return str(pid) in probe.stdout
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def read_holder(path):
    """The PID in the lock file, or None when it is absent or unreadable."""
    try:
        with open(path, encoding="utf-8") as handle:
            return int(handle.read().strip())
    except (OSError, ValueError):
        return None


def acquire(path, *, wait=True, poll=1.0, timeout=None, announce=print):
    """Takes the lock, waiting for a live holder and stepping over a dead one."""
    announced = False
    deadline = None if timeout is None else time.monotonic() + timeout
    while True:
        try:
            handle = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        except FileExistsError:
            holder = read_holder(path)
            if holder is None or not _process_alive(holder):
                # The holder is gone: its run was killed, or it hung and was
                # taken out. Leaving the file would block the checkout forever.
                announce(
                    f"flutter test lock: removing the lock of process {holder} "
                    "because it is no longer running"
                )
                try:
                    os.unlink(path)
                except FileNotFoundError:
                    pass
                continue
            if not wait:
                raise TimeoutError(
                    f"flutter test is already running in this checkout "
                    f"(process {holder}); one run at a time, because they "
                    "share build/native_assets"
                )
            if not announced:
                announce(
                    f"flutter test lock: waiting for process {holder}, which is "
                    "already running the tests in this checkout"
                )
                announced = True
            if deadline is not None and time.monotonic() >= deadline:
                raise TimeoutError(
                    f"waited for process {holder} and it is still running"
                )
            time.sleep(poll)
            continue
        with os.fdopen(handle, "w", encoding="utf-8") as writer:
            writer.write(str(os.getpid()))
        return path


def stale_testers(entries, project):
    """The `flutter_tester` processes left behind by a run in this checkout.

    Only ever called while the lock is held, so no legitimate run of this
    checkout is in flight and anything still pointing at its build directory is
    the residue of a killed or hung one - which is what keeps holding
    `sqlite3.dll` and produces the misleading permission error.

    Matched on the project path in the command line rather than on the process
    name: another checkout's tests are none of our business.
    """
    marker = os.path.normcase(os.path.abspath(project))
    stale = []
    for pid, command in entries:
        if "flutter_tester" not in os.path.normcase(command):
            continue
        if marker in os.path.normcase(command):
            stale.append(pid)
    return stale


def _running_processes():
    """`(pid, command line)` for every process, as far as the OS will say."""
    if os.name == "nt":
        probe = subprocess.run(
            [
                "powershell",
                "-NoProfile",
                "-Command",
                "Get-CimInstance Win32_Process -Filter \"Name='flutter_tester.exe'\""
                " | ForEach-Object { \"$($_.ProcessId)`t$($_.CommandLine)\" }",
            ],
            capture_output=True,
            text=True,
        )
    else:
        probe = subprocess.run(
            ["ps", "-eo", "pid=,args="], capture_output=True, text=True
        )
    entries = []
    for line in probe.stdout.splitlines():
        head, _, rest = line.strip().partition("\t" if os.name == "nt" else " ")
        try:
            entries.append((int(head), rest))
        except ValueError:
            continue
    return entries


def clear_stale_testers(project, announce=print):
    """Kills this checkout's orphaned testers. Returns what it killed."""
    killed = []
    for pid in stale_testers(_running_processes(), project):
        announce(
            f"flutter test lock: killing process {pid}, a test host left behind "
            "by an earlier run in this checkout"
        )
        if os.name == "nt":
            subprocess.run(["taskkill", "/F", "/PID", str(pid)], capture_output=True)
        else:
            try:
                os.kill(pid, 9)
            except OSError:
                continue
        killed.append(pid)
    return killed


def release(path):
    """Drops the lock, but never someone else's."""
    if read_holder(path) == os.getpid():
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--project",
        default=os.path.join(os.path.dirname(os.path.dirname(__file__)), "apps", "mobile"),
    )
    parser.add_argument("--flutter", default="flutter")
    parser.add_argument("--no-wait", action="store_true")
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)

    build = os.path.join(args.project, "build")
    os.makedirs(build, exist_ok=True)
    path = os.path.join(build, LOCK_NAME)
    try:
        acquire(path, wait=not args.no_wait)
    except TimeoutError as clash:
        print(f"flutter test lock: {clash}", file=sys.stderr)
        return 1
    try:
        clear_stale_testers(args.project)
        rest = [item for item in args.arguments if item != "--"]
        return subprocess.call([args.flutter, "test", *rest], cwd=args.project)
    finally:
        release(path)


if __name__ == "__main__":
    sys.exit(main())
