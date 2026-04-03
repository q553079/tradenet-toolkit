# TradeNet 一键部署与换机说明

这份文档是给“下一台机器也能照着做出来”的版本。

目标不是只讲原理，而是把整套流程拆成：

1. 要准备什么
2. 哪些步骤已经自动化
3. 哪些步骤必须人工做
4. 每个字段怎么填
5. 部署完以后怎么验证

## 1. 这套项目自动化了什么

当前项目自动化覆盖了两端：

- VPS 端：安装 WireGuard、安装或复用 `udp2raw`、写服务配置、开机自启、导出客户端产物
- Windows 客户端：生成 `TradeNet.Config.psd1`、生成 `TradeNet.SplitRouting.psd1`、构建 `mihomo\tradenet-split.yaml`、校验 Mihomo YAML、可选同步到 Clash Verge 已导入的本地 profile、可选注册开机 watchdog

另外还有两条补充脚本：

- `Build-TradeNetClashConfig.ps1`
  直接基于 `TradeNet.SplitRouting.psd1` 生成“纯 TradeNet 分流”的 Clash 配置，适合导入为 `TradeNet2`
- `deploy\server\install-tradenet-tcp-fallback.sh`
  在同一台 VPS 上额外起一个 TCP fallback 节点，并导出手机可导入的订阅
- `deploy\Initialize-WindowsSshTarget.ps1`
  把一台 Windows 机器初始化成可 SSH 登录的部署目标，适合后续让控制端推送脚本或产物
- `deploy\Retry-Initialize-WithPublicDns.ps1` / `deploy\Restore-DnsFromBackup.ps1`
  当目标机解析微软或 GitHub 域名不稳定，导致 OpenSSH 安装失败时，先临时切到公共 DNS 重试，再恢复原 DNS

当前仍然需要人工完成的部分：

- 购买并拿到 VPS 的公网 IP、SSH 端口、账号、密码
- 首次安装本地依赖软件
- 首次把 `tradenet-split.yaml` 导入到 Clash Verge
- 首次确认 Clash Verge 实际生成的 profile 文件路径
- 首次确认本机 `Npcap` 设备字符串和本地网关

一句话概括：

- 第一次部署是“半自动”
- 第一次做完以后，后续重装、换机、改规则，自动化程度就会很高

## 2. 当前实际链路

现在这套分流模式不是“浏览器全局翻墙”，而是：

- 交易软件和指定海外域名走 `TradeNet`
- 其他流量默认直连

当前链路是：

`应用 -> Mihomo TUN -> TradeNet-WG -> 127.0.0.1:24008 -> udp2raw -> VPS`

其中：

- `ATAS / Rithmic / OFT / Bookmap` 通过进程规则和域名规则走 `TradeNet`
- `TradeNet-WG` 的下一跳是本地 `127.0.0.1:24008`
- 本地 `127.0.0.1:24008` 再由 `udp2raw` 发到 VPS

所以只要日志里看到：

- `using TradeNet[TradeNet-WG]`

就说明它已经进入：

- `udp2raw -> VPS`

这条链路。

## 3. 部署前必须准备的资料

### 3.1 VPS 侧

你至少要有下面这些值：

- `Server.Host`
  一般直接填 VPS 公网 IP
- `Server.Port`
  SSH 端口，默认通常是 `22`
- `Server.User`
  当前脚本默认按密码登录，通常直接填 `root`
- `Server.Password`
  当前自动化脚本会直接用密码 SSH 登录，这个字段现在是必填
- `Server.PublicEndpoint`
  给客户端访问用的公网 IP，一般也是 VPS 公网 IP
- `Server.PublicInterface`
  VPS 出公网的网卡名，常见是 `eth0`、`ens3`、`enp1s0`

查看 `PublicInterface` 最简单的方法是在 VPS 里执行：

```bash
ip route get 1.1.1.1
```

通常输出里会包含：

- `dev eth0`
- 或 `dev ens3`

这个 `dev` 后面的值就是要填的公网网卡名。

### 3.2 Windows 客户端侧

你至少要有下面这些值：

- `Client.Udp2rawExePath`
  `udp2raw_mp.exe` 的本地路径
- `Client.Udp2rawDev`
  `Npcap` 设备字符串，格式类似 `\Device\NPF_{GUID}`
- `Client.LocalGateway`
  本机默认网关，例如 `192.168.0.1`
- `Client.MihomoExe`
  `verge-mihomo.exe` 的路径
- `Client.ClashVergeProfilePath`
  Clash Verge 导入后的实际本地 profile 文件路径

