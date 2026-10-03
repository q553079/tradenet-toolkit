# Clash TUN 与 Windows 移动热点配置记录

记录日期：2026-10-03。适用场景：Windows 主机通过以太网上网，
Clash Verge Rev / Mihomo 开启 TUN，同时向手机提供移动热点。
这是一台机器上的排障结果和复用说明，不保证所有 Windows、网卡和 VPN 组合表现一致。

## 已验证的配置

热点的上游选择 **Mihomo TUN 网卡（本机名为 Meta）**，主机和手机流量进入
Mihomo 后，按规则选择 DIRECT 或现有代理节点。

```text
主机应用 ───────────────────┐
手机 → Windows 移动热点 → Meta TUN → Mihomo 分流
                           ├─ DIRECT → 以太网 → 互联网
                           └─ 代理节点 → 以太网 → 互联网
```

本次使用独立的 Clash TCP 代理配置；这与项目中 WireGuard + udp2raw 的部署路径不同。
热点兼容方法关注 Windows 共享出口，不要求替换已有节点。

| 设置 | 本次使用值 / 含义 |
| --- | --- |
| Clash 模式 | Rule（规则） |
| TUN | 开启，网卡名 Meta，gVisor 协议栈 |
| 系统代理 | 开启，指向 `127.0.0.1:7901` |
| 混合代理端口 | `7901`；只是本机选择，其他机器应选空闲端口 |
| 热点上游 | Meta，而非物理以太网 |
| DNS 模式 | `redir-host` |
| 物理网卡 DNS | 自动获取；不依赖退出后可能消失的本地 DNS 服务 |
| 腾讯 / LOL | 国服相关进程及 `qq.com` 优先 DIRECT |
| 手机流量 | 跟随 Clash 分流规则，可能消耗代理节点流量 |

本次切换热点上游后，观察到以太网 IPv4 Forwarding 为 Disabled，
Meta 与热点网卡为 Enabled。这是本机共享方式切换后的状态，
**不要把手动关闭物理网卡转发作为通用修复步骤**。

## 故障原因与验证边界

原先热点使用物理网卡作为上游。开启 TUN 后，Mihomo 自己发出的直连流量又进入 TUN，
日志出现 `reject loopback connection`，DNS 请求也被再次截获。
这会造成浏览器部分网页正常，但腾讯登录、WeGame 等连接超时。

本机做过的对比：

1. 关闭以太网 IPv4 转发后，腾讯接口可以完成 TLS 握手，LOL 官网返回 HTTP 200。
2. 恢复转发后，腾讯连接再次失败。
3. 仅关闭转发会让手机热点断网，因此不能作为最终方案。
4. 将热点上游切换到 Meta 后，主机腾讯接口和国外代理访问正常，用户确认手机热点恢复。

腾讯登录域名根路径返回 HTTP 403，只能证明请求到达服务器且 TLS 成功，
不代表账号已登录。LOL 实际登录、对局，以及 Rithmic / ATAS 实时连接仍应在应用中验证。
本次没有据此宣称交易软件已通过端到端测试。

切换 gVisor / mixed 或固定物理出口网卡，均未解决本机的原始冲突。
DNS 分流有助于腾讯域名使用国内解析，但不能修复 Windows 转发回环本身。

## 可复用配置片段

- [Clash Merge 示例](examples/clash-hotspot-merge.example.yaml)：端口、TUN 和 DNS。
- [LOL Rules 示例](examples/clash-lol-rules.example.yaml)：国服进程和域名直连。

两个文件分别用于 Clash Verge 当前订阅的 Merge（合并配置）和 Rules（规则）增强。
它们不是完整订阅，不能作为独立节点配置导入，也不负责设置 Windows 热点上游。
应用前备份当前增强配置，将片段合并到已有内容，保留自己的节点、策略组和其他应用规则。

Merge 示例中的 `PROXY` 必须是已有策略组名。如果你的组名是 `TradeNet`，
应把 DNS 地址里的 `#PROXY` 改为 `#TradeNet`。
不要据此覆盖 WireGuard、Rithmic、ATAS 或 OpenAI 等原有分流规则。
本次使用 `GEOIP,CN,DIRECT` 与最终代理兜底的独立配置；示例不强制修改你的兜底规则。

LOL 示例适用于腾讯 / WeGame 国服。国际服可能需要不同分流。
`TCLS\client.exe` 使用实际完整路径匹配，避免通用 `client.exe` 规则误伤其他软件。

端口 `7897` 在本机曾被另一个 VPN 使用，Clash 改为 `7901`。
端口没有通用固定要求，系统代理与实际监听端口一致即可。
服务不可用、重复内核或端口冲突需要分别排查，不应通过不断修改 DNS 掩盖。

## 切换热点上游

### 日常使用

1. 启动 Clash，确认节点和 TUN 正常，Meta 网卡已出现。
2. 开启系统代理，确认国内网站和需要代理的网站可访问。
3. 将移动热点的共享来源选为 Meta，再开启热点；若界面未显示 Meta，可用下方 WinRT 方法。
4. 手机重连热点，实际打开网页；再验证 LOL、交易软件等主机应用。

**当前没有实现随 TUN 开关自动切换热点上游的后台任务。**
直接关闭 TUN 或退出 Clash，会使依赖 Meta 的热点失去出口。

### WinRT 手动切换示例

