# luci-app-mosdns 项目手册

> 给未来的自己/维护者看的。先读第 3 节，那是整个项目最容易被改坏的地方。

## 1. 这是什么

OpenWrt 上的 MosDNS 图形化封装。mosdns 本体（`mosdns/`）通过 patches 打了 30 多个补丁（热重载、stats_api、adblock_set、缓存预取等），LuCI 前端（`luci-app-mosdns/`）负责配置生成与展示。

上游分支：`v5`，mosdns 版本 5.3.4。

## 2. 目录结构

```
luci-app-mosdns/
├── htdocs/luci-static/resources/view/mosdns/   # 前端页面（JS）
│   ├── basic.js       基础设置
│   ├── rules.js       规则列表（纯文本编辑）
│   ├── route.js       自定义上游分流
│   ├── statistics.js  统计
│   ├── update.js      地理数据更新
│   └── logs.js        日志
├── root/etc/config/mosdns                      # UCI 默认值
├── root/etc/init.d/mosdns                      # 服务脚本 + 配置生成（jshn）
├── root/usr/share/mosdns/mosdns.uc             # 更新/导出工具（geo2txt、adlist）
├── root/usr/share/mosdns/route.uc              # 自定义路由配置后处理器
├── root/usr/share/rpcd/ucode/luci.mosdns       # RPC 后端
└── root/usr/share/{luci/menu.d,rpcd/acl.d}     # 菜单与权限
mosdns/                                          # 服务端源码与补丁
```

## 3. 配置是怎么生成出来的（核心链路）

```
uci (/etc/config/mosdns)
      │
      ├── /etc/init.d/mosdns: generate_config()   ← shell + jshn，逐条 json_add_*
      │        │
      │        └──> /var/etc/mosdns.base.json     ← 基础配置（日志/缓存/内置集合/内置分流）
      │
      ├── /usr/share/mosdns/route.uc              ← ucode，读 base.json + uci，追加自定义路由
      │        │
      │        └──> /var/etc/mosdns.json          ← mosdns 实际加载的最终配置
      │
      └── mosdns start -c /var/etc/mosdns.json -d /etc/mosdns
```

要点：

- **只有 `configfile = /var/etc/mosdns.json` 时才走这条链路**。用户选 `Custom Config` 时 mosdns 直接读 `/etc/mosdns/config_custom.yaml`，上面两条全部跳过。
- `generate_config` 末尾先 `cp base.json mosdns.json` 再跑 `route.uc`，所以 route.uc 崩了 mosdns 照样能用基础配置启动。
- `route.uc` 每次都从 base.json 重新构建，天然幂等，不会累积残留。

### main_sequence 的执行顺序

改优先级时必须先看这里。当前顺序（自上而下命中即走）：

```
stats_collector → hosts → [has_resp] → lazy_cache → [has_resp] → redirect → [has_resp]
→ apple(可选) → ddns → whitelist → reject(黑名单/广告) → ★自定义路由★
→ greylist → stream_media(可选) → geosite_cn → geosite_no_cn → fallback
```

自定义路由插在 `query_is_reject_domain` 之后、`query_is_greylist_domain` 之前：
黑名单优先级最高，其次用户手动指定的分流，最后才是内置的 GeoIP/GeoSite 自动分类。

## 4. 自定义上游分流（route.uc）

### 数据结构（UCI）

```
config route
    option enabled '1'
    option name 'OpenAI'              # 仅 UI 显示，不进配置
    list domain 'keyword:openai'      # 自定义规则表达式
    list domain 'chatgpt.com'         # 无前缀 = 后缀匹配
    list preset 'geosite_no_cn'       # 引用已有 domain_set 的 tag
    list upstream 'tls://8.8.8.8'     # 一个或多个，并发查询
```

### 生成的插件（每条启用规则 3~4 个）

```json
{"tag":"route_set_N",  "type":"domain_set", "args":{"exps":[...], "sets":[...]}}
{"tag":"route_fwd_M",  "type":"forward",    "args":{"concurrent":2,"upstreams":[...]}}
{"tag":"route_up_M",   "type":"sequence",   "args":[{"exec":"prefer_ipv4"},{"exec":"ecs x.x.x.x"},{"exec":"$route_fwd_M"}]}
{"tag":"route_seq_N",  "type":"sequence",   "args":[{"matches":"qname $route_set_N","exec":"$route_up_M"}]}
```

再加 main_sequence 里两行：`exec $route_seq_N` + `jump has_resp_sequence`。

`route_up_M` 只在用户开了「EDNS client subnet」或「Remote DNS prefer IPv4」时存在，
没开时 `route_seq_N` 直接调 `$route_fwd_M`。

### 四个设计约束（改动前必读）

