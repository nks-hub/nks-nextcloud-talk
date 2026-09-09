import importlib.util
import io
import os
import zipfile

import pytest

_spec = importlib.util.spec_from_file_location(
    "push_gateway_gate",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "push_gateway_gate.py"),
)
gate = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gate)

ORIGIN = "https://gateway.example"


def write(tmp_path, name, text):
    path = tmp_path / name
    path.write_text(text, encoding="utf-8")
    return str(path)


def test_accepts_the_expected_origin(tmp_path):
    path = write(tmp_path, "telemetry.env",
                 f"SENTRY_DSN=https://dsn.example\n{gate.DEFINE_NAME}={ORIGIN}\n")
    assert gate.check_defines(ORIGIN, [path], []) == ORIGIN


def test_the_negative_control_is_a_missing_define(tmp_path):
    """Exactly the build 65 near-miss: telemetry present, gateway absent."""
    path = write(tmp_path, "telemetry.env",
                 "SENTRY_DSN=https://dsn.example\nRYBBIT_HOST=https://rybbit.example\n"
                 "RYBBIT_SITE_ID=7\nTELEMETRY_ENVIRONMENT=production\n")
    with pytest.raises(gate.GateError, match="register for push nowhere"):
        gate.check_defines(ORIGIN, [path], [])


def test_a_command_line_define_can_supply_it(tmp_path):
    path = write(tmp_path, "telemetry.env", "SENTRY_DSN=https://dsn.example\n")
    assert gate.check_defines(
        ORIGIN, [path], [f"{gate.DEFINE_NAME}={ORIGIN}"]) == ORIGIN


def test_another_origin_is_refused(tmp_path):
    path = write(tmp_path, "telemetry.env", f"{gate.DEFINE_NAME}=https://other.example\n")
    with pytest.raises(gate.GateError, match="expects"):
        gate.check_defines(ORIGIN, [path], [])


@pytest.mark.parametrize("value", [
    "http://gateway.example",
    "https://gateway.example/push",
    "https://gateway.example?a=1",
    "https://user@gateway.example",
    "https://",
    " https://gateway.example",
    "",
])
def test_only_a_bare_https_origin_passes(value):
    assert not gate.valid_origin(value)


def test_a_trailing_slash_is_still_an_origin():
    assert gate.valid_origin("https://gateway.example/")


def apk(tmp_path, name, payload):
    path = tmp_path / name
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr("lib/arm64-v8a/libapp.so", payload)
        archive.writestr("AndroidManifest.xml", "<manifest/>")
    path.write_bytes(buffer.getvalue())
    return str(path)


def test_an_artifact_carrying_the_origin_passes(tmp_path):
    path = apk(tmp_path, "app.apk", b"\x7fELF..." + ORIGIN.encode() + b"...")
    assert "libapp.so" in gate.check_artifact(ORIGIN, path)


def test_an_artifact_built_without_the_define_fails(tmp_path):
    path = apk(tmp_path, "app.apk", b"\x7fELF...no gateway here...")
    with pytest.raises(gate.GateError, match="does not carry"):
        gate.check_artifact(ORIGIN, path)


def test_an_archive_without_compiled_dart_fails(tmp_path):
    path = tmp_path / "empty.apk"
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr("AndroidManifest.xml", "<manifest/>")
    path.write_bytes(buffer.getvalue())
    with pytest.raises(gate.GateError, match="no compiled Dart"):
        gate.check_artifact(ORIGIN, str(path))


def test_an_app_bundle_layout_is_understood(tmp_path):
    path = tmp_path / "app.aab"
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr("base/lib/arm64-v8a/libapp.so", ORIGIN.encode())
    path.write_bytes(buffer.getvalue())
    assert "base/lib/arm64-v8a/libapp.so" in gate.check_artifact(ORIGIN, str(path))


def test_an_ipa_payload_is_understood(tmp_path):
    path = tmp_path / "app.ipa"
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr(
            "Payload/Runner.app/Frameworks/App.framework/App", ORIGIN.encode())
    path.write_bytes(buffer.getvalue())
    assert "App.framework/App" in gate.check_artifact(ORIGIN, str(path))


def test_the_command_line_reports_a_missing_define(tmp_path, capsys):
    path = write(tmp_path, "telemetry.env", "SENTRY_DSN=https://dsn.example\n")
    assert gate.main(["--origin", ORIGIN, "defines", "--define-file", path]) == 1
    assert "push gateway gate" in capsys.readouterr().err


def test_the_command_line_passes_a_good_build(tmp_path, capsys):
    path = write(tmp_path, "telemetry.env", f"{gate.DEFINE_NAME}={ORIGIN}\n")
    assert gate.main(["--origin", ORIGIN, "defines", "--define-file", path]) == 0
    assert gate.DEFINE_NAME in capsys.readouterr().out


def test_a_windows_snapshot_is_not_judged(tmp_path, capsys):
    # The constant lives in the Apple branch, so the compiler drops it from a
    # Windows build. Reporting that as a missing origin sends the next release
    # chasing a defect that is not there.
    release = tmp_path / "windows" / "x64" / "runner" / "Release" / "data"
    release.mkdir(parents=True)
    snapshot = release / "app.so"
    snapshot.write_bytes(b"no origin here")
    assert gate.main(["--origin", ORIGIN, "artifact", str(snapshot)]) == 0
    assert "not expected to be" in capsys.readouterr().out


def test_a_linux_snapshot_is_not_judged(tmp_path, capsys):
    bundle = tmp_path / "linux" / "x64" / "release" / "bundle" / "lib"
    bundle.mkdir(parents=True)
    snapshot = bundle / "libapp.so"
    snapshot.write_bytes(b"no origin here")
    assert gate.main(["--origin", ORIGIN, "artifact", str(snapshot)]) == 0


def test_an_android_snapshot_is_still_judged(tmp_path):
    # The guard keys on the desktop layouts only: an Android library is named
    # libapp.so as well, and losing it would silence the check that matters.
    android = tmp_path / "app" / "outputs" / "flutter-apk"
    android.mkdir(parents=True)
    snapshot = android / "libapp.so"
    snapshot.write_bytes(b"no origin here")
    assert gate.main(["--origin", ORIGIN, "artifact", str(snapshot)]) == 1
