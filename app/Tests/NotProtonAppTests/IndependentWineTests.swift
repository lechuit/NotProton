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
}
