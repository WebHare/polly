#!/usr/bin/env python3
"""Run: python3 /absolute/path/to/polly/scripts/test-web.py

Builds PollyWeb and tests real HTTP against two temporary Nagios mocks.
Linux runner supplies POLLY_TEST_MOCK_URLS and --binary; no installed service is used.
"""

import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
PASSWORD = "viewer-test-password"


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, errors="replace", capture_output=True,
                          timeout=900, **kwargs).stdout.strip()


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
            raise AssertionError("Service did not stop gracefully")


def request(url, *, password=None, method="GET"):
    headers = {}
    if password is not None:
        headers["Authorization"] = "Basic " + base64.b64encode(("viewer:" + password).encode()).decode()
    req = urllib.request.Request(url, headers=headers, method=method)
    try:
        response = urllib.request.urlopen(req, timeout=5)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return response.status, response.headers, response.read()


def read_json(url):
    status, _, body = request(url)
    assert status == 200, "Mock control endpoint failed"
    return json.loads(body)


def wait_for(check, process):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        assert process.poll() is None, "Test process exited before readiness"
        try:
            if check():
                return
        except (OSError, urllib.error.URLError):
            pass
        time.sleep(0.1)
    raise AssertionError("Test process did not become ready")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path)
    options = parser.parse_args()
    binary = options.binary
    if binary is None:
        print("Building PollyWeb…", flush=True)
        run("swift", "build", "--package-path", str(ROOT / "Packages/PollyWeb"), "-j", "8")
        binary = Path(run("swift", "build", "--package-path", str(ROOT / "Packages/PollyWeb"), "--show-bin-path")) / "polly-web"
    binary = binary.resolve()
    # Reject secrets in argv before reading stdin, and never hash a truncated input.
    for arguments, password in [
        (["argument-secret"], PASSWORD + "\n"),
        ([], PASSWORD + "\n" * 1024 + "truncated-secret"),
        ([], "x" * 73 + "\n"),
        ([], "short\n"),
        ([], PASSWORD + "\nsecond-line"),
    ]:
        rejected = subprocess.run([str(binary), "hash-password", *arguments], input=password,
                                  text=True, capture_output=True, timeout=10)
        print(f"Hash rejection check: arguments={len(arguments)}, bytes={len(password.encode())}, exit={rejected.returncode}", flush=True)
        assert rejected.returncode != 0, "Invalid password input must be rejected"
        assert not rejected.stdout, "Rejected input must not produce a hash"
        assert "argument-secret" not in rejected.stderr and "truncated-secret" not in rejected.stderr
    processes = []
    logs = []
    with tempfile.TemporaryDirectory(prefix="polly-web-test-") as temporary:
        directory = Path(temporary)
        try:
            mocks = json.loads(os.environ.get("POLLY_TEST_MOCK_URLS", "[]"))
            if not mocks:
                for index in range(2):
                    port = free_port()
                    log = open(directory / f"mock-{index}.log", "w+")
                    logs.append(log)
                    process = subprocess.Popen(["node", str(ROOT / "mock/nagios-mock.mjs"), "--port", str(port), "--no-rotate"],
                                               stdout=log, stderr=log)
                    processes.append(process)
                    url = f"http://127.0.0.1:{port}"
                    wait_for(lambda: request(url + "/mock/reset")[0] == 200, process)
                    mocks.append(url)
            assert len(mocks) == 2, "Exactly two isolated mock servers are required"
            for url in mocks:
                read_json(url + "/mock/reset")
                before = read_json(url + "/mock/requests")["requests"]
                read_json(url + "/mock/reset")
                assert read_json(url + "/mock/requests")["requests"] == before + 2
            read_json(mocks[0] + "/mock/set?host=web1.example.com&service=HTTP&status=critical")
            read_json(mocks[1] + "/mock/set?host=web1.example.com&service=HTTP&status=warning")
            config = directory / "polly.yaml"
            secret = directory / "viewer.hash"
            secret.write_text(run(str(binary), "hash-password", input=PASSWORD + "\n") + "\n")
            secret.chmod(0o400)
            yaml = "passwordStorage: file\ndebugLog: true\nservers:\n" + "".join(
                f"  - name: Source {index}\n    url: {url}\n    username: nagiosadmin\n    password: nagios\n"
                for index, url in enumerate(mocks)
            )
            config.write_text(yaml)
            config.chmod(0o400)
            env = dict(os.environ, POLLY_CONFIG=str(config), POLLY_VIEWER_USERNAME="viewer",
                       POLLY_VIEWER_PASSWORD_HASH_FILE=str(secret))
            port = free_port()
            log = open(directory / "web.log", "w+")
            logs.append(log)
            service = subprocess.Popen([str(binary), "serve", "--hostname", "127.0.0.1", "--port", str(port)],
                                       env=env, stdout=log, stderr=log)
            processes.append(service)
            base = f"http://127.0.0.1:{port}"
            wait_for(lambda: request(base + "/healthz", password=PASSWORD)[0] == 200, service)

            def snapshot():
                status, headers, body = request(base + "/api/status", password=PASSWORD)
                assert status == 200
                assert headers["Cache-Control"] == "no-store"
                for value in ["nagiosadmin", PASSWORD, secret.read_text().strip(), *mocks]:
                    assert value.encode() not in body, "A secret or upstream URL leaked"
                return json.loads(body)

            wait_for(lambda: snapshot()["coverage"]["fresh"] == 2, service)
            initial = snapshot()
            assert initial["counts"]["hosts"] == 12
            assert initial["counts"]["services"] == 46
            assert [p["severity"] for p in initial["problems"]] == ["critical", "warning"]
            assert initial["state"] == "problems"
            for server in initial["servers"]:
                assert server["lastAttemptAt"] and server["lastSuccessAt"]
            before = [read_json(url + "/mock/requests")["requests"] for url in mocks]
            with ThreadPoolExecutor(max_workers=2) as readers:
                results = list(readers.map(lambda _: snapshot(), range(6)))
            def measurements(result):
                return [(s["id"], s["lastAttemptAt"], s["lastSuccessAt"]) for s in result["servers"]]
            assert all(measurements(result) == measurements(initial) for result in results)
            after = [read_json(url + "/mock/requests")["requests"] for url in mocks]
            assert after == [count + 1 for count in before], "API viewers triggered upstream polls"
            for path in ["/", "/index.html", "/api/status", "/healthz"]:
                assert request(base + path)[0] == 401
                assert request(base + path, password="wrong")[0] == 401
                assert request(base + path, password=PASSWORD)[0] == 200
            for path in ["/polly.yaml", "/viewer.hash", "/../polly.yaml", "/%2e%2e/viewer.hash", "/api/command"]:
                assert request(base + path, password=PASSWORD)[0] in (403, 404)
            for method in ["POST", "PUT", "PATCH", "DELETE"]:
                assert request(base + "/api/status", password=PASSWORD, method=method)[0] == 405
            for path, mime in [("/app.mjs", "javascript"), ("/dashboard.mjs", "javascript"),
                               ("/dashboard.css", "text/css"), ("/design.mjs", "javascript"),
                               ("/fonts/83ddc2f0-8211-487f-a86b-c3e677e1d298.woff2", "font/woff2")]:
                assert request(base + path)[0] == 401
                status, headers, body = request(base + path, password=PASSWORD)
                assert status == 200 and mime in headers["Content-Type"] and body
                assert headers["Cache-Control"] == "no-store"
            for path in ["/__test__/fixtures.mjs", "/doc/design/polly-web/source/Polly%20Animations.html"]:
                assert request(base + path, password=PASSWORD)[0] == 404
            assert config.read_text() == yaml
            assert not (directory / "polly-debug.log").exists()
            stop(service)
            assert service.returncode == 0, "Server shutdown did not complete normally"
            assert log.seek(0) == 0
            output = log.read()
            assert PASSWORD not in output and "nagiosadmin" not in output
            assert "listening on" in output

            # An upstream failure must affect coverage, not process liveness or another source's problems.
            assert yaml.count(f"url: {mocks[1]}") == 1
            failed_yaml = yaml.replace(f"url: {mocks[1]}", "url: http://127.0.0.1:9")
            config.chmod(0o600)
            config.write_text(failed_yaml)
            config.chmod(0o400)
            port = free_port()
            outage_log = open(directory / "outage.log", "w+")
            logs.append(outage_log)
            service = subprocess.Popen([str(binary), "serve", "--port", str(port)], env=env,
                                       stdout=outage_log, stderr=outage_log)
            processes.append(service)
            base = f"http://127.0.0.1:{port}"
            wait_for(lambda: request(base + "/healthz", password=PASSWORD)[0] == 200, service)
            wait_for(lambda: [server["state"] for server in snapshot()["servers"]] == ["ok", "unreachable"], service)
            outage = snapshot()
            assert outage["coverage"] == {"active": 2, "fresh": 1}
            assert outage["mood"] == "critical" and len(outage["problems"]) == 1
            assert request(base + "/healthz", password=PASSWORD)[0] == 200
            assert config.read_text() == failed_yaml
            stop(service)
            assert service.returncode == 0

            unauthenticated = {key: value for key, value in env.items() if not key.startswith("POLLY_VIEWER_")}
            for arguments in [["--hostname", "0.0.0.0"], ["--bind", "0.0.0.0:8088"], ["-H", "0.0.0.0"]]:
                rejected = subprocess.run([str(binary), "serve", *arguments], env=unauthenticated,
                                          text=True, capture_output=True, timeout=10)
                assert rejected.returncode != 0
                assert "requires viewer authentication" in rejected.stderr
                assert "listening on" not in rejected.stdout
            config.chmod(0o600)
            config.write_text("passwordStorage: file\nservers: [private-syntax-error-secret")
            invalid = subprocess.run([str(binary), "serve"], env=env, text=True, capture_output=True, timeout=10)
            assert invalid.returncode != 0
            assert "private-syntax-error-secret" not in invalid.stdout + invalid.stderr
            print("✅ Real HTTP: two sources, auth, read-only routes, no extra polls, upstream outage, safe bind and graceful shutdown.")
        finally:
            for process in reversed(processes):
                stop(process)
            for log in logs:
                log.close()


if __name__ == "__main__":
    main()
