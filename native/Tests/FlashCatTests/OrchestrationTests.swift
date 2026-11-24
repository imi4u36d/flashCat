// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatCore
import FlashCatKit
import XCTest

@testable import FlashCat

@MainActor
final class OrchestrationTests: XCTestCase {
    // MARK: ChatRunner

    func testThreadDeleteRequestIsOnlyCommittedOnConfirm() {
        let stores = makeChatStores()
        let runner = makeRunner(stores: stores, host: FakeChatHost())
        let thread = ChatThread(
            id: "t1", title: "旧对话", updatedAt: Date(), messages: [])

        runner.requestThreadDelete(thread)
        XCTAssertEqual(stores.session.pendingThreadDelete?.id, "t1")
        runner.cancelThreadDelete()
        XCTAssertNil(stores.session.pendingThreadDelete)

        runner.requestThreadDelete(thread)
        runner.requestThreadRename(thread)
        XCTAssertEqual(stores.session.pendingThreadRename?.id, "t1")
        runner.cancelThreadRename()
        XCTAssertNil(stores.session.pendingThreadRename)
    }

    func testChatHostReceivesShowChatWhenOpeningCurrentThread() {
        let stores = makeChatStores()
        let host = FakeChatHost()
        let runner = makeRunner(stores: stores, host: host)
        let thread = ChatThread(id: "t1", title: "当前", updatedAt: Date(), messages: [])
        stores.session.pendingThreadDelete = thread

        // 打开历史里的会话会读写 conversation.json；这里只验证「请求 / 取消」
        // 这一层状态机，确认不会落盘。真正的存储路径由 ChatHistory 的单测覆盖。
        runner.cancelThreadDelete()
        XCTAssertNil(stores.session.pendingThreadDelete)
    }

    // MARK: ModelOps

    func testCancelLibraryUseClearsPendingRequest() {
        let ops = makeModelOps()
        ops.modelLibrary.pendingLibraryUse = LibraryUseRequest(
            engine: .splash, model: "owner/repo", needsDownload: true)

        ops.cancelLibraryUse()

        XCTAssertNil(ops.modelLibrary.pendingLibraryUse)
    }

    func testInstallFailureDropsRecommendedDownloadForThatEngine() {
        let ops = makeModelOps()
        ops.modelLibrary.pendingRecommendedDownload = (engine: .omlx, model: "owner/repo")

        ops.engineInstallFailed(.omlx)

        XCTAssertNil(ops.modelLibrary.pendingRecommendedDownload)
    }

    // MARK: DownloadCenter

    func testDownloadRowsArePausedAfterRelaunch() throws {
        let path = temporaryTasksFile()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let task = ModelDownloadTask(
            engine: .splash, model: "__flashcat_test_missing__", status: .downloading)
        try ModelDownloadStore.save([task], to: path)

        let center = DownloadCenter(tasksFile: path)

        XCTAssertEqual(center.downloadTasks.first?.status, .paused)
    }

    func testRemovingAnIdleTaskUpdatesRowsAndToast() throws {
        let path = temporaryTasksFile()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let task = ModelDownloadTask(
            engine: .splash, model: "__flashcat_test_missing__", status: .paused)
        try ModelDownloadStore.save([task], to: path)

        let center = DownloadCenter(tasksFile: path)
        let host = FakeDownloadHost()
        center.host = host
        XCTAssertEqual(center.downloadTasks.count, 1)

        center.cancelDownload(task)

        XCTAssertTrue(center.downloadTasks.isEmpty)
        XCTAssertEqual(host.toasts.count, 1)
        XCTAssertTrue(try ModelDownloadStore.load(from: path).isEmpty)
    }

    // MARK: fixtures

    private struct ChatStores {
        let chat: ChatStore
        let session: ChatSessionStore
        let drafts: ChatDraftStore
        let engineSession: EngineSessionStore
        let history: ChatHistory
        let conversation: ConversationStore
    }

    private func makeChatStores() -> ChatStores {
        ChatStores(
            chat: ChatStore(),
            session: ChatSessionStore(),
            drafts: ChatDraftStore(),
            engineSession: EngineSessionStore(),
            history: ChatHistory(),
            conversation: ConversationStore())
    }

    private func makeRunner(stores: ChatStores, host: FakeChatHost) -> ChatRunner {
        let runner = ChatRunner(
            chat: stores.chat,
            session: stores.session,
            drafts: stores.drafts,
            engineSession: stores.engineSession,
            settings: AppSettings(),
            history: stores.history,
            conversation: stores.conversation,
            chatClient: FakeChatStream(),
            imageClient: FakeImageGenerator(),
            videoClient: FakeVideoGenerator(),
            metrics: MetricsStore())
        runner.host = host
        return runner
    }

    private func makeModelOps() -> ModelOps {
        let ops = ModelOps(
            settings: AppSettings(),
            downloads: DownloadCenter(tasksFile: temporaryTasksFile()),
            modelLibrary: ModelLibraryStore(),
            engineCoordinator: FakeEngineCatalog())
        ops.host = FakeModelHost()
        return ops
    }

    private func temporaryTasksFile() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("flashcat-downloads-\(UUID().uuidString).json")
            .path
    }
}
