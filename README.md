# 用量圈 · Usage Rings

A tiny macOS widget that shows how much of each AI coding plan you've used: one ring per agent, docked to the edge of the screen or wrapped around the MacBook notch. [English below.](#english)

一个 macOS 小工具：每个 AI 编程订阅一个圆环，贴在屏幕边上或刘海两侧，一眼看到 Codex、Claude、Gemini、Cursor、Copilot、OpenCode Go、Kimi、智谱 GLM、MiniMax 还剩多少额度。完全在本机运行，不需要安装其他软件。

![用量圈：侧边圆环、详情卡、收起状态和灵动岛（示例数据）](docs/screenshot.png)

## 下载安装

1. 到 [Releases](../../releases/latest) 下载 `UsageRings-v*-macOS.zip`，解压后把「用量圈」拖进「应用程序」。支持 Apple 芯片和 Intel，需要 macOS 14 或更新版本。
2. 这个 App 没有经过苹果公证，第一次打开会被系统拦下：打开「系统设置 → 隐私与安全性」，在下方找到「用量圈」，点「仍要打开」。也可以在终端执行：
   ```bash
   xattr -dr com.apple.quarantine /Applications/用量圈.app
   ```
3. 打开后圆环出现在屏幕左侧。右键圆环 →「设置…」可以调整外观、填写 API Key、打开提醒和开机启动。

## 功能

- **侧边圆环**：贴在屏幕左边或右边，可以拖动；拖过屏幕中线会自动吸附到另一边，拖到另一块显示器就停在那块，位置会记住
- **灵动岛**：刘海两侧显示迷你圆环，鼠标移上去会展开，显示全部详情。MacBook 外接显示器时，灵动岛会待在有刘海的那块屏幕上
- **收起**：点一下缩成屏幕边缘的一条细竖条，彩色小点表示各家状态
- **详情卡**：悬停或点击圆环，显示每个额度（5 小时 / 日 / 周 / 月，以及 Claude 的 Sonnet / Opus 周额度、Gemini 各模型的每日额度、Copilot 的高级请求等）的用量和重置倒计时
- **额度提醒**：用量超过设定比例（70% / 80% / 90%）时发一条系统通知，用完的额度重置后再提醒一次；每个周期最多提醒一次
- **节奏预测**：每个额度按目前的速度，算出多久后用完、能不能撑到重置
- **谁在烧额度**：读取 Claude Code 和 Codex 的本地会话记录，算出当前周期里每个会话（项目）占了多少（按 token 加权估算，只统计真正走订阅的模型）
- **下一个用谁**：在撑得到重置的账号里推荐最宽裕的那个，圆环上会出现小星标
- **登录失效时**：继续显示最后一次读到的数据，并标明是什么时候的；Codex 断网或登录过期时直接读它自己的本地记录
- **可定制**：大中小三种尺寸；显示"已用"或"剩余"；红绿灯配色或品牌色；透明度；单独隐藏某家；选择显示器；刷新间隔；开机启动
- **中文 / English**：界面跟随系统语言，也可以在设置里手动切换
- **自动适配**：服务很多、屏幕放不下时，侧边圆环自动缩小，展开的灵动岛自动换行；支持 VoiceOver 朗读和"降低透明度"

## 数据来源

| 服务 | 读取的本机登录 | 请求的接口 |
|---|---|---|
| Codex | `~/.codex/auth.json` | `chatgpt.com/backend-api/wham/usage` |
| Claude | 钥匙串 `Claude Code-credentials`（Claude Code 命令行登录） | `api.anthropic.com/api/oauth/usage` |
| Gemini CLI | `~/.gemini/oauth_creds.json`（Gemini CLI 的 Google 登录） | `cloudcode-pa.googleapis.com` 的 `retrieveUserQuota` |
| Cursor | Cursor.app 的 `state.vscdb`（只读打开） | `cursor.com/api/usage-summary` |
| GitHub Copilot | `~/.config/github-copilot/apps.json` / `hosts.json`（Neovim、JetBrains、Xcode 等编辑器插件的登录），或设置里填的令牌 | `api.github.com/copilot_internal/user` |
| OpenCode Go | `~/.local/share/opencode/auth.json` | `opencode.ai/zen/go/v1/usage` |
| Kimi Code | 设置里填的 API Key、Claude Code 设置，或 `~/.kimi-code/credentials/kimi-code.json` | `api.kimi.com/coding/v1/usages` |
| 智谱 GLM Coding Plan | 设置里填的 API Key、环境变量或 Claude Code 设置 | `open.bigmodel.cn` 或 `api.z.ai` 的 `/api/monitor/usage/quota/limit` |
| MiniMax Coding Plan | 设置里填的 API Key、环境变量或 Claude Code 设置 | `api.minimaxi.com` 或 `api.minimax.io` 的 `coding_plan/remains` |

