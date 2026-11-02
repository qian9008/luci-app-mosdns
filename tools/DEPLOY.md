# luci-app-mosdns 二开手动部署

不编译 OpenWrt SDK，纯文件覆盖。适用于：只改了 luci 层（JS / ucode / init.d / menu / acl / po）的场景。

---

## 0. 前置条件

在路由器上确认：

```sh
cat /etc/openwrt_release | grep DESCRIPTION
apk info | grep -E "mosdns|v2ray|geo"
```

需要已装这几个包（官方源即可）：

| 包 | 作用 |
|---|---|
| `mosdns` | 主程序二进制 |
| `luci-app-mosdns` | 本仓库要覆盖的目标 |
| `v2ray-geoip` / `v2ray-geosite` | 内置域名/IP 集合，基础配置会引用 |

**检查 mosdns 版本**：

```sh
/usr/bin/mosdns version
```

本仓库 `mosdns/Makefile` 是 `5.3.4-r15`，r15 比 r14 多 5 个 patch（stats_api 统计修复、fallback 保留 EDNS0 等）。**自定义上游路由功能不依赖这些 patch**，r14 也能正常跑 `route.uc`。只有 LuCI 的统计页面在 r14 上会有已知的小 bug。

不想编译就别管版本差，功能能用。

---

## 1. 本地打包

```sh
cd /Users/qian/Documents/code/luci-app-mosdns
./tools/pack-luci.sh
# → dist/luci-app-mosdns-overlay.tar.gz  (约 112 KB)
```

脚本会自检，全绿才继续。**看到任何 `✗` 就别往下走。**

关键自检项：

```
✓ 无 './' 条目，不会动根目录属性
✓ 全部条目 uid=0 gid=0 (root:root)
✓ 已排除 /etc/config/mosdns 与 /etc/mosdns/
```

前两条是 2026-11-01 事故的防线，缺一不可（详见 `PROJECT_wiki.md` 第 8 节）。

---

## 2. 传到路由器

```sh
scp dist/luci-app-mosdns-overlay.tar.gz root@192.168.50.9:/tmp/
```

---

## 3. 备份现有文件（建议，5 秒）

```sh
ssh root@192.168.50.9 '
cp /etc/init.d/mosdns /tmp/init.d-mosdns.bak
cp -r /usr/share/mosdns /tmp/mosdns-share.bak
'
```

出问题能直接还原，不用重装包。

---

## 4. 解压覆盖

```sh
ssh root@192.168.50.9 '
cd / && tar xzf /tmp/luci-app-mosdns-overlay.tar.gz
'
```

包内只有 `www/` `etc/init.d/` `etc/hotplug.d/` `etc/uci-defaults/` `usr/share/` 五个顶层，不会碰 `/etc/config` 和 `/etc/mosdns`。

---

## 5. 重启服务

```sh
ssh root@192.168.50.9 '
/etc/init.d/mosdns restart
rm -rf /tmp/luci-*
/etc/init.d/rpcd restart
'
```

三条的作用各不相同，缺一条就有一半改动不生效：

| 命令 | 让什么生效 |
|---|---|
| `/etc/init.d/mosdns restart` | `init.d/mosdns` 新逻辑、`route.uc` 后处理 |
| `rm -rf /tmp/luci-*` | LuCI 前端模板/菜单缓存（不清的话页面还是旧的） |
| `/etc/init.d/rpcd restart` | `menu.d` 菜单项、`acl.d` 权限、`luci.mosdns` ucode 后端 |

---

## 6. 验证

```sh
ssh root@192.168.50.9 '
echo "--- 文件 ---"
ls -l /usr/share/mosdns/route.uc /www/luci-static/resources/view/mosdns/route.js /etc/init.d/mosdns

echo "--- 语法 ---"
ucode -c /usr/share/mosdns/route.uc && echo "route.uc OK"

echo "--- 服务 ---"
/etc/init.d/mosdns status
ps w | grep "[m]osdns start"

echo "--- 配置生成走了后处理吗 ---"
grep -n "route.uc" /etc/init.d/mosdns

echo "--- 生成的配置 ---"
ls -l /var/etc/mosdns*.json

echo "--- 自定义路由生效条数（未配规则时为 0）---"
grep -c route_seq /var/etc/mosdns.json

echo "--- 日志有无报错 ---"
logread -e mosdns | tail -10
'
```

期望结果：

```
route.uc      14451 字节，755，root:root
route.js      4129 字节，644，root:root
init.d        含 ROUTE_SCRIPT=/usr/share/mosdns/route.uc
status        running
mosdns.base.json + mosdns.json 都在
```

`mosdns.base.json` 是新增的标志性文件 —— **只有新版 init.d 才会生成**。它出现就说明新逻辑跑通了。

---

## 7. 浏览器确认

打开 LuCI → **服务 → MosDNS**，侧边栏应该多一页「自定义上游」。

进去配规则：

| 字段 | 说明 |
|---|---|
| 预设规则组 | 从已生成的配置反查 `domain_set` tag，如 `geosite_openai` |
| 自定义域名 | 无前缀 = 后缀匹配；`keyword:xxx` = 关键词；`regexp:xxx` = 正则 |
| 上游 | `tls://8.8.8.8` 这类，多个则并发 |

保存后重新生成配置：`/etc/init.d/mosdns restart`，再验 `grep -c route_seq /var/etc/mosdns.json` 应 > 0。

---

## 回滚

### 只回滚文件（保留配置）

```sh
ssh root@192.168.50.9 '
cp /tmp/init.d-mosdns.bak /etc/init.d/mosdns
cp -r /tmp/mosdns-share.bak/. /usr/share/mosdns/
/etc/init.d/mosdns restart
rm -rf /tmp/luci-*
/etc/init.d/rpcd restart
'
```

### 彻底恢复官方版

```sh
apk fix luci-app-mosdns
```

`/etc/config/mosdns` 和 `/etc/mosdns/` 从未被覆盖，配置不会丢。

---

## 常见坑

| 现象 | 原因 | 处理 |
|---|---|---|
| 页面没变化 | 没清 `/tmp/luci-*` | 清了再刷新，浏览器强刷 Ctrl+Shift+R |
| 菜单不出现 | 没重启 rpcd | `/etc/init.d/rpcd restart` |
| 中文还是英文 | `.po` 覆盖无效，运行时读 `.lmo` | 要中文只能编译 `po2lmo` 后一起打包 |
| `route.uc failed` | `ucode -c` 先查语法 | 日志 `logger -t mosdns` 有详细报错 |
| mosdns 起不来 | 配置引用不存在的插件 | 检查 mosdns 是否为带 patch 的版本 |
| 重启后系统"回出厂" | overlay 挂错了盘（PVE 磁盘枚举延迟） | 见下方 |

### 关于"重启后系统回出厂"

这是 PVE / QEMU 环境的独立问题，与本部署无关。表现为 `dmesg` 里数据盘枚举时间远超 `mount_root`：

```
[  6.0s] mount_root: switching to f2fs overlay
[641.6s] sd ...: [sdb] 1.61 GB
```

系统 6 秒就定好 overlay，数据盘 10 分钟后才出现，于是用了镜像自带的空 overlay。修法是在 PVE 里把该盘的存储迁到 `local-lvm`，让开机即就绪。
