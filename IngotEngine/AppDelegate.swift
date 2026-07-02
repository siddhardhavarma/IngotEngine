//
//  AppDelegate.swift
//  IngotEngine
//
//  Professional editor window with NSToolbar in the title bar.
//

import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    var window: NSWindow?

    func applicationDidFinishLaunching(_ aNotification: Notification) {

        if ProjectManager.shared.currentProjectURL == nil {
            let panel = NSOpenPanel()
            panel.title = "Select or Create a Project Folder"
            panel.message = "Choose a folder for your game project."
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Open Project"

            let response = panel.runModal()
            if response == .OK, let url = panel.url {
                ProjectManager.shared.createOrOpenProject(at: url)
            } else {
                let fallback = FileManager.default.urls(for: .documentDirectory,
                                                         in: .userDomainMask).first!
                    .appendingPathComponent("IngotProject")
                ProjectManager.shared.createOrOpenProject(at: fallback)
            }
        }

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

        self.window = window
    }

    func applicationWillTerminate(_ aNotification: Notification) {}

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}
