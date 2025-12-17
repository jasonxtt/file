#!/usr/bin/env bash
set -euo pipefail

# ============================
#  基础工具与环境
# ============================

clear_screen() {
  if command -v tput >/dev/null 2>&1; then
    tput clear
  else
    printf "\033c"
  fi
}

pause() {
  echo
  read -r -e -p "按回车继续..." _ || true
}

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo " [ERR] 请用 root 执行：sudo $0"
  exit 1
fi

if [[ -t 0 ]]; then
  stty sane 2>/dev/null || true
  stty erase '^?' 2>/dev/null || stty erase '^H' 2>/dev/null || true
fi

NFT_CONF="/etc/nftables.conf"
PORTSYNC_SCRIPT="/usr/local/sbin/nftables-port-sync.sh"
DEFAULTS_FILE="/etc/default/nftables-port-sync"
SVC_FILE="/etc/systemd/system/nftables-port-sync.service"

# ============================
#  核心逻辑函数
# ============================

trim() { awk '{$1=$1};1' <<<"${1:-}"; }

# 标准化端口 (去重、排序、校验)
normalize_ports() {
  local raw p
  local out=()
  raw="$(trim "${1:-}")"
  raw="${raw//,/ }"
  raw="$(echo "$raw" | tr -s ' ' ' ')"
  [[ -z "$raw" ]] && { echo ""; return 0; }

  for p in $raw; do
    [[ "$p" =~ ^[0-9]+$ ]] || { echo " [ERR] 端口必须是数字：$p" >&2; return 1; }
    (( p>=1 && p<=65535 )) || { echo " [ERR] 端口范围必须 1-65535：$p" >&2; return 1; }
    out+=("$p")
  done
  printf "%s\n" "${out[@]}" | sort -n -u | paste -sd, -
}

# 从列表移除端口
remove_items_from_list() {
  local current="$1"
  local to_remove="$2"
  local cur_space="${current//,/ }"
  local rem_space="${to_remove//,/ }"
  local out_list=() p r keep

  for p in $cur_space; do
    keep=true
    for r in $rem_space; do
      [[ "$p" == "$r" ]] && { keep=false; break; }
    done
    $keep && out_list+=("$p")
  done
  local result="${out_list[*]}"
  normalize_ports "$result"
}

# 进程名清洗 (只允许小写字母、数字、下划线)
sanitize_proc() {
  local s="${1:-}"
  s="$(echo "$s" | tr '[:upper:]' '[:lower:]')"
  s="$(echo "$s" | sed 's/[^a-z0-9_]/_/g; s/__*/_/g; s/^_//; s/_$//')"
  [[ -z "$s" ]] && s="unknown"
  echo "$s"
}

# 猜测 SSH 端口
guess_ssh_ports() {
  local ports=""
  # 使用修复后的列判断逻辑
  ports="$(ss -lntpH 2>/dev/null | awk '
    /sshd/ {
      col = ($1 ~ /^(tcp|udp)$/) ? 4 : 4 
      # 注意：-p 参数下 ss 输出可能不带协议头，这里保守处理，通常 TCP 都在第4列
      addr = $4
      gsub(/.*:/,"",addr)
      if(addr~/^[0-9]+$/) print addr
    }' | sort -n -u | paste -sd, - || true)"

  if [[ -z "$ports" && -f /etc/ssh/sshd_config ]]; then
    ports="$(awk 'BEGIN{IGNORECASE=1} $1=="port"{print $2}' /etc/ssh/sshd_config 2>/dev/null \
      | sort -n -u | paste -sd, - || true)"
  fi
  [[ -z "$ports" ]] && ports="22"
  echo "$ports"
}

