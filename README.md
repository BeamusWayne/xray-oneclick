# xray-oneclick

单用户、无面板。一条命令在 Linux VPS 上安装 [Xray-core](https://github.com/XTLS/Xray-core)、写入 **VLESS + REALITY + Vision**、设 systemd 自启，并打印给 **Clash Verge / Clash Meta** 和 **Shadowrocket** 用的导入信息。

协议按「只用 IP、不要域名和证书」来选。仓库是私有的，所以**不能**对 `raw.githubusercontent.com` 做公开的 `curl | bash`。

## 在服务器上怎么跑

把本仓库弄到 VPS 上（任选一种），然后：

```bash
sudo bash install.sh
```

私有库常见拿法：

```bash
# 本机已登录 gh 时
gh repo clone BeamusWayne/xray-oneclick
cd xray-oneclick
sudo bash install.sh

# 或用带权限的 HTTPS（Personal Access Token）
git clone https://github.com/BeamusWayne/xray-oneclick.git
cd xray-oneclick
sudo bash install.sh

# 或在能访问此库的电脑上下载 install.sh，再 scp 到服务器
scp install.sh root@你的VPS:/root/
ssh root@你的VPS 'bash /root/install.sh'
```

需要：root、systemd（Debian / Ubuntu / CentOS 等）、能访问 GitHub 以下载官方 [Xray-install](https://github.com/XTLS/Xray-install)。

## 装完做什么

脚本会打印：

- 一行 `vless://...`：Shadowrocket 粘贴添加；Clash Verge 一般也能导入分享链接
- 一段 Clash YAML：也可直接拷服务器上的 `/usr/local/etc/xray/clash.yaml` 整份导入

再确认云厂商安全组放行脚本使用的 TCP 端口（默认 **443**）。本机 `ufw` / `firewalld` 若已开启，脚本会尝试放行。

以后只想再看一遍导入信息：

```bash
sudo bash install.sh --show
```

换新 UUID / 密钥（旧客户端会失效）：

```bash
sudo bash install.sh --reset
```

## 常用参数

| 参数 | 含义 | 默认 |
|---|---|---|
| `--port` | 监听端口 | `443` |
| `--sni` | REALITY 伪装站点 | `www.microsoft.com` |
| `--name` | 客户端里的节点名 | `xray-reality` |
| `--upgrade` | 用官方脚本升级 Xray-core | 否 |
| `--reset` | 重新生成密钥并覆盖配置 | 否 |
| `--show` | 只打印已有导入信息 | 否 |

443 被占用时：

```bash
sudo bash install.sh --port 8443
```

## 脚本会动哪些文件

- `/usr/local/bin/xray`：官方安装器放入
- `/usr/local/etc/xray/config.json`：服务端配置（含私钥）
- `/usr/local/etc/xray/oneclick.env`：本脚本状态，供 `--show` 使用
- `/usr/local/etc/xray/client.txt`、`clash.yaml`：客户端备份
- `systemctl enable --now xray`

分享链接和 YAML 等同节点密码，不要发到公开地方。
