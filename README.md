# 端口流量狗 · 钉钉通知美化安装版

基于 [zywe03/realm-xwPF](https://github.com/zywe03/realm-xwPF) 的 **端口流量狗 v1.4.3**，仅定制 Webhook 状态通知的纯文本排版；保留原作者的监控、流量计数、额度、限速、重置和通知功能。

## 一键安装

支持原项目适用的 **Debian / Ubuntu**，以 root 身份运行：

```bash
curl -fsSL https://raw.githubusercontent.com/jiaxinzi1212/port-traffic-dog-custom/main/install.sh -o /tmp/dog-install.sh && bash /tmp/dog-install.sh
```

如果尚未以 root 登录，可将末尾改为 `sudo bash /tmp/dog-install.sh`。

安装器会自动检查并在 Debian/Ubuntu 缺少 Python 3 时使用 `apt-get` 安装依赖，然后下载原版主脚本、检查版本与函数结构、集成通知美化模板、执行 Bash 语法检查，随后启动配置菜单。**不会自动帮你配置钉钉机器人或监控端口。**

首次安装完成后用 `dog` 打开菜单：添加需要监控的端口，并在通知设置里选择 **钉钉 (dingtalk)**，填写群机器人的 Webhook URL 和服务器名称，启用状态通知。每小时推送频率可以在原菜单内设置。测试：

```bash
dog --send-webhook-status
```

## 消息样式

- 🖥️ 服务器名称、🕒 汇报时间
- 🌐 各网卡整机流量、上行与下行
- 🟢 监控状态、监控项数量、端口汇总流量
- 🔌 逐端口总流量、入站、出站、备注
- 📦 单/双向额度、⚡ 限速、🔄 重置日期
- ⚠️ 已超限与已截止提示（如适用）

取消原状态通知的项目宣传横幅和链接，减少手机端过长的单行展示。**整机统计与端口统计沿用原脚本的计费/流量口径**，并非修改统计规则。

## 升级及兼容性

- 此安装器仅适配并校验原版 **v1.4.3**。原作者更新版本或函数结构变化时，安装器会拒绝修改，避免盲目兼容。
- 已安装主程序时会先备份旧主脚本再替换；保留原配置目录 `/etc/port-traffic-dog`。但仍建议自己先备份 VPS/配置。
- 原版菜单的脚本更新可能覆盖自定义排版；升级前应先适配新版本。
- **不要公开上传** `/etc/port-traffic-dog/config.json`、Webhook URL、Token、私钥等敏感信息。
- 本仓库的 `install.sh` 是安装器；它在部署时向原作者仓库下载主程序。运行前应自行审查仓库中的脚本。脚本未在所有 VPS 环境中进行端到端验证。

## 原项目及许可证

原项目：[zywe03/realm-xwPF](https://github.com/zywe03/realm-xwPF) · [原项目 MIT 许可证](https://github.com/zywe03/realm-xwPF/blob/main/LICENSE)（Copyright © 2025 zywe）。本仓库与原作者无官方关联，尊重原作者版权和开源许可。
