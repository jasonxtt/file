# config_rust：原生（Rust）版 MosDNS 配置包

`config_rust` 是由 `config_all` 改写的**原生运行时专用**配置包：路由、规则、缓存、开关、分流序列都与 `config_all` 相同，
只把“WebUI 里可调整的值”（代理地址、ECS 地址、各上游组的上游列表、域名生成开关）改成了**具名对象 + `$标签` 引用**，
由原生运行时统一管理。Go 版 MosDNS 不能加载本包（不认识 `socks5_proxy` / `ecs_address`，也不认识 `proxy:` / `use_proxy:` 写法）。

## 可调整的值放在哪里

| 值 | YAML 里的对象 | WebUI 位置 | 修改后保存在 |
| --- | --- | --- | --- |
| SOCKS5 代理地址 | `sub_config/settings.yaml` 的 `main_proxy`（`socks5_proxy`） | 系统设置 → SOCKS5 / ECS 覆盖 | `webinfo/settings.json` |
| ECS 地址 | 同上 `client_ecs`（`ecs_address`） | 同上 | 同上 |
| 各组上游列表、是否走代理 | 各 `aliapi` 的 `upstreams`（条目 `use_proxy`） | 上游设置 | 同上 |
| 域名生成开关 | `route_learner` 各类别的 `enabled` | 系统设置 → 域名生成 | 同上 |
| 功能开关（运行模式、屏蔽、缓存、客户端分流等） | `sub_config/flags.yaml` 的 `feature_flag` | 规则设置各子项顶部（按开关声明的 `section` 自动生成） | 同上（`flags` 段） |

- `webinfo/settings.json` 只保存**与本包 YAML 不同**的值；删除该文件即回到本包默认。修改在 WebUI 保存后**立即生效**，不需要重启。
- **代理默认为空 = 不使用代理**（与 `config_all` 在 Go 下默认的“全局 socks5 为空”相同）。填写 `main_proxy` 后，所有规则源下载以及
  `foreign` / `foreignecs` 里 `use_proxy: true` 的上游才经它连接；其余上游不受影响。
- 原生运行时**不读取** Go 版的 `webinfo/upstream_overrides.json`、`config_overrides.json`、`domain_generation_settings.json`。
  从 Go 版迁移时用一次性工具 `atomdns-settings-migrate`（见文末）。

## 与 config_all 的差异

除下列文件外，其余文件与 `config_all` **逐字节相同**。

### 新增 `sub_config/settings.yaml`，`config_custom.yaml` 的 include 首位加入它
定义 `main_proxy`（`addr: ""`，无代理）与 `client_ecs`（`2408:8888::8`，即 `config_all` 里 `ecs` 的原值）。

### 规则源：`sub_config/rule_set.yaml`（5 处）、`sub_config/adguard.yaml`（1 处）
`socks5: ""` → `proxy: $main_proxy`。
理由：Go 的全局 `socks5` 覆盖会替换**所有**名为 `socks5` 的参数（包括值为空串的）。因此全局代理为空时规则源直连，非空时全部走代理；
`proxy: $main_proxy` 在 `main_proxy` 为空/非空时分别得到同样的结果。

### `sub_config/forward_local.yaml`（`domestic`）
- 上游列表写成 Go 在 `config_all` 下**实际生效**的列表：随包发布的 `webinfo/upstream_overrides.json` 启用了 `阿里UDP`（`udp://223.5.5.5`）与
  `阿里DOH`（`https://dns.alidns.com/dns-query`，`dial_addr: 223.5.5.5`）；YAML 里原有的 `223.5.5.5 / 223.6.6.6 / 114.114.114.114` 在 Go 下被它整体替换。
