# 魔珐星云 接入与使用说明

核对日期：2026-11-03。能力：3D 数字人。当前状态：**待适配**。所有厂商均未进行真实账号联调。

## 开通与准备

注册平台、选择形象，并确认书面商用授权。平台学习试用许可不代表应用分发许可。

所需参数：待确定 SDK 与账号资源参数。

## CallBridge 调用方式

计划对接实时驱动 SDK 与端侧渲染，先确认 macOS/WKWebView 支持、部署和资源协议。

厂商端点：`未实现`。本机统一调用见 [API 契约](api.md)；配置不启动服务，创建请求必须明确确认本次云端处理和计费。

## 费用、数据与限制

定价页基础音色 0.5 积分/分钟、Pro 2 积分/分钟；不据此推算人民币商用成本。

当前启动返回 ADAPTER_NOT_IMPLEMENTED。端侧渲染、动作映射、SDK 授权以及屏幕尺寸条款尚未验收。

数据会按厂商条款处理；本轮没有核实统一的数据驻留/零留存承诺，不能仅凭本地预览推定数据留在本机。

## 排错

- `CREDENTIAL_MISSING`：检查宿主进程是否收到对应环境变量，不要把 Key 写到前端。
- `UPSTREAM_AUTH`：到官方控制台核对 Key、权限与产品账号。
- `UPSTREAM_CREDITS` / `UPSTREAM_RATE_LIMIT`：检查额度与并发，不自动重复创建。
- `creation_unknown`：请求结果未知，先在厂商控制台检查；不要直接重试创建。
- `cleanup_failed`：重试停止或到控制台结束；本地停止不等于远端停止。
- `ADAPTER_NOT_IMPLEMENTED`：仅目录候选，不能靠填写 Key 启用。

## 官方来源与设计

- [开发文档](https://xingyun3d.com/)
- [能力/接口说明](https://xingyun3d.com/support/53-186)
- [价格](https://xingyun3d.com/support/51-182)
