# Tavus CVI 接入与使用说明

核对日期：2026-11-03。能力：AI 对话数字人。当前状态：**接口适配；媒体未接线**。所有厂商均未进行真实账号联调。

## 开通与准备

在 Tavus 开通 API，准备 Face 和 PAL 资源。旧文章中的 replica_id/persona_id 与本次官方页面字段不同，当前适配采用 face_id/pal_id。

当前宿主通过环境变量 `CB_TAVUS_API_KEY` 接收已有密钥。只在你自己的安全终端/宿主中配置，不把密钥写入文稿、提交到仓库、粘贴到聊天或放入网页。当前没有 Keychain 设置界面。

参数：`faceId + palId；可选 context`。

## CallBridge 调用方式

创建 require_auth=true 的私有 Daily 房间，返回房间地址及 meeting token；不提供 meeting_url，也不自动加入 Zoom/Meet/真实会议。

厂商端点：`POST https://tavusapi.com/v2/conversations；POST /v2/conversations/{id}/end`。本机统一调用见 [API 契约](api.md)；配置不启动服务，创建请求必须明确确认本次云端处理和计费。

## 费用、数据与限制

主价格卡显示 $59/月 Starter、$397/月 Growth；官网混有其他比较表，额度必须在采购时再次核对。

关闭录制、限制会话时间、无人/离开超时；结束使用 end，不删除资源。对话 AI 不等于真人实时替身。尚未接入 Daily 媒体与音画同步。

数据会按厂商条款处理；本轮没有核实统一的数据驻留/零留存承诺，不能仅凭本地预览推定数据留在本机。

## 排错

- `CREDENTIAL_MISSING`：检查宿主进程是否收到对应环境变量，不要把 Key 写到前端。
- `UPSTREAM_AUTH`：到官方控制台核对 Key、权限与产品账号。
- `UPSTREAM_CREDITS` / `UPSTREAM_RATE_LIMIT`：检查额度与并发，不自动重复创建。
- `creation_unknown`：请求结果未知，先在厂商控制台检查；不要直接重试创建。
- `cleanup_failed`：重试停止或到控制台结束；本地停止不等于远端停止。
- `ADAPTER_NOT_IMPLEMENTED`：仅目录候选，不能靠填写 Key 启用。

## 官方来源与设计

- [开发文档](https://docs.tavus.io/api-reference/conversations/create-conversation)
- [能力/接口说明](https://docs.tavus.io/api-reference/conversations/end-conversation)
- [价格](https://www.tavus.io/pricing)