以下代码使用 **Windows PowerShell 5.1**（`powershell.exe`），不是 PowerShell 7。
在本机 WinRT 接口可正常调用。它会先停止再开启热点，手机会短暂断开。
不修改热点名称、密码、节点或系统 DNS。

先用 `Get-NetAdapter` 确认目标网卡名称。设 `$adapterName = 'Meta'` 可共享 TUN；
设为实际物理网卡名（例如 `'以太网'`）可切回普通热点。
脚本要求唯一网卡和连接配置，失败时抛出错误，不会声称已经切换成功。

```powershell
$ErrorActionPreference = 'Stop'
$adapterName = 'Meta' # Change to the physical adapter name to restore direct sharing.
$adapters = @(Get-NetAdapter -Name $adapterName -ErrorAction Stop)
if ($adapters.Count -ne 1) { throw 'Expected exactly one network adapter.' }
$adapter = $adapters[0]
if ($adapter.Status -ne 'Up') { throw 'The target adapter is not up.' }

Add-Type -AssemblyName System.Runtime.WindowsRuntime
$profiles = [Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime]::GetConnectionProfiles()
$selected = @($profiles | Where-Object {
    $_.NetworkAdapter.NetworkAdapterId -eq [guid]$adapter.InterfaceGuid
})
if ($selected.Count -ne 1) { throw 'Expected exactly one connection profile.' }
$manager = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]::CreateFromConnectionProfile($selected[0])
$resultType = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]
$asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and
    $_.GetGenericArguments().Count -eq 1 -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
} | Select-Object -First 1

function Wait-TetherResult($operation) {
    $task = $asTask.MakeGenericMethod($resultType).Invoke($null, @($operation))
    if (-not $task.Wait(20000)) {
        throw 'Operation timed out; check hotspot state before retrying.'
    }
    if ($task.Result.Status.ToString() -ne 'Success') {
        throw ('Tethering failed: ' + $task.Result.Status + ' ' + $task.Result.AdditionalErrorMessage)
    }
}

if ($manager.TetheringOperationalState.ToString() -eq 'On') {
    Wait-TetherResult ($manager.StopTetheringAsync())
}
Wait-TetherResult ($manager.StartTetheringAsync())
$manager.TetheringOperationalState
```

切换前记录原来的共享来源。如果启动失败或手机无法联网，
把 `$adapterName` 改回原物理网卡名，再执行一次。
这段手动示例没有自动回滚或自动重试；异常后先查看热点状态。

### 关闭 TUN，只用系统代理

1. 热点共享来源切回物理以太网，并确认手机直连可用。
2. 关闭 TUN，保留 Clash 系统代理。
3. 分别验证主机应用。支持系统代理的软件可继续走代理；
   不支持系统代理的软件可能需要单独配置，不能保证 Codex 或交易客户端自动接入。

此模式下手机热点不会自动使用主机的 HTTP 系统代理。
如果仍有冲突，可先关闭热点，关闭 TUN，再按物理网卡上游重新开启热点。
退出 Clash 前关闭其系统代理，避免系统指向已停止监听的本地端口。
其他 VPN 同时运行时，需要重新核对代理端口、DNS 和默认路由。

## 验证与恢复

只读检查：

```powershell
Get-NetAdapter | Select-Object Name, InterfaceIndex, Status
Get-NetIPInterface -AddressFamily IPv4 |
    Select-Object InterfaceAlias, Forwarding, ConnectionState
Get-DnsClientServerAddress -AddressFamily IPv4
Get-NetTCPConnection -State Listen -LocalPort 7901 -ErrorAction SilentlyContinue
```

热点显示“已开启”或手机已关联，不等于手机已经能上网。
验收至少包括：手机网页、主机国内网站、代理网站、实际应用登录。
修改 Clash 规则后应检查实际命中的规则和日志；只保存 YAML 不代表运行内核已加载。

若再次出现“热点能用但主机腾讯连接超时”，先检查热点是否重新共享了物理网卡，
以及日志是否出现自身进程回环。不要用固定服务器 IP 或全局网络重置替代诊断。

恢复普通网络：停止热点，关闭 TUN，关闭不再使用的系统代理，
再通过物理网卡重新开启热点。若只需撤销示例配置，恢复修改前备份的 Merge / Rules。
本指南不安装服务或定时任务，不更改现有项目部署流程。

## 备份与公开范围

GitHub 中只保存本文和脱敏示例。完整订阅、真实节点、密码、令牌、WireGuard 密钥、
个人网卡 GUID、热点密码以及运行日志不应随文档提交。
Windows 热点共享状态不在 Clash YAML 中；换电脑后必须重新选择上游。
仅下载这两个示例文件不会自动恢复整台电脑的网络配置。

## 参考资料

- [Mihomo：Windows 转发导致 TUN 自身回环的报告](https://github.com/MetaCubeX/mihomo/issues/3186)
- [Clash Verge Rev：移动热点与 TUN 兼容方案讨论](https://github.com/clash-verge-rev/clash-verge-rev/issues/7739)
- [Microsoft：CreateFromConnectionProfile 选择公共上游连接](https://learn.microsoft.com/en-us/uwp/api/windows.networking.networkoperators.networkoperatortetheringmanager.createfromconnectionprofile)
- [Microsoft：StartTetheringAsync 与停止后重新启动的说明](https://learn.microsoft.com/en-us/uwp/api/windows.networking.networkoperators.networkoperatortetheringmanager.starttetheringasync)
- [Mihomo DNS 配置](https://wiki.metacubex.one/config/dns/)
