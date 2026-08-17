# sts-chat 部署指南

本指南面向部署私有 `sts-chat` 服务的维护者。推荐的生产路径是 Docker Compose；macOS 的 LaunchAgent 配置仅适合本机开发或受控的单机运行。

## 1. 前置条件

- Docker Engine 或 Docker Desktop，且包含 Docker Compose v2。
- 本地模型路径，或一个可被 Docker 网络访问的 OpenAI 兼容模型服务。
- NVIDIA 部署需启用 Docker GPU 支持；Apple Silicon 使用 CPU Compose 覆盖层。
- 远程设备建议先加入同一 Tailscale Tailnet。不要将 Gateway 管理接口、SQLite 数据库或模型端口直接暴露到公网。
- 浏览器客户端需要 HTTPS（`localhost` 例外）才能稳定获取麦克风权限。

## 2. 配置环境变量

在仓库根目录创建本地配置文件：

```bash
cp .env.example .env
```

至少替换以下值，生成的密钥不要提交到 Git：

```bash
openssl rand -hex 32 # ADMIN_SETUP_SECRET
openssl rand -hex 32 # JWT_SECRET
openssl rand -hex 32 # LIVEKIT_API_SECRET
```

| 变量 | 是否必填 | 用途 |
| --- | --- | --- |
| `ADMIN_SETUP_SECRET` | 是 | 创建设备、批准配对和撤销设备的管理员密钥。 |
| `JWT_SECRET` | 是 | Gateway 签发设备 JWT 的签名密钥。 |
| `LIVEKIT_API_KEY`、`LIVEKIT_API_SECRET` | 是 | Gateway、LiveKit 与 Voice Agent 的服务凭据。 |
| `LIVEKIT_URL` | 是 | 客户端实际连接的 WSS/WS 地址；Docker 内部地址由 `LIVEKIT_INTERNAL_URL` 管理。 |
| `LLM_LOCAL_BASE_URL` | 视情况 | Docker 模型服务或外部 OpenAI 兼容模型服务的 `/v1` 地址。 |
| `CORS_ALLOWED_ORIGINS` | H5 时建议设置 | 允许访问 Gateway 的浏览器来源。 |

不要使用示例文件中的占位符启动生产服务。若通过反向代理提供远程访问，`LIVEKIT_URL` 必须是客户端可到达的 WSS 地址。

## 3. NVIDIA Docker 部署

1. 将 GGUF 模型放入 `models/`，默认文件名为 `Qwen2.5-3B-Instruct-Q4_K_M.gguf`。
2. 先渲染 Compose 配置，确认变量已被替换：

   ```bash
   docker compose --profile models config
   ```

3. 启动完整栈：

   ```bash
   docker compose --profile models up -d --build
   ```

4. 验证服务：

   ```bash
   docker compose ps
   curl --fail http://127.0.0.1:8080/health
   ```

`gateway`、`voice-agent` 和 `livekit` 会在 Docker 私有网络中通信。主机默认只绑定 Gateway 和 LiveKit TCP 控制端口到回环地址；按需通过 HTTPS 反向代理或 Tailscale 提供访问。

## 4. 使用外部模型服务

若模型运行在其他机器或由托管服务提供，请让容器能够访问其地址，并在 `.env` 设置：

```dotenv
LLM_LOCAL_BASE_URL=http://reachable-model-host:8080/v1
```

随后不启用 `models` profile：

```bash
docker compose up -d --build
```

在开始配对前检查 `/health` 中的 LLM 状态。空模型地址或不可达模型会让 Voice Agent 返回模型不可用错误。

## 5. macOS / Apple Silicon

使用 CPU 模型覆盖层启动 Docker 栈：

```bash
docker compose --profile cpu-model \
  -f docker-compose.yml \
  -f docker-compose.macos.yml \
  up -d --build
```

对应配置校验命令：

```bash
docker compose --profile cpu-model \
  -f docker-compose.yml \
  -f docker-compose.macos.yml \
  config
```

CPU 推理速度取决于模型和内存，不等同于 NVIDIA GPU 部署。完整原生 macOS 客户端构建还需要完整 Xcode，而不只是 Command Line Tools。

### 同机 H5 浏览器开发

`docker-compose.local.yml` 为 Docker Desktop 上的同机浏览器开发提供回环 WebRTC 候选地址和独立端口：Gateway 为 `8084`，LiveKit 信令为 `7882`，TCP/UDP 媒体端口为 `7883` 与 `50101-50201`。它只能用于浏览器和服务运行在同一台机器的场景，不可用于局域网、Tailscale 或公网访问。

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.macos.yml \
  -f docker-compose.local.yml \
  up -d --build gateway livekit voice-agent
```

随后将 H5 构建中的 `GATEWAY_URL` 设为 `http://localhost:8084`，并用本地静态服务器提供页面，例如 `python3 -m http.server 3002 --bind 127.0.0.1 --directory build/web`。如果需要本地模型，将同一命令加上 `--profile cpu-model`，并确保 `models/` 中存在对应 GGUF 文件。

### 可选：本机 LaunchAgent

`deploy/com.stschat.*.plist` 使用 `$HOME/Library/Application Support/StsChat` 作为运行时目录，并且不再依赖某个特定用户名。仅在本机直接运行 Agent、llama-server 或 H5 静态站点时安装它们。

```bash
runtime_dir="$HOME/Library/Application Support/StsChat"
install -d "$runtime_dir"
cp .env "$runtime_dir/.env"
rsync -a --delete src/voice_agent/ "$runtime_dir/voice_agent/"
python3 -m venv "$runtime_dir/.venv"
"$runtime_dir/.venv/bin/pip" install -r "$runtime_dir/voice_agent/requirements.txt"
rsync -a models/ "$runtime_dir/models/"

(
  cd src/client
  flutter pub get
  flutter build web --dart-define=GATEWAY_URL=http://localhost:8080
)
rsync -a --delete src/client/build/web/ "$runtime_dir/web/"

cp deploy/com.stschat.*.plist "$HOME/Library/LaunchAgents/"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.stschat.web.plist"
```

`com.stschat.agent` 默认连接 `ws://127.0.0.1:7880` 和 `http://127.0.0.1:8081/v1`。只有在本机 LiveKit 与 llama-server 已就绪且 Gateway 健康检查已指向该 Agent 时才启动它。不要与 Docker Compose 的 `voice-agent` 同时运行，否则会为同一 LiveKit Agent 名称创建重复 worker。

原生模型服务还要求 `/opt/homebrew/bin/llama-server` 可用，之后可单独加载：

```bash
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.stschat.llm.plist"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.stschat.agent.plist"
```

## 6. 运维、更新与停止

```bash
# 查看日志
docker compose logs --tail=200 gateway voice-agent livekit

# 更新源码后重新构建
docker compose --profile models up -d --build

# 停止容器但保留设备数据
docker compose down

# macOS Docker 冒烟测试（需要根目录 .env 和运行中的 Gateway）
./scripts/smoke-macos.sh
```

首次启动、模型升级或变更 `LIVEKIT_URL` 后，应重新执行 `/health` 检查。需要撤销丢失设备时，使用管理员密钥调用 `DELETE /v1/admin/devices/{deviceId}`；不要仅依赖客户端卸载。

从旧命名空间升级到 `sts-chat` 时，Gateway 的 JWT issuer/audience、LiveKit Agent 名称和数据 topic 都会改变。升级后请在每个客户端删除已保存的设备凭据并重新配对；旧版本客户端不能与新 Agent 协议互通。
