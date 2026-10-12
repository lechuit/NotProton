import Foundation

enum ImportWineCommand {
    static let flag = "--import-wine-engine"

    static func run(arguments: [String]) -> Never {
        guard arguments.count == 2, arguments[0] == flag else {
            FileHandle.standardError.write(Data("Usage: NotProtonApp --import-wine-engine /absolute/path/runtime-descriptor.json\n".utf8))
            exit(2)
        }
        do {
            let imported = try IndependentWine.register(descriptorAt: URL(filePath: arguments[1]))
            FileHandle.standardOutput.write(Data("Registered \(imported.display). Restart Steam to select it.\n\(IndependentWine.limitations)\n".utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
