import NetworkExtension
import SwiftUI
import UIKit

struct NetworkDetail: View {
    @EnvironmentObject private var model: NetworkModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    let network: VirtualNetwork
    let connect: () -> Void
    let invite: () -> Void
    @State private var copied: String?
    @State private var destructive: (() -> Void)?
    @State private var confirmation = ""
    @State private var confirm = false

    private var owner: Bool { model.deviceID == network.ownerDeviceId }
    private var attached: Bool { model.active == network.id }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                connectionCard
                ViewThatFits(in: .horizontal) {
                    if sizeClass == .regular {
                        HStack(alignment: .top, spacing: 20) {
                            membersCard.frame(minWidth: 290)
                            helpCard.frame(minWidth: 220)
                        }
                    }
                    VStack(alignment: .leading, spacing: 20) { membersCard; helpCard }
                }
            }
            .frame(maxWidth: 850)
            .padding(sizeClass == .regular ? 24 : 16)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(network.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if owner {
                        Button("解散网络", role: .destructive) {
                            ask("解散后，所有成员都会断开。") { Task { await model.disband(network.id) } }
                        }
                    } else {
                        Button("退出网络", role: .destructive) {
                            ask("退出后需要新的邀请才能重新加入。") {
                                Task { await model.memberAction(network.id, member: model.deviceID) }
                            }
                        }
                    }
                } label: { Label("网络管理", systemImage: "ellipsis.circle") }
                .disabled(model.busy)
            }
        }
        .confirmationDialog(confirmation, isPresented: $confirm, titleVisibility: .visible) {
            Button("确认", role: .destructive) { destructive?(); destructive = nil }
            Button("取消", role: .cancel) { destructive = nil }
        }
    }

    private var connectionCard: some View {
        card {
            Label(statusTitle, systemImage: attached && model.latency != nil ? "checkmark.circle.fill" : "network")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let mine = network.members.first(where: { $0.id == model.deviceID }) {
                Label("我的虚拟 IP", systemImage: "iphone").font(.subheadline).foregroundStyle(.secondary)
                copyAddress(mine.address)
            }
            if model.busy { ProgressView() }
            ViewThatFits(in: .horizontal) {
                HStack { actions }
                VStack(alignment: .leading) { actions }
            }
            .disabled(model.busy)
        }
    }

    @ViewBuilder private var actions: some View {
        if attached {
            Button("断开连接", systemImage: "pause.circle") { Task { await model.disconnect() } }
                .buttonStyle(.bordered)
        } else {
            Button("连接网络", systemImage: "link", action: connect)
                .buttonStyle(.borderedProminent)
        }
        if owner {
            if attached {
                Button("邀请朋友", systemImage: "person.badge.plus", action: invite).buttonStyle(.borderedProminent)
            } else {
                Button("邀请朋友", systemImage: "person.badge.plus", action: invite).buttonStyle(.bordered)
            }
        }
    }

    private var membersCard: some View {
        card {
            Text("成员 \(network.members.count) / 8").font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(network.members) { member in
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.name).font(.subheadline.weight(.semibold))
                            Text(member.online ? "连接许可有效" : "未连接")
                                .font(.caption).foregroundStyle(.secondary)
                            if member.id == network.ownerDeviceId {
                                Text("管理员").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        if owner && member.id != model.deviceID {
                            Menu {
                                Button("转让管理权") {
                                    ask("将管理权交给\(member.name)？") {
                                        Task { await model.memberAction(network.id, member: member.id, transfer: true) }
                                    }
                                }
                                Button("移除成员", role: .destructive) {
                                    ask("移除\(member.name)？") {
                                        Task { await model.memberAction(network.id, member: member.id) }
                                    }
                                }
                            } label: {
                                Label("管理\(member.name)", systemImage: "ellipsis").labelStyle(.iconOnly)
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .disabled(model.busy)
                        }
                    }
                    copyAddress(member.address)
                }
            }
        }
    }

    private var helpCard: some View {
        card {
            Text("在游戏中加入").font(.headline).accessibilityAddTraits(.isHeader)
            Text("让朋友先连接同一个网络，然后在游戏的联机界面填写游戏主机的虚拟 IP。").font(.subheadline)
            if attached {
                Divider()
                Text("连接诊断").font(.headline).accessibilityAddTraits(.isHeader)
                Text("路径为网关转发").font(.subheadline)
                if let latency = model.latency {
                    Text("到网关 \(latency, format: .number.precision(.fractionLength(0))) ms")
                } else {
                    Text("暂无网关延迟测量").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var statusTitle: String {
        guard attached else { return "未连接" }
        switch model.status {
        case .connected: return model.latency == nil ? "VPN 已启动，等待节点响应" : "网络可用"
        case .connecting: return "正在连接"
        case .reasserting: return "正在恢复连接"
        case .disconnecting: return "正在断开"
        default: return "未连接"
        }
    }

    private func copyAddress(_ address: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack { addressText(address); copyButton(address) }
            VStack(alignment: .leading) { addressText(address); copyButton(address) }
        }
    }

    private func addressText(_ address: String) -> some View {
        Text(address).font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
    }

    private func copyButton(_ address: String) -> some View {
        Button {
            UIPasteboard.general.string = address
            copied = address
        } label: {
            Label(copied == address ? "已复制" : "复制", systemImage: copied == address ? "checkmark" : "doc.on.doc")
                .font(.subheadline).frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("复制虚拟 IP \(address)")
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
    }

    private func ask(_ title: String, action: @escaping () -> Void) {
        confirmation = title
        destructive = action
        confirm = true
    }
}
