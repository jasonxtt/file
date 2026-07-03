# Natter + RouterOS + VPS YAML Auto-Sync Bundle

这套 bundle 用来把内网服务通过 `Natter` 打到公网，并自动同步两类信息：

- 主路由 `RouterOS` 上的 `dst-nat` 规则
- VPS 上一个或多个订阅 YAML 的 `server` / `port`

它适合这样的场景：

- 内网服务机没有公网 IPv4
- 路由器支持 `UPnP`
- 想把若干 `TCP/UDP` 端口暴露给外部客户端
- 希望手机或电脑端始终使用一个固定订阅 URL，不手改节点出口

## 1. Bundle 里有什么

```text
natter-bundle/
├── env/natter-sync.env.example
├── examples/
│   ├── Egern-web.example.yaml
│   ├── hy2-home-natter.example.yaml
│   └── stash-ph-web-natter.example.yaml
├── scripts/
│   ├── healthcheck.sh
│   ├── install.sh
│   ├── natter.py
│   └── natter_sync.py
└── systemd/
    ├── natter-sync.service
    ├── natter-tcp-56001.service
    ├── natter-tcp-56004.service
    └── natter-udp-56003.service
```

其中：

- `install.sh` 负责把同步脚本、环境文件模板、systemd 单元安装到系统目录
- `natter_sync.py` 负责解析 `Natter` 日志，更新 RouterOS 和远端 YAML
- `examples/` 提供 `stash` / `egern` / `clash(mihomo)` 示例订阅
- `healthcheck.sh` 用来快速查看服务状态和同步结果

## 2. 运行逻辑

每轮同步会做这些事：

1. 从 `journalctl` 解析各个 `Natter` 服务的最新映射
2. 得到公网 `server`、公网 `port`、本地监听 `local_port`
3. 如果配置了 RouterOS，则自动 PATCH 对应 NAT 规则
4. 通过 SSH 登录 VPS，改写一个或多个订阅 YAML
5. 把当前状态写到 `/var/lib/natter-sync/state.json`

## 3. 你需要准备什么

### 3.1 一台内网转发机

要求：

- Linux
- 能访问内网目标服务
- 能访问公网
- 能运行 `systemd` 和 `Python 3`

示例：

```text
FORWARDER_IP=10.0.0.11
```

### 3.2 一台内网服务机

真正承载业务端口的机器。

示例：

```text
LAN_SERVICE_IP=10.0.0.6
```

### 3.3 一台 VPS

要求：

- 有固定公网 IP
- 能通过 `SSH` 登录
- 能放一个对外可访问的 YAML 文件
- 最好已经有 `Nginx` 和一个静态文件服务或文件目录

示例：

```text
VPS_IP=203.0.113.10
VPS_SSH_PORT=22
```

### 3.4 一个域名和 HTTPS

- 你能控制 DNS
- `A` 记录指向 VPS
- 建议使用 `Let's Encrypt`

示例：

```text
SUB_DOMAIN=stash.example.com
```

### 3.5 主路由

推荐先明确主路由类型：

- `RouterOS`
- `iKuai`
- 其他

本文的 RouterOS 自动 NAT 同步只对 `RouterOS REST API` 生效；如果不是 RouterOS，也可以只用 YAML 自动同步。

示例：

```text
ROUTER_IP=10.0.0.1
```

### 3.6 一个固定订阅 URL token

示例：

```text
RANDOM_LONG_TOKEN=9f3b7f2c2a5b4d6e8c1f0a9b7d3e5c11
```

### 3.7 一个专用 SSH key

这个 key 只给自动同步脚本用，不要复用你平时的管理私钥。

## 4. 支持的节点名和 YAML 格式

脚本按节点名精确改 `server` 和 `port`，名称必须和配置一致。

默认目标名：

- `ss-in-natter`
- `hy2-in-natter`
- `anytls-in-natter`

支持的远端格式：

- `stash`
  - 识别形如 `- name: ss-in-natter`
- `egern`
  - 识别 `- shadowsocks:` / `- hysteria2:` 块内的 `name:`
- `clash`
  - 识别 `name:` / `server:` / `port:` 结构
- `v2rayn`
  - 直接改现有 txt 订阅里 `#ss-in-natter` / `#hy2-in-natter` 对应分享链接的 `host:port`

示例文件：

- `examples/stash-ph-web-natter.example.yaml`
- `examples/Egern-web.example.yaml`
- `examples/hy2-home-natter.example.yaml`

