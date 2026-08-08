# Codex Status Bar

[English](README.en.md)

一个轻量级原生 macOS 菜单栏工具，用于查看本机 Codex 对话的任务状态和周额度，并在任务完成后提供全屏提醒。

> 这是独立的本地工具，不是 OpenAI 官方产品。

## 功能

- 每 3 秒从 Codex 本地线程索引和生命周期事件同步任务状态，支持并行和跨天任务。
- 单独显示每个用户对话的“开发中”“已完成”或“闲置”，不显示内部子代理。
- 已完成任务保留 10 分钟；闲置满 5 小时后从列表清除。
- 任务完成时，在鼠标所在屏幕显示高清角色和毛玻璃全屏提示。
- 提示淡入 0.8 秒；收到键盘、鼠标移动、点击或滚动后，最快于第 1 秒完全消失；无操作时最长显示 1 分钟。
- 每 60 秒读取一次周额度；菜单栏空间不足时，菜单会提示文字可能被截断，悬浮提示保留完整内容。

## 架构

```text
Sources/CodexStatusBar/
├── Core.*                 状态规则、会话解析、额度解析与快照合并
├── AppServerClient.*      Codex app-server 的 JSON-RPC 客户端
├── CompletionOverlay.*    全屏毛玻璃完成提示和输入退出逻辑
├── AppDelegate.*          刷新调度、菜单渲染与任务完成转场
└── main.m                 启动入口和命令行自测
```

`Core` 不依赖 AppKit，集中保存可测试的数据规则。`AppDelegate` 仅负责协调 UI 和定时刷新。额度快照会合并部分接口响应，避免某次响应缺少字段时清空已有额度。

## 要求

- macOS 13 或更高版本
- 已安装 Codex Desktop 或 Codex CLI
- macOS Command Line Tools

不依赖 Xcode 或第三方库。

## 快速安装

从 [v0.1.0 Release](https://github.com/Universeeeeeee/codex-status-bar/releases/tag/v0.1.0) 下载 `Codex.Status.zip`，解压后将 `Codex Status.app` 拖到“应用程序”文件夹并打开。

应用为个人使用的临时签名版本。首次打开若被 macOS 拦截，请在 Finder 中按住 Control 点击应用并选择“打开”，或前往“系统设置 -> 隐私与安全性”确认打开。

## 构建与运行

```bash
make test
make app
make archive
make run
```

构建产物位于 `outputs/Codex Status.app`；`make archive` 生成可分发的 `outputs/Codex Status.zip`。应用使用本地临时签名，适合个人使用和本地分发。

## 诊断

```bash
.build/CodexStatusBarTests --probe-sessions
.build/CodexStatusBarTests --test-overlay
```

第一个命令打印被识别的用户任务；第二个命令触发完成提示测试。

## 数据与隐私

应用只读取本机 `~/.codex` 中的线程索引和会话生命周期事件，并通过本机 `codex app-server` 获取额度。不会上传会话内容，也不保存账户凭据。

## 已知限制

- 周额度是否可用取决于当前 Codex app-server 是否返回该窗口；未返回时显示 `--`。
- macOS 没有公开 API 用于精确计算所有菜单栏图标的总占用空间。应用可检测自身文字被截断，但无法可靠判断整个状态项是否被系统收纳。

## 许可证

本项目采用 [MIT License](LICENSE)。允许商业使用、修改和再分发，但副本或实质部分必须保留版权与许可证声明。
