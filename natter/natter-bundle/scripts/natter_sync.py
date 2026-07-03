#!/usr/bin/env python3
import ipaddress
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path


STATE_PATH = Path(os.environ.get("STATE_PATH", "/var/lib/natter-sync/state.json"))
POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "15"))
TCP_PUBLISH_MIN_UPTIME_SECONDS = int(os.environ.get("TCP_PUBLISH_MIN_UPTIME_SECONDS", "12"))

SSH_KEY = os.environ["SSH_KEY"]
SSH_HOST = os.environ["SSH_HOST"]
SSH_PORT = os.environ.get("SSH_PORT", "22")
SSH_USER = os.environ.get("SSH_USER", "root")

ROUTER_IP = os.environ.get("ROUTER_IP", "")
ROS_BASE = f"http://{ROUTER_IP}/rest/ip/firewall/nat" if ROUTER_IP else ""
ROS_ADDR_BASE = f"http://{ROUTER_IP}/rest/ip/address" if ROUTER_IP else ""
ROS_USER = os.environ.get("ROS_USER", "")
ROS_PASS = os.environ.get("ROS_PASS", "")
ROS_TARGET_IP = os.environ.get("ROS_TARGET_IP", "")
CGNAT_NET = ipaddress.ip_network("100.64.0.0/10")

TARGETS = json.loads(os.environ["TARGETS_JSON"])
REMOTE_YAMLS = json.loads(os.environ["REMOTE_YAMLS_JSON"])

LINE_PATTERNS = {
    "tcp": re.compile(r"tcp://[^\s]+ <--socket--> tcp://([^:]+):(\d+) <--Natter--> tcp://([^:]+):(\d+)"),
    "udp": re.compile(r"udp://[^\s]+ <--socket--> udp://([^:]+):(\d+) <--Natter--> udp://([^:]+):(\d+)"),
}
STUN_PATTERNS = {
    "tcp": re.compile(r"Got address tcp://([^:]+):(\d+) .* source tcp://([^:]+):(\d+)"),
    "udp": re.compile(r"Got address udp://([^:]+):(\d+) .* source udp://([^:]+):(\d+)"),
}


def run(cmd, input_text=None, check=True):
    proc = subprocess.run(cmd, input=input_text, text=True, capture_output=True)
    if check and proc.returncode != 0:
        raise RuntimeError(
            f"command failed: {' '.join(cmd)}\nstdout={proc.stdout}\nstderr={proc.stderr}"
        )
    return proc


def get_mapping(service, proto):
    proc = run(["journalctl", "-u", service, "-b", "0", "--no-pager", "-o", "cat"])
    pattern = LINE_PATTERNS[proto]
    stun_pattern = STUN_PATTERNS[proto]
    found = None
    for line in proc.stdout.splitlines():
        match = pattern.search(line)
        if match:
            found = {
                "local_ip": match.group(1),
                "local_port": int(match.group(2)),
                "server": match.group(3),
                "port": int(match.group(4)),
            }
            continue
        match = stun_pattern.search(line)
        if match:
            found = {
                "local_ip": match.group(3),
                "local_port": int(match.group(4)),
                "server": match.group(1),
                "port": int(match.group(2)),
            }
    if not found:
        raise RuntimeError(f"no {proto} mapping found in logs for {service}")
    return found


def load_state():
    if not STATE_PATH.exists():
        return {}
    try:
        return json.loads(STATE_PATH.read_text())
    except Exception:
        return {}


def save_state(state):
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    STATE_PATH.write_text(json.dumps(state, indent=2, sort_keys=True))


def parse_systemctl_show(text):
    data = {}
    for line in text.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key] = value
    return data


def get_service_runtime_status(service):
    proc = run([
        "systemctl", "show", service,
        "--property", "ActiveState",
        "--property", "SubState",
        "--property", "ActiveEnterTimestampMonotonic",
        "--property", "ExecMainPID",
    ])
    data = parse_systemctl_show(proc.stdout)
    active_usec = int(data.get("ActiveEnterTimestampMonotonic") or "0")
    now_usec = int(time.clock_gettime(time.CLOCK_MONOTONIC) * 1_000_000)
    uptime_seconds = max(0.0, (now_usec - active_usec) / 1_000_000) if active_usec else 0.0
    return {
        "active_state": data.get("ActiveState", ""),
        "sub_state": data.get("SubState", ""),
        "exec_main_pid": int(data.get("ExecMainPID") or "0"),
        "uptime_seconds": uptime_seconds,
    }


