import XCTest

final class AppReviewVideoTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = name.contains("testPhysicalFilesFolderAccess")
            ? ["--app-review-fixtures", "--reset-file-access-onboarding"]
            : ["--app-review-fixtures"]
        app.launch()
        XCTAssertTrue(app.otherElements["TitleToolbar"].waitForExistence(timeout: 15))
    }

    func testTypicalFileManagementFlowForAppReview() throws {
        // Show that Copy/Move is one compact toggle and both states are reachable.
        let operation = app.buttons["OperationButton"]
        XCTAssertTrue(operation.waitForExistence(timeout: 5))
        operation.tap()
        sleep(1)
        operation.tap()
        sleep(1)

        // Copy a real folder between panes using the same long-press drag users perform.
        let dragMe = app.descendants(matching: .any)["File-1-DragMe"]
        let dropHere = app.descendants(matching: .any)["File-2-DropHere"]
        XCTAssertTrue(dragMe.waitForExistence(timeout: 5))
        XCTAssertTrue(dropHere.waitForExistence(timeout: 5))
        dragMe.press(forDuration: 1.5, thenDragTo: dropHere, withVelocity: .slow, thenHoldForDuration: 1.0)
        sleep(3)
        dropHere.doubleTap()
        sleep(1)
        XCTAssertTrue(app.descendants(matching: .any)["File-2-DragMe"].waitForExistence(timeout: 5))

        // ZIP a folder, then expose the operation history and undo control.
        let source = app.descendants(matching: .any)["File-1-Source"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.tap()
        app.buttons["ZipButton"].tap()
        sleep(4)
        XCTAssertTrue(app.descendants(matching: .any)["File-1-Source.zip"].waitForExistence(timeout: 5))
        app.buttons["HistoryButton"].tap()
        sleep(2)
        XCTAssertTrue(app.scrollViews["HistoryList"].exists)
        app.buttons["UndoButton"].tap()
        sleep(3)

        // Show the in-app help and the complete language chooser.
        app.buttons["HelpButton"].tap()
        sleep(2)
        app.navigationBars.buttons.firstMatch.tap()
        sleep(1)
        app.buttons["LanguageButton"].tap()
        sleep(3)
        XCTAssertTrue(app.sheets.firstMatch.exists)
    }

    func testPhysicalFilesFolderAccessAndPersistence() throws {
        let chooseFolder = app.alerts.buttons["Choose folder"]
        XCTAssertTrue(chooseFolder.waitForExistence(timeout: 10))
        chooseFolder.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 15))
        let open = app.navigationBars.buttons["Öffnen"].firstMatch
        if !open.waitForExistence(timeout: 3) {
            let browse = app.tabBars.buttons["Durchsuchen"]
            XCTAssertTrue(browse.waitForExistence(timeout: 10))
            browse.tap()
            sleep(2)

            let onMyIPhone = app.staticTexts["Auf meinem iPhone"].firstMatch
            XCTAssertTrue(onMyIPhone.waitForExistence(timeout: 10))
            onMyIPhone.tap()
            sleep(2)
        }

        // Select the app's visible folder inside "On My iPhone" when the picker
        // is currently showing the location root. If already inside it, no row exists.
        let openCommanderFolder = app.cells.containing(.staticText, identifier: "OpenCommander").firstMatch
        if openCommanderFolder.waitForExistence(timeout: 3) {
            openCommanderFolder.tap()
            sleep(2)
        }

        XCTAssertTrue(open.waitForExistence(timeout: 10))
        XCTAssertTrue(open.isEnabled)
        open.tap()

        XCTAssertTrue(app.descendants(matching: .any)["Tree-1-Documents"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["Tree-2-Documents"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["File-1-Source"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["File-2-Source"].waitForExistence(timeout: 10))

        // Prove that the user-selected Apple Files location is writable, not just visible.
        app.descendants(matching: .any)["File-1-Source"].tap()
        app.buttons["ZipButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["File-1-Source.zip"].waitForExistence(timeout: 15))
        app.buttons["HistoryButton"].tap()
        XCTAssertTrue(app.scrollViews["HistoryList"].waitForExistence(timeout: 5))
        app.buttons["UndoButton"].tap()
        XCTAssertFalse(app.descendants(matching: .any)["File-1-Source.zip"].waitForExistence(timeout: 5))

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "physical-on-my-iphone-both-panes"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["Tree-1-Documents"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["Tree-2-Documents"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["File-1-Source"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["File-2-Source"].waitForExistence(timeout: 10))
    }
}