1. **插件顺序 = 加载顺序**。`domain_set` 的 `sets` 字段在 Init 阶段就通过 `GetPlugin` 解析，所以引用 `geosite_cn` 的集合必须排在它后面 —— 所有 route 插件统一插在 `main_sequence` 之前。
2. **forward 按上游组合去重**。N 条规则用同一组上游只生成 1 个 forward 实例，避免重复连接池和 bootstrap。
3. **上游参数不硬编码（forward 层）**。bootstrap / enable_pipeline / insecure_skip_verify / idle_timeout 从 base.json 里「字段最全」的 forward 插件复制模板。注意不能取第一个 forward —— 那是 `forward_xinfeng_udp`，只有 addr。
4. **上游包装不硬编码（sequence 层）**。`prefer_ipv4` / `ecs` 这些查询预处理，直接复制 `forward_remote_upstream` 的 args 前缀（丢掉末项的 `$forward_remote`），这样自定义路由和「远程 DNS」行为完全一致，用户改全局开关自动跟随。

### 匹配语义（性能相关）

| 写法 | 实现 | 复杂度 |
|---|---|---|
| `example.com`（默认） | SubDomainMatcher，按标签从右往左走 trie | O(标签数)，与规则数无关 |
| `keyword:xxx` | map 遍历 + strings.Contains | O(n)，每次查询全表扫描 |
| `full:xxx` | map 直接查 | O(1) |

几十条关键词无所谓，上千条会明显吃 CPU。UI 文案里已提示。

## 5. 修改代码时必读的约束

- **UCI 变更会自动重启 mosdns**（`ucitrack` 里配了 `{"config":"mosdns","init":"mosdns"}`），不需要在页面里写重启按钮。
- **规则文件热重载**：patch 206 给 `domain_set` / `ip_set` / `hosts` / `redirect` 加了 3 秒文件轮询。改 `/etc/mosdns/rule/*.txt` 不用重启；但改 `forward` 上游地址必须重启（写在 JSON 里）。
- **新增页面要动三个文件**：`menu.d/*.json`（菜单）、`acl.d/*.json`（权限）、`rpcd/ucode/luci.mosdns`（后端）。
- **rpcd 里读文件不需要 acl 授权**，只有前端 `fs.read/write` 才受 acl 的 file 段限制。
- **`_()` 不能在模块顶层调用**，翻译表可能还没就绪，放在函数里。

## 6. 调试

```sh
# 看生成出来的配置
cat /var/etc/mosdns.base.json
cat /var/etc/mosdns.json

# 单独跑一遍配置生成
/etc/init.d/mosdns restart && logread -e mosdns

# 验证某个域名最终走哪个上游
nslookup example.com 127.0.0.1:5335

# 验证配置能否被 mosdns 加载（不启动服务）
mosdns start -c /var/etc/mosdns.json -d /etc/mosdns   # 前台跑，Ctrl+C 退出
```

## 7. CI 构建（.github/workflows/release-build.yml）

### 两种触发方式

| 触发 | 构建范围 | 产物去向 |
|---|---|---|
| push tag（`v*`） | 精选 9 个常用架构 × 2 个 OpenWrt 版本 = 18 job | 发布到该 tag 的 Release |
| 手动 Run workflow | 下拉选 1 个架构 × 选定版本（默认 x86_64 + 25.12 = 1 job） | 填了 `release_tag` → Release；留空 → Actions artifact |

手动触发的三个输入：

- **arch**（下拉单选，默认 `x86_64`）：选 `all` = 全部 32 个架构；其余为单个架构
- **tag**（下拉单选，默认 `openwrt-25.12`）：`openwrt-25.12` / `openwrt-24.10` / `all`
- **release_tag**（文本框）：留空时**不会碰 Release**，只把 tar.gz 挂成 Actions 产物

> GitHub Actions 的 `choice` 只能单选、只能硬编码选项，不支持多选下拉。想一次编多个架构，只能选 `all` 或者分多次触发。

### 架构清单有两份，必须同步

| 位置 | 作用 |
|---|---|
| `workflow_dispatch.inputs.arch.options` | 只决定下拉框显示什么 |
| `prepare` job Python 里的 `ALL_ARCHES` | 真正的构建清单 |

`choice` 无法引用变量，这是平台限制。两边不同步时 `prepare` 会直接报错 `options 与 ALL_ARCHES 不同步`，不会静默构建错误架构。

其余三份数据只在 Python 里（单一来源）：

- `DEFAULT_ARCHES` —— push tag 时跑的精选列表（9 个）
- `ARCH_ALIAS` —— 版本间改名映射（如 25.12 的 `riscv64_riscv64` → `riscv64_generic`）
- `SKIP` —— 该版本已不存在的组合（如 25.12 的 `mips_4kec`），**在 prepare 阶段就剔除**

### 为什么要有 prepare job

旧写法把 `EFFECTIVE_ARCH` / `SKIP_BUILD` 塞进每个 job 的 `if`，结果是无效组合照样启动 runner 空跑。现在映射和剔除都前置到 prepare，build job 的 matrix 里每项已经是最终可用的 `effective_arch`，job 内无分支逻辑。
