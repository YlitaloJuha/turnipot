import Foundation
import NotchCore

// Minimal test runner (XCTest / swift-testing unavailable without Xcode).
// Run: swift run turnipot-selftest
// Add cases with check(name) { ... return condition }. Implementers: put your tests in
// separate files in this directory as `func registerXxxTests()` and call them below.

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passes = 0

func check(_ name: String, _ condition: @autoclosure () -> Bool, file: StaticString = #file, line: UInt = #line) {
    if condition() { passes += 1 } else { failures += 1; print("FAIL \(name) (\(file):\(line))") }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ name: String, file: StaticString = #file, line: UInt = #line) {
    if a == b { passes += 1 } else { failures += 1; print("FAIL \(name): \(a) != \(b) (\(file):\(line))") }
}

// MARK: Models
expectEqual(NotchPaths.encodeProjectDirName(cwd: "/Users/x/Work Projects/acme-api"), "-Users-x-Work-Projects-acme-api", "encode cwd")
expectEqual(NotchPaths.encodeProjectDirName(cwd: "/Users/x/.claude"), "-Users-x--claude", "encode dot dir")
expectEqual(PermissionRequest.summarize(toolName: "Bash", toolInput: .object(["command": .string("npm test")])), "npm test", "summary")
expectEqual(TokenTotals.format(12_345), "12.3k", "format k")

// MARK: Component tests (each implementer fills only their own <X>Tests.swift file)
registerTranscriptTests()
registerUsageTests()
registerSessionTests()
registerAppStateTests()
registerSubagentTests()
registerTurnipTests()
registerAttentionTests()
registerReplyTests()
registerHostTests()
registerQuestionTests()
registerMigrationTests()
registerHapticsTests()
registerScrollGestureTests()
registerRowTests()
registerHotKeyGateTests()
registerGuardTests()
registerDistributionTests()

print("selftest: \(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
