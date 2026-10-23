# TT中枢：第一次发布，以及以后如何让用户更新

## 你需要准备什么

产品显示名是 **TT中枢**，本次按用户选择，在 **`tli96692-maker`** 账号下新建目标仓库 **`TT-SU`**：[仓库主页](https://github.com/tli96692-maker/TT-SU)。公开源码包文件名与 Codex skill 仍采用 `tt-su-hub`。中文名称写在 README、Description 和 Release 标题中即可。[GitHub 新建仓库说明](https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-new-repository)

`src/release.json` 的 repository 应为 `tli96692-maker/TT-SU`。工作流构建时还会用真实的 `github.repository` 写入 RBZ。首次分享前须核实仓库公开、源码上传、发行附件和签名；本文中的真实链接不表示这些线上步骤已经通过验收。早期未绑定的包仍会显示“未配置更新来源”，需要安装一次绑定仓库的新包。

你作为开发与发行维护者，需要 GitHub 账号、GitHub Desktop，以及 Python 3.12、Node.js 22、Ruby 3.2 和 Windows PowerShell 5.1+ 或 PowerShell 7。GitHub Actions 会在云端准备构建环境；本机运行测试需要以上开发工具，签名后重新生成发行元数据至少需要 Python 3.12。

普通试用者只需 Windows 上的 SketchUp 2024 和你发布的 RBZ，无需安装这些开发工具。对外产品名是 TT中枢；当前版本沿用软件内的“SU 中枢”菜单与技术命名空间，安装重启后从 **扩展程序 → SU 中枢 · 面板** 打开，面板底部可进入“关于与更新”。

## 第一次上传源码

1. 在 `tli96692-maker` 账号下新建 `TT-SU`，Description 填“TT中枢 · SketchUp 建模与插件工作台”，选择 Public。若目标仓库已创建，直接打开并核对完整地址 `tli96692-maker/TT-SU`，不重复创建；其他账号下的同名仓库保持原样。
2. 克隆这个目标仓库后，在 GitHub Desktop 选择它，通过“存储库 → 在资源管理器中显示”核对本地目录和 origin。保留该仓库的 `.git` 和 `.gitattributes`；不要把旧仓库的 `.git` 复制进来。
3. 解压交付的 **`tt-su-hub-时间戳.zip` 公开源码包**，把里面 `tt-su-hub` 文件夹的内容复制到刚克隆的仓库根目录，包含 `.github` 和 `.gitignore`。根目录应直接看到 `src`、`tools`、`tests`、`docs`、README 和 LICENSE。不要复制整个 REA 工作区或本机完整版 RBZ。
4. 检查 `src/release.json` 的 repository 是 `tli96692-maker/TT-SU`。不要填写网址或密码。将来本地 Core 构建可直接继承此配置；Actions 构建也会再次注入实际仓库名。GitHub Desktop 的改动列表应显示许多源码文件；若只有一个 ZIP，说明还没有把 ZIP 内的源码解压到仓库根目录。
5. 在 GitHub Desktop 检查 Changed files，确认都是这份公开源码，再 **Commit to main → Push origin**。如果默认分支不是 main，统一改为 main 或调整工作流触发分支。
6. 打开 GitHub 仓库 **Actions**，等待 **Core checks and draft release** 通过。首次运行可能需要在 Actions 页启用工作流；若组织限制 GitHub Actions，则由仓库管理员调整允许的 Actions。这里的绿色结果只代表离线测试与打包，不代表 SketchUp 实机全功能通过。

## 第一次生成发行草稿

1. 在 Actions 中打开 **Core checks and draft release → Run workflow**，选择 main，输入 **`v0.2.3-beta.1`**。这个 tag 必须严格匹配 `src/su_zhongshu.rb` / `src/hub/main.rb` 的版本前加 `v`。
2. 工作流重新测试、打包，并创建 **Draft Release**；不会自动公开。附件为 `su_zhongshu-core.rbz`、`release-manifest.json`、`SHA256SUMS.txt`。已存在的 tag 或 Release 会让流程停止，不覆盖旧版。
3. 到 **Releases** 打开草稿，下载 Core RBZ。先按核对单完成测试，再到 SketchUp 官方签名入口登录你的 Trimble 账号提交包。选择**仅签名、不加密 Ruby**；现有验包脚本需要读取自研 Ruby 入口以核对版本。官方签名会修改包内容，未签名包的加载受用户加载策略影响。[SketchUp 官方说明](https://help.sketchup.com/en/extension-warehouse/extension-encryption-and-signing)
4. 下载官方返回的签名包，将它保存为本地公开源码目录下 `dist/su_zhongshu-core.rbz`。**签名后不再修改或重新打包它**。生成新的校验元数据：

```powershell
python tools/create-release-manifest.py --repository tli96692-maker/TT-SU --tag v0.2.3-beta.1
python tools/verify-public-release.py --repository tli96692-maker/TT-SU --manifest dist/release-manifest.json
```

5. 在 Release 草稿中删除旧的 3 个附件，上传这次最终的同名 3 个文件；更新版本说明里的测试结果和签名状态，保留 **Set as a pre-release**。核对下载文件后点击 **Publish release**。这一步才会让其他用户看见版本；草稿阶段匿名客户端查不到。
6. 用另一台电脑或独立用户账号下载、安装、重启并验证。把这个 Release 页面链接发给试用者。无需对方安装 Git、Python、Node.js 或 Codex。

工作流使用 GitHub 官方 `workflow_dispatch` 手动触发机制和 `gh release create --draft`。工作流文件须先存在于仓库默认分支，网页才会显示手动执行入口。[GitHub 触发说明](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_dispatch)、[GitHub CLI 草稿发行](https://cli.github.com/manual/gh_release_create)

## 以后每次更新

1. 在同一仓库改代码，递增 **loader、host、package.json** 里的宿主版本，例如 `0.2.3-beta.2`，并同步 `package-lock.json` 的项目版本；更新 `docs/public-release-notes.md`，写清新增内容、修复、已知限制和迁移说明。内置工具没有改动时，不必把每个工具自己的版本一起改掉。
2. 运行本地检查和真实 SketchUp 回归，提交后 Push。绿色 CI 后，再手动 Run workflow，tag 填 `v0.2.3-beta.2`。
3. 下载草稿包、签名、重新生成 manifest/校验值、替换草稿附件、核对并公开。每版使用新 tag；不要用旧版本号覆盖不同代码。
4. 用户打开面板并连接宿主后，会自动在后台检查一次；发现兼容新版时显示提醒，也可以在“关于与更新”手动点击“检查更新”。同一 SketchUp 进程会缓存成功结果 10 分钟、失败结果 30 秒，短时间重复检查会使用缓存。用户看到更新后打开你的 Release，下载安装 RBZ、重启即可。**只 Push 源码，不发布 Release，用户不会收到一个可安装的新版本。** 自动检查只读取发行信息，不会在后台覆盖安装。
5. 成熟后发布稳定版时，使用不带 `-beta` 的语义版本，把 `src/release.json` 的 channel 改成 `stable`，重新构建；工作流会按 stable 生成非预发布草稿。先确认各渠道实际检查行为再引导用户切换。

## 本地直接给别人试用

在公开源码根目录运行，明确绑定同一个实际仓库：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/build-rbz.ps1 -Core -Repository tli96692-maker/TT-SU
python tools/create-release-manifest.py --repository tli96692-maker/TT-SU
python tools/verify-public-release.py --repository tli96692-maker/TT-SU --manifest dist/release-manifest.json
```

可以把最终签名的 Core RBZ 和安装说明直接发给试用者。需要让已分发的未绑定包收到 GitHub 更新时，请先给他们安装一次绑定了实际仓库的新包。更新地址来自安装包，不会因为你后来创建仓库就自动出现在旧包里。

## 出现故障与回退

用户先保存模型；退出 SketchUp，备份 `su_zhongshu.rb`、`su_zhongshu` 目录和设置文件，再通过扩展管理器安装上一版已签名 RBZ并重启。不要删除其他作者插件。若新版引入数据结构迁移，必须遵守该版说明；不保证所有未来设置可被旧版直接读取。

保留上一版 Release 和问题反馈 Issues，严重问题先撤下问题版本的公开可见状态或发布清晰说明，再发布新版本号修复。不要悄悄替换已经公开版本的同名 RBZ，否则已下载用户的文件和校验值会不一致。完整自动下载、备份安装、失败回滚仍是后续功能。

## 仍需你实际完成的步骤

逐项核实仓库公开状态、LICENSE 署名、源码上传、第一次云端工作流、Trimble 签名、公开 Release、另一台电脑安装验证。以实际运行记录和线上结果为准，本地通过不能代替这些项目。首次发布采用核心测试版，不上传仍待逐项核验分发许可的完整第三方离线包。
