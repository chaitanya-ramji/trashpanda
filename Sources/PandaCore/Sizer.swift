import Foundation

public enum Sizer {
    /// Disk space that a delete would free, in bytes. Symbolic links are not followed.
    /// A file with more than one hard link frees its space only when all its links are deleted.
    /// So it is counted one time, and only when the walk finds all its links in this folder.
    /// This matters for pnpm, which links files from its store into each project.
    /// Clones (APFS) cannot be seen here. The file system does not tell which files share blocks.
    public static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [
            .totalFileAllocatedSizeKey, .isRegularFileKey, .linkCountKey, .fileResourceIdentifierKey,
        ]
        let keySet = Set(keys)

        if let own = try? url.resourceValues(forKeys: keySet), own.isRegularFile == true {
            // One link is all that this path can show. A file with more links frees nothing.
            return (own.linkCount ?? 1) > 1 ? 0 : Int64(own.totalFileAllocatedSize ?? 0)
        }
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        // For a file with many links: how many links the walk found, how many links it has, its size.
        var shared: [AnyHashable: (found: Int, links: Int, bytes: Int64)] = [:]
        for case let item as URL in walker {
            guard let v = try? item.resourceValues(forKeys: keySet), v.isRegularFile == true else { continue }
            let bytes = Int64(v.totalFileAllocatedSize ?? 0)
            let links = v.linkCount ?? 1
            guard links > 1, let id = v.fileResourceIdentifier as? AnyHashable else {
                // A file with many links and no id cannot be matched, so it is not counted.
                if links == 1 { total += bytes }
                continue
            }
            var entry = shared[id] ?? (found: 0, links: links, bytes: bytes)
            entry.found += 1
            shared[id] = entry
        }
        for entry in shared.values where entry.found >= entry.links { total += entry.bytes }
        return total
    }
}