def is_target_publish_ready(name, cfg):
    if cfg["proto"] != "tcp":
        return True, None
    status = get_service_runtime_status(cfg["service"])
    if status["active_state"] != "active" or status["sub_state"] != "running":
        return False, "service_not_running"
    if status["uptime_seconds"] < TCP_PUBLISH_MIN_UPTIME_SECONDS:
        return False, "waiting_for_tcp_validation"
    return True, None


def build_publish_mappings(observed_mappings, previous_published):
    publish_mappings = {}
    publish_status = {}
    for name, cfg in TARGETS.items():
        ready, reason = is_target_publish_ready(name, cfg)
        if ready:
            publish_mappings[name] = observed_mappings[name]
            publish_status[name] = {"status": "ready"}
            continue
        if name in previous_published:
            publish_mappings[name] = previous_published[name]
            publish_status[name] = {"status": "holding", "reason": reason}
            continue
        publish_status[name] = {"status": "skipped", "reason": reason}
    return publish_mappings, publish_status


REMOTE_SCRIPT_TEMPLATE = r'''
import json
import re
import shutil
import sys
import urllib.parse
from pathlib import Path

data = json.loads(sys.stdin.read())
payload = data["payload"]
yaml_configs = data["yaml_configs"]

def update_stash_format(path, payload):
    text = path.read_text()
    lines = text.splitlines()
    current = None
    seen = set()
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("- name:"):
            name = stripped.split(":", 1)[1].strip()
            current = name if name in payload else None
            if current:
                seen.add(current)
            continue
        if current and line.startswith("    server:"):
            lines[i] = "    server: {}".format(payload[current]["server"])
        elif current and line.startswith("    port:"):
            lines[i] = "    port: {}".format(payload[current]["port"])
    missing = [name for name in payload if name not in seen]
    if missing:
        raise SystemExit("missing YAML entries: " + ", ".join(missing))
    new_text = "\n".join(lines) + "\n"
    if new_text != text:
        path.write_text(new_text)
        return "updated"
    return "unchanged"

def update_egern_format(path, payload):
    text = path.read_text()
    lines = text.splitlines()
    current_block = None
    current_name = None
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("- shadowsocks:") or stripped.startswith("- hysteria2:"):
            current_block = stripped.split(":")[0].lstrip("- ")
            current_name = None
            continue
        if current_block and stripped.startswith("name:"):
            current_name = stripped.split(":", 1)[1].strip()
            if current_name not in payload:
                current_name = None
            continue
        if current_name and line.startswith("    server:"):
            lines[i] = "    server: {}".format(payload[current_name]["server"])
        elif current_name and line.startswith("    port:"):
            lines[i] = "    port: {}".format(payload[current_name]["port"])
    new_text = "\n".join(lines) + "\n"
    if new_text != text:
        path.write_text(new_text)
        return "updated"
    return "unchanged"

def update_clash_format(path, payload):
    text = path.read_text()
    lines = text.splitlines()
    seen = set()
    for i, line in enumerate(lines):
        if "name:" not in line or "server:" not in line or "port:" not in line:
            continue
        name_match = re.search(r"name:\s*['\"]?([^,'\"}]+)", line)
        if not name_match:
            continue
        name = name_match.group(1).strip()
        if name not in payload:
            continue
        seen.add(name)
        line = re.sub(r"server:\s*[^,}]+", "server: {}".format(payload[name]["server"]), line)
        line = re.sub(r"port:\s*\d+", "port: {}".format(payload[name]["port"]), line)
        lines[i] = line
    missing = [name for name in payload if name not in seen]
    if missing:
        raise SystemExit("missing YAML entries: " + ", ".join(missing))
    new_text = "\n".join(lines) + "\n"
    if new_text != text:
        path.write_text(new_text)
        return "updated"
    return "unchanged"

def update_v2rayn_format(path, payload):
    text = path.read_text()
    lines = text.splitlines()
    seen = set()

    for i, line in enumerate(lines):
        stripped = line.strip()
        if not stripped:
            continue
        parsed = urllib.parse.urlsplit(stripped)
        name = urllib.parse.unquote(parsed.fragment)
        if name not in payload:
            continue
        if "@" not in parsed.netloc:
            raise SystemExit("invalid v2rayN entry for {}: missing userinfo".format(name))
        userinfo = parsed.netloc.rsplit("@", 1)[0]
        server = str(payload[name]["server"])
        if ":" in server and not server.startswith("["):
            server = "[{}]".format(server)
        new_netloc = "{}@{}:{}".format(userinfo, server, payload[name]["port"])
        lines[i] = urllib.parse.urlunsplit(parsed._replace(netloc=new_netloc))
        seen.add(name)

    missing = [name for name in payload if name not in seen]
    if missing:
        raise SystemExit("missing v2rayN entries: " + ", ".join(missing))
    new_text = "\n".join(lines) + "\n"
    if new_text != text:
        path.write_text(new_text)
        return "updated"
    return "unchanged"

results = {}
for name, config in yaml_configs.items():
    path = Path(config["path"])
    backup = path.with_suffix(path.suffix + ".sync.bak")
    shutil.copy2(path, backup)
    fmt = config["format"]
    target_names = config.get("targets")
    scoped_payload = payload if not target_names else {k: payload[k] for k in target_names if k in payload}
    if fmt == "stash":
        results[name] = update_stash_format(path, scoped_payload)
    elif fmt == "egern":
        results[name] = update_egern_format(path, scoped_payload)
    elif fmt == "clash":
        results[name] = update_clash_format(path, scoped_payload)
    elif fmt == "v2rayn":
        results[name] = update_v2rayn_format(path, scoped_payload)
    else:
        results[name] = "unknown format"

print(json.dumps(results))
'''


