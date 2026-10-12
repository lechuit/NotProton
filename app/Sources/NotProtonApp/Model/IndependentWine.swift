import Darwin
import Foundation

struct IndependentWineDescriptor: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let id: String
    let displayName: String
    let backend: String
    let root: String
    let wineLoader: String
    let wineServer: String
    let steamAPI: String
    let bridgeRoot: String?

    init(schemaVersion: Int, id: String, displayName: String, backend: String, root: String,
         wineLoader: String, wineServer: String, steamAPI: String, bridgeRoot: String? = nil) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.displayName = displayName
        self.backend = backend
        self.root = root
        self.wineLoader = wineLoader
        self.wineServer = wineServer
        self.steamAPI = steamAPI
        self.bridgeRoot = bridgeRoot
    }
}

enum IndependentWine {
    static let step = "Import experimental Wine engine"
    static let limitations = "Experimental raw Wine backend. No native SteamAPI bridge, Steam Input bridge, or automatic graphics installation. Games requiring SteamAPI need Windows Steam running inside this backend's own prefix."
    static let nativeLimitations = "Experimental native SteamAPI bridge for Wine 11.17. Keep Steam for Mac running. No Steam Input bridge, overlay, or automatic graphics installation. Game and anti-cheat compatibility are unverified."

    struct Validated: Sendable {
        let descriptor: IndependentWineDescriptor
        let loaderHash: String
        let serverHash: String
        let bridge: NativeWineBridge.Validated?

