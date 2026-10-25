import CryptoKit
import Foundation
import ZIPFoundation

struct PackageCache: Sendable {
    static let maxZIPSize = 10 * 1024 * 1024
    static let maxUnpackedSize = 30 * 1024 * 1024
    let root: URL

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func archiveURL(_ hash: String) -> URL { root.appendingPathComponent("\(hash).zip") }

    func cached(_ hash: String) throws -> URL {
        let data = try Data(contentsOf: archiveURL(hash), options: .mappedIfSafe)
        return try unpack(data, hash: hash)
    }

    func store(_ data: Data, hash: String) throws -> URL {
        let index = try unpack(data, hash: hash)
        try data.write(to: archiveURL(hash), options: .atomic)
        return index
    }

    /// Extraction is bounded and staged; only a fully verified package is exposed.
    /// Rechecking extracted bytes also repairs disk corruption without a download.
    private func unpack(_ data: Data, hash: String) throws -> URL {
        guard data.count <= Self.maxZIPSize, Placement.validHash(hash) else {
            throw FlowdeckError.invalidPackage
        }
        guard Self.hash(data) == hash else { throw FlowdeckError.hashMismatch }
        let archive = try Archive(data: data, accessMode: .read)
        var files: [(String, Data)] = []
        var names = Set<String>()
        var total = 0
        for entry in archive {
            let path = entry.path
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard entry.type == .file, !path.contains("\\"), !path.contains(":"),
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  names.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  names.count <= 500,
                  entry.uncompressedSize <= Self.maxUnpackedSize - total else {
                throw FlowdeckError.invalidPackage
            }
            var bytes = Data()
            let checksum = try archive.extract(entry) { chunk in
                guard chunk.count <= Self.maxUnpackedSize - total else {
                    throw FlowdeckError.invalidPackage
                }
                total += chunk.count
                bytes.append(chunk)
            }
            guard checksum == entry.checksum, bytes.count == entry.uncompressedSize else {
                throw FlowdeckError.invalidPackage
            }
            files.append((path, bytes))
        }
        guard files.contains(where: { $0.0 == "index.html" }) else { throw FlowdeckError.invalidPackage }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent(hash, isDirectory: true)
        // Never trust symlinks or extra files in a previously extracted directory.
        let existing = fm.enumerator(at: destination, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        var existingFiles = Set<String>()
        var safe = (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false
        while let item = existing?.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { safe = false; break }
            if values.isRegularFile == true {
                existingFiles.insert(String(item.path.dropFirst(destination.path.count + 1)))
            }
        }
        if safe, existingFiles == Set(files.map(\.0)), files.allSatisfy({ path, bytes in
            (try? Data(contentsOf: destination.appendingPathComponent(path))) == bytes
        }) {
            return destination.appendingPathComponent("index.html")
        }
        let staging = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        for (path, bytes) in files {
            let target = staging.appendingPathComponent(path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target)
        }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: staging, to: destination)
        return destination.appendingPathComponent("index.html")
    }
}