- `concurrent: 3` → `2`：Go 对覆盖列表按启用数重算（2 个启用 → 2），原生不重算，所以直接写成 2。
- 加插件级 `proxy: $main_proxy`：让 WebUI 可以给本组任意条目勾选“走代理”；本组条目默认都不走代理（与 Go 下 `domestic` 默认一致）。
- 原包里默认停用的预置上游（`阿里TCP`、`阿里DOT`、`运营商`、停用的签名 AliAPI）不在列表里（YAML 只写启用项，设置层列表只保存差异），
  已以注释保留在文件里，需要时在 WebUI 上游页重新添加即可。

### `sub_config/forward_nocn.yaml`（`foreign`）
- 上游写成 Go 实际生效的 `google`（`https://dns.google/dns-query`，`dial_addr: 8.8.8.8`）与 `cloudflare`（`https://1.1.1.1/dns-query`）；
  YAML 原有的 `1.1.1.1 / 8.8.8.8`（后者 `upstream_query_timeout: 1000`）在 Go 下被覆盖列表替换。
- 两个条目写 `use_proxy: true`，插件级 `proxy: $main_proxy`。理由：Go 对 `foreign` / `foreignecs` 的 `tcp/tls/https` 条目在未显式关闭时默认使用全局代理；
  原生去掉了这条按组名的隐式规则，改成显式的 `use_proxy`。`main_proxy` 为空时仍然直连，结果相同。

### `sub_config/forward_nocn_ecs.yaml`（`foreignecs` 与 `sequence_google_node`）
- 上游写成 Go 实际生效的 `google`；YAML 里的字面量 `socks5: "127.0.0.1:7891"` 在 Go 下被覆盖列表替换而**不会被使用**（包内 `foreignecs` 有启用的覆盖条目），所以本包不保留它。
- 条目标签 `google` → `google-foreignecs`：原生要求上游标签**全局唯一**（用于观察、缓存来源记录），`foreign` 已使用 `google`。
- `exec: ecs 2408:8888::8` → `exec: ecs $client_ecs`（值相同）。

### `sub_config/forward_1.yaml`（`nocnfake`、`cnfake`）
- `nocnfake` 的上游写成 Go 实际生效的 `sing-box`（`udp://127.0.0.1:6666`；YAML 原值 `7874` 在 Go 下被覆盖列表替换）。
- `cnfake` 的覆盖条目全部停用，Go 沿用 YAML 列表，所以仍是 `udp://127.0.0.1:1053`，仅补上标签 `cnfake`（WebUI 要求每个上游有标签）。
- 两个组都加插件级 `proxy: $main_proxy`（默认不走代理）。

### 路由学习（config schema 2）：`sub_config/route_learner.yaml`（新）、`domain_output.yaml`、`rule_set.yaml`、`forward_1.yaml`、`process_v4.yaml`、`process_v6.yaml`
原来分散在流程里的 `matches` + `exec: $my_xxxlist` 学习名单（七个 `domain_output`、七个 `my_*rule` 规则源、`unified_matcher1` 里的五条学习规则）改成一个 `route_learner`
（存储，每类每条单独过期，状态写 `gen/route_learner.json`）和七个 `route_learn` 规则（条件与类别）；流程里只剩 `exec: $learn_xxx` 一行。
`domain_output.yaml` 只剩 `top_domains`（访问排行，只计数）。类别 tag（`my_realiplist` 等）、标签字符串与 mark（2/3/4/11/12）都没变，后续流程的 `fast_mark` 判断没变。
`config_custom.yaml` 的 `sequence_requery`（只有刷新分流的服务器用它）不再因 `fast_mark 2/3`（记忆无V4/无V6）提前空答：刷新要重新探测这些名字，规则才能再确认它们、刷新到期时间；普通查询入口 `sequence_6666` 不变。
`gen/` 下旧的学习名单文件（`*list.txt`、`*rule.txt`）不再被读取，已部署的机器上可以手动删除。详见 mosdns-rust 的 `docs/rust/contracts/native-route-learner.md`。

