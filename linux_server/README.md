# Linux AI 编程环境安装说明

本目录提供两个脚本：

- `set_claude_provider_keys.sh`：基础安装。安装或更新 Claude Code、Codex、Claude Code Router（CCR），并配置火山、百炼、BlackAI GPT、BlackAI Claude/Grok。
- `set_jd_gateway_config.sh`：JD 内网附加配置。在基础安装之上增加 JD，不覆盖已有网关，并把普通 Codex 的默认网关切到 JD。

所有运行文件默认放在 `/mnt/d/agent`：

```text
/mnt/d/agent/
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
source /mnt/d/agent/env.sh
hash -r
```

确认命令来自本安装目录：

```bash
command -v claude
command -v codex
command -v ccr
```

正常情况下均指向 `/mnt/d/agent/bin/`。

需要用 root 安装、但之后由普通用户运行时，请指定实际用户：

```bash
sudo AI_SETUP_USER="$USER" bash ./set_claude_provider_keys.sh
```

需要改用其他安装目录时，两个脚本都传入相同环境变量：

```bash
AI_SETUP_AGENT_DIR="$HOME/agent" bash ./set_claude_provider_keys.sh
```

## 安装验收与认证恢复

基础脚本执行到最终验收时，不再仅凭 CLI 版本、CCR 状态或管理密钥判断安装成功，还会：

1. 从 Claude settings 读取实际静态凭据；未设置静态凭据时，执行已配置且受信任的 `apiKeyHelper`（最多等待 15 秒）。不会回退到 CCR 管理密钥；缺失凭据、助手失败或多行凭据会导致验收失败。
2. 使用该实际凭据请求 CCR `/v1/models`，要求 HTTP 200 且模型列表非空（请求最多等待 10 秒）。
3. 分别执行普通 `claude` 和 `codex` 的简短真实请求，各最多等待 90 秒，以退出状态判断是否成功。请求提示要求只回复 OK、不使用工具；Claude 同时显式禁用工具。

**调用成本与范围：** 这两次客户端请求可能消耗上游额度；发生恢复时还会重新请求。验收检查的是两个客户端当前默认配置，不保证所有独立 profile 或模型均可用。已保留 JD 默认配置时，普通 Codex 验证的是 JD 直连，而不是强制改回 CCR。

**认证恢复规则：** 当模型发现返回 401，或真实 CLI 请求失败并报告认证拒绝时，脚本最多重启 CCR 一次、等待服务恢复并重新检查 Claude 模型发现和两个 CLI。恢复后任何检查仍失败，安装验收立即失败，不会循环重启。Codex 只有默认 provider 为 `claude-code-router` 时，其认证失败才允许触发 CCR 恢复。

网络错误、超时、非认证服务错误以及空模型列表不会触发认证恢复。失败提示仅报告检查类别，不输出原始响应正文、凭据或 CLI 诊断；必要时在本机检查私有日志，分享前先脱敏。

此机制用于发现真实客户端不可用，并尝试刷新 CCR 运行时认证状态；它不改变安装顺序，也不意味着 CCR 内部持久化配置与认证快照不同步的深层原因已根治。

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
source /mnt/d/agent/env.sh
```

它会：

1. 隐藏读取 JD token；已有 token 时直接回车可保留。
2. 从 JD 的 Claude 和 Codex `/models` 端点发现模型。
3. 将接口返回结果与内置候选合并，并逐个发送实际请求验证。
4. 只把验证成功的模型写入 `/mnt/d/agent/config/codex/catalogs/jd.json` 和 `jd.config.toml`。
5. 生成 `/mnt/d/agent/bin/claude-jd`。
6. 把 `JD_GATEWAY_TOKEN` 追加到 `/mnt/d/agent/env.sh`，不改动已有网关变量。
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
source /mnt/d/agent/env.sh
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
source /mnt/d/agent/env.sh
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
--merge               追加 JD 配置（默认）：写入 .codex/jd.config.toml
--inline-token        Codex 配置用 http_headers 内联 token（默认用 env_key 更安全）
```

日常追加或更新 JD 时不需要额外参数。

## CCR 自动恢复

基础脚本会动态选择连续三个空闲端口，并写入：

```text
/mnt/d/agent/home/.claude-code-router/runtime.env
```

