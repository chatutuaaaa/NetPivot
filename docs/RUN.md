# NetPivot 部署、编译和验收

当前实现使用 WireGuard 网关转发，单个网络最多容纳 8 台设备。iPhone 和 iPad 使用同一个 App。创建、邀请链接、二维码、短码加入和成员管理由服务端统一处理。客户端连接后可复制任一成员的虚拟 IPv4 地址。

## 1. 准备三种环境

| 环境 | 准备事项 |
| --- | --- |
| 开发电脑 | Go 1.25 或更新版本。Windows 可以执行第 2 步 |
| 专用 Ubuntu 24.04 主机 | 具备公网 IPv4、联网及 sudo 权限。安装 Go 1.25+、Docker Engine 与 Compose 插件，再安装 WireGuard 工具 |
| Mac 与 Apple 设备 | 使用支持设备系统版本的稳定 Xcode，安装 Go 与 XcodeGen。准备可签 Network Extension 的开发团队和至少一台 iPhone、一台 iPad |

准备用于 API、邀请和 WireGuard 的同一域名，以下以 `netpivot.example.com` 为例。添加 A 记录指向服务器公网 IPv4，DNS 服务直接解析到服务器。只有在服务器支持真实 IPv6 入站时才添加 AAAA 记录。服务器允许入站 TCP 80、TCP 443、UDP 51820。SSH 按服务器现有规则管理。

