#!/usr/bin/env bash
set -euo pipefail

# ============================
#  基础工具函数
# ============================

clear_screen() {
  if command -v tput >/dev/null 2>&1; then
    tput clear
  else
    printf "\033c"
  fi
}

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "[ERR] 请用 root 执行：sudo $0"
  exit 1
fi

if [[ -t 0 ]]; then
  stty sane 2>/dev/null || true
  stty erase '^?' 2>/dev/null || stty erase '^H' 2>/dev/null || true
fi

# ============================
#  配置文件路径定义
# ============================

NFT_CONF="/etc/nftables.conf"
PORTSYNC_SCRIPT="/usr/local/sbin/nftables-port-sync.sh"
DEFAULTS_FILE="/etc/default/nftables-port-sync"
SVC_FILE="/etc/systemd/system/nftables-port-sync.service"

# ============================
#  辅助处理函数
# ============================

trim() { awk '{$1=$1};1' <<<"${1:-}"; }

pause() {
  echo
  read -r -e -p "按回车继续..." _ || true
}

# 标准化端口列表：排序、去重、逗号分隔
normalize_ports() {
  local raw
  raw="$(trim "${1:-}")"
  raw="${raw//,/ }"
  raw="$(echo "$raw" | tr -s ' ' ' ')"
  [[ -z "$raw" ]] && { echo ""; return 0; }

  local out=() p
  for p in $raw; do
    [[ "$p" =~ ^[0-9]+$ ]] || { echo "[ERR] 端口必须是数字：$p" >&2; return 1; }
    (( p>=1 && p<=65535 )) || { echo "[ERR] 端口范围必须 1-65535：$p" >&2; return 1; }
    out+=("$p")
  done

  printf "%s\n" "${out[@]}" | sort -n -u | paste -sd, -
}

# 从列表 list 中移除 remove_list 中的端口
remove_ports_from_list() {
  local current="$1"
  local to_remove="$2"
  
  # 转为空格分隔
  local cur_space="${current//,/ }"
  local rem_space="${to_remove//,/ }"
  local out_list=()
  local p r keep

  for p in $cur_space; do
    keep=true
    for r in $rem_space; do
      if [[ "$p" == "$r" ]]; then
        keep=false
        break
      fi
    done
    if $keep; then
      out_list+=("$p")
    fi
  done

  # 重新标准化输出
  local result="${out_list[*]}"
  normalize_ports "$result"
}

# 猜测 SSH 端口 (通常只用 TCP)
guess_ssh_ports() {
  local ports=""
  ports="$(ss -lntpH 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); p=a[n]; if(p~/^[0-9]+$/) print p}' \
    | sort -u | paste -sd, - || true)"
  if [[ -z "$ports" && -f /etc/ssh/sshd_config ]]; then
    ports="$(awk 'BEGIN{IGNORECASE=1} $1=="port"{print $2}' /etc/ssh/sshd_config 2>/dev/null \
      | sort -u | paste -sd, - || true)"
  fi
  [[ -z "$ports" ]] && ports="22"
  echo "$ports"
}

# 猜测 Sing-box 端口 (修复版：智能适配列位置)
guess_sb_ports() {
  ss -lntupH 2>/dev/null | awk '/sing-box/ { 
    # 核心修复：如果第1列是 tcp/udp，地址就在第5列；否则在第4列
    col = ($1 ~ /^(tcp|udp)$/) ? 5 : 4
    addr = $col
    n = split(addr, a, ":")
    p = a[n]
    if (p ~ /^[0-9]+$/) print p 
  }' | sort -u | paste -sd, - || true
}

# 猜测 SUI 端口 (修复版：智能适配列位置)
guess_sui_ports() {
  ss -lntupH 2>/dev/null | awk '/\("sui"/ { 
    # 核心修复：同上
    col = ($1 ~ /^(tcp|udp)$/) ? 5 : 4
    addr = $col
    n = split(addr, a, ":")
    p = a[n]
    if (p ~ /^[0-9]+$/) print p 
  }' | sort -u | paste -sd, - || true
}

