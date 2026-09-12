import XCTest

final class AppReviewVideoTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        if name.contains("testPhysicalFilesFolderAccess") {
            app.launchArguments = ["--app-review-fixtures", "--reset-file-access-onboarding"]
        } else if name.contains("testPhysicalStorageSmoke") {
            app.launchArguments = []
        } else if name.contains("testStaleFolderBookmark") {
            app.launchArguments = ["--stale-folder-bookmark-fixture"]
        } else if name.contains("testPhotoMediaImport") {
            app.launchArguments = ["--app-review-fixtures", "--reset-media-import-fixtures"]
        } else {
            app.launchArguments = ["--app-review-fixtures"]
        }
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

    func testStaleFolderBookmarkFallsBackAndCanBeReplaced() throws {
        let recovery = app.alerts.firstMatch
        XCTAssertTrue(recovery.waitForExistence(timeout: 10))
        XCTAssertTrue(recovery.buttons["Choose another folder"].exists)

        XCTAssertTrue(app.descendants(matching: .any)["Tree-1-Documents"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["Tree-2-Documents"].waitForExistence(timeout: 10))
        let leftMessage = app.staticTexts["DirectoryMessage-1"]
        let rightMessage = app.staticTexts["DirectoryMessage-2"]
        if leftMessage.exists { XCTAssertFalse(leftMessage.label.contains("Could not load")) }
        if rightMessage.exists { XCTAssertFalse(rightMessage.label.contains("Could not load")) }

        let fallbackScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        fallbackScreenshot.name = "stale-bookmark-fallback"
        fallbackScreenshot.lifetime = .keepAlways
        add(fallbackScreenshot)

        recovery.buttons["Later"].tap()
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.otherElements["TitleToolbar"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["Tree-1-Documents"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["Tree-2-Documents"].exists)
    }

    func testMediaFolderAndPhotoPickerEntry() throws {
        app.buttons["OpenFolderButton"].tap()
        let menu = app.sheets.firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertTrue(menu.buttons["Media folder"].exists)
        XCTAssertTrue(menu.buttons["Import Photos & Videos…"].exists)
        XCTAssertTrue(menu.buttons["Apple Music (read-only)…"].exists)
        XCTAssertTrue(menu.buttons["Local OpenCommander files"].exists)
        XCTAssertTrue(menu.buttons["Choose another folder"].exists)

        menu.buttons["Media folder"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["Tree-1-Media"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["Path-1"].value as? String, "/Documents/Media")

        app.buttons["OpenFolderButton"].tap()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        app.sheets.firstMatch.buttons["Import Photos & Videos…"].tap()
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 10))

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "system-photo-video-picker"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.otherElements["TitleToolbar"].waitForExistence(timeout: 10))
    }

    func testPhotoMediaImportAndLargeViewer() throws {
        app.buttons["OpenFolderButton"].tap()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        app.sheets.firstMatch.buttons["Import Photos & Videos…"].tap()
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 10))

        // The private system picker doesn't expose its photo grid to the host app's
        // accessibility hierarchy. Activate visible settled coordinates instead.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.42)).tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.08)).tap()

        XCTAssertEqual(app.textFields["Path-1"].value as? String, "/Documents/Media")
        let importedFiles = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'File-1-'")
        )
        XCTAssertTrue(importedFiles.firstMatch.waitForExistence(timeout: 20))
        importedFiles.firstMatch.doubleTap()
        XCTAssertTrue(app.otherElements["ImageViewer"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.images["ImageViewerImage"].exists)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "imported-photo-large-viewer"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["ImageViewerClose"].tap()
    }

    func testPhysicalStorageSmokeDoesNotStartInAnUnreadableFolder() throws {
        let recovery = app.alerts.firstMatch
        if recovery.waitForExistence(timeout: 2), recovery.buttons["Later"].exists {
            recovery.buttons["Later"].tap()
        }
        XCTAssertTrue(app.buttons["OpenFolderButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tables["TreeList-1"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tables["TreeList-2"].waitForExistence(timeout: 10))
        let leftMessage = app.staticTexts["DirectoryMessage-1"]
        let rightMessage = app.staticTexts["DirectoryMessage-2"]
        if leftMessage.exists { XCTAssertFalse(leftMessage.label.contains("Could not load")) }
        if rightMessage.exists { XCTAssertFalse(rightMessage.label.contains("Could not load")) }

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "physical-storage-readable"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

final class ImageViewerTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--image-viewer-fixtures"]
        app.launch()
        XCTAssertTrue(app.otherElements["TitleToolbar"].waitForExistence(timeout: 15))
        for _ in 0..<3 where app.alerts.buttons["OK"].exists { app.alerts.buttons["OK"].tap() }
    }

    func testFolderAndZipImageGallery() throws {
        let folder = app.descendants(matching: .any)["File-1-ImageViewerQA"]
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        folder.doubleTap()
        let first = app.descendants(matching: .any)["File-1-01-first.png"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.tap()
        XCTAssertTrue(app.staticTexts["Selection-1"].label.hasPrefix("1/"))
        app.descendants(matching: .any)["File-1-01-first.png"].doubleTap()

        let page = app.staticTexts["ImageViewerPage"]
        let title = app.staticTexts["ImageViewerTitle"]
        let image = app.images["ImageViewerImage"]
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        XCTAssertEqual(page.label, "1 / 3")
        XCTAssertEqual(title.label, "01-first.png")
        XCTAssertTrue(image.exists)
        attach("folder-first")

        image.swipeLeft()
        XCTAssertTrue(waitForLabel(page, "2 / 3"))
        XCTAssertEqual(title.label, "02-second.png")
        attach("folder-second")
        image.swipeLeft()
        XCTAssertTrue(waitForLabel(page, "3 / 3"))
        XCTAssertTrue(app.staticTexts["ImageViewerError"].waitForExistence(timeout: 5))
        image.swipeLeft()
        XCTAssertEqual(page.label, "3 / 3")
        image.swipeRight()
        XCTAssertTrue(waitForLabel(page, "2 / 3"))

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["ImageViewerClose"].waitForExistence(timeout: 5))
        XCTAssertTrue(page.isHittable)
        attach("landscape")
        XCUIDevice.shared.orientation = .portrait
        app.buttons["ImageViewerClose"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5))

        let zip = app.descendants(matching: .any)["File-1-gallery.zip"]
        XCTAssertTrue(zip.waitForExistence(timeout: 5))
        zip.doubleTap()
        let zippedFirst = app.descendants(matching: .any)["File-1-01-first.png"]
        XCTAssertTrue(zippedFirst.waitForExistence(timeout: 5))
        zippedFirst.doubleTap()
        XCTAssertTrue(waitForLabel(page, "1 / 2"))
        app.images["ImageViewerImage"].swipeLeft()
        XCTAssertTrue(waitForLabel(page, "2 / 2"))
        XCTAssertEqual(title.label, "02-second.png")
        attach("zip-second")
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
