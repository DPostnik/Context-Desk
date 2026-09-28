import XCTest
import UIKit

final class ScrollTests: XCTestCase {
    @MainActor func testOfflineConnectionStatusInBothLanguagesPreservesChat() throws {
        for (language, status) in [("ru", "Нет сети. Подключимся после её восстановления."),
                                   ("en", "Offline. Will reconnect when the network returns.")] {
            let app = XCUIApplication()
            app.launchArguments = ["-mobile-preview", "-preview-chat", "-preview-offline", "-interfaceLanguage", language]
            app.launch()
            XCTAssertTrue(app.staticTexts[status].firstMatch.waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["message-text-m2"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["message-input"].firstMatch.exists)
            app.terminate()
        }
    }

    @MainActor func testPhotoComposerDoesNotOverlapKeyboardInBothLanguages() throws {
        for (language, hide, done) in [("ru", "Скрыть клавиатуру", "Готово"), ("en", "Hide keyboard", "Done")] {
            let app = XCUIApplication()
            app.launchArguments = ["-mobile-preview", "-preview-chat", "-interfaceLanguage", language]
            app.launch()
            let input = app.descendants(matching: .any)["message-input"].firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 10))
            input.tap()
            input.typeText("Photo test")
            let keyboard = app.keyboards.firstMatch
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
            let send = app.buttons["send-message"]
            let photos = app.buttons["add-photos"]
            XCTAssertTrue(send.isHittable)
            XCTAssertTrue(photos.isHittable)
            XCTAssertLessThanOrEqual(send.frame.maxY, keyboard.frame.minY + 1)
            XCTAssertFalse(app.buttons[done].exists)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Photo composer " + language; screenshot.lifetime = .keepAlways
            add(screenshot)
            app.buttons[hide].tap()
            photos.tap()
            // The system picker opens without requesting broad library access.
            XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5) || app.buttons["Отменить"].exists)
            app.terminate()
        }
    }

    @MainActor func testNativeJumpCancelsInFlightScrolling() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let scroll = UIScrollView(frame: root.view.bounds)
        root.view.addSubview(scroll)
        scroll.contentSize = CGSize(width: 320, height: 12_000)
        scroll.contentInset.bottom = 40
        let controller = TranscriptScrollController()
        controller.scrollView = scroll
        XCTAssertTrue(controller.jumpToBottom())
        let bottom = scroll.contentOffset.y
        scroll.setContentOffset(.zero, animated: true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(scroll.contentOffset.y, 0)
        XCTAssertLessThan(scroll.contentOffset.y, bottom, "The test must interrupt actual movement")
        XCTAssertTrue(controller.jumpToBottom())
        XCTAssertEqual(scroll.contentOffset.y, bottom, accuracy: 1)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(scroll.contentOffset.y, bottom, accuracy: 1, "Old motion must not resume after the jump")
        XCTAssertTrue(scroll.panGestureRecognizer.isEnabled)
    }

    @MainActor func testOpeningLongChatAndRepeatedJumpToLatest() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-mobile-preview", "-preview-chat", "-preview-long", "-interfaceLanguage", "en"]
        app.launch()
        let tail = app.staticTexts["message-text-long-19"]
        XCTAssertTrue(tail.waitForExistence(timeout: 15))
        XCTAssertTrue(tail.isHittable, "Opening a long chat must show the last message")
        let scroll = app.scrollViews["conversation-scroll"]
        let jump = app.buttons["jump-to-latest"]
        for velocity in [XCUIGestureVelocity.slow, .fast, .fast] {
            scroll.swipeDown(velocity: velocity)
            scroll.swipeDown(velocity: velocity)
            XCTAssertTrue(jump.waitForExistence(timeout: 3))
            jump.tap()
            let reachedBottom = NSPredicate { _, _ in tail.isHittable && !jump.exists }
            expectation(for: reachedBottom, evaluatedWith: nil)
            waitForExpectations(timeout: 5)
        }
        let input = app.descendants(matching: .any)["message-input"].firstMatch
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Done"].exists)
        app.buttons["Hide keyboard"].tap()
        let hidden = NSPredicate { _, _ in !app.keyboards.firstMatch.exists }
        expectation(for: hidden, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(tail.isHittable)
    }
}
