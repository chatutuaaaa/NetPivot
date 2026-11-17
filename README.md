# NetPivot

面向 iPhone / iPad 的快捷虚拟局域网工具。创建网络、分享邀请、加入网络后，玩家在游戏中通过主机虚拟 IP 联机。首个验证对象是《星露谷物语》普通移动版。

当前阶段为 **WireGuard 网关版**。仓库包含 Go 服务端、网关、SwiftUI 客户端及部署配置。Linux 上已验证 8 台设备的 UDP 互通；Apple 真机和《星露谷物语》联机待测。

## 运行项目

从 [部署、编译和验收](docs/RUN.md) 开始。Windows 可以开发和测试服务端，部署网关使用 Linux，签名并安装客户端使用 Mac 和 Xcode。

没有 Mac 时，可先按[云端编译验证步骤](docs/RUN.md#没有-mac-时的编译验证)使用 GitHub Actions 检查 iOS App 和 Packet Tunnel 扩展的构建。

## 阅读顺序

1. [产品与技术设计](docs/DESIGN.md)：确认产品范围、使用流程、架构、界面和技术决策。
2. [分阶段搭建指南](docs/BUILD_GUIDE.md)：设计阶段留下的手工互联实验与后续优化方案。
3. [测试与交付清单](docs/ACCEPTANCE.md)：每个阶段完成后逐项验收，记录证据。

## 已确认的要求

- 异地设备加入同一个虚拟局域网。
- 优先低延迟，连接稳定，异常时能够恢复。
- iPhone / iPad 分别适配，支持不同尺寸、横竖屏及 iPad 窗口变化。
- 创建、加入操作简单快捷。
- NetPivot 只负责网络；游戏内建房和加入由玩家自行操作，不实现游戏房间扫描。
- 多设备共享同一网络，首版暂定上限 8 台；两台测试只是基础连通关卡。

## 图标

[SVG 图标母版](assets/brand/netpivot-icon.svg) · [透明标志](assets/brand/netpivot-mark.svg) · [图标使用说明](assets/brand/README.md)

文档日期：2026-11-17。项目名暂沿用当前目录名称 NetPivot。
