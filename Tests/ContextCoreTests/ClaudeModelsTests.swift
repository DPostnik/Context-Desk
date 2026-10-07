import Foundation
import ContextCore
import Testing
@testable import ClaudeAdapter

@Test func claudeCatalogIdentifiersAreUniqueAndWellFormed() {
    let ids = ClaudeModel.catalog.map(\.id)
    #expect(ids.count == Set(ids).count)
    for entry in ClaudeModel.catalog {
        #expect(entry.id.hasPrefix("claude-"))
        #expect(entry.id == entry.id.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(!entry.name.isEmpty)
        #expect(!entry.reasoning.title.isEmpty)
    }
}

@Test func claudeCatalogOffersTheCurrentLineup() {
    let current = Set(ClaudeModel.current.map(\.id))
    #expect(current == ["claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-1", "claude-haiku-4-5"])
    #expect(ClaudeModel.previous.allSatisfy { !$0.isCurrent })
    #expect(ClaudeModel.current.count + ClaudeModel.previous.count == ClaudeModel.catalog.count)
    #expect(ClaudeModel.entry(for: "claude-opus-5-5")?.reasoning == .always)
    #expect(ClaudeModel.entry(for: "claude-haiku-4-5")?.reasoning == .extended)
    #expect(ClaudeModel.entry(for: "claude-opus-5")?.reasoning == .adaptive)
}

/// The configured string stays authoritative: an unknown model is shown, never rewritten.
@Test func claudeModelTitlesPreserveUnknownIdentifiers() {
    #expect(ClaudeModel.title(for: "claude-opus-5-5") == "Opus 5.5")
    #expect(ClaudeModel.title(for: " claude-opus-5-5 ") == "Opus 5.5")
    #expect(ClaudeModel.title(for: "claude-future-9") == "claude-future-9")
    #expect(ClaudeModel.title(for: "") == L10n.text("По умолчанию", "Default"))
    #expect(ClaudeModel.title(for: "   ") == L10n.text("По умолчанию", "Default"))
    #expect(ClaudeModel.entry(for: "claude-future-9") == nil)
    #expect(ClaudeModel.reasoningTitle(for: "claude-future-9") == nil)
    #expect(ClaudeModel.reasoningTitle(for: "claude-sonnet-5-5") == ClaudeModel.Reasoning.always.title)
}

@Test func claudeMenuTitleNamesTheModelAndItsReasoning() {
    let opus = ClaudeModel.entry(for: "claude-opus-5-5")
    #expect(opus?.menuTitle == "Opus 5.5 · " + ClaudeModel.Reasoning.always.title)
}

@Test func claudeVersionComparisonOrdersDottedComponentsNumerically() {
    #expect(ClaudeRuntime.version("2.1.260", isAtLeast: "2.1.260"))
    #expect(ClaudeRuntime.version("2.1.280", isAtLeast: "2.1.260"))
    #expect(!ClaudeRuntime.version("2.1.260", isAtLeast: "2.1.280"))
    #expect(ClaudeRuntime.version("2.2.0", isAtLeast: "2.1.999"))
    #expect(!ClaudeRuntime.version("2.1.9", isAtLeast: "2.1.10"))
    #expect(ClaudeRuntime.version("2.1", isAtLeast: "2.1.0"))
}

/// The pinned CLI rejects a model its own catalog does not describe, so a model above the pin
/// must not be selectable. Both 5.5 entries were absent from 2.1.260 and are present in the
/// pinned 2.1.292, where `claude-opus-5-5` was run end to end.
@Test func claudeCatalogGatesModelsAgainstThePinnedRuntime() {
    #expect(ClaudeRuntime.pinnedVersion == "2.1.292")
    for id in ["claude-opus-5-5", "claude-sonnet-5-5"] {
        let entry = ClaudeModel.entry(for: id)
        #expect(entry?.isSupported(by: "2.1.260") == false)
        #expect(entry?.isSupported() == true)
        #expect(ClaudeModel.requirementNote(for: id) == nil)
        #expect(entry?.requirementNote(for: "2.1.260") != nil)
    }
    #expect(ClaudeModel.entry(for: "claude-opus-5-5")?.minimumCLI == "2.1.280")
    #expect(ClaudeModel.entry(for: "claude-sonnet-5-5")?.minimumCLI == "2.1.292")
    // Every catalog entry is selectable on the pinned build.
    for entry in ClaudeModel.catalog {
        #expect(entry.isSupported())
        #expect(ClaudeRuntime.version(ClaudeRuntime.pinnedVersion, isAtLeast: entry.minimumCLI))
    }
    // A model above the pin stays listed but is reported as unavailable.
    let future = ClaudeModel(id: "claude-future-9", name: "Future 9", reasoning: .always,
                             isCurrent: true, minimumCLI: "9.9.9")
    #expect(!future.isSupported())
    #expect(future.requirementNote()?.contains("9.9.9") == true)
    // Availability of an identifier outside the catalog is proven by execution, not by this list.
    #expect(ClaudeModel.requirementNote(for: "claude-future-9") == nil)
}

