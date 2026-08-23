# dsh 服务管理

这个目录用于管理 DeepSeek Harness（`dsh`）的 Web 服务。

脚本使用 Linux 的 systemd 管理后台进程。systemd 是发行版提供的系统服务管理组件，不是
本仓库额外安装的 npm 软件；Ubuntu、Debian、Fedora 等系统通常已经自带。执行安装前可以
检查：

```bash
command -v systemctl
ps -p 1 -o comm=
systemctl is-system-running
```

在 WSL 中，需要先在 `/etc/wsl.conf` 启用 `systemd=true`，然后从 Windows 侧执行
`wsl --shutdown` 并重新进入发行版。没有 systemd 的环境不能使用本目录的 systemd 安装脚本，
应改用该环境已有的进程管理器。

## 文件

- `start_dsh_service.sh`：安装和管理 dsh 的 systemd 服务。
- `/etc/systemd/system/dsh-web.service`：脚本安装后生成的 systemd 单元，不在仓库目录中。

## 实现原理

直接执行 `dsh web` 时，dsh 会跟随当前终端退出。脚本将它包装成一个 systemd 服务：

1. 检查 dsh、`DSH_HOME`、工作目录和端口配置。
2. 选择一个由操作系统分配的空闲端口，并保存到 `/var/lib/dsh-web/port`。
3. 生成 `/etc/systemd/system/dsh-web.service`。
4. 为 systemd 设置 Node.js 的 `PATH`、`HOME`、`DSH_HOME` 和工作目录。
5. 使用动态端口启动 Web UI。
6. 执行 `systemctl enable`，让系统启动时自动运行。
7. 使用 `Restart=on-failure`，让 dsh 异常退出后自动重启。

服务默认只监听 `127.0.0.1`。dsh 当前禁止绑定 `0.0.0.0`，因为 Web UI 具有代码执行能力，直接暴露到网络存在安全风险。

## 安装并启动

在本目录执行：

```bash
# 在你 clone 的仓库目录中执行；将路径替换为实际位置
cd /path/to/ai-coding-setup/linux_server/dsh_server
chmod 755 start_dsh_service.sh
./start_dsh_service.sh install
```

脚本执行 `install`、`start` 或不带参数时，会先检查服务是否同时满足以下条件：systemd 状态为 active、已记录的端口仍在监听、HTTP 根路径返回成功。如果服务健康，脚本不重启、不改端口；如果服务缺失或异常，才会重新选择空闲端口并修复服务。

不带参数时也会执行上述健康检查：

```bash
./start_dsh_service.sh
```

成功后访问：

脚本会输出实际地址，例如：

```text
http://127.0.0.1:41827
```

端口保存在：

```text
/var/lib/dsh-web/port
```

## 日常操作

```bash
# 查看状态
./start_dsh_service.sh status

# 服务异常时检查并修复；健康时不做任何操作
./start_dsh_service.sh start

# 强制重启，并重新选择一个动态端口
./start_dsh_service.sh restart

# 停止服务
./start_dsh_service.sh stop

# 查看实时日志
journalctl -u dsh-web.service -f
```

如果修改了端口、dsh 路径或工作目录，应使用 `install` 或 `start`，让脚本重新生成 systemd 配置：

```bash
./start_dsh_service.sh install
```

## 配置覆盖

脚本默认从当前环境探测 `dsh` 和 `node`，并使用当前用户的 DSH 目录：

```text
DSH_BIN=PATH 中的 dsh
DSH_HOME=$HOME/.dsh
DSH_HOST=127.0.0.1
DSH_WORKDIR=当前执行目录
NODE_BIN_DIR=PATH 中 node 所在目录
```

改用指定工作目录：

```bash
DSH_WORKDIR=/path/to/ai-coding-setup/linux_server ./start_dsh_service.sh install
```

如果 `dsh` 或 `node` 不在 PATH 中，请显式指定 `DSH_BIN` 和 `NODE_BIN_DIR`。

## 卸载

下面命令会停止服务、取消开机启动并删除 systemd 单元；不会删除 dsh 数据或凭据：

```bash
./start_dsh_service.sh uninstall
```

## 故障排查

检查服务和端口：

```bash
systemctl status dsh-web.service --no-pager -l
port=$(cat /var/lib/dsh-web/port)
ss -ltnp | grep ":${port}"
curl -i "http://127.0.0.1:${port}/"
```

如果 `curl` 返回 `200`，但宿主机浏览器仍提示 `ERR_CONNECTION_REFUSED`，通常是浏览器和 dsh 不在同一个容器或 WSL 网络空间，需要使用对应的端口转发方式访问。端口以 `/var/lib/dsh-web/port` 或 `status` 输出为准，不再假设是 8080。

如果日志提示找不到 `dsh` 或 `node`，请检查 PATH，或显式设置 `DSH_BIN`、`NODE_BIN_DIR` 后重新运行 `install`。
