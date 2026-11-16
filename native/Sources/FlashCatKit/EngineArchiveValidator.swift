// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation

// MARK: - Archive links

/// A `tar -tvzf` entry whose type is a link.
///
/// pack 可以带链接——Python 发行包本来就有一批同目录的软链——但目标不能出包：
/// `pack/link -> ~/.ssh/id_rsa` 能把包外文件拉进来，`validate` 再给它 `chmod 755`
/// 并启动，就成了在包外执行东西。
struct ArchiveLink: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// `l` 开头：目标相对链接自己所在的目录。
        case symbolic
        /// `h` 开头：目标相对归档根。
        case hard
    }

    var kind: Kind
    /// 归档里的条目名（解包前的位置）。
    var path: String
    var target: String
}

// MARK: - Archive inspection

/// 一次归档检查的结论：解包时要去掉几层目录，以及归档里带着哪些链接。
struct ArchiveInspection: Equatable, Sendable {
    /// `--strip-components` 的取值。
    var stripComponents: Int
    /// 归档里的链接。它们的目标已按 strip 之后的坐标验过。
    var links: [ArchiveLink]
}

/// 归档校验：tar 列表 → 条目模型 → 安全检查。
///
/// 这块逻辑独立于安装编排：它不认识 URLSession、版本名或文件锁，只吃 tar 打出来
/// 的文本行和一份落盘快照。抽出来之后「路径穿越 / 绝对路径 / 硬链出包」这些安全
/// 判定可以被直接单测，`EngineInstaller` 只留「下载 → 校验 → 解包 → 激活」的编排。
enum EngineArchiveValidator {

    /// 校验整个归档并给出解包计划。任何一条不合格都整包拒绝——半信半疑地解包
    /// 等于把风险留给了后面的 `chmod`/启动。
    static func inspect(entries: [String], listing: [String]) throws -> ArchiveInspection {
        try validate(entries: entries)
        let strip = stripComponents(for: entries)
        let links = try links(inListing: listing, names: entries)
        try validate(links: links, stripComponents: strip)
        return ArchiveInspection(stripComponents: strip, links: links)
    }

    /// A tar entry that is absolute or climbs out with `..` would land outside
    /// the staging directory, so the whole archive is rejected.
    static func validate(entries: [String]) throws {
        for entry in entries {
            if entry.hasPrefix("/") || entry.hasPrefix("~/") {
                throw EngineInstallError.unsafeArchiveEntry(entry)
            }
            if pathComponents(entry).contains("..") {
                throw EngineInstallError.unsafeArchiveEntry(entry)
            }
        }
    }

    /// 从带类型的列表里挑出链接。看不懂的一行按失败处理：那可能正是被塞进来的
    /// 一条链接。
    static func links(inListing listing: [String], names: [String]) throws -> [ArchiveLink] {
        let known = names.sorted { $0.count > $1.count }
        var links: [ArchiveLink] = []
        for line in listing {
            guard let first = line.first, first == "l" || first == "h" else { continue }
            let kind: ArchiveLink.Kind = first == "l" ? .symbolic : .hard
            let separator = kind == .symbolic ? " -> " : " link to "
            guard let (path, target) = splitName(line, at: separator, known: known),
                !target.isEmpty
            else {
                throw EngineInstallError.unsafeArchiveLink(line)
            }
            links.append(ArchiveLink(kind: kind, path: path, target: target))
        }
        return links
    }

    /// 切出「条目名 + 目标」。名字里可以有空格，甚至可以带 ` -> ` 这串字面量，
    /// 所以既不按列数、也不按第一个分隔符切：在归档的名字表里找正好停在这里的
    /// 最长后缀——tar 打印的一定是归档里的原名。GNU tar 与 bsdtar 的列数不同，
    /// 这样也不受影响。
    private static func splitName(
        _ line: String,
        at separator: String,
        known: [String]
    ) -> (path: String, target: String)? {
        var start = line.startIndex
        while let range = line.range(of: separator, range: start..<line.endIndex) {
            let head = line[..<range.lowerBound]
            if let name = known.first(where: { nameStops(head: head, name: $0) }) {
                return (name, String(line[range.upperBound...]))
            }
            start = range.upperBound
        }
        return nil
    }

    /// `head` 是「元数据 + 名字」，元数据以空白收尾；名字里也可能有空格，所以
    /// 只要求名字前面是空白，不假设有多少列。
    private static func nameStops(head: Substring, name: String) -> Bool {
        guard head.hasSuffix(name) else { return false }
        let before = head.dropLast(name.count)
        return before.isEmpty || before.last == " " || before.last == "\t"
    }

