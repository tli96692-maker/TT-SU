# TT中枢维护者：以后怎样发新版

在公开源码仓库根目录打开 PowerShell。下面以从 `0.2.3-beta.1` 升级到 `0.2.3-beta.2` 为例；以后每次换成更高的新版本号。首次建仓库、官方签名及上传附件的完整操作见 [GitHub 发布指南](github-setup.md)。

## 1. 先看计划，再修改版本

```powershell
python tools/prepare-next-release.py --version 0.2.3-beta.2
python tools/prepare-next-release.py --version 0.2.3-beta.2 --apply
```

第一条只显示计划，不创建或修改文件。第二条先在 `dist/release-preparation/时间戳/` 保存原文件，再同步加载器、宿主、`package.json` 和 `package-lock.json` 的两处项目版本，同时设置发布渠道。`-beta`、`-rc` 等预发行版本默认使用 `preview`；不带预发行后缀的正式版本默认使用 `stable`。要在 preview 渠道试用不带后缀的版本，可明确传入 `--channel preview`。

实际维护仓库为 `tli96692-maker/TT-SU`。需要在这次升级时绑定它，可在两条命令后都添加 `--repository tli96692-maker/TT-SU`。不要填写网址或口令；不传此参数时保留现有仓库。首次发行而且版本号不变时，按发布指南填写 `src/release.json` 即可，无需运行升级工具。

工具会拒绝相同版本、降级、文件版本不一致、非法版本号和“预发行版本 + stable 渠道”。它使用语义版本顺序，因此 `beta.10` 高于 `beta.2`；不接受 `v` 前缀，当前验包器也不支持 `+build` 构建元数据。重复运行已完成的升级会被拒绝，不会重复写入。文件替换出错时尝试恢复原字节，并给出备份路径；若文件权限或磁盘故障导致恢复也失败，会明确列出未恢复文件，保留备份供修复。断电或进程被强制终止时也可用该备份恢复。

## 2. 写更新说明，并运行检查

手动更新 `docs/public-release-notes.md`，写明新增内容、修复、已知限制、测试范围和迁移要求。版本工具不会替你改更新说明，也不会修改每个内置工具的独立版本。

```powershell
python tests/test_prepare_next_release.py
python tools/test-public-release.py
ruby --disable-gems tests/run_all.rb
npm run test:ui
```

首次在新电脑开发，需要先按发布指南安装运行环境、运行 `npm ci --ignore-scripts`，再运行 `npx playwright install chromium`。在独立 SketchUp 测试模型中检查本次修改涉及的操作、撤销和设置保留；离线测试不能代替原生验收。

## 3. 推送、生成草稿，再正式公布

1. 检查 Git 改动，提交并 Push；等待 GitHub Actions 检查通过。
2. 运行 **Core checks and draft release** 工作流，本例输入 `v0.2.3-beta.2`。它只生成草稿，不会自动公布。
3. 下载草稿 RBZ，完成 SketchUp 官方仅签名、不加密；按发布指南重新生成 manifest 和校验和，再替换草稿的三个附件。
4. 核对附件和版本说明后 Publish release。保留上一版 Release，便于排查和用户手动回退。不要覆盖已经公开版本的同名附件。

用户打开面板后会自动检查更新，也可在“关于与更新”手动检查。收到提示后下载新 RBZ、通过扩展管理器安装并重启 SketchUp。**当前功能是检查与提醒，安装由用户完成；不会自动替换插件，也没有自动安装失败回滚。** 只 Push 源码不会生成用户可安装的更新；未绑定仓库的旧包需先安装一次绑定真实仓库的新包。