## 5. 部署前先确认内网端口可达

在转发机上测试 TCP：

```bash
timeout 5 bash -lc '</dev/tcp/LAN_SERVICE_IP/56001' && echo tcp-open || echo tcp-closed
timeout 5 bash -lc '</dev/tcp/LAN_SERVICE_IP/56004' && echo tcp-open || echo tcp-closed
```

UDP 不像 TCP 那样容易直接探测，至少要确认：

- 应用确实监听在目标 UDP 端口
- 转发机到服务机网络可达

## 6. 安装 Natter

bundle 自带了 `scripts/natter.py`，你也可以手工拉最新版本到系统目录。最终目标是让下面这个路径存在：

```text
/opt/natter/natter.py
```

安装示例：

```bash
mkdir -p /opt/natter
curl -fsSL https://raw.githubusercontent.com/MikeWang000000/Natter/master/natter.py -o /opt/natter/natter.py
chmod 755 /opt/natter/natter.py
python3 /opt/natter/natter.py --help
```

## 7. 修改 bundle 自带的 systemd 服务

`systemd/` 里的服务文件默认写的是示例地址：

- 转发机 `10.0.0.11`
- 服务机 `10.0.0.6`

部署前请先按你的环境修改下面几项：

- `-i FORWARDER_IP`
- `-t LAN_SERVICE_IP`
- 需要的端口号

当前 bundle 预置了三条：

- `natter-tcp-56001.service`
- `natter-udp-56003.service`
- `natter-tcp-56004.service`

对应关系是：

- `56001/tcp` -> `ss-in-natter`
- `56003/udp` -> `hy2-in-natter`
- `56004/tcp` -> `anytls-in-natter`

如果你不需要 `56004/tcp`，可以不启用它，但要同步调整 `TARGETS_JSON` 和远端 YAML。

## 8. 在 VPS 准备订阅 YAML

先把示例 YAML 复制到 VPS 的真实路径，再填好密码、SNI 等业务字段。

例如：

```bash
mkdir -p /root/docker/gohttpserver/stash
cp stash-ph-web-natter.example.yaml /root/docker/gohttpserver/stash/stash-ph-web-natter.yaml
```

或者使用其他示例：

- `Egern-web.example.yaml`
- `hy2-home-natter.example.yaml`

注意：

- 自动同步只会改 `server` 和 `port`
- 密码、加密方式、SNI、ALPN 等其余字段需要你自己提前写好
- YAML 中目标节点名必须和 `TARGETS_JSON` 一致

## 9. 生成自动同步用 SSH key

在转发机上执行：

```bash
mkdir -p /root/.ssh
chmod 700 /root/.ssh
ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519_natter_sync
cat /root/.ssh/id_ed25519_natter_sync.pub
```

把输出的公钥追加到 VPS 的：

```text
/root/.ssh/authorized_keys
```

再把 VPS host key 加入转发机：

```bash
ssh-keyscan -p VPS_SSH_PORT VPS_IP >> /root/.ssh/known_hosts
chmod 600 /root/.ssh/known_hosts
```

最后测试免交互 SSH：

```bash
ssh -i /root/.ssh/id_ed25519_natter_sync -p VPS_SSH_PORT root@VPS_IP
```

能直接登录就说明自动同步所需的 SSH 前置条件已经齐了。

## 10. 安装 bundle

在转发机上把整个目录放到例如：

```text
/root/natter-bundle
```

然后执行：

```bash
cd /root/natter-bundle
chmod +x scripts/install.sh scripts/healthcheck.sh
./scripts/install.sh
```

这一步会安装：

- `/opt/natter/natter_sync.py`
- `/etc/natter-sync/natter-sync.env`
- `/etc/systemd/system/natter-*.service`

`install.sh` 不会自动下载 `natter.py`，也不会自动替你改 IP 和端口，所以第 6、7 步仍然需要手工完成。

## 11. 配置 `/etc/natter-sync/natter-sync.env`

默认模板见：

- `env/natter-sync.env.example`

关键字段如下：

