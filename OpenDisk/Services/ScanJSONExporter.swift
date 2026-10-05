import Foundation

extension Notification.Name {
    static let exportOpenDiskScanJSON = Notification.Name(
        "OpenDisk.exportScanJSON"
    )
}

/// The immutable finished tree and metadata captured for one export.
struct ScanExportSnapshot: Sendable {
    let tree: FileTree
    let startedAt: Date
    let finishedAt: Date
    let reportedUnreadableDirectories: Int
}

/// Writes a completed scan as a compact, relative-path JSON document.
///
/// The output is streamed to a sibling temporary file and published only
/// after the document is complete, so a failed export cannot replace an
/// existing destination with a partial document.
enum ScanJSONExporter {

    private struct ScanMetadata: Encodable {
        let state = "finished"
        let startedAt: Date
        let finishedAt: Date
        let coverage = "best_effort"
        let reportedUnreadableDirectories: Int
    }

    private struct Prefix: Encodable {
        let format = "opendisk.scan"
        let schemaVersion = 1
        let scan: ScanMetadata
        let pathMode = "relative"
        let truncated = false
    }

    private struct NodeRecord: Encodable {
        let id: Int
        let parentId: Int?
        let name: String
        let isDirectory: Bool
        let allocatedBytes: String

        private enum CodingKeys: String, CodingKey {
            case id, parentId, name, isDirectory, allocatedBytes
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            // Keep the root's parent explicit so consumers can distinguish
            // it from a malformed record with a missing parent.
            try container.encode(parentId, forKey: .parentId)
            try container.encode(name, forKey: .name)
            try container.encode(isDirectory, forKey: .isDirectory)
            try container.encode(allocatedBytes, forKey: .allocatedBytes)
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func write(
        tree: FileTree,
        unreadableDirectories: Int,
        startedAt: Date,
        finishedAt: Date,
        to destination: URL
    ) throws {
        let fileManager = FileManager.default
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
            )
        guard fileManager.createFile(atPath: temporary.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: temporary) else {
            throw CocoaError(.fileWriteUnknown)
        }

        do {
            let encoder = Self.makeEncoder()
            let prefix = Prefix(scan: ScanMetadata(
                startedAt: startedAt,
                finishedAt: finishedAt,
                reportedUnreadableDirectories: unreadableDirectories
            ))
            var prefixData = try encoder.encode(prefix)
            guard prefixData.last == UInt8(ascii: "}") else {
                throw CocoaError(.fileWriteUnknown)
            }
            prefixData.removeLast()
            prefixData.append(contentsOf: Data(",\"nodes\":[".utf8))
            try handle.write(contentsOf: prefixData)

            let reachable = tree.reachabilityBitmap()
            var isFirst = true
            for index in reachable.indices where reachable[index] {
                let id = FileTree.NodeID(index)
                let parent = tree.parent(of: id)
                let record = NodeRecord(
                    id: index,
                    parentId: parent == FileTree.noNode ? nil : Int(parent),
                    name: id == FileTree.rootID ? "." : tree.name(of: id),
                    isDirectory: tree.isDirectory(id),
                    allocatedBytes: String(tree.size(of: id))
                )
                if !isFirst {
                    try handle.write(contentsOf: Data(",".utf8))
                }
                try handle.write(contentsOf: encoder.encode(record))
                isFirst = false
            }

            try handle.write(contentsOf: Data("]}".utf8))
            try handle.close()

            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }
}
