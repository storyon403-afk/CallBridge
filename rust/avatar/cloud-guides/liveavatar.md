# LiveAvatar by HeyGen 接入与使用说明

核对日期：2026-11-03。能力：音频驱动数字人。当前状态：**接口适配；媒体未接线**。所有厂商均未进行真实账号联调。

## 开通与准备

开通独立 LiveAvatar 账号，准备 API Key 和已获授权的 Avatar ID。不要把 HeyGen Video 的额度或 Key 当作通用凭据。

当前宿主通过环境变量 `CB_LIVEAVATAR_API_KEY` 接收已有密钥。只在你自己的安全终端/宿主中配置，不把密钥写入文稿、提交到仓库、粘贴到聊天或放入网页。当前没有 Keychain 设置界面。

参数：`avatarId: 已有形象 UUID`。

## CallBridge 调用方式

以 LITE 模式创建并启动会话，返回客户端 LiveKit 地址/令牌及可用的 WebSocket 控制地址。长期 Key 和厂商管理会话 token 不返回给客户端。

厂商端点：`POST https://api.liveavatar.com/v1/sessions/token → /start；停止 /stop`。本机统一调用见 [API 契约](api.md)；配置不启动服务，创建请求必须明确确认本次云端处理和计费。

## 费用、数据与限制

官网 Essential $99/月、1,100 credits；Lite 每 credit 1 分钟，Full 每 credit 半分钟。套餐与额度须以控制台为准。

控制音频是 PCM16 / 24kHz；发送前需等远端连接就绪。当前未接入 Rust PCM 转换、WebSocket 音频、LiveKit 媒体订阅或虚拟设备。停止失败保留 cleanup_failed。

数据会按厂商条款处理；本轮没有核实统一的数据驻留/零留存承诺，不能仅凭本地预览推定数据留在本机。

## 排错

- `CREDENTIAL_MISSING`：检查宿主进程是否收到对应环境变量，不要把 Key 写到前端。
- `UPSTREAM_AUTH`：到官方控制台核对 Key、权限与产品账号。
- `UPSTREAM_CREDITS` / `UPSTREAM_RATE_LIMIT`：检查额度与并发，不自动重复创建。
- `creation_unknown`：请求结果未知，先在厂商控制台检查；不要直接重试创建。
- `cleanup_failed`：重试停止或到控制台结束；本地停止不等于远端停止。
- `ADAPTER_NOT_IMPLEMENTED`：仅目录候选，不能靠填写 Key 启用。

## 官方来源与设计

- [开发文档](https://docs.liveavatar.com/docs/lite-mode/lifecycle)
- [能力/接口说明](https://docs.liveavatar.com/api-reference/sessions/create-session-token)
- [价格](https://www.liveavatar.com/)
