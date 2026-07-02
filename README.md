# OpenVPN 一键安装脚本

一个支持 Debian/Ubuntu/CentOS 的 OpenVPN 一键安装与管理脚本。

## 目录

- [快速开始](#快速开始)
- [安装步骤](#安装步骤)
- [管理功能](#管理功能)
- [代码架构](#代码架构)
- [常见问题](#常见问题)
- [技术细节](#技术细节)

---

## 快速开始

```bash
# 1. 上传脚本到服务器
# 2. 修复换行符（如果从 Windows 上传）
sed -i 's/\r$//' openvpn.sh

# 3. 以 root 运行
sudo bash openvpn.sh
```

## 安装步骤

脚本采用交互式安装，依次提示以下配置：

| 步骤 | 配置项 | 默认值 | 说明 |
|------|--------|--------|------|
| 1 | 同意协议 | `n` | 输入 `y` 继续 |
| 2 | 服务器 IP | 自动检测 | 直接回车使用默认值 |
| 3 | 传输协议 | `1` (UDP) | 建议 UDP，速度更快 |
| 4 | 端口 | `10088` | 自定义端口号 |
| 5 | DNS | `1` (系统DNS) | 推荐选 `2` GoogleDNS |
| 6 | 客户端名称 | `client` | 英文单词，不含特殊字符 |

安装完成后，客户端配置文件生成在 `~/客户端名称.ovpn`，将其导入 OpenVPN 客户端即可连接。

### DNS 选项说明

| 选项 | DNS 提供商 | 地址 |
|------|-----------|------|
| 1 | 系统 DNS | 自动获取 |
| 2 | Google DNS | `8.8.8.8`, `8.8.4.4` |
| 3 | OpenDNS | `208.67.222.222`, `208.67.220.220` |
| 4 | NTT | `129.250.35.250`, `129.250.35.251` |
| 5 | Hurricane Electric | `74.82.42.42` |
| 6 | Verisign | `64.6.64.6`, `64.6.65.6` |

## 管理功能

已安装 OpenVPN 后，再次运行脚本进入管理面板：

```
OpenVpn管理面板
-----------------------------------------------
   1) 添加新用户
   2) 删除用户
   3) 删除OPENVPN
   4) 退出
```

### 1. 添加新用户
生成新的客户端证书和 `.ovpn` 配置文件。

### 2. 删除用户
吊销指定客户端的证书，使其无法再连接 VPN。

### 3. 删除 OPENVPN
完全卸载 OpenVPN，包括：
- 停止并移除 OpenVPN 服务
- 清理 iptables / firewalld 规则
- 删除所有证书和配置文件
- 卸载 OpenVPN 软件包

### 4. 退出
退出管理面板。

---

## 代码架构

### 文件结构

```
openvpn.sh                    # 主脚本（单一文件）
├── 前置检查 (行 1-35)        # 运行环境校验
├── newclient() (行 37-52)    # 客户端配置生成函数
├── IP 检测 (行 54-67)        # 内网/公网 IP 自动识别
├── 管理面板 (行 69-178)      # 已安装后的管理菜单
│   ├── 添加用户
│   ├── 删除用户
│   ├── 卸载 OpenVPN
│   └── 退出
└── 安装流程 (行 179-450)     # 首次安装逻辑
    ├── 用户交互配置
    ├── 软件安装 (行 231-250)
    ├── PKI/证书生成 (行 251-264)
    ├── server.conf 生成 (行 265-334)
    ├── 网络配置 (行 335-384)
    └── 客户端配置生成 (行 410-450)
```

### 核心函数：`newclient()`

```bash
newclient () {
    cp /etc/openvpn/client-common.txt ~/$1.ovpn
    echo "<ca>" >> ~/$1.ovpn
    cat /etc/openvpn/easy-rsa/pki/ca.crt >> ~/$1.ovpn
    echo "</ca>" >> ~/$1.ovpn
    # ... cert, key, tls-auth
}
```

将客户端通用模板与证书、密钥、TLS 认证密钥拼接为完整的 `.ovpn` 配置文件，支持内联证书，无需额外文件。

### 执行流程

```
开始
  ├─ 检查 Shell 类型（必须 bash）
  ├─ 检查 root 权限
  ├─ 检查 TUN 设备
  ├─ 检查 OS 兼容性
  ├─ 检测已有安装？
  │   ├─ 是 → 管理面板
  │   └─ 否 → 安装流程
  │       ├─ 收集用户配置
  │       ├─ 安装 OpenVPN + EasyRSA
  │       ├─ 生成 CA/证书/DH/CRL
  │       ├─ 生成 server.conf
  │       ├─ 配置网络（ip_forward, iptables, NAT）
  │       ├─ 配置 CAP_NET_ADMIN
  │       ├─ 启动服务
  │       └─ 生成客户端 .ovpn
  └─ 完成
```

---

## 常见问题

### Q: 运行报错 `syntax error near unexpected token 'elif'`

**原因**：文件包含 Windows 换行符（CRLF）。

**解决**：
```bash
sed -i 's/\r$//' openvpn.sh
bash openvpn.sh
```

### Q: 连接 VPN 后无法访问网页

**排查步骤**：

1. 检查 VPN 是否成功连接（查看日志 `systemctl status openvpn@server.service`）
2. ping VPN 网关 `10.8.0.1`，不通说明隧道问题
3. ping 外网 IP `8.8.8.8`，通但打不开网页说明 DNS 问题，不通说明 NAT 问题
4. 腾讯云/阿里云等需在**安全组放行端口**（UDP 10088 或你自定义的端口）

### Q: 云服务器 NAT 环境不通

**原因**：云服务器的内网 IP 和公网 IP 不同，SNAT 用了错误的 IP。

**解决**：脚本已自动使用 `MASQUERADE` 替代固定 IP 的 SNAT，无需手动处理。

### Q: 如何更换端口

修改 `/etc/openvpn/server.conf` 中的 `port` 和客户端 `.ovpn` 中的 `remote`，然后：
```bash
systemctl restart openvpn@server.service
```

---

## 技术细节

### 生成的配置文件

| 文件 | 路径 | 说明 |
|------|------|------|
| server.conf | `/etc/openvpn/server.conf` | 服务器主配置 |
| client-common.txt | `/etc/openvpn/client-common.txt` | 客户端配置模板 |
| ca.crt | `/etc/openvpn/easy-rsa/pki/ca.crt` | CA 根证书 |
| ta.key | `/etc/openvpn/ta.key` | TLS 认证密钥 |
| crl.pem | `/etc/openvpn/crl.pem` | 证书吊销列表 |
| *.ovpn | `~/客户端名.ovpn` | 客户端配置文件 |

### server.conf 关键配置

```
port 10088                    # 监听端口
proto udp                     # 传输协议
dev tun                       # TUN 模式（三层路由）
topology subnet               # 子网拓扑模式
server 10.8.0.0 255.255.255.0 # VPN 子网
push "redirect-gateway def1"  # 全局流量代理
auth SHA512                   # 认证算法
cipher AES-256-CBC            # 数据加密
comp-lzo                      # LZO 压缩
user nobody / group nogroup   # 降权运行
persist-key / persist-tun     # 重连保持密钥和 tun 设备
```

### 网络架构

```
客户端 (10.8.0.x)
    │
    │ UDP/TCP 加密隧道
    │
    ▼
服务器 tun0 (10.8.0.1)
    │
    │ iptables FORWARD
    │
    ▼
服务器 eth0 (内网 IP)
    │
    │ iptables MASQUERADE (SNAT)
    │
    ▼
外网
```

### 安全特性

- **TLS 认证**：`tls-auth ta.key` 防止未授权连接和 DDoS
- **证书吊销**：CRL 机制支持吊销已泄露的客户端证书
- **权限降级**：OpenVPN 以 `nobody/nogroup` 运行
- **HMAC 认证**：SHA-512 消息认证
- **数据加密**：AES-256-CBC 加密通道

### 支持的操作系统

| 系统 | 版本 | 状态 |
|------|------|------|
| Debian | 8+ | ✅ 支持 |
| Ubuntu | 16.04+ | ✅ 支持 |
| CentOS | 7+ | ✅ 支持 |
| CentOS | 5 | ❌ 不支持 |
| 其他 | - | ❌ 不支持 |

### 系统要求

- root 权限
- TUN 设备已启用（`/dev/net/tun`）
- bash shell（不支持 dash）
- 网络可访问外网（下载依赖和 EasyRSA）
