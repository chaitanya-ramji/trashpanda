import Foundation

/// The disk image that a local Docker engine keeps all its data in (Docker Desktop or OrbStack). We only read its size.
/// We never change it. Lowering the disk limit in Docker Desktop deletes this file and all containers and images,
/// so this app never offers that step.
public struct DockerDesktopDisk: Sendable, Equatable {
    public let url: URL
    /// Space that the file really uses on this Mac.
    public let allocatedBytes: Int64
    /// The size that Finder shows. The file is sparse, so this can be many times larger.
    public let logicalBytes: Int64

    /// Where Docker Desktop keeps the disk image by default. Newer versions use .raw, older ones .qcow2.
    static let candidates = [
        "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
        "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.qcow2",
    ]

    /// OrbStack's data disk image. The official OrbStack FAQ gives this as the default location of the data
    /// (its `du` command for the size uses the same path). NOT CHECKED ON A REAL INSTALL. If it is wrong, fix this one constant.
    static let orbStackCandidates = [
        "Library/Group Containers/HUAQ24HBR6.dev.orbstack/data/data.img",
    ]

    /// The paths to look at for one engine. Docker Desktop and OrbStack each keep their own file. Any other engine has none.
    static func paths(forEngine kind: String) -> [String] {
        switch kind {
        case "Docker Desktop": return candidates
        case "OrbStack": return orbStackCandidates
        default: return []
        }
    }

    /// The official page about the disk image and about getting space back.
    public static let helpURL = URL(string: "https://docs.docker.com/desktop/troubleshoot-and-support/faqs/macfaqs/")!

    /// Reads the size of the file of one engine. It returns nil when there is no regular file, or when macOS does not allow the read.
    /// A link is never followed.
    public static func find(home: URL, engine: String = "Docker Desktop") -> DockerDesktopDisk? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        for relative in paths(forEngine: engine) {
            let url = home.appendingPathComponent(relative)
            guard let v = try? url.resourceValues(forKeys: keys),
                  v.isSymbolicLink != true, v.isRegularFile == true else { continue }
            return DockerDesktopDisk(url: url, allocatedBytes: Int64(v.totalFileAllocatedSize ?? 0),
                                     logicalBytes: Int64(v.fileSize ?? 0))
        }
        return nil
    }
}
