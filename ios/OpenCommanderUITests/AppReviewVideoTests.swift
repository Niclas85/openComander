import XCTest

final class AppReviewVideoTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        if name.contains("testMainFolderOnboarding") {
            app.launchArguments = ["--reset-file-access-onboarding"]
        } else if name.contains("testPhysicalFilesFolderAccess") {
            app.launchArguments = ["--app-review-fixtures", "--reset-file-access-onboarding"]
        } else if name.contains("testPhysicalStorageSmoke") {
            app.launchArguments = []
        } else if name.contains("testStaleFolderBookmark") {
            app.launchArguments = ["--stale-folder-bookmark-fixture"]
        } else if name.contains("testPhotoMediaImport") {
#if !targetEnvironment(simulator)
            throw XCTSkip("This reset-based fixture test is simulator-only; physical media tests preserve the user's files")
#endif
            app.launchArguments = ["--app-review-fixtures", "--reset-media-import-fixtures"]
        } else {
            app.launchArguments = ["--app-review-fixtures"]
        }
        app.launch()
        if !name.contains("testMainFolder") && !name.contains("testPhysicalFilesFolderAccess") {
            if app.buttons["StorageSourcesClose"].waitForExistence(timeout: 5) { app.buttons["StorageSourcesClose"].tap() }
            XCTAssertTrue(app.otherElements["TitleToolbar"].waitForExistence(timeout: 15))
        }
    }

    func testMainFolderHubAndRelaunch() throws {
        XCTAssertTrue(app.descendants(matching: .any)["StorageSources"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.cells["Source-media_photos"].exists)
        app.buttons["StorageSourcesClose"].tap()
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["StorageSources"].waitForExistence(timeout: 15))
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
        let chooseFolder = app.cells["Source-choose_another_folder"]
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
        let menu = app.descendants(matching: .any)["StorageSources"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertTrue(app.cells["Source-media_folder"].exists)
        XCTAssertTrue(app.cells["Source-import_photos_videos"].exists)
        XCTAssertTrue(app.cells["Source-media_music"].exists)
        XCTAssertTrue(app.cells["Source-local_documents"].exists)
        XCTAssertTrue(app.cells["Source-choose_another_folder"].exists)

        app.cells["Source-media_folder"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["Tree-1-Media"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["Path-1"].value as? String, "/Documents/Media")

        app.buttons["OpenFolderButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["StorageSources"].waitForExistence(timeout: 5))
        app.cells["Source-import_photos_videos"].tap()
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
        XCTAssertTrue(app.descendants(matching: .any)["StorageSources"].waitForExistence(timeout: 5))
        app.cells["Source-import_photos_videos"].tap()
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
        if app.buttons["StorageSourcesClose"].waitForExistence(timeout: 5) { app.buttons["StorageSourcesClose"].tap() }
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

// Fixtures are copied into this unique directory through devicectl before the
// run. This exercises the shipping Release binary without DEBUG launch hooks.
final class ReleaseFileManagementUITests: XCTestCase {
    private let app = XCUIApplication()
    private let root = "/Documents/OpenCommander-Release-QA-1_3_9-8CF631E2"
    private func openPath(_ path: String, pane: Int) {
        let field = app.textFields["Path-\(pane)"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.press(forDuration: 1.2)
        let selectAllPredicate = NSPredicate(format: "label IN %@", ["Select All", "Alles auswählen", "Tout sélectionner"])
        let selectAll = app.menuItems.matching(selectAllPredicate).firstMatch
        let selectAllButton = app.buttons.matching(selectAllPredicate).firstMatch
        if selectAll.waitForExistence(timeout: 1) { selectAll.tap() }
        else if selectAllButton.waitForExistence(timeout: 1) { selectAllButton.tap() }
        else { field.tap(withNumberOfTaps: 3, numberOfTouches: 1) }
        field.typeText(path + "\n")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", path), object: field)], timeout: 15), .completed)
    }
    private func file(_ name: String, pane: Int) -> XCUIElement {
        app.descendants(matching: .any)["File-\(pane)-\(name)"]
    }
    private func evidence(_ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription); hierarchy.name = name + "-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }
    func testIsolatedReleaseCopyMoveZipAndUndo() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = []; app.launch()
        XCTAssertTrue(app.buttons["StorageSourcesClose"].waitForExistence(timeout: 15))
        app.buttons["StorageSourcesClose"].tap()
        openPath(root, pane: 1); openPath(root, pane: 2)
        let operation = app.buttons["OperationButton"]
        if operation.isSelected { operation.tap() }
        XCTAssertFalse(operation.isSelected)

        // A fresh empty destination proves that this drag actually copied data.
        openPath(root + "/DropHere", pane: 2)
        XCTAssertTrue(file("Destination.txt", pane: 2).waitForExistence(timeout: 10))
        XCTAssertFalse(file("DragMe", pane: 2).exists)
        openPath(root, pane: 2)
        file("DragMe", pane: 1).press(forDuration: 1.5, thenDragTo: file("DropHere", pane: 2), withVelocity: .slow, thenHoldForDuration: 1)
        file("DropHere", pane: 2).doubleTap()
        XCTAssertTrue(file("DragMe", pane: 2).waitForExistence(timeout: 20))
        file("DragMe", pane: 2).doubleTap()
        XCTAssertTrue(file("Proof.txt", pane: 2).waitForExistence(timeout: 10))
        XCTAssertTrue(file("DragMe", pane: 1).exists)
        evidence("release-drag-copy")

        // Navigating clears the previous selection; ZIP must contain Source only.
        openPath(root, pane: 1)
        XCTAssertFalse(file("Source.zip", pane: 1).exists)
        file("Source", pane: 1).tap()
        XCTAssertTrue(app.staticTexts["Selection-1"].label.hasPrefix("1/"))
        app.buttons["ZipButton"].tap()
        XCTAssertTrue(file("Source.zip", pane: 1).waitForExistence(timeout: 20))
        file("Source.zip", pane: 1).doubleTap()
        XCTAssertTrue(file("Source", pane: 1).waitForExistence(timeout: 10))
        file("Source", pane: 1).doubleTap()
        XCTAssertTrue(file("Welcome.txt", pane: 1).waitForExistence(timeout: 10))
        evidence("release-folder-zip-opened")
        openPath(root, pane: 1)
        app.buttons["UndoButton"].tap()
        XCTAssertTrue(file("Source.zip", pane: 1).waitForNonExistence(timeout: 15))

        // Move the app-created copy, then restore it and undo the initial copy.
        // This avoids transfer-tool protection attributes on fixture originals.
        openPath(root + "/DropHere", pane: 1); openPath(root, pane: 2)
        operation.tap(); XCTAssertTrue(operation.isSelected)
        file("DragMe", pane: 1).press(forDuration: 1.5, thenDragTo: file("MoveHere", pane: 2), withVelocity: .slow, thenHoldForDuration: 1)
        XCTAssertTrue(file("DragMe", pane: 1).waitForNonExistence(timeout: 20))
        file("MoveHere", pane: 2).doubleTap()
        XCTAssertTrue(file("DragMe", pane: 2).waitForExistence(timeout: 10))
        file("DragMe", pane: 2).doubleTap()
        XCTAssertTrue(file("Proof.txt", pane: 2).waitForExistence(timeout: 10))
        evidence("release-drag-move")
        openPath(root + "/MoveHere", pane: 2)
        app.buttons["UndoButton"].tap()
        XCTAssertTrue(file("DragMe", pane: 1).waitForExistence(timeout: 15))
        // Re-enter to discard UIKit accessibility cells cached after reloadData.
        openPath(root, pane: 2); openPath(root + "/MoveHere", pane: 2)
        XCTAssertTrue(app.staticTexts["Selection-2"].label.hasPrefix("0/0 |"))
        XCTAssertEqual(app.tables["FileList-2"].label, "This folder is empty.")
        evidence("release-move-undo-empty-destination")
        app.buttons["UndoButton"].tap()
        openPath(root, pane: 1); openPath(root + "/DropHere", pane: 1)
        XCTAssertTrue(app.staticTexts["Selection-1"].label.hasPrefix("0/1 |"))
        XCTAssertTrue(file("Destination.txt", pane: 1).exists)
        openPath(root, pane: 1)
        XCTAssertTrue(file("DragMe", pane: 1).waitForExistence(timeout: 10))
        operation.tap(); XCTAssertFalse(operation.isSelected)
        evidence("release-undo-restored-fixtures")
    }
}

final class MediaLibraryUITests: XCTestCase {
    private let app = XCUIApplication()
    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["StorageSources"].waitForExistence(timeout: 15))
    }
    private func evidence(_ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription); hierarchy.name = name + "-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }
    private func grantLibraryPermission() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.firstMatch.waitForExistence(timeout: 3) {
            let allow = springboard.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["Allow Full Access", "Vollen Zugriff erlauben", "Vollzugriff erlauben", "Allow", "Erlauben", "OK", "Zugriff auf alle Fotos erlauben"])).firstMatch
            XCTAssertTrue(allow.waitForExistence(timeout: 5), springboard.alerts.debugDescription)
            allow.tap()
        }
    }
    func testSourcesAndPhotoSwipe() throws {
        for key in ["media_photos", "media_videos", "media_music", "choose_another_folder", "local_documents"] {
            XCTAssertTrue(app.cells["Source-" + key].exists)
        }
        evidence("sources")
        app.cells["Source-media_photos"].tap()
        grantLibraryPermission()
        XCTAssertTrue(app.descendants(matching: .any)["PhotoLibrary"].waitForExistence(timeout: 10))
        let first = app.cells["PhotoAsset-0"]
        guard first.waitForExistence(timeout: 20) else {
            evidence("photos-empty-or-denied"); throw XCTSkip("No permitted photos available on physical device")
        }
        let hasSecond = app.cells["PhotoAsset-1"].exists
        first.tap()
        XCTAssertTrue(app.otherElements["LibraryMediaViewer"].waitForExistence(timeout: 10))
        let image = app.images["LibraryMediaImage"]
        XCTAssertTrue(image.waitForExistence(timeout: 20))
        XCTAssertTrue(NSPredicate(format: "value == 'loaded'").evaluate(with: image) || XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'loaded'"), object: image)], timeout: 30) == .completed)
        let before = app.staticTexts["LibraryMediaCounter"].label
        evidence("photo-fullscreen")
        if hasSecond {
            app.otherElements["LibraryMediaViewer"].swipeLeft()
            XCTAssertTrue(app.staticTexts["LibraryMediaCounter"].label.hasPrefix("2 /"))
            XCTAssertTrue(NSPredicate(format: "value == 'loaded'").evaluate(with: image) || XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 'loaded'"), object: image)], timeout: 30) == .completed)
            app.otherElements["LibraryMediaViewer"].swipeRight()
            XCTAssertEqual(app.staticTexts["LibraryMediaCounter"].label, before)
            XCUIDevice.shared.orientation = .landscapeLeft
            evidence("photo-landscape")
        }
        app.buttons["LibraryMediaClose"].tap()
        XCTAssertTrue(app.otherElements["LibraryMediaViewer"].waitForNonExistence(timeout: 15))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["PhotoSelect"].waitForExistence(timeout: 10))
        app.buttons["PhotoSelect"].tap()
        first.tap()
        XCTAssertTrue(app.buttons["PhotoExport"].isEnabled)
        app.buttons["PhotoExport"].tap()
        let save = app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", ["Save", "Sichern", "Export", "Exportieren", "Move", "Bewegen"])).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 40), app.debugDescription)
        evidence("photo-export-destination")
        // Interrupt before saving: no personal files or library originals are modified.
        app.terminate(); app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["StorageSources"].waitForExistence(timeout: 15))
        app.cells["Source-media_photos"].tap()
        XCTAssertTrue(app.cells["PhotoAsset-0"].waitForExistence(timeout: 20))
    }
    func testPhotoExportToLocalFiles() throws {
        app.cells["Source-media_photos"].tap(); grantLibraryPermission()
        let first = app.cells["PhotoAsset-0"]
        guard first.waitForExistence(timeout: 20) else { throw XCTSkip("No permitted photos available") }
        app.buttons["PhotoSelect"].tap(); first.tap(); app.buttons["PhotoExport"].tap()
        let nameField = app.textFields["DOCPicker.filenameTextField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 40))
        let fixtureName = "OpenCommander-Export-QA-" + UUID().uuidString
        nameField.tap()
        if let value = nameField.value as? String { nameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count)) }
        nameField.typeText(fixtureName)
        let save = app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", ["Save", "Sichern"])).firstMatch
        XCTAssertTrue(save.exists); save.tap()
        XCTAssertTrue(nameField.waitForNonExistence(timeout: 20))
        evidence("photo-export-saved")
        app.navigationBars.buttons["BackButton"].tap()
        app.cells["Source-local_documents"].tap()
        let exported = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "File-1-" + fixtureName)).firstMatch
        XCTAssertTrue(exported.waitForExistence(timeout: 15), app.debugDescription)
        exported.doubleTap()
        XCTAssertTrue(app.otherElements["ImageViewer"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.images["ImageViewerImage"].exists)
        XCTAssertTrue(app.activityIndicators["ImageViewerLoading"].waitForNonExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["ImageViewerError"].exists)
        evidence("exported-photo-opened-as-file")
        app.buttons["ImageViewerClose"].tap()
    }

    func testVideoLibrary() throws {
        app.cells["Source-media_videos"].tap(); grantLibraryPermission()
        let first = app.cells["PhotoAsset-0"]
        guard first.waitForExistence(timeout: 15) else { evidence("videos-empty"); throw XCTSkip("No permitted videos available") }
        first.tap()
        XCTAssertTrue(app.otherElements["LibraryMediaViewer"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["LibraryVideoPlayer"].waitForExistence(timeout: 30))
        let counter = app.staticTexts["LibraryMediaCounter"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in Double(counter.value as? String ?? "") != nil }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        let initialTime = Double(counter.value as? String ?? "0") ?? 0
        app.descendants(matching: .any)["LibraryVideoPlayer"].tap()
        let play = app.buttons.matching(NSPredicate(format: "label IN %@", ["Play", "Wiedergabe", "Abspielen"])).firstMatch
        if play.waitForExistence(timeout: 2) { play.tap() }
        let progressed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (Double(counter.value as? String ?? "0") ?? 0) > initialTime + 0.5
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [progressed], timeout: 20), .completed)
        evidence("video-player-playing")
        app.buttons["LibraryMediaClose"].tap()
    }
    func testMusicLibraryAndPlayback() throws {
        app.cells["Source-media_music"].tap(); grantLibraryPermission()
        XCTAssertTrue(app.descendants(matching: .any)["MusicLibrary"].waitForExistence(timeout: 10))
        let first = app.cells["MusicSong-0"]
        guard first.waitForExistence(timeout: 15) else {
            XCTAssertFalse(app.buttons["MusicPlayPause"].isEnabled)
            evidence("music-empty-or-denied"); throw XCTSkip("No playable song in this device library")
        }
        first.tap()
        let now = app.staticTexts["MusicNowPlaying"]
        XCTAssertTrue(now.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["MusicStop"].isEnabled)
        evidence("music-playing")
        app.buttons["MusicPlayPause"].tap()
        app.buttons["MusicPlayPause"].tap()
        app.buttons["MusicStop"].tap()
        evidence("music-stopped")
    }
}