restore_or_remove_nft_conf() {
  cat >"$NFT_CONF" <<'EOF'
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
  chain input { type filter hook input priority filter; policy accept; }
  chain forward { type filter hook forward priority filter; policy accept; }
  chain output { type filter hook output priority filter; policy accept; }
}
EOF
  echo "[OK] 已写回默认 nftables.conf 模板：$NFT_CONF"
}

# ============================
#  安装逻辑 (写文件)
# ============================

write_files_install() {
  local ssh_ports="$1"
  local sb_ports="$2"
  local sui_ports="$3"
  local other_ports="$4"
  local allow_ping="${5:-yes}"

  local sb_trim="${sb_ports//[[:space:]]/}"
  local sui_trim="${sui_ports//[[:space:]]/}"
  local other_trim="${other_ports//[[:space:]]/}"

  # 1. 生成主配置文件 /etc/nftables.conf
  cat >"$NFT_CONF" <<EOF
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
  set ssh_ports { type inet_service; elements = { $ssh_ports } }
EOF

  if [[ -n "$sb_trim" ]]; then
    cat >>"$NFT_CONF" <<EOF
  set sb_ports { type inet_service; elements = { $sb_ports } }
EOF
  fi

  if [[ -n "$sui_trim" ]]; then
    cat >>"$NFT_CONF" <<EOF
  set sui_ports { type inet_service; elements = { $sui_ports } }
EOF
  fi

  if [[ -n "$other_trim" ]]; then
    cat >>"$NFT_CONF" <<EOF
  set other_ports { type inet_service; elements = { $other_ports } }
EOF
  fi

  cat >>"$NFT_CONF" <<'EOF'

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
EOF

  if [[ "$allow_ping" == "yes" ]]; then
    cat >>"$NFT_CONF" <<'EOF'

    icmp type echo-request accept
    icmpv6 type echo-request accept
EOF
  else
    cat >>"$NFT_CONF" <<'EOF'

    icmp type echo-request drop
    icmpv6 type echo-request drop
EOF
  fi

  # 优化点：放宽 SSH 限制 (20/minute, burst 10)
  cat >>"$NFT_CONF" <<'EOF'

    tcp dport @ssh_ports ct state new limit rate 20/minute burst 10 packets accept
EOF

  if [[ -n "$sb_trim" ]]; then
    cat >>"$NFT_CONF" <<'EOF'

    meta l4proto { tcp, udp } th dport @sb_ports accept
EOF
  fi

  if [[ -n "$sui_trim" ]]; then
    cat >>"$NFT_CONF" <<'EOF'

    meta l4proto { tcp, udp } th dport @sui_ports accept
EOF
  fi

  if [[ -n "$other_trim" ]]; then
    cat >>"$NFT_CONF" <<'EOF'

    meta l4proto { tcp, udp } th dport @other_ports accept
EOF
  fi

  cat >>"$NFT_CONF" <<'EOF'
  }

  chain forward {
    type filter hook forward priority 0;
    policy drop;
  }

  chain output {
    type filter hook output priority 0;
    policy accept;
  }
}
EOF

  # 2. 生成端口同步脚本 (这里也要修复检测逻辑)
  cat >"$PORTSYNC_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

FAMILY="inet"
TABLE="filter"

MGMT_SET="ssh_ports"
SB_SET="sb_ports"
SUI_SET="sui_ports"
OTHER_SET="other_ports"

DEFAULTS_FILE="/etc/default/nftables-port-sync"

SSH_PORTS_OVERRIDE=""
SB_PORTS_OVERRIDE=""
SUI_PORTS_OVERRIDE=""
OTHER_PORTS_OVERRIDE=""