def update_remote_yamls(mappings):
    import tempfile

    payload = {key: {"server": value["server"], "port": value["port"]} for key, value in mappings.items()}
    data = json.dumps({"payload": payload, "yaml_configs": REMOTE_YAMLS})
    with tempfile.NamedTemporaryFile(mode="w", suffix=".py", delete=False) as sf:
        sf.write(REMOTE_SCRIPT_TEMPLATE)
        script_path = sf.name
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as df:
        df.write(data)
        data_path = df.name
    try:
        run([
            "scp", "-i", SSH_KEY, "-P", SSH_PORT,
            "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
            script_path, f"{SSH_USER}@{SSH_HOST}:/tmp/natter_sync_script.py",
        ])
        run([
            "scp", "-i", SSH_KEY, "-P", SSH_PORT,
            "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
            data_path, f"{SSH_USER}@{SSH_HOST}:/tmp/natter_sync_data.json",
        ])
        proc = run([
            "ssh", "-i", SSH_KEY, "-p", SSH_PORT,
            "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
            f"{SSH_USER}@{SSH_HOST}",
            "python3 /tmp/natter_sync_script.py < /tmp/natter_sync_data.json; "
            "rm -f /tmp/natter_sync_script.py /tmp/natter_sync_data.json",
        ])
        return proc.stdout.strip() or "ok"
    finally:
        os.unlink(script_path)
        os.unlink(data_path)


def ros_probe():
    if not ROUTER_IP or not ROS_USER or not ROS_PASS or not ROS_TARGET_IP:
        return {"mode": "skipped", "reason": "router_env_missing"}
    proc = run(["curl", "-sS", "-u", f"{ROS_USER}:{ROS_PASS}", ROS_BASE], check=False)
    if proc.returncode != 0:
        return {"mode": "skipped", "reason": f"curl_failed:{proc.returncode}"}
    try:
        data = json.loads(proc.stdout)
    except Exception:
        return {"mode": "skipped", "reason": "not_routeros_json"}
    if not isinstance(data, list):
        return {"mode": "skipped", "reason": "unexpected_json_type"}
    if any(isinstance(row, dict) and ".id" in row for row in data):
        return {"mode": "routeros", "data": data}
    return {"mode": "skipped", "reason": "no_routeros_records"}


def ros_load_addresses():
    proc = run(["curl", "-sS", "-u", f"{ROS_USER}:{ROS_PASS}", ROS_ADDR_BASE], check=False)
    if proc.returncode != 0:
        raise RuntimeError(f"ROS address query failed: {proc.returncode}")
    data = json.loads(proc.stdout)
    if not isinstance(data, list):
        raise RuntimeError("ROS address query returned unexpected JSON type")
    return data


def ros_find_rule_id(rows, comment):
    for row in rows:
        if row.get("comment") == comment:
            return row[".id"]
    raise RuntimeError(f"ROS NAT rule not found for comment: {comment}")


def ros_is_private_like(address):
    try:
        ip = ipaddress.ip_interface(address).ip
    except ValueError:
        ip = ipaddress.ip_address(address)
    return ip.is_private or ip in CGNAT_NET


def ros_pick_dst_port(rule, mapping, addr_rows):
    in_interface = rule.get("in-interface")
    iface_addrs = []
    if in_interface:
        for row in addr_rows:
            if row.get("interface") == in_interface or row.get("actual-interface") == in_interface:
                address = row.get("address")
                if address:
                    iface_addrs.append(address)
    use_local_port = any(ros_is_private_like(address) for address in iface_addrs)
    return {
        "dst_port": mapping["local_port"] if use_local_port else mapping["port"],
        "port_source": "local_port" if use_local_port else "public_port",
        "in_interface": in_interface,
        "wan_addresses": iface_addrs,
    }


