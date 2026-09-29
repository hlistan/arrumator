import Foundation

let usage = """
    Renders and checks the synthetic document corpus used by Arrumator's extractor tests and classifier evaluation.

    Usage:
      fixturegen --out <directory> [--seed <n>]   render every fixture and expected.json (default seed 42)
      fixturegen --verify <directory>             check a rendered corpus (files, text layers, OCR, determinism)
    """

enum Command {
    case generate(URL, seed: UInt64)
    case verify(URL)
}

func parse(_ arguments: [String]) -> Command? {
    var output: URL?
    var verify: URL?
    var seed: UInt64 = 42
    var remaining = arguments[...]
    while let flag = remaining.popFirst() {
        guard let value = remaining.popFirst() else { return nil }
        switch flag {
        case "--out": output = URL(fileURLWithPath: value, isDirectory: true)
        case "--verify": verify = URL(fileURLWithPath: value, isDirectory: true)
        case "--seed":
            guard let parsed = UInt64(value) else { return nil }
            seed = parsed
        default: return nil
        }
    }
    switch (output, verify) {
    case (let output?, nil): return .generate(output, seed: seed)
    case (nil, let verify?): return .verify(verify)
    default: return nil
    }
}

guard let command = parse(Array(CommandLine.arguments.dropFirst())) else {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(64)
}

do {
    switch command {
    case .generate(let root, let seed):
        let summary = try Generator(settings: .standard, seed: seed).generate(into: root)
        print("Wrote \(summary.fileCount) fixtures + \(Manifest.fileName) to \(root.path) " +
              "(\(ByteCountFormatter.string(fromByteCount: Int64(summary.totalBytes), countStyle: .file)), seed \(seed)).")
    case .verify(let root):
        let passed = try await Verifier(settings: .standard, root: root).run()
        exit(passed ? 0 : 1)
    }
} catch {
    FileHandle.standardError.write(Data("fixturegen: \(error)\n".utf8))
    exit(1)
}
