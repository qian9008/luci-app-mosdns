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

# ── 打包：用 Python 的 tarfile，不用系统 tar ────────────────────────────
#
# 为什么不能用 `tar -C "$TMP" .`：
#   mktemp -d 建的临时目录是 drwx------ (0700)，属主是当前用户（macOS 上 501:20,
#   即 qian:staff）。`tar -C dir .` 会把目录本身打成一条 `./` 条目，带着这个
#   0700 + 501:20 的属性进包。
#
#   路由器的 tar 以 root 身份解压时，会忠实恢复这条条目：
#     chmod 700 /  +  chown 501:20 /
#   而 `/` 是 overlayfs 合并视图，这个改动落到 upperdir 根，即
#   /overlay/upper 变成 drwx------ 501:dialout（Linux 上 gid 20 = dialout）。
#
#   后果：下次启动 overlay 挂好后 `/` 直接继承 0700 501:dialout，所有非 root
#   进程（uhttpd、dnsmasq、dropbear）无法遍历根目录，系统表现为"坏了"。
#
#   Python 版本做了三件事：
#     1. 只打 www/etc/usr 三个顶层目录，绝不产生 `./` 条目
#     2. 所有条目 uid/gid 强制 0，属主 root:root（属主对了就不再依赖解压端参数）
#     3. 目录统一 755，文件按可执行位给 755/644（防止源文件权限被 macOS 带歪）
#
#   macOS 的 ._xxx / .DS_Store 一并跳过。
python3 - "$TMP" "$OUT" <<'PYEOF'
import os, sys, tarfile

tmp, out = sys.argv[1], sys.argv[2]
TOPS = ("www", "etc", "usr")   # 只打这三个顶层，绝不包含 `.` 本身
SKIP = {".DS_Store"}
SKIP_PREFIX = "._"             # macOS 扩展属性旁文件

def norm(ti, path, isdir):
    """强制 root:root，并按类型规范权限位"""
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = "root"
    if isdir:
        ti.mode = 0o755
    elif ti.isfile():
        ti.mode = 0o755 if (os.stat(path).st_mode & 0o111) else 0o644
    # 符号链接保持原样（gettarinfo 已填好 linkname）

with tarfile.open(out, "w:gz", compresslevel=9) as tf:
    for top in TOPS:
        root = os.path.join(tmp, top)
        if not os.path.isdir(root):
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            # 原地过滤，os.walk 才不会进 macOS 垃圾目录
            dirnames[:] = sorted(d for d in dirnames if not d.startswith(SKIP_PREFIX))
            ti = tf.gettarinfo(dirpath, os.path.relpath(dirpath, tmp))
            norm(ti, dirpath, True)
            tf.addfile(ti)
            for name in sorted(filenames):
                if name in SKIP or name.startswith(SKIP_PREFIX):
                    continue
                full = os.path.join(dirpath, name)
                ti = tf.gettarinfo(full, os.path.relpath(full, tmp))
                norm(ti, full, False)
                if ti.isfile():
                    with open(full, "rb") as f:
                        tf.addfile(ti, f)
                else:
                    tf.addfile(ti)   # 符号链接、设备文件等只写头
PYEOF

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
# 注意：Python 打包时 arcname 是 "www/..." 而不是 "./www/..."，这里不能带 ./ 前缀
for p in 'www/luci-static/resources/view/mosdns/basic.js' \
         'www/luci-static/resources/view/mosdns/route.js' \
         'usr/share/mosdns/route.uc' \
         'usr/share/rpcd/ucode/luci.mosdns' \
         'etc/init.d/mosdns' \
         'usr/share/luci/menu.d/luci-app-mosdns.json' \
         'usr/share/rpcd/acl.d/luci-app-mosdns.json'; do
	tar tzf "$OUT" | grep -qxF "$p" && echo "  ✓ $p" || { echo "  ✗ 缺失 $p"; BAD=1; }
done
if tar tzf "$OUT" | grep -qE '^\./etc/(config|mosdns)'; then
	echo "  ✗ 危险：/etc/config 或 /etc/mosdns 混进包里了，别解压到路由器！"
	BAD=1
else
	echo "  ✓ 已排除 /etc/config/mosdns 与 /etc/mosdns/（含 config_custom.yaml、rule/）"
fi

# 必须项：包里不能有 `./` 条目。有的话 `cd / && tar xzf` 会把根目录改成
# 打包机临时目录的 owner/mode（历史事故：/ 变成 0700 501:dialout，系统起不来）
if tar tzf "$OUT" | grep -qx '\./' ; then
	echo "  ✗ 致命：包内含 './' 条目，解压到 / 会覆盖根目录权限！"
	BAD=1
else
	echo "  ✓ 无 './' 条目，不会动根目录属性"
fi

# 必须项：所有条目属主为 root。非 root 属主会导致 /etc/init.d 脚本、
# /usr/share/rpcd 下的 ucode 等文件属主错乱。
# 用 Python 读真实 uid 判断 —— tar tzvf 的列在不同实现下不一致
# （bsdtar 第二列是 link count，GNU tar 第二列才是 owner），不可靠
BADOWN=$(python3 - "$OUT" <<'PYEOF'
import sys, tarfile
bad = set()
with tarfile.open(sys.argv[1]) as tf:
    for m in tf.getmembers():
        if m.uid != 0 or m.gid != 0:
            bad.add("%s:%s" % (m.uid, m.gid))
print(" ".join(sorted(bad)))
PYEOF
)
if [ -n "$BADOWN" ]; then
	echo "  ✗ 致命：包内有非 root 属主: $BADOWN"
	BAD=1
else
	echo "  ✓ 全部条目 uid=0 gid=0 (root:root)"
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
