// zswitch — menu bar account switcher for ZCode (GLM Coding Plan)
//
// Snapshots ~/.zcode/v2/credentials.json per account, swaps them atomically,
// and restarts ZCode when no task is running.

import AppKit
import CryptoKit
import SQLite3
import ServiceManagement
import UserNotifications

// MARK: - Paths

let home = NSHomeDirectory()
let zcodeCredsPath = home + "/.zcode/v2/credentials.json"
let zswitchDir = home + "/.zswitch"
let accountsDir = zswitchDir + "/accounts"
let statePath = zswitchDir + "/state.json"
let zcodeStatusDir = home + "/.zcode-status"
let zcodeExecDir = home + "/.zcode/cli/exec"
let zcodeTasksDb = home + "/.zcode/v2/tasks-index.sqlite"
let zcodeBundleID = "dev.zcode.app"

// MARK: - Credential crypto (mirrors ZCode's credentialService)

let credentialKey: SymmetricKey = {
    let env = ProcessInfo.processInfo.environment["ZCODE_CREDENTIAL_SECRET"] ?? ""
    let secret = env.isEmpty
        ? "zcode-credential-fallback:darwin:\(NSHomeDirectory()):\(NSUserName())"
        : env
    return SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
}()

func base64urlDecode(_ s: String) -> Data? {
    var t = s.replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    while t.count % 4 != 0 { t += "=" }
    return Data(base64Encoded: t)
}

func decryptCredentialValue(_ v: String) -> Data? {
    guard v.hasPrefix("enc:v1:") else { return Data(v.utf8) }
    let parts = v.dropFirst("enc:v1:".count).components(separatedBy: ".")
    guard parts.count == 3,
          let iv = base64urlDecode(parts[0]),
          let tag = base64urlDecode(parts[1]),
          let ct = base64urlDecode(parts[2]),
          iv.count == 12, tag.count == 16
    else { return nil }
    guard let sealed = try? AES.GCM.SealedBox(combined: iv + ct + tag) else { return nil }
    return try? AES.GCM.open(sealed, using: credentialKey)
}

struct AccountIdentity {
    var email: String?
    var name: String?
    var userId: String?
}

func identity(ofCredentialsData data: Data) -> AccountIdentity {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let raw = obj["oauth:zai:user_info"] as? String,
          let plain = decryptCredentialValue(raw),
          let info = try? JSONSerialization.jsonObject(with: plain) as? [String: Any]
    else { return AccountIdentity(email: nil, name: nil, userId: nil) }
    return AccountIdentity(email: info["email"] as? String,
                           name: info["name"] as? String,
                           userId: info["user_id"] as? String)
}

// MARK: - Account store

struct Account {
    var dirName: String      // folder under ~/.zswitch/accounts
    var name: String
    var email: String
    var userId: String
    var auto: Bool

    var dir: String { accountsDir + "/" + dirName }
    var credsFile: String { dir + "/credentials.json" }
    var metaFile: String { dir + "/meta.json" }
}

func loadAccounts() -> [Account] {
    let fm = FileManager.default
    guard let children = try? fm.contentsOfDirectory(atPath: accountsDir) else { return [] }
    var result: [Account] = []
    for child in children.sorted() {
        let metaPath = accountsDir + "/" + child + "/meta.json"
        guard let data = fm.contents(atPath: metaPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["name"] as? String
        else { continue }
        result.append(Account(dirName: child,
                              name: name,
                              email: obj["email"] as? String ?? "",
                              userId: obj["userId"] as? String ?? "",
                              auto: obj["auto"] as? Bool ?? false))
    }
    return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

func saveMeta(_ account: Account) {
    let obj: [String: Any] = ["name": account.name, "email": account.email,
                              "userId": account.userId, "auto": account.auto]
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
    FileManager.default.createFile(atPath: account.metaFile, contents: data, attributes: [.posixPermissions: 0o600])
}

func loadState() -> [String: Any] {
    guard let data = FileManager.default.contents(atPath: statePath),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return obj
}

func saveState(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
    FileManager.default.createFile(atPath: statePath, contents: data, attributes: [.posixPermissions: 0o600])
}

func sanitizedFolderName(_ name: String) -> String {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    let scalars = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
    var s = String(scalars)
    if s.count > 48 { s = String(s.prefix(48)) }
    return s.isEmpty ? "account" : s
}

func atomicWrite(_ data: Data, to path: String) throws {
    let dir = (path as NSString).deletingLastPathComponent
    let tmp = dir + "/.zswitch.tmp." + UUID().uuidString
    FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600])
    let tmpURL = URL(fileURLWithPath: tmp)
    let dstURL = URL(fileURLWithPath: path)
    let fm = FileManager.default
    if fm.fileExists(atPath: path) {
        _ = try fm.replaceItemAt(dstURL, withItemAt: tmpURL)
    } else {
        try fm.moveItem(at: tmpURL, to: dstURL)
    }
}

