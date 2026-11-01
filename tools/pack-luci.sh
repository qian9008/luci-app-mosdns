#!/bin/sh
# 打包 luci-app-mosdns 的「文件层」产物，用于覆盖到已装官方版的路由器上。
#
# 为什么不走 ipk/apk：
#   本包 LUCI_PKGARCH:=all，是纯文件包，没有 Go 二进制。走包管理器意味着
#   拉整个 OpenWrt SDK 并连带编译 mosdns / geo2txt（Go 交叉编译，每个架构
#   5~10 分钟）。那才是 CI 慢的根源，和前端代码毫无关系。
#
# 目录映射（关键，别搞错）：
#   htdocs/*  →  /www/*      ← luci.mk 的安装规则，不是 /htdocs/
#   root/*    →  /*          ← root/ 里的 etc、usr 直接对根目录
#
# 排除项（覆盖会破坏用户数据）：
#   etc/config/mosdns         UCI 配置，覆盖 = 所有设置重置
#   etc/mosdns/rule/*.txt     黑白名单 / hosts / 重定向规则，覆盖 = 清空
#
# 用法：
#   ./tools/pack-luci.sh               # 输出 ./dist/luci-app-mosdns-overlay.tar.gz
#   ./tools/pack-luci.sh ./out.tar.gz  # 指定输出
#
# 默认落在项目内 dist/ 而不是 /tmp：macOS 的 /tmp 其实是 /private/tmp 的符号链接，
# 用 Finder 或别的工具找 /tmp 经常扑空。dist/ 已在 .gitignore 里。

set -e

cd "$(dirname "$0")/.."

SRC=luci-app-mosdns
OUT=${1:-dist/luci-app-mosdns-overlay.tar.gz}

[ -d "$SRC/htdocs" ] || { echo "错误：找不到 $SRC/htdocs，确认在仓库根目录" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 按 OpenWrt 根文件系统的布局重建目录树，之后整体 tar 就能直接解压到 /
mkdir -p "$TMP/www"
cp -R "$SRC/htdocs/." "$TMP/www/"
cp -R "$SRC/root/."   "$TMP/"

# 会覆盖用户数据的路径，删掉
#   etc/config      → UCI 配置
#   etc/mosdns      → config_custom.yaml + rule/*.txt，全是用户自己的东西
# 这两个对应 Makefile 里的 conffiles，本来就该由用户保管
rm -rf "$TMP/etc/config" "$TMP/etc/mosdns"

# 校验：临时树里不该再有 config / mosdns 目录
if [ -e "$TMP/etc/config" ] || [ -e "$TMP/etc/mosdns" ]; then
	echo "错误：排除失败，仍有 $TMP/etc/config 或 $TMP/etc/mosdns" >&2
	exit 1
fi

rm -f "$OUT"

# COPYFILE_DISABLE=1：阻止 macOS 把扩展属性写成 ._xxx 垃圾文件
# --no-xattr/--no-acl 只有 bsdtar 支持，GNU tar 会报错，所以加容错重试
COPYFILE_DISABLE=1 tar -czf "$OUT" --no-xattr --no-acl -C "$TMP" . 2>/dev/null || \
	COPYFILE_DISABLE=1 tar -czf "$OUT" -C "$TMP" .

SIZE=$(du -h "$OUT" | awk '{print $1}')
ABS=$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")
NAME=$(basename "$OUT")

echo "已生成: $ABS ($SIZE)"
echo
echo "── 包内顶层目录 ──"
tar tzf "$OUT" | awk -F/ 'NF>=3 {print "/" $2}' | sort -u | sed 's/^/  /'

echo
echo "── 自检 ──"
BAD=0
for p in './www/luci-static/resources/view/mosdns/basic.js' \
         './www/luci-static/resources/view/mosdns/route.js' \
         './usr/share/mosdns/route.uc' \
         './usr/share/rpcd/ucode/luci.mosdns' \
         './etc/init.d/mosdns' \
         './usr/share/luci/menu.d/luci-app-mosdns.json' \
         './usr/share/rpcd/acl.d/luci-app-mosdns.json'; do
	tar tzf "$OUT" | grep -qxF "$p" && echo "  ✓ $p" || { echo "  ✗ 缺失 $p"; BAD=1; }
done
if tar tzf "$OUT" | grep -qE '^\./etc/(config|mosdns)'; then
	echo "  ✗ 危险：/etc/config 或 /etc/mosdns 混进包里了，别解压到路由器！"
	BAD=1
else
	echo "  ✓ 已排除 /etc/config/mosdns 与 /etc/mosdns/（含 config_custom.yaml、rule/）"
fi
[ "$BAD" -eq 0 ] || exit 1

echo
echo "── 路由器上执行 ──"
echo "  cd / && tar xzf /tmp/$NAME"
echo "  /etc/init.d/mosdns restart"
echo "  rm -rf /tmp/luci-*"
echo "  /etc/init.d/rpcd restart"
echo
echo "注：po/ 下的翻译不会生效。运行时读的是编译好的 .lmo，.po 覆盖没用。"
