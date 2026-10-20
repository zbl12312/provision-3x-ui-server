# provision-3x-ui-server

一键在 Linux 服务器上部署 / 复用 3X-UI（Xray 代理管理面板），并交付经过真实流量验证的 VLESS TCP 与 SOCKS5 访问信息。

## 功能

- 通过密码认证 SSH 连接服务器；已安装 3X-UI 时直接复用，未安装时自动安装
- 创建独立的 VLESS TCP inbound 与带认证的 SOCKS5（mixed）inbound
- 生成专用 API Token、面板凭据、VLESS 二维码 PNG 与结构化交付 JSON
- 通过真实代理请求验证出口 IP，API 成功不等于交付完成
- 支持 `--dry-run` 预览计划、`--resume` 恢复未完成的任务

## 安装

将整个目录（`SKILL.md`、`agents/`、`references/`、`scripts/`）放入智能体的用户技能根目录即可作为 Skill 使用；也可以单独运行 `scripts/provision_3x_ui.sh`。

## 使用

```bash
# 交互式（静默提示输入 SSH 密码）
scripts/provision_3x_ui.sh --host SERVER --ssh-port 22 --ssh-user root

# 非交互（密码仅注入进程环境，不写入命令行）
PROVISION_SSH_PASSWORD='...' scripts/provision_3x_ui.sh --host SERVER --ssh-port 22

# 仅检查输入并预览计划
scripts/provision_3x_ui.sh --host SERVER --dry-run
```

可选参数：`--panel-port`、`--vless-port`、`--socks-port`、`--output-dir`。

## 运行依赖

本地：`bash`、`curl`、`jq`、`ssh`、`base64`、`perl`、`expect`（脚本内嵌）。
远端：Ubuntu / Debian / CentOS / RHEL / AlmaLinux / Rocky / Fedora / Arch 任一发行版，root 权限，至少 1.5 GB 可用磁盘。

## 安全说明

- SSH 密码绝不写入命令行、日志或聊天记录
- VLESS TCP 与 SOCKS5 均不加密传输流量，请勿在不受信网络中直接使用
