// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Darwin
import FlashCatKit
import Foundation

extension EngineController {
    // MARK: port claim

    var preferredPort: Int {
        EngineStore.shared.configuration(for: id).port ?? descriptor.defaultPort
    }

    /// Ports the app reserves for its own loopback interfaces. An engine may
    /// never claim them, even when the listener is not up yet.
    var reservedPorts: Set<Int> {
        [settings.gatewayPort, settings.controlPort]
    }

    /// Port the engine may bind, or nil when no loopback port is available.
    /// A leftover engine from an earlier session is reaped first — and the
    /// port being free proves nothing: a server killed mid-startup is still
    /// loading weights, holds its memory for minutes and binds its port only
    /// once the load finishes, exactly when a second engine would pile on top.
    func claimPort(_ selectedModel: String) async -> Int? {
        let wanted = preferredPort
        if let stale = readPidFile() {
            if processAlive(stale), processBelongsToPack(stale) {
                guard await reclaimStaleEngine(stale) else {
                    failureMessage = "遗留的服务进程（pid \(stale)）未能退出，无法启动 \(id.displayName)"
                    onChange()
                    return nil
                }
            } else {
                // Stale bookkeeping: the pid is gone, or was reused by a
                // process that is not this pack's engine. Either way it must
                // not be signalled.
                removePidFile()
            }
        }
        let reserved = reservedPorts
        if (1024...65535).contains(wanted), !reserved.contains(wanted), !portOpen(wanted) {
            return wanted
        }

        // Occupied with nothing on the pid file. This app has no evidence the
        // listener is its own leftover, so it never kills blind — it moves on.
        // The allocator walks the engine's band first and then the rest of the
        // loopback range; the port is an internal detail (clients use the
        // gateway), so a full band must not send the reader to a settings page.
        guard
            let claimed = EnginePortAllocator.allocate(
                for: id,
                preferred: wanted,
                taken: reserved,
                isOpen: portOpen)
        else {
            failureMessage = "没有可用的本机端口，无法启动 \(id.displayName)"
            return nil
        }
        note("==> 端口 \(wanted) 不可用，自动改用 \(claimed)")
        return claimed
    }

    /// The engine pack this controller runs, one level up so a leftover from a
    /// previous pack version (same engine, older directory) still matches.
    /// Symlinks are resolved because proc_pidpath reports the canonical path:
    /// a pack under /tmp would otherwise never match its own /private/tmp
    /// executable paths.
    var packMarkerDirectory: String {
        (installation.root.deletingLastPathComponent().path as NSString).resolvingSymlinksInPath
    }

    var orphanCleanupDirectories: [String] {
        [packMarkerDirectory]
    }

    /// Launch-time sweep for processes a crashed or force-quit session left
    /// behind. Nothing of this session runs yet, so any live executable inside
    /// this engine's pack directories is residue: the pack python and the
    /// binaries below it are started by nobody else. SIGKILL straight away —
    /// a leftover stuck inside a weight load cannot act on SIGINT, and its pid
    /// bookkeeping was already removed by the clean-quit path.
    package func sweepOrphans() {
        let markers = orphanCleanupDirectories.map { $0 + "/" }
        for entry in allProcesses() where entry.pid != ProcessInfo.processInfo.processIdentifier {
            guard let path = processExecutablePath(entry.pid),
                markers.contains(where: { path.hasPrefix($0) })
            else { continue }
            note("==> 清扫上次会话遗留的引擎进程（pid \(entry.pid)）")
            killTree(entry.pid, SIGKILL)
        }
    }

    /// The pid's executable lives inside this engine's pack directories — the
    /// only processes this app ever starts there. Guards the reclaim against
    /// firing on a reused pid.
    func processBelongsToPack(_ pid: Int32) -> Bool {
        guard let path = processExecutablePath(pid) else { return false }
        return path.hasPrefix(packMarkerDirectory + "/")
    }

    /// Ends a server left behind by an earlier session: SIGINT to the whole
    /// tree, SIGKILL after the grace, and "gone" means the *process* exited —
    /// not merely that the port came free, which a server still inside a Metal
    /// weight load never signals.
    func reclaimStaleEngine(_ stale: Int32, grace: Double = 10) async -> Bool {
        note("==> 清理上次遗留的 \(id.displayName) 服务进程（pid \(stale)）…")
        killTree(stale, SIGINT)
        let startedAt = Date()
        var escalated = false
        while Date().timeIntervalSince(startedAt) < 90 {
            if !processAlive(stale) {
                removePidFile()
                note("==> 遗留进程已结束")
                return true
            }
            if !escalated, Date().timeIntervalSince(startedAt) > grace {
                escalated = true
                note("==> 遗留进程未在 \(Int(grace)) 秒内退出，强制结束整棵进程树")
                killTree(stale, SIGKILL)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return !processAlive(stale)
    }

    func processAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }
}
