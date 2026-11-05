import XCTest
@testable import FlashCat

final class ModelQuantizationTests: XCTestCase {
    func testGGUFQuantNames() {
        XCTAssertEqual(ModelQuantization.detect(in: "Qwen3.8-Flash-Next-Q4_K_M.gguf"), "Q4_K_M")
        XCTAssertEqual(ModelQuantization.detect(in: "Qwen3.8-IQ3_XXS-00001-of-00002.gguf"), "IQ3_XXS")
        XCTAssertEqual(ModelQuantization.detect(in: "owner/repo:Q2_0"), "Q2_0")
    }

    func testMLXVariantNames() {
        XCTAssertEqual(ModelQuantization.detect(in: "Jundot--Qwen3.8-Flash-Next-oQ4e-mtp"), "oQ4e")
        XCTAssertEqual(ModelQuantization.detect(in: "Qwen3.8-Flash-Next-Sushi-3bpw"), "3 bpw")
    }

    func testBitLabelsAndDtypes() {
        XCTAssertEqual(ModelQuantization.detect(in: "MiniMax-H3-FL2VA-MLX-Serve-8bit"), "8-bit")
        XCTAssertEqual(ModelQuantization.detect(in: "4-bit"), "4-bit")
        XCTAssertEqual(ModelQuantization.detect(in: "BF16"), "BF16")
    }

    func testNamesWithoutAQuantReturnNil() {
        XCTAssertNil(ModelQuantization.detect(in: "Qwen3.8-Flash-Next-DFlash2"))
        XCTAssertNil(ModelQuantization.detect(in: "Youssofal/Qwen3.8-27B-MTPLX-Optimized-Speed"))
    }
}
