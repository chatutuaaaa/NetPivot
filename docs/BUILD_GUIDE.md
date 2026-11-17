# NetPivot 分阶段搭建指南

配套版本：设计文档 0.1 · 2026-11-17。

## 0. 怎样使用本指南

本文保留设计阶段的实施顺序和独立 WireGuard 实验。仓库现有代码、真实配置和命令以 [部署、编译和验收](RUN.md) 为准。第 3 至 10 节同时包含长期目标，实际交付情况记录在运行指南。

步骤 2 的 WireGuard 试验可以先独立执行，以验证核心场景。后续再逐步替换为自有 App 和控制服务。没有经过真机测试的方案，不能保证对任意游戏版本、运营商和设备都有效。

建议建立 `docs/IMPLEMENTATION_LOG.md`，记录每个关卡的日期、设备、版本、结果与故障证据。未通过关卡不要打勾。

## 1. 准备环境和资源

### 1.1 必备条件

| 资源 | 用途 | 通过条件 |
| --- | --- | --- |
| Windows 工作机 | 文档、后端、远程服务器管理 | Git、编辑器、SSH 可用 |
| Mac | 编译、签名、运行 iOS 扩展 | Xcode 支持实际连接设备的系统版本 |
| Apple 开发团队与签名配置 | App / 扩展身份与能力 | 可为 Packet Tunnel 配置签名和描述文件 |
| iPhone 和 iPad 真机 | 游戏与后台验证 | 最早至少 2 台，发布前准备 3、4、8 台组网测试 |
| 不同网络 | 异地行为验证 | 至少两条独立宽带或宽带 + 蜂窝 |
| Ubuntu 24.04 LTS 测试服务器 | 网关与控制服务 | 公网地址，可开放 UDP 51820 和 HTTPS |
| 自有域名 | API、邀请链接、网关域名 | HTTPS 证书和 DNS 可控制 |
| 游戏测试副本 | 真实业务验证 | 普通移动版，双方版本和多人入口已核对 |

优先使用空白测试服务器。不要直接在承载现有 VPN、路由或业务的机器上套用防火墙示例。

