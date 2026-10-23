# TT中枢 0.2.3-beta.1 · 核心测试版

- 新增“关于与更新”：显示版本、渠道、仓库和检查结果；用户确认后打开 GitHub Release 下载页面。
- 新增独立 Core 包：宿主、7 个内置工具、诊断界面；第三方工具改为官方入口。
- 补充 MIT LICENSE、第三方声明、可独立构建的公开源码和 GitHub 检查/草稿发行流程。
- 提供 `tt-su-hub` Codex skill，包含安装、排障、更新与源码维护指引；skill 和 RBZ 分别安装及更新。
- 增加版本准备工具：先预览，再备份并同步版本与渠道；不代替测试、签名或公开发行。
- 修复 Lite 包省略 ZIP 后仍显示无效安装入口的问题。

兼容声明：Windows / SketchUp 2024。尚未完成全部成熟化任务；AI 出图、插件内自动下载安装/恢复、完整第三方分发不在此版本范围。

下载 `su_zhongshu-core.rbz`，使用扩展程序管理器安装并重启。`release-manifest.json` 与 `SHA256SUMS.txt` 对应同一份最终 RBZ；Source code ZIP 不能直接安装。

维护者在公开前应完成 `docs/public-release-checklist.md`，补写真实原生验证结果与签名状态。此模板不表示 GitHub 工作流、其他用户电脑或扩展签名已经通过验收。