def ros_find_shadowing_udp_eim(rows, target_rule_id):
    target_index = None
    for idx, row in enumerate(rows):
        if row.get(".id") == target_rule_id:
            target_index = idx
            break
    if target_index is None:
        return None
    for row in rows[:target_index]:
        if (
            row.get("chain") == "dstnat"
            and row.get("action") == "endpoint-independent-nat"
            and row.get("protocol") == "udp"
            and row.get("disabled") != "true"
        ):
            return row.get(".id")
    return None


def ros_patch_rule(rule_id, proto, dst_port, local_port):
    body = json.dumps({
        "protocol": proto,
        "dst-port": str(dst_port),
        "to-addresses": ROS_TARGET_IP,
        "to-ports": str(local_port),
    })
    proc = run([
        "curl", "-sS", "-u", f"{ROS_USER}:{ROS_PASS}", "-X", "PATCH",
        f"{ROS_BASE}/{rule_id}",
        "-H", "content-type: application/json",
        "--data", body,
    ])
    return json.loads(proc.stdout)


def maybe_update_ros_nat(mappings):
    probe = ros_probe()
    if probe["mode"] != "routeros":
        return {"mode": "skipped", "reason": probe["reason"]}
    rows = probe["data"]
    addr_rows = ros_load_addresses()
    results = {"mode": "routeros"}
    for name, cfg in TARGETS.items():
        if "ros_comment" not in cfg:
            continue
        if name not in mappings:
            results[name] = {"status": "skipped", "reason": "mapping_unavailable"}
            continue
        rule_id = ros_find_rule_id(rows, cfg["ros_comment"])
        rule = next(row for row in rows if row.get(".id") == rule_id)
        port_plan = ros_pick_dst_port(rule, mappings[name], addr_rows)
        row = ros_patch_rule(rule_id, cfg["proto"], port_plan["dst_port"], mappings[name]["local_port"])
        results[name] = {
            "id": row.get(".id", rule_id),
            "protocol": row.get("protocol"),
            "dst-port": row.get("dst-port"),
            "to-ports": row.get("to-ports"),
            "port-source": port_plan["port_source"],
            "in-interface": port_plan["in_interface"],
            "wan-addresses": port_plan["wan_addresses"],
        }
        if cfg["proto"] == "udp":
            shadow_rule_id = ros_find_shadowing_udp_eim(rows, rule_id)
            if shadow_rule_id:
                results[name]["shadowed-by"] = shadow_rule_id
    return results


def main():
    print("natter-sync started", flush=True)
    state = load_state()
    while True:
        try:
            observed_mappings = {
                name: get_mapping(cfg["service"], cfg["proto"])
                for name, cfg in TARGETS.items()
            }
            previous_observed = state.get("observed_mappings", state.get("mappings", {}))
            previous_published = state.get("published_mappings", state.get("mappings", {}))
            publish_mappings, publish_status = build_publish_mappings(observed_mappings, previous_published)
            observed_changed = observed_mappings != previous_observed
            publish_changed = publish_mappings != previous_published
            state_schema_changed = any(
                key not in state for key in ("observed_mappings", "publish_status", "published_mappings")
            )
            if observed_changed or publish_changed or state_schema_changed:
                if publish_changed:
                    ros_result = maybe_update_ros_nat(publish_mappings)
                    yaml_result = update_remote_yamls(publish_mappings)
                else:
                    ros_result = state.get("ros")
                    yaml_result = state.get("yaml")
                state = {
                    "mappings": publish_mappings,
                    "observed_mappings": observed_mappings,
                    "publish_status": publish_status,
                    "published_mappings": publish_mappings,
                    "ros": ros_result,
                    "updated_at": int(time.time()),
                    "yaml": yaml_result,
                }
                save_state(state)
                print(
                    f"synced: observed={json.dumps(observed_mappings, sort_keys=True)} "
                    f"published={json.dumps(publish_mappings, sort_keys=True)} "
                    f"publish_status={json.dumps(publish_status, sort_keys=True)} "
                    f"ros={json.dumps(ros_result, sort_keys=True)} "
                    f"yaml={yaml_result}",
                    flush=True,
                )
        except Exception as exc:
            print(f"sync error: {exc}", file=sys.stderr, flush=True)
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    main()
