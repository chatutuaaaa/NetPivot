import NetworkExtension
import SwiftUI
import UIKit

@main
struct NetPivotApp: App {
    @StateObject private var model = NetworkModel()

    var body: some Scene {
        WindowGroup { NetworksView().environmentObject(model).tint(Color(red: 0.04, green: 0.49, blue: 0.44)) }
    }
}

private struct NetworksView: View {
    @EnvironmentObject private var model: NetworkModel
    @Environment(\.scenePhase) private var phase
    @AppStorage("vpnDisclosureAccepted") private var disclosureAccepted = false
    @State private var actionAfterDisclosure: (() -> Void)?
    @State private var afterDismiss: (() -> Void)?
    @State private var compactColumn = NavigationSplitViewColumn.sidebar
    @State private var sheet: Sheet?
    @State private var code = ""
    @State private var pendingLink: String?
    @State private var name = ""
    private var sceneCanRefresh: Bool { phase == .active && disclosureAccepted }

    private enum Sheet: String, Identifiable {
        case join, scan, invite, settings, disclosure
        var id: String { rawValue }
    }

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            List(selection: $model.selected) {
                Section {
                    Button("创建网络", systemImage: "plus.circle.fill") {
                        requireDisclosure { Task { await model.create() } }
                    }
                    Button("加入网络", systemImage: "person.badge.plus") { requireDisclosure { sheet = .join } }
                }
                .disabled(model.busy)
                if !model.networks.isEmpty {
                    Section("我的网络") {
                        ForEach(model.networks) { network in
                            NavigationLink(value: network.id) {
                                Label(network.name, systemImage: model.active == network.id ? "point.3.connected.trianglepath.dotted" : "network")
                            }
                        }
                    }
                }
            }
            .navigationTitle("NetPivot")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("设置", systemImage: "gearshape") {
                        name = Vault.preferences.string(forKey: "deviceName") ?? ""
                        sheet = .settings
                    }
                }
            }
            .refreshable { await model.refresh() }
        } detail: {
            if let network = model.networks.first(where: { $0.id == model.selected }) {
                NetworkDetail(network: network, connect: {
                    requireDisclosure { Task { await model.connect(network.id) } }
                }, invite: {
                    model.invitation = nil
                    sheet = .invite
                    Task { await model.invite(network.id) }
                })
            } else {
                ContentUnavailableView("开始组网", systemImage: "network",
                                       description: Text("创建网络，或通过朋友的邀请加入。"))
            }
        }
        .onChange(of: model.selected) { _, id in
            compactColumn = id == nil ? .sidebar : .detail
        }
        .task(id: sceneCanRefresh) {
            guard sceneCanRefresh else { return }
            if Vault.preferences.string(forKey: "deviceName") == nil {
                Vault.preferences.set(UIDevice.current.userInterfaceIdiom == .pad ? "我的 iPad" : "我的 iPhone", forKey: "deviceName")
            }
            while !Task.isCancelled {
                await model.refresh()
                do { try await Task.sleep(for: .seconds(8)) }
                catch { return }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NEVPNStatusDidChange)) { _ in model.readStatus() }
        .onOpenURL { openInvitation($0) }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) {
            if let url = $0.webpageURL { openInvitation(url) }
        }
        .sheet(item: $sheet, onDismiss: {
            if let action = afterDismiss { afterDismiss = nil; action() }
            else if let link = pendingLink { pendingLink = nil; submit(link) }
        }) { item in
            NavigationStack {
                switch item {
                case .join: joinSheet
                case .scan: scanSheet
                case .invite: inviteSheet
                case .settings: settingsSheet
                case .disclosure: disclosureSheet
                }
            }
            .presentationDetents(item == .scan ? [.large] : [.medium, .large])
        }
        .alert("NetPivot", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private func requireDisclosure(_ action: @escaping () -> Void) {
        if disclosureAccepted { action(); return }
        actionAfterDisclosure = action
        sheet = .disclosure
    }

    private func openInvitation(_ url: URL) {
        if !disclosureAccepted {
            requireDisclosure { submit(url.absoluteString) }
            return
        }
        if sheet != nil && sheet != .join {
            pendingLink = url.absoluteString
            sheet = nil
        } else {
            submit(url.absoluteString)
        }
    }

    private func submit(_ value: String) {
        code = value
        model.preview = nil
        sheet = .join
        Task { await model.resolve(value) }
    }

    private var joinSheet: some View {
        Form {
            if let preview = model.preview {
                Section {
                    LabeledContent("网络", value: preview.name)
                    LabeledContent("邀请人", value: preview.inviter)
                    LabeledContent("成员", value: "\(preview.count) / 8")
                    Button("加入并连接") {
                        sheet = nil
                        Task { await model.redeem() }
                    }
                    .disabled(model.busy || preview.count >= 8)
                    if preview.count >= 8 { Text("网络已满").foregroundStyle(.secondary) }
                } footer: {
                    Text("加入后，同一虚拟网络中的其他成员可以访问你的虚拟 IP。")
                }
            } else {
                Section {
                    TextField("8 位邀请码", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await model.resolve(code) } }
                    PasteButton(payloadType: String.self) { if let first = $0.first { submit(first) } }
                    Button("继续", systemImage: "arrow.right") { Task { await model.resolve(code) } }
                        .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
                    Button("扫描邀请二维码", systemImage: "qrcode.viewfinder") {
                        sheet = .scan
                    }
                }
            }
            if model.busy { ProgressView() }
            if let error = model.error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("加入网络")
        .toolbar { ToolbarItem(placement: .cancellationAction) {
            Button("关闭") { sheet = nil; code = ""; model.preview = nil }
        } }
    }

    private var scanSheet: some View {
        QRScanner { value in
            pendingLink = value
            sheet = nil
        }
        .navigationTitle("扫描邀请")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回") { sheet = .join } } }
    }

    private var inviteSheet: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let invitation = model.invitation {
                    InvitationQR(url: invitation.url)
                    Text(invitation.code).font(.system(.title, design: .monospaced)).textSelection(.enabled)
                    LabeledContent("有效至") { Text(invitation.expiresAt, style: .time) }
                    ShareLink(item: invitation.url) { Label("分享邀请链接", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.borderedProminent)
                    if let id = model.selected {
                        Button("刷新邀请码") { Task { await model.invite(id, rotate: true) } }
                        Button("关闭当前邀请", role: .destructive) { Task { await model.revoke(id); sheet = nil } }
                    }
                    Text("收到邀请的人可以加入，请只分享给信任的人。").font(.footnote).foregroundStyle(.secondary)
                } else if model.busy {
                    ProgressView("正在准备邀请")
                } else {
                    if let error = model.error { Text(error).foregroundStyle(.red) }
                    if let id = model.selected {
                        Button("获取邀请") { Task { await model.invite(id) } }
                    }
                }
            }
            .frame(maxWidth: 420)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("邀请朋友")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { sheet = nil } } }
    }

    private var settingsSheet: some View {
        Form {
            Section("设备") {
                TextField("设备名称", text: $name)
                Button("保存名称") {
                    if disclosureAccepted { Task { await model.saveName(name) } }
                    else { Vault.preferences.set(name, forKey: "deviceName") }
                }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.unicodeScalars.count > 40)
            }
            Section("游戏") {
                Link("星露谷物语移动端联机指南", destination: URL(string: "https://www.stardewvalley.net/mobile-multiplayer-guide/")!)
            }
            Section("隐私") { Text(disclosureText) }
        }
        .navigationTitle("设置")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { sheet = nil } } }
    }

    private let disclosureText = "NetPivot 保存设备标识、网络成员、虚拟 IP 和连接许可，用于组网及管理访问权限。组网流量在设备与网关之间加密传输，网关解密后转发，服务不记录游戏数据包内容。日常上网仍走原网络。"

    private var disclosureSheet: some View {
        Form {
            Section("使用 VPN 组网") {
                Text(disclosureText)
                Text("系统会询问是否允许添加 VPN 配置。允许后，可以在 NetPivot 或系统设置中断开连接。")
                Button("继续") {
                    disclosureAccepted = true
                    let action = actionAfterDisclosure
                    actionAfterDisclosure = nil
                    afterDismiss = action
                    sheet = nil
                }
            }
        }
        .navigationTitle("连接前说明")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { sheet = nil; actionAfterDisclosure = nil } } }
    }
}
