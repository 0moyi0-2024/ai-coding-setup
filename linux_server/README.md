# Linux AI 编程环境安装说明

本目录提供两个脚本：

- `set_claude_provider_keys.sh`：基础安装。安装或更新 Claude Code、Codex、Claude Code Router（CCR），并配置火山、百炼、BlackAI GPT、BlackAI Claude/Grok。
- `set_jd_gateway_config.sh`：JD 内网附加配置。在基础安装之上增加 JD，不覆盖已有网关，并把普通 Codex 的默认网关切到 JD。

所有运行文件默认放在 `/agent`：

```text
/agent/
├── bin/                    # claude、codex、ccr、claude-jd 启动器
├── node/                   # Node.js 和 npm 全局包
├── config/claude/          # Claude Code 主配置
├── config/codex/           # Codex 主配置、profile、模型 catalog 和 token
├── home/.claude-code-router/
├── cache/
└── env.sh                  # PATH、CODEX_HOME、CLAUDE_CONFIG_DIR、JD token
```

## 配置结构

基础脚本按 token 动态发现或验证模型，并为每个网关生成独立 Codex catalog。未配置 token、模型列表获取失败或没有可用模型时，不生成该网关的 profile。

| 启动方式 | provider | 显示的模型 |
| --- | --- | --- |
| `codex`（未安装 JD） | 本地 CCR，默认路由到火山 | 当前火山 token 验证成功的模型 |
| `codex`（安装 JD 后） | 直连 JD | 当前 JD token 验证成功的 GPT 模型 |
| `codex --profile volcano` | 直连火山 | 火山模型 |
| `codex --profile bailian` | 直连百炼 | 百炼模型 |
| `codex --profile blackai-gpt` | 直连 BlackAI GPT | BlackAI GPT 模型 |
| `codex --profile blackai-claude` | 直连 BlackAI Claude/Grok | BlackAI Claude/Grok 模型 |
| `codex --profile jd` | 直连 JD | JD GPT 模型 |
| `claude` | 本地 CCR，默认路由到火山 | CCR 中已注册的网关模型 |
| `claude-jd` | 直连 JD Anthropic 端点 | JD Claude 模型 |

普通 `codex` 不再合并所有网关模型，也不使用 `火山AI网关/模型名` 或 `京东网关/模型名` 这类显示前缀。这样模型选择与 provider 始终由同一个 profile 决定，避免模型被转发到错误网关。

基础脚本会把火山设为 CCR 的默认网关。未安装 JD 时，普通 Codex 也默认通过 CCR 使用火山；安装 JD 后，JD 脚本会把普通 Codex 默认切为直连 JD，但普通 Claude 和 CCR 的默认路由仍保持火山。因此基础配置至少需要一个可用的火山 token。

## 第一次安装

进入目录后运行：

```bash
cd /path/to/ai-coding-setup/linux_server
bash ./set_claude_provider_keys.sh
```

脚本会依次询问四个网关的 token。输入隐藏；已有值直接回车会保留，未配置的值直接回车会跳过。

安装完成后，在当前 shell 加载环境：

```bash
source /agent/env.sh
hash -r
```

确认命令来自本安装目录：

```bash
command -v claude
command -v codex
command -v ccr
```

正常情况下均指向 `/agent/bin/`。

需要用 root 安装、但之后由普通用户运行时，请指定实际用户：

```bash
sudo AI_SETUP_USER="$USER" bash ./set_claude_provider_keys.sh
```

需要改用其他安装目录时，两个脚本都传入相同环境变量：

```bash
AI_SETUP_AGENT_DIR="$HOME/agent" bash ./set_claude_provider_keys.sh
```

## 基础网关使用

尚未安装 JD 时，普通启动使用火山默认模型：

```bash
codex
```

切换到某个独立网关：

```bash
codex --profile volcano
codex --profile bailian
codex --profile blackai-gpt
codex --profile blackai-claude
```

profile 的 `/model` 只显示该 token 实际发现或验证成功的模型，不会混入其他网关。

恢复会话时，安装器生成的 `codex` 启动器会读取会话记录的 provider。没有显式指定 profile 时，会为直连网关会话自动恢复原 profile：

```bash
codex resume <SESSION_ID>
```

需要明确用另一网关继续时，可显式覆盖：

```bash
codex resume <SESSION_ID> --profile jd
codex resume <SESSION_ID> --profile bailian
```

显式 `--profile` 始终优先。跨网关恢复时，上游必须兼容该会话已有的消息和工具格式。

## 添加或更新 JD 网关

JD 脚本用于可访问 `llm-gw.jd.local` 的内网机器。先完成基础安装，再运行：

```bash
bash ./set_jd_gateway_config.sh
source /agent/env.sh
```

它会：

1. 隐藏读取 JD token；已有 token 时直接回车可保留。
2. 从 JD 的 Claude 和 Codex `/models` 端点发现模型。
3. 将接口返回结果与内置候选合并，并逐个发送实际请求验证。
4. 只把验证成功的模型写入 `/agent/config/codex/catalogs/jd.json` 和 `jd.config.toml`。
5. 生成 `/agent/bin/claude-jd`。
6. 把 `JD_GATEWAY_TOKEN` 追加到 `/agent/env.sh`，不改动已有网关变量。
7. 把 JD provider 追加或更新到 CCR，同时保持 CCR 和普通 `claude` 默认路由到火山。
8. 把普通 `codex` 的默认 provider 和模型目录切到 JD；已有火山、百炼和 BlackAI profile 继续保留。

