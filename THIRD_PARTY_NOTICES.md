# 许可证与第三方入口

TT中枢（原 SU 中枢）的宿主、自研界面和 7 个内置工具按根目录 LICENSE 中的 MIT License 提供。技术命名空间 `SUHub` / `su_zhongshu` 为兼容旧设置而保留。版权声明不改变第三方内容的原有归属。

## 公开核心包

`su_zhongshu-core.rbz` 包含宿主及模型统计、圆角、推拉、放样、地形、喷漆、缩放 7 个内置工具。它不包含第三方 ZIP、DLL、EXE、适配器 vendor 或 TT_Lib²，核心功能不依赖 TT_Lib²。插件市场的第三方项目均为官方入口；访问、下载、安装、付费和依赖条件以各作者网站为准。

官网入口只是信息索引，不表示这些作品采用本项目的 MIT 许可证、不表示作者合作或背书。GitHub 上可见的源代码也不自动获得再次分发许可。

## 本机完整离线包

默认构建的 `su_zhongshu.rbz` 可能包含早期集成的第三方适配包。各包保留自己的许可证；Parametric Modeling / Universal Importer 的目录声明为 GPL-3.0，其余开源条目按各自附带许可证执行。部分上游包包含额外原生程序、运行库和 SDK 文件，逐组件分发条件尚未完成核验。因此完整离线包不属于本次公开发行物，不应直接上传公共仓库或 Release。

## 开发依赖

公开源码使用 Playwright 1.59.1（Microsoft，Apache-2.0）作为开发测试依赖，通过 npm 获取，不打入 RBZ。Ruby、Python、Node.js、GitHub Actions 与 SketchUp 为外部运行或构建环境。SketchUp 为 Trimble 的产品；本项目不附带 SketchUp 安装程序或 SDK 二进制。

未来加入第三方代码时，须记录上游地址、版本或提交、许可证、修改说明和必需声明，再更新本文件及发行清单。