### 3.3 如何找本机默认网关

在 Windows PowerShell 执行：

```powershell
Get-NetRoute -DestinationPrefix 0.0.0.0/0 |
  Sort-Object RouteMetric |
  Select-Object -First 1 ifIndex,NextHop,RouteMetric
```

一般 `NextHop` 就是要填的 `Client.LocalGateway`。

### 3.4 如何找 `Npcap` 设备字符串

最容易出错的字段就是这里。

在管理员 PowerShell 执行：

```powershell
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkCards' |
  ForEach-Object {
    $p = Get-ItemProperty $_.PSPath
    [pscustomobject]@{
      Description = $p.Description
      ServiceName = $p.ServiceName
      NpcapDevice = "\\Device\\NPF_{$($p.ServiceName)}"
    }
  } | Format-Table -AutoSize
```

你会看到类似：

- 网卡描述
- 对应 GUID
- 拼好的 `NpcapDevice`

然后选你当前实际联网的物理网卡：

- Wi-Fi 就选无线网卡
- 网线就选有线网卡
- 不要选虚拟网卡
- 不要选没在联网的网卡

把对应那一行的 `NpcapDevice` 复制到：

- `Client.Udp2rawDev`

## 4. 本地必须安装的软件

### 4.1 Python

用途：

- `Deploy-TradeNetServer.ps1` 会调用本地 Python
- 脚本会自动执行 `py -m pip install --user paramiko`

官方地址：

