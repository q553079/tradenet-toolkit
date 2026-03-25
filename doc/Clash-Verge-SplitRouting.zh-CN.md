# TradeNet Clash Verge 分流配置与启动说明

如果你现在是在给一台新机器做完整落地，先看：

- [TradeNet-Deployment.zh-CN.md](D:/TradeNet/doc/TradeNet-Deployment.zh-CN.md)

本文更偏向“已经部署好以后，日常怎么启动、构建、同步、验证”。

## 概述

这套方案用于在 Windows 客户端上运行一条稳定的：

`udp2raw -> Mihomo(Clash Meta) TUN -> WireGuard outbound -> VPS`

当前设计目标是：

- 交易软件优先稳定
- 常用海外网站按白名单分流
- 其他流量默认直连
- 不再使用 `GEOSITE,geolocation-!cn` 这类过宽规则

当前默认思路不是“全局海外都走 VPS”，而是“交易软件 + 明确域名白名单走 VPS”。

## 当前链路

本机当前链路如下：

1. 流量进入 Mihomo TUN
2. Mihomo 按规则匹配 `TradeNet`
3. `TradeNet` 组使用 `TradeNet-WG`
4. `TradeNet-WG` 连接到本地 `127.0.0.1:24008`
5. 本地 `127.0.0.1:24008` 由 `udp2raw` 监听
6. `udp2raw` 再转发到 VPS `38.207.170.65:4000`

也就是：

`应用 -> Mihomo -> TradeNet-WG -> 127.0.0.1:24008 -> udp2raw -> VPS`

## 关键文件

- [Build-TradeNetMihomoConfig.ps1](D:/TradeNet/Build-TradeNetMihomoConfig.ps1)
  负责从分流配置生成 Mihomo YAML，并做校验
- [TradeNet.SplitRouting.example.psd1](D:/TradeNet/TradeNet.SplitRouting.example.psd1)
  分流配置模板
- `TradeNet.SplitRouting.psd1`
  本机真实配置，包含密钥，不提交 Git
- `mihomo\tradenet-split.yaml`
  生成后的 Mihomo 配置，不提交 Git
- [SplitRouting.md](D:/TradeNet/SplitRouting.md)
  分流设计说明
- [start-tradenet.ps1](D:/TradeNet/start-tradenet.ps1)
  启动底层栈
- [stop-tradenet.ps1](D:/TradeNet/stop-tradenet.ps1)
  停止底层栈
- [Run-TradeNetDashboard.bat](D:/TradeNet/Run-TradeNetDashboard.bat)
  打开仪表板

## 当前配置要点

### DNS

- `enhanced-mode: redir-host`
- 启用 `sniffer`
- 海外白名单域名通过 fallback DNS 走 `TradeNet`
- 关闭 IPv6，降低异常 IPv6 解析导致的失败

### WireGuard outbound

- `server: 127.0.0.1`
- `port: 24008`
- `allowed-ips: 0.0.0.0/0`
- `remote-dns-resolve: true`

这里的 `0.0.0.0/0` 仅指 Mihomo 内部这个出站的允许范围，不代表系统默认路由改成全局 WireGuard。

### 交易流量保障

交易相关流量同时使用两层规则：

1. 进程名规则
2. 域名规则

交易进程包括：

- `OFT.Platform.exe`
- `ATASPlatform.exe`
- `Bookmap.exe`
- `RTraderPro.exe`
- `RTrader.exe`
- `RithmicTraderPro.exe`

交易域名包括：

- `rithmic.com`
- `atas.net`
- `orderflowtrading.net`

这样即使未来有 helper 进程变化，交易域名仍然会继续走 `TradeNet`。

## 当前已纳入的常用海外网站白名单

当前规则已经覆盖：

- Google / YouTube
- OpenAI / ChatGPT / Codex
- GitHub
- Reddit
- Discord
- Docker
- Pornhub / PHN CDN
- XVideos / XVideos CDN
- XNXX
- xHamster
- Redtube

以及这类页面常见的辅助域名：

- `trafficjunky.net`
- `orbsrv.com`
- `xlivrdr.com`
- `mmcdn.com`

## 启动方式

### 启动底层栈

```powershell
powershell -ExecutionPolicy Bypass -File .\start-tradenet.ps1
```

或者直接双击：

```text
start-tradenet.bat
```

启动后会：

- 检查 VPS 直连路由
- 启动 `udp2raw`
- 监听 `127.0.0.1:24008`
- 写入启动日志和诊断快照

### 停止底层栈