        var engineKey: String { bridge == nil ? descriptor.id : "native-\(descriptor.id)" }
        var name: String { "notproton-wine-\(engineKey)" }
        var display: String { "\(descriptor.displayName)\(bridge == nil ? " (Experimental)" : " (Native, Experimental)")" }
        var limitations: String { bridge == nil ? IndependentWine.limitations : IndependentWine.nativeLimitations }
        var registryLine: String { "\(name)\twine-\(engineKey)\trosetta\t\(display)\n" }
        var runtimeRecord: String {
            var lines = [String(descriptor.schemaVersion), engineKey, descriptor.root, descriptor.wineLoader,
                         descriptor.wineServer, loaderHash, serverHash]
            if let bridge { lines += [bridge.identity, bridge.manifest.runtimeNtdllSHA256] }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    static func validate(_ descriptor: IndependentWineDescriptor) throws -> Validated {
        func refuse(_ detail: String) throws -> Never { throw StepFailure(step: step, detail: detail) }
        let native = descriptor.schemaVersion == 2 && descriptor.steamAPI == "native" && descriptor.bridgeRoot != nil
        let raw = descriptor.schemaVersion == 1 && descriptor.steamAPI == "unavailable" && descriptor.bridgeRoot == nil
        guard descriptor.backend == "wine", raw || native else {
            try refuse("Unsupported descriptor. Use version 1/unavailable for raw Wine or version 2/native with bridgeRoot.")
        }
        let id = descriptor.id
        guard !id.isEmpty, id.utf8.count <= 40, !id.hasPrefix("."), !id.hasPrefix("native-"), !id.contains(".."),
              id.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }) else {
            try refuse("Engine id must contain 1-40 lowercase letters, digits, dots or hyphens, without traversal.")
        }
        guard !descriptor.displayName.isEmpty, descriptor.displayName.utf8.count <= (native ? 68 : 78),
              !descriptor.displayName.contains("\""), !descriptor.displayName.contains("\\"),
              descriptor.displayName.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            try refuse("Invalid display name.")
        }
        guard descriptor.root.hasPrefix("/"), descriptor.root != "/",
              descriptor.root.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            try refuse("Runtime root must be an absolute directory without control characters.")
        }
        guard let resolvedRoot = realpath(descriptor.root, nil) else { try refuse("Runtime directory is missing.") }
        defer { free(resolvedRoot) }
        let rootPath = String(cString: resolvedRoot)
        let root = URL(filePath: rootPath, directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: descriptor.root, isDirectory: &isDirectory), isDirectory.boolValue else {
            try refuse("Runtime directory is missing.")
        }
        guard !FileManager.default.fileExists(atPath: root.appending(path: "share/crossover").path(percentEncoded: false)),
              !root.pathComponents.contains(where: { $0.hasPrefix("CrossOver") && $0.hasSuffix(".app") }) else {
            try refuse("CrossOver cannot be imported as an independent Wine engine. Use its licensed compatibility tool.")
        }
        guard ["bin/wine", "bin/wine64"].contains(descriptor.wineLoader), descriptor.wineServer == "bin/wineserver" else {
            try refuse("Version 1 supports bin/wine or bin/wine64 with the same runtime's bin/wineserver.")
        }
        func executable(_ relative: String) throws -> URL {
            let candidate = root.appending(path: relative)
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard let rawPath = realpath(candidate.path(percentEncoded: false), nil) else {
                try refuse("\(relative) is missing.")
            }
            defer { free(rawPath) }
            guard String(cString: rawPath).hasPrefix(rootPath + "/"),
                  FileManager.default.isExecutableFile(atPath: candidate.path(percentEncoded: false)),
                  (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                try refuse("\(relative) must be an executable file within the registered runtime root.")
            }
            return candidate
        }
        let normalized = IndependentWineDescriptor(schemaVersion: descriptor.schemaVersion, id: descriptor.id,
            displayName: descriptor.displayName, backend: descriptor.backend, root: rootPath,
            wineLoader: descriptor.wineLoader, wineServer: descriptor.wineServer, steamAPI: descriptor.steamAPI,
            bridgeRoot: descriptor.bridgeRoot)
        let bridge = try native ? NativeWineBridge.validate(root: descriptor.bridgeRoot!, runtime: root) : nil
        return try Validated(descriptor: normalized, loaderHash: Digest.sha256(of: executable(descriptor.wineLoader)),
                             serverHash: Digest.sha256(of: executable(descriptor.wineServer)), bridge: bridge)
    }

    @discardableResult
    static func register(
        descriptorAt file: URL,
        support: URL = SupportPaths.support,
        compatTools: URL = SupportPaths.Steam.compatTools,
        runScript: URL? = nil
    ) throws -> Validated {
        let decoded = try JSONDecoder().decode(IndependentWineDescriptor.self, from: Data(contentsOf: file))
        let validated = try validate(decoded)
        let descriptor = validated.descriptor
        let source = try runScript ?? InstallPayload.root().appending(path: "run-wine")
        guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
            throw StepFailure(step: step, detail: "The independent Wine launch script is missing from this build.")
        }
        let fm = FileManager.default
        for directory in [support, support.appending(path: "runners"), compatTools] {
            guard (try? fm.destinationOfSymbolicLink(atPath: directory.path(percentEncoded: false))) == nil else {
                throw StepFailure(step: step, detail: "A managed installation directory is a symlink.")
            }
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let lock = open(support.path(percentEncoded: false), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard lock >= 0 else { throw StepFailure(step: step, detail: "Cannot lock the engine registry.") }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock)
            throw StepFailure(step: step, detail: "Another engine registration is running.")
        }
        defer { FileLock.release(lock) }
        let managed = support.appending(path: "runners/wine-\(validated.engineKey)")
        let tool = compatTools.appending(path: validated.name)
        for directory in [managed, tool] {
            guard (try? fm.destinationOfSymbolicLink(atPath: directory.path(percentEncoded: false))) == nil else {
                throw StepFailure(step: step, detail: "The target installation directory is a symlink.")
            }
        }
        let registry = support.appending(path: "wine-tools")
        guard (try? fm.destinationOfSymbolicLink(atPath: registry.path(percentEncoded: false))) == nil else {
            throw StepFailure(step: step, detail: "The independent engine registry is a symlink.")
        }
        let old = (try? String(contentsOf: registry, encoding: .utf8)) ?? ""
        let kept = old.split(separator: "\n").filter { $0.split(separator: "\t").first != Substring(validated.name) }
        let text = kept.map(String.init).joined(separator: "\n")
        if let bridge = validated.bridge { try NativeWineBridge.stage(bridge, managed: managed) }
        try atomicReplace(managed.appending(path: "descriptor.json"), with: JSONEncoder().encode(descriptor), step: step)
        try atomicReplace(managed.appending(path: "runtime.v1"), with: Data(validated.runtimeRecord.utf8), step: step)
        try atomicReplace(tool.appending(path: "build"), with: Data("wine-\(validated.engineKey)\n".utf8), step: step)
        try atomicReplace(tool.appending(path: "flavor"), with: Data("rosetta\n".utf8), step: step)
        try atomicReplace(tool.appending(path: "run"), from: source, step: step)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.appending(path: "run").path(percentEncoded: false))
        let declaration = "\"compatibilitytools\"\n{\n  \"compat_tools\"\n  {\n    \"\(validated.name)\"\n    {\n      \"install_path\" \".\"\n      \"display_name\" \"\(validated.display)\"\n      \"from_oslist\" \"windows\"\n      \"to_oslist\" \"macos\"\n    }\n  }\n}\n"
        let manifest = "\"manifest\"\n{\n  \"version\" \"2\"\n  \"commandline\" \"/run %verb%\"\n}\n"
        try atomicReplace(tool.appending(path: "compatibilitytool.vdf"), with: Data(declaration.utf8), step: step)
        try atomicReplace(tool.appending(path: "toolmanifest.vdf"), with: Data(manifest.utf8), step: step)
        try atomicReplace(registry, with: Data(((text.isEmpty ? "" : text + "\n") + validated.registryLine).utf8), step: step)
        return validated
    }
}
