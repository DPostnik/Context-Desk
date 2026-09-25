import Foundation
import Testing
import ContextCore
@testable import ContextDesk

@Test @MainActor func newChatDraftsFollowTheirProjects() {
    let model = DeskModel()
    let projects = (1...3).map { Project(path: "/tmp/draft-project-\($0)") }
    model.state.projects = projects
    let drafts = ["Первый\nчерновик", "Второй черновик  ", "Третий черновик"]

    for (project, draft) in zip(projects, drafts) {
        model.selectProject(project.id)
        #expect(model.draft.isEmpty)
        model.draft = draft
    }
    for (project, draft) in zip(projects, drafts) {
        model.selectProject(project.id)
        #expect(model.draft == draft)
        model.newChat()
        #expect(model.draft == draft)
        model.showingJobs = true
        model.selectProject(project.id)
        #expect(!model.showingJobs)
        #expect(model.draft == draft)
    }

    model.draft = ""
    model.selectProject(projects[0].id)
    #expect(model.draft == drafts[0])
    model.selectProject(projects[2].id)
    #expect(model.draft.isEmpty)
}

@Test @MainActor func existingChatDoesNotOverwriteNewChatDraft() async {
    let model = DeskModel()
    let project = Project(path: "/tmp/draft-project")
    let chat = Chat(id: "existing", projectID: project.id, title: "Existing", model: "")
    model.state.projects = [project]
    model.state.chats = [chat]
    model.selectProject(project.id)
    model.draft = "Черновик нового чата"

    // A disconnected read fails immediately; navigation still selects the chat.
    await model.openChat(chat)
    #expect(model.chatID == chat.id)
    #expect(model.draft.isEmpty)
    model.draft = "Сообщение существующего чата"
    model.newChat()
    #expect(model.chatID == nil)
    #expect(model.draft == "Черновик нового чата")
}