如果 PID 1 是 systemd，脚本会安装并启用 `ai-coding-setup-ccr.service`，机器重启后自动恢复 CCR。查看状态：

```bash
systemctl status ai-coding-setup-ccr.service
```

没有 systemd 的容器不会安装系统服务。脚本会在 `env.sh` 中写入兜底恢复逻辑：容器重启后打开新的 Bash 终端时，如果检测到没有 systemd user bus 且 CCR 尚未运行，会自动在后台启动：

```bash
/mnt/d/agent/bin/ccr-autostart
```

因此无 systemd 容器重启后，打开终端即可快速恢复 CCR；需要容器一启动就恢复，仍应由容器入口、Supervisor 或其他进程管理器执行上面的命令。

## 常见问题

### 找不到命令

```bash
source /mnt/d/agent/env.sh
hash -r
command -v codex
```

### Claude Code 或 Codex 缺少 ARM64 原生包

基础脚本会强制安装 npm optional dependencies，并根据主包 `package.json` 补装与 CPU、libc 匹配的原生包。重新运行完整安装：

```bash
bash ./set_claude_provider_keys.sh
```

脚本只有在 `claude --version` 和 `codex --version` 都成功后才进入配置阶段。

### 更新时报 `npm error EACCES ... rename`

Windows/WSL（NTFS）不允许重命名正在运行的程序目录。更新前请先退出正在运行的 Claude Code 和 Codex 会话；CCR 会由脚本自动停止并在配置完成后恢复。

### 普通 Codex 显示了其他网关或带中文前缀的旧模型

未安装 JD 的机器重新运行基础配置后，普通 `codex` 应只显示火山模型：

```bash
bash ./set_claude_provider_keys.sh --configure-only
source /mnt/d/agent/env.sh
```

已安装 JD 且 JD token、profile 和 catalog 都有效时，基础脚本重跑会保留普通 `codex` 默认使用 JD。需要刷新 JD 模型时重新运行 JD 脚本。其他网关继续使用对应 `--profile`。

### 客户端报 401 或 Invalid or expired API key

即使 CCR 管理接口中存在密钥，运行时也可能拒绝客户端实际使用的凭据。不要用管理密钥测试成功来替代 Claude/Codex 的实际请求，也不要把 token 或完整错误响应贴到公共日志。

使用最新基础脚本重新配置时，最终验收会执行上述检查，并在认证拒绝时尝试一次 CCR 恢复：

```bash
bash ./set_claude_provider_keys.sh --configure-only
source /mnt/d/agent/env.sh
```

该命令会重新探测并更新基础网关配置，并非只读诊断。需要保留现有配置时，应先备份安装目录中的配置和 CCR 状态。

若恢复后仍失败，检查 Claude settings 中的实际凭据或密钥助手、Codex 当前默认 provider 及其凭据来源，以及相应上游 token 的权限和有效期。Codex 直连 JD 等非 CCR 服务时，应排查该服务的认证，重启 CCR 无法修复其 token。网络或超时失败则优先检查连通性和上游状态。

### JD 模型没有更新

重新运行 JD 脚本。若 `/models` 没有返回某个已知候选，脚本仍会主动探测；只有实际调用成功才会加入 JD catalog。

```bash
bash ./set_jd_gateway_config.sh
source /mnt/d/agent/env.sh
```

### CCR 没有注册 JD

确认基础安装已完成并且 CCR 能启动，再重新执行 JD 脚本：

```bash
source /mnt/d/agent/env.sh
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

认证验收回归覆盖静态凭据、密钥助手执行、401/服务错误/超时分类、非 CCR Codex 失败不重启，以及一次恢复后的完整重验和持续失败终止。此次更新验证通过基础回归 42 项、JD 回归 13 项；同时完成两个真实客户端请求验证。隔离回归不等同于当前生产环境的在线验收。

已安装环境可额外检查：

```bash
bash ./test/set_claude_provider_keys_test.sh --installed-codex
```

## 安全和清理

基础四网关 token 保存在 `/mnt/d/agent/config/codex/gateways.env`，JD token 保存在 `/mnt/d/agent/env.sh`；相关文件权限为 600。不要把 token 输出到日志或提交到仓库。

确认 `/mnt/d/agent` 是本脚本创建的专用目录后，可删除当前容器中的安装：

```bash
source /mnt/d/agent/env.sh
ccr stop || true
rm -rf -- /mnt/d/agent
```
