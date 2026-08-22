# AI 编程工具使用说明

此操作手册与 `set_claude_provider_keys.sh` 和它的测试脚本配套使用。

Claude Code、Codex、Claude Code Router（CCR）、Node.js、配置和缓存都放在
当前容器的 `/agent` 目录中。

仓库目录结构：

```text
ai-coding-setup/
├── README.md
├── set_claude_provider_keys.sh
├── dsh_server/
│   ├── start_dsh_service.sh
│   └── README.md
└── test/
    └── set_claude_provider_keys_test.sh
```

`set_claude_provider_keys_test.sh` 默认执行修改代码后的隔离开发测试；加上
`--installed-codex` 后，用于安装完成后检查当前容器中的真实 Codex 配置。

`dsh_server/` 目录用于将 DSH Web 服务注册为 systemd 后台服务，支持开机自启和异常自动重启。详见 [dsh_server/README.md](dsh_server/README.md)。

## 这套脚本会做什么

脚本会完成以下工作：

1. 缺少时安装 Node.js，并安装或更新 Claude Code、Codex 和 CCR。
2. 询问并保存你提供的网关 API key，输入内容不会显示在屏幕上。
3. 根据每个 token 返回的模型列表生成独立配置，避免不同 token 的模型混在一起。
4. 为 CCR 自动选择空闲端口，并让 Claude Code 通过本地 CCR 调用模型。
5. 生成 Claude 和 Codex 的启动环境及模型配置。

## 第一次安装

请先进入需要使用这些工具的容器，再进入存放这套脚本的仓库根目录，然后运行：

```bash
bash ./set_claude_provider_keys.sh
```

脚本会依次询问以下四个可选 API key：

| API key | 用途 |
| --- | --- |
| Volcano | Claude 和 Codex |
| Bailian | Claude 和 Codex |
| BlackAI GPT | Codex |
| BlackAI Claude/Grok | Claude 和 Codex |

- 已经保存过的 key：直接按 Enter 会保留原值。
- 从未配置过的 key：直接按 Enter 会跳过该网关。
- 需要替换 key：输入新 key 后按 Enter。

安装过程可能需要访问 Node.js、npm 和相应模型网关。缺少 `libatomic.so.1` 时，
脚本可能通过容器的 apt、dnf 或 yum 安装这个系统依赖。

## 修改或上库前运行开发测试

运行配套测试脚本：

```bash
bash ./test/set_claude_provider_keys_test.sh
```

测试使用隔离的临时目录，不会修改 `/agent`，不会访问真实模型网关，也不会消耗
API token。它会检查安装编排、CCR 配置、Claude 配置，以及 Codex profile 和模型
catalog 的生成与隔离。当前环境能够找到 Codex 时，还会使用真实 Codex CLI 加载每个
临时 profile。测试脚本退出状态为 0，且输出中没有 `not ok`，即表示测试通过。

## 安装后验证 Codex

完成安装和 token 配置后，在仓库根目录运行：

```bash
bash ./test/set_claude_provider_keys_test.sh --installed-codex
```

该测试检查 `/agent/bin/codex`、`CODEX_HOME`、已配置 token 对应的 profile、独立模型
catalog 以及模型 metadata 是否能被 Codex 正确加载。它只使用 Codex 的本地调试命令，
不会向模型网关发送推理请求，也不会消耗 API token。至少需要配置一个网关 token；
只执行过 `--install-only`、尚未生成 profile 时，该测试会提示先完成网关配置。

## 安装完成后激活环境

安装成功后，在当前 shell 执行：

```bash
source "/agent/env.sh"
hash -r
```

确认当前使用的是本容器中的命令：

```bash
command -v claude
command -v codex
command -v ccr
```

正常情况下，它们都应指向 `/agent/bin/`。每次打开新的 shell，都需要重新执行：

```bash
source "/agent/env.sh"
```

## 使用 Claude Code

启动 Claude Code：

```bash
claude
```

进入 Claude Code 后，通过 `/model` 查看 CCR 从已配置 token 发现的模型并进行选择。
火山、百炼和 BlackAI Claude/Grok 的模型会按 provider 分组显示。

查看 CCR 状态：

```bash
ccr status
```

## 使用 Codex

Codex 会把已配置 token 对应的 provider 注册到全局配置，同时为每个 token 保留独立
profile。新会话建议带上对应的 `--profile`，以保持模型目录和 token 隔离：

```bash
codex --profile volcano
codex --profile bailian
codex --profile blackai-gpt
codex --profile blackai-claude
```

没有配置 token 的 profile 不会生成。直接运行不带 profile 的 `codex`，可能看到
CCR 的默认模型。恢复历史会话时，全局配置可以识别已配置的 provider；如果需要严格
使用某个 token 的独立模型目录，仍应带上对应的 `--profile`。

## 查看脚本发现的模型

以下命令只读取模型名称，不会打印 API key：

```bash
jq -r '.models[].slug' "/agent/config/codex/catalogs/volcano.json"
jq -r '.models[].slug' "/agent/config/codex/catalogs/bailian.json"
jq -r '.models[].slug' "/agent/config/codex/catalogs/blackai-gpt.json"
jq -r '.models[].slug' "/agent/config/codex/catalogs/blackai-claude.json"
```

未配置的 provider 不会有对应 catalog 文件。`/models` 返回模型名称，只说明网关向
该 token 公布了模型；最终是否完全兼容 Claude/Codex，需要以实际调用结果为准。

## 以后如何重新运行

只更新 token、端口和模型配置，不重新安装工具：

```bash
bash ./set_claude_provider_keys.sh --configure-only
```

只安装或更新工具，不配置网关：

```bash
bash ./set_claude_provider_keys.sh --install-only
```

`--install-only` 之后如需使用 Claude 网关，再运行一次 `--configure-only`。

预览脚本将执行的操作，但不写文件：

```bash
bash ./set_claude_provider_keys.sh --configure-only --dry-run
```

重新配置后再次执行：

```bash
source "/agent/env.sh"
hash -r
```

## 常见问题

### 找不到 claude、codex 或 ccr

```bash
source "/agent/env.sh"
hash -r
```

然后使用 `command -v codex` 确认路径是否位于 `/agent/bin/`。

### 端口已被占用

脚本会从 3456 开始寻找连续的三个空闲端口。重新运行 `--configure-only` 会重新选择
端口。完成后可用 `ccr status` 检查状态。

### 修改了 token，但模型列表没有更新

重新运行：

```bash
bash ./set_claude_provider_keys.sh --configure-only
source "/agent/env.sh"
```

## 目录和安全说明

主要目录：

```text
/agent/
├── bin/       claude、codex、ccr 启动器
├── node/      Node.js 和已安装的 CLI 工具
├── config/    Claude、Codex、模型 catalog 和 API key 配置
├── home/      CCR 的容器内 HOME 和服务配置
├── cache/     npm 缓存
└── env.sh     当前 shell 的环境加载文件
```

API key 保存在 `/agent/config/codex/gateways.env`，文件权限为 600。
不要把该文件内容粘贴到聊天、日志、工单或代码仓库中。

工具、配置和缓存位于 `/agent`。系统安装的 `libatomic` 等依赖不属于该目录。

## 删除当前容器中的安装

仅在确认 `/agent` 是当前容器由本脚本创建的专用目录后执行：

```bash
source "/agent/env.sh"
ccr stop || true
rm -rf -- "/agent"
```

删除后无法从该目录恢复 API key 和配置。该操作只应针对当前容器，不要替换成其他
容器或宿主机的目录。
