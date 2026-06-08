import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum SyncPermissionChoice {
    case startAuthorization
    case pageSync
}

private enum InputSyncFallbackPreference {
    private static let defaultToPageSyncKey = "inputSync.defaultToPageSyncWhenSystemPermissionsMissing.v2"

    static var defaultToPageSync: Bool {
        get { UserDefaults.standard.bool(forKey: defaultToPageSyncKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultToPageSyncKey)
            UserDefaults.standard.synchronize()
        }
    }
}

private struct PendingInputSyncAuthorization {
    let masterID: Int
    let targetIDs: [Int]
    var didOpenInputMonitoring = false
    var didOpenAccessibility = false
}

struct ContentView: View {
    @StateObject private var store = ProfileStore()
    private let controller = ChromeController()

    @State private var selection = Set<Int>()
    @State private var runtime = RuntimeStatus()
    @State private var draftProfile = ChromeProfile.blank(id: 1)
    @State private var editingExisting = false
    @State private var showingEditor = false
    @State private var groupURL = "https://www.google.com"
    @State private var groupScript = ""
    @State private var onlySelected = false
    @State private var syncMasterID: Int?
    @State private var inputSync: MacInputSynchronizer?
    @State private var pendingInputSyncAuthorization: PendingInputSyncAuthorization?
    @State private var permissionPollTask: Task<Void, Never>?
    @State private var pageModeUpgradeTask: Task<Void, Never>?
    @State private var isBusy = false
    @State private var operationID: UUID?

