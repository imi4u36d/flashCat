#!/usr/bin/env python3
"""Serve a model flashCat keeps in its own directory, with Splash's engine.

flashCat's models live outside Splash's models directory, and `splash serve`
only takes a Hub repository ID (it resolves a repository, it never serves a
path), so this script prepares the files itself —

    install.local.prepare_local_model, the installer's documented interface
    for applications that start the server on what it prepares

— and then execs the runtime's own server on the directory it prepared, the
way `install/launcher.py` does after it installs a Hub model. It makes no
network request: no Hub ID is resolved and no download happens.

    flashcat_serve.py --runtime RUNTIME --models-dir DIR --target TARGET
                      [--draft DIR] [--mmproj FILE] --model OWNER/REPO
                      --port PORT [--language-only] [SERVER OPTION ...]

--runtime is the Splash release or checkout (the directory holding install/,
server/ and engine/), --models-dir is where preparations are kept (flashCat's
own models directory). --target is a GGUF file, any part of a split GGUF, or
a model directory; --draft is a DFlash2 draft directory (config.json and
safetensors weights); --mmproj is a GGUF vision projector.

Everything else, --language-only and --offline aside, goes to the server
unchanged. Exit status 1 with "error: ..." on stderr means the files could
not be prepared.
"""

import os
import signal
import subprocess
import sys
import time
from pathlib import Path

STOP_SIGNALS = (signal.SIGINT, signal.SIGTERM)

# The server keeps this process's pid through the exec below, so a detached
# watchdog can end it when the flashCat app that started it is gone: otherwise
# an app that quits or crashes leaves the port bound until the next launch
# reclaims it.
WATCHDOG = """
import os, signal, sys, time

child, parent = (int(argument) for argument in sys.argv[1:3])

def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False

while alive(parent) and alive(child):
    time.sleep(2)
if alive(child):
    try:
        os.kill(child, signal.SIGINT)
    except OSError:
        pass
    for _ in range(15):
        if not alive(child):
            break
        time.sleep(1)
    if alive(child):
        try:
            os.kill(child, signal.SIGKILL)
        except OSError:
            pass
"""

# flashCat's own arguments; every other argument is the server's.
VALUE_FLAGS = {
    "--runtime": "runtime",
    "--models-dir": "models_dir",
    "--target": "target",
    "--draft": "draft",
    "--mmproj": "mmproj",
    "--model": "model",
    "--port": "port",
}
SWITCH_FLAGS = {"--language-only": "language_only", "--offline": "offline"}


def parse(argv):
    """flashCat's arguments, and the server's in order."""
    values = {
        "runtime": None,
        "models_dir": None,
        "target": None,
        "draft": None,
        "mmproj": None,
        "model": None,
        "port": None,
        "language_only": False,
        "offline": False,
    }
    forwarded = []
    index = 0
    while index < len(argv):
        flag, separator, inline = argv[index].partition("=")
        if flag in VALUE_FLAGS:
            if separator:
                values[VALUE_FLAGS[flag]] = inline
                index += 1
            elif index + 1 < len(argv):
                values[VALUE_FLAGS[flag]] = argv[index + 1]
                index += 2
            else:
                raise ValueError(f"{flag} needs a value")
        elif flag in SWITCH_FLAGS:
            values[SWITCH_FLAGS[flag]] = True
            index += 1
        else:
            forwarded.append(argv[index])
            index += 1
    required = ("runtime", "models_dir", "target", "model", "port")
    missing = [name for name in required if values[name] in (None, "")]
    if missing:
        raise ValueError("missing " + ", ".join("--" + name.replace("_", "-") for name in missing))
    values["port"] = int(values["port"])
    values["forwarded"] = forwarded
    return values


def main(argv):
    try:
        args = parse(argv)
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    runtime = Path(args["runtime"]).expanduser().resolve()
    if str(runtime) not in sys.path:
        sys.path.insert(0, str(runtime))
    try:
        from install.local import ModelError, prepare_local_model
    except ImportError as error:
        print(f"error: {runtime} is not a Splash runtime ({error})", file=sys.stderr)
        return 1

    if args["language_only"] and args["mmproj"]:
        print("==> flashCat 仅文本模式：忽略视觉投影器", flush=True)
        args["mmproj"] = None

    print(f"==> flashCat 准备本地模型：{args['target']}", flush=True)
    try:
        model = prepare_local_model(
            args["target"],
            args["draft"],
            mmproj=args["mmproj"],
            language_only=args["language_only"],
            models_dir=args["models_dir"],
        )
    except ModelError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"==> flashCat 已准备：{model}", flush=True)

    # The server of this runtime, from any working directory: -P keeps the
    # directory, which may hold a package of the same name, off sys.path, and
    # PYTHONPATH names the root. The server holds the prepared directory from
    # startup until it exits, however a later preparation moves past it.
    command = [
        sys.executable,
        "-u",
        "-P",
        "-m",
        "server.server",
        str(model),
        "--model",
        args["model"],
        "--binary",
        str(runtime / "engine" / "splash"),
        "--port",
        str(args["port"]),
        *args["forwarded"],
    ]
    environment = dict(
        os.environ,
        PYTHONUNBUFFERED="1",
        TRANSFORMERS_VERBOSITY="error",
        PYTHONPATH=str(runtime),
    )
    # The exec resets the handlers; the server unblocks the signals once its
    # own are in place, past its imports (as `splash serve` does).
    try:
        subprocess.Popen(
            [
                sys.executable,
                "-u",
                "-c",
                WATCHDOG,
                str(os.getpid()),
                str(os.getppid()),
            ],
            start_new_session=True,
        )
    except OSError:
        pass
    signal.pthread_sigmask(signal.SIG_BLOCK, STOP_SIGNALS)
    os.execve(command[0], command, environment)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