# 扫描当前监听端口 (用于安装时的展示)
scan_listen_ports() {
  echo "========== 扫描当前监听端口 (TCP/UDP) =========="
  # 核心修复：兼容 TCP/UDP 输出格式
  ss -lntupH 2>/dev/null | awk '{
    if ($1 ~ /^(tcp|udp|sctp|dccp)$/) { proto=$1; addr=$5; info=$0; } else { proto="tcp"; addr=$4; info=$0; }
    gsub(/.*:/,"",addr)
    if (addr !~ /^[0-9]+$/) next
    
    proc="(unknown)"
    pos=index(info,"users:((\"")
    if (pos>0) {
      t=substr(info, pos+9)
      sub(/".*/,"",t); gsub(/"/,"",t)
      if(t!="") proc=t
    }
    printf "%-4s %-6s %s\n", proto, addr, proc
  }' | sort -k3,3 -k1,1

  echo
  echo "--- 汇总视图 ---"
  ss -lntupH 2>/dev/null | awk '{
    if ($1 ~ /^(tcp|udp|sctp|dccp)$/) { proto=$1; addr=$5; info=$0; } else { proto="tcp"; addr=$4; info=$0; }
    gsub(/.*:/,"",addr)
    if (addr !~ /^[0-9]+$/) next
    
    proc="(unknown)"
    pos=index(info,"users:((\"")
    if (pos>0) {
      t=substr(info, pos+9)
      sub(/".*/,"",t); gsub(/"/,"",t)
      if(t!="") proc=t
    }
    
    key = proc "," proto
    if (!seen[key]++) { ports[key] = addr } else { ports[key] = ports[key] "," addr }
    proc_list[proc] = 1
  } END {
    for (p in proc_list) {
      print "进程: " p
      if (ports[p ",tcp"]) print "  - TCP: " ports[p ",tcp"]
      if (ports[p ",udp"]) print "  - UDP: " ports[p ",udp"]
    }
  }'
}

# 生成进程端口映射表 (用于脚本内部逻辑)
scan_proc_ports_tab() {
  ss -lntupH 2>/dev/null | awk '{
    if ($1 ~ /^(tcp|udp|sctp|dccp)$/) { addr=$5; info=$0; } else { addr=$4; info=$0; }
    gsub(/.*:/,"",addr)
    if (addr !~ /^[0-9]+$/) next
    
    proc="(unknown)"
    pos=index(info,"users:((\"")
    if (pos>0) {
      t=substr(info, pos+9)
      sub(/".*/,"",t); gsub(/"/,"",t)
      if(t!="") proc=t
    }
    print proc "\t" addr
  }' | sort -u | awk -F'\t' '{
    p=$1; port=$2
    if (p=="" || port=="") next
    ports[p]=ports[p] (ports[p] ? "," : "") port
    procs[p]=1
  } END {
    for (p in procs) print p "\t" ports[p]
  }'
}

restore_or_remove_nft_conf() {
  cat >"$NFT_CONF" <<'EOF'
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
  chain input   { type filter hook input priority filter; policy accept; }
  chain forward { type filter hook forward priority filter; policy accept; }
  chain output  { type filter hook output priority filter; policy accept; }
}
EOF
  echo " [OK] 已写回默认 nftables.conf 模板。"
}

# ============================
#  写文件逻辑 (核心部分)
# ============================

write_files_install() {
  local ssh_ports="$1"
  local allow_ping="$2"
  local allow_procs_str="$3"
  local other_ports_str="$4"

  # 1. 生成同步脚本 (每次服务启动或端口变更时运行)
  cat >"$PORTSYNC_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

NFT_CONF="/etc/nftables.conf"
DEFAULTS_FILE="/etc/default/nftables-port-sync"

trim(){ awk '{$1=$1};1' <<<"${1:-}"; }
sanitize_proc() {
  local s="${1:-}"
  s="$(echo "$s" | tr '[:upper:]' '[:lower:]')"
  s="$(echo "$s" | sed 's/[^a-z0-9_]/_/g; s/__*/_/g; s/^_//; s/_$//')"
  [[ -z "$s" ]] && s="unknown"
  echo "$s"
}

# 内部扫描函数
scan_proc_ports_tab() {
  ss -lntupH 2>/dev/null | awk '{
    if ($1 ~ /^(tcp|udp|sctp|dccp)$/) { addr=$5; info=$0; } else { addr=$4; info=$0; }
    gsub(/.*:/,"",addr)
    if (addr !~ /^[0-9]+$/) next
    proc="(unknown)"
    pos=index(info,"users:((\"")
    if (pos>0) { t=substr(info, pos+9); sub(/".*/,"",t); gsub(/"/,"",t); if(t!="") proc=t }
    print proc "\t" addr
  }' | sort -u | awk -F'\t' '{
    p=$1; port=$2
    if (p=="" || port=="") next
    ports[p]=ports[p] (ports[p] ? "," : "") port
    procs[p]=1
  } END { for (p in procs) print p "\t" ports[p] }'
}