- 只**读取**各家官方工具已经保存在本机的登录，从不刷新或改写令牌；令牌只发给对应的官方 HTTPS 地址，并且拒绝重定向。
- **Claude Code 设置**：如果你让 Claude Code 走 GLM、Kimi 或 MiniMax 的套餐（手动改 `~/.claude/settings.json`，或用 CC Switch 切换），里面的 `ANTHROPIC_BASE_URL` 和 key 会被自动识别，不用再填一遍。只认这几家的官方域名。
- 智谱和 MiniMax 的国内站、国际站都支持，第一次会自动试出 key 属于哪边，之后直接用那边。
- 这些接口都是各家没有公开文档的内部接口，以后可能随时变化。
- 会话统计会逐行解析 `~/.claude/projects` 和 `~/.codex/sessions` 里的会话记录，但只取 token 数、时间和项目目录，对话内容不保存、不上传。每次刷新只读新增的部分。
- 默认只用内置方式，**不需要安装任何其他软件**。
- Gemini CLI 的登录 1 小时就过期，只在你使用 Gemini CLI 时有效，其余时间显示最后一次的读数。Google 已停止个人免费版的 Gemini CLI，Workspace 和付费的 Code Assist 账号仍然可以读到。
- Kimi 命令行的登录 15 分钟就过期，只在你使用 Kimi 时有效；想一直读到，在设置里填一个 [Kimi Code API Key](https://www.kimi.com/code/console)。API key 只保存在本机 `~/Library/Application Support/UsageRings/keys.json`（权限 600）。
- 某家暂时读不到时，显示最后一次的读数并标明时间；期间已经过了重置时间的额度会直接归零。
- 可选：装了 [CodexBar](https://github.com/steipete/CodexBar) 的话，可以在设置里把数据来源切到"内置 + CodexBar"，让它补上内置读不到的服务（支持 100 多家）。

## 从源码构建

需要 macOS 14+、Xcode 16+（Swift 6）。

```bash
zsh scripts/package.sh            # 编译、安装到 ~/Applications/用量圈.app 并启动
zsh scripts/package.sh --no-launch
zsh scripts/release.sh            # 跑测试，打包通用版到 dist/ 并生成发布用的 zip 和 sha256
swift test
```

右键圆环可以刷新、收起、切换左右或打开设置。

开发时可以用截图模式检查布局，它把所有样式渲染成 PNG：

```bash
swift build -c release && .build/release/UsageRings --snapshot /tmp/rings              # 真实数据
swift build -c release && .build/release/UsageRings --snapshot /tmp/rings --demo       # 示例数据
swift build -c release && .build/release/UsageRings --snapshot /tmp/rings --demo-all --lang en   # 全部服务、英文界面
```

核心逻辑（各家接口解析、会话统计、提醒、布局计算）不依赖 AppKit，在 Linux 上也能 `swift test`。

**发布流程**：改 `scripts/package.sh` 里的 `version`，在 [CHANGELOG.md](CHANGELOG.md) 写好这一版的说明，打一个同名标签推上去（例如 `git tag v0.6.0 && git push origin v0.6.0`），GitHub Actions 会跑测试、打包通用版并自动发布 Release。每次推送也会在 CI 里编译、测试并产出可下载的 App。

## English

Usage Rings is a small floating widget for macOS 14+ that draws one ring per AI coding subscription, showing how much of each quota window (5-hour, weekly, monthly, model-specific) is used and when it resets.

- **Services built in:** Codex, Claude Code, Gemini CLI, Cursor, GitHub Copilot, OpenCode Go, Kimi Code, Z.ai / Zhipu GLM Coding Plan and MiniMax Coding Plan. Anything else can come from [CodexBar](https://github.com/steipete/CodexBar) if it's installed.
- **Read-only:** it reuses the logins those tools already saved on your Mac (or an API key you paste into Settings), never refreshes or rewrites tokens, sends them only to that service's own HTTPS API, and refuses redirects. If Claude Code is pointed at GLM, Kimi or MiniMax (by hand or with CC Switch), the key in `~/.claude/settings.json` is picked up automatically.
- **Two looks:** rings docked to a screen edge (any display, draggable, collapsible) or a "Dynamic Island" around the notch that expands on hover.
- **Insights:** pace forecast (will this window last until it resets?), which local Claude Code / Codex session is burning the quota, and a hint for which subscription to use next.
- **Alerts:** a notification when a quota passes 70/80/90% and when a used-up quota resets.
- **Chinese or English** interface (follows the system language, or pick one in Settings), VoiceOver labels and Reduce Transparency support.

Install: download `UsageRings-v*-macOS.zip` from [Releases](../../releases/latest), move the app to Applications, and since it isn't notarized, allow it once under System Settings → Privacy & Security (or run `xattr -dr com.apple.quarantine /Applications/用量圈.app`). Right-click a ring for Settings.

Build: `zsh scripts/package.sh` (needs Xcode 16+). Tests: `swift test` — the core logic also builds and tests on Linux.

## 致谢

各家用量接口的地址和格式参考了 [CodexBar](https://github.com/steipete/CodexBar)（MIT）的文档和实现。本项目没有包含 CodexBar 的代码。

## 许可证

MIT，见 [LICENSE](LICENSE)。