Mac 的系统与 Xcode 组合应依据 Apple 当前兼容表选择稳定版本，并记录完整版本号；不把“最低支持 iOS 17”误认为旧 Xcode 一定能调试新系统设备。[Apple Xcode 兼容表](https://developer.apple.com/xcode/system-requirements)

### 1.2 固定版本，避免“昨天能编译今天不能”

创建版本记录，至少填写：macOS、Xcode 完整 build、Swift、Go、Ubuntu、PostgreSQL、WireGuardKit 提交哈希、wireguard-go 提交哈希、两端系统和游戏版本。

应用依赖提交 `Package.resolved`、`go.mod`、`go.sum`；容器记录镜像 digest；禁止只写 `latest`。本文不伪造未经验证的依赖组合，实际锁定组合以 M0 编译通过的记录为准。

### 1.3 未来代码目录

以下是设计阶段的目标目录。当前代码目录见 [运行指南](RUN.md)：

```text
NetPivot/
  README.md
  docs/
  assets/brand/
  apple/
    NetPivot.xcodeproj
    NetPivotApp/               页面、邀请链接、用户操作
    PacketTunnel/              扩展、配置应用、续租、状态
    Shared/                    DTO、配置校验、共享存储协议
  server/
    cmd/api/                   HTTPS 控制 API
    cmd/gateway-agent/         受限网关管理
    internal/auth/
    internal/networks/
    internal/invitations/
    internal/leases/
    internal/gateways/
    migrations/
  deploy/
    compose.yaml               API + 数据库，网关宿主机运行
    systemd/
    nftables/
  tests/
    integration/
    network-scenarios/
```

**本步骤通过条件**：设备和服务器齐备；Mac 可运行一个签名测试 App；开发团队能够配置所需能力。缺少 Mac 可以继续后端工作，但不能将 iOS 构建验证标记完成。

## 2. 先用手工配置证明多设备互联可行

本阶段不开发 UI，不做自动邀请，先消除游戏和隧道兼容性风险。前两台证明基本路径，再加入第三台证明多设备能力。

### 2.1 安装测试网关组件

以下命令在 **Ubuntu 服务器终端** 执行，不在 Windows PowerShell 执行。

```bash
sudo apt update
sudo apt install -y wireguard nftables tcpdump
sudo install -d -m 700 /etc/wireguard
sudo install -d -m 700 /etc/netpivot
```

使用下面的脚本在服务器本地生成私钥。私钥不粘贴到聊天、不上传 Git、不写入普通日志。

```bash
sudo bash <<'SH'
set -eu
umask 077
if [ -e /etc/wireguard/server.key ]; then
  echo 'server.key already exists; keeping existing key'
else
  wg genkey > /etc/wireguard/server.key
fi
wg pubkey < /etc/wireguard/server.key > /etc/wireguard/server.pub
SH
sudo cat /etc/wireguard/server.pub
```

最后一条只显示公钥，可用于配置客户端。

### 2.2 在设备上准备测试客户端

在每台测试 iPhone / iPad 上安装官方 WireGuard 客户端，创建空隧道，使用客户端生成的设备密钥。记录每台设备的**公钥**。临时测试无需分发或集中保存客户端私钥。[WireGuard 官方安装入口](https://www.wireguard.com/install/)

建议分配：

| 设备 | 虚拟地址 | 用途 |
| --- | --- | --- |
| A：iPhone | 10.203.1.10/32 | 第一台测试设备 |
| B：iPad | 10.203.1.11/32 | 第二台测试设备 |
| C：第三台设备 | 10.203.1.12/32 | 多设备验证 |
| 后续设备 | .13 到 .17 | 扩展至 8 台 |

这些地址仅用于当前隔离实验，不要在真实局域网已经使用相同地址段时照抄。

### 2.3 写网关配置

编辑 `/etc/wireguard/wg0.conf`，替换全部占位符。服务器私钥从本机文件复制到该配置，不展示给其他人。文件权限设为 600。

```ini
[Interface]
Address = 10.203.0.1/16
ListenPort = 51820
PrivateKey = REPLACE_WITH_SERVER_PRIVATE_KEY
MTU = 1280

[Peer]
# Device A
PublicKey = REPLACE_WITH_DEVICE_A_PUBLIC_KEY
AllowedIPs = 10.203.1.10/32

[Peer]
# Device B
PublicKey = REPLACE_WITH_DEVICE_B_PUBLIC_KEY
AllowedIPs = 10.203.1.11/32

[Peer]
# Device C
PublicKey = REPLACE_WITH_DEVICE_C_PUBLIC_KEY
AllowedIPs = 10.203.1.12/32
```

```bash
sudo chmod 600 /etc/wireguard/wg0.conf
sudo sysctl -w net.ipv4.ip_forward=1
```

当前只临时开启转发。正式部署时才将该项写入独立的 `/etc/sysctl.d/70-netpivot.conf`，并验证重启行为。

### 2.4 在启动隧道前限制转发范围

将下列内容保存为 `/etc/netpivot/lab-firewall.nft`。示例只许可三个指定成员之间的流量；没有端口映射、互联网出口或跨网络通行能力。

```nft
table inet netpivot_lab {
  set members {
    type ipv4_addr
    elements = { 10.203.1.10, 10.203.1.11, 10.203.1.12 }
  }

  chain forward {
    type filter hook forward priority 0; policy accept;
    iifname "wg0" oifname "wg0" ip saddr @members ip daddr @members accept
    iifname "wg0" drop
    oifname "wg0" drop
  }

  chain input {
    type filter hook input priority 0; policy accept;
    iifname "wg0" ip daddr 10.203.0.1 icmp type echo-request accept
    iifname "wg0" drop
  }
}
```

```bash
sudo nft -c -f /etc/netpivot/lab-firewall.nft
sudo nft -f /etc/netpivot/lab-firewall.nft
sudo nft list table inet netpivot_lab
```

仅初次加载执行第二条；表已存在时先审阅现状，不重复粘贴叠加规则。该示例只管理自己的表，**不要使用 `nft flush ruleset` 清空整台服务器规则**。其他防火墙链仍可能拒绝流量，需要结合现有策略检查。

这不是完整主机防火墙：服务器安全组仍须限制 SSH 来源，数据库不对公网开放，仅暴露业务需要的端口。

正式系统不能把不同网络的所有地址放进同一个 members 集合；必须为每个网络生成独立许可，或生成带网络关系的源/目的地址对集合。动态更新使用事务，防止刷新期间短暂全放行。

### 2.5 开放公网端口并启动

云安全组和主机防火墙允许客户端到服务器的 **UDP 51820**。公网管理端口仅允许可信管理来源。

```bash
sudo wg-quick up wg0
sudo wg show wg0
ip route get 10.203.1.10
```

本实验暂不设置开机启动。服务器重启后应先重新加载限制规则，再启动 wg0。生产部署中必须用服务依赖保证这一顺序，配置失败则不启动网关。

### 2.6 写设备配置

设备 A 的配置如下，B / C 分别改 Address 和自己的 PrivateKey。`vpn.example.com` 必须换成实际已解析的网关域名。

```ini
[Interface]
PrivateKey = DEVICE_A_PRIVATE_KEY_GENERATED_ON_DEVICE
Address = 10.203.1.10/32
MTU = 1280

[Peer]
PublicKey = REPLACE_WITH_SERVER_PUBLIC_KEY
Endpoint = vpn.example.com:51820
AllowedIPs = 10.203.1.0/24, 10.203.0.1/32
PersistentKeepalive = 25
```

不设置 DNS，不添加默认路由，不把多个设备配置成同一个私钥或地址。连接时允许系统添加 VPN 配置。

### 2.7 按三层顺序检查

1. **外层握手**：设备连接后 `sudo wg show wg0` 能看到近期握手和计数增长。
2. **内层数据**：使用测试工具或后续诊断程序，让 A 向 B 的虚拟 IP 发送 UDP，观察服务器的虚拟接口。
3. **真实游戏**：在游戏内启动主机，另一台输入该主机的虚拟 IP 尝试加入。

只观察包头的命令：

```bash
sudo tcpdump -ni wg0 'host 10.203.1.10 or host 10.203.1.11'
```

不要默认使用 `-A`、`-X` 或保存完整流量。正式用户诊断不应自动收集业务内容。

握手存在不代表游戏监听正常；设备也不一定响应 ICMP，因此 ping 不通不能单独作为游戏失败结论。服务器收到请求但没有回包时，继续检查接收端游戏、路由与权限。

### 2.8 星露谷与多人验证

按官方指南开启实验性多人入口、准备可加入的农场，测试使用新存档。当前官方指南标注游戏使用 UDP 24642；测试记录仍以实际版本和抓到的包头为准。[官方指南](https://www.stardewvalley.net/mobile-multiplayer-guide/)

依次验证：

1. A、B 使用不同外网，A 建房，B 填 `10.203.1.10` 加入。
2. B 建房，A 填 `10.203.1.11` 加入，排除仅单向可用。
3. C 加入虚拟网络，验证 A↔C、B↔C；游戏允许时共同进入同一农场。
4. A 为网络管理员但 B 为游戏主机，确认角色互不绑定。
5. 关闭 NetPivot/WireGuard 的主界面并切到游戏，持续游玩至少 30 分钟。

**通过条件**：两端主机角色均可用；三设备网络逐对可达；游戏能持续通信。**若不通过，停止后续产品化开发，先用第 11 节排查。**

## 3. 实现控制服务

### 3.1 初始化服务骨架

在计划的 `server` 目录初始化 Go module；模块路径根据最终仓库确定。创建 HTTP 服务、配置加载、数据库连接、结构化日志和优雅退出。

必须先实现：

- `GET /healthz`：进程存活，200。
- `GET /readyz`：数据库和必要网关能力可用，200；不可用时 503。
- 请求大小限制、超时、请求 ID、受信代理配置、错误格式。
- 数据库迁移命令，不能在每个 API 请求里动态建表。

使用独立数据库用户，API 不使用数据库超级管理员。配置中的密码和签名密钥由部署环境注入，不提交仓库。

**交付物**：可启动的 API、首个迁移、配置样例。**通过条件**：停数据库时 readyz 变 503，healthz 仍能正确反映进程状态；日志不含密码。

### 3.2 按顺序实现数据与身份

1. 实现 devices、networks、memberships、invitations、sessions、gateways、audit_events 表。
2. 增加外键、唯一约束与状态检查；IP 分配由服务端完成，不接受客户端指定任意地址。
3. 实现设备挑战签名：随机 nonce、单次使用、60 秒有效期、绑定 device ID 与用途，使用成熟密码库验证。
4. 注册时提交身份公钥并验证持有证明；访问令牌短期有效，客户端以设备密钥重新换取。
5. WireGuard 密钥每个网络成员关系独立生成，减少跨网络关联及配置冲突；身份密钥不直接充当 WireGuard 密钥。

免注册不等于无身份或无限创建：需要设备、来源和总体容量限制。设备密钥丢失不自动恢复匿名网络管理权；首版明确这一行为。

### 3.3 实现创建与兑换事务

创建网络事务：分配唯一网络 ID → 锁定可用地址段 → 建立 owner 成员 → 分配地址 → 创建邀请 → 写入待配置任务 → 提交。

邀请兑换事务：校验设备身份 → 锁定邀请和网络行 → 检查有效期、次数、容量 → 已是成员则返回原成员关系 → 新增成员与地址 → 更新次数 → 写待配置任务 → 提交。

API 使用 `Idempotency-Key`；同设备、同接口、同 key 重试必须返回相同业务结果。相同 key 不同请求体返回冲突。过期或无效邀请不得暴露网络成员详情。

初始限流值可使用：每设备每分钟 10 次邀请码尝试、每来源每分钟 30 次，超出返回 429 与 Retry-After。共享出口可能误伤，内测根据记录调整；不能仅依赖单一 IP 限制。

**通过条件**：并发请求最后一个名额时只有一个新增成员成功；重复请求不产生重复网络、重复地址或重复扣减邀请次数。

### 3.4 网关代理与一致性

实现一个最小权限管理进程：只接收“将网络 revision N 配置成指定有效成员集合”这一类结构化操作。不得接受任意命令字符串。

代理流程：

1. 校验来源身份、目标网关、地址池、公钥格式、版本及成员租约。
2. 为新增成员先装载 Peer，再更新许可；准备完成前不发布 ready。
3. 删除成员时先撤销许可，再清理 Peer；任何步骤失败保持拒绝访问。
4. 将期望配置与内核状态比对，更新必要差异；不要每次成员变化都重启 wg0。
5. 应用成功后回报 revision；失败记录可重试错误，由后台任务协调。
6. 独立清理到期成员；进程重启后以持久化租约和服务端状态重建，过期成员默认不放行。

撤销还需考虑已建立连接：防火墙中成员许可检查不能被更早的全局 `established,related accept` 绕过；必要时移除对应连接跟踪状态。

**通过条件**：服务中途崩溃或代理不可达时，API 不虚报已生效；恢复后配置一致；移除成员后旧 UDP 流不能继续通行。

### 3.5 接口完成顺序

按 [设计中的 API 契约](DESIGN.md#72-接口清单) 实现：身份 → 创建 → 配置 → 邀请解析与兑换 → 最近网络 → 续租 → 移除与解散 → 事件通知。

先用测试客户端调用接口，拿返回值手工配置 WireGuard。证明“后台动态加人”可用后再接 App，避免前后端问题混在一起。

## 4. 创建 iPhone / iPad 工程

### 4.1 Xcode Targets

1. 新建 SwiftUI iOS App，支持 iPhone 和 iPad，最低系统暂设 17。
2. 添加 Packet Tunnel Provider 扩展 Target。
3. 为 App、扩展使用独立 Bundle ID，例如 `com.yourteam.netpivot` 与 `com.yourteam.netpivot.tunnel`。
4. 配置同一开发团队；检查实际签名文件包含正确 Network Extensions 能力。
5. 配置 App Groups 与 Keychain Sharing，App 与扩展标识必须一致；使用真实团队 ID，不照抄示例。
6. 预留邀请域名的 Associated Domains；域名未准备好时先完成短码流程。

**通过条件**：两个 Target 都能签名；扩展能够被真机系统发现；重新安装后行为可解释，不依赖旧描述文件偶然成功。

### 4.2 接入 WireGuardKit

按固定提交的官方 README 添加 Swift Package、Go bridge 构建目标和扩展链接依赖。第三方工具链路径不要硬编码为某位开发者的用户目录。[WireGuardKit 集成说明](https://git.zx2c4.com/wireguard-apple/about/)

先使用步骤 2 的静态配置跑通，再接动态控制服务。记录确切依赖版本与构建命令；许可证及第三方声明随项目保留。

**通过条件**：干净构建成功；清理构建缓存后仍成功；真机隧道有真实握手与流量。模拟器只用于界面和部分逻辑，不能替代此项。

### 4.3 扩展实现职责

实现并测试以下生命周期：

- `startTunnel`：读取本地私钥引用和服务器配置 → 校验 → 设置虚拟地址/路由/MTU → 启动适配器 → 成功或明确失败回调。
- `stopTunnel`：取消续租与重试任务 → 停止适配器 → 释放资源 → 完成停止回调。
- Provider 消息处理：返回最小状态快照、执行明确的刷新请求，不通过消息暴露私钥。
- 网络变化处理：重建必要外层连接，保留内层地址；用 generation ID 丢弃旧异步回调。
- 续租与配置更新：在扩展中运行，App 不在前台也能处理；控制面失联时按租约到期停止。

所有 start/stop 完成回调必须且只能调用一次。用户断开后禁止旧重试任务重新连接。不要在扩展内实现供其他 App 访问的本地监听代理。

Keychain 可访问性需要覆盖首次解锁后的后台运行，并采用设备本地保护；开机尚未首次解锁时给出明确恢复行为。用真机验证，不假定扩展拥有主 App 的完整生命周期或资源预算。

### 4.4 主 App 管理隧道

通过 NETunnelProviderManager 加载已有配置，首次创建使用 NETunnelProviderProtocol 并设置实际扩展 Bundle ID。保存后按 API 生命周期重新加载，再发起启动；观察系统状态变化并结合扩展健康状态更新 UI。

避免每次点连接都创建新配置。首版只允许当前连接一个虚拟网络，切换网络先明确断开当前网络，不影响已保存的成员身份。

**通过条件**：首次授权、拒绝授权、重复点击、重启 App、断开过程中重连都有确定结果；主 App 被系统挂起后隧道仍可为前台游戏提供通信。

## 5. 实现快捷创建与加入

### 5.1 创建按钮的完整行为

用户点击 → 生成幂等 key → 调创建 API → 等网关 ready → 请求连接配置 → 首次系统授权 → 启动隧道 → 展示网络详情。

按钮提交中禁用重复触发，但允许取消 UI 等待；用户取消不等于服务器一定撤销已创建网络。恢复页面时按幂等结果查询，避免产生重复网络。

服务器配置超时应显示“网络已创建，连接准备中”或具体错误，不重新建一个网络。

### 5.2 三种邀请共用一套实现

创建 `InviteResolver`：输入 URL / 二维码内容 / 短码 → 规范化 → 向服务端解析 → 展示最少信息 → 用户确认 → 兑换 → 连接。

短码先实现；随后增加相机扫码和链接入口。二维码不携带私钥、公钥配置或成员列表，只承载 HTTPS 邀请链接。

邀请 URL 建议使用 `https://join.example.com/j#t=随机令牌`，令牌置于 fragment 以减少普通服务器访问日志泄漏；App 读取完整 URL 后将令牌放请求体兑换。网页不得加载第三方分析脚本，也不将令牌写入 localStorage。该形式必须在真机验证 Universal Link 和网页回退行为，不通过时改用路径令牌并对所有相关访问日志严格脱敏。

### 5.3 配置 Universal Links

1. App 添加 `applinks:join.example.com`。
2. 域名提供 HTTPS 的 `/.well-known/apple-app-site-association`，不要求登录、不重定向。
3. 文件中的 Team ID、Bundle ID、邀请路径与实际工程保持一致。
4. SwiftUI 接收 `NSUserActivityTypeBrowsingWeb`，把 URL 传给统一解析器。
5. 验证已安装、未安装、用户选择浏览器打开、令牌过期四种情况；始终保留短码加入入口。

具体配置格式以 Apple 官方文档为准；测试时注意系统缓存，不能只凭浏览器能打开 JSON 就判定 App 关联成功。[Apple Associated Domains](https://developer.apple.com/documentation/xcode/supporting-associated-domains)

最小关联文件示例（将应用标识前缀与 Bundle ID 替换为签名中的真实值；多数新团队前缀为 Team ID，但应以实际配置核对）：

```json
{
  "applinks": {
    "details": [
      {
        "appIDs": ["YOUR_PREFIX.com.yourteam.netpivot"],
        "components": [{ "/": "/j" }]
      }
    ]
  }
}
```

### 5.4 最近网络

仅保存自己已有成员资格的网络。点击连接时重新获取有效租约；不能靠本地旧配置绕过移除。对不再拥有资格的网络移出可连接列表并解释原因。

**通过条件**：首次系统授权后，创建只需一次主要操作；链接加入只需一次确认；回到最近网络一键重连。弱网重试不产生重复成员。

## 6. 完成双端布局

先做网络首页、详情、邀请弹层和错误页，再做高级诊断。共享 ViewModel / 状态仓库，布局组件分别组织，避免为两个设备维护两套连接逻辑。

使用 NavigationStack 处理紧凑布局、NavigationSplitView 处理宽布局。以可用宽度和 size class 选择布局，保留当前 network ID 和导航状态。

必须逐项完成：

- iPhone 小屏和大屏，横竖屏，键盘弹出后邀请码按钮仍可操作。
- iPad mini、常见尺寸 iPad 的全屏和窄窗口。
- 动态字体最大辅助字号，VoiceOver 朗读 IP 与连接状态。
- 深浅模式、长网络名、8 个成员、加载中、空状态和错误状态。
- 连接中旋转或调整窗口不重建隧道、不丢失输入。

**通过条件**：所有主要操作不截断、不被键盘遮挡；iPad 可同时查看列表与详情；窗口变窄不丢状态。

## 7. 从可用网关版升级到低延迟直连版

本阶段不是把配置开关设成 true。需要实现并验证 UDP 候选、映射与双向路径协调。未完成时产品明确标为“网关连接”。

### 7.1 先验证底层能力

构建独立的传输实验：A、B 通过同一个实际用于 WireGuard 的 UDP socket 或可证明等价的映射发起候选探测；由控制服务交换候选；双方同时发送连接检查。

不得只使用另一个 socket 的 STUN 结果。不要将所有网络套用一种固定 NAT 分类。探测目标只允许当前网络已授权成员的候选；拒绝无关内网、环回、链路本地和云元数据地址，防止探测被滥用。

本机私网候选暂不交换，避免不同家庭相同地址误匹配；首版优先公网映射或公网 IPv6 候选。之后有充分验证再增加同物理网络优化。

**通过条件**：在至少两种独立路由器和蜂窝场景下，日志能解释直连成功或失败；打洞失败时已有网关连接继续可用。

### 7.2 两端配置协调

以每一对成员维护状态，而非整个网络只有一个 direct 标志：

`gateway → probing → prepare(revision) → both-ready → commit → direct`。

任一端未确认、超时或网络变化 → 回滚该成员对到 gateway。控制消息必须有 session ID、revision、过期时间和双方确认，旧消息不得覆盖新配置。

直连建立后增加远端 `/32` Peer；回退时两端移除对应直连 Peer，使流量回到网关 `/24`。必须测试 WireGuard 接收源地址校验造成的过渡丢包，设置切换超时和回滚，不对外承诺无缝零丢包。

### 7.3 多设备拓扑

8 个成员最多有 28 对路径。网络逻辑上所有成员可互通，传输路径可以混合：A↔B 直连，A↔C 走网关，B↔C 仍可直连。

对活跃通信的成员对按需探测；不要让 8 台设备始终高频全互探。人数扩大前先评估 O(n²) 路径状态、耗电和候选信令量，不能只把上限常量改为 100。

网关在稳定直连时可降低空闲维护流量，但保留必要回退能力。对局期间切换需要限制频率，不能为了小幅降低 RTT 破坏稳定性。

### 7.4 备选网关

为网络准备主备网关，地址规划一致，公钥和公网端点独立；控制服务负责同步有效成员。只有备节点配置 revision 已确认才能发布为可切换目标。

主节点失效 → 控制面提供已就绪备节点 → 客户端更新网关 Peer → 验证收发 → 更新状态。若控制服务也不可用且没有有效缓存配置，不得假装可以自动恢复。

**通过条件**：三台以上设备混合路径仍逐对互通；主动切断一个直连或网关节点后按预期回退；其他成员连接不被无故重建。

## 8. 正式部署、监控与恢复

### 8.1 首个内测环境

一台测试机器可以承载 API、数据库和网关，但这是成本较低的单点内测环境，不满足高可用目标。API 通过 HTTPS 暴露，数据库仅绑定本地/私网；代理只通过本地 socket 或双向 TLS 管理。

上线前至少拆分：数据库持久化存储、两个控制服务实例、主备网关。网关按实测参与者位置选区；不要在没有用户位置和价格数据时购买大量节点。

网关成本主要由实际中继流量决定。估算公式：`每月网关出口字节 ≈ 活跃连接的游戏数据速率总和 × 中继占比 × 在线秒数 × 协议开销系数`；云厂商是否双向计费、是否有最低带宽收费另行核对，不用玩家人数直接推算固定账单。

### 8.2 必须记录的指标

- 创建、兑换、连接耗时与错误率；网关配置应用延迟。
- 活跃网络数、有效成员数、并发连接、邀请拒绝/限流次数。
- 直连成功率按网络类型拆分；回退次数、切换原因、恢复时长。
- 网关 CPU、内存、带宽、包丢弃、队列和握手状态。
- 扩展异常退出、内存峰值、版本、错误码；不附游戏载荷。

没有真实测量的指标显示未知，不用固定随机值做“实时延迟”。日志含 request ID 与配置 revision 以关联问题。

### 8.3 备份和回滚

每日加密备份控制数据库，按最小权限保存网关密钥与必要部署配置；禁止集中备份客户端私钥。恢复演练使用隔离环境，验证地址和成员关系不重复。

数据库采用先兼容扩展、后清理的迁移方式；客户端和服务端声明协议版本。部署先灰度一台网关/小范围设备，再扩大。失败时回滚应用版本和配置版本，不盲目逆转破坏性数据库迁移。

系统重启必须先建立拒绝默认的隔离策略，再恢复有效 Peer；过期租约不因重启重新获得有效期。

## 9. 打包和发行

1. 完成 [验收清单](ACCEPTANCE.md)，所有 P0 通过后才能发可用内测包。
2. 使用 Archive 检查 App 与扩展的签名、能力、版本号、第三方许可证。
3. 为 TestFlight 准备真实可用的测试服务器、邀请和说明；首次连接过程可复现。
4. 准备隐私说明，准确描述可信网关与设备直连差异。
5. 若公开上架，重新核对 VPN 审核规则和发行地区要求；不能认为内测成功就必然获准上架。[Apple 审核规则](https://developer.apple.com/app-store/review/guidelines/#vpn-apps)
6. 首发支持列表列出实测系统、游戏版本、网络条件与已知限制；未测组合不得标记已支持。

## 10. 最终交付必须包含什么

- 可在干净环境构建的完整源代码和锁定依赖。
- App、Packet Tunnel、控制 API、数据库迁移、网关代理与部署配置。
- 三种邀请方式、最近网络、一键连接与可复制虚拟 IP。
- iPhone / iPad 真机证据和 3、4、8 设备组网记录。
- 主机角色互换、混合路径、成员撤销、跨网络隔离与故障恢复记录。
- 服务器部署/升级/备份/恢复/回滚步骤。
- 测试包、版本记录、已知限制及图标资产。

当前文档交付完成不表示以上软件交付已经完成。

## 11. 按现象排查

| 现象 | 先查 | 再查 / 处理 |
| --- | --- | --- |
| 无 WireGuard 握手 | 公网端点、UDP 端口、安全组、公钥 | 设备其他 VPN、网络封锁、DNS/IPv6 解析 |
| 有握手无内层流量 | 客户端 AllowedIPs、虚拟地址 | 路由进入隧道情况、网关转发开关 |
| 请求到网关但不到对端 | 同网许可、目标 Peer `/32` | 其他 nftables 链、目的路由、对端在线状态 |
| 对端收到但无回应 | 游戏是否建房、目标 IP、游戏权限 | 游戏是否监听虚拟可达地址、版本兼容 |
| 可以上网但游戏连不上 | 上网本来就不经过本隧道 | 用虚拟 IP 业务流检查，不用浏览器能上网作证据 |
| 小包通、大包异常 | MTU 与分片 | ICMP 是否被阻断、不同外层网络开销 |
| App 后台后断开 | 生命周期是否写在主 App | 扩展日志、续租、资源压力；区分游戏自己后台停止 |
| 切网后不能恢复 | 旧 UDP 映射、端点缓存 | 路径 generation、重新握手、网关回退 |
| 加入成功但提示未连接 | 网关是否确认配置 revision | 签名、系统 VPN 状态、旧回调覆盖 |
| 直连后单向不通 | 双端 `/32` 是否一致应用 | 混合路径源地址校验，超时协调回网关 |
| 两台能用、第三台不通 | 地址/密钥是否重复 | 同网防火墙是否只写了 A↔B、每对路径状态 |
| 被移除后还能通信 | 客户端快照与租约 | 网关许可、连接跟踪、直连 Peer 是否撤销 |
| 链接进入网页而非 App | Associated Domains / AASA | 系统缓存、用户选择；用短码回退 |
| iPad 窄窗口按钮消失 | 固定尺寸 / 机型判断 | 采用可用空间布局，检查大字体和键盘 |

排查时每次只改变一个条件，记录修改前后现象。不能通过关闭所有隔离规则或让全部流量走 VPN 来掩盖问题。