// MARK: - Task-running detection

func zcodeRunning() -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: zcodeBundleID).isEmpty
}

func fileAge(_ path: String) -> TimeInterval? {
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    guard let date = attrs?[.modificationDate] as? Date else { return nil }
    return Date().timeIntervalSince(date)
}

/// The user's ZCode hooks touch ~/.zcode-status/{thinking,tool} during a run
/// and {done} on Stop. If activity is newer than the last Stop (and recent
/// enough that a crashed session can't pin it forever), a task is live.
func statusHookRunning() -> Bool {
    var latestActivity: Date?
    for marker in ["thinking", "tool"] {
        let p = zcodeStatusDir + "/" + marker
        if let attrs = try? FileManager.default.attributesOfItem(atPath: p),
           let d = attrs[.modificationDate] as? Date {
            latestActivity = max(latestActivity ?? .distantPast, d)
        }
    }
    guard let activity = latestActivity else { return false }
    let doneAttrs = try? FileManager.default.attributesOfItem(atPath: zcodeStatusDir + "/done")
    let done = (doneAttrs?[.modificationDate] as? Date) ?? .distantPast
    if activity <= done { return false }                 // explicit Stop after last activity
    guard Date().timeIntervalSince(activity) < 600 else { return false } // stale crash leftover
    return true
}

/// Agent execution logs appear under ~/.zcode/cli/exec/sess_*/ while a run
/// streams tool output; completed sessions leave their dir empty.
func execLogsFresh() -> Bool {
    let fm = FileManager.default
    guard let sessions = try? fm.contentsOfDirectory(atPath: zcodeExecDir) else { return false }
    for session in sessions where session.hasPrefix("sess_") {
        let dir = zcodeExecDir + "/" + session
        if let age = fileAge(dir), age < 90 { return true }
        if let files = try? fm.contentsOfDirectory(atPath: dir) {
            for f in files {
                if let age = fileAge(dir + "/" + f), age < 90 { return true }
            }
        }
    }
    return false
}

/// Belt-and-suspenders: the tasks DB (read-only) may report running rows.
func dbReportsRunning() -> Bool {
    var db: OpaquePointer?
    guard sqlite3_open_v2(zcodeTasksDb, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        if db != nil { sqlite3_close(db) }
        return false
    }
    defer { sqlite3_close(db) }
    let sql = "SELECT (SELECT COUNT(*) FROM tasks WHERE deleted=0 AND task_status='running')" +
              " + (SELECT COUNT(*) FROM automations WHERE running=1);"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
    return sqlite3_column_int64(stmt, 0) > 0
}

func taskRunning() -> Bool {
    guard zcodeRunning() else { return false }
    return statusHookRunning() || execLogsFresh() || dbReportsRunning()
}

// MARK: - ZCode lifecycle

func zcodeAppURL() -> URL? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: zcodeBundleID)
}