if [[ -f "$DEFAULTS_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$DEFAULTS_FILE" || true
fi

normalize_ports() {
  local raw="${1:-}"
  raw="${raw//,/ }"
  raw="$(echo "$raw" | tr -s ' ' ' ' | awk '{$1=$1};1')"
  [[ -z "$raw" ]] && { echo ""; return 0; }
  local out=() p
  for p in $raw; do
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    (( p>=1 && p<=65535 )) || return 1
    out+=("$p")
  done
  printf "%s\n" "${out[@]}" | sort -n -u | paste -sd, -
}

has_set() { nft list set "$FAMILY" "$TABLE" "$1" >/dev/null 2>&1; }

MGMT_LIST=""
if [[ -n "${SSH_PORTS_OVERRIDE:-}" ]]; then
  MGMT_LIST="$(normalize_ports "$SSH_PORTS_OVERRIDE" || true)"
fi
# 如果配置为空，尝试自动检测
if [[ -z "$MGMT_LIST" ]]; then
  mapfile -t MGMT_PORTS < <(
    ss -lntpH 2>/dev/null | awk '
      /sshd/ {
        addr=$4
        n=split(addr, a, ":")
        port=a[n]
        if (port ~ /^[0-9]+$/) print port
      }' | sort -u
  )
  if [[ ${#MGMT_PORTS[@]} -eq 0 ]]; then
    mapfile -t MGMT_PORTS < <(
      awk 'BEGIN{IGNORECASE=1} $1=="port"{print $2}' /etc/ssh/sshd_config 2>/dev/null | sort -u
    )
  fi
  if [[ ${#MGMT_PORTS[@]} -eq 0 ]]; then
    MGMT_PORTS=(22)
  fi
  MGMT_LIST="$(printf "%s\n" "${MGMT_PORTS[@]}" | paste -sd, -)"
fi

SB_LIST=""
if [[ -n "${SB_PORTS_OVERRIDE:-}" ]]; then
  SB_LIST="$(normalize_ports "$SB_PORTS_OVERRIDE" || true)"
else
  # 修复：ss -lntupH (支持 UDP)
  mapfile -t SB_PORTS < <(
    ss -lntupH 2>/dev/null | awk '
      /sing-box/ {
        addr=$4
        n=split(addr, a, ":")
        port=a[n]
        if (port ~ /^[0-9]+$/) print port
      }' | sort -u
  )
  if [[ ${#SB_PORTS[@]} -gt 0 ]]; then
    SB_LIST="$(printf "%s\n" "${SB_PORTS[@]}" | paste -sd, -)"
  fi
fi

SUI_LIST=""
if [[ -n "${SUI_PORTS_OVERRIDE:-}" ]]; then
  SUI_LIST="$(normalize_ports "$SUI_PORTS_OVERRIDE" || true)"
else
  # 修复：ss -lntupH (支持 UDP)
  mapfile -t SUI_PORTS < <(
    ss -lntupH 2>/dev/null | awk '
      /\("sui"/ {
        addr=$4
        n=split(addr, a, ":")
        port=a[n]
        if (port ~ /^[0-9]+$/) print port
      }' | sort -u
  )
  if [[ ${#SUI_PORTS[@]} -gt 0 ]]; then
    SUI_LIST="$(printf "%s\n" "${SUI_PORTS[@]}" | paste -sd, -)"
  fi
fi

OTHER_LIST=""
if [[ -n "${OTHER_PORTS_OVERRIDE:-}" ]]; then
  OTHER_LIST="$(normalize_ports "$OTHER_PORTS_OVERRIDE" || true)"
fi

# 更新 nftables 集合
if has_set "$MGMT_SET"; then
  nft -f - <<EOF_IN
flush set $FAMILY $TABLE $MGMT_SET
add element $FAMILY $TABLE $MGMT_SET { $MGMT_LIST }
EOF_IN
  echo "[OK] ssh_ports   => $MGMT_LIST"
fi

if has_set "$SB_SET"; then
  if [[ -n "$SB_LIST" ]]; then
    nft -f - <<EOF_SB
flush set $FAMILY $TABLE $SB_SET
add element $FAMILY $TABLE $SB_SET { $SB_LIST }
EOF_SB
    echo "[OK] sb_ports    => $SB_LIST"
  else
    nft flush set $FAMILY $TABLE $SB_SET
    echo "[OK] sb_ports    => (已清空)"
  fi
fi

if has_set "$SUI_SET"; then
  if [[ -n "$SUI_LIST" ]]; then
    nft -f - <<EOF_SUI
flush set $FAMILY $TABLE $SUI_SET
add element $FAMILY $TABLE $SUI_SET { $SUI_LIST }
EOF_SUI
    echo "[OK] sui_ports   => $SUI_LIST"
  else
    nft flush set $FAMILY $TABLE $SUI_SET
    echo "[OK] sui_ports   => (已清空)"
  fi
fi

if has_set "$OTHER_SET"; then
  if [[ -n "$OTHER_LIST" ]]; then
    nft -f - <<EOF_OT
flush set $FAMILY $TABLE $OTHER_SET
add element $FAMILY $TABLE $OTHER_SET { $OTHER_LIST }
EOF_OT
    echo "[OK] other_ports => $OTHER_LIST"
  else
    nft flush set $FAMILY $TABLE $OTHER_SET
    echo "[OK] other_ports => (已清空)"
  fi
fi
EOF
  chmod 0755 "$PORTSYNC_SCRIPT"

  # 3. 生成环境变量文件
  cat >"$DEFAULTS_FILE" <<EOF
SSH_PORTS_OVERRIDE="${ssh_ports}"
SB_PORTS_OVERRIDE="${sb_ports}"
SUI_PORTS_OVERRIDE="${sui_ports}"
OTHER_PORTS_OVERRIDE="${other_ports}"
EOF
  chmod 0644 "$DEFAULTS_FILE"

  # 4. 生成 Systemd Service
  cat >"$SVC_FILE" <<'EOF'
[Unit]
Description=Sync nftables port sets (ssh/sing-box/sui/other)
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
#  功能：安装/重装
# ============================

install_fw() {
  echo "========== 安装 / 重置防火墙 =========="

  local default_ssh default_sb default_sui
  local in_ssh in_sb in_sui in_other in_ping
  local ssh_ports sb_ports sui_ports other_ports
  local allow_ping="yes"

  default_ssh="$(guess_ssh_ports)"
  echo "检测到 SSH 端口：${default_ssh}"
  read -r -e -p "请输入要放行的 SSH 端口（可多端口，逗号分隔）[默认: ${default_ssh}] : " in_ssh || true
  in_ssh="$(trim "${in_ssh:-}")"
  [[ -z "$in_ssh" ]] && in_ssh="$default_ssh"
  ssh_ports="$(normalize_ports "$in_ssh")"

  sb_ports=""
  default_sb="$(guess_sb_ports)"
  if [[ -n "$default_sb" ]]; then
    echo "检测到 sing-box 监听端口 (TCP/UDP)：${default_sb}"
    read -r -e -p "请输入 sing-box 端口（TCP/UDP）[默认: ${default_sb}] : " in_sb || true
    in_sb="$(trim "${in_sb:-}")"
    [[ -z "$in_sb" ]] && in_sb="$default_sb"
    sb_ports="$(normalize_ports "$in_sb")"
  else
    read -r -e -p "请输入 sing-box 端口（TCP/UDP；留空跳过）: " in_sb || true
    in_sb="$(trim "${in_sb:-}")"
    [[ -n "$in_sb" ]] && sb_ports="$(normalize_ports "$in_sb")"
  fi

  sui_ports=""
  default_sui="$(guess_sui_ports)"
  if [[ -n "$default_sui" ]]; then
    echo "检测到 SUI 监听端口 (TCP/UDP)：${default_sui}"
    read -r -e -p "请输入 SUI 端口（TCP/UDP）[默认: ${default_sui}] : " in_sui || true
    in_sui="$(trim "${in_sui:-}")"
    [[ -z "$in_sui" ]] && in_sui="$default_sui"
    sui_ports="$(normalize_ports "$in_sui")"
  else
    read -r -e -p "请输入 SUI 端口（TCP/UDP；留空跳过）: " in_sui || true
    in_sui="$(trim "${in_sui:-}")"
    [[ -n "$in_sui" ]] && sui_ports="$(normalize_ports "$in_sui")"
  fi

  other_ports=""
  read -r -e -p "请输入额外放行的端口 other_ports（留空跳过）: " in_other || true
  in_other="$(trim "${in_other:-}")"
  [[ -n "$in_other" ]] && other_ports="$(normalize_ports "$in_other")"

  echo
  read -r -e -p "是否允许 Ping（ICMP echo-request）？[Y/n] : " in_ping || true
  in_ping="$(trim "${in_ping:-}")"
  case "${in_ping,,}" in
    ""|"y"|"yes") allow_ping="yes" ;;
    "n"|"no")     allow_ping="no" ;;
    *) echo "[WARN] 输入无效，默认允许 Ping"; allow_ping="yes" ;;
  esac

  echo
  echo "[INFO] 正在安装..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y nftables iproute2

  write_files_install "$ssh_ports" "$sb_ports" "$sui_ports" "$other_ports" "$allow_ping"

  systemctl daemon-reload
  systemctl enable --now nftables

  nft -f "$NFT_CONF"

  systemctl enable nftables-port-sync.service
  systemctl restart nftables-port-sync.service || true

  echo
  echo "[DONE] 安装完成。"
}

# ============================
#  功能：管理端口 (增删)
# ============================

manage_ports() {
  if [[ ! -f "$DEFAULTS_FILE" ]]; then
    echo "[ERR] 未找到配置文件，请先执行「安装」！"
    return 1
  fi

  # 读取当前配置
  # shellcheck disable=SC1090
  source "$DEFAULTS_FILE"

  echo "========== 管理放行端口 =========="
  echo "请选择要管理的类别："
  echo "1) SSH 端口 (当前: ${SSH_PORTS_OVERRIDE:-默认检测})"
  echo "2) Sing-box 端口 (当前: ${SB_PORTS_OVERRIDE:-空})"
  echo "3) SUI 端口 (当前: ${SUI_PORTS_OVERRIDE:-空})"
  echo "4) 其他端口 (当前: ${OTHER_PORTS_OVERRIDE:-空})"
  echo "0) 返回"
  
  local type_choice
  read -r -e -p "请输入选项 [0-4]: " type_choice || true
  
  local target_var=""
  local target_name=""
  local current_val=""

  case "$type_choice" in
    1) target_var="SSH_PORTS_OVERRIDE"; target_name="SSH"; current_val="${SSH_PORTS_OVERRIDE:-}" ;;
    2) target_var="SB_PORTS_OVERRIDE"; target_name="Sing-box"; current_val="${SB_PORTS_OVERRIDE:-}" ;;
    3) target_var="SUI_PORTS_OVERRIDE"; target_name="SUI"; current_val="${SUI_PORTS_OVERRIDE:-}" ;;
    4) target_var="OTHER_PORTS_OVERRIDE"; target_name="其他"; current_val="${OTHER_PORTS_OVERRIDE:-}" ;;
    0) return 0 ;;
    *) echo "[ERR] 输入无效"; return 1 ;;
  esac

  echo
  echo "当前 $target_name 端口: [ ${current_val:-空} ]"
  echo "请选择操作："
  echo "1) 添加端口 (Add)"
  echo "2) 删除端口 (Remove)"
  echo "0) 取消"

  local action_choice
  read -r -e -p "请输入选项 [0-2]: " action_choice || true

  local input_ports=""
  local new_val=""

  if [[ "$action_choice" == "1" ]]; then
    # 添加
    read -r -e -p "请输入要【添加】的端口 (逗号分隔): " input_ports || true
    input_ports="$(trim "$input_ports")"
    [[ -z "$input_ports" ]] && { echo "未输入，已取消。"; return 0; }
    
    # 逻辑：旧 + 新 -> 标准化
    new_val="$(normalize_ports "${current_val},${input_ports}")"

  elif [[ "$action_choice" == "2" ]]; then
    # 删除
    read -r -e -p "请输入要【删除】的端口 (逗号分隔): " input_ports || true
    input_ports="$(trim "$input_ports")"
    [[ -z "$input_ports" ]] && { echo "未输入，已取消。"; return 0; }

    # 逻辑：从当前列表中移除目标
    new_val="$(remove_ports_from_list "${current_val}" "${input_ports}")"

  else
    echo "已取消。"
    return 0
  fi

  echo
  echo "修改前: ${current_val:-空}"
  echo "修改后: ${new_val:-空}"
  
  local confirm
  read -r -e -p "确认应用修改？[Y/n]: " confirm || true
  if [[ "${confirm,,}" == "n" || "${confirm,,}" == "no" ]]; then
    echo "已取消保存。"
    return 0
  fi

  # 更新变量
  case "$type_choice" in
    1) SSH_PORTS_OVERRIDE="$new_val" ;;
    2) SB_PORTS_OVERRIDE="$new_val" ;;
    3) SUI_PORTS_OVERRIDE="$new_val" ;;
    4) OTHER_PORTS_OVERRIDE="$new_val" ;;
  esac

  # 写回配置文件
  cat >"$DEFAULTS_FILE" <<EOF
SSH_PORTS_OVERRIDE="${SSH_PORTS_OVERRIDE}"
SB_PORTS_OVERRIDE="${SB_PORTS_OVERRIDE}"
SUI_PORTS_OVERRIDE="${SUI_PORTS_OVERRIDE}"
OTHER_PORTS_OVERRIDE="${OTHER_PORTS_OVERRIDE}"
EOF

  echo "[OK] 配置文件已更新。"
  
  # 触发同步
  echo "[INFO] 正在刷新防火墙规则..."
  if [[ -x "$PORTSYNC_SCRIPT" ]]; then
    "$PORTSYNC_SCRIPT"
  else
    systemctl restart nftables-port-sync.service
  fi
  echo "[DONE] 端口修改已生效！"
}

# ============================
#  功能：卸载
# ============================

uninstall_fw() {
  echo "========== 卸载 =========="
  echo "[INFO] 卸载将："
  echo "  - 删除 service / defaults / portsync 脚本"
  echo "  - 写回默认 nftables.conf 模板"
  echo "  - 关闭 nftables 服务并取消自启"
  echo

  read -r -e -p "确认卸载？输入 YES 继续：" confirm || true
  confirm="$(trim "${confirm:-}")"
  if [[ "$confirm" != "YES" ]]; then
    echo "[INFO] 已取消卸载。"
    return 0
  fi

  systemctl stop nftables-port-sync.service 2>/dev/null || true
  systemctl disable nftables-port-sync.service 2>/dev/null || true

  rm -f "$SVC_FILE" 2>/dev/null || true
  rm -f "$DEFAULTS_FILE" 2>/dev/null || true
  rm -f "$PORTSYNC_SCRIPT" 2>/dev/null || true

  restore_or_remove_nft_conf

  nft -f "$NFT_CONF" 2>/dev/null || true
  systemctl disable --now nftables 2>/dev/null || true
  systemctl daemon-reload || true

  echo
  echo "[DONE] 卸载完成。"
}

# ============================
#  主菜单
# ============================

show_menu() {
  clear_screen
  echo
  echo "=============================="
  echo "   NFTables 防火墙管理菜单"
  echo "=============================="
  echo "1) 安装 / 重置"
  echo "2) 管理放行端口 (新增/删除)"
  echo "3) 卸载"
  echo "0) 退出"
  echo "------------------------------"
}

main() {
  while true; do
    show_menu
    read -r -e -p "请选择 [0-3]：" choice || true
    choice="$(trim "${choice:-}")"
    case "$choice" in
      1) install_fw; pause ;;
      2) manage_ports; pause ;;
      3) uninstall_fw; pause ;;
      0) echo "退出。"; exit 0 ;;
      *) echo "[ERR] 请输入 0/1/2/3"; pause ;;
    esac
  done
}

main