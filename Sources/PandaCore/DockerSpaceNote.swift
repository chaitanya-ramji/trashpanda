import Foundation

/// After a Docker clean, "Freed 568 MB" is true inside Docker. It is not always true for the Mac.
/// Docker Desktop, OrbStack, Colima, and Rancher Desktop keep their data in one sparse disk file, and the file can give the space back slowly.
/// If the Mac gained less than half of what Docker freed, we say so in one plain sentence. We never say it for other engines.
/// Evidence: a real run on OrbStack freed 568 MB in Docker, and the free space of the Mac changed by -4.6 MB (see #12 and #40).
public enum DockerSpaceNote {
    /// The engines whose data lives in a disk file. Plain `Docker` (a native socket) is not in this list.
    static let diskFileEngines: Set<String> = ["OrbStack", "Docker Desktop", "Colima", "Rancher Desktop"]
    /// A freed amount below this is too small to tell from the noise of other writes.
    static let minimumBytes: Int64 = 50_000_000

    /// The sentence, or nil when nothing needs to be said.
    /// - dockerFreed: what the Docker items freed inside Docker.
    /// - otherFreed: what the other items of the same clean freed. They really are on the Mac.
    /// - volumeChange: the change of the free space of the Mac during the whole clean.
    public static func message(engine: String?, dockerFreed: Int64, otherFreed: Int64, volumeChange: Int64) -> String? {
        guard let engine, diskFileEngines.contains(engine), dockerFreed >= minimumBytes else { return nil }
        let gainFromDocker = volumeChange - otherFreed
        guard gainFromDocker < dockerFreed / 2 else { return nil }
        return "Freed \(ByteText.string(dockerFreed)) inside Docker. Your Mac may take a while to show it."
    }
}
