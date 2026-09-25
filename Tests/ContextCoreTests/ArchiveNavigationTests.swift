import Foundation
import Testing
import ContextCore
@testable import ContextDesk

@Test @MainActor func archiveNavigationPreservesDraftAndReturnsToWorkspace() async {
    let model = DeskModel()
    let project = Project(path: "/tmp/archive-navigation")
    var archived = Chat(id: "archived", projectID: project.id, title: "История / History", model: "")
    archived.archived = true
    let active = Chat(id: "active", projectID: project.id, title: "Active", model: "")
    model.state.projects = [project]
    model.state.chats = [archived, active]
    model.selectProject(project.id)
    model.draft = "Draft / Черновик"
    model.showingJobs = true
    model.openArchive()
    #expect(model.showingArchive && !model.showingJobs)
    #expect(!model.archiveViewingChat)
    #expect(model.draft == "Draft / Черновик")
    model.closeArchive()
    #expect(!model.showingArchive)
    #expect(model.draft == "Draft / Черновик")

    // A disconnected read fails immediately, while navigation still selects history.
    await model.openChat(archived)
    #expect(model.showingArchive && model.archiveViewingChat)
    #expect(!model.canSend)
    model.openArchive()
    #expect(!model.archiveViewingChat)
    model.closeArchive()
    #expect(!model.showingArchive && model.chatID == nil)
    #expect(model.draft == "Draft / Черновик")

    model.openArchive()
    model.selectProject(project.id)
    #expect(!model.showingArchive)
    model.openArchive()
    await model.openChat(active)
    #expect(!model.showingArchive && model.chatID == active.id)
    model.draft = "Existing draft"
    model.openArchive()
    model.closeArchive()
    #expect(model.chatID == active.id && model.draft == "Existing draft")
    model.openArchive()
    model.newChat()
    #expect(!model.showingArchive)
    #expect(model.draft == "Draft / Черновик")
}
