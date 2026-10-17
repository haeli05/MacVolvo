import AppKit
import SwiftUI
import Darwin

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let model=AppModel()
    var window:NSWindow!
    var lockFD:Int32 = -1
    func applicationDidFinishLaunching(_ notification:Notification) {
        // NSWorkspace normally routes repeat opens to this process. The file lock
        // also covers explicit `open -n` and copies of the same app bundle.
        let lockDirectory=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent(Brand.bundleIdentifier)
        try? FileManager.default.createDirectory(at:lockDirectory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        lockFD=open(lockDirectory.appendingPathComponent("app.lock").path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
        if lockFD<0 || flock(lockFD,LOCK_EX|LOCK_NB) != 0 {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier:Bundle.main.bundleIdentifier ?? "") where app.processIdentifier != ProcessInfo.processInfo.processIdentifier { app.activate(options:[]) }
            NSApp.terminate(nil);return
        }
        // Quits from outside the app (the Dock, logging out, System Settings' "Quit & Reopen"
        // after a privacy change) arrive as this event. AppKit drops it while a sheet is open,
        // so AppModel.quit handles it: it closes the sheet first.
        NSAppleEventManager.shared().setEventHandler(self,andSelector:#selector(quitEvent(_:withReplyEvent:)),forEventClass:AEEventClass(kCoreEventClass),andEventID:AEEventID(kAEQuitApplication))
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:800),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title=Brand.name;window.isReleasedWhenClosed=false
        window.titlebarAppearsTransparent=true;window.minSize=NSSize(width:540,height:620)
        window.contentView=NSHostingView(rootView:SetupView(model:model));window.center();window.makeKeyAndOrderFront(nil)
        NSApp.mainMenu=menu();NSApp.activate(ignoringOtherApps:true)
    }
    func menu()->NSMenu {
        let main=NSMenu(),app=NSMenu(),top=NSMenuItem();main.addItem(top);top.submenu=app
        func add(_ title:String,_ action:Selector,_ key:String="",to menu:NSMenu?=nil) { let item=NSMenuItem(title:title,action:action,keyEquivalent:key);item.target=self;(menu ?? app).addItem(item) }
        add("About \(Brand.name)",#selector(about))
        add("Check for Updates…",#selector(checkForUpdates))
        app.addItem(.separator())
        add("Settings…",#selector(settings),",")
        app.addItem(.separator())
        for game in AppModel.Game.allCases { app.addItem(playItem(game)) }
        add("Open Steam",#selector(launch),"o")
        app.addItem(.separator())
        add("Uninstall \(Brand.name)…",#selector(uninstall))
        app.addItem(.separator())
        let hide=NSMenuItem(title:"Hide \(Brand.name)",action:#selector(NSApplication.hide(_:)),keyEquivalent:"h");app.addItem(hide)
        add("Quit \(Brand.name)",#selector(quit),"q")
        let editItem=NSMenuItem();main.addItem(editItem);let edit=NSMenu(title:"Edit");editItem.submenu=edit
        for (title,selector,key) in [("Copy",#selector(NSText.copy(_:)),"c"),("Select All",#selector(NSText.selectAll(_:)),"a")] { edit.addItem(NSMenuItem(title:title,action:selector,keyEquivalent:key)) }
        let windowItem=NSMenuItem();main.addItem(windowItem);let wm=NSMenu(title:"Window");windowItem.submenu=wm
        wm.addItem(NSMenuItem(title:"Minimize",action:#selector(NSWindow.performMiniaturize(_:)),keyEquivalent:"m"))
        wm.addItem(NSMenuItem(title:"Close",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w"))
        NSApp.windowsMenu=wm
        let helpItem=NSMenuItem();main.addItem(helpItem);let helpMenu=NSMenu(title:"Help");helpItem.submenu=helpMenu
        add("\(Brand.name) Help",#selector(help),"?",to:helpMenu)
        add("What’s New in \(Brand.name)",#selector(whatsNew),to:helpMenu)
        helpMenu.addItem(.separator())
        add("Release Notes",#selector(releaseNotes),to:helpMenu)
        add("Report a Problem…",#selector(reportProblem),to:helpMenu)
        add("\(Brand.name) on GitHub",#selector(repository),to:helpMenu)
        NSApp.helpMenu=helpMenu
        if model.release?.distribution == "private-preview" && CommandLine.arguments.contains("--preview-state") {
            let item=NSMenuItem();main.addItem(item);let preview=NSMenu(title:"Preview");item.submenu=preview
            for screen in AppModel.Screen.allCases {
                let option=NSMenuItem(title:screen.rawValue,action:#selector(previewScreen(_:)),keyEquivalent:"")
                option.representedObject=screen.rawValue;option.target=self;preview.addItem(option)
            }
            preview.addItem(.separator())
            for title in ["Light appearance","Dark appearance"] {
                let option=NSMenuItem(title:title,action:#selector(previewAppearance(_:)),keyEquivalent:"");option.target=self;preview.addItem(option)
            }
        }
        return main
    }
    func validateMenuItem(_ item:NSMenuItem)->Bool {
        if item.action == #selector(checkForUpdates) && !Brand.allowsUpdates { return false }
        // Still on the disk image: only moving to Applications, Help and About.
        if model.screen == .moveApp,let action=item.action,[#selector(launch),#selector(forceQuit),#selector(play(_:)),#selector(settings),#selector(checkForUpdates),#selector(uninstall)].contains(action) { return false }
        if item.action == #selector(launch) || item.action == #selector(forceQuit) { return model.clientInstalled && !model.busy }
        if item.action == #selector(play(_:)) {
            let game=(item.representedObject as? String).flatMap(AppModel.Game.init(rawValue:))
            return model.clientInstalled && game.map(model.installedGames.contains) == true && !model.busy
        }
        if item.action == #selector(settings) || item.action == #selector(checkForUpdates) { return model.uninstall != .working }
        return true
    }
    // Right-clicking the Dock icon: start the game, or close a frozen one.
    func applicationDockMenu(_ sender:NSApplication)->NSMenu? {
        let menu=NSMenu()
        for game in AppModel.Game.allCases { menu.addItem(playItem(game)) }
        for (title,action) in [("Open Steam",#selector(launch)),("Force Quit Game & Steam…",#selector(forceQuit))] {
            let item=NSMenuItem(title:title,action:action,keyEquivalent:"");item.target=self;menu.addItem(item)
        }
        return menu
    }
    /// Play <game>, in the app and Dock menus; enabled once Steam has installed it.
    private func playItem(_ game:AppModel.Game)->NSMenuItem {
        let item=NSMenuItem(title:"Play \(game.title)",action:#selector(play(_:)),keyEquivalent:"")
        item.representedObject=game.rawValue;item.target=self;return item
    }
    @objc func play(_ sender:NSMenuItem) {
        guard let game=(sender.representedObject as? String).flatMap(AppModel.Game.init(rawValue:)) else { return }
        show();model.play(game)
    }
    @objc func checkForUpdates() { show();model.checkForUpdates(manual:true) }
    @objc func whatsNew() { show();model.sheet = .whatsNew }
    @objc func releaseNotes() { NSWorkspace.shared.open(Brand.releases) }
    @objc func reportProblem() { NSWorkspace.shared.open(Brand.issues) }
    @objc func repository() { NSWorkspace.shared.open(Brand.repository) }
    @objc func forceQuit() {
        show()
        let alert=NSAlert();alert.messageText="Force quit your game and Steam?"
        alert.informativeText="Use this when the game stops responding. If you’re in a match, you’ll leave it."
        alert.addButton(withTitle:"Force Quit").hasDestructiveAction=true;alert.addButton(withTitle:"Cancel")
        if alert.runModal() == .alertFirstButtonReturn { model.forceQuit() }
    }
    @objc func previewScreen(_ sender:NSMenuItem) {
        if let value=sender.representedObject as? String,let screen=AppModel.Screen(rawValue:value) { model.previewScreen(screen) }
    }
    @objc func previewAppearance(_ sender:NSMenuItem) {
        guard model.isPreview else { return };NSApp.appearance=NSAppearance(named:sender.title == "Dark appearance" ? .darkAqua : .aqua)
    }
    @objc func launch() { show();model.launch() }
    @objc func quit() { model.quit() }
    @objc func quitEvent(_ event:NSAppleEventDescriptor,withReplyEvent reply:NSAppleEventDescriptor) { model.quit() }
    @objc func settings() { show();model.sheet = .settings }
    @objc func about() { show();model.sheet = .about }
    @objc func uninstall() { show();model.sheet = .uninstall }
    @objc func help() { show();model.makeReport();model.sheet = .help }
    func show() { window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true) }
    func applicationDidBecomeActive(_ notification:Notification) { model.syncSession();model.checkIfDue() }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool)->Bool { show();model.reopen();return false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { false }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        if model.quitsNow { return .terminateNow }
        if !model.canCancel { show();model.notice="Finishing the current step. You can quit as soon as it completes.";return .terminateCancel }
        model.cancel()
        Task { while model.busy { try? await Task.sleep(for:.milliseconds(100)) };sender.reply(toApplicationShouldTerminate:true) }
        return .terminateLater
    }
}
@main struct LauncherMain {
    @MainActor static func main() {
        let app=NSApplication.shared,delegate=AppDelegate()
        app.setActivationPolicy(.regular);app.delegate=delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
