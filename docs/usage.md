# sts-chat 使用指南

本指南面向日常使用 `sts-chat` 的设备所有者和客户端测试人员。开始前，维护者应已完成 [部署指南](deployment.md) 中的服务健康检查。

## 1. 启动客户端

在开发机上使用 Flutter 运行 H5 客户端：

```bash
cd src/client
flutter pub get
flutter run -d chrome --dart-define=GATEWAY_URL=http://localhost:8080
```

将地址替换为实际 Gateway 地址。远程 H5 场景使用 HTTPS Gateway；浏览器必须在安全上下文中才能访问麦克风。

可用的常见目标：

| 目标 | 命令 |
| --- | --- |
| macOS | `flutter run -d macos` |
| Windows | `flutter run -d windows` |
| Android | `flutter run -d <device-id>` |
| iOS | `flutter run -d <device-id>` |
| 发布 H5 | `flutter build web --dart-define=GATEWAY_URL=https://gateway.example` |

首次在新的平台构建时，让 Flutter 自动下载依赖和平台工具链。构建产物位于 `src/client/build/`，不应提交到仓库。

## 2. 配对设备

1. 打开客户端，在右上角打开设备配对操作。
2. 输入 Gateway 地址和 `ADMIN_SETUP_SECRET`。
3. 客户端会创建配对请求、以管理员身份批准该请求，并领取设备 JWT；凭据随后保存在平台安全存储中。
4. 页面出现“已连接”后即可发送文字或点击圆形按钮进行语音输入。

管理员密钥能够批准任意设备，因此只能由设备所有者在受信任设备上输入。不要通过聊天、截图或浏览器 URL 传播该值。

## 3. 进行语音聊天

1. 点击圆形按钮开始录音；首次使用时允许麦克风权限，Apple 平台还需允许语音识别权限。
2. 说完短句后等待转写和 Agent 回复。客户端显示“思考中”时可继续查看文字消息。
3. 回答到达后由本地 TTS 播放；再次点击按钮会停止持续监听。
4. 也可以在文字输入框中直接提交问题，作为没有语音识别服务时的回退。

语音识别和语音播报在客户端本地完成。服务端通过 LiveKit data channel 传输文本事件并调用模型，不会把原始麦克风音频作为 LiveKit 音轨上传。

## 4. 管理已配对设备

设备令牌默认由 Gateway 签发并可由管理员撤销。丢失设备、共享设备变更归属或怀疑令牌泄露时，找到设备 ID 后执行：

```bash
curl --fail -X DELETE "http://127.0.0.1:8080/v1/admin/devices/<device-id>" \
  -H "X-Admin-Secret: $ADMIN_SETUP_SECRET"
```

撤销后，该设备下次访问 Gateway 时会被拒绝；在客户端删除本地凭据并重新配对即可恢复使用。

## 5. 常见问题

| 现象 | 检查与处理 |
| --- | --- |
| 配对失败 | 确认 Gateway 地址、`ADMIN_SETUP_SECRET` 和反向代理路径；查看 `docker compose logs gateway`。 |
| 已配对但无法连接 Agent | 访问 `/health`，确认 LiveKit、Voice Agent、LLM 均可用；检查 `LIVEKIT_URL` 是客户端可访问的地址。 |
| 浏览器无法录音 | 使用 HTTPS 或 `localhost`，检查浏览器站点权限，并确认页面保持前台。 |
| Agent 返回模型不可用 | 检查模型容器/外部模型服务、`LLM_LOCAL_BASE_URL` 和 `docker compose logs voice-agent`。 |
| macOS 客户端不能编译 | 安装完整 Xcode，并选择其开发者目录：`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`。 |
| Windows 没有语音转写 | 确认系统语音识别组件和麦克风权限可用；仍可使用文字输入。 |

## 6. 隐私与安全边界

- `.env`、模型权重、SQLite 运行数据、Flutter 构建产物和虚拟环境均不进入 Git。
- 建议仅在家庭局域网或 Tailscale 私网提供服务，并通过 HTTPS/WSS 暴露给远程客户端。
- 管理员密钥、JWT 密钥和 LiveKit secret 都应使用随机值并定期轮换；轮换后重新配对相关设备。