# v2rayN 7.x 自动换最快的 IP

一个独立的 PowerShell 脚本：**定时把 v2rayN 的出口节点切换到一个延迟最低、且与当前不同的节点**，让 Google 看到的出口 IP 保持"新鲜"。

不需要跑 scraper、不依赖任何爬虫项目——只要这台电脑装了 v2rayN 7.x 就能用。

---

## 它是干什么的

脚本每隔一段时间（默认 30 分钟）做一件事：

1. 读取 v2rayN 的节点数据库，找出所有延迟 ≤ 500ms 的快节点
2. 从里面挑一个**跟当前不同**、且最近几次没用过的节点
3. 停掉 v2rayN → 改配置 → 重启 → 验证 socks 端口和 Google 连通性
4. 失败自动回滚到原节点

### 为什么不直接"挑最快的"

因为当前激活的节点通常**已经就是最快的**，字面意义上的"挑最快"等于永远不换。所以脚本是在快节点池里**轮换出口身份**，而不是去追那几毫秒延迟差。

> 换 IP 解决的是"这个出口被 Google 标记了"，不是"网速慢"。它不保证提高速度，也不保证消除验证码——频繁换出口反而可能被识别成机器人。请按需设置间隔。

---

## 要求

| 项 | 要求 |
|---|---|
| 系统 | Windows + PowerShell 5.1（系统自带） |
| 客户端 | **v2rayN 7.x（xray 内核）** — 不是 Clash/mihomo，切节点机制不同 |
| Python | **Python 3**（用来读节点的 sqlite 数据库，标准库就够，无需 pip 安装） |

脚本依赖 v2rayN 7.x 的这两个文件：
- `guiConfigs\guiNDB.db`（节点表 `ProfileItem` / `ProfileExItem`）
- `guiConfigs\guiNConfig.json`（当前节点 `IndexId`）

---

## 快速开始

### 1. 拷贝脚本

把 `proxy-fastest-rotate.ps1` 放到任意目录（放哪都行，日志会写在它旁边）。

### 2. 自检（不改任何东西）

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\proxy-fastest-rotate.ps1" -ProbeOnly
```

输出类似这样，最后出现 `READY.` 就说明环境探测正常：

```
ENV: v2rayN  = F:\v2rayN-windows-64\v2rayN-windows-64
ENV: python  = C:\Users\你\AppData\Local\Programs\Python\Python312\python.exe
POOL: 31 fast nodes (<=500ms)
  CUR 68ms CF官方优选28 172.64.229.146:443
      90ms CF官方优选13 172.64.229.135:2083
      ...
PROBE ONLY -> no change. READY.
```

`CUR` 标记的是当前节点。如果探测不到路径，看下面"路径探测"一节。

### 3. 试运行（dry-run，不真换）

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\proxy-fastest-rotate.ps1" -WhatIfOnly
```

它会打印选中了哪个节点，但**不停止进程、不改文件**。确认逻辑对了再往下。

### 4. 注册定时任务（真正自动运行）

在 PowerShell 里执行（把路径换成你实际的）：

```powershell
$script = "D:\你的路径\proxy-fastest-rotate.ps1"
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`"")
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
  -RepetitionInterval (New-TimeSpan -Minutes 30) `
  -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 6) `
  -MultipleInstances IgnoreNew -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
  -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName 'V2rayN-Fastest-IP-Rotator' `
  -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force
```

> **注意**：PowerShell 5.1 创建重复触发器必须用上面 `-RepetitionInterval` 的写法；直接给 `$trigger.Repetition.Interval` 赋值会报 `PropertyNotFound`。

确认任务状态：

```powershell
Get-ScheduledTaskInfo -TaskName 'V2rayN-Fastest-IP-Rotator'
```

`LastResult = 0` 表示上次运行成功。

---

## 路径探测

脚本按以下顺序自动找 v2rayN 和 Python，正常情况不用配置：

| 目标 | 顺序 |
|---|---|
| v2rayN | 参数 `-V2rayDir` → 环境变量 `V2RAYN_DIR` → 卸载注册表 → 常见安装路径 |
| Python | 参数 `-PyExe` → 环境变量 `PYTHON_EXE` → PATH 里的 `python.exe` / `py.exe` |

如果自动探测失败，设环境变量或传参数即可：

```powershell
# 方式一：环境变量
$env:V2RAYN_DIR = "D:\v2rayN-windows-64\v2rayN-windows-64"
$env:PYTHON_EXE = "C:\Users\你\AppData\Local\Programs\Python\Python312\python.exe"

# 方式二：参数
powershell.exe -File ".\proxy-fastest-rotate.ps1" -V2rayDir "D:\..." -PyExe "C:\..."
```

---

## 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `-ProbeOnly` | 关 | 只探测环境 + 列出快节点 top5，不检查冷却、不切换 |
| `-WhatIfOnly` | 关 | dry-run：选节点但只打印，不动进程和文件 |
| `-Force` | 关 | 忽略冷却时间，强制走一遍（测试用） |
| `-IntervalMin` | 30 | 两次轮换之间的最小间隔（分钟） |
| `-RecentExclude` | 3 | 不轮换回最近用过的 N 个节点 |
| `-MaxLatencyMs` | 500 | 候选节点的延迟上限（毫秒） |
| `-V2rayDir` / `-PyExe` | 自动探测 | 手动指定安装路径 |

---

## 产生哪些文件

全部写在**脚本所在目录**，不往别处写：

| 文件 | 用途 |
|---|---|
| `_proxy_rotate.log` | 运行日志 |
| `_proxy_rotate_state.json` | 上次切换时间 + 历史节点 |
| `_proxy_rotate_backup\` | 切换前的配置备份 |
| `_proxy_rotate.lock` | 运行锁（结束后自动删除） |

切换前会备份 `guiNConfig.json`；验证失败（socks 不通或 Google 204 失败）会自动回滚并重启原来的节点。

---

## 注意事项

- 每次切换会 **kill 并重启 v2rayN，断网约 15 秒**，正在进行的下载/抓取会中断。
- 如果同时运行了别的会切节点的脚本，两个脚本可能冲突。本脚本会检查 `_proxy_switch.lock`，5 分钟内有其他切换动作就跳过本轮。
- 换 IP 不解决 captcha 本身；如果目标是绕过 Google 风控，频繁切换可能适得其反。
- 只支持 **xray 内核的 v2rayN 7.x**。Clash / mihomo / v2rayN 6.x 不适用。