```powershell
powershell -ExecutionPolicy Bypass -File .\stop-tradenet.ps1
```

或者双击：

```text
stop-tradenet.bat
```

### 打开仪表板

```text
Run-TradeNetDashboard.bat
```

## 重建 Clash 分流配置

修改分流模板后，执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\Build-TradeNetMihomoConfig.ps1
```

成功后会生成：

- `D:\TradeNet\mihomo\tradenet-split.yaml`

并写入：

- `D:\TradeNet\state\split-routing-state.json`

脚本会自动调用 Mihomo 做语法校验；只有校验通过，才说明生成结果可用。

## 同步到 Clash Verge

生成后的 `tradenet-split.yaml` 需要同步到 Clash Verge 实际导入的本地 profile 文件。

现在项目已经支持两种方式：

1. 第一次手动导入
2. 导入完成后，后续通过 `Install-TradeNetClient.ps1` 自动覆盖同步

也就是说，第一次让 Clash Verge 认识这个 profile，仍然建议手工操作一次；从第二次开始，就可以让自动化脚本直接覆盖这个本地 profile 文件。

本机当前使用过的 profile 文件示例：

- `C:\Users\666\AppData\Roaming\io.github.clash-verge-rev.clash-verge-rev\profiles\LzcYMgIeZchO.yaml`

同步示例：

```powershell
Copy-Item `
  -Path D:\TradeNet\mihomo\tradenet-split.yaml `
  -Destination C:\Users\666\AppData\Roaming\io.github.clash-verge-rev.clash-verge-rev\profiles\LzcYMgIeZchO.yaml `
  -Force
```

同步后建议：

1. 重启 Mihomo service
2. 或切到别的 profile，再切回 `TradeNet分流`

如果你已经在 `TradeNet.Deployment.psd1` 里配置了：

- `Client.ClashVergeProfilePath`
- `Client.Deployment.SyncClashProfile = $true`

那么重新执行下面任一命令时，脚本会在生成 YAML 后自动覆盖这个 Clash Verge profile 文件：

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy\Install-TradeNetClient.ps1
```

或者：

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy\Setup-TradeNet.ps1 -SkipServer
```

## 日常推荐顺序

1. 启动 `TradeNet`
2. 打开 Clash Verge
3. 切换到 `TradeNet分流`
4. 验证交易软件和目标网站
5. 开始使用

## 如何验证交易流量确实走了 udp2raw

### 看 `udp2raw` 是否在监听

```powershell
Get-NetUDPEndpoint -LocalAddress 127.0.0.1 -LocalPort 24008
Get-Process -Name udp2raw_mp
```

### 看 Mihomo 服务日志

重点看：

- `C:\Users\666\AppData\Roaming\io.github.clash-verge-rev.clash-verge-rev\logs\service\service_latest.log`

例如这类日志就表示交易流量已经走进 `TradeNet-WG`：

```text
[TCP] ... (OFT.Platform.exe) --> ritpz01004.01.rithmic.com:65000 match ProcessName(OFT.Platform.exe) using TradeNet[TradeNet-WG]
[UDP] ... (OFT.Platform.exe) --> sntp.atas.net:123 match DomainSuffix(atas.net) using TradeNet[TradeNet-WG]
```

## 常见问题

### 1. 海外网站打不开

先看 `service_latest.log` 里它是：

- `using TradeNet[TradeNet-WG]`
- 还是 `using DIRECT`

如果是 `using DIRECT`，通常说明它还没被加入白名单。

### 2. 改了 YAML 但 Clash Verge 没生效

因为：

- `D:\TradeNet\mihomo\tradenet-split.yaml`
- Clash Verge 导入后的 profile 文件

默认不是自动同步关系。只有当你在部署配置里明确开启 `SyncClashProfile` 时，脚本才会自动覆盖目标 profile；否则仍然需要手工复制或重新导入。

### 3. 交易正常，但某些网页异常

一般是页面还依赖了其他辅助域名，没有一起进白名单。继续按日志补规则即可，不建议回退到“全量海外分流”。

## Git 提交建议

适合提交 Git：

- `Build-TradeNetMihomoConfig.ps1`
- `TradeNet.Common.ps1`
- `TradeNet.SplitRouting.example.psd1`
- `SplitRouting.md`
- 本文档

不要提交 Git：

- `TradeNet.Config.psd1`
- `TradeNet.SplitRouting.psd1`
- `TradeNet.Deployment.psd1`
- `logs\`
- `state\`
- `mihomo\`
