// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import Foundation
import PDFKit

/// 文本 / 视觉对话里挂的一个文件附件。正文在挂上时抽取一次，发送时随
/// `engineContent` 一起交给引擎；气泡里只显示名字，不把文件内容摊开。
struct ChatFileAttachment: Identifiable, Equatable {
    let id = UUID()
    let path: String
    let name: String
    let byteSize: Int
    let text: String
    /// 超过 `ChatAttachmentReader.maxCharacters` 时只保留前一段。
    let truncated: Bool

    var kindLabel: String {
        let ext = (name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "TXT" : ext
    }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)
    }

    var metaText: String {
        truncated ? "\(kindLabel) · \(sizeText) · 已截断" : "\(kindLabel) · \(sizeText)"
    }
}

/// 本地附件读取：纯文本 / 源码按 UTF-8 解码，PDF 走 PDFKit，RTF 走
/// NSAttributedString。任何读不出文字的二进制文件都退回一句可读的错误，
/// 而不是把乱码塞进提示词。
enum ChatAttachmentReader {
    static let maxBytes = 4 * 1024 * 1024
    static let maxCharacters = 60_000
    static let maxFiles = 4
    static let maxImages = 6

    enum Failure: LocalizedError {
        case tooLarge
        case unreadable
        case unsupported
        case empty

        var errorDescription: String? {
            switch self {
            case .tooLarge: return "附件超过 4 MB，先压缩或截取一段再试。"
            case .unreadable: return "读不出这个文件的文字。"
            case .unsupported: return "这个文件不是可读取的文本或 PDF。"
            case .empty: return "这个文件里没有可用的文字。"
            }
        }
    }

    static func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func read(_ url: URL) throws -> ChatFileAttachment {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile != false else { throw Failure.unreadable }
        let byteSize = values?.fileSize ?? 0
        guard byteSize <= maxBytes else { throw Failure.tooLarge }

        let ext = url.pathExtension.lowercased()
        let raw: String
        if ext == "pdf" {
            raw = try pdfText(url)
        } else if ext == "rtf" {
            raw = try rtfText(url)
        } else {
            raw = try plainText(url)
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.empty }
        let truncated = trimmed.count > maxCharacters
        let text = truncated ? String(trimmed.prefix(maxCharacters)) : trimmed
        return ChatFileAttachment(
            path: url.path,
            name: url.lastPathComponent,
            byteSize: byteSize,
            text: text,
            truncated: truncated)
    }

    /// 一段文件正文怎么塞进引擎提示词：抬头带文件名，模型才知道边界。
    static func promptBlock(for attachment: ChatFileAttachment) -> String {
        var header = "[附件：\(attachment.name)"
        if attachment.truncated { header += "（内容过长，只保留前 \(maxCharacters) 字）" }
        header += "]"
        return "\(header)\n\(attachment.text)\n[/附件]"
    }

    private static func pdfText(_ url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else { throw Failure.unreadable }
        var text = ""
        for index in 0..<document.pageCount {
            guard text.count < maxCharacters else { break }
            if let page = document.page(at: index), let pageText = page.string {
                text += pageText + "\n"
            }
        }
        return text
    }

    private static func rtfText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard
            let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil)
        else { throw Failure.unreadable }
        return attributed.string
    }

    private static func plainText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        // 先按 UTF-8；失败再按系统西文编码兜一次（老 txt / csv 很常见）。
        let decoded =
            String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        guard let decoded else { throw Failure.unsupported }
        // 二进制文件经常能“解码”成一串控制字符：有 NUL 或控制字符占比过高
        // 就当成不支持，避免把乱码发给模型。
        if decoded.unicodeScalars.contains(where: { $0.value == 0 }) {
            throw Failure.unsupported
        }
        let controls = decoded.unicodeScalars.filter {
            $0.value < 0x20 && $0 != "\n" && $0 != "\t" && $0 != "\r"
        }
        if !decoded.isEmpty, Double(controls.count) / Double(decoded.count) > 0.02 {
            throw Failure.unsupported
        }
        return decoded
    }
}
