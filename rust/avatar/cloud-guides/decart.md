# Decart Lucy / Anywear 接入与使用说明

核对日期：2026-11-03。能力：实时视频换装。当前状态：**接口适配；媒体未接线**。所有厂商均未进行真实账号联调。

## 开通与准备

在 Decart 开通开发者账号与 API 计费，使用自己的 API Key。Anywear 的 Beta 免费额度不等于 API 免费额度。

当前宿主通过环境变量 `CB_DECART_API_KEY` 接收已有密钥。只在你自己的安全终端/宿主中配置，不把密钥写入文稿、提交到仓库、粘贴到聊天或放入网页。当前没有 Keychain 设置界面。

参数：`model: lucy-vton-3.6`。

## CallBridge 调用方式

返回短期 token、apiKey、expiresAt 与模型名。下一阶段用 Decart 官方 SDK 建立 WebRTC，输入必须来自用户主动允许的画面/素材。

厂商端点：`POST https://api.decart.ai/v1/client/tokens`。本机统一调用见 [API 契约](api.md)；配置不启动服务，创建请求必须明确确认本次云端处理和计费。

## 费用、数据与限制

官方模型页标准实时 2 credits/秒；定价页 $1=100 credits。价格是公开 API 单价，不代表商家协议价。

令牌限定本机 Origin、模型、60 秒有效期及会话最长时长。有效期只限制新连接，不能撤销已经连上的流。停止接口会返回 client_disconnect_required，客户端仍须断开传输。

数据会按厂商条款处理；本轮没有核实统一的数据驻留/零留存承诺，不能仅凭本地预览推定数据留在本机。

## 排错

- `CREDENTIAL_MISSING`：检查宿主进程是否收到对应环境变量，不要把 Key 写到前端。
- `UPSTREAM_AUTH`：到官方控制台核对 Key、权限与产品账号。
- `UPSTREAM_CREDITS` / `UPSTREAM_RATE_LIMIT`：检查额度与并发，不自动重复创建。
- `creation_unknown`：请求结果未知，先在厂商控制台检查；不要直接重试创建。
- `cleanup_failed`：重试停止或到控制台结束；本地停止不等于远端停止。
- `ADAPTER_NOT_IMPLEMENTED`：仅目录候选，不能靠填写 Key 启用。

## 官方来源与设计

- [开发文档](https://docs.platform.decart.ai/getting-started/client-tokens)
- [能力/接口说明](https://platform.decart.ai/models/lucy-vton)
- [价格](https://docs.platform.decart.ai/getting-started/pricing)
