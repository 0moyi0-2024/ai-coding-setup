# AI 编程工具使用说明

此操作手册与 `set_claude_provider_keys.sh` 和它的测试脚本配套使用。

Claude Code、Codex、Claude Code Router（CCR）、Node.js、配置和缓存都放在
当前容器的 `/agent` 目录中。

本目录结构：

```text
linux_server/
├── README.md
├── set_claude_provider_keys.sh
├── set_jd_gateway_config.sh
├── dsh_server/
│   ├── start_dsh_service.sh
│   └── README.md
└── test/
    ├── set_claude_provider_keys_test.sh
    └── set_jd_gateway_config_test.sh
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

请先进入需要使用这些工具的容器，再进入仓库的 `ai-coding-setup/linux_server` 目录，然后运行：

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

默认安装根目录是 `/agent`。如需在无 root 权限的目录中安装或隔离测试，可在运行两个 Linux
脚本时设置 `AI_SETUP_AGENT_DIR`；例如
`AI_SETUP_AGENT_DIR="$HOME/agent" bash ./set_claude_provider_keys.sh`。JD 配置脚本会使用同一
变量查找 Claude、Codex 和公共环境文件。

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
脚本可能通过容器的 apt、dnf 或 yum 安装这个系统依赖。对于 `dnf`，如果镜像或
代理返回的仓库元数据校验失败，脚本会清理缓存并强制刷新后重试，最后才临时禁用
名称中包含 `update` 的仓库。如果该环境使用了不同的更新仓库名称，可以设置
`AI_SETUP_DNF_DISABLE_REPO`（支持 dnf 的仓库 glob 或逗号分隔值）后重新运行，例如：

```bash
AI_SETUP_DNF_DISABLE_REPO='updates,update' bash ./set_claude_provider_keys.sh
```

Claude Code 和 Codex 的 npm 主包还需要与当前 CPU 和 libc 匹配的原生包。安装器会
强制包含 npm optional dependencies；如果 npm 仍跳过当前平台包，安装器会从主包的
`package.json` 读取精确版本并补装。只有 `claude --version` 和 `codex --version`
都能正常执行后，脚本才会继续生成网关配置，避免留下显示安装成功但命令无法启动的环境。

## 修改或上库前运行开发测试

运行配套测试脚本：

```bash
bash ./test/set_claude_provider_keys_test.sh
```

测试使用隔离的临时目录，不会修改 `/agent`，不会访问真实模型网关，也不会消耗
API token。它会检查安装编排、CCR 配置、Claude 配置，以及 Codex profile 和模型
catalog 的生成与隔离，也会模拟平台原生包被 npm 跳过以及 CLI 无法启动的失败场景。
当前环境能够找到 Codex 时，还会使用真实 Codex CLI 加载每个
临时 profile。测试脚本退出状态为 0，且输出中没有 `not ok`，即表示测试通过。

## 安装后验证 Codex

完成安装和 token 配置后，在 `ai-coding-setup/linux_server` 目录运行：

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

## 只生成京东网关配置

`set_jd_gateway_config.sh` 是基础安装完成后的附加脚本。它不安装 Node.js、Claude Code、
Codex 或 CCR，也不修改主安装器保存的火山、百炼和 BlackAI 配置。默认只探测 JD 网关
下方列出的候选模型，不会使用或混合其他网关的模型列表。

### 一键追加到已有配置

直接运行脚本即可。脚本会隐藏输入 JD token，并把 JD 支持追加到已有安装：

```bash
bash ./set_jd_gateway_config.sh
```

`--merge` 与默认行为相同，可在自动化命令中显式使用。这个模式不会修改 Claude 的主
`settings.json`，也不会改变 Codex 主配置中的默认 provider、模型和已有网关。它只向
Codex 主配置追加一个不含 token 的 JD provider 注册，使 JD 会话之后可以直接使用
`codex resume`。已保存过 token 时，交互运行可直接按 Enter 保留原值；非交互运行会优先
使用当前环境中的值，否则复用 `/agent/env.sh` 中保存的值。

- Codex 会生成独立 profile 文件：`$CODEX_HOME/jd.config.toml`。未设置 `CODEX_HOME`
  时，本安装器环境写入 `/agent/config/codex/jd.config.toml`；普通环境写入
  `~/.codex/jd.config.toml`。
- 同时生成 JD 独立模型 catalog：`$CODEX_HOME/catalogs/jd.json`；模型列表只包含探测成功
  的 JD 模型，不会继承全局配置里的火山模型。JD catalog 使用标准 Responses 历史格式，
  因此从其他 provider 切换或恢复的长会话不会携带 JD 网关不支持的 Responses Lite 项。
- `$CODEX_HOME/config.toml` 只增加带受管标记的 `[model_providers.jd]` 注册；不会改变原来的
  `model_provider`、`model`、CCR 配置或其他 provider。这个注册使不带 `--profile jd` 的
  `codex resume <JD会话ID>` 也能识别会话中保存的 JD provider。
- 安装器布局中，脚本把 `JD_GATEWAY_TOKEN` 直接追加到 `/agent/env.sh` 的受管区块，并把
  文件权限设置为 `600`；不会另外生成 `jd.env`。主安装器以后重写 `/agent/env.sh` 时会
  读取并保留这个值。当前已打开的 shell 需要执行一次：

  ```bash
  source /agent/env.sh
  ```

- 主安装器中的 `claude` 命令继续读取原来的 `settings.json` 并通过 CCR 使用火山、百炼和
  BlackAI 网关。JD 脚本不会生成第二份 Claude settings 文件，而是在 `/agent/bin` 生成
  `claude-jd` 启动器。启动器从 `/agent/env.sh` 读取 token，并只在自己的 Claude 进程中
  叠加 JD 地址、模型和权限：

  ```bash
  claude-jd
  ```

  普通 Linux 环境会把 token 追加到 `~/.bashrc` 或 `~/.zshrc`，并生成
  `~/.local/bin/claude-jd`。如果该目录不在 `PATH`，可使用完整路径：

  ```bash
  "$HOME/.local/bin/claude-jd"
  ```

- Codex 使用独立 JD profile：

  ```bash
  codex --profile jd
  ```

  JD profile 与火山 profile 使用相同的连续执行策略：`approval_policy = "never"`、
  `sandbox_mode = "danger-full-access"`，新启动的 JD 会话不会请求命令审批。

- `claude-jd` 使用 `bypassPermissions`；主安装器生成的 Claude CCR 配置也使用相同模式。
  JD 路由只存在于 `claude-jd` 进程中，不会改变普通 `claude` 的网关。
- 如果只需要 Codex JD profile，可以使用：

  ```bash
  bash ./set_jd_gateway_config.sh --codex-only
  ```

### 其他模式

```bash
# 生成独立文件，不写入现有配置目录
bash ./set_jd_gateway_config.sh --standalone --output-dir "$HOME/jd-config"

