import ContextCore
import SwiftUI

@main enum AppEntry {
    @MainActor static func main() async {
        if RestartCommand.run(arguments: CommandLine.arguments) { return }
        if await ChromeSessionImportCommand.run(arguments: CommandLine.arguments) { return }
        ContextDeskApp.main()
    }
}
