# HeyGen Video 接入与使用说明

核对日期：2026-11-03。能力：异步数字人视频。当前状态：**待适配**。所有厂商均未进行真实账号联调。

## 开通与准备

开通 HeyGen API 权限，核对套餐是否包含拟使用的接口，准备授权的形象和声音资产。

所需参数：待确定 avatar、voice、script 参数。

## CallBridge 调用方式

计划添加视频任务创建、查询、取消能力核对以及素材导入。实时音频驱动请看独立 LiveAvatar 页面。

厂商端点：`未实现`。本机统一调用见 [API 契约](api.md)；配置不启动服务，创建请求必须明确确认本次云端处理和计费。

## 费用、数据与限制

产品 Creator 月付 $29、600 credits；API 额度与权限需单独核对。

不会把 Creator 订阅直接当作 API 权限；异步视频生成不能标记为实时通话已接通。

数据会按厂商条款处理；本轮没有核实统一的数据驻留/零留存承诺，不能仅凭本地预览推定数据留在本机。

## 排错

- `CREDENTIAL_MISSING`：检查宿主进程是否收到对应环境变量，不要把 Key 写到前端。
- `UPSTREAM_AUTH`：到官方控制台核对 Key、权限与产品账号。
- `UPSTREAM_CREDITS` / `UPSTREAM_RATE_LIMIT`：检查额度与并发，不自动重复创建。
- `creation_unknown`：请求结果未知，先在厂商控制台检查；不要直接重试创建。
- `cleanup_failed`：重试停止或到控制台结束；本地停止不等于远端停止。
- `ADAPTER_NOT_IMPLEMENTED`：仅目录候选，不能靠填写 Key 启用。

## 官方来源与设计

- [开发文档](https://docs.heygen.com/)
- [能力/接口说明](https://www.heygen.com/)
- [价格](https://www.heygen.com/pricing)
