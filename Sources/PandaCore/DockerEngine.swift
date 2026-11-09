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
