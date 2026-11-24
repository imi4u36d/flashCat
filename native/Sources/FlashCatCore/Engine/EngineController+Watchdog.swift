// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Darwin
import FlashCatKit
import Foundation

extension EngineController {
    // MARK: orphan watchdog

    /// Detached last resort for a crashed or force-quit app — the paths where
    /// `dispose` never runs. A python from the pack itself watches the app's
    /// pid; once the app is gone it ends the engine's whole tree within
    /// seconds, instead of leaving a half-loaded 20 GB model resident until
    /// the next launch's sweep gets around to it. On a normal quit the
    /// watchdog finds its engine already dead, kills nothing and exits, so it
    /// needs no management from this side (splash additionally runs its own
    /// python-side watchdog from flashcat_serve.py; the two overlap harmlessly).
    func spawnWatchdog(enginePid: Int32) {
        if !installation.entrypoint.path.contains("/python/") {
            spawnNativeWatchdog(enginePid: enginePid)
            return
        }
        let task = Process()
        task.launchPath = installation.entrypoint.path
        task.arguments = [
            "-u", "-c", Self.watchdogScript,
            String(enginePid),
            String(ProcessInfo.processInfo.processIdentifier),
            packMarkerDirectory,
        ]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            // Best effort only: dispose and the launch sweep remain the
            // primary cleanup, the watchdog just narrows the crash window.
            note("==> 未能启动引擎守护进程（不影响正常启停）：\(error)")
        }
    }

    /// Native single-binary engines do not understand the Python watchdog's
    /// `-c` argument. This watcher uses only macOS system tools and is reused by
    /// every non-Python pack.
    func spawnNativeWatchdog(enginePid: Int32) {
        let task = Process()
        task.launchPath = "/bin/sh"
        // `sh -c script name a b c` assigns `name` to `$0`, not `$1`. Without
        // this placeholder the script's `$1/$2/$3` shift by one: it would treat
        // the app's pid as the engine and the empty marker as the app, then
        // SIGINT flashCat itself the moment the engine starts.
        task.arguments = [
            "-c", Self.nativeWatchdogScript,
            "flashcat-watchdog",
            String(enginePid),
            String(ProcessInfo.processInfo.processIdentifier),
            packMarkerDirectory,
        ]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            note("==> 未能启动引擎守护进程（不影响正常启停）：\(error)")
        }
    }

    static let nativeWatchdogScript = #"""
        engine="$1"
        app="$2"
        marker="$3"

        # Snapshot the tree while the root is alive. Once it exits, its children are
        # re-parented to launchd and `pgrep -P` can no longer tie them back to the
        # engine — walking the tree at kill time (the old behaviour) therefore found
        # nothing to signal exactly when it was needed.
        collect() {
          for child in $(/usr/bin/pgrep -P "$1" 2>/dev/null); do
            printf '%s\n' "$child"
            collect "$child"
          done
        }
        victims="$(collect "$engine")"

        while kill -0 "$app" 2>/dev/null && kill -0 "$engine" 2>/dev/null; do
          sleep 1
        done

        signal_victims() {
          signal="$1"
          for pid in $victims "$engine"; do
            path=$(/bin/ps -p "$pid" -o command= 2>/dev/null) || continue
            case "$path" in
              "$marker"/*) /bin/kill "-$signal" "$pid" 2>/dev/null || true ;;
            esac
          done
        }

        signal_victims INT
        sleep 15
        signal_victims KILL
        """#

    /// Runs as `python -u -c <script> <engine-pid> <app-pid> <pack-marker>`.
    /// Every candidate is re-verified against the pack root through
    /// proc_pidpath before a signal is sent, so a pid that died and was reused
    /// in the polling gap is never hit. The descendant snapshot is taken while
    /// the engine root is still alive — after its death the children are
    /// re-parented to launchd and the chain would be lost.
    static let watchdogScript = #"""
        import ctypes, os, signal, subprocess, sys, time

        engine = int(sys.argv[1])
        app = int(sys.argv[2])
        marker = os.path.realpath(sys.argv[3])

        libproc = None
        try:
            libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
        except OSError:
            pass

        def alive(pid):
            try:
                os.kill(pid, 0)
                return True
            except OSError:
                return False

        def ours(pid):
            if libproc is None:
                return False
            try:
                buf = ctypes.create_string_buffer(4096)
                n = libproc.proc_pidpath(pid, buf, 4096)
                path = buf.value.decode("utf-8", "replace") if n > 0 else ""
            except Exception:
                return False
            return path.startswith(marker + "/")

        def tree(pid):
            pids, index = [pid], 0
            while index < len(pids):
                try:
                    out = subprocess.run(["/usr/bin/pgrep", "-P", str(pids[index])],
                                         capture_output=True, text=True, timeout=5).stdout
                    pids.extend(int(line) for line in out.split())
                except Exception:
                    pass
                index += 1
            return pids

        snapshot = tree(engine)
        while alive(app) and alive(engine):
            snapshot = tree(engine)
            time.sleep(2)

        victims = [pid for pid in snapshot if alive(pid) and ours(pid)]
        for pid in victims:
            try:
                os.kill(pid, signal.SIGINT)
            except OSError:
                pass
        deadline = time.time() + 15
        while victims and time.time() < deadline:
            time.sleep(1)
            victims = [pid for pid in victims if alive(pid)]
        for pid in victims:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        """#

    package func updateCatalog(_ value: ModelCatalog) { catalog = value }

    package func rescanModels() async {
        guard isRunning else { return }
        guard let action = descriptor.modelControl?.rescan else {
            catalog = ModelCatalogService().load()
            return
        }
        let response = await modelControl(
            action,
            target: "",
            fallbackPath: action.path,
            timeout: 20)
        logs.append(
            "==> 重新扫描模型 → HTTP \(response?.status ?? 0)",
            level: (response?.status ?? 0) < 300 ? .system : .warning)
    }
}
