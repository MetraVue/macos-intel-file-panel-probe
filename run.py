import os
from pathlib import Path
import platform
import re
import subprocess
import tempfile

MARKERS = {
    "constructor-started", "constructor-returned", "panel-visible-on-screen",
    "native-key-input-posted", "native-key-input-unavailable", "native-escape-posted",
    "programmatic-dismissal-requested", "panel-dismissed-without-confirming",
    "panel-confirmed", "open-sample-verified", "save-sample-verified",
    "confirmed-operation-unverified",
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


def main():
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
        for kind in ("open", "save"):
            run_panel(executable, "baseline", kind, root)

        bootout = command("launchctl", "bootout", service).returncode
        disable = command("launchctl", "disable", service).returncode
        print(f"workaround: bootout-exit={bootout} disable-exit={disable}; {state()}", flush=True)
        for kind in ("open", "save"):
            run_panel(executable, "after", kind, root)
        print(f"final agent: {state()}", flush=True)


if __name__ == "__main__":
    main()
