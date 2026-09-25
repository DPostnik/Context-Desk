import Foundation
import HeadroomIntegration
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
        let headroom = HeadroomRuntime()
        do {
            let throughHeadroom = args.contains("--headroom")
            var overrides: [String] = []
            if throughHeadroom {
                let endpoint = try await headroom.start()
                overrides = try RequestRoute.providerArguments(endpoint: endpoint)
                print("Headroom ready: \(try await headroom.status().version)")
            }
            try await connection.start(executable: Locations.codexExecutable(), home: home, extraArguments: overrides)
            let result = try await connection.request("account/read", params: .object(["refreshToken": .bool(false)]))
            print("initialize: OK")
            print("account/read: OK; authenticated=\(result["account"] != .null)")
            print("scheduled definitions: \(ScheduledJobs.read(directory: Locations.automations).count)")
            if args.contains("--smoke-test") {
                guard throughHeadroom, result["account"] != .null else { throw ClientFailure("Smoke test requires Headroom and an authenticated app home") }
                let models = try await connection.request("model/list", params: .object(["limit": .number(100)]))["data"].array
                guard let model = (models.first { $0["isDefault"].bool == true } ?? models.first)?["model"].string else { throw ClientFailure("No model available") }
                let project = FileManager.default.temporaryDirectory.appendingPathComponent("contextdesk-headroom-smoke")
                try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
                let thread = try await connection.request("thread/start", params: .object([
                    "cwd": .string(project.path), "model": .string(model), "modelProvider": .string(RequestRoute.headroom.providerID),
                    "approvalPolicy": .string("never"), "sandbox": .string("read-only"), "ephemeral": .bool(true)
                ]))
                guard let id = thread["thread"]["id"].string else { throw ClientFailure("No thread ID") }
                _ = try await connection.request("turn/start", params: .object([
                    "threadId": .string(id), "input": .array([.object(["type": .string("text"),
                    "text": .string("Reply with exactly HEADROOM_OK. Do not read files or call tools."), "text_elements": .array([])])])
                ]))
                let timeout = Task {
                    do { try await Task.sleep(for: .seconds(90)) } catch { return }
                    await connection.stop(); await headroom.stop()
                    FileHandle.standardError.write(Data("Smoke test timed out; no retry.\n".utf8))
                    exit(1)
                }
                defer { timeout.cancel() }
                var complete = false
                for await event in connection.events {
                    if event["method"].string == "turn/completed" {
                        guard event["params"]["turn"]["status"].string == "completed" else { throw ClientFailure("Headroom smoke turn failed") }
                        complete = true; break
                    }
                    if event["method"].string == "client/disconnected" { break }
                }
                guard complete else { throw ClientFailure("Smoke test did not finish") }
                let status = try await headroom.status()
                print("Headroom smoke turn completed; proxy requests=\(status.requests), tokens removed=\(status.tokensSaved)")
                guard status.requests > 0 else { throw ClientFailure("No requests observed by Headroom") }
            } else { print("No model turn sent. Credentials were not copied.") }
            await connection.stop()
            await headroom.stop()
        } catch {
            await connection.stop()
            await headroom.stop()
            FileHandle.standardError.write(Data("Probe failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
