import XCTest
@testable import FlashCat

final class ModelFamilyTests: XCTestCase {
    func testMiMoTakesPriorityOverEmbeddedQwen() {
        XCTAssertEqual(
            ModelFamily.resolve(id: "Youssofal/MiMo-V2.6-Qwen-9B-MTPLX-Optimized-Speed"),
            .mimo
        )
        XCTAssertEqual(ModelFamily.resolve(id: "XiaomiMiMo/MiMo-VL-7B"), .mimo)
    }

    func testQwenStillResolvesToQwen() {
        XCTAssertEqual(ModelFamily.resolve(id: "Qwen/Qwen3.8-27B"), .qwen)
        XCTAssertEqual(ModelFamily.resolve(id: "mlx-community/Qwen3.6-35B-A3B-4bit"), .qwen)
    }

    func testUnrelatedRepositoryFallsBackToOther() {
        XCTAssertEqual(ModelFamily.resolve(id: "acme/unknown-weights"), .other)
    }
}