# 默认值
SSH_PORTS_OVERRIDE="22"
ALLOW_PING="yes"
ALLOW_PROCS=""
OTHER_PORTS_OVERRIDE=""

if [[ -f "$DEFAULTS_FILE" ]]; then
  source "$DEFAULTS_FILE" || true
fi

# 1. 处理 SSH
ssh_ports="$(trim "${SSH_PORTS_OVERRIDE}")"
[[ -z "$ssh_ports" ]] && ssh_ports="22"

# 2. 处理 Other Ports (静态列表)
other_ports="$(trim "${OTHER_PORTS_OVERRIDE}")"
other_ports="${other_ports//,/ }"
other_ports="$(echo "$other_ports" | tr -s ' ' ',')" # 逗号分隔

# 3. 处理动态进程
declare -A MAP=()
while IFS=$'\t' read -r p csv; do
  p="$(trim "${p//\"/}")"
  [[ -z "$p" ]] && continue
  MAP["$p"]="$csv"
done < <(scan_proc_ports_tab)

allow_lines=()
for p in ${ALLOW_PROCS:-}; do
  csv="${MAP[$p]:-}"
  [[ -z "${csv// /}" ]] && continue
  allow_lines+=("$p"$'\t'"$csv")
done

# 4. 生成临时配置文件
tmp="$(mktemp /tmp/nftables.conf.XXXXXX)"

cat >"$tmp" <<EOF2
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
  set ssh_ports { type inet_service; elements = { ${ssh_ports} } }
EOF2

# 写入静态端口集合
if [[ -n "$other_ports" ]]; then
  echo "  set other_ports { type inet_service; elements = { ${other_ports} } }" >>"$tmp"
fi

# 写入动态进程集合
for line in "${allow_lines[@]}"; do
  proc="${line%%$'\t'*}"
  ports="${line#*$'\t'}"
  p_s="$(sanitize_proc "$proc")"
  echo "  set listen_${p_s}_ports { type inet_service; elements = { ${ports} } }" >>"$tmp"
done

cat >>"$tmp" <<EOF2

  chain input {
    type filter hook input priority 0;
    policy drop;

    iif lo accept
    ct state established,related accept

    ip6 nexthdr icmpv6 icmpv6 type {
      nd-router-solicit, nd-router-advert,
      nd-neighbor-solicit, nd-neighbor-advert,
      nd-redirect,
      packet-too-big, time-exceeded, parameter-problem,
      destination-unreachable
    } accept
EOF2

if [[ "$ALLOW_PING" == "yes" ]]; then
  echo "    icmp type echo-request accept" >>"$tmp"
  echo "    icmpv6 type echo-request accept" >>"$tmp"
else
  echo "    icmp type echo-request drop" >>"$tmp"
  echo "    icmpv6 type echo-request drop" >>"$tmp"
fi

cat >>"$tmp" <<EOF2

    # SSH (带防爆破)
    tcp dport @ssh_ports ct state new limit rate 20/minute burst 10 packets accept
    tcp dport @ssh_ports drop
EOF2

# 放行静态端口规则
if [[ -n "$other_ports" ]]; then
  echo "    meta l4proto { tcp, udp } th dport @other_ports accept" >>"$tmp"
fi

# 放行动态进程规则
for line in "${allow_lines[@]}"; do
  proc="${line%%$'\t'*}"
  p_s="$(sanitize_proc "$proc")"
  echo "    meta l4proto { tcp, udp, sctp, dccp } th dport @listen_${p_s}_ports accept # ${proc}" >>"$tmp"
done

cat >>"$tmp" <<EOF2
  }
  chain forward { type filter hook forward priority 0; policy drop; }
  chain output  { type filter hook output priority 0; policy accept; }
}
EOF2

# 检查并应用
if nft -c -f "$tmp"; then
  install -m 0644 "$tmp" "$NFT_CONF"
  nft -f "$NFT_CONF"
  echo "[OK] 防火墙规则已更新。"
else
  echo "[ERR] 生成的规则有误，未应用。"
  rm -f "$tmp"
  exit 1
fi
rm -f "$tmp"
EOF
  chmod 0755 "$PORTSYNC_SCRIPT"

  # 2. 生成默认配置变量文件
  cat >"$DEFAULTS_FILE" <<EOF
