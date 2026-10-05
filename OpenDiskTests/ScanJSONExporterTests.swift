import Foundation
import Testing
@testable import OpenDisk

@Suite("Scan JSON export")
struct ScanJSONExporterTests {

    @Test("replaces an existing destination only after a complete write")
    func replacesExistingDestination() throws {
        var firstTree = FileTree(rootName: "/Volumes/Test")
        firstTree.addNode(
            name: "first.txt", parent: FileTree.rootID,
            size: 1, isDirectory: false
        )
        firstTree.rollUpDirectorySizes()

        var secondTree = FileTree(rootName: "/Volumes/Test")
        secondTree.addNode(
            name: "second.txt", parent: FileTree.rootID,
            size: 2, isDirectory: false
        )
        secondTree.rollUpDirectorySizes()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenDiskExport-\(UUID().uuidString)")
        let output = directory.appendingPathComponent("scan.json")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try ScanJSONExporter.write(
            tree: firstTree, unreadableDirectories: 0,
            startedAt: date, finishedAt: date, to: output
        )
        try ScanJSONExporter.write(
            tree: secondTree, unreadableDirectories: 0,
            startedAt: date, finishedAt: date, to: output
        )

        let root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: output))
                as? [String: Any]
        )
        let nodes = try #require(root["nodes"] as? [[String: Any]])
        #expect(nodes.last?["name"] as? String == "second.txt")
    }

    @Test("writes a relative reachable tree with exact byte values")
    func writesExportableScan() throws {
        var tree = FileTree(rootName: "/Volumes/Test")
        _ = tree.appendUnlinked(name: "detached", size: 999, isDirectory: false)
        let documents = tree.addNode(
            name: "Documents \"2026\"", parent: FileTree.rootID,
            size: 0, isDirectory: true
        )
        tree.addNode(
            name: "report — épreuve.txt", parent: documents,
            size: 5_000_000_000_000, isDirectory: false
        )
        tree.rollUpDirectorySizes()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenDiskExport-\(UUID().uuidString)")
        let output = directory.appendingPathComponent("scan.json")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        try ScanJSONExporter.write(
            tree: tree,
            unreadableDirectories: 2,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_002),
            to: output
        )

        let root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: output))
                as? [String: Any]
        )
        #expect(root["format"] as? String == "opendisk.scan")
        #expect(root["schemaVersion"] as? Int == 1)
        #expect(root["pathMode"] as? String == "relative")
        #expect(root["truncated"] as? Bool == false)

        let scan = try #require(root["scan"] as? [String: Any])
        #expect(scan["state"] as? String == "finished")
        #expect(scan["coverage"] as? String == "best_effort")
        #expect(scan["reportedUnreadableDirectories"] as? Int == 2)

        let nodes = try #require(root["nodes"] as? [[String: Any]])
        #expect(nodes.map { $0["id"] as? Int } == [0, 2, 3])
        #expect(nodes[0]["name"] as? String == ".")
        #expect(nodes[0]["parentId"] is NSNull)
        #expect(nodes[1]["name"] as? String == "Documents \"2026\"")
        #expect(nodes[2]["name"] as? String == "report — épreuve.txt")
        #expect(nodes[2]["allocatedBytes"] as? String == "5000000000000")
    }
}
