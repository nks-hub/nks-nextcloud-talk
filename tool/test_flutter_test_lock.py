import os

import pytest

import flutter_test_lock as lock


def test_the_lock_records_its_holder(tmp_path):
    path = str(tmp_path / "flutter-test.lock")
    lock.acquire(path)
    assert lock.read_holder(path) == os.getpid()
    lock.release(path)
    assert not os.path.exists(path)


def test_a_live_holder_is_refused_without_waiting(tmp_path):
    path = str(tmp_path / "flutter-test.lock")
    lock.acquire(path)
    with pytest.raises(TimeoutError) as clash:
        lock.acquire(path, wait=False)
    assert "one run at a time" in str(clash.value)
    lock.release(path)


def test_a_dead_holder_does_not_block_the_checkout(tmp_path):
    # A killed or hung run must not leave the checkout unusable, which is the
    # failure that made the original message so misleading.
    path = tmp_path / "flutter-test.lock"
    path.write_text("999999999", encoding="utf-8")
    said = []
    lock.acquire(str(path), wait=False, announce=said.append)
    assert lock.read_holder(str(path)) == os.getpid()
    assert any("no longer running" in line for line in said)
    lock.release(str(path))


def test_a_lock_file_without_a_pid_is_broken(tmp_path):
    path = tmp_path / "flutter-test.lock"
    path.write_text("", encoding="utf-8")
    lock.acquire(str(path), wait=False)
    assert lock.read_holder(str(path)) == os.getpid()
    lock.release(str(path))


def test_release_never_drops_another_run_lock(tmp_path):
    path = tmp_path / "flutter-test.lock"
    path.write_text("999999999", encoding="utf-8")
    lock.release(str(path))
    assert path.exists()


def test_waiting_says_what_it_waits_for(tmp_path):
    path = str(tmp_path / "flutter-test.lock")
    lock.acquire(path)
    said = []
    with pytest.raises(TimeoutError):
        lock.acquire(path, poll=0.01, timeout=0.05, announce=said.append)
    assert any("already running the tests" in line for line in said)
    lock.release(path)


def test_a_tester_of_this_checkout_is_stale(tmp_path):
    project = str(tmp_path / "apps" / "mobile")
    entries = [
        (11, rf"C:\flutter\flutter_tester.exe --flutter-assets-dir={project}\build\x"),
    ]
    assert lock.stale_testers(entries, project) == [11]


def test_another_checkout_is_left_alone(tmp_path):
    project = str(tmp_path / "apps" / "mobile")
    entries = [
        (12, r"C:\flutter\flutter_tester.exe --flutter-assets-dir=C:\other\build\x"),
    ]
    assert lock.stale_testers(entries, project) == []


def test_only_test_hosts_are_considered(tmp_path):
    project = str(tmp_path / "apps" / "mobile")
    entries = [(13, rf"C:\bin\dart.exe --packages={project}\.dart_tool\x")]
    assert lock.stale_testers(entries, project) == []