```dotenv
POLL_SECONDS=15
STATE_PATH=/var/lib/natter-sync/state.json

SSH_KEY=/root/.ssh/id_ed25519_natter_sync
SSH_HOST=203.0.113.10
SSH_PORT=22
SSH_USER=root

ROUTER_IP=10.0.0.1
ROS_USER=router_api_user
ROS_PASS=router_api_pass
ROS_TARGET_IP=10.0.0.11

TARGETS_JSON={"ss-in-natter":{"service":"natter-tcp-56001.service","proto":"tcp","ros_comment":"natter-56001"},"anytls-in-natter":{"service":"natter-tcp-56004.service","proto":"tcp","ros_comment":"natter-56004"},"hy2-in-natter":{"service":"natter-udp-56003.service","proto":"udp","ros_comment":"natter-56003"}}

REMOTE_YAMLS_JSON={"stash":{"path":"/root/docker/gohttpserver/stash/stash-ph-web-natter.yaml","format":"stash"},"egern":{"path":"/root/docker/gohttpserver/egern/Egern-web.yaml","format":"egern"},"clash":{"path":"/root/docker/gohttpserver/clash/hy2-home-natter.yaml","format":"clash","targets":["ss-in-natter","hy2-in-natter"]},"v2rayn":{"path":"/root/docker/gohttpserver/v2rayN/natter-v2rayn.txt","format":"v2rayn","targets":["ss-in-natter","hy2-in-natter"]}}
```

说明：

- `TARGETS_JSON` 定义“目标节点名 -> Natter 服务 -> RouterOS 注释名”
- `REMOTE_YAMLS_JSON` 定义“要改哪些远端订阅文件、各自格式是什么”
- `targets` 可选，用来限制某个 YAML 只同步其中一部分节点
- `v2rayn` 格式要求目标 txt 已经存在，并保留 `#ss-in-natter` / `#hy2-in-natter` 这两个片段，脚本只替换对应链接的 `host:port`

如果你不是 RouterOS，只想更新 VPS YAML，可以把这四项留空：

- `ROUTER_IP`
- `ROS_USER`
- `ROS_PASS`
- `ROS_TARGET_IP`

这样脚本会跳过 NAT 同步，但仍然继续更新远端 YAML。

## 12. 如果启用 RouterOS 自动 NAT，同步前先建好规则

脚本不会帮你新建规则，只会按 `ros_comment` 去修改已有规则。

你需要先在 RouterOS 中准备好对应 `comment` 的规则，例如：

- `natter-56001`
- `natter-56003`
- `natter-56004`

规则原则：

- `to-addresses` 应该指向转发机 `FORWARDER_IP`
- `to-ports` 应该等于对应本地端口
- 如果 RouterOS 的 `WAN/PPPoE` 是公网 IP，`dst-port` 通常使用 Natter 公网映射端口
- 如果 RouterOS 的 `WAN/PPPoE` 是私网或 `CGNAT`，`dst-port` 应使用 `Natter local_port`，不要误写成公网映射端口

脚本会自动判断 WAN 地址是不是私网 / `CGNAT`，并选择公网端口还是本地端口来回写 `dst-port`。

补充说明：

- 如果 RouterOS 里已经有全局 UDP `endpoint-independent-nat` 规则，不要默认删掉
- 它可能正在服务其他设备或其他打洞流量
- 如果你的主路由是 `iKuai` 或其他系统，看到 RouterOS 部分显示 `skipped` 是正常的

## 13. 给订阅做一个固定 URL

推荐做法是：

```text
手机 App -> https://SUB_DOMAIN/sub/RANDOM_LONG_TOKEN.yaml -> VPS Nginx -> 实际 YAML 文件
```

这样手机端永远只用一个地址，底层 YAML 内容由同步脚本自动改写。

一个最小 Nginx 示例：

```nginx
server {
    listen 80;
    server_name SUB_DOMAIN;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name SUB_DOMAIN;

    ssl_certificate /etc/letsencrypt/live/SUB_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/SUB_DOMAIN/privkey.pem;

    location = /sub/RANDOM_LONG_TOKEN.yaml {
        proxy_pass http://127.0.0.1:8080/stash/stash-ph-web-natter.yaml;
        proxy_set_header Host $host;
    }

    location / {
        return 404;
    }
}
```

如果上游文件服务本身还需要 Basic Auth，可以先生成认证头：

```bash
printf 'HTTP_USER:HTTP_PASS' | base64
```

然后在 `location` 里补：

```nginx
proxy_set_header Authorization "Basic BASE64_USERPASS";
```

修改完成后重载：

```bash
nginx -t && systemctl reload nginx
```

最终给客户端的订阅地址就是：

```text
https://SUB_DOMAIN/sub/RANDOM_LONG_TOKEN.yaml
```

## 14. 启动服务