func restartZCode() {
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: zcodeBundleID)
    if !running.isEmpty {
        for app in running { app.terminate() }
        for _ in 0..<50 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: zcodeBundleID).isEmpty { break }
            usleep(200_000)
        }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: zcodeBundleID) {
            app.forceTerminate()
        }
        usleep(500_000)
    }
    if let url = zcodeAppURL() {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

func launchZCode() {
    guard !zcodeRunning(), let url = zcodeAppURL() else { return }
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
}

// MARK: - Notifications

func requestNotificationPermission() {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
}

func notify(_ title: String, _ body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(req)
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: accountsDir, withIntermediateDirectories: true)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let icon = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                                  accessibilityDescription: "zswitch") {
                button.image = icon
            } else {
                button.title = "ZS"
            }
            button.toolTip = "zswitch — ZCode account switcher"
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        requestNotificationPermission()

        // Dev/testing hooks: open "zswitch://menu" or "zswitch://capture"
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
    }

    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        let url = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue ?? ""
        if url.hasPrefix("zswitch://menu") {
            statusItem.button?.performClick(nil)
        } else if url.hasPrefix("zswitch://capture") {
            captureCurrent(NSMenuItem())
        }
    }

    // MARK: Menu construction

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let accounts = loadAccounts()
        let liveData = FileManager.default.contents(atPath: zcodeCredsPath)
        let liveIdentity = liveData.map { identity(ofCredentialsData: $0) } ?? AccountIdentity(email: nil, name: nil, userId: nil)
        let activeUserId = liveIdentity.userId

        let activeLabel = activeUserId.flatMap { uid in
            accounts.first { $0.userId == uid }?.name
        } ?? liveIdentity.email ?? "unknown (not captured)"

        let header = NSMenuItem(title: "Active account: \(activeLabel)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let state: String
        if !zcodeRunning() { state = "ZCode not running" }
        else if taskRunning() { state = "● Task running in ZCode" }
        else { state = "ZCode idle — safe to switch" }
        let statusLine = NSMenuItem(title: state, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        menu.addItem(.separator())

        if accounts.isEmpty {
            let empty = NSMenuItem(title: "No accounts saved yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for account in accounts {
            let isActive = !account.userId.isEmpty && account.userId == activeUserId
            let title = isActive ? "✓ \(account.name)" : "   \(account.name)"
            let item = NSMenuItem(title: title, action: #selector(switchAccount(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = account.dirName
            item.toolTip = account.email
            item.isEnabled = true
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let add = NSMenuItem(title: "Add Account — Capture Current Login…",
                             action: #selector(captureCurrent(_:)), keyEquivalent: "")
        add.target = self
        menu.addItem(add)

        if !accounts.isEmpty {
            let removeItem = NSMenuItem(title: "Remove Account", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for account in accounts {
                let row = NSMenuItem(title: "“\(account.name)”…",
                                     action: #selector(removeAccount(_:)), keyEquivalent: "")
                row.target = self
                row.representedObject = account.dirName
                row.isEnabled = true
                submenu.addItem(row)
            }
            removeItem.submenu = submenu
            menu.addItem(removeItem)
        }

        menu.addItem(.separator())

        let open = NSMenuItem(title: "Open ZCode", action: #selector(openZCode(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit zswitch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func account(from sender: NSMenuItem) -> Account? {
        guard let dirName = sender.representedObject as? String else { return nil }
        return loadAccounts().first { $0.dirName == dirName }
    }

    // MARK: Actions

    @objc func captureCurrent(_ sender: NSMenuItem) {
        let fm = FileManager.default
        guard let data = fm.contents(atPath: zcodeCredsPath) else {
            alert(title: "No ZCode login found",
                  text: "\(zcodeCredsPath) not found. Log into ZCode first, then capture.")
            return
        }
        let ident = identity(ofCredentialsData: data)

        if let uid = ident.userId,
           let existing = loadAccounts().first(where: { $0.userId == uid }) {
            do { try atomicWrite(data, to: existing.credsFile) }
            catch { alert(title: "Could not update snapshot", text: "\(error)"); return }
            alert(title: "Snapshot updated",
                  text: "This login is already saved as “\(existing.name)”. Its snapshot was refreshed.")
            return
        }

        let proposedName = ident.email ?? ident.name ?? "Account \(loadAccounts().count + 1)"
        guard let name = prompt(title: "Add Account",
                                text: "Captures the ZCode login currently active on disk"
                                      + (ident.email.map { " (\($0))" } ?? "")
                                      + ". Name this account:",
                                initial: proposedName) else { return }

        var dirName = sanitizedFolderName(name)
        while fm.fileExists(atPath: accountsDir + "/" + dirName) {
            dirName += "-" + String(format: "%04x", Int.random(in: 0..<0x10000))
        }
        let dir = accountsDir + "/" + dirName
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let account = Account(dirName: dirName, name: name,
                                  email: ident.email ?? "", userId: ident.userId ?? "", auto: false)
            try atomicWrite(data, to: account.credsFile)
            saveMeta(account)
            var state = loadState()
            state["activeUserId"] = ident.userId ?? ""
            saveState(state)
            notify("Account added", "“\(name)” captured and ready in the menu.")
        } catch {
            alert(title: "Capture failed", text: "\(error)")
        }
    }

    @objc func switchAccount(_ sender: NSMenuItem) {
        guard let target = account(from: sender) else { return }
        let fm = FileManager.default
        guard let liveData = fm.contents(atPath: zcodeCredsPath) else {
            alert(title: "No ZCode login found",
                  text: "\(zcodeCredsPath) not found — ZCode may not be logged in yet.")
            return
        }
        let liveIdentity = identity(ofCredentialsData: liveData)

        if !target.userId.isEmpty && target.userId == liveIdentity.userId {
            do { try atomicWrite(liveData, to: target.credsFile) } // refresh snapshot
            catch { alert(title: "Could not refresh snapshot", text: "\(error)") }
            notify("Already active", "“\(target.name)” is the current ZCode account.")
            return
        }

        if taskRunning() {
            let a = NSAlert()
            a.messageText = "Task running in ZCode"
            a.informativeText = "Switching accounts now could interrupt the running task. Switch anyway?"
            a.addButton(withTitle: "Cancel")
            a.addButton(withTitle: "Switch Anyway")
            a.alertStyle = .warning
            if a.runModal() != .alertSecondButtonReturn { return }
        }

        do {
            // Never lose a freshly refreshed token: stash the current login first.
            try stashCurrentLogin(liveData, liveIdentity: liveIdentity)
            guard let snapshot = fm.contents(atPath: target.credsFile) else {
                alert(title: "Switch failed",
                      text: "Snapshot missing for “\(target.name)” at \(target.credsFile).")
                return
            }
            try atomicWrite(snapshot, to: zcodeCredsPath)
        } catch {
            alert(title: "Switch failed", text: "\(error)")
            return
        }

        var state = loadState()
        state["activeUserId"] = target.userId
        saveState(state)

        let wasRunning = zcodeRunning()
        notify("Switched to “\(target.name)”", wasRunning ? "Restarting ZCode…" : "Launching ZCode…")
        DispatchQueue.global(qos: .userInitiated).async {
            if wasRunning { restartZCode() } else { launchZCode() }
        }
    }

    /// Saves the live credentials back to whichever account they belong to,
    /// auto-capturing if the login on disk was never saved.
    private func stashCurrentLogin(_ liveData: Data, liveIdentity: AccountIdentity) throws {
        if let uid = liveIdentity.userId,
           let existing = loadAccounts().first(where: { $0.userId == uid }) {
            try atomicWrite(liveData, to: existing.credsFile)
            return
        }
        let fm = FileManager.default
        let name = liveIdentity.email ?? "Auto-captured \(Int(Date().timeIntervalSince1970))"
        var dirName = sanitizedFolderName(name)
        while fm.fileExists(atPath: accountsDir + "/" + dirName) {
            dirName += "-" + String(format: "%04x", Int.random(in: 0..<0x10000))
        }
        let account = Account(dirName: dirName, name: name, email: liveIdentity.email ?? "",
                              userId: liveIdentity.userId ?? "", auto: true)
        try fm.createDirectory(atPath: account.dir, withIntermediateDirectories: true)
        try atomicWrite(liveData, to: account.credsFile)
        saveMeta(account)
    }

    @objc func removeAccount(_ sender: NSMenuItem) {
        guard let target = account(from: sender) else { return }
        let a = NSAlert()
        a.messageText = "Remove “\(target.name)”?"
        a.informativeText = "Only the zswitch snapshot is deleted. The login currently active in ZCode is not touched."
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Remove")
        a.alertStyle = .warning
        guard a.runModal() == .alertSecondButtonReturn else { return }
        try? FileManager.default.removeItem(atPath: target.dir)
    }

    @objc func openZCode(_ sender: NSMenuItem) {
        if zcodeRunning() {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: zcodeBundleID) {
                app.activate()
            }
        } else {
            launchZCode()
        }
    }

    @objc func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        switch service.status {
        case .enabled:
            try? service.unregister()
        default:
            try? service.register()
        }
    }

    // MARK: Dialog helpers

    func alert(title: String, text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    @discardableResult
    func prompt(title: String, text: String, initial: String) -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = initial
        a.accessoryView = input
        a.window.initialFirstResponder = input
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let value = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

// MARK: - Entry point

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