# 只生成 Codex 独立配置
bash ./set_jd_gateway_config.sh --standalone --codex-only

# 只显示将要修改的文件，不写文件、不打印 token；仍会探测网关
bash ./set_jd_gateway_config.sh --dry-run

# 完全离线预览，不写文件、不打印 token，也不探测网关
bash ./set_jd_gateway_config.sh --dry-run --no-probe
```

`--standalone` 会在输出目录生成 `claude-settings.json` 和 `codex-config.toml`。
`--merge` 和 `--standalone` 不能同时使用。默认追加模式不会修改 Claude 的
`settings.json` 或 Codex 的默认路由，只更新 `/agent/env.sh` 的 JD 变量、在 Codex 主配置
中注册不含 token 的 JD provider，并维护 `jd.config.toml`、模型 catalog 和
`/agent/bin/claude-jd` 启动器。Codex 当前通过独立
`<profile>.config.toml` 实现 `--profile`，因此 `jd.config.toml` 是必须保留的 profile 文件。

### token 和权限

默认使用 Codex 的 `env_key = "JD_GATEWAY_TOKEN"`，不会把 token 写入 `jd.config.toml`。
默认追加模式会把 token 直接写入 `/agent/env.sh`，并将该文件权限设为 `600`；普通环境
则写入 `~/.bashrc` 或 `~/.zshrc` 的受管区块。交互输入 token 后通常不需要再手动
`export`。当前已打开的安装器 shell 需要执行一次 `source /agent/env.sh`。

如果在 `--codex-only` 模式明确选择 `--inline-token`，token 会写入 TOML 而不修改环境文件；
Claude 同时启用时仍需要环境中的 JD token。选择 `--no-save-token` 时不保存
token，也不修改 `/agent/env.sh` 或 shell 配置。包含 token 的 `/agent/env.sh` 和生成的
配置文件权限都是 `600`。不要把 token 或生成文件内容粘贴到聊天、日志、工单或代码仓库中。

### 模型探测

脚本只探测以下 JD 候选模型：

| 端点 | 候选模型 |
| --- | --- |
| Claude | `Claude-Opus-4.8-joybuilder`、`Claude-Opus-4.7-joybuilder`、`Claude-Sonnet-5-joybuilder` |
| Codex | `GPT-5.6-Terra-joybuilder`、`GPT-5.6-Sol-joybuilder` |

可用模型以当前 JD token 实际探测结果为准；探测失败的模型不会写入配置。全部失败时，
脚本会停止且不修改配置。网络不可达时可明确使用 `--no-probe` 跳过验证，但之后需要自行
确认模型确实可用。`--dry-run` 默认也会探测网关；与 `--no-probe` 一起使用才是完全离线预览。

### JD 配置脚本测试

```bash
bash ./test/set_jd_gateway_config_test.sh
```

测试会在临时目录模拟已有 Claude/Codex/CCR 配置，检查默认交互追加、主配置隔离、
`claude-jd`、`jd.config.toml`、token 权限、重复运行和 `--dry-run`。它不会访问 JD 网关，也不会修改
`/agent` 下的真实配置。

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

主安装器重跑时会刷新 Claude 的 CCR 配置，同时从已有 `/agent/env.sh` 保留 JD token；
`jd.config.toml`、`catalogs/jd.json` 和 `claude-jd` 也不会被删除。因此普通 `claude`
继续使用 CCR，`claude-jd` 和 `codex --profile jd` 继续使用 JD，两者互不覆盖。

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