    /// 链接本身可以留，它去哪才是问题。软链的目标相对链接自己所在的目录、硬链
    /// 的目标相对归档根；两者都按 `--strip-components` 之后的坐标解析，任何一步
    /// 越出 pack 根都整包拒绝。
    static func validate(links: [ArchiveLink], stripComponents: Int) throws {
        for link in links where !staysInsideRoot(link, stripComponents: stripComponents) {
            let arrow = link.kind == .symbolic ? "->" : "link to"
            throw EngineInstallError.unsafeArchiveLink("\(link.path) \(arrow) \(link.target)")
        }
    }

    /// 解析链接目标，看它是否还留在解包目录里：绝对路径与 `~` 直接拒绝，`..`
    /// 从根往上爬也拒绝。
    static func staysInsideRoot(_ link: ArchiveLink, stripComponents: Int) -> Bool {
        let target = link.target
        guard !target.hasPrefix("/"), !target.hasPrefix("~") else { return false }

        // 软链从链接所在的目录出发，硬链从归档根出发。
        var stack: [String]
        switch link.kind {
        case .symbolic:
            let components = strippedComponents(link.path, stripComponents: stripComponents)
            guard !components.isEmpty else { return false }
            stack = Array(components.dropLast())
        case .hard:
            stack = []
        }

        for component in pathComponents(target) {
            if component == ".." {
                guard !stack.isEmpty else { return false }
                stack.removeLast()
            } else {
                stack.append(component)
            }
        }

        // 硬链要指向一个真条目：`--strip-components` 之后什么都不剩也就不算。
        if link.kind == .hard {
            let strip = min(max(stripComponents, 0), stack.count)
            return !stack.dropFirst(strip).isEmpty
        }
        return true
    }

    /// 条目在解包后的位置：tar 会先去掉最前面的 N 段。
    private static func strippedComponents(_ entry: String, stripComponents: Int) -> [String] {
        var components = pathComponents(entry)
        components.removeFirst(min(max(stripComponents, 0), components.count))
        return components
    }

    /// 解包后的兜底审计。列表解析依赖 tar 的文本格式，这里直接看落盘的每一个
    /// 软链，层级按真实目录算，且不跟随链接（链接目录不再进去逐层展开）：链套链
    /// 时，越界的那一条自己会被抓到。硬链由上面那轮解析负责——tar 造不出指向
    /// 包外的硬链。
    static func validateExtractedLinks(in root: URL) throws {
        try auditLinks(inDirectory: root.path, relative: "", fm: FileManager.default)
    }

    private static func auditLinks(
        inDirectory path: String,
        relative: String,
        fm: FileManager
    ) throws {
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: path)
        } catch {
            throw EngineInstallError.commandFailed("无法检查归档中的链接：\(error.localizedDescription)")
        }
        for name in names {
            let childPath = path + "/" + name
            let childRelative = relative.isEmpty ? name : relative + "/" + name
            if let target = try? fm.destinationOfSymbolicLink(atPath: childPath) {
                let link = ArchiveLink(kind: .symbolic, path: childRelative, target: target)
                guard staysInsideRoot(link, stripComponents: 0) else {
                    throw EngineInstallError.unsafeArchiveLink("\(childRelative) -> \(target)")
                }
                continue
            }
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: childPath, isDirectory: &isDirectory), isDirectory.boolValue {
                try auditLinks(inDirectory: childPath, relative: childRelative, fm: fm)
            }
        }
    }

    /// Whether the archive wraps everything in one top-level directory. That
    /// decides `--strip-components 1`; a flat archive must not get it or the
    /// manifest would be stripped away with the folder name.
    static func stripComponents(for entries: [String]) -> Int {
        var head: String?
        for entry in entries {
            let components = pathComponents(entry)
            guard let first = components.first else { continue }
            // 只有一条路径分量、又不以 "/" 结尾，说明它是归档根上的文件（tar 给
            // 目录条目补 "/"）。这种平铺归档 strip 1 会把根上的文件（例如
            // manifest.json）整条丢掉，解包目录只剩空壳，最后报「无法解码清单」。
            if components.count == 1, !entry.hasSuffix("/") { return 0 }
            if let head {
                if head != first { return 0 }
            } else {
                head = first
            }
        }
        return head == nil ? 0 : 1
    }

    /// Splits an archive entry into meaningful components, dropping the `./`
    /// prefix tar sometimes writes.
    static func pathComponents(_ entry: String) -> [String] {
        entry.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." }
    }
}