@Test func claudeEffortAcceptsOnlyDocumentedLevels() {
    #expect(ClaudeEffort.allCases.map(\.rawValue) == ["low", "medium", "high", "xhigh", "max"])
    #expect(ClaudeEffort.accepted("low") == .low)
    #expect(ClaudeEffort.accepted("xhigh") == .xhigh)
    #expect(ClaudeEffort.accepted("") == nil)
    #expect(ClaudeEffort.accepted(nil) == nil)
    #expect(ClaudeEffort.accepted("ultra") == nil)
    #expect(ClaudeEffort.isDispatchable(nil))
    #expect(ClaudeEffort.isDispatchable(""))
    #expect(ClaudeEffort.isDispatchable("medium"))
    #expect(!ClaudeEffort.isDispatchable("ultra"))
    #expect(!ClaudeEffort.isDispatchable("Low"))
    for level in ClaudeEffort.allCases { #expect(!level.title.isEmpty) }
}

@Test func claudeArgumentsForwardOnlyDocumentedEffortLevels() {
    #expect(ClaudeJobRunner.version == ClaudeRuntime.pinnedVersion)
    let auto = ClaudeJobRunner.arguments(model: "claude-opus-5", effort: nil)
    #expect(!auto.contains("--effort"))
    let low = ClaudeJobRunner.arguments(model: "claude-opus-5", effort: "low")
    #expect(low.contains("--effort"))
    #expect(low[low.firstIndex(of: "--effort")! + 1] == "low")
    #expect(!ClaudeJobRunner.arguments(model: "claude-opus-5", effort: "").contains("--effort"))
    #expect(!ClaudeJobRunner.arguments(model: "claude-opus-5", effort: "ultra").contains("--effort"))

    let interactive = ClaudeIntegration.arguments(id: UUID().uuidString, resumed: false,
                                                  access: .fullAccess, model: "claude-opus-5", effort: "xhigh")
    #expect(interactive[interactive.firstIndex(of: "--effort")! + 1] == "xhigh")
    #expect(interactive[interactive.firstIndex(of: "--model")! + 1] == "claude-opus-5")
    #expect(!ClaudeIntegration.arguments(id: UUID().uuidString, resumed: false,
                                         access: .fullAccess, model: "", effort: nil).contains("--effort"))
}

@Test func claudeDefaultsAreOpus55AtHighAndRunnableOnThePin() {
    #expect(ClaudeModel.defaultID == "claude-opus-5-5")
    #expect(ClaudeEffort.defaultLevel == .high)
    #expect(ClaudeModel.entry(for: ClaudeModel.defaultID)?.isSupported() == true)
    #expect(ClaudeModel.resolved(nil) == "claude-opus-5-5")
    #expect(ClaudeModel.resolved("") == "claude-opus-5-5")
    #expect(ClaudeModel.resolved("  ") == "claude-opus-5-5")
    #expect(ClaudeModel.resolved("claude-haiku-4-5") == "claude-haiku-4-5")
    #expect(ClaudeModel.resolved(" claude-future-9 ") == "claude-future-9")
    #expect(ClaudeEffort.resolved(nil) == "high")
    #expect(ClaudeEffort.resolved("") == "high")
    #expect(ClaudeEffort.resolved("ultra") == "high")
    #expect(ClaudeEffort.resolved("low") == "low")
}
