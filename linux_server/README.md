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

## systemd 说明

systemd 不是本项目安装的第三方 npm 软件，而是 Linux 中常见的系统初始化和服务管理组件。
Ubuntu、Debian、Fedora 等发行版通常已经随系统提供；本脚本只调用 `systemctl` 创建和管理服务
单元，不会重复安装 systemd。

检查当前环境是否可用：

```bash
command -v systemctl
ps -p 1 -o comm=
systemctl is-system-running
```

WSL 使用 systemd 需要较新的 WSL 版本，并在 `/etc/wsl.conf` 中启用：

```ini
[boot]
systemd=true
```

修改后需从 Windows 侧执行 `wsl --shutdown`，再重新启动发行版。没有 systemd 的 Linux/WSL
环境仍可以运行 Claude Code、Codex 和 CCR，但不会自动安装 systemd 服务；CCR 需要手动启动。

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

脚本应由以后实际使用 `claude`、`codex` 和 `ccr` 的用户执行。如果需要使用 root
安装（例如 `/agent` 只有 root 可写），请明确指定安装用户；通过 `sudo` 执行时脚本会
自动使用 `SUDO_USER`：

```bash
sudo AI_SETUP_USER="$USER" bash ./set_claude_provider_keys.sh
```

`AI_SETUP_USER` 会拥有 `/agent/config`、CCR 运行目录、缓存、密钥文件和生成的 Codex
profile。直接以 root 执行且不设置它时，文件会归 root，普通用户无法读取 `config.toml`；
这时应重新用上述命令运行，或先执行一次权限修复：

```bash
sudo AI_SETUP_USER="$USER" bash ./set_claude_provider_keys.sh --configure-only
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

安装脚本会在当前用户的 `~/.bashrc` 中维护一个带标记的配置区块，让以后新打开的
Bash 会话自动加载 `/agent/env.sh`。重复运行安装脚本不会重复追加配置。
`/agent/env.sh` 本身也会在加载时先移除 PATH 中已有的 `/agent/bin` 和
`/agent/node/bin`，再各添加一次，因此反复执行 `source` 或打开嵌套 Bash 不会让
PATH 持续增长。

安装脚本无法修改已经启动的 shell 进程，因此安装完成后仍需在当前 shell 执行一次：

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

正常情况下，它们都应指向 `/agent/bin/`。以后新打开的 Bash 会话会通过 `~/.bashrc`
自动加载环境，不需要再次手动执行 `source`。

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
profile。支持完整 Codex 工具协议的网关可以直接使用对应的 `--profile`：

```bash
codex --profile volcano
codex --profile bailian
codex --profile blackai-gpt
codex --profile blackai-claude
```

火山网关的原生 Responses 接口不支持 Codex 的 `additional_tools`、`namespace` 等工具项，
因此不要使用 `codex --profile volcano` 执行需要工具的会话。请通过 CCR 使用火山模型，
CCR 会负责协议转换：

```bash
codex -m '火山AI网关/deepseek-v4-pro'
```

没有配置 token 的 profile 不会生成。需要使用 CCR 转发的火山模型时，请显式指定
`火山AI网关/deepseek-v4-pro`；恢复历史会话时，全局配置可以识别已配置的 provider；
如果需要严格使用某个 token 的独立模型目录，仍应带上对应的 `--profile`。

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

重新配置会更新 `/agent/env.sh` 和密钥文件；新开的 Bash 会话会自动读取。当前 shell
如果需要立即使用新值，再执行：

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

### 普通用户提示 `config.toml: Permission denied`

这通常表示之前用 root 安装，导致 Codex 配置和 CCR HOME 仍为 `root:root`。使用实际登录
用户重新执行一次上面的 `--configure-only` 命令；脚本会保留已保存的 key，并修复配置、
SQLite 状态和缓存的所有权，不会把 key 打印到终端。

### 端口已被占用

脚本默认从 3456 开始扫描连续的三个空闲端口，但实际端口由当前环境动态选择并写入
`/agent/home/.claude-code-router/runtime.env`；CCR 启动器和 systemd 服务都会读取这个
运行时文件，不会把 3456 当成固定端口。重新运行 `--configure-only` 会重新选择端口。
也可以通过 `AI_SETUP_CCR_PORT_SCAN_START` 指定扫描起点。完成后可用 systemd 和端口检查状态。

### CCR 开机自动启动（WSL 和普通 Linux）

如果系统 PID 1 是 systemd（WSL 需要在 `/etc/wsl.conf` 中启用 `systemd=true`），配置阶段
会自动安装并启用 `ai-coding-setup-ccr.service`。服务启动时读取保存的动态端口，网络就绪
后启动 CCR；没有 systemd 的 Linux 环境不会修改系统启动文件，只会提示手动启动：

```bash
ccr start --host 127.0.0.1 --port "$(awk -F= '$1 == "CCR_MANAGEMENT_PORT" {print $2}' \
  /agent/home/.claude-code-router/runtime.env)" --no-open --gateway
```

查看服务状态：

```bash
systemctl status ai-coding-setup-ccr.service
ss -ltnp | grep -E '127\.0\.0\.1:[0-9]+'
```

如果 `systemctl is-system-running` 报错或 PID 1 不是 `systemd`，说明当前环境没有可用的
systemd。此时不需要为了本脚本单独安装 npm 包；可以手动启动 CCR，或在已有的进程管理器
（例如 Docker、Supervisor、runit）中托管 `/agent/bin/ccr-autostart`。

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
