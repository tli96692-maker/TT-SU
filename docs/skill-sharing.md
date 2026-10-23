# 如何让别人找到、安装和更新 TT中枢 skill

## 先区分两个交付物

| 交付物 | 给谁使用 | 如何安装 |
|---|---|---|
| SketchUp Core 插件 `su_zhongshu-core.rbz` | 在 SketchUp 里使用面板和建模工具的人 | 从 GitHub Release 下载，通过 SketchUp 扩展管理器安装 |
| Codex skill `tt-su-hub` | 想让 Codex 协助安装、排障、检查更新或维护源码的人 | 用 Codex 的 `$skill-installer` 安装仓库内 `skills/tt-su-hub` |

安装 skill 不会自动安装 SketchUp 插件、REA 或第三方插件，也不会自动获得 SketchUp 模型控制能力。只使用 TT中枢面板的人不需要安装 skill。

## 链接在哪里

本次选用账号 `tli96692-maker` 新建目标仓库 `TT-SU`，skill 名称仍为 `tt-su-hub`。以下链接使用这个目标仓库名称；首次分享前须确认仓库公开、源码已推送且 Release 已发布。这份说明本身不表示这些线上步骤已经完成。

| 用途 | 地址 |
|---|---|
| 产品主页 | [TT中枢 / TT-SU](https://github.com/tli96692-maker/TT-SU) |
| 插件下载与历史版本 | [Releases](https://github.com/tli96692-maker/TT-SU/releases) |
| skill 目录与安装来源 | [skills/tt-su-hub](https://github.com/tli96692-maker/TT-SU/tree/main/skills/tt-su-hub) |
| 问题反馈 | [Issues](https://github.com/tli96692-maker/TT-SU/issues) |

测试版下载入口建议分享 `/releases` 或指定版本的 Release 链接。GitHub 的 `/releases/latest` 不一定指向最新预发行，不适合作为 beta 唯一入口。

别人可以在 GitHub 搜索 `TT-SU`、`tt-su-hub`、`TT中枢`，或搜索 `TT-SU user:tli96692-maker` 缩小范围。仓库的 Description、README 应同时出现中英文名称，并添加 `sketchup`、`sketchup-extension`、`codex-skill` 等相关 topics。公开仓库便于检索，但搜索收录时间和排序不能保证；直接分享完整仓库链接最确定。[GitHub 仓库搜索说明](https://docs.github.com/en/search-github/searching-on-github/searching-for-repositories)

## 别人在 Codex 中怎样安装

仓库公开且源码推送后，对方可以把以下内容发给支持本地 skill 的 Codex：

```text
$skill-installer 请安装这个 GitHub skill：
https://github.com/tli96692-maker/TT-SU/tree/main/skills/tt-su-hub
```

需要固定版本时，将 `main` 改成已经存在且含此目录的 tag，例如 `v0.2.3-beta.1`。安装器只下载 skill 目录，不会自动下载整套插件源码或 RBZ。安装后在下一轮输入：

```text
$tt-su-hub 帮我安装 TT中枢 Core，并检查当前 SketchUp 是否兼容。
```

新安装技能通常会被自动发现；若未出现，重启 Codex 后再试。官方支持使用安装器从其他仓库安装本地技能。[OpenAI 技能说明](https://learn.chatgpt.com/docs/build-skills)

## 你更新以后，对方怎样更新

**RBZ 更新和 skill 更新是两个独立流程。** 发布新版 RBZ 后，SketchUp 面板可以检查并提示用户下载；这个操作不会修改 Codex 安装的 skill。仅修改 skill 文档时，也无需伪造一个新的 RBZ 版本。

维护者修改 `skills/tt-su-hub/` 后提交 GitHub，并在发行说明中记录 skill 的变化。使用者安装的是当时的副本，默认不会持续拉取 main。现有 `skill-installer` 遇到同名目标目录会停止，不提供静默覆盖。

让使用者给 Codex 这样的更新请求：

```text
请更新我安装的 tt-su-hub skill，来源为：
https://github.com/tli96692-maker/TT-SU/tree/main/skills/tt-su-hub
先定位当前实际安装目录，把旧版本完整备份到技能扫描目录以外，保留我的改动；
验证备份后将原目录移出技能扫描位置，确保安装目标不存在，再用 skill-installer 安装新版。
检查 SKILL.md 和引用文件完整性，失败时恢复旧版。
```

默认安装位置由该用户的 `CODEX_HOME` 决定，未设置时通常是用户目录下 `.codex/skills/tt-su-hub`。不要复制开发者电脑的绝对路径。备份放在扫描目录外，可以避免旧版被重复识别；存在本地改动时，保留差异后再决定是否迁入新版。

## GitHub 分享与官方目录上架

公开 GitHub 仓库、可从链接安装、在 Codex 官方插件目录中搜索到，是不同阶段。当前交付的是仓库中的独立 skill；公开仓库不会自动加入 OpenAI 的 curated skills 或官方插件目录。当前没有宣称已提交或已上架。

仓库首发与 SketchUp 包更新步骤见 [GitHub 发布指南](github-setup.md)。
