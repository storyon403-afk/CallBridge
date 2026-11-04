# ZEGO 即构 接入与使用说明

核对日期：2026-11-03。能力：文本/音频驱动数字人。当前状态：**待适配**。所有厂商均未进行真实账号联调。

## 开通与准备

向即构开通数字人服务，建立项目和形象，确认具体账号认证、地域和报价。

所需参数：待确定 AppID、签名、形象与 RTC 配置。

## CallBridge 调用方式

计划接入官方数字人控制 API 与 ZEGO RTC 接收；暂不创建请求、签名或远端会话。

厂商端点：`未实现；不得用通用 HTTP 模板假冒已接入`。本机统一调用见 [API 契约](api.md)；配置不启动服务，创建请求必须明确确认本次云端处理和计费。

## 费用、数据与限制

未确认统一公开单价，按厂商报价。

当前目录可查询，调用返回 ADAPTER_NOT_IMPLEMENTED。需补签名、形象生命周期、RTC 解码、退出清理与合同使用范围。

数据会按厂商条款处理；本轮没有核实统一的数据驻留/零留存承诺，不能仅凭本地预览推定数据留在本机。

## 排错

- `CREDENTIAL_MISSING`：检查宿主进程是否收到对应环境变量，不要把 Key 写到前端。
- `UPSTREAM_AUTH`：到官方控制台核对 Key、权限与产品账号。
- `UPSTREAM_CREDITS` / `UPSTREAM_RATE_LIMIT`：检查额度与并发，不自动重复创建。
- `creation_unknown`：请求结果未知，先在厂商控制台检查；不要直接重试创建。
- `cleanup_failed`：重试停止或到控制台结束；本地停止不等于远端停止。
- `ADAPTER_NOT_IMPLEMENTED`：仅目录候选，不能靠填写 Key 启用。

## 官方来源与设计

- [开发文档](https://doc-zh.zego.im/aigc-digital-human-server/introduction/overview)
- [能力/接口说明](https://www.zego.im/html/digital-human-api)
