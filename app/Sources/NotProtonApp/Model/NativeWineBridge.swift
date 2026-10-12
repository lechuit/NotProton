import Darwin
import Foundation

struct NativeWineBridgeManifest: Codable, Sendable {
    let schemaVersion: Int
    let wineVersion: String
    let wineCommit: String
    let runtimeNtdllSHA256: String
    let files: [String: String]
}

enum NativeWineBridge {
    static let identitySalt = "ntdll-runtime-link-v1\n"
    static let sourceCommitsByVersion = [
        "11.17": "36b6a2cf679fb395f668a917b76537190e212d9c",
        "11.18": "7b3fff76fa5178f6ce0141b2c776afa2a822f101",
    ]
    static let runtimeNtdll = "lib/wine/x86_64-unix/ntdll.so"
    static let files = [
        "x86_64-windows/lsteamclient.dll", "x86_64-windows/steamclient64.dll", "x86_64-windows/steam.exe",
        "i386-windows/lsteamclient.dll", "i386-windows/steamclient.dll", "x86_64-unix/lsteamclient.so",
    ]

    struct Validated: Sendable {
        let root: URL
        let manifest: NativeWineBridgeManifest
        let runtimeNtdllSource: URL

        var checksums: String {
            NativeWineBridge.files.sorted().map { "\(manifest.files[$0]!)  \($0)\n" }.joined()
                + "\(manifest.runtimeNtdllSHA256)  x86_64-unix/ntdll.so\n"
        }
        var identity: String { Digest.sha256(of: Data((NativeWineBridge.identitySalt + checksums).utf8)) }
    }

    static func validate(root path: String, runtime: URL) throws -> Validated {
        func refuse(_ detail: String) throws -> Never {
            throw StepFailure(step: IndependentWine.step, detail: detail)
        }
        guard path.hasPrefix("/"), path != "/",
              path.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              let resolved = realpath(path, nil) else { try refuse("Native bridge root must be an existing absolute directory.") }
        defer { free(resolved) }
        let rootPath = String(cString: resolved)
        let root = URL(filePath: rootPath, directoryHint: .isDirectory)
        let manifestFile = root.appending(path: "bridge-manifest.json")
        let manifest = try JSONDecoder().decode(NativeWineBridgeManifest.self, from: Data(contentsOf: manifestFile))
        guard manifest.schemaVersion == 1,
              sourceCommitsByVersion[manifest.wineVersion] == manifest.wineCommit,
              Set(manifest.files.keys) == Set(files), validHash(manifest.runtimeNtdllSHA256),
              manifest.files.values.allSatisfy(validHash) else {
            try refuse("Native bridge manifest must use a supported Wine Devel 11.17 or 11.18 source commit and the fixed file set.")
        }
        for relative in files {
            let file = root.appending(path: relative)
            guard let resolvedFile = realpath(file.path(percentEncoded: false), nil) else {
                try refuse("Native bridge file \(relative) is missing.")
            }
            defer { free(resolvedFile) }
            guard String(cString: resolvedFile).hasPrefix(rootPath + "/"),
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  Digest.sha256IfPresent(file) == manifest.files[relative] else {
                try refuse("Native bridge file \(relative) is invalid or its hash changed.")
            }
        }
        let ntdll = runtime.appending(path: runtimeNtdll)
        guard let realNtdll = realpath(ntdll.path(percentEncoded: false), nil) else { try refuse("Runtime ntdll.so is missing.") }
        defer { free(realNtdll) }
        guard let realRuntime = realpath(runtime.path(percentEncoded: false), nil) else { try refuse("Runtime root is missing.") }
        defer { free(realRuntime) }
        guard String(cString: realNtdll).hasPrefix(String(cString: realRuntime) + "/"),
              Digest.sha256IfPresent(ntdll) == manifest.runtimeNtdllSHA256 else {
            try refuse("The native bridge does not match this runtime's ntdll.so. Rebuild the bridge against the exact installed Wine.")
        }
        return Validated(root: root, manifest: manifest, runtimeNtdllSource: URL(filePath: String(cString: realNtdll)))
    }

    private static func validHash(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func stage(_ validated: Validated, managed: URL) throws {
        let fm = FileManager.default
        let destination = managed.appending(path: "bridge-\(validated.identity)")
        guard (try? fm.destinationOfSymbolicLink(atPath: destination.path(percentEncoded: false))) == nil else {
            throw StepFailure(step: IndependentWine.step, detail: "Managed native bridge directory is a symlink.")
        }
        let scratch = managed.appending(path: ".bridge-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        for relative in files {
            let target = scratch.appending(path: relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: validated.root.appending(path: relative).resolvingSymlinksInPath(), to: target)
            guard Digest.sha256IfPresent(target) == validated.manifest.files[relative] else {
                throw StepFailure(step: IndependentWine.step, detail: "Native bridge source changed during registration.")
            }
        }
        let ntdll = scratch.appending(path: "x86_64-unix/ntdll.so")
        // A second copy loads separate Wine globals through dyld; use the runtime's actual image.
        try fm.createSymbolicLink(at: ntdll, withDestinationURL: validated.runtimeNtdllSource)
        guard Digest.sha256IfPresent(ntdll) == validated.manifest.runtimeNtdllSHA256 else {
            throw StepFailure(step: IndependentWine.step, detail: "Wine runtime changed during bridge registration.")
        }
        try Data(validated.checksums.utf8).write(to: scratch.appending(path: "checksums.sha256"))
        if fm.fileExists(atPath: destination.path(percentEncoded: false)) {
            guard (try? String(contentsOf: destination.appending(path: "checksums.sha256"), encoding: .utf8)) == validated.checksums else {
                throw StepFailure(step: IndependentWine.step, detail: "The installed native bridge manifest was modified. Import a clean bridge into a fresh managed directory.")
            }
            guard (try? fm.destinationOfSymbolicLink(atPath: destination.appending(path: "x86_64-unix/ntdll.so").path(percentEncoded: false)))
                    == validated.runtimeNtdllSource.path(percentEncoded: false) else {
                throw StepFailure(step: IndependentWine.step, detail: "The native bridge must link to the exact runtime ntdll.so. A copied or redirected ntdll is not supported.")
            }
            for relative in files {
                guard (try? fm.destinationOfSymbolicLink(atPath: destination.appending(path: relative).path(percentEncoded: false))) == nil else {
                    throw StepFailure(step: IndependentWine.step, detail: "Only the runtime ntdll.so link is allowed in a managed native bridge.")
                }
            }
            for relative in files + ["x86_64-unix/ntdll.so"] {
                guard Digest.sha256IfPresent(destination.appending(path: relative)) == Digest.sha256IfPresent(scratch.appending(path: relative)) else {
                    throw StepFailure(step: IndependentWine.step, detail: "An installed native bridge was modified. Remove that bridge directory and import again.")
                }
            }
        } else {
            try fm.moveItem(at: scratch, to: destination)
        }
    }
}
