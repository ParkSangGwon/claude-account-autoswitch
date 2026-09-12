<p align="center">
  <img src="Resources/AppIcon.iconset/icon_256x256.png" width="128" alt="Claude AutoSwitch 图标">
</p>
<h1 align="center">Claude AutoSwitch</h1>
<p align="center">
  多个 Claude 订阅，一个 Claude Code。一款菜单栏应用，在各账户额度用满时<br>
  自动轮换账户，并让你一眼看清每个账户的配额。
</p>
<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-000?logo=apple&logoColor=white">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
  <img alt="无需安装 Node 或 CLI" src="https://img.shields.io/badge/runtime-none%20needed-2ea44f">
  <img alt="7 种语言" src="https://img.shields.io/badge/languages-7-3b82f6">
  <a href="LICENSE"><img alt="MIT" src="https://img.shields.io/badge/license-MIT-lightgrey"></a>
</p>
<p align="center" data-readme-switcher>
  <a href="README.md">English</a> · <a href="README.ko.md">한국어</a> · <a href="README.ja.md">日本語</a> · 简体中文 · <a href="README.de.md">Deutsch</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a>
</p>

<p align="center">
  <img src="docs/assets/menubar/menubar-item.png" width="440" alt="菜单栏项：系统图标旁的 3h18m 33%">
</p>
<p align="center">
  <img src="docs/assets/menubar/popover-dark.png" width="406" alt="弹出面板：账户表、全部账户条形图、路由、会话和轮换日志">
</p>

## 问题

**一个 $200 的 Max 套餐已经不够用了，于是你付着两三个的钱。**<br>
身处其中的人，每天是这样过的。

#### 订了两个 Max 套餐的自由职业者

> “每天下午都是同一行：`You've hit your usage limit · resets at 4pm`。<br>
> 打开浏览器，登出，登录，回到终端，再找回刚才做到哪了。”

一天两三回，每回五分钟。<br>
一个月下来，半天就这么没了。

#### 装了账户切换工具的那位

> “它省了我一次点击，可什么时候该点，它不会告诉我。<br>
> 上限还是我自己盯，切换还是我自己动手。”

#### 跑着轮换 TUI 的那位

> “切换是自动了，看余量可没有。<br>
> 那是另一个终端、另一条命令，就开在我真正干活的那个终端旁边。”

**“我就不能……”**

- **……直接用两个账户？** 可以。只是每次撞上上限，负责切换的都是你。
- **……装个切换器？** 它把切换缩短成一下点击。可什么时候切、切到哪个账户，仍然得你自己拿主意。
- **……跑一个会轮换的 TUI？** 它们确实会轮换。可用量也跟着留在了一个你必须一直开着的终端里。

**是不是很耳熟？**

- [ ] 你付着不止一个 Max 套餐的钱。
- [ ] 一条上限提示就把你直接送进浏览器。
- [ ] 你有时想不起某个终端用的是哪个账户。
- [ ] 你打开一个终端，只为看看还剩多少。
- [ ] 每周上限每次都让你措手不及。

中了三条以上，下一节就是为你写的。

## 解决方案

Claude AutoSwitch 是一个带菜单栏的本地代理。<br>
登录两个或更多 Claude 账户，把 Claude Code 指向 `http://127.0.0.1:10912`。<br>
之后每个请求都会带着仍有余量的账户的令牌发出。<br>
当某个账户达到 5 小时或每周限额时，下一个请求就直接换用另一个账户。<br>
Claude Code 不会登出、不会重启，也毫无察觉。<br>
每个账户的配额都在菜单栏里，你再也不用为了看一眼而打开终端。

它不是账户*切换器*：钥匙串里什么都不会被替换，也没有任何会话会被打断。<br>
轮换按请求进行，在触及限额之前发生，多个终端可以同时使用不同的账户。

## 安装

要求：macOS 14 Sonoma 或更高版本，以及 Claude Code。<br>
无需安装 Node、npm 包或其他代理。

### Homebrew

```sh
brew install --cask ParkSangGwon/tap/claude-autoswitch
```

安装后如果 macOS 拒绝打开应用，清除隔离标记：`xattr -dr com.apple.quarantine "/Applications/Claude AutoSwitch.app"`（或按下文所述点击“仍要打开”）。

### GitHub Release

