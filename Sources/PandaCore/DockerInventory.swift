import Foundation

/// What a Docker engine holds, read from `docker system df -v --format json`.
/// All sizes are decimal bytes, like Docker prints them.
public struct DockerInventory: Sendable {
    public struct Image: Sendable, Equatable {
        public let id: String
        public let repository: String
        public let tag: String
        /// How many containers use this image, running or stopped.
        /// -1 means that Docker did not say. We treat that as "in use", never as "unused".
        public let containers: Int
        /// The space that Docker frees when it removes this image. Shared layers are not counted.
        public let uniqueBytes: Int64
        public let sizeBytes: Int64
        /// When the image was built, which can be long before it came to this Mac.
        public let createdAt: Date?

        /// An image with no name and no tag. Docker calls it "dangling".
        public var isDangling: Bool { repository == "<none>" && tag == "<none>" }
    }

    public struct Container: Sendable, Equatable {
        public let id: String
        public let name: String
        public let image: String
        /// `running`, `exited`, `created`, `paused`, `restarting`, or `dead`.
        public let state: String
        /// Docker's own words, for example "Exited (0) 4 months ago".
        public let status: String
        /// The size of the writable layer of the container.
        public let writableBytes: Int64

        /// A container that is not running and is not about to run.
        public var isStopped: Bool { ["exited", "created", "dead"].contains(state) }
    }

    public let images: [Image]
    public let containers: [Container]

    public static func parse(_ text: String) -> DockerInventory? {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let images = (root["Images"] as? [[String: Any]] ?? []).map { item in
            Image(id: string(item["ID"]), repository: string(item["Repository"]), tag: string(item["Tag"]),
                  containers: Int(string(item["Containers"])) ?? (item["Containers"] as? Int) ?? -1,
                  uniqueBytes: bytes(item["UniqueSize"]), sizeBytes: bytes(item["Size"]),
                  createdAt: parseDate(string(item["CreatedAt"])))
        }
        let containers = (root["Containers"] as? [[String: Any]] ?? []).map { item in
            // Docker can give several names. The first one is the main name.
            let name = string(item["Names"]).split(separator: ",").first.map(String.init) ?? ""
            return Container(id: string(item["ID"]), name: name, image: string(item["Image"]),
                             state: string(item["State"]), status: string(item["Status"]),
                             writableBytes: bytes(item["Size"]))
        }
        return DockerInventory(images: images, containers: containers)
    }

    /// Containers that are stopped. A running container never appears here.
    public var stoppedContainers: [Container] { containers.filter(\.isStopped) }

    /// One image, with every name that points to it.
    public struct ImageGroup: Sendable, Equatable {
        public let id: String
        /// `repository:tag` for each name. `docker image rm` with all of them removes the image.
        public let refs: [String]
        public let uniqueBytes: Int64
        public let createdAt: Date?
    }

    /// Named images that no container uses, running or stopped. An image with two names counts once.
    /// If any name of the image is in use, or Docker did not say, the image is left out.
    public var unusedNamedImages: [ImageGroup] {
        let named = images.filter { $0.repository != "<none>" && $0.tag != "<none>" && !$0.id.isEmpty }
        return Dictionary(grouping: named, by: \.id).values.compactMap { entries in
            guard entries.allSatisfy({ $0.containers == 0 }) else { return nil }
            let refs = entries.map { "\($0.repository):\($0.tag)" }.sorted()
            return ImageGroup(id: entries[0].id, refs: refs, uniqueBytes: entries[0].uniqueBytes,
                              createdAt: entries[0].createdAt)
        }.sorted { $0.uniqueBytes > $1.uniqueBytes }
    }

    /// Images that have no name and that no container uses. `docker image prune -f` removes exactly these.
    public var danglingImages: [Image] { images.filter { $0.isDangling && $0.containers == 0 } }

    // MARK: Reading Docker's text values. Docker prints numbers as strings.

    static func string(_ value: Any?) -> String { value as? String ?? "" }

    /// Reads "2026-10-23 14:21:40 +0530 IST" (image list) and "2026-10-31T03:45:57.348516651Z" (inspect).
    /// A date before 1971 means "not set" in Docker. We return nil for it.
    static func parseDate(_ text: String) -> Date? {
        var t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let date: Date?
        // ISO form starts with a date and a "T". A zone name such as "IST" must not count.
        if t.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T", options: .regularExpression) != nil {
            t = t.replacingOccurrences(of: "\\.[0-9]+", with: "", options: .regularExpression)
            date = ISO8601DateFormatter().date(from: t)
        } else {
            // Drop the zone name at the end (for example "IST"). Keep the numeric offset.
            let parts = t.split(separator: " ").prefix(3).joined(separator: " ")
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
            date = f.date(from: parts)
        }
        guard let date, date.timeIntervalSince1970 > 31_536_000 else { return nil }
        return date
    }

    static func int(_ value: Any?) -> Int {
        if let n = value as? Int { return n }
        return Int((value as? String) ?? "") ?? 0
    }

    static func bytes(_ value: Any?) -> Int64 {
        DiskScanner.parseDockerSize(string(value)) ?? 0
    }
}
