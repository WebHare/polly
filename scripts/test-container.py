#!/usr/bin/env python3
"""Run: python3 /absolute/path/to/polly/scripts/test-container.py

Builds and checks the actual Compose runtime. Requires a running Docker engine.
POLLY_TEST_PLATFORM selects linux/arm64 or linux/amd64; default is the engine architecture.
"""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]


def run(*args, **kwargs):
    result = subprocess.run(args, check=True, text=True, capture_output=True,
                            timeout=kwargs.pop("timeout", 3600), **kwargs)
    return result.stdout.strip()


def main():
    assert (ROOT / "Dockerfile").is_file(), "The distributable Dockerfile is missing"
    name = "polly-smoke-" + uuid.uuid4().hex[:10]
    image = os.environ.get("POLLY_TEST_IMAGE", name)
    platform = os.environ.get("POLLY_TEST_PLATFORM")
    build = ["docker", "build", "--tag", image]
    if platform:
        build += ["--platform", platform]
    # Exercise Docker's own ignore matcher, including a deliberately planted private file.
    with tempfile.NamedTemporaryFile(prefix="polly-secret-", suffix=".yaml", dir=ROOT) as canary:
        canary.write(b"password: must-not-enter-the-build-context\n")
        canary.flush()
        probe = ("FROM ubuntu:24.04\nCOPY . /context\nRUN test ! -e /context/.git "
                 "&& test ! -e /context/.build && test ! -e /context/node_modules "
                 "&& test ! -e /context/Packages/PollyWeb/.build "
                 f"&& test ! -e /context/{Path(canary.name).name}\n")
        run("docker", "build", "--file", "-", str(ROOT), input=probe)
        print("✅ Docker context excludes private config, Git, dependencies and build caches.", flush=True)
    revision = run("git", "-C", str(ROOT), "rev-parse", "HEAD")
    print(f"Building {image} from {revision} (plus current working changes)", flush=True)
    subprocess.run([*build, "--build-arg", f"REVISION={revision}", str(ROOT)], check=True)
    print(run("docker", "image", "inspect", image, "--format", "{{.Id}} {{.Os}}/{{.Architecture}}"), flush=True)
    with tempfile.TemporaryDirectory(prefix="polly-container-") as temporary:
        directory = Path(temporary)
        password = "container-viewer-" + uuid.uuid4().hex
        secret = directory / "viewer.hash"
        config = directory / "polly.yaml"
        config.write_bytes((ROOT / "examples/polly-web.mock.yaml").read_bytes())
        secret.write_text(run("docker", "run", "--rm", "-i", image, "hash-password", input=password + "\n") + "\n")
        for path in (config, secret):
            path.chmod(0o400)
        originals = {p: p.read_bytes() for p in (config, secret)}
        env = dict(os.environ, POLLY_IMAGE=image, POLLY_CONFIG=str(config),
                   POLLY_VIEWER_PASSWORD_HASH_FILE=str(secret), POLLY_VIEWER_USERNAME="viewer",
                   POLLY_UID=str(os.getuid() or 10001), POLLY_GID=str(os.getgid() or 10001),
                   POLLY_PORT="0")
        # Root CI runners still exercise a non-root service with private mounts.
        if os.getuid() == 0:
            for path in (config, secret):
                os.chown(path, 10001, 10001)
        compose = ["docker", "compose", "--project-name", name, "--file", str(ROOT / "compose.yaml"),
                   "--file", str(ROOT / "compose.mock.yaml")]
        try:
            rendered = json.loads(run(*compose, "config", "--format", "json", env=env))
            assert rendered["services"]["polly"]["ports"][0]["host_ip"] == "127.0.0.1"
            run(*compose, "up", "--detach", "--no-build", env=env)
            container = run(*compose, "ps", "--quiet", "polly", env=env)
            inspect = json.loads(run("docker", "inspect", container))[0]
            assert inspect["Config"]["User"].split(":")[0] != "0"
            assert inspect["HostConfig"]["ReadonlyRootfs"]
            assert all(not m["RW"] for m in inspect["Mounts"] if m["Type"] == "bind")
            runtime = run("docker", "exec", container, "sh", "-ec",
                          "test -s /etc/ssl/certs/ca-certificates.crt; "
                          "! command -v swift; ! command -v node; "
                          "test ! -e /app/polly.yaml; test ! -e /app/.git; id -u")
            assert runtime != "0"
            image_files = run("docker", "run", "--rm", "--entrypoint", "find", image, "/app", "-type", "f")
            assert "/app/polly-web" in image_files
            assert all(path == "/app/polly-web" or path.startswith("/app/PollyWeb_PollyWeb.bundle/")
                       for path in image_files.splitlines())
            trust = subprocess.run(["docker", "exec", "-i", container, "openssl", "s_client",
                                    "-connect", "github.com:443", "-servername", "github.com",
                                    "-verify_return_error", "-brief"], input="", text=True,
                                   capture_output=True, timeout=30, check=True)
            assert "Verification: OK" in trust.stderr, "Runtime CA trust did not verify a real TLS peer"
            print("✅ Runtime CA trust verified github.com over TLS.", flush=True)
            for iteration in range(2):
                print(f"HTTP checks from a separate container, run {iteration + 1}", flush=True)
                print(run("docker", "run", "--rm", "--network", name + "_default", "-i",
                          "--mount", f"type=bind,source={ROOT},target=/checkout,readonly",
                          "node:22.14.0-bookworm-slim", "node", "/checkout/scripts/test-container-http.mjs",
                          input=password), flush=True)
                assert all(p.read_bytes() == content for p, content in originals.items())
                if iteration == 0:
                    run(*compose, "restart", "polly", env=env)
            port = run(*compose, "port", "polly", "8088", env=env)
            print(run("node", str(ROOT / "scripts/test-container-browser.mjs"),
                      env=dict(os.environ, POLLY_CONTAINER_URL="http://" + port), input=password), flush=True)
            logs = run(*compose, "logs", "--no-color", "polly", env=env)
            assert all(value not in logs for value in (password, secret.read_text().strip(), "nagiosadmin"))
            print("✅ Container HTTP, authentication, assets, restart, private mounts and unchanged configuration passed.", flush=True)
        finally:
            run(*compose, "down", "--volumes", "--remove-orphans", env=env)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        print(error.stdout or "")
        print(error.stderr or "")
        raise