### 功能开关（config schema 3）：`sub_config/flags.yaml`（新，取代 `switch.yaml`）、`config_custom.yaml`、`forward_1.yaml`、`forward_nocn.yaml`、`process_v4.yaml`、`process_v6.yaml`
原来的 `switch1`–`switch17`（值 `A`/`B`，存 `rule/switchN.txt`）改成 13 个具名开关（`feature_flag`）：`core_mode`（原 3）、`dns_mode`（17）、`cn_fakeip`（9，开 = 旧 B）、`prefer_v4`（8）、`ddns_foreign`（16）、
`block_empty` 与 `block_blocklist`（原 1 拆成两个）、`block_qtypes`（5）、`block_ads`（7）、`block_aaaa`（6）、`lazy_cache`（4）、`full_cache`（13）、`client_routing`（2 与 12 合并为三选一）；10/11/14/15 没有引用，删除。
流程里的 82 处 `switchN 'X'` 逐一换成 `flag 名字` / `flag 名字=选项` / `"!flag 名字"`，规则条数、顺序与所在流程都没变；默认值与本包原来的 `rule/switchN.txt` 相同。
开关的值存 `webinfo/settings.json` 的 `flags` 段（只存与默认不同的）；首次以新程序正常启动时从 `rule/switchN.txt` 迁移一次（在线更新试运行期间不写），旧文件保留但不再读取。
`rule/switchN.txt` 样例文件保留（新安装时它们就是迁移来源，取值等于默认）。详见 mosdns-rust 的 `docs/rust/contracts/native-feature-flags.md`。
`core_mode`、`dns_mode`、`cn_fakeip` 三个开关带可选参数 `requery_on_change: true`：值实际改变并发布后，程序自己启动一次 `requery`（清缓存再预热，由 `requery` 的 `flush_rules` 决定清什么）；
值没变、在线更新试运行期间（接口 503）或配置里没有 `requery` 插件时不触发。WebUI 不再自己做“切换后清缓存、触发刷新”的联动，接口返回里的 `requery_triggered` 说明这次是否已触发。
自己新增开关时需要同样联动，在它的 `args` 里写 `requery_on_change: true`。

### 不再附带 `ui/ilog/`
本包不再附带旧的 `ui/ilog/` 日志页（atomdns 的 WebUI 在 `/`，不需要它）。配置包（`config_rust_up.zip`）只管理配置，不管理已部署机器上的 `ui/` 目录：已有的 `ui/ilog/` 不会被动到，也不再被更新，不用时可以手动删除。

### 上游组随开关显示/隐藏、开关归属、刷新修正（config schema 4，atomdns v0.4.0）：`forward_1.yaml`、`flags.yaml`
- `aliapi` 新增可选参数 `show_when`（只影响 WebUI，不影响解析）：条件写法与流程里的开关匹配相同（`flag 名字`、`flag 名字=选项`、`"!flag 名字"`，列表表示全部满足），写错会在加载时报错。
  条件不成立时，该组在上游设置里默认隐藏（可点“显示未生效的组”），概览的上游统计里不显示。本包：`cnfake` → `show_when: flag cn_fakeip`；`nocnfake` → `show_when: flag dns_mode=fakeip`。
  注意：**3099 端口（clashmi 回家）不看 `cn_fakeip`，始终使用 `cnfake`**；`cn_fakeip` 关时界面不显示 `cnfake`，但 3099 端口照常用它。`domestic`、`foreign`、`foreignecs`（4444 端口一直在用）始终显示。
- 一个上游组至少要保留一个启用的上游：全部停用或删掉最后一个会被拒绝并说明原因；不想用某个组，关闭使用它的开关即可。
- `ddns_foreign`（DDNS 优先国外解析）的 `section` 从 `upstream` 改为 `mode`，在 WebUI 的“运行模式”里。
- 刷新（requery）流程 `sequence_local_addlist_exit_requery`、`sequence_localfake_addlist_exit_requery` 里“国外应答含非国内 IP”的分支改为按 `dns_mode` 走：FakeIP 分流照旧丢弃应答改问 sing-box（`nocnfake`）；
  RealIP 分流保留国外真实 IP、不再问 sing-box。原来在 RealIP 模式下刷新会把 FakeIP 写进与客户端共用的缓存（`cache_all` / `cache_all_noleak`），客户端随后拿到 FakeIP。

