import Testing
import ContextCore

@Test func chatSelectionTogglesAndKeepsOpenChat() {
    var selection = ChatSelection()
    selection.toggle("b", current: "a", eligible: ["a", "b"])
    #expect(selection.ids == ["a", "b"])
    selection.toggle("a")
    #expect(selection.ids == ["b"])
    selection.toggle("b")
    #expect(selection.isEmpty)
    selection.toggle("c", current: "archived", eligible: ["c"])
    #expect(selection.ids == ["c"])
}

@Test func chatSelectionExtendsRangeWithinOrder() {
    let order = ["a", "b", "c", "d", "e"]
    var selection = ChatSelection()
    selection.extend(to: "d", in: order, current: "b")
    #expect(selection.ids == ["b", "c", "d"])
    #expect(selection.anchor == "b")
    selection.extend(to: "a", in: order)
    #expect(selection.ids == ["a", "b", "c", "d"])
    // A chat from another project is added on its own and becomes the new anchor.
    selection.extend(to: "x", in: order)
    #expect(selection.ids.contains("x") && selection.anchor == "x")
}

@Test func chatSelectionPrunesRemovedChats() {
    var selection = ChatSelection()
    selection.select(["a", "b", "c"])
    selection.prune(keeping: ["a"])
    #expect(selection.ids == ["a"])
    #expect(selection.anchor == nil)
    selection.clear()
    #expect(selection.isEmpty)
}
