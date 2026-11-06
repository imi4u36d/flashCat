import XCTest
@testable import FlashCatKit

final class GatewayModelRoutingTests: XCTestCase {
    func testChoosesTheEngineThatOwnsTheRequestedModel() {
        let active = EngineID.omlx
        let other = EngineID.mtplx
        let route = GatewayModelRouting.resolve(
            requestedModel: "Youssofal--Qwen3.8-27B-oQ4e-mtp",
            orderedEngines: [active, other],
            modelsByEngine: [
                active: ["Jundot--Qwen3.8-27B-oQ4e-mtp"],
                other: ["Youssofal--Qwen3.8-27B-oQ4e-mtp"],
            ])
        XCTAssertEqual(route, GatewayModelRoute(model: "Youssofal--Qwen3.8-27B-oQ4e-mtp", engine: other))
    }

    func testActiveEngineWinsWhenAnIdExistsInMoreThanOneDirectory() {
        let route = GatewayModelRouting.resolve(
            requestedModel: "shared",
            orderedEngines: [.splash, .omlx],
            modelsByEngine: [.splash: ["shared"], .omlx: ["shared"]])
        XCTAssertEqual(route?.engine, .splash)
    }

    func testUnknownModelDoesNotFallBackToTheActiveModel() {
        XCTAssertNil(GatewayModelRouting.resolve(
            requestedModel: "not-installed",
            orderedEngines: [.splash, .omlx],
            modelsByEngine: [.splash: ["a"], .omlx: ["b"]]))
    }

    func testBlankModelIsNotRouted() {
        XCTAssertNil(GatewayModelRouting.resolve(
            requestedModel: "   ",
            orderedEngines: [.splash],
            modelsByEngine: [.splash: ["a"]]))
    }
}