给 App 选择正式签名标识。以下示例使用 Team ID `ABCDE12345`、Bundle ID `com.example.netpivot`。如果开发团队使用不同的 App Identifier Prefix，把它作为服务器应用标识的前缀，并作为 Apple 脚本的第四个参数。Mac 与真机系统的匹配关系见 [Apple Xcode 支持表](https://developer.apple.com/xcode/system-requirements)。

## 2. 本地构建检查

在项目根目录进入 `server`，运行以下命令。PowerShell 和 Bash 均可直接执行。

```text
cd server
go test -count=1 ./...
go vet ./...
go build ./...
```

通过条件：测试输出包含 `internal/control` 和 `cmd/gateway-agent` 两个通过项。服务端测试包含签名重放、创建重试、8 台容量、跨网络权限和成员撤销。需要复测 PostgreSQL 时，将 `NETPIVOT_TEST_DATABASE_URL` 设置为**空的专用测试数据库**的连接地址，再重跑 `go test -count=1 ./internal/control`。

## 3. 部署网关与 API

把项目文件放到专用 Ubuntu 服务器。在项目根目录运行以下命令。网关代理使用受限 systemd 服务管理内核 WireGuard，PostgreSQL、API 和 HTTPS 代理由 Compose 管理。

```bash
sudo apt update
sudo apt install -y wireguard-tools iproute2 nftables openssl

mkdir -p server/.build
(
    cd server
    CGO_ENABLED=0 go build -trimpath -o .build/gateway-agent ./cmd/gateway-agent
)

sudo bash deploy/setup-gateway.sh "$PWD/server/.build/gateway-agent"
sudo bash deploy/configure-server.sh netpivot.example.com ABCDE12345.com.example.netpivot
sudo docker compose -f deploy/compose.yaml up -d --build
```

将示例域名和应用标识换成你的值。脚本将私钥保存在 `/etc/netpivot/gateway.key`，并创建只有管理员可读的 `deploy/.env`。Docker Compose 从该文件获取数据库和网关所需的凭据。API 的本机端口只绑定在 `127.0.0.1:8080`，可以用它检查网关状态。如果系统已配置 UFW 或其他转发链，确保它们允许 `netpivot0` 到 `netpivot0` 的转发，并允许 `netpivot0` 发往 `10.203.0.1:41820/UDP` 的探测流量。NetPivot 的同网隔离仍由自己管理的规则强制执行。

```bash
curl -fsS http://127.0.0.1:8080/healthz
curl -fsS http://127.0.0.1:8080/readyz
curl -fsS https://netpivot.example.com/healthz
curl -fsS https://netpivot.example.com/.well-known/apple-app-site-association
sudo wg show netpivot0
sudo systemctl status netpivot-agent --no-pager
```

通过条件：两个健康检查都返回 `{"ok":true}`，域名默认用 HTTPS 访问，关联文件包含签名后的应用标识。客户端还没加入时，网关没有 Peer 属于正常状态。

如果 `healthz` 成功但 `readyz` 返回 503，查看 `sudo journalctl -u netpivot-agent -n 50 --no-pager` 和 `sudo nft list table inet netpivot`。域名无法签发证书时查看 `sudo docker compose -f deploy/compose.yaml logs web`，核对 DNS 与 TCP 80/443。

## 4. 在 Mac 上生成并签名

### 没有 Mac 时的编译验证

GitHub Actions 的 `macos-26` 运行环境提供 Xcode，可以从 Windows 浏览器发起 NetPivot 的无签名构建。这个检查编译并链接 iPhone／iPad App、Packet Tunnel 扩展和 WireGuard 桥接库。流程用占位标识，因此无需 Apple 开发者账号、真实域名或已部署的网关。[GitHub macOS 运行环境说明](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)

1. 在 GitHub 创建空白私有仓库，从项目根目录提交并推送源码。当前目录如果没有 Git 仓库，可以在 PowerShell 执行下列命令。把远程地址换成你刚创建的仓库。

   ```powershell
   git init -b main
   git add --all
   git status --short
   git commit -m "Add NetPivot and iOS build check"
   git remote add origin https://github.com/YOUR_ACCOUNT/NetPivot.git
   git push -u origin main
   ```

   提交前查看 `git status --short`，确保没有密钥、签名文件或本机配置。私有仓库的运行时间计入账号的 GitHub Actions 额度。[GitHub Actions 计费说明](https://docs.github.com/en/billing/concepts/product-billing/github-actions)

2. 确认工作流已进入仓库默认分支。打开 **Actions → iOS Build Check → Run workflow**，选择分支并启动。[GitHub 手动运行工作流说明](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)
3. **Verify both binaries** 通过后，主 App 和 VPN 扩展均已构建成功。如果失败，打开标红步骤，查看第一条编译或链接错误。

无签名构建用于编译验证，产物无法安装到 iPhone／iPad。后续真机测试可用云 Mac 完成签名并通过 TestFlight 分发。届时需要具备对应 Network Extension 权限的开发团队，以及 NetPivot 网关。[Apple Network Extension 配置说明](https://developer.apple.com/documentation/xcode/configuring-network-extensions/) · [TestFlight 说明](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)

### 在有 Xcode 的环境中安装到设备

使用 Xcode 登录开发团队，在 Apple Developer 中为主 App 和 `.tunnel` 扩展准备标识，启用所需的 Network Extensions 和 App Group 能力。主 App 启用 Associated Domains。为两个标识关联同一个 App Group，例如 `group.com.example.netpivot`，保持共享 Keychain 的标识前缀与签名匹配。

```bash
brew install go xcodegen
bash apple/scripts/bootstrap.sh ABCDE12345 com.example.netpivot netpivot.example.com
open apple/NetPivot.xcodeproj
```

脚本下载固定提交的 WireGuardKit 和供桥接库使用的 Go 1.19.13，写入本机配置并生成 Xcode 工程。服务端继续使用 Go 1.25+。桥接库通过固定的上游构建脚本生成。首次构建需要能够访问 Go、Git 和 Apple 的构建工具。

在 Xcode 中选择 `NetPivot` scheme 和已配对 iPhone/iPad。检查 App 与 PacketTunnel 两个 target 的 Team 和签名，然后运行。当前工程生成配置面向 iOS 真机。若签名失败，先检查两个 Bundle ID、Network Extensions、共享 Keychain 和 App Group 是否与对应描述文件匹配。

通过条件：两类真机都能安装并打开，首次连接时出现系统 VPN 授权。用户确认后，网关 `wg show netpivot0` 出现相应设备的近期握手。

## 5. 星露谷与多人真机验收

1. 让 iPhone 和 iPad 使用不同的外网。打开 NetPivot，iPhone 点击「创建网络」，阅读连接说明并允许系统配置 VPN。
2. 等待详情显示「网络可用」。点击「邀请朋友」，用链接、扫码或短码让 iPad 加入。新设备应收到不同的虚拟 IP。
3. 在游戏中启用普通移动版的实验性联机。版本保持一致，首次验证使用测试存档，准备可加入的农场和空闲小屋。移动端在游戏中通过 IP 加入，Apple Arcade 版缺少该模式。参见 [星露谷官方联机指南](https://www.stardewvalley.net/mobile-multiplayer-guide/)。
4. 游戏主机在 NetPivot 复制自己的虚拟 IP，另一台设备在游戏「加入」中填写该 IP。进入农场并持续游玩，随后交换主机角色。
5. 加入第三台真机，验证各设备都能通信。游戏的房间人数遵循游戏限制，网络容量单独按 8 台验证。
6. 验证不同尺寸 iPhone 横竖屏、iPad 全屏与窄窗口、相机拒绝、VPN 拒绝、管理员离线、Wi‑Fi 与蜂窝切换。记录设备、系统、游戏版本和结果。

游戏无法加入时，先核对双方游戏版本、主机农场、游戏自己的本地网络权限及主机虚拟 IP。网关探测成功只证明到网关的收发，游戏端行为需要实际进入农场验证。查看 [按现象排查](BUILD_GUIDE.md#11-按现象排查) 和 [验收清单](ACCEPTANCE.md)。

## 6. 可重复的内核网络实验

此实验在独立容器中创建 9 个 Linux 网络命名空间和真实 WireGuard 接口。8 个成员属于同一个网络，另有一个隔离网络用于验证防火墙。子进程使用 UDP 24642 进行请求和回包。

如果主机已有 Docker，从项目根目录执行以下命令。Podman 用户可以使用对应的 `podman` 命令。在 Windows 上可从具有容器运行能力的 WSL 环境执行，工作目录应指向同一个项目。

```bash
(
    cd server
    GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -o .build/ ./cmd/api ./cmd/gateway-agent
)
docker build -f server/tests/Containerfile -t netpivot-kernel-lab server/tests
docker run --rm --privileged -v "$PWD:/project:ro" netpivot-kernel-lab
```

上面用的是 Linux amd64。ARM64 主机将 `GOARCH` 改为 `arm64`。实验验证 56 条有向 UDP 路径、UDP 源端口变化后的恢复、跨网双向拦截，以及移除成员后其余成员的通信。

## 7. 当前实现与发布状态

| 项目 | 状态 |
| --- | --- |
| 服务 API | Go 测试通过，使用 PostgreSQL 17 的集成测试通过 |
| 8 台多设备转发 | Linux 内核 WireGuard 验证 56 条有向 UDP 路径，并确认客户端更换 UDP 源端口后恢复双向通信 |
| 网络隔离和撤销 | Linux 实验验证跨网双向拦截，移除成员后其余成员仍可收发 |
| iPhone / iPad | 客户端、扩展、权限配置和图标已接入。Swift 源文件和配置已做静态检查，Xcode 编译、签名和真机交互待验证 |
| 游戏和网络性能 | 星露谷真机联机、不同运营商下的 RTT、丢包和切网恢复待测 |
| 路径优化与高可用 | 当前所有设备使用指定网关。逐对直连、区域网关选择、备节点切换仍待开发 |

当前服务端面向小规模内测。成员、邀请和租约保存于 PostgreSQL 的一个事务状态行，扩展续租、App 按周期刷新成员列表。关系表拆分、事件流和多网关管理是后续扩展。数据与证书可通过 Compose 对应卷备份。正式部署前按 [设计与发行要求](DESIGN.md#9-安全隐私与发行) 核对许可证、依赖版本、审核和运行指标。

更新服务端时保留 `deploy/.env` 和数据库卷，重建 API。更新网关代理时用新构建产物替换 `/usr/local/sbin/netpivot-agent` 后重启对应服务。代理重启时会先清理旧转发许可，再恢复仍有效的租约，安排在联机间隙操作。