    private var selectedProfiles: [ChromeProfile] {
        store.profiles.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                Divider()
                profileTable
            }
            Divider()
            groupControlBar
            Divider()
            statusBar
        }
        .navigationTitle("\(AppInfo.displayName) v\(AppInfo.version)")
        .onAppear { handleAppear() }
        .sheet(isPresented: $showingEditor) {
            ProfileEditorView(profile: $draftProfile, title: editingExisting ? "编辑配置" : "新建配置") {
                if editingExisting {
                    store.update(draftProfile)
                } else {
                    store.add(draftProfile)
                }
                refreshRuntime()
                showingEditor = false
            } onCancel: {
                showingEditor = false
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            button("新建配置", systemImage: "plus", action: newProfile)
            button("编辑选中", systemImage: "pencil", action: editProfile)
            button("删除选中", systemImage: "trash", role: .destructive, action: deleteSelected)

            Divider().padding(.vertical, 4)

            button("启动选中", systemImage: "play.fill", action: launchSelected)
            button("全部启动", systemImage: "play.circle", action: launchAll)
            button("关闭选中", systemImage: "stop.fill", action: stopSelected)
            button("全部关闭", systemImage: "stop.circle", action: stopAll)

            Divider().padding(.vertical, 4)

            button("排列窗口", systemImage: "rectangle.3.group", action: arrangeWindows)
            button("设为主控", systemImage: "cursorarrow.click", action: setSyncMaster)
            button(inputSync == nil ? "同步鼠标/键盘" : "停止同步", systemImage: inputSync == nil ? "keyboard" : "pause.circle", action: toggleInputSync)
            button("全窗口授权", systemImage: "lock.shield", action: authorizeFullWindowSync)
            button("导入代理", systemImage: "square.and.arrow.down", action: importProxies)
            button("刷新状态", systemImage: "arrow.clockwise") { refreshRuntime() }
            button("刷新徽标", systemImage: "number.square", action: refreshBadges)

            Spacer()
        }
        .padding(14)
        .frame(width: 178)
    }

    private var profileTable: some View {
        Table(store.profiles, selection: $selection) {
            TableColumn("#") { profile in
                Text("\(profile.id)")
                    .monospacedDigit()
            }
            .width(min: 42, ideal: 48, max: 64)

            TableColumn("名称") { profile in
                Text(profile.name)
            }
            .width(min: 110, ideal: 150)

            TableColumn("分组") { profile in
                Text(profile.group)
            }
            .width(min: 70, ideal: 90)

            TableColumn("代理") { profile in
                Text(profile.proxy)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 220, ideal: 360)

            TableColumn("状态") { profile in
                Label(runtime.isRunning(profile) ? "运行中" : "已停止",
                      systemImage: runtime.isRunning(profile) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(runtime.isRunning(profile) ? .green : .secondary)
            }
            .width(min: 90, ideal: 110)

            TableColumn("备注") { profile in
                Text(profile.note)
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 160)
        }
        .contextMenu {
            Button("启动") { launchSelected() }
            Button("关闭") { stopSelected() }
            Divider()
            Button("编辑") { editProfile() }
            Button("删除", role: .destructive) { deleteSelected() }
        }
    }

    private var groupControlBar: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Toggle("仅选中", isOn: $onlySelected)
                    .toggleStyle(.checkbox)
                    .gridColumnAlignment(.leading)

                Text("URL")
                    .foregroundStyle(.secondary)

                TextField("https://www.google.com", text: $groupURL)
                    .textFieldStyle(.roundedBorder)

                Button {
                    groupNavigate()
                } label: {
                    Label("全部跳转", systemImage: "arrow.right.circle")
                }
            }

            GridRow {
                Color.clear.frame(width: 1, height: 1)

                Text("JS")
                    .foregroundStyle(.secondary)

                TextField("document.title", text: $groupScript, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)

                Button {
                    groupEvaluate()
                } label: {
                    Label("执行 JS", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
        }
        .padding(12)
    }

    private var statusBar: some View {
        HStack {
            Text(store.status)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 26)
    }

    private func button(_ title: String, systemImage: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
    }

    private func handleAppear() {
        refreshRuntime()
        resumeInputSyncAuthorizationIfNeeded()
    }

    private func newProfile() {
        let nextID = store.nextID()
        draftProfile = ChromeProfile.blank(id: nextID)
        editingExisting = false
        showingEditor = true
    }

    private func editProfile() {
        guard selection.count == 1, let id = selection.first, let profile = store.profile(id: id) else {
            store.status = "请选中一个配置。"
            return
        }
        draftProfile = profile
        editingExisting = true
        showingEditor = true
    }

    private func deleteSelected() {
        guard !selection.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "确认删除 \(selection.count) 个配置？"
        alert.informativeText = "浏览器存档文件夹不会自动删除。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let removed = store.remove(ids: selection)
        stopSyncIfNeeded(including: removed.map(\.id))
        for profile in removed {
            controller.stop(profile)
        }
        selection.removeAll()
        refreshRuntime()
    }

    private func launchSelected() {
        let targets = selectedProfiles
        guard !targets.isEmpty else {
            store.status = "请先选中配置。"
            return
        }
        AppLogger.info("launch selected clicked count=\(targets.count)")
        launch(profiles: targets, finalMessage: "已启动 \(targets.count) 个配置。")
    }

    private func launchAll() {
        AppLogger.info("launch all clicked count=\(store.profiles.count)")
        launch(profiles: store.profiles, finalMessage: "已启动 \(store.profiles.count) 个配置。")
    }

    private func launch(profiles: [ChromeProfile], finalMessage: String) {
        guard !profiles.isEmpty else {
            store.status = "还没有配置。"
            return
        }
        guard let token = beginOperation("正在启动 \(profiles.count) 个配置...") else { return }
        let controller = controller
        let store = store
        Task.detached(priority: .userInitiated) {
            var updatedProfiles: [ChromeProfile] = []
            var failedMessages: [String] = []
            await withTaskGroup(of: (ChromeProfile, ChromeProfile?, String?).self) { group in
                for profile in profiles {
                    group.addTask {
                        do {
                            let updated = try controller.launch(profile)
                            return (profile, updated, nil)
                        } catch {
                            return (profile, nil, error.localizedDescription)
                        }
                    }
                }
                var completed = 0
                for await outcome in group {
                    completed += 1
                    let original = outcome.0
                    if let updated = outcome.1 {
                        updatedProfiles.append(updated)
                        await MainActor.run {
                            store.replace(updated)
                            store.status = "正在启动: \(original.name)   \(completed)/\(profiles.count)"
                        }
                    } else if let errorMessage = outcome.2 {
                        failedMessages.append("\(original.name): \(errorMessage)")
                        await MainActor.run {
                            store.status = "启动失败: \(original.name)   \(errorMessage)   \(completed)/\(profiles.count)"
                        }
                    }
                }
            }
            let message: String
            if failedMessages.isEmpty {
                message = finalMessage
            } else {
                message = "已启动 \(updatedProfiles.count) 个，失败 \(failedMessages.count) 个。\(failedMessages.first ?? "")"
            }
            AppLogger.info("launch batch finished success=\(updatedProfiles.count) failed=\(failedMessages.count)")
            await MainActor.run {
                finishOperation(token, message: message)
            }
            if !updatedProfiles.isEmpty {
                controller.refreshBadges(profiles: updatedProfiles)
            }
        }
    }

    private func stopSelected() {
        let targets = selectedProfiles
        guard !targets.isEmpty else {
            store.status = "请先选中配置。"
            return
        }
        AppLogger.info("stop selected clicked count=\(targets.count)")
        stopSyncIfNeeded(including: targets.map(\.id))
        guard let token = beginOperation("正在关闭 \(targets.count) 个配置...", allowWhileBusy: true) else { return }
        let controller = controller
        let store = store
        Task.detached(priority: .userInitiated) {
            await withTaskGroup(of: ChromeProfile.self) { group in
                for profile in targets {
                    group.addTask {
                        controller.stop(profile)
                        var stopped = profile
                        stopped.pid = nil
                        return stopped
                    }
                }
                for await stopped in group {
                    await MainActor.run {
                        store.replace(stopped)
                    }
                }
            }
            await MainActor.run {
                finishOperation(token, message: "已关闭 \(targets.count) 个配置。")
            }
        }
    }

    private func stopAll() {
        let targets = store.profiles
        guard !targets.isEmpty else {
            store.status = "还没有配置。"
            return
        }
        AppLogger.info("stop all clicked count=\(targets.count)")
        stopInputSync(message: "")
        guard let token = beginOperation("正在关闭全部配置...", allowWhileBusy: true) else { return }
        let controller = controller
        let store = store
        Task.detached(priority: .userInitiated) {
            for profile in targets {
                controller.stop(profile)
                var stopped = profile
                stopped.pid = nil
                await MainActor.run {
                    store.replace(stopped)
                }
            }
            await MainActor.run {
                finishOperation(token, message: "全部已关闭。")
            }
        }
    }

    private func setSyncMaster() {
        guard selection.count == 1, let id = selection.first, let profile = store.profile(id: id) else {
            store.status = "请选择一个运行中的配置作为主控。"
            return
        }
        guard controller.isRunning(profile) else {
            store.status = "主控配置尚未启动，请先启动。"
            return
        }
        syncMasterID = id
        refreshRuntime(message: "主控已设为: #\(profile.id) \(profile.name)。")
    }

    private func currentSyncMaster() -> ChromeProfile? {
        if let syncMasterID, let profile = store.profile(id: syncMasterID), controller.isRunning(profile) {
            return profile
        }
        if selection.count == 1, let id = selection.first, let profile = store.profile(id: id), controller.isRunning(profile) {
            syncMasterID = id
            return profile
        }
        let running = store.profiles.first { controller.isRunning($0) }
        syncMasterID = running?.id
        return running
    }

    private func toggleInputSync() {
        if inputSync != nil {
            stopInputSync(message: "同步已停止。")
            return
        }
        guard let master = currentSyncMaster() else {
            store.status = "没有运行中的 Chrome 窗口，请先启动配置。"
            return
        }
        let targets = store.profiles.filter { $0.id != master.id && controller.isRunning($0) }
        guard !targets.isEmpty else {
            store.status = "至少需要 1 个从控窗口。请再启动一个配置。"
            return
        }

        continuePendingInputSyncAuthorizationIfReady()
        if inputSync != nil {
            return
        }

        let permissionStatus = MacInputSynchronizer.systemPermissionStatus()
        if !permissionStatus.canUseSystemMode {
            if InputSyncFallbackPreference.defaultToPageSync {
                startInputSync(master: master, targets: targets, requestSystemPermissions: false, preferSystemMode: false)
                return
            }

            switch showInputSyncPermissionGuide(status: permissionStatus) {
            case .startAuthorization:
                beginInputSyncAuthorization(master: master, targets: targets)
            case .pageSync:
                InputSyncFallbackPreference.defaultToPageSync = true
                startInputSync(master: master, targets: targets, requestSystemPermissions: false, preferSystemMode: false)
            }
            return
        }

        InputSyncFallbackPreference.defaultToPageSync = false
        startInputSync(master: master, targets: targets, requestSystemPermissions: false)
    }

    private func authorizeFullWindowSync() {
        let status = MacInputSynchronizer.systemPermissionStatus()
        if status.canUseSystemMode {
            InputSyncFallbackPreference.defaultToPageSync = false
            if upgradePageSyncToSystemIfPossible() {
                return
            }
            store.status = "全窗口同步权限已开启。启动窗口后点同步即可。"
            return
        }

        copyAppPathToPasteboard()
        let updatedStatus = MacInputSynchronizer.requestSystemPermissions()
        if updatedStatus.canUseSystemMode {
            InputSyncFallbackPreference.defaultToPageSync = false
            if upgradePageSyncToSystemIfPossible() {
                return
            }
            store.status = "全窗口同步权限已开启。启动窗口后点同步即可。"
            return
        }

        openStandaloneInputSyncPermissionPane(status: updatedStatus)
    }

    private func startInputSync(
        master: ChromeProfile,
        targets: [ChromeProfile],
        requestSystemPermissions: Bool,
        preferSystemMode: Bool = true,
        clearAuthorizationState: Bool = true
    ) {
        let sync = MacInputSynchronizer(master: master, targets: targets) { port in
            controller.pidForDebugPort(port)
        }
        do {
            try sync.start(requestSystemPermissions: requestSystemPermissions, preferSystemMode: preferSystemMode)
            if clearAuthorizationState {
                stopPermissionPolling()
                pendingInputSyncAuthorization = nil
                InputSyncAuthorizationResume.clearPending()
            }
            inputSync = sync
            var suffix = ""
            if sync.limitedByMissingSystemPermissions {
                if !clearAuthorizationState {
                    suffix += "；全窗口权限生效后会自动升级"
                }
                suffix += "；只同步网页内容，地址栏/工具栏不会逐字同步"
                startPageModeUpgradePolling(master: master, targets: targets)
            } else {
                stopPageModeUpgradePolling()
            }
            refreshRuntime(message: "\(sync.modeTitle)已启动\(suffix)。主控: #\(master.id) \(master.name)   从控: \(targets.count) 个")
        } catch {
            inputSync = nil
            AppLogger.error("input sync failed error=\(error.localizedDescription)")
            store.status = error.localizedDescription
        }
    }

    private func beginInputSyncAuthorization(master: ChromeProfile, targets: [ChromeProfile]) {
        copyAppPathToPasteboard()
        InputSyncAuthorizationResume.prepare(masterID: master.id, targetIDs: targets.map(\.id))
        pendingInputSyncAuthorization = PendingInputSyncAuthorization(
            masterID: master.id,
            targetIDs: targets.map(\.id)
        )
        AppLogger.info("input sync authorization started master=\(master.id) targets=\(targets.map(\.id).map(String.init).joined(separator: ","))")
        let updatedStatus = MacInputSynchronizer.requestSystemPermissions()
        if updatedStatus.canUseSystemMode {
            startInputSync(master: master, targets: targets, requestSystemPermissions: false)
            return
        }

        openNextInputSyncPermissionPane(status: updatedStatus)
        startInputSync(master: master, targets: targets, requestSystemPermissions: false, clearAuthorizationState: false)
        startPermissionPolling()
    }

    private func openNextInputSyncPermissionPane(status: InputSyncPermissionStatus) {
        if !status.canListenToInput {
            pendingInputSyncAuthorization?.didOpenInputMonitoring = true
            openInputMonitoringSettings()
            store.status = "已复制 App 路径。请在“输入监控”点“+”添加本 App 并开启；开启后会自动继续。"
        } else if !status.canPostEvents {
            pendingInputSyncAuthorization?.didOpenAccessibility = true
            openAccessibilitySettings()
            store.status = "已复制 App 路径。请在“辅助功能”中添加并开启本 App；开启后会自动启动同步。"
        } else {
            store.status = "权限已开启，请再次点击同步。"
        }
    }

    private func openStandaloneInputSyncPermissionPane(status: InputSyncPermissionStatus) {
        if !status.canListenToInput {
            openInputMonitoringSettings()
            store.status = "已复制 App 路径。请在“输入监控”点“+”添加并开启当前 App。"
        } else if !status.canPostEvents {
            openAccessibilitySettings()
            store.status = "已复制 App 路径。请在“辅助功能”中添加并开启当前 App。"
        } else {
            store.status = "权限已开启，请再次点击同步。"
        }
    }

    private func startPermissionPolling() {
        stopPermissionPolling()
        permissionPollTask = Task { @MainActor in
            for _ in 0..<180 {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                continuePendingInputSyncAuthorizationIfReady()
                if pendingInputSyncAuthorization == nil ||
                    (inputSync != nil && inputSync?.limitedByMissingSystemPermissions == false) {
                    return
                }
            }
            if pendingInputSyncAuthorization != nil {
                InputSyncAuthorizationResume.clearPending()
                store.status = "仍未获得全窗口同步权限。请确认“输入监控”和“辅助功能”里开启的是当前这个 App。"
            }
        }
    }

    private func stopPermissionPolling() {
        permissionPollTask?.cancel()
        permissionPollTask = nil
    }

    private func startPageModeUpgradePolling(master: ChromeProfile, targets: [ChromeProfile]) {
        stopPageModeUpgradePolling()
        pageModeUpgradeTask = Task { @MainActor in
            for _ in 0..<300 {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                guard let sync = inputSync,
                      sync.limitedByMissingSystemPermissions else {
                    return
                }
                guard MacInputSynchronizer.systemPermissionStatus().canUseSystemMode else {
                    continue
                }
                let liveTargets = targets.filter { controller.isRunning($0) }
                guard controller.isRunning(master), !liveTargets.isEmpty else {
                    return
                }
                sync.stop()
                inputSync = nil
                InputSyncFallbackPreference.defaultToPageSync = false
                startInputSync(master: master, targets: liveTargets, requestSystemPermissions: false)
                return
            }
        }
    }

    private func stopPageModeUpgradePolling() {
        pageModeUpgradeTask?.cancel()
        pageModeUpgradeTask = nil
    }

    private func upgradePageSyncToSystemIfPossible() -> Bool {
        guard let sync = inputSync,
              sync.limitedByMissingSystemPermissions,
              let master = currentSyncMaster(),
              controller.isRunning(master) else {
            return false
        }
        let targets = store.profiles.filter { $0.id != master.id && controller.isRunning($0) }
        guard !targets.isEmpty else { return false }
        sync.stop()
        inputSync = nil
        startInputSync(master: master, targets: targets, requestSystemPermissions: false)
        return inputSync?.limitedByMissingSystemPermissions == false
    }

    private func continuePendingInputSyncAuthorizationIfReady() {
        guard var pending = pendingInputSyncAuthorization else { return }
        let status = MacInputSynchronizer.systemPermissionStatus()
        AppLogger.info("input sync authorization check listen=\(status.canListenToInput) post=\(status.canPostEvents)")

        if status.canUseSystemMode {
            guard let master = store.profile(id: pending.masterID),
                  controller.isRunning(master) else {
                stopPermissionPolling()
                pendingInputSyncAuthorization = nil
                InputSyncAuthorizationResume.clearPending()
                store.status = "主控窗口已关闭，无法启动同步。"
                return
            }
            let targets = pending.targetIDs.compactMap { store.profile(id: $0) }.filter { controller.isRunning($0) }
            guard !targets.isEmpty else {
                stopPermissionPolling()
                pendingInputSyncAuthorization = nil
                InputSyncAuthorizationResume.clearPending()
                store.status = "从控窗口已关闭，无法启动同步。"
                return
            }
            inputSync?.stop()
            inputSync = nil
            startInputSync(master: master, targets: targets, requestSystemPermissions: false)
            return
        }

        if !status.canListenToInput {
            if !pending.didOpenInputMonitoring {
                pending.didOpenInputMonitoring = true
                pendingInputSyncAuthorization = pending
                openInputMonitoringSettings()
            }
            store.status = "等待“输入监控”授权：点“+”添加并开启当前 App。"
            return
        }

        if !status.canPostEvents {
            if !pending.didOpenAccessibility {
                pending.didOpenAccessibility = true
                pendingInputSyncAuthorization = pending
                openAccessibilitySettings()
            }
            store.status = "等待“辅助功能”授权：添加并开启当前 App。"
        }
    }

    private func resumeInputSyncAuthorizationIfNeeded() {
        guard inputSync == nil,
              pendingInputSyncAuthorization == nil,
              let pending = InputSyncAuthorizationResume.pendingIDs() else {
            return
        }

        AppLogger.info("input sync authorization resumed master=\(pending.masterID) targets=\(pending.targetIDs.map(String.init).joined(separator: ","))")
        pendingInputSyncAuthorization = PendingInputSyncAuthorization(
            masterID: pending.masterID,
            targetIDs: pending.targetIDs,
            didOpenInputMonitoring: true,
            didOpenAccessibility: false
        )
        continuePendingInputSyncAuthorizationIfReady()
        if inputSync == nil {
            guard let master = store.profile(id: pending.masterID),
                  controller.isRunning(master) else {
                pendingInputSyncAuthorization = nil
                InputSyncAuthorizationResume.clearPending()
                store.status = "上次同步窗口已关闭。请先启动窗口，再点击同步。"
                return
            }
            let targets = pending.targetIDs.compactMap { store.profile(id: $0) }.filter { controller.isRunning($0) }
            guard !targets.isEmpty else {
                pendingInputSyncAuthorization = nil
                InputSyncAuthorizationResume.clearPending()
                store.status = "上次同步从控窗口已关闭。请先启动窗口，再点击同步。"
                return
            }
            startInputSync(master: master, targets: targets, requestSystemPermissions: false, clearAuthorizationState: false)
        }
        if inputSync == nil, pendingInputSyncAuthorization != nil {
            startPermissionPolling()
        }
    }

    private func showInputSyncPermissionGuide(status: InputSyncPermissionStatus) -> SyncPermissionChoice {
        let appPath = Bundle.main.bundlePath
        let alert = NSAlert()
        alert.messageText = "全窗口同步需要一次系统授权"
        alert.informativeText = """
        当前缺少：\(status.missingItemsText)。

        点“开始授权”后会自动复制 App 路径并打开正确的系统设置页。如果列表里没有“Chrome 多开管理器”，点左下角“+”，粘贴或选择：
        \(appPath)

        开启后回到本软件，状态显示“全窗口同步已启动”才是完整鼠标/键盘同步。

        没拿到权限时会先启动“网页同步”，它只同步网页内容；地址栏输入、浏览器工具栏和 about:blank 需要状态显示为“全窗口同步”才会实时同步。

        选择“仅网页同步”后，下次会直接使用网页同步，不再重复弹出此提示。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "开始授权")
        alert.addButton(withTitle: "仅网页同步")

        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? .startAuthorization : .pageSync
    }

    private func copyAppPathToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(Bundle.main.bundlePath, forType: .string)
    }

    private func stopInputSync(message: String) {
        inputSync?.stop()
        inputSync = nil
        stopPermissionPolling()
        stopPageModeUpgradePolling()
        pendingInputSyncAuthorization = nil
        InputSyncAuthorizationResume.clearPending()
        if !message.isEmpty {
            refreshRuntime(message: message)
        }
    }

    private func stopSyncIfNeeded(including ids: [Int]) {
        guard inputSync != nil else { return }
        if let syncMasterID, ids.contains(syncMasterID) {
            stopInputSync(message: "同步已停止：主控窗口被关闭。")
            return
        }
        let runningAfterClose = store.profiles.filter { profile in
            !ids.contains(profile.id) && profile.id != syncMasterID && controller.isRunning(profile)
        }
        if runningAfterClose.isEmpty {
            stopInputSync(message: "同步已停止：没有从控窗口。")
        }
    }

    private func arrangeWindows() {
        AppLogger.info("arrange clicked")
        do {
            let master = arrangementMaster()
            let count = try controller.arrangeWindows(profiles: store.profiles, masterProfile: master)
            let message: String
            if count == 0 {
                message = "没有运行中的窗口。"
            } else if let master {
                message = "已按主控 #\(master.id) 的窗口大小排列 \(count) 个 Chrome 窗口。"
            } else {
                message = "已按屏幕大小排列 \(count) 个 Chrome 窗口。"
            }
            refreshRuntime(message: message)
        } catch {
            AppLogger.error("arrange failed error=\(error.localizedDescription)")
            if let controllerError = error as? ChromeControllerError,
               case .accessibilityDenied = controllerError {
                openAccessibilitySettings()
            }
            store.status = "\(error.localizedDescription)\n请给本 App 开启辅助功能权限。"
        }
    }

    private func arrangementMaster() -> ChromeProfile? {
        if let syncMasterID,
           let profile = store.profile(id: syncMasterID),
           controller.isRunning(profile) {
            return profile
        }
        if selection.count == 1,
           let id = selection.first,
           let profile = store.profile(id: id),
           controller.isRunning(profile) {
            return profile
        }
        return nil
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func importProxies() {
        let panel = NSOpenPanel()
        panel.title = "选择代理文件"
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try controller.importProxyProfiles(from: url, startID: store.nextID())
            for profile in imported {
                store.add(profile)
            }
            refreshRuntime(message: "已导入 \(imported.count) 个代理配置。")
        } catch {
            store.status = "导入失败: \(error.localizedDescription)"
        }
    }

    private func groupTargets() -> [ChromeProfile] {
        onlySelected ? selectedProfiles : store.profiles
    }

    private func groupNavigate() {
        let count = controller.groupNavigate(profiles: groupTargets(), url: groupURL)
        refreshRuntime(message: "群控跳转: 已向 \(count) 个窗口发送。")
    }

    private func groupEvaluate() {
        let count = controller.groupEvaluate(profiles: groupTargets(), script: groupScript)
        refreshRuntime(message: "群控执行: 已向 \(count) 个窗口执行脚本。")
    }

    private func refreshBadges() {
        controller.refreshBadges(profiles: store.profiles)
        refreshRuntime(message: "已刷新运行中窗口徽标。")
    }

    private func beginOperation(_ status: String, allowWhileBusy: Bool = false) -> UUID? {
        if isBusy && !allowWhileBusy {
            store.status = "已有任务正在执行；如果 Chrome 已打开，可点“全部关闭”恢复。"
            AppLogger.info("operation ignored while busy status=\(status)")
            return nil
        }
        if isBusy && allowWhileBusy {
            AppLogger.info("operation overriding busy status=\(status)")
        }
        let token = UUID()
        operationID = token
        isBusy = true
        store.status = status
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 18_000_000_000)
            guard operationID == token, isBusy else { return }
            AppLogger.error("operation timed out and UI lock was released status=\(status)")
            operationID = nil
            isBusy = false
            refreshRuntime(message: "任务仍在后台收尾，已解除界面锁。")
        }
        return token
    }

    private func finishOperation(_ token: UUID, message: String) {
        guard operationID == token else {
            AppLogger.info("operation finished after a newer command took over message=\(message)")
            return
        }
        operationID = nil
        isBusy = false
        refreshRuntime(message: message)
    }

    private func refreshRuntime(message: String? = nil) {
        let profiles = store.profiles
        let controller = controller
        let store = store
        Task.detached(priority: .utility) {
            let runningIDs = controller.runningIDs(for: profiles)
            let restoredProxyCount = controller.ensureLocalProxies(for: profiles.filter { runningIDs.contains($0.id) })
            let total = profiles.count
            let running = runningIDs.count
            let proxySummary = restoredProxyCount > 0 ? "   代理: \(restoredProxyCount)" : ""
            let summary = "配置: \(total)   运行中: \(running)   已停止: \(total - running)\(proxySummary)   存档: \(AppPaths.profileDirectory.path)"
            await MainActor.run {
                runtime.runningIDs = runningIDs
                store.status = message.map { "\($0)   \(summary)" } ?? summary
            }
        }
    }
}
