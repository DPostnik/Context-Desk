import Combine
import Foundation
import ContextCore

/// High-frequency text changes are observed only by the transcript and remote publisher.
@MainActor final class TranscriptPresentation: ObservableObject {
    @Published private(set) var items: [TranscriptItem] = []
    private struct Delta {
        var text: String
        var turn: String?
        var decorate: (inout TranscriptItem) -> Void
    }
    private var pending: [String: Delta] = [:]
    private var order: [String] = []
    private var task: Task<Void, Never>?
    private var generation = 0
    private let interval: Duration

    init(interval: Duration = .milliseconds(75)) { self.interval = interval }

    func replace(_ value: [TranscriptItem]) {
        guard items != value else { return }
        items = value
    }

    func enqueue(id: String, text: String, turn: String?, decorate: @escaping (inout TranscriptItem) -> Void = { _ in }) {
        guard !text.isEmpty else { return }
        if pending[id] == nil {
            order.append(id)
            pending[id] = Delta(text: text, turn: turn, decorate: decorate)
        } else {
            pending[id]?.text += text
            pending[id]?.turn = turn
            pending[id]?.decorate = decorate
        }
        guard task == nil else { return }
        let ticket = generation
        let interval = interval
        task = Task { [weak self] in
            do { try await Task.sleep(for: interval) } catch { return }
            guard let self, generation == ticket else { return }
            flush()
        }
    }

    /// Completion/item boundaries publish immediately, including their pending text.
    func flush() {
        task?.cancel(); task = nil
        guard !order.isEmpty else { return }
        var next = items
        for id in order {
            guard let delta = pending[id] else { continue }
            if let index = next.firstIndex(where: { $0.id == id }) {
                next[index].text += delta.text
                next[index].turnID = delta.turn
                delta.decorate(&next[index])
            } else {
                var item = TranscriptItem(id: id, kind: "assistant", text: delta.text)
                item.turnID = delta.turn; delta.decorate(&item)
                next.append(item)
            }
        }
        pending.removeAll(keepingCapacity: true); order.removeAll(keepingCapacity: true)
        replace(next)
    }

    /// Invalidates delayed publication when the selected conversation changes.
    func cancelPending() {
        generation += 1
        task?.cancel(); task = nil
        pending.removeAll(); order.removeAll()
    }
}
