# Codex Scheduler

Codex Scheduler 是一款 macOS 日程插件。它通过 MCP（模型上下文协议）读取 Apple 日历和提醒事项，计算空闲时段，预览排程，并在你于 Codex 对话中批准后保存变更。

## 安装

需要 macOS 14 或更新版本、Swift 6.1 或更新版本，以及支持插件的本地 Codex 客户端。Swift 可通过 Xcode 命令行工具获得。首次构建需要联网下载锁定版本的依赖。

**1. 构建并授权本地应用**

~~~bash
git clone --branch v0.3.0 --depth 1 https://github.com/turambarr/codex-scheduler.git
cd codex-scheduler
bash plugins/codex-scheduler/scripts/install-local.sh
~~~

在 macOS 的系统提示里允许访问日历和提醒事项。脚本将应用安装到当前用户的应用支持目录。每次写入的确认都在 Codex 对话中完成。

**2. 安装 Codex 插件**

~~~bash
codex plugin marketplace add turambarr/codex-scheduler --ref v0.3.0
codex plugin add codex-scheduler@turambarr-tools
~~~

也可以在桌面版 Codex 的插件目录中，从 **turambarr Tools** 来源安装 **Codex Scheduler**。添加来源后如未出现，可重新打开客户端。

**3. 在本地 Codex 对话中使用**

> 查看未来七天的空闲时间。下周五前帮我找两个连续小时写报告，先给我看预览。

> 明天下午三点提醒我联系老师。

默认使用本机时区。工作窗口默认为工作日 09:00–12:00 和 13:00–18:00。可以直接在对话里指定你的工作时段、午休、固定安排和任务截止时间。

改期、标记完成和撤销适用于插件创建的事项。写入使用独立的「AI 日程安排」日历和「AI 日程提醒」清单。若系统中已有同名集合，应用会先核对绑定。

## 单独接入 MCP

完成本地应用安装后，也可以从仓库根目录直接注册服务。

~~~bash
codex mcp add codex-scheduler -- /bin/bash "$PWD/plugins/codex-scheduler/scripts/launch-mcp.sh"
~~~

插件模式和单独注册模式任选一种，以免在工具列表里出现重复服务。查询与排程预览可以使用支持标准输入输出传输的 MCP 客户端。保存变更需要客户端支持 MCP 对话确认。

## 数据与测试

日历和提醒由 macOS 的 EventKit（事件与提醒事项框架）访问。应用自己的计划、绑定和写入记录保存在当前用户的 SQLite（嵌入式数据库）文件。更多信息见 [隐私说明](PRIVACY.md)。

~~~bash
cd plugins/codex-scheduler
swift test --only-use-versions-from-resolved-file
bash scripts/build-app.sh
python3 scripts/smoke-mcp.py
~~~

最后一条是可选的端到端测试，使用合成数据。首次授权后加上 `--live` 可验证真实读取和排程预览。

## License

本项目自有源码采用 [MIT 许可证](LICENSE)。[MCP Swift 软件开发工具包](https://github.com/modelcontextprotocol/swift-sdk/blob/0.12.0/LICENSE) 等第三方依赖适用各自的许可证。

## English quick start

On macOS 14 or later, clone the tagged source and run `bash plugins/codex-scheduler/scripts/install-local.sh`. Grant Apple Calendar and Reminders access. Add the GitHub marketplace and install `codex-scheduler@turambarr-tools` using the commands above. In a new local Codex chat, ask for free time, a schedule preview, or a reminder. Review and approve changes in the chat.
