import ContextCore
import SwiftUI

@main enum AppEntry {
    @MainActor static func main() async {
        if await ChromeSessionImportCommand.run(arguments: CommandLine.arguments) { return }
        ContextDeskApp.main()
    }
}
