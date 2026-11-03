#!/usr/bin/env python3
"""Keep a Strata launch in the foreground for flashCat.

Strata's `launch --no-tui` starts a background server and returns. The app's
process controller expects one owned foreground process, so this wrapper:

* stages the bundled signed engine component in a writable per-user directory;
* asks Strata to prepare and start the selected model;
* waits until flashCat stops the wrapper; and
* asks Strata to drain and stop the corresponding service.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import time
import urllib.request
from pathlib import Path


def parse_args() -> tuple[argparse.Namespace, list[str]]:
    parser = argparse.ArgumentParser()
    parser.add_argument("--strata-root", required=True)
    parser.add_argument("--models", required=True)
    parser.add_argument("--support", required=True)
    parser.add_argument("--model-path")
    parser.add_argument("--model-id")
    parser.add_argument("--port", type=int)
    parser.add_argument("--install-only", action="store_true")
    parser.add_argument("--family")
    parser.add_argument("--model")
    return parser.parse_known_args()


def read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def stage_engine(root: Path, support: Path) -> Path:
    source = root / "engine"
    manifest = read_json(source / "engine-component.json")
    version = str(manifest.get("version") or "unknown")
    backend = str(manifest.get("backend") or "metal")
    platform = str(manifest.get("platform") or "macos-arm64")
    component = support / "strata-components" / "engine" / f"{version}-{platform}-{backend}"
    marker = component / ".flashcat-component"
    expected = json.dumps(
        {"version": version, "backend": backend, "platform": platform},
        sort_keys=True,
    )
    try:
        current = marker.read_text(encoding="utf-8")
    except OSError:
        current = ""
    if current != expected:
        component.parent.mkdir(parents=True, exist_ok=True)
        shutil.rmtree(component, ignore_errors=True)
        shutil.copytree(source, component)
        marker.write_text(expected, encoding="utf-8")
    return component


def stage_control(root: Path, support: Path) -> Path:
    """Copy Control to a writable, versioned runtime directory.

    The source pack may live in a signed .app or vendor/engines and must remain
    read-only. Strata installs run configs and optional engine updates into its
    installation folder, so it gets a private copy under flashCat support.
    """
    runtime = support / "strata-runtime"
    marker = runtime / ".flashcat-runtime"
    try:
        version = (root / "VERSION").read_text(encoding="utf-8").strip()
    except OSError:
        version = ""
    expected = f"flashcat-strata-runtime:{version}"
    try:
        current = marker.read_text(encoding="utf-8")
    except OSError:
        current = ""
    if current != expected or not (runtime / "bin" / "strata").is_file():
        shutil.rmtree(runtime, ignore_errors=True)
        shutil.copytree(
            root,
            runtime,
            ignore=shutil.ignore_patterns("models", "engine", ".runtime-check"),
        )
        marker.write_text(expected, encoding="utf-8")
    return runtime


def healthy(port: int) -> bool:
    try:
        with urllib.request.urlopen(
            f"http://127.0.0.1:{port}/health", timeout=1.5
        ) as response:
            return 200 <= response.status < 300
    except Exception:
        return False


def preset_name(port: int) -> str:
    return f"flashcat-{port}"


def run_strata(
    strata: Path,
    root: Path,
    env: dict[str, str],
    args: list[str],
) -> int:
    command = [str(strata), *args]
    completed = subprocess.run(command, cwd=root, env=env)
    return completed.returncode


def main() -> int:
    args, extra = parse_args()
    root = Path(args.strata_root).resolve()
    support = Path(args.support).resolve()
    models = Path(args.models).resolve()
    support.mkdir(parents=True, exist_ok=True)
    models.mkdir(parents=True, exist_ok=True)

    component = stage_engine(root, support)
    runtime = stage_control(root, support)
    env = dict(os.environ)
    env.update(
        {
            "PYTHONNOUSERSITE": "1",
            "PYTHONPATH": str(runtime),
            "STRATA_INSTALL_DIR": str(runtime),
            "STRATA_COMPONENTS_DIR": str(support / "strata-components"),
            "STRATA_ENGINE_BACKEND": read_json(component / "engine-component.json").get(
                "backend", "metal"
            ),
        }
    )
    for key in ("PYTHONHOME", "VIRTUAL_ENV"):
        env.pop(key, None)

    strata = runtime / "bin" / "strata"
    if args.install_only:
        if not args.family or not args.model:
            print("error: --install-only needs --family and --model", file=sys.stderr)
            return 2
        install_args = [
            "install",
            "--family",
            args.family,
            "--model",
            args.model,
            "--data-dir",
            str(models),
            "--no-start",
            "--yes",
        ]
        if args.model_path and Path(args.model_path).exists():
            install_args += ["--gguf-dir", str(Path(args.model_path).resolve())]
        install_args.extend(extra)
        return run_strata(strata, runtime, env, install_args)

    if not args.model_path or not args.model_id or not args.port:
        print("error: launch needs --model-path, --model-id and --port", file=sys.stderr)
        return 2
    model_path = Path(args.model_path).resolve()
    preset = preset_name(args.port)
    launch_args = [
        "launch",
        "--model-path",
        str(model_path),
        "--data-dir",
        str(models),
        "--context",
        "32k",
        "--vision",
        "gpu",
        "--drafting",
        "auto",
        "--tune",
        "skip",
        "--access",
        "local",
        "--port",
        str(args.port),
        "--save-preset",
        preset,
        "--restart",
        "--yes",
        "--no-tui",
        "--output",
        "json",
    ]
    launch_args.extend(extra)

    stopping = False
    app_pid = os.getppid()

    def request_stop(_signum, _frame) -> None:
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)

    code = run_strata(strata, runtime, env, launch_args)
    if code != 0:
        return code
    if not healthy(args.port):
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline and not stopping and not healthy(args.port):
            time.sleep(1)
        if not healthy(args.port):
            print("error: Strata did not become healthy", file=sys.stderr, flush=True)
            run_strata(strata, runtime, env, ["launch", "--stop", "--preset", preset, "--output", "json"])
            return 1

    failures = 0
    while not stopping:
        time.sleep(2)
        if app_pid > 1 and os.getppid() != app_pid:
            stopping = True
            break
        if healthy(args.port):
            failures = 0
        else:
            failures += 1
            if failures >= 15:
                print("error: Strata stopped answering /health", file=sys.stderr, flush=True)
                break

    run_strata(strata, runtime, env, ["launch", "--stop", "--preset", preset, "--output", "json"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