从[最新版本](https://github.com/ParkSangGwon/claude-account-autoswitch/releases/latest)下载 `Claude-AutoSwitch-vX.Y.Z.zip`。<br>
解压后把 **Claude AutoSwitch.app** 拖到 `/Applications`。

### 从源码构建

```sh
git clone https://github.com/ParkSangGwon/claude-account-autoswitch
cd claude-account-autoswitch
make install          # builds dist/Claude AutoSwitch.app and copies it to /Applications
```

应用为 ad-hoc 签名，未经公证。<br>
首次启动时 macOS 可能提示无法验证开发者。<br>
打开**系统设置 → 隐私与安全性**，点击**仍要打开**，或右键点击应用 → **打开**。

## 三步完成设置

1. **添加账户。** 设置 → 账户 → *添加账户…*
   - 通过浏览器登录。
   - 在浏览器无法访问此 Mac 时粘贴代码。
   - 导入 Claude Code 已有的登录（钥匙串）。
2. **让 Claude Code 使用代理。** 只需一行，显示在设置 → 代理下，旁边有拷贝按钮：
   ```sh
   export ANTHROPIC_BASE_URL=http://127.0.0.1:10912
   ```
   把它放进 shell 配置，或使用*在终端中打开 Claude Code*。
3. **打开“登录时启动”**（设置 → 通用），这样只要 Claude Code 在，代理就在。

设置就这么多。<br>
Claude Code 保留自己的登录。<br>
代理只在请求发出时替换令牌，请求中的其他一切保持不变。

## 你能得到什么

- **一个直接显示用量的菜单栏项。**
  - `1h12m 42%` 是全部账户的 5 小时窗口：先是距离重置的时间，再是已用的比例。下方的条形图分别是 5 小时和每周。
  - 条形图超前于其窗口时为橙色，达到切换阈值或无账户可服务时为红色。
  - 轮换时显示 `→ par` 六秒，监听停止时显示 `—`。
- **每个账户一目了然。**
  - 会话、每周和按模型系列（Fable、Sonnet）的条形图，每条下方标有数值和重置时间。
  - 层级、优先级、受限倒计时，以及固定到该账户的会话。
  - 行菜单：设为当前、启用、优先级、移除。
- **下一个请求去哪里，以及为什么。**
  - 原账户的原因、更高的优先级，或“仍使用 ted”。
- **全部账户汇总和重置时间线。**
  - 按层级加权的汇总。
  - 每一次即将到来的窗口重置，能让账户重新加入轮换的标有 `↑`。
- **能应对真实情况的轮换。**
  - 指明窗口已关闭的 429 会按其 retry-after 让账户受限。
  - 普通 429 会短暂让位。
  - 过期令牌刷新一次后重试。
  - 403 和 5xx 故障转移。
  - 所有账户耗尽时，请求可以挂起一段可配置的时间，而不是直接失败。
- **会话。**
  - 每个 Claude Code 会话按每周配额桶固定在自己的账户上。
  - 可选的均匀分配会把新会话分给负载最低的账户。
- **随时随地切换。**
  - 弹出面板中的账户菜单、右键菜单，或按 `⌃⌥⌘N` 切换到下一个可服务的账户。
  - `⌃⌥⌘T` 打开弹出面板。
- **有意义的通知。**
  - 全部账户阈值、附原因的轮换、账户退出或重新加入轮换。
  - 需要重新登录、探测失败、挂起、超额计费。
  - 可以暂停 1 小时。
- **七天历史。**
  - 应用运行时每分钟一个样本：全部账户的迷你趋势图和每个账户的状态条，保存在本地。
- **说你的语言。**
  - English、한국어、日本語、简体中文、Español、Deutsch、Français。
  - 跟随 Mac 的语言列表，也可在应用内直接切换。

## 图库

#### 账户
<img src="docs/assets/menubar/settings-accounts.png" width="780" alt="账户面板">

#### 轮换
<img src="docs/assets/menubar/settings-rotation.png" width="780" alt="轮换面板：切换阈值、按配额桶的阈值、会话分配、耗尽时挂起">

#### 代理
<img src="docs/assets/menubar/settings-proxy.png" width="780" alt="代理面板：监听状态和 Claude Code 需要的那一行">

#### 通用
<img src="docs/assets/menubar/settings-general.png" width="780" alt="通用面板：菜单栏样式、语言、刷新、快捷键、通知">

## 菜单栏项

| 标题 | 含义 |
| --- | --- |
| `1h12m 42%` | 全部账户的 5 小时窗口将在 1h12m 后重置，已用 42%。下方条形图为 5 小时（上）和每周（下）。 |
| `ted 1h12m 42%` | 固定显示当前账户（设置 → 通用）：其三字母标签置于标题开头。 |
| `1h12m 42% · 3d12h 61%` | *条形图 + 5h · 7d* 样式：连每周窗口也一并显示。 |
| `1h12m 93%!` | 严重：已达切换阈值，或无账户可服务。 |
| `→ par` | 刚发生了一次轮换；显示六秒。 |
| `—` | 监听已停止（通常是端口被占用）。 |
| `0%` | 尚无账户。 |

## 快捷键

| 按键 | 位置 | 作用 |
| --- | --- | --- |
| `⌃⌥⌘N` | 任意位置 | 切换到下一个可用账户 |
| `⌃⌥⌘T` | 任意位置 | 显示或隐藏弹出面板 |
| `⌘R` `⌘T` `⌘,` `⌘Q` | 弹出面板 | 刷新 · 在终端中打开 Claude Code · 设置 · 退出 |
| 右键点击菜单栏项 | 菜单栏 | 切换、刷新、重新加载配置、暂停通知 |

## 工作原理

- 应用在 `127.0.0.1` 上运行一个 HTTP/1.1 监听（SwiftNIO）。
- 发往自身控制平面以外任何路径的请求都会转发到 `https://api.anthropic.com`，并用所选账户的 `Authorization` 替换客户端的。
- 其他所有请求头原样透传，`metadata.user_id` 标明令牌所属的账户。
- 响应到达时即流式返回。
- 账户先按优先级选择，再按最早重置的每周窗口选择。
- 已停用、受限、达到上限、出错，或在该请求的模型系列上已达阈值的账户都会被跳过。
- 每个响应中的 `anthropic-ratelimit-*` 响应头让各账户的窗口保持最新。
- 对用量端点的后台探测补上空闲账户的数据。
- 令牌在过期前五分钟刷新。
- 配置位于 `~/Library/Application Support/Claude AutoSwitch/config.json`，以 `0600` 权限原子写入。
- 令牌只存在于该文件中，别无他处。

配置文件、健康检查端点和轮换规则的参考见 [docs/reference.md](docs/reference.md)。

## 隐私

只会联系两个主机：Claude API（你的请求、用量探测、令牌刷新），以及登录期间的 claude.ai / platform.claude.com。<br>
没有遥测，没有更新检查。<br>
导出诊断信息时会在写入前替换所有机密。

## 关于服务条款的说明

在多个个人订阅之间轮换请求，可能超出 Anthropic 消费者条款的本意。<br>
本项目向你展示自己账户的配额，如何使用由你决定。<br>
请阅读适用于你套餐的条款。

## 文档

- [docs/troubleshooting.md](docs/troubleshooting.md)：Gatekeeper、端口被占用、重新登录、与其他工具共用的令牌。
- [docs/reference.md](docs/reference.md)：配置文件、健康检查端点、轮换规则。
- [CHANGELOG.md](CHANGELOG.md)：每个版本的变更。

## 开发

```sh
swift build
swift test            # engine tests run against loopback stand-ins for the Claude API
make app              # dist/Claude AutoSwitch.app
AUTOSWITCH_DEBUG_DEMO_QUOTA=1 CLAUDE_AUTOSWITCH_CONFIG=/tmp/demo.json swift run ClaudeAutoSwitch
```

- `AutoSwitchCore`：模型（账户、窗口、阻塞项）、规则（调度、节奏、全部账户汇总）、本地化和配置文档。
- `AutoSwitchEngine`：代理，包含账户、OAuth、配额、轮换和监听。
- `ClaudeAutoSwitch`：应用。
- 字符串位于 `Sources/AutoSwitchCore/Resources/<lang>.lproj/Localizable.strings`，以英文文本为键。
- 源码中的字符串若在其中没有对应行，测试会失败。
- `AUTOSWITCH_DEBUG_WINDOW=<section>` 和 `AUTOSWITCH_DEBUG_APPEARANCE=light|dark` 可打开某个设置面板和弹出面板以便截图。
- `README.md` 和旁边的六个翻译版本一同修改；结构出现偏差时 `scripts/check-readmes.sh` 会失败。

## 许可证

MIT。