### 订阅集合改名（config schema 5，只改命中标签）：`rule_set.yaml`，另有注释改动：`process_v4.yaml`、`process_v6.yaml`、`route_learner.yaml`
`rule_set.yaml` 里四个订阅集合的 `output_tag`（日志里的命中标签）改成与 WebUI 分流规则里的名称一致：`订阅直连补充` → `直连域名`（`cuscn`）、`订阅代理补充` → `代理域名`（`cusnocn`）、`订阅直连` → `中国域名`（`geosite_cn`）、`订阅代理` → `非中国域名`（`geosite_no_cn`）。
`fast_mark` 编号、匹配顺序和分流判定都没有变；程序同时认新旧两套名字，旧的查询日志保留旧名称，统计里新旧名称分开计数。

### 缓存默认值收紧、数值可在 WebUI 调整（config schema 6）：`cache.yaml`
7 个缓存原来都是 `size: 20000000`（实际不设限）、`lazy_cache_ttl: 259200000`（秒，3000 天，等于不限）、`dump_interval: 36000`。现改为：

| 缓存 | `size`（条） | `lazy_cache_ttl` | `dump_interval` |
|---|---|---|---|
| `cache_all`、`cache_all_noleak`（直面客户端，兼容/安全模式只有一个在用） | 100000 | 604800（7 天） | 21600（6 小时） |
| `cache_cn` | 50000 | 604800 | 21600 |
| `cache_google`、`cache_google_node`、`cache_node`、`cache_cnmihomo` | 20000 | 604800 | 21600 |

依据：生产观察里最大的缓存约 3.3 万条，各档约为现有用量的 3 倍以上。应用本包后这 7 个缓存各以空缓存重新开始一次（容量、保留时长、写盘间隔都是缓存的“身份”），之后过期缓存最多再保留 7 天。
三个数值可在 WebUI「规则设置 › 缓存设置」调整，保存在 `webinfo/settings.json` 的 `caches` 段（只存与本文件不同的值），**不受配置包更新影响**；域名学习的每类有效期、容量和写盘间隔同样可在「域名学习」页调整（`learning` 段），本包的 `route_learner.yaml` 数值没有改。
7 个缓存都加了可选的 `label`（WebUI 里显示的中文名，如“全局缓存·兼容模式”“国内查询缓存”），`route_learner.yaml` 里的学习规则也加了 `label`（学习明细“原因”列的中文说明）；不写就显示 tag。程序为专属分流组生成的缓存（`cache_special_N`）自动带 `专属分流组「组名」缓存` 的标签，容量、保留时长、写盘间隔用同一组新默认值（20000、604800、21600）。
回滚到不认识这两段的旧程序前，先在 WebUI 里“恢复默认”（或删除 `settings.json` 里的 `caches`、`learning`），否则旧程序会因未知键拒绝启动。

### 全新安装包 `config_rust.zip` 带 WebUI
atomdns 从 v0.4.0 起不再把 WebUI 编进程序：WebUI 是 `<配置根>/ui/main/`（由 `/` 提供），随在线更新与程序一起替换（只在该目录已存在时）。
`config_rust.zip` 由 `../build_config_rust_zip.sh <atomdns-webui.tar.gz>` 生成：本目录内容 + 同版本 atomdns Release 的 `atomdns-webui.tar.gz` 解到 `ui/main/`。本目录里不放 WebUI 文件。
不要 WebUI（纯后端）就删掉 `ui/main/`，`/` 会显示“没有安装 WebUI”，接口照常。