SSH_PORTS_OVERRIDE="${ssh_ports}"
ALLOW_PING="${allow_ping}"
ALLOW_PROCS="${allow_procs_str}"
OTHER_PORTS_OVERRIDE="${other_ports_str}"
EOF
  chmod 0644 "$DEFAULTS_FILE"

  # 3. 生成 Service
  cat >"$SVC_FILE" <<'EOF'
[Unit]
Description=Sync nftables.conf from static & dynamic ports
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 5
ExecStart=/usr/local/sbin/nftables-port-sync.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

# ============================
#  功能模块
# ============================

install_fw() {
  echo "========== 安装 / 重置 =========="
  echo
  scan_listen_ports
  read -r -e -p "(已显示当前监听端口) 按回车开始配置..." _ || true
  echo

  # SSH
  local default_ssh in_ssh ssh_ports
  default_ssh="$(guess_ssh_ports)"
  read -r -e -p "请输入 SSH 端口 [默认: ${default_ssh}] : " in_ssh || true
  in_ssh="$(trim "${in_ssh:-}")"
  [[ -z "$in_ssh" ]] && in_ssh="$default_ssh"
  ssh_ports="$(normalize_ports "$in_ssh")"

  # 动态进程 (白名单)
  echo
  echo "--- 动态进程白名单配置 ---"
  echo "输入你信任的进程名（如 sing-box, nginx）。"
  echo "脚本会自动放行它们占用的所有端口。"
  echo
  local in_procs allow_procs_str=""
  read -r -e -p "请输入信任的进程名 (空格分隔，留空跳过): " in_procs || true
  in_procs="$(trim "${in_procs:-}")"
  allow_procs_str="$in_procs"

  # 静态端口 (Docker/其他)
  echo
  echo "--- 手动/静态端口配置 (Docker必选) ---"
  echo "适用于：Docker容器端口、目前没运行但需要放行的端口。"
  local in_other other_ports_str=""
  read -r -e -p "请输入手动放行的端口 (数字，逗号分隔，留空跳过): " in_other || true
  in_other="$(trim "${in_other:-}")"
  other_ports_str="$(normalize_ports "$in_other")"

  # Ping
  local in_ping allow_ping="yes"
  echo
  read -r -e -p "是否允许 Ping？[Y/n] : " in_ping || true
  [[ "${in_ping,,}" == "n" || "${in_ping,,}" == "no" ]] && allow_ping="no"

  echo
  echo "配置汇总："
  echo "  SSH 端口: ${ssh_ports}"
  echo "  信任进程: ${allow_procs_str:-(无)}"
  echo "  手动端口: ${other_ports_str:-(无)}"
  echo "  Ping: ${allow_ping}"
  echo

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y nftables iproute2

  write_files_install "$ssh_ports" "$allow_ping" "$allow_procs_str" "$other_ports_str"

  systemctl daemon-reload
  systemctl enable --now nftables
  
  systemctl enable nftables-port-sync.service
  systemctl restart nftables-port-sync.service || true

  echo " [DONE] 安装完成。"
}

# --- 端口管理子菜单 ---

manage_ssh_menu() {
  source "$DEFAULTS_FILE"
  echo
  echo "当前 SSH 端口: ${SSH_PORTS_OVERRIDE}"
  read -r -e -p "请输入新的 SSH 端口 (逗号分隔): " new_ports || true
  new_ports="$(normalize_ports "$new_ports")"
  [[ -z "$new_ports" ]] && { echo "输入为空，取消。"; return; }
  
  # 替换
  sed -i "s/^SSH_PORTS_OVERRIDE=.*/SSH_PORTS_OVERRIDE=\"$new_ports\"/" "$DEFAULTS_FILE"
  echo "已更新配置，正在刷新..."
  "$PORTSYNC_SCRIPT"
}

