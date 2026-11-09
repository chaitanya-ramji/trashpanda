import Foundation

public enum Sizer {
    /// Disk space that a delete would free, in bytes. Symbolic links are not followed.
    /// With `exclusiveOnly`, files that have more than one hard link are not counted,
    /// because deleting one link frees no space. This matters for pnpm.
    public static func size(of url: URL, exclusiveOnly: Bool = false) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey, .linkCountKey]
        let keySet = Set(keys)

        if let own = try? url.resourceValues(forKeys: keySet), own.isRegularFile == true {
            return Int64(own.totalFileAllocatedSize ?? 0)
        }
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        for case let item as URL in walker {
            guard let v = try? item.resourceValues(forKeys: keySet), v.isRegularFile == true else { continue }
            if exclusiveOnly, (v.linkCount ?? 1) > 1 { continue }
            total += Int64(v.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
