#!/usr/bin/env python3
"""Run: python3 /absolute/path/to/polly/scripts/test-web-upstream-faults.py

Real PollyWeb, two Nagios mocks, source fault/recovery and service restart. Own processes only.
"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("webtest", ROOT / "scripts/test-web.py")
web = importlib.util.module_from_spec(spec)
spec.loader.exec_module(web)

def main():
    web.run("swift", "build", "--package-path", str(ROOT / "Packages/PollyWeb"), "-j", "8")
    binary = Path(web.run("swift", "build", "--package-path", str(ROOT / "Packages/PollyWeb"), "--show-bin-path")) / "polly-web"
    processes = []
    with tempfile.TemporaryDirectory(prefix="polly-upstream-faults-") as temporary:
        directory = Path(temporary)
        logs = []
        try:
            urls = []
            for i in range(2):
                port = web.free_port()
                log = open(directory / f"mock-{i}.log", "w+")
                logs.append(log)
                process = subprocess.Popen(["node", str(ROOT / "mock/nagios-mock.mjs"), "--port", str(port), "--no-rotate"], stdout=log, stderr=log)
                processes.append(process)
                url = f"http://127.0.0.1:{port}"
                web.wait_for(lambda: web.request(url + "/mock/reset")[0] == 200, process)
                urls.append(url)
            web.read_json(urls[0] + "/mock/set?host=web1.example.com&service=HTTP&status=critical")
            config = directory / "polly.yaml"
            original = "passwordStorage: file\nservers:\n" + "".join(f"  - name: Source {i}\n    url: {url}\n    username: nagiosadmin\n    password: nagios\n" for i, url in enumerate(urls))
            config.write_text(original)
            config.chmod(0o400)
            env = dict(os.environ, POLLY_CONFIG=str(config))
            port = web.free_port()
            base = f"http://127.0.0.1:{port}"
            def start():
                log = open(directory / f"web-{len(logs)}.log", "w+")
                logs.append(log)
                p = subprocess.Popen([str(binary), "serve", "--hostname", "127.0.0.1", "--port", str(port)], env=env, stdout=log, stderr=log)
                processes.append(p)
                web.wait_for(lambda: web.request(base + "/healthz")[0] == 200, p)
                return p
            def snapshot():
                status, _, body = web.request(base + "/api/status")
                assert status == 200
                return json.loads(body)
            service = start()
            web.wait_for(lambda: snapshot()["coverage"]["fresh"] == 2, service)
            web.stop(service)
            for fault in ["auth", "503", "redirect", "invalid-json", "slow", "hang"]:
                result = web.read_json(urls[1] + f"/mock/config?fault={fault}")
                print(f"Mock fault requested={fault}, observed={result.get('fault')}", flush=True)
                assert result.get("fault") == fault, "Mock must actually enter the requested fault"
                service = start()
                if fault == "slow":
                    web.wait_for(lambda: snapshot()["coverage"]["fresh"] == 2, service)
                else:
                    web.wait_for(lambda: [s["state"] for s in snapshot()["servers"]] == ["ok", "unreachable"], service)
                    data = snapshot()
                    assert data["coverage"] == {"active": 2, "fresh": 1}
                    assert data["counts"]["critical"] == 1 and len(data["problems"]) == 1
                    assert data["mood"] == "critical"
                    assert web.request(base + "/healthz")[0] == 200
                web.read_json(urls[1] + "/mock/config?fault=none")
                # One real poll interval proves automatic source recovery without restarting Polly.
                if fault == "503":
                    deadline = time.monotonic() + 80
                    while snapshot()["coverage"]["fresh"] != 2:
                        assert time.monotonic() < deadline, "Source did not recover automatically"
                        time.sleep(1)
                web.stop(service)
                assert service.returncode == 0
                service = start()
                web.wait_for(lambda: snapshot()["coverage"]["fresh"] == 2, service)
                assert snapshot()["counts"]["critical"] == 1
                web.stop(service)
                print(f"✅ {fault}: source isolation, recovery, service restart", flush=True)
            assert config.read_text() == original
            print("✅ Real upstream fault suite passed; configuration unchanged", flush=True)
        finally:
            for p in reversed(processes):
                web.stop(p)
            for log in logs:
                log.close()

if __name__ == "__main__":
    main()
