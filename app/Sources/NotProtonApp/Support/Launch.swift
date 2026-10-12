import Foundation

@main
enum Launch {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == ImportWineCommand.flag {
            ImportWineCommand.run(arguments: arguments)
        }
        if CommandLine.arguments.dropFirst().contains(RemoveEverythingCommand.flag) {
            RemoveEverythingCommand.run()
        }
        NotProtonApp.main()
    }
}