JD Codex 候选目前包括：

```text
GPT-5.6-Terra-joybuilder
GPT-5.6-Sol-joybuilder
GPT-5.5-joybuilder
GPT-5.6-Luna-joybuilder
GPT-6-Astra-joybuilder
```

候选不是最终可见列表。即使 `/models` 漏报某个候选，脚本也会主动调用验证；只有验证成功的模型才会写入配置。

安装完成后，普通 `codex` 默认使用 JD；显式 profile 与 Claude 启动方式如下：

```bash
codex
codex --profile jd
codex --profile volcano
claude-jd
claude
```

其中 `claude-jd` 直连 JD，普通 `claude` 仍通过 CCR 默认使用火山。

更新 JD token 时重新运行同一脚本即可：

```bash
bash ./set_jd_gateway_config.sh
source /agent/env.sh
```

自动化场景可以显式传入 token：

```bash
bash ./set_jd_gateway_config.sh --token "$JD_GATEWAY_TOKEN"
```

JD profile 与基础网关使用相同的 Codex 权限策略：

```toml
approval_policy = "never"
sandbox_mode = "danger-full-access"
```

因此正常执行任务时不会弹出 Codex 命令审批。

## 配置更新命令

只重新探测并更新基础网关，不重新安装 CLI：

```bash
bash ./set_claude_provider_keys.sh --configure-only
source /agent/env.sh
```

只安装或更新 CLI，不修改网关配置：

```bash
bash ./set_claude_provider_keys.sh --install-only
```

预览基础脚本，不写文件：

```bash
bash ./set_claude_provider_keys.sh --configure-only --dry-run
```

JD 常用可选参数：

```text
--token <token>       非交互提供 token
--claude-only         只生成 Claude 配置
--codex-only          只生成 Codex 配置
--no-probe            跳过在线验证，使用内置候选
--no-save-token       不持久化 token，也不把 token 写入 CCR
--dry-run             仅显示计划
--output-dir <dir>    输出到指定目录，适合隔离测试
--standalone          生成独立配置文件
```

日常追加或更新 JD 时不需要额外参数。

## CCR 自动恢复

基础脚本会动态选择连续三个空闲端口，并写入：

```text
/agent/home/.claude-code-router/runtime.env
```

如果 PID 1 是 systemd，脚本会安装并启用 `ai-coding-setup-ccr.service`，机器重启后自动恢复 CCR。查看状态：

```bash
systemctl status ai-coding-setup-ccr.service
```

没有 systemd 的容器不会安装服务，需要由容器入口、Supervisor 或其他进程管理器执行：

```bash
/agent/bin/ccr-autostart
```

## 常见问题

### 找不到命令

```bash
source /agent/env.sh
hash -r
command -v codex
```

### Claude Code 或 Codex 缺少 ARM64 原生包

基础脚本会强制安装 npm optional dependencies，并根据主包 `package.json` 补装与 CPU、libc 匹配的原生包。重新运行完整安装：

```bash
bash ./set_claude_provider_keys.sh
```

脚本只有在 `claude --version` 和 `codex --version` 都成功后才进入配置阶段。

### 普通 Codex 显示了其他网关或带中文前缀的旧模型

未安装 JD 的机器重新运行基础配置后，普通 `codex` 应只显示火山模型：

```bash
bash ./set_claude_provider_keys.sh --configure-only
source /agent/env.sh
```

已安装 JD 且 JD token、profile 和 catalog 都有效时，基础脚本重跑会保留普通 `codex` 默认使用 JD。需要刷新 JD 模型时重新运行 JD 脚本。其他网关继续使用对应 `--profile`。

### JD 模型没有更新

重新运行 JD 脚本。若 `/models` 没有返回某个已知候选，脚本仍会主动探测；只有实际调用成功才会加入 JD catalog。

```bash
bash ./set_jd_gateway_config.sh
source /agent/env.sh
```

### CCR 没有注册 JD

确认基础安装已完成并且 CCR 能启动，再重新执行 JD 脚本：

```bash
source /agent/env.sh
ccr status
bash ./set_jd_gateway_config.sh
```

JD 脚本会更新 CCR 中的 JD provider，但不改变 CCR 的 `preferredProvider` 和 `defaultOpenAIModel`，所以普通 `claude` 仍默认走火山；普通 `codex` 会改用 JD catalog。

## 开发验证

```bash
bash ./test/set_claude_provider_keys_test.sh
bash ./test/set_jd_gateway_config_test.sh
bash -n ./set_claude_provider_keys.sh
bash -n ./set_jd_gateway_config.sh
```

已安装环境可额外检查：

```bash
bash ./test/set_claude_provider_keys_test.sh --installed-codex
```

## 安全和清理

基础四网关 token 保存在 `/agent/config/codex/gateways.env`，JD token 保存在 `/agent/env.sh`；相关文件权限为 600。不要把 token 输出到日志或提交到仓库。

确认 `/agent` 是本脚本创建的专用目录后，可删除当前容器中的安装：

```bash
source /agent/env.sh
ccr stop || true
rm -rf -- /agent
```
