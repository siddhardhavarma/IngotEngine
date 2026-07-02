//
//  AppDelegate.swift
//  IngotEngine
//
//  App startup flow:
//
//    launch → Project Launcher (recents / new / open) → Editor window
//
//  The launcher is the first thing users see (like Godot's Project
//  Manager). Choosing or creating a project closes the launcher and
//  opens the full editor for that project.
//

import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    var launcherWindow: NSWindow?
    var editorWindow: NSWindow?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        showProjectLauncher()
    }

    // MARK: - Project launcher

    private func showProjectLauncher() {
        let launcher = ProjectLauncherViewController()
        launcher.onProjectChosen = { [weak self] url in
            self?.openProject(at: url)
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Ingot Engine"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentViewController = launcher
        window.center()
        window.makeKeyAndOrderFront(nil)

        launcherWindow = window
    }

    // MARK: - Editor

    private func openProject(at url: URL) {
        ProjectManager.shared.createOrOpenProject(at: url)
        ProjectLauncherViewController.addRecent(url)

        launcherWindow?.close()
        launcherWindow = nil

        openEditorWindow()
    }

    private func openEditorWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        let projectName = ProjectManager.shared.currentProjectURL?.lastPathComponent ?? "Untitled"
        window.title = "Ingot Engine — \(projectName)"
        window.minSize = NSSize(width: 960, height: 600)
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.toolbarStyle = .unified

        let editorVC = EditorViewController()
        window.contentViewController = editorVC

        // Build the toolbar.
        let toolbar = NSToolbar(identifier: "IngotToolbar")
        toolbar.delegate = editorVC
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        window.center()
        window.makeKeyAndOrderFront(nil)

        editorWindow = window
    }

    func applicationWillTerminate(_ aNotification: Notification) {}

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}
