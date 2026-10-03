import Foundation
import Testing

/// How the tests run a command: they fail, not hang, whatever the command does with its outputs or however long it runs.
@Suite struct ChildProcessTests {
    private static let shell = URL(filePath: "/bin/sh")
    /// More than a pipe holds (64 KiB on macOS), so a writer waits until someone reads.
    private static let moreThanAPipeHolds = 1 << 20

    @Test(.timeLimit(.minutes(1)))
    func aCommandThatFillsItsErrorOutputBeforeWritingItsOutputRunsToItsEnd() throws {
        let outcome = try ChildProcess.run(Self.shell, ["-c", "head -c \(Self.moreThanAPipeHolds) /dev/zero >&2; printf done"],
                                           environment: [:])
        #expect(outcome.status == 0 && outcome.stdout == Data("done".utf8),
                "the command is not left waiting to write its errors while its output is read")
        #expect(outcome.stderr.count == Self.moreThanAPipeHolds, "and every byte of its error output is read")
    }

    @Test(.timeLimit(.minutes(1)))
    func aCommandThatDoesNotEndIsStoppedAndFailsTheTest() throws {
        let deadline: TimeInterval = 0.5
        #expect(throws: ChildProcess.DidNotFinish.self, "a command still running at its deadline fails rather than hangs") {
            try ChildProcess.run(URL(filePath: "/usr/bin/tail"), ["-f", "/dev/null"], environment: [:], deadline: deadline)
        }
    }
}