### `webinfo/`
删除 `upstream_overrides.json` 与 `config_overrides.json`（原生不读取，保留会让人误以为它们仍然生效）。其余文件不变。

## 等价性论证（路由、上游、代理、ECS）

- **路由与序列**：除上面列出的 `aliapi` 参数和 `ecs` 写法外，所有 `sequence`、规则、缓存、开关、监听、`requery` 等定义没有任何改动（学习名单见上面“路由学习”一节）。
- **上游**：每个 `aliapi` 组的有效上游列表、协议、地址、`dial_addr`、`concurrent` 与 `config_all`（含随包覆盖文件）在 Go 下的实际值一致；仅 `foreignecs` 的上游标签加了后缀。
- **代理**：Go 默认（全局 socks5 为空）下所有连接都是直连；本包默认 `main_proxy` 为空，同样全部直连。填写代理后，Go 下走代理的集合是“全部规则源 + `foreign`/`foreignecs` 的 tcp/tls/https 条目”，
  本包与之相同（规则源 `proxy: $main_proxy`，两组条目 `use_proxy: true`）；UDP 条目在两边都不使用代理。
- **ECS**：`ecs $client_ecs` 的默认值就是原来的 `2408:8888::8`。Go 下全局 `ecs` 覆盖会替换 `ecs ` 开头的字符串，等价于修改 `client_ecs`。
- 用 Go 语义的独立实现（`scripts/go-effective-oracle.py`，在 mosdns-rust 仓库）对迁移后的有效配置做过逐条对照，结果记录在 mosdns-rust 的 `docs/rust/validation-records/10-09-m1-f2/`。

## 已知差异

1. 默认停用的预置上游不在列表里（见 `forward_local.yaml` 的注释）。
2. `concurrent` 是 YAML 里的固定值，WebUI 增删启用上游不会重算它（Go 会重算为 `min(启用数, 20)`）。
3. 上游标签全局唯一（`foreignecs` 的 `google-foreignecs`）。
4. 原生没有“高级替换规则”（任意字符串替换）；需要的改动请直接修改 YAML。
5. 专属分流组（special_groups）的托管、更新检查、重启、WebUI 端口、配置包管理等页面按原生运行时当前能力显示，与本包无关。

## 部署

1. 解压 `config_rust.zip` 为配置目录，用原生 `atomdns start -d <目录> -c config_custom.yaml` 运行；先用 `atomdns check -d <目录> -c config_custom.yaml` 检查
   （应为 `gaps=0 cascades=0 globals=0`，所有 `EFFECTIVE` 行的来源为 `yaml`）。
2. 从 Go 版迁移已有的覆盖设置（代理、ECS、上游列表、域名生成开关）：

   ```bash
   atomdns-settings-migrate --from <Go 配置目录> -d <config_rust 目录> -c config_custom.yaml --out <输出目录>
   ```

   工具只读 Go 目录里的三个覆盖文件，不修改任何输入，在 `<输出目录>` 写 `settings.json` 与 `migration-report.txt`。
   退出码 0 表示全部映射；1 表示报告里列出了无法映射或需要人工确认的项（例如启用的签名 AliAPI、`so_mark`、条目自带的不同代理地址、`replacements`；
   以及覆盖文件里没有某个组、或该组条目全部停用——这时 Go 实际运行的是它自己 YAML 里的上游列表，工具看不到，需要你核对原生默认列表是否与之一致），需人工处理；2 表示出错，此时不会留下残缺的输出。
   确认报告后把 `settings.json` 复制到 `<config_rust 目录>/webinfo/settings.json`，再次 `check` 并启动。
3. Go 版 `special_upstream_groups.json` 等其它状态文件不在迁移范围内。

## 打包

```bash
cd atomdns/config/config_rust && zip -r ../config_rust.zip . -x '.DS_Store' -x '*/.DS_Store'
```

（`build_config_up.sh` 面向 Go 版的增量更新包 `config_up`，不适用于本包。）
