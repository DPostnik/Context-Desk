import Foundation
import ContextCore

@main struct Probe {
    static func main() async {
        let args = CommandLine.arguments
        let home: URL
        if let index = args.firstIndex(of: "--home"), args.indices.contains(index + 1) {
            home = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        } else {
            home = Locations.root.appendingPathComponent("probe-home", isDirectory: true)
        }
        let connection = CodexConnection()
        var runtime: ProviderPluginRuntime?
        do {
            var plugin: ProviderPlugin?
            var overrides: [String] = []
            if let index = args.firstIndex(of: "--plugin") {
                guard args.indices.contains(index + 1),
                      let installed = PluginCatalog.scan(directory: PluginCatalog.defaultDirectory).plugins.first(where: { $0.id == args[index + 1] }) else {
                    throw ClientFailure("Plugin is not installed")
                }
                plugin = installed
                let process = ProviderPluginRuntime(plugin: installed, codexHome: home)
                runtime = process
                overrides = try installed.providerArguments(endpoint: await process.start())
                print("Plugin ready: \(installed.manifest.title) \(try await process.status().pluginVersion)")
                if args.contains("--plugin-check") {
                    await process.stop()
                    print("Plugin protocol check passed. No Codex connection or model request made.")
                    return
                }
            }
            try await connection.start(executable: Locations.codexExecutable(), home: home, extraArguments: overrides)
            let result = try await connection.request("account/read", params: .object(["refreshToken": .bool(false)]))
            print("initialize: OK")
            print("account/read: OK; authenticated=\(result["account"] != .null)")
            print("scheduled definitions: \(ScheduledJobs.read(directory: Locations.automations).count)")
            if args.contains("--smoke-test") {
                guard let plugin, let runtime, result["account"] != .null else { throw ClientFailure("Smoke test requires a plugin and an authenticated app home") }
                let models = try await connection.request("model/list", params: .object(["limit": .number(100)]))["data"].array
                guard let model = (models.first { $0["isDefault"].bool == true } ?? models.first)?["model"].string else { throw ClientFailure("No model available") }
                let project = FileManager.default.temporaryDirectory.appendingPathComponent("contextdesk-plugin-smoke")
                try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
                let thread = try await connection.request("thread/start", params: .object([
                    "cwd": .string(project.path), "model": .string(model), "modelProvider": .string(plugin.route.providerID),
                    "approvalPolicy": .string("never"), "sandbox": .string("read-only"), "ephemeral": .bool(true)
                ]))
                guard let id = thread["thread"]["id"].string else { throw ClientFailure("No thread ID") }
                _ = try await connection.request("turn/start", params: .object([
                    "threadId": .string(id), "input": .array([.object(["type": .string("text"),
                    "text": .string("Reply with exactly PLUGIN_OK. Do not read files or call tools."), "text_elements": .array([])])])
                ]))
                let timeout = Task {
                    do { try await Task.sleep(for: .seconds(90)) } catch { return }
                    await connection.stop(); await runtime.stop()
                    FileHandle.standardError.write(Data("Smoke test timed out; no retry.\n".utf8))
                    exit(1)
                }
                defer { timeout.cancel() }
                var complete = false
                for await event in connection.events {
                    if event["method"].string == "turn/completed" {
                        guard event["params"]["turn"]["status"].string == "completed" else { throw ClientFailure("Plugin smoke turn failed") }
                        complete = true; break
                    }
                    if event["method"].string == "client/disconnected" { break }
                }
                guard complete else { throw ClientFailure("Smoke test did not finish") }
                let status = try await runtime.status()
                print("Plugin smoke turn completed; metrics=\(status.metrics)")
            } else { print("No model turn sent. Credentials were not copied.") }
            await connection.stop()
            await runtime?.stop()
        } catch {
            await connection.stop()
            await runtime?.stop()
            FileHandle.standardError.write(Data("Probe failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
