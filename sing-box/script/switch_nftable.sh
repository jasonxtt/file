#!/bin/bash

TARGET_CONF="/etc/nftables.conf"

# 显示菜单
echo "请选择要应用的 Nftable 模式："
echo "1) Redirect"
echo "2) Tproxy"
read -p "输入选项 [1-2]: " choice

# 根据选择写入对应配置
case "$choice" in
  1)
    echo "应用 redirect 模式..."
    cat > "$TARGET_CONF" << 'EOF'
#!/usr/sbin/nft -f

flush ruleset

table inet singbox {

set china_dns_ipv4 {
    type ipv4_addr;
    elements = { 223.5.5.5, 223.6.6.6, 114.114.114.114, 114.114.115.115 };
}

set china_dns_ipv6 {
    type ipv6_addr;
    elements = { 2400:3200::1, 2400:3200:baba::1 };
}

set remote_dns_ipv4 {
    type ipv4_addr;
    elements = { 8.8.8.8, 8.8.4.4, 1.1.1.1, 1.0.0.1 };
}

set remote_dns_ipv6 {
    type ipv6_addr;
    elements = { 2001:4860:4860::8888, 2001:4860:4860::8844, 2606:4700:4700::1111, 2606:4700:4700::1001 };
}

set fake_ipv4 {
    type ipv4_addr;
    flags interval;
    elements = { 28.0.0.0/8 };
}

set fake_ipv6 {
    type ipv6_addr;
    flags interval;
    elements = { f2b0::/18 };
}

set local_ipv4 {
    type ipv4_addr;
    flags interval;
    elements = { 0.0.0.0/8, 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 224.0.0.0/4, 240.0.0.0/4 };
}

set local_ipv6 {
    type ipv6_addr;
    flags interval;
    elements = { ::ffff:0.0.0.0/96, 64:ff9b::/96, 100::/64, 2001::/32, 2001:10::/28, 2001:20::/28, 2001:db8::/32, 2002::/16, fe80::/10 };
}

chain redirect-proxy {
    fib daddr type { unspec, local, anycast, multicast } return
    ip daddr @local_ipv4 return
    ip6 daddr @local_ipv6 return
    ip daddr @china_dns_ipv4 return
    ip6 daddr @china_dns_ipv6 return
    meta l4proto tcp redirect to :9887
}    

chain redirect-prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    meta l4proto tcp ct direction original goto redirect-proxy
}

chain redirect-output {
    type nat hook output priority dstnat; policy accept;
    fib daddr type { unspec, local, anycast, multicast } return
    ip daddr @fake_ipv4 meta l4proto tcp redirect to :9887
    ip6 daddr @fake_ipv6 meta l4proto tcp redirect to :9887
}

chain tproxy-proxy {    
    fib daddr type { unspec, local, anycast, multicast } return
    ip daddr @local_ipv4 return
    ip6 daddr @local_ipv6 return
    ip daddr @china_dns_ipv4 return
    ip6 daddr @china_dns_ipv6 return
    udp dport {123} return    
    meta l4proto udp meta mark set 1 tproxy to :9888 accept
}

chain tproxy-mark {
    fib daddr type { unspec, local, anycast, multicast } return
    ip daddr @local_ipv4 return
    ip6 daddr @local_ipv6 return
    ip daddr @china_dns_ipv4 return
    ip6 daddr @china_dns_ipv6 return
    udp dport {123} return
    meta mark set 1
}

chain tproxy-prerouting {
    type filter hook prerouting priority mangle; policy accept;
    meta l4proto udp ct direction original goto tproxy-proxy
}

chain tproxy-output {
	type route hook output priority mangle; policy accept;
	meta l4proto udp skgid != 1 ct direction original goto tproxy-mark
}
}
EOF
    ;;
  2)
    echo "应用 tproxy 模式..."
    cat > "$TARGET_CONF" << 'EOF'
#!/usr/sbin/nft -f

flush ruleset

table inet singbox {

set china_dns_ipv4 {
    type ipv4_addr;
    elements = { 223.5.5.5, 223.6.6.6, 114.114.114.114, 114.114.115.115 };
}

set china_dns_ipv6 {
    type ipv6_addr;
    elements = { 2400:3200::1, 2400:3200:baba::1 };
}

set remote_dns_ipv4 {
    type ipv4_addr;
    elements = { 8.8.8.8, 8.8.4.4, 1.1.1.1, 1.0.0.1 };
}

set remote_dns_ipv6 {
    type ipv6_addr;
    elements = { 2001:4860:4860::8888, 2001:4860:4860::8844, 2606:4700:4700::1111, 2606:4700:4700::1001 };
}

set fake_ipv4 {
    type ipv4_addr;
    flags interval;
    elements = { 28.0.0.0/8 };
}

set fake_ipv6 {
    type ipv6_addr;
    flags interval;
    elements = { f2b0::/18 };
}

set local_ipv4 {
    type ipv4_addr;
    flags interval;
    elements = { 0.0.0.0/8, 10.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 224.0.0.0/4, 240.0.0.0/4 };
}

set local_ipv6 {
    type ipv6_addr;
    flags interval;
    elements = { ::ffff:0.0.0.0/96, 64:ff9b::/96, 100::/64, 2001::/32, 2001:10::/28, 2001:20::/28, 2001:db8::/32, 2002::/16, fe80::/10 };
}

chain tproxy-proxy {
    fib daddr type { unspec, local, anycast, multicast } return
    ip daddr @local_ipv4 return
    ip6 daddr @local_ipv6 return
    ip daddr @china_dns_ipv4 return
    ip6 daddr @china_dns_ipv6 return
    udp dport {123} return
    meta l4proto { tcp, udp } meta mark set 1 tproxy to :9888 accept
}

chain tproxy-mark {
    fib daddr type { unspec, local, anycast, multicast } return
    ip daddr @local_ipv4 return
    ip6 daddr @local_ipv6 return
    ip daddr @china_dns_ipv4 return
    ip6 daddr @china_dns_ipv6 return
    udp dport {123} return
    meta l4proto { tcp, udp } meta mark set 1
}

chain tproxy-prerouting {
    type filter hook prerouting priority mangle; policy accept;
    meta l4proto { tcp, udp } ct direction original goto tproxy-proxy
}

chain tproxy-output {
    type route hook output priority mangle; policy accept;
    meta l4proto { tcp, udp } skgid != 1 ct direction original goto tproxy-mark
}
}
EOF
    ;;
  *)
    echo "无效选项，退出。"
    exit 1
    ;;
esac

# 启用并启动 nftables 服务
if command -v systemctl &>/dev/null; then
  echo "正在启用并启动 nftables 服务..."
  systemctl enable nftables
fi

# 重启服务
if command -v systemctl &>/dev/null; then
  echo "正在重启 nftables 服务..."
  systemctl restart nftables
else
  echo "加载新配置..."
  nft -f "$TARGET_CONF"
fi

echo "操作完成。"