manage_procs_menu() {
  source "$DEFAULTS_FILE"
  echo
  echo "当前信任的进程: [ ${ALLOW_PROCS} ]"
  echo "1) 添加进程名 (Add)"
  echo "2) 删除进程名 (Remove)"
  echo "0) 返回"
  read -r -e -p "选择: " act || true
  
  case "$act" in
    1)
      read -r -e -p "输入要添加的进程名 (如 sing-box): " add_p || true
      add_p="$(trim "$add_p")"
      [[ -z "$add_p" ]] && return
      if [[ " $ALLOW_PROCS " != *" $add_p "* ]]; then
         ALLOW_PROCS="${ALLOW_PROCS} ${add_p}"
         ALLOW_PROCS="$(echo "$ALLOW_PROCS" | xargs)" # 去多余空格
      fi
      ;;
    2)
      read -r -e -p "输入要删除的进程名: " del_p || true
      del_p="$(trim "$del_p")"
      [[ -z "$del_p" ]] && return
      # 简易字符串替换删除
      ALLOW_PROCS=" ${ALLOW_PROCS} "
      ALLOW_PROCS="${ALLOW_PROCS/ $del_p / }"
      ALLOW_PROCS="$(echo "$ALLOW_PROCS" | xargs)"
      ;;
    *) return ;;
  esac

  sed -i "s/^ALLOW_PROCS=.*/ALLOW_PROCS=\"$ALLOW_PROCS\"/" "$DEFAULTS_FILE"
  echo "已更新配置，正在刷新..."
  "$PORTSYNC_SCRIPT"
}

manage_static_menu() {
  source "$DEFAULTS_FILE"
  echo
  echo "当前手动/静态端口 (Docker等): [ ${OTHER_PORTS_OVERRIDE} ]"
  echo "1) 添加端口 (Add)"
  echo "2) 删除端口 (Remove)"
  echo "0) 返回"
  read -r -e -p "选择: " act || true

  local current="${OTHER_PORTS_OVERRIDE}"
  local new_val=""

  case "$act" in
    1)
      read -r -e -p "输入要添加的端口 (逗号分隔): " in_p || true
      new_val="$(normalize_ports "${current},${in_p}")"
      ;;
    2)
      read -r -e -p "输入要删除的端口 (逗号分隔): " in_p || true
      new_val="$(remove_items_from_list "${current}" "${in_p}")"
      ;;
    *) return ;;
  esac
  
  sed -i "s/^OTHER_PORTS_OVERRIDE=.*/OTHER_PORTS_OVERRIDE=\"$new_val\"/" "$DEFAULTS_FILE"
  echo "已更新配置，正在刷新..."
  "$PORTSYNC_SCRIPT"
}

manage_ports() {
  if [[ ! -f "$DEFAULTS_FILE" ]]; then
    echo " [ERR] 未安装，请先选择安装。"
    return
  fi

  while true; do
    clear_screen
    echo "========== 管理放行端口 =========="
    echo "1) 修改 SSH 端口"
    echo "2) 管理 动态进程 (按名字放行)"
    echo "3) 管理 手动端口 (按数字放行，Docker/自定义)"
    echo "0) 返回主菜单"
    echo "----------------------------------"
    read -r -e -p "请选择: " sub || true
    case "$sub" in
      1) manage_ssh_menu; pause ;;
      2) manage_procs_menu; pause ;;
      3) manage_static_menu; pause ;;
      0) return ;;
      *) ;;
    esac
  done
}

uninstall_fw() {
  echo "========== 卸载 =========="
  read -r -e -p "确认卸载？(输入 YES 继续): " confirm || true
  [[ "$confirm" != "YES" ]] && return

  systemctl stop nftables-port-sync.service 2>/dev/null || true
  systemctl disable nftables-port-sync.service 2>/dev/null || true
  rm -f "$SVC_FILE" "$DEFAULTS_FILE" "$PORTSYNC_SCRIPT" 2>/dev/null || true

  restore_or_remove_nft_conf
  nft -f "$NFT_CONF" 2>/dev/null || true
  systemctl disable --now nftables 2>/dev/null || true
  
  echo " 卸载完成。"
}

show_menu() {
  clear_screen
  echo
  echo "=============================="
  echo "   NFTables 智能防火墙管理器"
  echo "=============================="
  echo "1) 安装 / 重置"
  echo "2) 管理放行端口 (SSH / 进程 / Docker)"
  echo "3) 卸载"
  echo "0) 退出"
  echo "------------------------------"
}

main() {
  while true; do
    show_menu
    read -r -e -p "请选择 [0-3]：" choice || true
    case "$(trim "${choice:-}")" in
      1) install_fw; pause ;;
      2) manage_ports ;;
      3) uninstall_fw; pause ;;
      0) echo "退出。"; exit 0 ;;
      *) echo " 输入无效"; pause ;;
    esac
  done
}

main