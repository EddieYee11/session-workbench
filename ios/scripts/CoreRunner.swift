import Foundation
@main struct CoreRunner {
    static func main() throws { print("ComCore: \(try CoreChecks.run()) recovery/transport checks passed") }
}