```bash
systemctl daemon-reload
systemctl enable --now natter-tcp-56001.service
systemctl enable --now natter-udp-56003.service
systemctl enable --now natter-tcp-56004.service
systemctl enable --now natter-sync.service
```

查看状态：

```bash
systemctl status natter-tcp-56001.service
systemctl status natter-udp-56003.service
systemctl status natter-tcp-56004.service
systemctl status natter-sync.service
```

## 15. 如何验证

### 15.1 看 Natter 是否正常打洞

```bash
journalctl -u natter-tcp-56001.service -n 50 --no-pager -o cat
journalctl -u natter-udp-56003.service -n 50 --no-pager -o cat
journalctl -u natter-tcp-56004.service -n 50 --no-pager -o cat
```

### 15.2 看同步器是否正常

```bash
journalctl -u natter-sync.service -n 50 --no-pager -o cat
cat /var/lib/natter-sync/state.json
```

### 15.3 看 VPS 上的 YAML 是否已改写

```bash
sed -n '1,120p' /root/docker/gohttpserver/stash/stash-ph-web-natter.yaml
```

### 15.4 如果启用了 RouterOS，同步 NAT 是否成功

```bash
curl -sS -u ROS_USER:ROS_PASS http://ROUTER_IP/rest/ip/firewall/nat
```

重点检查这些 `comment` 对应的规则：

- `natter-56001`
- `natter-56003`
- `natter-56004`

重点看：

- `dst-port`
- `to-addresses`
- `to-ports`

### 15.5 看固定订阅 URL 是否可用

```bash
curl -I https://SUB_DOMAIN/sub/RANDOM_LONG_TOKEN.yaml
curl https://SUB_DOMAIN/sub/RANDOM_LONG_TOKEN.yaml
```

### 15.6 一键健康检查

```bash
cd /root/natter-bundle
./scripts/healthcheck.sh
```

## 16. 常见问题

### 16.1 `missing YAML entries`

说明远端 YAML 里缺少 `TARGETS_JSON` 中声明的节点名。

检查：

- 节点 `name` 是否真的存在
- 拼写是否与 `ss-in-natter` / `hy2-in-natter` / `anytls-in-natter` 完全一致
- 某个 `clash` YAML 是否设置了 `targets`

### 16.2 `not_routeros_json`

说明脚本访问的并不是 RouterOS REST JSON。

检查：

- `ROUTER_IP` 是否填对
- RouterOS REST API 是否已启用
- 用户名密码是否正确
- 目标设备是不是其实不是 RouterOS

### 16.3 SSH 连接失败

检查：

- VPS 公钥是否加入 `authorized_keys`
- 转发机 `known_hosts` 是否已有 VPS host key
- `SSH_HOST` / `SSH_PORT` / `SSH_USER` / `SSH_KEY` 是否正确
- 手工执行一次 `ssh -i ...` 是否能无交互登录

### 16.4 订阅 URL 不可访问

检查：

- 域名解析是否正确
- `Nginx` 是否 reload 成功
- HTTPS 证书是否正常
- token 路径是否和配置一致
- 如果有 Basic Auth，认证头是否写对

### 16.5 `OnlyPermanentLeasesSupported`

这是某些路由环境里 `UPnP` / 映射能力受限的典型报错，通常不是同步脚本问题。

优先检查：

- 路由器 `UPnP` 状态
- 上游网关限制
- 是否处于更严格的 NAT 或运营商封锁环境

### 16.6 `fwd-socket: cannot forward port: Too many threads`

直接重启对应 `Natter` 服务：

```bash
systemctl restart natter-tcp-56001.service
```

### 16.7 主路由不是 RouterOS

这不是问题。把 RouterOS 相关环境变量留空即可，脚本仍然会继续更新 VPS 订阅 YAML。

## 17. 一个常见的完整流程

1. 在 VPS 准备好 YAML 文件和固定订阅 URL。
2. 在转发机确认目标端口能访问。
3. 安装 `/opt/natter/natter.py`。
4. 修改 `systemd/natter-*.service` 里的 IP 和端口。
5. 生成自动同步专用 SSH key，并配好 `known_hosts`。
6. 运行 `./scripts/install.sh`。
7. 编辑 `/etc/natter-sync/natter-sync.env`。
8. 如果用 RouterOS，提前创建带固定 `comment` 的 NAT 规则。
9. `systemctl enable --now ...` 启动全部服务。
10. 用 `healthcheck.sh`、`journalctl`、`curl` 验证整套链路。
