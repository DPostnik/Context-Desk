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

@Test @MainActor func existingChatDraftsSurviveNavigationAndClearing() async {
    let model = DeskModel()
    let projects = (1...2).map { Project(path: "/tmp/existing-draft-project-\($0)") }
    let chats = (0..<3).map {
        Chat(id: "draft-chat-\($0)", projectID: projects[$0 % 2].id, title: "Chat", model: "")
    }
    model.state.projects = projects
    model.state.chats = chats
    let drafts = ["Русский черновик\nсо второй строкой  ", "English draft 👋", "  "]
    model.selectProject(projects[0].id)
    model.draft = "New chat draft"
    for (chat, draft) in zip(chats, drafts) {
        await model.openChat(chat)
        #expect(model.draft.isEmpty)
        model.draft = draft
    }
    for (chat, draft) in zip(chats, drafts) {
        await model.openChat(chat)
        #expect(model.draft == draft)
        await model.openChat(chat)
        #expect(model.draft == draft)
        model.showingJobs = true
        await model.openChat(chat)
        #expect(!model.showingJobs)
        #expect(model.draft == draft)
    }
    model.selectProject(projects[0].id)
    #expect(model.draft == "New chat draft")
    await model.openChat(chats[0])
    model.draft = ""
    await model.openChat(chats[1])
    #expect(model.draft == drafts[1])
    await model.openChat(chats[0])
    #expect(model.draft.isEmpty)

    let freshModel = DeskModel()
    freshModel.state = model.state
    await freshModel.openChat(chats[1])
    #expect(freshModel.draft.isEmpty)
    freshModel.newChat()
    #expect(freshModel.draft.isEmpty)
}

@Test @MainActor func failedSendRestoresExistingChatDraftAcrossNavigation() async {
    let model = DeskModel()
    let project = Project(path: "/tmp/failed-draft-project")
    let chat = Chat(id: "failed-draft-chat", projectID: project.id, title: "Chat", model: "")
    model.state.projects = [project]
    model.state.chats = [chat]
    await model.openChat(chat)
    // Keep transport disconnected so delivery fails without sending a real request.
    model.connected = true
    model.authenticated = true
    model.draft = "Unconfirmed message"
    await model.send()
    #expect(model.draft == "Unconfirmed message")
    model.newChat()
    #expect(model.draft.isEmpty)
    await model.openChat(chat)
    #expect(model.draft == "Unconfirmed message")
}
