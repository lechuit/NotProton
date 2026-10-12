import Foundation
import Testing

@testable import NotProtonApp

@Suite("Independent experimental Wine engines")
struct IndependentWineTests {
    private func descriptor(root: URL, id: String = "wine-11.17", loader: String = "bin/wine",
                            server: String = "bin/wineserver", steamAPI: String = "unavailable") -> IndependentWineDescriptor {
        IndependentWineDescriptor(schemaVersion: 1, id: id, displayName: "Wine 11.17", backend: "wine",
                                  root: root.path(percentEncoded: false), wineLoader: loader,
                                  wineServer: server, steamAPI: steamAPI)
    }

    private func fixture(_ scratch: URL) throws -> URL {
        let root = scratch.appending(path: "Wine engine with spaces")
        try FileManager.default.createDirectory(at: root.appending(path: "bin"), withIntermediateDirectories: true)
        for name in ["wine", "wineserver"] {
            let executable = root.appending(path: "bin/\(name)")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path(percentEncoded: false))
        }
        return root.resolvingSymlinksInPath()
    }

    @Test("Registers isolated tools and hashes in paths containing spaces")
    func registration() throws {
        let scratch = try scratchDirectory("independent-wine")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = try fixture(scratch)
        let file = scratch.appending(path: "engine.json")
        try JSONEncoder().encode(descriptor(root: root)).write(to: file)
        let script = scratch.appending(path: "run-wine")
        try Data("#!/bin/sh\n# independent launcher\nexit 0\n".utf8).write(to: script)
        let support = scratch.appending(path: "support")
        let tools = scratch.appending(path: "Steam tools")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("existing CrossOver tool\n".utf8).write(to: support.appending(path: "tools"))
        let validated = try IndependentWine.register(descriptorAt: file, support: support, compatTools: tools, runScript: script)
        #expect(validated.loaderHash.count == 64)
        #expect(try String(contentsOf: support.appending(path: "wine-tools"), encoding: .utf8) == validated.registryLine)
        let managed = support.appending(path: "runners/wine-wine-11.17")
        #expect(try String(contentsOf: managed.appending(path: "runtime.v1"), encoding: .utf8) == validated.runtimeRecord)
        #expect(!FileManager.default.fileExists(atPath: support.appending(path: "bridge").path(percentEncoded: false)))
        #expect(try String(contentsOf: support.appending(path: "tools"), encoding: .utf8) == "existing CrossOver tool\n")
        #expect(try String(contentsOf: tools.appending(path: "\(validated.name)/run"), encoding: .utf8).contains("independent launcher"))
        #expect(try String(contentsOf: tools.appending(path: "\(validated.name)/compatibilitytool.vdf"), encoding: .utf8).contains("Experimental"))
        _ = try IndependentWine.register(descriptorAt: file, support: support, compatTools: tools, runScript: script)
        #expect(try String(contentsOf: support.appending(path: "wine-tools"), encoding: .utf8) == validated.registryLine)
        let registry = try Data(contentsOf: support.appending(path: "wine-tools"))
        _ = try CompatToolList.sync(runners: support.appending(path: "runners"), bridge: support.appending(path: "bridge"),
                                  file: support.appending(path: "tools"), compatTools: tools)
        #expect(try Data(contentsOf: support.appending(path: "wine-tools")) == registry)
        #expect(FileManager.default.fileExists(atPath: tools.appending(path: "\(validated.name)/run").path(percentEncoded: false)))
    }

    @Test("Rejects traversal, another provider, missing loaders and native bridge claims")
    func validationFailures() throws {
        let scratch = try scratchDirectory("independent-validation")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = try fixture(scratch)
        for invalid in [descriptor(root: root, id: "../../escape"), descriptor(root: root, id: ".hidden"),
                        descriptor(root: root, loader: "/bin/sh"), descriptor(root: root, server: "../bin/wineserver"),
                        descriptor(root: root, steamAPI: "native")] {
            #expect(throws: (any Error).self) { try IndependentWine.validate(invalid) }
        }
        try FileManager.default.removeItem(at: root.appending(path: "bin/wine"))
        #expect(throws: (any Error).self) { try IndependentWine.validate(descriptor(root: root)) }
    }

    @Test("Rejects CrossOver and executables linked out of their root")
    func foreignRuntime() throws {
        let scratch = try scratchDirectory("independent-foreign")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = try fixture(scratch)
        try FileManager.default.createDirectory(at: root.appending(path: "share/crossover"), withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try IndependentWine.validate(descriptor(root: root)) }
        try FileManager.default.removeItem(at: root.appending(path: "share/crossover"))
        try FileManager.default.removeItem(at: root.appending(path: "bin/wine"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "bin/wine"), withDestinationURL: URL(filePath: "/bin/sh"))
        #expect(throws: (any Error).self) { try IndependentWine.validate(descriptor(root: root)) }
    }

    @Test("Refuses a managed runner directory linked elsewhere before mutation")
    func managedSymlink() throws {
        let scratch = try scratchDirectory("independent-symlink")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = try fixture(scratch)
        let file = scratch.appending(path: "engine.json")
        try JSONEncoder().encode(descriptor(root: root)).write(to: file)
        let support = scratch.appending(path: "support")
        let victim = scratch.appending(path: "untouched")
        try FileManager.default.createDirectory(at: support.appending(path: "runners"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: support.appending(path: "runners/wine-wine-11.17"), withDestinationURL: victim)
        let script = scratch.appending(path: "run-wine")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        #expect(throws: (any Error).self) {
            try IndependentWine.register(descriptorAt: file, support: support, compatTools: scratch.appending(path: "tools"), runScript: script)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: victim.path(percentEncoded: false)).isEmpty)
    }

    private func nativeFixture(_ scratch: URL, runtime: URL, version: String = "11.17",
                               commit: String = "36b6a2cf679fb395f668a917b76537190e212d9c") throws -> URL {
        let bridge = scratch.appending(path: "matching native bridge")
        try FileManager.default.createDirectory(at: bridge, withIntermediateDirectories: true)
        let ntdll = runtime.appending(path: NativeWineBridge.runtimeNtdll)
        try FileManager.default.createDirectory(at: ntdll.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("matching stock ntdll \(version)".utf8).write(to: ntdll)
        var files: [String: String] = [:]
        for relative in NativeWineBridge.files {
            let file = bridge.appending(path: relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("compiled bridge: \(relative)".utf8).write(to: file)
            files[relative] = try Digest.sha256(of: file)
        }
        let manifest = NativeWineBridgeManifest(schemaVersion: 1, wineVersion: version,
            wineCommit: commit, runtimeNtdllSHA256: try Digest.sha256(of: ntdll), files: files)
        try JSONEncoder().encode(manifest).write(to: bridge.appending(path: "bridge-manifest.json"))
        return bridge
    }

    private func nativeDescriptor(root: URL, bridge: URL, version: String = "11.17") -> IndependentWineDescriptor {
        IndependentWineDescriptor(schemaVersion: 2, id: "wine-\(version)", displayName: "Wine \(version)", backend: "wine",
            root: root.path(percentEncoded: false), wineLoader: "bin/wine", wineServer: "bin/wineserver",
            steamAPI: "native", bridgeRoot: bridge.path(percentEncoded: false))
    }

    @Test("Native registration copies bridge files and links the exact Wine image without changing Wine or raw registrations")
    func nativeRegistration() throws {
        let scratch = try scratchDirectory("native-wine")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = try fixture(scratch)
        let bridge = try nativeFixture(scratch, runtime: root)
        let file = scratch.appending(path: "engine.json")
        let script = scratch.appending(path: "run-wine")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        let support = scratch.appending(path: "support")
        let tools = scratch.appending(path: "tools")
        try JSONEncoder().encode(descriptor(root: root)).write(to: file)
        let raw = try IndependentWine.register(descriptorAt: file, support: support, compatTools: tools, runScript: script)
        try JSONEncoder().encode(nativeDescriptor(root: root, bridge: bridge)).write(to: file)
        let sourceNtdll = try Data(contentsOf: root.appending(path: NativeWineBridge.runtimeNtdll))
        let native = try IndependentWine.register(descriptorAt: file, support: support, compatTools: tools, runScript: script)
        #expect(native.name == "notproton-wine-native-wine-11.17")
        #expect(native.runtimeRecord.hasPrefix("2\nnative-wine-11.17\n"))
        let copied = support.appending(path: "runners/wine-native-wine-11.17/bridge-\(native.bridge!.identity)")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: copied.appending(path: "x86_64-unix/ntdll.so").path(percentEncoded: false))
            == native.bridge!.runtimeNtdllSource.path(percentEncoded: false))
        #expect(try Data(contentsOf: copied.appending(path: "x86_64-unix/ntdll.so")) == sourceNtdll)
        #expect(try Data(contentsOf: root.appending(path: NativeWineBridge.runtimeNtdll)) == sourceNtdll)
        for relative in NativeWineBridge.files {
            #expect(try Data(contentsOf: copied.appending(path: relative)) == Data(contentsOf: bridge.appending(path: relative)))
        }
        let registered = try String(contentsOf: support.appending(path: "wine-tools"), encoding: .utf8)
        #expect(registered.contains(raw.registryLine) && registered.contains(native.registryLine))
        #expect(native.limitations.contains("Steam for Mac") && !native.limitations.contains("Windows Steam"))
        let linkedNtdll = copied.appending(path: "x86_64-unix/ntdll.so")
        try FileManager.default.removeItem(at: linkedNtdll)
        try sourceNtdll.write(to: linkedNtdll)
        #expect(throws: (any Error).self) {
            try IndependentWine.register(descriptorAt: file, support: support, compatTools: tools, runScript: script)
        }
    }

    @Test("Wine 11.18 registers separately while preserving the Wine 11.17 tool and runtime")
    func nativeVersionUpgrade() throws {
        let scratch = try scratchDirectory("native-version-upgrade")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let olderScratch = scratch.appending(path: "11.17")
        let newerScratch = scratch.appending(path: "11.18")
        let olderRoot = try fixture(olderScratch)
        let newerRoot = try fixture(newerScratch)
        let olderBridge = try nativeFixture(olderScratch, runtime: olderRoot)
        let newerBridge = try nativeFixture(newerScratch, runtime: newerRoot, version: "11.18",
            commit: "7b3fff76fa5178f6ce0141b2c776afa2a822f101")
        let file = scratch.appending(path: "engine.json")
        let script = scratch.appending(path: "run-wine")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        let support = scratch.appending(path: "support")
        let tools = scratch.appending(path: "tools")
        try JSONEncoder().encode(nativeDescriptor(root: olderRoot, bridge: olderBridge)).write(to: file)
        let older = try IndependentWine.register(descriptorAt: file, support: support, compatTools: tools, runScript: script)
        let olderRecordFile = support.appending(path: "runners/wine-native-wine-11.17/runtime.v1")
        let olderRecord = try Data(contentsOf: olderRecordFile)
        let olderNtdll = try Data(contentsOf: olderRoot.appending(path: NativeWineBridge.runtimeNtdll))
        let newerNtdll = try Data(contentsOf: newerRoot.appending(path: NativeWineBridge.runtimeNtdll))
        try JSONEncoder().encode(nativeDescriptor(root: newerRoot, bridge: newerBridge, version: "11.18")).write(to: file)
        let newer = try IndependentWine.register(descriptorAt: file, support: support, compatTools: tools, runScript: script)
        #expect(newer.name == "notproton-wine-native-wine-11.18")
        #expect(newer.runtimeRecord.hasPrefix("2\nnative-wine-11.18\n"))
        #expect(newer.bridge?.manifest.wineVersion == "11.18")
        #expect(newer.bridge?.manifest.wineCommit == "7b3fff76fa5178f6ce0141b2c776afa2a822f101")
        let managed = support.appending(path: "runners/wine-native-wine-11.18/bridge-\(newer.bridge!.identity)")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: managed.appending(path: "x86_64-unix/ntdll.so").path(percentEncoded: false))
            == newer.bridge!.runtimeNtdllSource.path(percentEncoded: false))
        #expect(try Data(contentsOf: olderRecordFile) == olderRecord)
        #expect(try Data(contentsOf: olderRoot.appending(path: NativeWineBridge.runtimeNtdll)) == olderNtdll)
        #expect(try Data(contentsOf: newerRoot.appending(path: NativeWineBridge.runtimeNtdll)) == newerNtdll)
        let registry = try String(contentsOf: support.appending(path: "wine-tools"), encoding: .utf8)
        #expect(registry.contains(older.registryLine) && registry.contains(newer.registryLine))
        #expect(newer.limitations == older.limitations)
        #expect(!newer.limitations.contains("11.17"))
        try Data("updated 11.18 ntdll".utf8).write(to: newerRoot.appending(path: NativeWineBridge.runtimeNtdll))
        #expect(throws: (any Error).self) {
            try IndependentWine.validate(nativeDescriptor(root: newerRoot, bridge: newerBridge, version: "11.18"))
        }
        #expect(try Data(contentsOf: olderRecordFile) == olderRecord)
    }

    @Test("Native imports reject mixed source versions, Staging and unapproved versions before registration")
    func nativeVersionSourcePairs() throws {
        let scratch = try scratchDirectory("native-version-source")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = try fixture(scratch)
        let bridge = try nativeFixture(scratch, runtime: root)
        let manifestFile = bridge.appending(path: "bridge-manifest.json")
        let manifest = try JSONDecoder().decode(NativeWineBridgeManifest.self, from: Data(contentsOf: manifestFile))
        let wine17 = "36b6a2cf679fb395f668a917b76537190e212d9c"
        let wine18 = "7b3fff76fa5178f6ce0141b2c776afa2a822f101"
        let invalidPairs = [("11.17", wine18), ("11.18", wine17), ("11.18", "unknown"),
                            ("11.18 (Staging)", wine18), ("wine-11.18", wine18), ("11.19", wine18)]
        let descriptorFile = scratch.appending(path: "engine.json")
        try JSONEncoder().encode(nativeDescriptor(root: root, bridge: bridge)).write(to: descriptorFile)
        let support = scratch.appending(path: "support")
        let tools = scratch.appending(path: "tools")
        let script = scratch.appending(path: "run-wine")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        for (version, commit) in invalidPairs {
            let invalid = NativeWineBridgeManifest(schemaVersion: 1, wineVersion: version, wineCommit: commit,
                runtimeNtdllSHA256: manifest.runtimeNtdllSHA256, files: manifest.files)
            try JSONEncoder().encode(invalid).write(to: manifestFile)
            #expect(throws: (any Error).self) {
                try IndependentWine.register(descriptorAt: descriptorFile, support: support, compatTools: tools, runScript: script)
            }
            #expect(!FileManager.default.fileExists(atPath: support.path(percentEncoded: false)))
            #expect(!FileManager.default.fileExists(atPath: tools.path(percentEncoded: false)))
        }
    }

    @Test("Native descriptors refuse an ABI mismatch rather than falling back to raw Wine")
    func nativeMismatch() throws {
        let scratch = try scratchDirectory("native-mismatch")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = try fixture(scratch)
        let bridge = try nativeFixture(scratch, runtime: root)
        try Data("different Wine ntdll".utf8).write(to: root.appending(path: NativeWineBridge.runtimeNtdll))
        #expect(throws: (any Error).self) { try IndependentWine.validate(nativeDescriptor(root: root, bridge: bridge)) }
        #expect(throws: (any Error).self) { try IndependentWine.validate(descriptor(root: root, id: "native-wine-11.17")) }
    }

    @Test("Native descriptors refuse corrupted bridge files and unknown source commits")
    func nativeCorruption() throws {
        let scratch = try scratchDirectory("native-corruption")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = try fixture(scratch)
        let bridge = try nativeFixture(scratch, runtime: root)
        let manifestFile = bridge.appending(path: "bridge-manifest.json")
        let manifestData = try Data(contentsOf: manifestFile)
        let manifest = try JSONDecoder().decode(NativeWineBridgeManifest.self, from: manifestData)
        let wrongCommit = NativeWineBridgeManifest(schemaVersion: 1, wineVersion: "11.17", wineCommit: "unknown",
            runtimeNtdllSHA256: manifest.runtimeNtdllSHA256, files: manifest.files)
        try JSONEncoder().encode(wrongCommit).write(to: manifestFile)
        #expect(throws: (any Error).self) { try IndependentWine.validate(nativeDescriptor(root: root, bridge: bridge)) }
        try manifestData.write(to: manifestFile)
        try Data("corrupt".utf8).write(to: bridge.appending(path: NativeWineBridge.files[0]))
        #expect(throws: (any Error).self) { try IndependentWine.validate(nativeDescriptor(root: root, bridge: bridge)) }
    }
}
