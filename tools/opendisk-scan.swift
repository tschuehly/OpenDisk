import Foundation

@main
struct OpenDiskScanCLI {
    static func main() async throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2 else {
            fputs("usage: opendisk-scan PATH OUTPUT\n", stderr)
            exit(2)
        }

        let path = arguments.removeFirst()
        let output = arguments.removeFirst()
        let startedAt = Date()
        let engine = ScanEngine()
        let result = await engine.scan(path: path) { event in
            if case let .progress(progress) = event {
                fputs(
                    "\rScanned \(progress.itemsScanned) items (\(progress.scannedBytes) bytes)",
                    stderr
                )
            }
        }
        let finishedAt = Date()
        try ScanJSONExporter.write(
            tree: result.tree,
            unreadableDirectories: result.unreadableDirectories,
            startedAt: startedAt,
            finishedAt: finishedAt,
            to: URL(fileURLWithPath: output)
        )
        fputs("\nWrote \(output) (\(result.tree.nodeCount) nodes)\n", stderr)
    }
}
