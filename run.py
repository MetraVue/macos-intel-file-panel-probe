import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile
import time

MARKERS = {
    "constructor-started", "constructor-returned", "panel-visible-on-screen",
    "native-key-input-posted", "native-key-input-unavailable", "native-escape-posted",
    "programmatic-dismissal-requested", "panel-dismissed-without-confirming",
    "panel-confirmed", "open-sample-verified", "save-sample-verified",
    "confirmed-operation-unverified", "open-input-unavailable",
    "native-open-file-click-posted", "open-file-row-unavailable",
}


def command(*args, timeout=10):
    return subprocess.run(args, timeout=timeout, capture_output=True, text=True)


def safe_value(value):
    return value if re.fullmatch(r"[a-zA-Z0-9._-]+", value) else "unavailable"


def run_panel(executable, phase, kind, root):
    folder = root / f"{phase}-{kind}"
    folder.mkdir()
    try:
        result = subprocess.run([executable, kind, folder], timeout=15, capture_output=True)
        output, outcome = result.stdout, f"exit-{result.returncode}"
    except subprocess.TimeoutExpired as failure:
        output, outcome = failure.stdout or b"", "timeout"
    marks = [line for line in output.decode(errors="replace").splitlines() if line in MARKERS]
    print(f"{phase}/{kind}: {outcome}; {' '.join(marks) or 'no-markers'}", flush=True)


def confirm_open(executable, root):
    folder = root / "open-confirmation"
    folder.mkdir()
    transcript = root / "open-transcript"
    driver_output = b""
    with transcript.open("wb") as output, subprocess.Popen(
        [executable, "confirm-open", folder], stdout=output, stderr=subprocess.DEVNULL
    ) as panel:
        deadline = time.monotonic() + 17
        while panel.poll() is None and time.monotonic() < deadline:
            if b"panel-visible-on-screen" in transcript.read_bytes():
                try:
                    driver = subprocess.run([executable, "select-open", str(panel.pid)],
                                            timeout=12, capture_output=True)
                    driver_output = driver.stdout
                except subprocess.TimeoutExpired as error:
                    driver_output = error.stdout or b""
                break
            time.sleep(0.15)
        try:
            result = f"exit-{panel.wait(timeout=max(1, deadline - time.monotonic()))}"
        except subprocess.TimeoutExpired:
            panel.kill()
            panel.wait()
            result = "timeout"
    panel_output = transcript.read_bytes()

    def markers(output):
        return [line for line in output.decode(errors="replace").splitlines() if line in MARKERS]

    driver_marks = markers(driver_output)
    panel_marks = markers(panel_output)
    print(f"open input: {' '.join(driver_marks) or 'no-markers'}", flush=True)
    print(f"open result: {result}; {' '.join(panel_marks) or 'no-markers'}", flush=True)
    return (
        result == "exit-0"
        and "native-open-file-click-posted" in driver_marks
        and {"panel-visible-on-screen", "panel-confirmed", "open-sample-verified"}.issubset(panel_marks)
    )


def main():
    targeted = sys.argv[1:] == ["--confirm-open-only"]
    machine = platform.machine()
    translation = command("sysctl", "-in", "sysctl.proc_translated").stdout.strip()
    version = command("sw_vers", "-productVersion").stdout.strip()
    build = command("sw_vers", "-buildVersion").stdout.strip()
    print(f"macOS={safe_value(version)} build={safe_value(build)} arch={safe_value(machine)}")
    print(f"image={safe_value(os.getenv('ImageOS', ''))} image-version={safe_value(os.getenv('ImageVersion', ''))}")
    if machine != "x86_64" or translation == "1" or not version.startswith("26."):
        raise SystemExit("Unexpected host")
    domain = f"gui/{os.getuid()}"
    label = "com.apple.iconservices.iconservicesagent"
    service = f"{domain}/{label}"

    def state():
        listing = command("launchctl", "print-disabled", domain).stdout
        disabled = bool(re.search(rf'"{re.escape(label)}"\s*=>\s*(?:disabled|true)\b', listing))
        loaded = command("launchctl", "print", service).returncode == 0
        return f"explicitly-disabled={disabled} service-loaded={loaded}"

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        executable = root / "panel-probe"
        build_result = command("swiftc", "panel.swift", "-o", str(executable), timeout=45)
        if build_result.returncode != 0:
            raise SystemExit("Standalone probe compilation failed")
        print(f"baseline agent: {state()}", flush=True)
        if not targeted:
            for kind in ("open", "save"):
                run_panel(executable, "baseline", kind, root)

        bootout = command("launchctl", "bootout", service).returncode
        disable = command("launchctl", "disable", service).returncode
        print(f"workaround: bootout-exit={bootout} disable-exit={disable}; {state()}", flush=True)
        if targeted:
            if disable != 0 or state() != "explicitly-disabled=True service-loaded=False":
                raise SystemExit("Workaround state could not be verified")
            if not confirm_open(executable, root):
                raise SystemExit("Open confirmation did not reach the verified file read")
        else:
            for kind in ("open", "save"):
                run_panel(executable, "after", kind, root)
        print(f"final agent: {state()}", flush=True)


if __name__ == "__main__":
    main()
