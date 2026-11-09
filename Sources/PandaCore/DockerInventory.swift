import Foundation

/// What a Docker engine holds, read from `docker system df -v --format json`.
/// All sizes are decimal bytes, like Docker prints them.
public struct DockerInventory: Sendable {
    public struct Image: Sendable, Equatable {
        public let id: String
        public let repository: String
        public let tag: String
        /// How many containers use this image, running or stopped.
        public let containers: Int
        /// The space that Docker frees when it removes this image. Shared layers are not counted.
        public let uniqueBytes: Int64
        public let sizeBytes: Int64

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
                  containers: int(item["Containers"]), uniqueBytes: bytes(item["UniqueSize"]),
                  sizeBytes: bytes(item["Size"]))
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

    /// Images that have no name and that no container uses. `docker image prune -f` removes exactly these.
    public var danglingImages: [Image] { images.filter { $0.isDangling && $0.containers == 0 } }

    // MARK: Reading Docker's text values. Docker prints numbers as strings.

    static func string(_ value: Any?) -> String { value as? String ?? "" }

    static func int(_ value: Any?) -> Int {
        if let n = value as? Int { return n }
        return Int((value as? String) ?? "") ?? 0
    }

    static func bytes(_ value: Any?) -> Int64 {
        DiskScanner.parseDockerSize(string(value)) ?? 0
    }
}
