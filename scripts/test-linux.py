#!/usr/bin/env python3
"""Run: python3 /absolute/path/to/polly/scripts/test-linux.py

Runs PollyKit and its real HTTP mock integration on Linux with Swift 6.4.2.
Requires Docker and Python 3. Starts/stops OrbStack on macOS if it was stopped.
"""

from pathlib import Path
import re
import shutil
import subprocess
import time
import uuid


ROOT = Path(__file__).resolve().parents[1]
SWIFT_IMAGE = "swift:6.4.2-noble"
NODE_IMAGE = "node:22.14.0-bookworm-slim"


def run(*args):
    return subprocess.run(args, check=True, text=True, errors="replace", stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, timeout=900).stdout


def verified(output):
    return bool(re.search(r"Test run with [1-9][0-9]* tests .* passed", output)
                and re.search(r"✔ Suite MockIntegrationTests passed", output))


def main():
    # A successful process with skipped integration tests must not pass this gate.
    assert not verified("✔ Test run with 100 tests in 20 suites passed")
    assert verified("✔ Suite MockIntegrationTests passed\n✔ Test run with 100 tests in 20 suites passed")
    name = "polly-linux-" + uuid.uuid4().hex[:12]
    mock, tests = name + "-mock", name + "-tests"
    started_orb = False
    network = False
    try:
        if subprocess.run(["docker", "info"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
            if not shutil.which("orbctl") or subprocess.run(
                    ["orbctl", "status"], capture_output=True, text=True).stdout.strip() != "Stopped":
                raise RuntimeError("Start Docker before running the Linux tests.")
            started_orb = True
            print(run("orbctl", "start"), flush=True)
        print(run("docker", "info", "--format", "{{.ServerVersion}} {{.Architecture}}"), flush=True)
        run("docker", "network", "create", name)
        network = True
        run("docker", "run", "--detach", "--rm", "--name", mock, "--network", name,
            "--mount", f"type=bind,source={ROOT / 'mock'},target=/mock,readonly",
            NODE_IMAGE, "node", "/mock/nagios-mock.mjs", "--no-rotate")
        for _ in range(60):
            ready = subprocess.run(["docker", "exec", mock, "node", "-e",
                "fetch('http://127.0.0.1:8080/mock/reset').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if ready.returncode == 0:
                break
            time.sleep(0.5)
        else:
            raise RuntimeError("Mock did not become ready.")
        print(f"Testing with {SWIFT_IMAGE}; POLLY_MOCK_URL=http://{mock}:8080", flush=True)
        print(run("docker", "run", "--rm", SWIFT_IMAGE, "swift", "--version"), flush=True)
        output = run("docker", "run", "--rm", "--name", tests, "--network", name,
            "--mount", f"type=bind,source={ROOT},target=/workspace",
            "--env", f"POLLY_MOCK_URL=http://{mock}:8080", SWIFT_IMAGE,
            "swift", "test", "--package-path", "/workspace/Packages/PollyKit",
            "--scratch-path", "/workspace/.build/linux")
        print(output, flush=True)
        if not verified(output):
            raise RuntimeError("Expected passing tests and real MockIntegrationTests, but did not find both.")
        print("✅ Linux tests and real HTTP mock integration passed.")
    except subprocess.CalledProcessError as error:
        print(error.stdout or "", flush=True)
        raise
    finally:
        try:
            if network:
                for container in (tests, mock):
                    subprocess.run(["docker", "rm", "--force", container],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                run("docker", "network", "rm", name)
        finally:
            if started_orb:
                run("orbctl", "stop")


if __name__ == "__main__":
    main()