- [Python Windows Downloads](https://www.python.org/downloads/windows/)

安装后请先确认这两个命令至少有一个能用：

```powershell
py --version
python --version
```

### 4.2 Clash Verge Rev

用途：

- 提供 Mihomo 内核和 TUN 分流能力

官方地址：

- [Clash Verge Rev Releases](https://github.com/clash-verge-rev/clash-verge-rev/releases)

默认常见路径：

- `C:\Program Files\Clash Verge\verge-mihomo.exe`

安装后至少启动一次，让它创建自己的数据目录。

### 4.3 Npcap

用途：

- `udp2raw_mp.exe` 在 Windows 下需要依赖抓包驱动

官方地址：

- [Npcap Download](https://npcap.com/#download)

安装后如果后面 `udp2raw` 仍然无法打开网卡，再回头检查：

- 是否装对了网卡驱动
- 是否需要重装并启用兼容模式

### 4.4 udp2raw

用途：

- 本地和 VPS 之间的底层伪装隧道

项目地址：

- [udp2raw Releases](https://github.com/wangyu-/udp2raw-tunnel/releases)

这个项目当前不会自动帮你下载 Windows 版 `udp2raw_mp.exe`。

但 VPS 端部署脚本现在已经会在 Linux 服务器上自动下载并安装 `udp2raw`，默认使用官方发布的归档包。

你需要人工下载并放到固定路径，例如：

```text
D:\TradeNet\bin\udp2raw_mp.exe
```

然后把这个路径填到：

- `Client.Udp2rawExePath`

### 4.5 WireGuard for Windows

用途：

- 如果你要安装本地 WireGuard tunnel service，就必须安装
- 即使不装隧道服务，也建议装，方便以后排查和看握手

官方地址：

- [WireGuard Install](https://www.wireguard.com/install/)

如果你明确只跑：

- `udp2raw + Mihomo split-routing`

并且：

- `Client.Deployment.InstallWireGuardTunnel = $false`

那当前脚本不会再把 `WireGuard GUI` 和 `wg.exe` 当成硬性前置依赖。

## 5. 复制并填写部署文件

先复制模板：

```powershell
Copy-Item .\TradeNet.Deployment.example.psd1 .\TradeNet.Deployment.psd1
```

然后编辑：

- `D:\TradeNet\TradeNet.Deployment.psd1`

### 5.1 Server 段怎么填

下面这些字段最关键：

- `Host`
  你的 VPS IP
- `Port`
  SSH 端口
- `User`
  默认填 `root`
- `Password`
  root 密码
- `PublicEndpoint`
  给客户端访问的公网 IP
- `PublicInterface`
  VPS 出公网网卡名
- `Udp2rawPassword`
  你自己定义的密码，客户端和服务器必须一致

如果你没有特别需求，下面这些可以先沿用模板默认值：

- `WireGuardInterface = "wg0"`
- `WireGuardSubnet = "10.77.0.0/24"`
- `ServerAddress = "10.77.0.1/24"`
- `ClientAddress = "10.77.0.2/24"`
- `WireGuardListenPort = 24008`
- `Udp2rawListenPort = 4000`
- `Udp2rawMode = "faketcp"`

### 5.2 Client 段怎么填

这些字段是本机必须改的：

- `Udp2rawExePath`
- `Udp2rawDev`
- `LocalGateway`
- `MihomoExe`
- `ClashVergeProfilePath`

说明：

- `ClashVergeProfilePath` 可以先暂时写占位路径
- 但只有在你真正找到导入后的 profile 文件后，才能把 `SyncClashProfile` 打开

### 5.3 Client.Deployment 段怎么填

最常用的是这几个开关：

- `VerifyBinaries`
  是否做本地二进制检查
- `RunPreflightChecks`
  是否生成 `artifacts\client-preflight.txt`
- `InstallWireGuardTunnel`
  是否安装本地 WireGuard tunnel service
- `InstallWatchdogTask`
  是否注册开机 watchdog
- `SyncClashProfile`
  是否把生成的 YAML 自动覆盖到 Clash Verge 的本地 profile 文件
- `BackupClashProfileBeforeSync`
  覆盖前是否自动备份旧 profile

推荐第一台机器这么用：

- `InstallWireGuardTunnel = $false`
- `InstallWatchdogTask = $true`
- `SyncClashProfile = $false`

理由：

- 先把整套链路跑通
- 等你确认 Clash Verge 的 profile 文件路径以后，再把自动同步打开

### 5.4 SplitRouting 段现在怎么理解

当前客户端安装脚本会先读：

- `TradeNet.SplitRouting.example.psd1`

把它当成完整模板，然后再叠加：

- `TradeNet.Deployment.psd1` 里的 `SplitRouting`

这意味着：

- 项目默认分流规则在模板里维护
- 换机差异或临时增补规则可以放在部署文件里

目前 `SplitRouting` 段里最常用的字段是：

- `DirectApps`
- `TradeApps`
- `WireGuardAllowedIPs`
- `WireGuardRemoteDnsResolve`
- `WireGuardDns`
- `AdditionalRules`
- `AdditionalFallbackDomains`

例如你想临时给某个站点加规则，只需要在：

- `AdditionalRules`
- `AdditionalFallbackDomains`

里追加，而不用改脚本。

如果是“某些 API 必须走本地直连”，规则写法要直接指向 `DIRECT`，例如：

```powershell
AdditionalRules = @(
    "DOMAIN-SUFFIX,api.deepseek.com,DIRECT",
    "DOMAIN-SUFFIX,platform.deepseek.com,DIRECT",
    "DOMAIN-SUFFIX,deepseek.com,DIRECT"
)
```

注意：

- 这种本地直连 API 不要加进 `AdditionalFallbackDomains`
- 否则 DNS 仍会被当成需要走 `TradeNet` 的域名处理

## 6. 自动化部署命令

### 6.1 一次性完成 VPS + Client

推荐在管理员 PowerShell 里执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy\Setup-TradeNet.ps1
```

这个命令会依次做两件事：

1. `Deploy-TradeNetServer.ps1`
2. `Install-TradeNetClient.ps1`

### 6.2 只部署 VPS

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy\Setup-TradeNet.ps1 -SkipClient
```

### 6.3 只刷新本机客户端

适合下面这些场景：

- 服务器已经部署好了
- 你只是改了分流规则
- 你只是换了本机路径
- 你已经知道 Clash Verge 的 profile 文件路径，想重新同步

执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy\Setup-TradeNet.ps1 -SkipServer
```

或者直接：

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy\Install-TradeNetClient.ps1
```

### 6.4 生成纯 TradeNet 的 Clash 配置

如果你已经有 `TradeNet.SplitRouting.psd1`，想额外生成一份干净的本地 Clash profile，可以执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\Build-TradeNetClashConfig.ps1
```

默认输出：

- `mihomo\tradenet-clash-merged.yaml`

注意：

- 这份文件现在是“纯 TradeNet 配置”，不会再混入现有机场节点
- 它不会读取你当前正在使用的机场 profile，只复用 `TradeNet.SplitRouting.psd1` 对应的分流结果
- 如果你想在 Clash Verge 里单独保留一个干净 profile，推荐导入后命名为 `TradeNet2`

### 6.5 部署 TCP fallback 订阅

这条脚本是独立的 VPS 侧补充脚本，不会自动跟 `Setup-TradeNet.ps1` 一起执行。

最少需要这 3 个环境变量：

- `TRADENET_TCP_PUBLIC_ENDPOINT`
- `TRADENET_TCP_SS_PASSWORD`
- `TRADENET_TCP_SUBSCRIPTION_TOKEN`

示例：

```bash
TRADENET_TCP_PUBLIC_ENDPOINT=154.51.40.118 \
TRADENET_TCP_SS_PASSWORD='replace-with-strong-password' \
TRADENET_TCP_SUBSCRIPTION_TOKEN='replace-with-random-token' \
bash ./deploy/server/install-tradenet-tcp-fallback.sh
```

执行完成后，服务器会在下面两个位置给出结果：

- HTTP 订阅地址：`http://<PUBLIC_ENDPOINT>/<prefix>-<token>.yaml`
- 服务器产物目录：`/opt/tradenet/artifacts/`

## 7. 自动化部署后会产出什么

服务器部署成功后，仓库里的 `artifacts\` 目录通常会有：

- `tradenet-client-artifact.json`
- `client-wireguard.conf`
- `server-health.txt`
- `server-summary.txt`
- `server-install.stdout.log`
- `server-install.stderr.log`

如果你额外部署了 TCP fallback，服务器 `/opt/tradenet/artifacts/` 下还会看到：

- `tcp-fallback-summary.txt`
- `tcp-fallback-subscription.yaml`
- `TradeNet2-Mobile-Subscription.md`

客户端部署成功后，会生成：

- `TradeNet.Config.psd1`
- `TradeNet.SplitRouting.psd1`
- `mihomo\tradenet-split.yaml`
- `artifacts\client-preflight.txt`

其中：

- `TradeNet.Config.psd1` 是本机运行时配置
- `TradeNet.SplitRouting.psd1` 是分流源配置
- `mihomo\tradenet-split.yaml` 是实际导入 Clash Verge 的 YAML
- `mihomo\tradenet-clash-merged.yaml` 是可单独导入的“纯 TradeNet” Clash 配置

## 8. 第一次接入 Clash Verge

这一步现在仍然建议人工做一次。

原因很简单：

- Clash Verge 自己会生成本地 profile ID
- 自动化脚本可以覆盖这个文件
- 但第一次“让 Clash Verge 知道这份配置”，手工导入最稳

### 8.1 第一次手工导入

1. 打开 Clash Verge
2. 导入：
   - `D:\TradeNet\mihomo\tradenet-split.yaml`
3. 给这个 profile 取一个容易认的名字，例如：
   - `TradeNet分流`
4. 先手工切换到它一次，确认能被 Clash Verge 正常加载

### 8.2 找到 Clash Verge 实际 profile 文件

导入后，在 PowerShell 执行：

```powershell
Get-ChildItem "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev\profiles" -Filter *.yaml |
  Sort-Object LastWriteTime -Descending |
  Select-Object LastWriteTime,FullName
```

通常最新那一个就是你刚导入的文件。

把这个完整路径填回：

- `Client.ClashVergeProfilePath`

然后把：

- `Client.Deployment.SyncClashProfile = $true`

打开。

### 8.3 打开自动同步以后怎么用

以后每次你重新执行：

- `Install-TradeNetClient.ps1`
- 或 `Setup-TradeNet.ps1 -SkipServer`

脚本都会：

1. 重新生成 `TradeNet.SplitRouting.psd1`
2. 重新生成 `mihomo\tradenet-split.yaml`
3. 调用 Mihomo 做语法校验
4. 自动覆盖 Clash Verge 本地 profile 文件
5. 如果你开了备份，再先做一份 `.bak_时间戳`

注意：

- 这一步是“覆盖已存在的本地 profile 文件”
- 不是“自动在 Clash Verge UI 里新建一个从未导入过的 profile”

## 9. 日常启动方式

日常使用建议顺序：

1. 启动底层栈
2. 打开 Clash Verge
3. 切到 `TradeNet分流`
4. 验证交易软件和目标网站
5. 再开始使用

启动命令：

```powershell
powershell -ExecutionPolicy Bypass -File .\start-tradenet.ps1
```

或者直接双击：

```text
start-tradenet.bat
```

打开仪表板：

```text
Run-TradeNetDashboard.bat
```

停止：

```powershell
powershell -ExecutionPolicy Bypass -File .\stop-tradenet.ps1
```

## 10. 怎么验证部署成功

### 10.1 看客户端预检查报告

检查：

- `D:\TradeNet\artifacts\client-preflight.txt`

重点看：

- 本地二进制路径是否正确
- 渲染出的 `TradeNet WG endpoint`
- `Allowed IPs`
- `Clash Verge sync requested`
- `Clash Verge profile target`

### 10.2 看 Mihomo 日志

重点路径：

- `C:\Users\<你的用户名>\AppData\Roaming\io.github.clash-verge-rev.clash-verge-rev\logs\sidecar\sidecar_latest.log`

如果你看到类似：

```text
[TCP] ... (OFT.Platform.exe) ... using TradeNet[TradeNet-WG]
[UDP] ... (ATASPlatform.exe) ... using TradeNet[TradeNet-WG]
```

就说明交易流量已经进入：

- `TradeNet-WG -> udp2raw -> VPS`

### 10.3 看本地 udp2raw 是否起来

```powershell
Get-Process -Name udp2raw_mp
Get-NetUDPEndpoint -LocalAddress 127.0.0.1 -LocalPort 24008
```

如果你为了绕过旧进程占用，手工把本地监听端口改过，例如改到 `24009`，这里也要改成对应端口检查。

### 10.4 看 VPS 端健康快照

检查：

- `D:\TradeNet\artifacts\server-health.txt`

重点看：

- `wg-quick@wg0` 是否 active
- `udp2raw.service` 是否 active
- 监听端口是否存在

## 11. 常见问题

### 11.1 交易正常，但某些海外网站打不开

先去看 Clash Verge 的 `service_latest.log`。

关键看它是：

- `using TradeNet[TradeNet-WG]`
- 还是 `using DIRECT`

如果它走的是 `DIRECT`，说明规则没覆盖到。

可以补到：

- `TradeNet.SplitRouting.example.psd1`

或者先临时补到：

- `TradeNet.Deployment.psd1 -> SplitRouting -> AdditionalRules`
- `TradeNet.Deployment.psd1 -> SplitRouting -> AdditionalFallbackDomains`

### 11.2 自动部署成功了，但 Clash Verge 没切过去

自动部署只负责：

- 生成 YAML
- 校验 YAML
- 可选覆盖 Clash Verge profile 文件

它不会替你点击 UI 切换当前活动 profile。

所以部署后仍然需要你在 Clash Verge 里：

- 手工选中 `TradeNet分流`

### 11.3 `SyncClashProfile = $true` 但没同步成功

优先检查三件事：

1. `Client.ClashVergeProfilePath` 是否是真正的本地 profile 文件
2. 这个路径所在目录是否存在
3. 这个 profile 是否已经被 Clash Verge 导入过

### 11.4 脚本提示缺少 WireGuard，但我明明只想用 split-routing

现在脚本已经改成：

- 只有在 `InstallWireGuardTunnel = $true` 时，才把 `WireGuard GUI` 当成硬性前置依赖

如果你只是走：

- `udp2raw + Mihomo split-routing`

可以先不安装 tunnel service。

### 11.5 VPS 部署失败怎么看

先看：

- `artifacts\server-install.stdout.log`
- `artifacts\server-install.stderr.log`

再看：

- `artifacts\server-summary.txt`
- `artifacts\server-health.txt`

### 11.6 `wg` 有握手，但海外站点还是不通

优先在 VPS 上检查这三件事：

```bash
sysctl net.ipv4.ip_forward
iptables -t nat -L POSTROUTING -n -v
wg show wg0
```

如果出现下面这种组合：

- `wg show wg0` 能看到最新握手
- `net.ipv4.ip_forward = 0`
- `iptables -t nat` 里的 `MASQUERADE` 计数长期是 `0`

那就说明隧道握手起来了，但 VPS 没把 WireGuard 流量真正转发到公网。

处理方式：

- 先更新到当前仓库版本
- 然后重新执行一次：

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy\Deploy-TradeNetServer.ps1
```

当前版本已经修复了旧部署脚本里布尔参数大小写导致的 `sysctl / firewall / verify` 不生效问题。

## 12. 这一版自动化现在的边界

目前已经自动化的重点是：

- VPS 侧服务部署
- 客户端配置渲染
- Mihomo YAML 校验
- Clash Verge 本地 profile 覆盖同步

目前仍然保留人工步骤的地方，是故意的：

- 第一次导入 Clash Verge profile
- 第一次确认 `Npcap` 网卡
- 第一次确认本地 profile 路径

原因是这三步和具体机器环境绑定很强，盲目全自动反而容易把配置写错。

等第一次落地完成以后，这套项目已经足够支持：

- 换 VPS
- 换本机
- 增补规则
- 一键重建分流配置
- 自动同步到 Clash Verge 本地 profile
