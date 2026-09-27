import Foundation
import ContextCore

@MainActor extension DeskModel {
    func startScheduler() async {
        guard schedulerTask == nil, !schedulerStopping else { return }
        do { jobLedger = try await jobStore.load(); schedulerReady = true }
        catch { schedulerReady = false; self.error = error.localizedDescription; return }
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tickJobs()
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }
    func tickJobs(now: Date = Date()) async {
        guard schedulerReady, !schedulerStopping else { return }
        for job in jobLedger.jobs where job.enabled && job.nextRun.map({ $0 <= now }) == true {
            // Offline Codex work remains due; no network call has been made and no run is claimed.
            if job.engine == .codex && (!connected || !authenticated) { continue }
            await launchJob(job.id, manual: false, now: now)
        }
    }
    func saveJob(_ job: ManagedJob) async -> Bool {
        do { jobLedger = try await jobStore.save(job); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func deleteJob(_ id: UUID) async {
        do { jobLedger = try await jobStore.remove(id) } catch { self.error = error.localizedDescription }
    }
    func toggleJob(_ job: ManagedJob) async {
        var updated = job; updated.enabled.toggle(); _ = await saveJob(updated)
    }
    func launchJob(_ id: UUID, manual: Bool = true, now: Date = Date()) async {
        guard schedulerReady, !schedulerStopping else { return }
        do {
            guard let (job, run) = try await jobStore.claim(id, manual: manual, now: now) else { return }
            jobLedger = try await jobStore.load()
            guard let project = state.projects.first(where: { $0.id == job.projectID }),
                  FileManager.default.fileExists(atPath: project.path) else {
                await finishJob(run.id, status: .failed, output: L10n.text("Проект недоступен. Проверь папку задания.", "Project unavailable. Check the task folder.")); return
            }
            if job.engine == .codex && (!connected || !authenticated || !routeIsAvailable(job.route)) {
                await finishJob(run.id, status: .failed, output: L10n.text("Подключись к Codex и проверь выбранный маршрут.", "Connect to Codex and check the selected route.")); return
            }
            guard !schedulerStopping else { await finishJob(run.id, status: .interrupted); return }
            jobTasks[run.id] = Task { [weak self] in
                guard let self else { return }
                defer { jobTasks.removeValue(forKey: run.id); claudeRunners.removeValue(forKey: run.id) }
                if job.engine == .codex {
                    await deliverScheduled(job, run: run, project: project)
                } else {
                    let runner = ClaudeJobRunner(); claudeRunners[run.id] = runner
                    do {
                        jobLedger = try await jobStore.attach(run.id)
                        let (status, output) = try await runner.run(prompt: job.prompt, model: job.model, cwd: URL(fileURLWithPath: project.path))
                        await finishJob(run.id, status: status, output: output)
                    } catch {
                        await finishJob(run.id, status: error is CancellationError ? .interrupted : .uncertain, output: error.localizedDescription)
                    }
                }
            }
        } catch { self.error = error.localizedDescription; schedulerReady = false }
    }
    func finishJob(_ id: UUID, status: JobRunStatus, output: String = "") async {
        do { jobLedger = try await jobStore.finish(id, status: status, output: output) }
        catch { schedulerReady = false; self.error = error.localizedDescription }
    }
    func stopJob(_ run: JobRun) async {
        if let runner = claudeRunners[run.id] { await runner.stop(); return }
        if let thread = run.threadID, let turn = run.turnID {
            do { try await connection.interrupt(sessionForChat(thread), turn: turn) }
            catch { self.error = error.localizedDescription }
        } else { jobTasks[run.id]?.cancel() }
    }
    func stopScheduler() async {
        schedulerStopping = true; schedulerReady = false
        schedulerTask?.cancel(); schedulerTask = nil
        for task in jobTasks.values { task.cancel() }
        for runner in claudeRunners.values { await runner.stop() }
        for task in Array(jobTasks.values) { await task.value }
        for run in jobLedger.runs where run.status.active { await finishJob(run.id, status: .uncertain) }
        await jobStore.release()
    }
    func importedJob(_ source: ScheduledJob) -> ManagedJob {
        var job = ManagedJob(); job.name = source.name; job.prompt = source.prompt; job.engine = source.engine
        job.model = source.model; job.effort = source.effort; job.source = source.engine.rawValue + ":" + source.id
        job.projectID = state.projects.first(where: { source.paths.contains($0.path) })?.id
        // A source thread belongs to the other app. Only its explicit prompt can be transferred.
        job.schedule = JobSchedule(rule: source.rawRule)
        return job
    }
}
