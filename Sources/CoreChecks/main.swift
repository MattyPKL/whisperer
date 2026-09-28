import Foundation

// Tiny check runner. Swift Testing does not discover tests under Command Line Tools,
// so `swift run CoreChecks` is the test command (exit 1 on any failure).
nonisolated(unsafe) var failures: [String] = []
nonisolated(unsafe) var current = ""

func expect(_ ok: @autoclosure () throws -> Bool, file: String = #fileID, line: Int = #line) {
    do { if try !ok() { failures.append("\(current) failed at \(file):\(line)") } }
    catch { failures.append("\(current) threw \(error) at \(file):\(line)") }
}

func expectThrows(file: String = #fileID, line: Int = #line, _ body: () throws -> Void) {
    do { try body(); failures.append("\(current) expected a throw at \(file):\(line)") } catch {}
}

var ran = 0
for (name, check) in allChecks {
    current = name
    do { try check() } catch { failures.append("\(name) threw \(error)") }
    ran += 1
}
if failures.isEmpty {
    print("CoreChecks: \(ran) checks, all passed")
} else {
    failures.forEach { print("FAIL \($0)") }
    print("CoreChecks: \(ran) checks, \(failures.count) failures")
    exit(1)
}
