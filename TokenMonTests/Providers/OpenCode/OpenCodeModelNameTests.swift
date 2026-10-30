@testable import TokenMon
import XCTest

final class OpenCodeModelNameTests: XCTestCase {
    func testModelDisplayNames() {
        XCTAssertEqual(OpenCodeModelName.display("gpt-5.4-mini"), "GPT-5.4 Mini")
        XCTAssertEqual(OpenCodeModelName.display("glm-5.1"), "GLM-5.1")
        XCTAssertEqual(OpenCodeModelName.display("kimi-k2.6"), "Kimi K2.6")
        XCTAssertEqual(OpenCodeModelName.display("qwen3.6-plus"), "Qwen3.6 Plus")
        XCTAssertEqual(OpenCodeModelName.display("minimax-m3"), "MiniMax M3")
        XCTAssertEqual(OpenCodeModelName.display("deepseek-v4-flash-free"), "DeepSeek V4 Flash Free")
        XCTAssertEqual(OpenCodeModelName.display("claude-sonnet-4-5"), "Claude Sonnet 4.5")
        XCTAssertEqual(OpenCodeModelName.display("muse-spark-1.2-contributor-free"), "Muse Spark")
    }
}
