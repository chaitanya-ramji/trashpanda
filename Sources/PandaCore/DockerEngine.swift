import Foundation

public enum DockerRefusal: Error, Equatable, CustomStringConvertible {
    case noDocker
    case noContext
    case remote(String)
    case unknownSocket(String)
    case notRunning(String)

    public var description: String {
        switch self {
        case .noDocker: return "docker is not installed"
        case .noContext: return "could not read the current docker context"
        case .remote(let host): return "the engine is not local (\(host))"
        case .unknownSocket(let path): return "the socket is not a known local engine (\(path))"
        case .notRunning(let path): return "the engine is not running (\(path))"
        }
    }
}

/// A Docker engine on this Mac. The app acts on a local engine only.
/// A Docker context can point to a remote server. A clean there could destroy a server.
public struct DockerEngine: Sendable, Equatable {
    public let contextName: String
    public let kind: String
    public let socket: String
    let dockerPath: String

    public var host: String { "unix://" + socket }

    /// Variables that can send a command to another engine. We remove them for every Docker command.
    static let scrubbedEnvironment = ["DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH"]

    /// Finds the engine of the current Docker context. Returns the reason when the app must not use it.
    public static func detect(dockerPath: String?, home: URL,
                              isSocket: (String) -> Bool = DockerEngine.isUnixSocket) -> Result<DockerEngine, DockerRefusal> {
        guard let dockerPath else { return refuse(.noDocker) }

        // Read the stored context, not the environment. The environment can point anywhere.
        let r = Shell.run(dockerPath, ["context", "inspect"], timeout: 8, unsetEnv: scrubbedEnvironment)
        guard r.status == 0,
              let json = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [[String: Any]],
              let context = json.first,
              let name = context["Name"] as? String,
              let endpoints = context["Endpoints"] as? [String: Any],
              let docker = endpoints["docker"] as? [String: Any],
              let host = docker["Host"] as? String else { return refuse(.noContext) }

        guard host.hasPrefix("unix://") else { return refuse(.remote(host)) }
        let socket = String(host.dropFirst("unix://".count))
        guard socket.hasPrefix("/"), !socket.contains(".."), !socket.contains("\0") else {
            return refuse(.unknownSocket(socket))
        }
        guard let kind = classify(socket: socket, home: home.resolvingSymlinksInPath().path) else {
            return refuse(.unknownSocket(socket))
        }
        guard isSocket(socket) else { return refuse(.notRunning(socket)) }

        let engine = DockerEngine(contextName: name, kind: kind, socket: socket, dockerPath: dockerPath)
        Log.info("docker engine ok: context=\(name) kind=\(kind) socket=\(socket)")
        return .success(engine)
    }

    /// Runs a Docker command against this engine only.
    public func run(_ args: [String], timeout: TimeInterval = 30) -> ShellResult {
        Shell.run(dockerPath, ["--host", host] + args, timeout: timeout, unsetEnvironment: Self.scrubbedEnvironment)
    }

    /// The size and the reclaimable size of each kind of data, from `docker system df`.
    public func summary() -> [String: (size: Int64, reclaimable: Int64)] {
        let r = run(["system", "df", "--format", "{{json .}}"], timeout: 8)
        guard r.status == 0 else { return [:] }
        var out: [String: (size: Int64, reclaimable: Int64)] = [:]
        for line in r.stdout.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = obj["Type"] as? String else { continue }
            out[type] = (ByteText.parse(DockerInventory.string(obj["Size"])) ?? 0,
                         ByteText.parse(DockerInventory.string(obj["Reclaimable"])) ?? 0)
        }
        return out
    }

    /// Reads everything the engine holds. Returns nil when Docker does not answer in the expected format.
    public func inventory() -> DockerInventory? {
        let r = run(["system", "df", "-v", "--format", "json"], timeout: 20)
        guard r.status == 0, let inventory = DockerInventory.parse(r.stdout) else {
            Log.warn("docker inventory unavailable")
            return nil
        }
        return inventory
    }

    /// The volumes that each container mounts, by container id. nil when the engine did not answer.
    /// A container that is not in the answer has no volumes. Only named and anonymous volumes count (not a bind of a folder).
    /// `index . "Name"` is needed: a bind mount has no `Name`, and `.Name` would stop the whole answer with a template error.
    /// The real tool prints `bind:<no value>` for such a mount. Checked on OrbStack.
    public func volumes(ofContainers ids: [String]) -> [String: [String]]? {
        let valid = ids.filter(DockerAction.isHexID).prefix(200)
        guard !valid.isEmpty else { return [:] }
        let r = run(["container", "inspect", "--format", #"{{.Id}}|{{range .Mounts}}{{.Type}}:{{index . "Name"}},{{end}}"#] + valid, timeout: 30)
        guard r.status == 0, !r.timedOut else { return nil }
        var out: [String: [String]] = [:]
        for line in r.stdout.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, DockerAction.isHexID(parts[0]) else { continue }
            // Each mount is `<type>:<name>`. Only a `volume` counts. A bind of a folder has a path as its name and is left out.
            out[parts[0]] = parts[1].split(separator: ",").compactMap { mount -> String? in
                let pieces = mount.split(separator: ":", maxSplits: 1).map(String.init)
                return pieces.count == 2 && pieces[0] == "volume" && DockerAction.isVolumeName(pieces[1]) ? pieces[1] : nil
            }
        }
        return out
    }

    /// When each image came to this Mac (the last time a name was set on it). The build date can be years older.
    /// An image that is missing from the answer has an unknown age.
    public func tagTimes(ofImages ids: [String]) -> [String: Date] {
        let valid = ids.filter(DockerAction.isImageID).prefix(200)
        guard !valid.isEmpty else { return [:] }
        let r = run(["image", "inspect", "--format", "{{.ID}} {{json .Metadata.LastTagTime}}"] + valid, timeout: 30)
        guard r.status == 0 else { return [:] }
        var times: [String: Date] = [:]
        for line in r.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let date = DockerInventory.parseDate(parts[1].replacingOccurrences(of: "\"", with: ""))
            else { continue }
            times[parts[0]] = date
        }
        return times
    }

    // MARK: Known local engines

    /// Returns the name of a known local engine, or nil. A socket in any other place is refused,
    /// because a local socket can be a tunnel to a remote engine.
    static func classify(socket: String, home: String) -> String? {
        let resolved = URL(fileURLWithPath: socket).resolvingSymlinksInPath().path
        // A link must not lead out of the home folder or the system socket folders.
        let allowedRoots = [home + "/", "/var/run/", "/private/var/run/"]
        guard allowedRoots.contains(where: { resolved.hasPrefix($0) || socket.hasPrefix($0) }) else { return nil }

        switch socket {
        case "\(home)/.orbstack/run/docker.sock": return "OrbStack"
        case "\(home)/.docker/run/docker.sock", "\(home)/.docker/desktop/docker.sock": return "Docker Desktop"
        case "\(home)/.rd/docker.sock": return "Rancher Desktop"
        case "/var/run/docker.sock", "/private/var/run/docker.sock": return "Docker"
        default: break
        }
        let colima = "\(home)/.colima/"
        if socket.hasPrefix(colima), socket.hasSuffix("/docker.sock"),
           socket.dropFirst(colima.count).split(separator: "/").count == 2 {
            return "Colima"
        }
        return nil
    }

    public static func isUnixSocket(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK
    }

    private static func refuse(_ why: DockerRefusal) -> Result<DockerEngine, DockerRefusal> {
        Log.warn("docker refused: \(why)")
        return .failure(why)
    }
}
