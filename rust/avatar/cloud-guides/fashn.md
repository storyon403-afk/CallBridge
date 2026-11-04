# FASHN 接入与使用说明

核对日期：2026-11-03。能力：异步图片换装。当前状态：**接口适配；生成结果待人工选用**。所有厂商均未进行真实账号联调。

## 开通与准备

单独开通 FASHN Developer API 额度与 Key，准备已获授权的人物和单件服装图片。API 额度与应用订阅分开。

当前宿主通过环境变量 `CB_FASHN_API_KEY` 接收已有密钥。只在你自己的安全终端/宿主中配置，不把密钥写入文稿、提交到仓库、粘贴到聊天或放入网页。当前没有 Keychain 设置界面。

参数：`personImage + garmentImage（data URI）`。

## CallBridge 调用方式

提交 tryon-v1.6、num_samples=1，返回本地 session ID；显式 poll 返回任务状态及完成后的 HTTPS 图片地址。不会下载、导入或自动用于通话。

厂商端点：`POST https://api.fashn.ai/v1/run；GET /v1/status/{predictionId}`。本机统一调用见 [API 契约](api.md)；配置不启动服务，创建请求必须明确确认本次云端处理和计费。

## 费用、数据与限制

按需 $0.075/credit；tryon-v1.6 每输出图 1 credit。Try-On Max 和其他端点成本不同。

输入只接受 PNG/JPEG/WebP base64 data URI，每个字段最多 250,000 字符，总请求最多 512 KiB。当前不接收远程图片 URL。停止只停止本地等待，remote_job_pending 仍可查询，不能保证取消远端任务。

数据会按厂商条款处理；本轮没有核实统一的数据驻留/零留存承诺，不能仅凭本地预览推定数据留在本机。

## 排错

- `CREDENTIAL_MISSING`：检查宿主进程是否收到对应环境变量，不要把 Key 写到前端。
- `UPSTREAM_AUTH`：到官方控制台核对 Key、权限与产品账号。
- `UPSTREAM_CREDITS` / `UPSTREAM_RATE_LIMIT`：检查额度与并发，不自动重复创建。
- `creation_unknown`：请求结果未知，先在厂商控制台检查；不要直接重试创建。
- `cleanup_failed`：重试停止或到控制台结束；本地停止不等于远端停止。
- `ADAPTER_NOT_IMPLEMENTED`：仅目录候选，不能靠填写 Key 启用。

## 官方来源与设计

- [开发文档](https://docs.fashn.ai/api-reference/tryon-v1-6)
- [能力/接口说明](https://docs.fashn.ai/api-overview/api-fundamentals)
- [价格](https://help.fashn.ai/plans-and-pricing/api-pricing)
