#!/bin/sh
# 打包 luci-app-mosdns 的「文件层」产物，用于覆盖到已装官方版的路由器上。
#
# 为什么不走 ipk/apk：
#   本包 LUCI_PKGARCH:=all，是纯文件包，没有 Go 二进制。走包管理器意味着
#   拉整个 OpenWrt SDK 并连带编译 mosdns / geo2txt（Go 交叉编译，每个架构
#   5~10 分钟）。那才是 CI 慢的根源，和前端代码毫无关系。
#
# 为什么排除下面两个路径（重要）：
#   root/etc/config/mosdns        你的 UCI 配置，覆盖 = 所有设置重置
#   root/etc/mosdns/rule/*.txt    你的黑白名单 / hosts / 重定向规则，覆盖 = 清空
# 这两个是 conffiles，本来就该由用户自己保管。
#
# 用法：
#   ./tools/pack-luci.sh              # 输出到 /tmp/luci-app-mosdns-overlay.tar.gz
#   ./tools/pack-luci.sh ./out.tar.gz # 指定输出路径

set -e

# 切到仓库根目录（脚本可能在任意位置被调用）
cd "$(dirname "$0")/.."

SRC=luci-app-mosdns
OUT=${1:-/tmp/luci-app-mosdns-overlay.tar.gz}

[ -d "$SRC/htdocs" ] || { echo "错误：找不到 $SRC/htdocs，确认在仓库根目录" >&2; exit 1; }

rm -f "$OUT"

# --exclude 用相对 SRC 的路径。同时写不带 /* 和带 /* 两种，
# 兼容不同 tar 实现对「目录本身」和「目录下内容」的匹配差异。
tar czf "$OUT" \
	--exclude 'root/etc/config' \
	--exclude 'root/etc/config/*' \
	--exclude 'root/etc/mosdns/rule' \
	--exclude 'root/etc/mosdns/rule/*' \
	-C "$SRC" htdocs root

SIZE=$(du -h "$OUT" | awk '{print $1}')
NAME=$(basename "$OUT")

echo "已生成: $OUT ($SIZE)"
echo
echo "── 校验排除是否生效 ──"
if tar tzf "$OUT" | grep -qE '^root/etc/(config|mosdns/rule)'; then
	echo "⚠ 警告：tar 里仍有 config/rule，--exclude 没生效，别往路由器上解压！"
	tar tzf "$OUT" | grep -E '^root/etc/(config|mosdns/rule)'
	exit 1
fi
echo "✓ 已排除 /etc/config/mosdns 与 /etc/mosdns/rule/"
echo
echo "── 路由器上执行 ──"
echo "  cd / && tar xzf /tmp/$NAME"
echo "  /etc/init.d/mosdns restart          # init.d / ucode 后端改动需要"
echo "  rm -rf /tmp/luci-*                  # 清 LuCI 页面缓存"
echo "  /etc/init.d/rpcd restart            # menu.d / acl.d 改动需要"
echo
echo "注：po/ 下的翻译不会生效。运行时读的是编译好的 .lmo，.po 覆盖没用。"
