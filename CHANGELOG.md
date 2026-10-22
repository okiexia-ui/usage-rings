# 更新日志 · Changelog

## 0.6.0

### 新增服务
- **智谱 GLM Coding Plan**：国内 bigmodel.cn 和国际 z.ai 都支持，自动识别 key 属于哪边。
- **MiniMax Coding Plan / Token Plan**：国内 minimaxi.com 和国际 minimax.io 都支持。
- **GitHub Copilot**：读取编辑器插件（Neovim、JetBrains、Xcode 等）保存的登录，也可以在设置里填令牌；显示高级请求，免费版显示对话和补全额度。
- **Cursor**：只读打开 Cursor.app 自己的状态数据库，显示本计费周期的额度。
- **Gemini CLI**：读取 Gemini CLI 的 Google 登录，按 Pro / Flash / Flash Lite 显示每日额度（Workspace 和付费 Code Assist 账号；个人免费版已被 Google 停用）。
- **Claude 按模型的周额度**（Sonnet / Opus），套餐有时自动显示。
- 让 Claude Code 走 GLM、Kimi 或 MiniMax 套餐时（手动或 CC Switch），自动从 `~/.claude/settings.json` 读出 key，不用再填。

### 适配
- 中文 / English 界面，跟随系统或手动切换。
- 多显示器：侧边圆环可以放在任意一块屏幕上（设置里选，或直接拖过去）；MacBook 外接显示器时灵动岛待在有刘海的屏幕上。
- 服务很多时侧边圆环自动缩小、展开的灵动岛自动换行，不会超出屏幕。
- VoiceOver 朗读每个圆环的全部额度；支持"降低透明度"。
- App 图标。

### 优化
- 会话统计按文件缓存，每次刷新只解析新增的行，大量会话记录时 CPU 和磁盘读取明显减少。
- 日期解析复用格式化器；CodexBar 查询不再占用并发线程。
- 修复：手动刷新和定时刷新同时进行时，较慢的旧结果可能覆盖新结果。
- 睡眠唤醒后、额度重置后会立即刷新，不用等下一个刷新周期。
- 额度提醒：超过设定比例时提醒一次，用完的额度重置后再提醒。

### 交付
- 每次推送由 GitHub Actions 在 macOS 上编译、测试、打包通用版，并在 Linux 上测试核心逻辑。
- 推送 `v*` 标签自动发布 Release（附 sha256）。

---

### New services
- Z.ai / Zhipu GLM Coding Plan (bigmodel.cn and z.ai) and MiniMax Coding / Token Plan (minimaxi.com and minimax.io), from a pasted key, the environment, or Claude Code's `settings.json` (as written by hand or by CC Switch).
- Gemini CLI's daily Pro / Flash / Flash Lite quotas from its Google login; GitHub Copilot from the editor plugins' login; Cursor from Cursor.app's own database, read-only.
- Claude's model-specific weekly limits.

### Adaptations
- Chinese / English interface; any display for the side rings, the notched display for the island; long lists shrink or wrap to fit; VoiceOver and Reduce Transparency; an app icon.

### Optimizations
- Incremental transcript scanning, cached date formatters, no stale refresh overwriting a newer one, refresh after wake and after resets, quota alerts.

## 0.5.1
- 灵动岛填满刘海并避开菜单栏图标；设置里的输入框支持粘贴；发布打包、示例截图和安装说明。

## 0.5.0
- 节奏预测、按会话统计用量、推荐下一个用谁；内置读取 Codex、Claude、OpenCode Go、Kimi Code，默认不再依赖 CodexBar。

## 0.4 及更早
- 侧边圆环、设置、收起、拖动停靠和灵动岛；最初通过 CodexBar 读取用量。
