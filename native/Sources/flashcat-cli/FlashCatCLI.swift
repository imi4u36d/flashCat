import Darwin
import Foundation
import FlashCatCLICore

/// Thin executable wrapper: all behavior lives in `FlashCatCLICore` so the
/// parser, formatters and control client can be unit tested.
@main
struct FlashCatCLIMain {
    static func main() async {
        let code = await CLI.run(arguments: Array(CommandLine.arguments.dropFirst()))
        exit(code)
    }
}
