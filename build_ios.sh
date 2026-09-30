#!/bin/bash
# ============================================================================
# CloakKit v1.1.0 —— Ubuntu/Linux 交叉编译，产出「未签名裸 raw.ipa」
# ----------------------------------------------------------------------------
# host=linux  target=arm64-apple-ios16.0（iPhone + iPad 通用）
#   swiftc/clang 交叉编译 + ld64.lld 链接 + Rust 内核(libcloakkit_core.a)
#   -> arm64 Mach-O（adhoc 签名槽，ldid 嵌入授权）
#   手动搭建 Payload/CloakKit.app（Info.plist / PkgInfo / 全套图标）
#   规范 zip -> raw ipa；设备端由 SideStore 完成签名安装。
#
# 蓝本：ClipboardHistory-deploy/build_linux.sh（本机已验证的 iOS 交叉输出链）
# 关键修复（缺一不可）：
#   1) resource-dir 用绝对路径，删除与 iOS SDK 冲突的 Linux 模块
#   2) 补 Dispatch.apinotes / os.apinotes
#   3) 用名为 ld 的包装脚本转调 ld64.lld（GNU ld 不认 -dynamic）
#   4) -Xlinker -adhoc_codesign 写签名槽（否则 SideStore 重签失败）
#   5) 链接显式传 -platform_version ios 16.0.0 16.4
#   6) -Xcc -fmodules-cache-path=PATH 必须是单参数（= 形式）
#   7) Rust 静态库需额外 -framework CoreFoundation / -liconv / -lm
# ============================================================================
set -euo pipefail

APP_NAME="CloakKit"
BUNDLE_ID="com.hi1781.cloakkit"
MARK_VER="1.4.0"; CUR_VER="5"
DEPLOY="16.0"; SDK_VER="16.4"
TARGET="arm64-apple-ios${DEPLOY}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="${ROOT}/build-ios"
APP="${BUILD}/Payload/${APP_NAME}.app"
OUT_IPA="${BUILD}/CloakKit-${MARK_VER}-raw-unsigned.ipa"
CORE_LIB="${ROOT}/cloakkit-core/target/aarch64-apple-ios/release/libcloakkit_core.a"

SWIFT_TOOLCHAIN="${SWIFT_TOOLCHAIN:-}"
IOS_SDK="${IOS_SDK:-}"
for c in "$SWIFT_TOOLCHAIN" "${ROOT}/../toolchain/swift-5.8-RELEASE-ubuntu22.04/usr" \
         /home/user/.doubao/agent_mode/workspace/toolchain/swift-5.8-RELEASE-ubuntu22.04/usr; do
    [[ -z "$c" ]] && continue
    if [[ -x "$c/bin/swiftc" ]]; then SWIFT_TOOLCHAIN="$c"; break; fi
done
for s in "$IOS_SDK" "${ROOT}/../toolchain/iPhoneOS16.4.sdk" \
         /home/user/.doubao/agent_mode/workspace/toolchain/iPhoneOS16.4.sdk; do
    [[ -z "$s" ]] && continue
    if [[ -d "$s/usr/include" ]]; then IOS_SDK="$s"; break; fi
done
[[ -x "${SWIFT_TOOLCHAIN}/bin/swiftc" ]] || { echo "❌ 未找到 swiftc"; exit 1; }
[[ -d "${IOS_SDK}" ]] || { echo "❌ 未找到 iOS SDK"; exit 1; }
[[ -f "${CORE_LIB}" ]] || { echo "❌ 未找到 Rust 静态库 libcloakkit_core.a，请先编译"; exit 1; }
SWIFTC="${SWIFT_TOOLCHAIN}/bin/swiftc"
echo "swiftc: ${SWIFTC}"
echo "SDK:    ${IOS_SDK}"
echo "内核:   ${CORE_LIB} ($(du -h "${CORE_LIB}" | cut -f1))"

# ---- ldid：嵌入 entitlements 的 ad-hoc 签名 ----
LDID="${LDID:-}"
for c in "$LDID" "${ROOT}/../toolchain/bin/ldid" \
         /home/user/.doubao/agent_mode/workspace/toolchain/bin/ldid "$(command -v ldid)"; do
    [[ -z "$c" ]] && continue
    if [[ -x "$c" ]]; then LDID="$c"; break; fi
done
[[ -n "$LDID" && -x "$LDID" ]] || { echo "❌ 未找到 ldid"; exit 1; }
echo "ldid:   ${LDID}"

# ---- ld 包装：swiftc 链接默认调 /usr/bin/ld(GNU)，转调 ld64.lld ----
LINKBIN="${BUILD}/linkbin"; mkdir -p "$LINKBIN"
cat > "$LINKBIN/ld" <<EOF
#!/bin/bash
exec "${SWIFT_TOOLCHAIN}/bin/ld64.lld" "\$@"
EOF
chmod +x "$LINKBIN/ld"
export PATH="${LINKBIN}:${SWIFT_TOOLCHAIN}/bin:$PATH"

# ---- resource-dir（绝对路径）----
RES="$(mkdir -p "${BUILD}/resource-dir" && cd "${BUILD}/resource-dir" && pwd)"
if [[ ! -f "${RES}/.prepared" ]]; then
  rm -rf "${RES:?}"/*
  cp -R "${SWIFT_TOOLCHAIN}/lib/swift/"*.swift "${RES}/" 2>/dev/null || true
  cp -R "${SWIFT_TOOLCHAIN}/lib/swift/linux" "${RES}/" 2>/dev/null || true
  rm -rf "${RES}/dispatch" "${RES}/os" "${RES}/CoreFoundation" "${RES}/Block" "${RES}/linux" 2>/dev/null || true
  CLANG_VER="$(ls "${SWIFT_TOOLCHAIN}/lib/clang" | head -1)"
  mkdir -p "${RES}/clang"
  cp -R "${SWIFT_TOOLCHAIN}/lib/clang/${CLANG_VER}/include" "${RES}/clang/" 2>/dev/null || true
  mkdir -p "${RES}/apinotes"
  for ap in Dispatch.apinotes os.apinotes; do
    for cand in "${ROOT}/../toolchain/swift-apinotes/apinotes/$ap" \
                "/home/user/.doubao/agent_mode/workspace/toolchain/swift-apinotes/apinotes/$ap"; do
      [[ -f "$cand" ]] && cp "$cand" "${RES}/apinotes/" && break
    done
  done
  touch "${RES}/.prepared"
fi

COMMON=(-target "$TARGET" -sdk "$IOS_SDK" -resource-dir "$RES" -O -parse-as-library
        -Xcc -fmodules-cache-path="${BUILD}/mcapp"
        -I "${ROOT}/CloakKitApp/include")
# 写 ad-hoc 签名槽 + 平台版本 + Rust 静态库所需系统库
LINKV=(-Xlinker -adhoc_codesign \
       -Xlinker -platform_version -Xlinker ios -Xlinker "${DEPLOY}.0" -Xlinker "$SDK_VER" \
       -Xlinker -framework -Xlinker CoreFoundation \
       -Xlinker -liconv -Xlinker -lm)

# 桥接头（把 cloakkit_core.h 暴露给 Swift）
BRIDGE_HEADER="${ROOT}/CloakKitApp/CloakKitApp-Bridging-Header.h"

# ---- 源码清单（App/*.swift + 根目录 *.swift）----
mapfile -t APPSRC < <(find "${ROOT}/CloakKitApp" -name '*.swift' | sort)

mkdir -p "${APP}"

echo "==> [1/4] 编译并链接 CloakKit（arm64 iOS）"
"$SWIFTC" "${COMMON[@]}" -module-name CloakKit -emit-executable \
  -import-objc-header "${BRIDGE_HEADER}" \
  "${LINKV[@]}" \
  -o "${APP}/CloakKit" \
  "${CORE_LIB}" "${APPSRC[@]}"
echo "  ✓ 主可执行文件产出"

echo "==> [2/4] ldid 嵌入 entitlements（adhoc 签名）"
cat > "${BUILD}/CloakKit.entitlements" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>get-task-allow</key><true/>
</dict></plist>
ENT
"$LDID" -S"${BUILD}/CloakKit.entitlements" "${APP}/CloakKit"
echo "  ✓ 已签名（ldid adhoc + get-task-allow）"

echo "==> [3/4] 组装 Info.plist / PkgInfo / 图标"
cat > "${BUILD}/Info.plist.tmpl" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
	<key>CFBundleDisplayName</key><string>CloakKit</string>
	<key>CFBundleExecutable</key><string>\$(EXECUTABLE_NAME)</string>
	<key>CFBundleIdentifier</key><string>\$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>\$(PRODUCT_NAME)</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>\$(MARKETING_VERSION)</string>
	<key>CFBundleVersion</key><string>\$(CURRENT_PROJECT_VERSION)</string>
	<key>LSRequiresIPhoneOS</key><true/>
	<key>UILaunchScreen</key><dict/>
	<key>UIRequiredDeviceCapabilities</key><array><string>arm64</string></array>
	<key>UISupportedInterfaceOrientations</key>
	<array><string>UIInterfaceOrientationPortrait</string></array>
	<key>UISupportedInterfaceOrientations~ipad</key>
	<array>
		<string>UIInterfaceOrientationPortrait</string>
		<string>UIInterfaceOrientationPortraitUpsideDown</string>
		<string>UIInterfaceOrientationLandscapeLeft</string>
		<string>UIInterfaceOrientationLandscapeRight</string>
	</array>
	<key>CFBundleIcons</key><dict>
		<key>CFBundlePrimaryIcon</key><dict>
			<key>CFBundleIconFiles</key><array>
				<string>Icon-60@2x</string><string>Icon-60@3x</string>
				<string>Icon-76~ipad</string><string>Icon-76@2x~ipad</string>
			</array>
		</dict>
	</dict>
	<key>CFBundleIcons~ipad</key><dict>
		<key>CFBundlePrimaryIcon</key><dict>
			<key>CFBundleIconFiles</key><array>
				<string>Icon-60@2x</string><string>Icon-60@3x</string>
				<string>Icon-76~ipad</string><string>Icon-76@2x~ipad</string>
			</array>
		</dict>
	</dict>
</dict></plist>
PLIST
sed -e "s/\\\$(EXECUTABLE_NAME)/CloakKit/g" -e "s/\\\$(PRODUCT_MODULE_NAME)/CloakKit/g" \
    -e "s/\\\$(PRODUCT_NAME)/CloakKit/g" -e "s/\\\$(PRODUCT_BUNDLE_IDENTIFIER)/${BUNDLE_ID}/g" \
    -e "s/\\\$(MARKETING_VERSION)/${MARK_VER}/g" -e "s/\\\$(CURRENT_PROJECT_VERSION)/${CUR_VER}/g" \
    "${BUILD}/Info.plist.tmpl" > "${APP}/Info.plist"
printf 'APPL????' > "${APP}/PkgInfo"

# 补齐 installd 校验所需标准键
python3 - "${DEPLOY}" "${SDK_VER}" "${APP}/Info.plist" <<'PY'
import sys, plistlib
minos, sdkver, path = sys.argv[1], sys.argv[2], sys.argv[3]
std = {
    "MinimumOSVersion": minos,
    "CFBundleSupportedPlatforms": ["iPhoneOS"],
    "DTPlatformName": "iphoneos",
    "DTPlatformVersion": sdkver,
    "DTSDKName": f"iphoneos{sdkver}",
    "DTCompiler": "com.apple.compilers.llvm.clang.1_0",
}
with open(path, "rb") as f: pl = plistlib.load(f)
for k, v in std.items(): pl.setdefault(k, v)
with open(path, "wb") as f: plistlib.dump(pl, f, fmt=plistlib.FMT_XML)
print("  ✓ Info.plist 补齐标准键")
PY

# 生成散件图标
python3 - "${APP}" <<'PY'
import sys
from PIL import Image, ImageDraw, ImageFont
app = sys.argv[1]
# 深蓝渐变底 + 白色"C"圆角标识
S = 1024
im = Image.new("RGB", (S, S), "#0B1026")
d = ImageDraw.Draw(im)
top, bot = (16, 26, 60), (64, 160, 255)
for y in range(S):
    t = y / S
    r = int(top[0] + (bot[0]-top[0])*t); g = int(top[1] + (bot[1]-top[1])*t); b = int(top[2] + (bot[2]-top[2])*t)
    d.line([(0, y), (S, y)], fill=(r, g, b))
# 圆角遮罩
mask = Image.new("L", (S, S), 0)
dm = ImageDraw.Draw(mask)
dm.rounded_rectangle([0, 0, S, S], radius=224, fill=255)
# 白色"C"形圆环（拨号式，示意"下载/侧载"）
d.ellipse([236, 236, 788, 788], outline=(255, 255, 255), width=72)
d.ellipse([360, 360, 664, 664], outline=(16, 26, 60), width=44)
# 向内箭头缺口
out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
out.paste(im, (0, 0), mask)
out = out.convert("RGB")
specs = [("Icon-20","@2x",40),("Icon-20","@3x",60),("Icon-20~ipad","",20),("Icon-20@2x~ipad","",40),
("Icon-29","@2x",58),("Icon-29","@3x",87),("Icon-29~ipad","",29),("Icon-29@2x~ipad","",58),
("Icon-40","@2x",80),("Icon-40","@3x",120),("Icon-40~ipad","",40),("Icon-40@2x~ipad","",80),
("Icon-60","@2x",120),("Icon-60","@3x",180),("Icon-76~ipad","",76),("Icon-76@2x~ipad","",152),
("Icon-83.5@2x~ipad","",167),("Icon-1024","",1024)]
for base, suf, size in specs:
    out.resize((size, size), Image.LANCZOS).save(f"{app}/{base}{suf}.png", "PNG", optimize=True)
print("  ✓ 全套图标生成")
PY

echo "==> [4/4] Mach-O 校验"
python3 - "${APP}" <<'PY'
import struct, sys, os
app = sys.argv[1]
b = "CloakKit"
d = open(os.path.join(app, b), "rb").read()
magic, cput, sub, ft, n = struct.unpack('<IiiII', d[:20])
assert magic == 0xfeedfacf and cput == 0x0100000c, b + " 非 arm64 Mach-O64"
assert ft == 2, f"filetype={ft}，期望 MH_EXECUTE(2)"
off = 32; plat = None; sig = None
for _ in range(n):
    cmd, cs = struct.unpack('<II', d[off:off+8])
    if cmd == 0x32: plat = struct.unpack('<I', d[off+8:off+12])[0]
    if cmd == 0x1d: sig = struct.unpack('<II', d[off+8:off+16])
    off += cs
assert plat == 2, b + " 平台非 iOS"
assert sig and sig[1] > 0, b + " 缺少 LC_CODE_SIGNATURE 签名槽"
so, ss = sig
assert struct.unpack('>I', d[so:so+4])[0] == 0xfade0cc0, "签名 SuperBlob magic 异常"
print(f"  ✓ {b} arm64/iOS/MH_EXECUTE + ad-hoc签名槽({ss}B)")
print("Mach-O 全部通过")
PY

# ---- 规范化打包裸 IPA ----
echo "==> 规范化打包 IPA"
rm -f "$OUT_IPA"
python3 - "$BUILD" "$OUT_IPA" <<'PY'
import sys, os, zipfile
build, out = sys.argv[1], sys.argv[2]
root = os.path.join(build, "Payload")
exec_names = {"CloakKit"}
fixed = (2024, 1, 1, 0, 0, 0)

def add_dir(zf, arc):
    zi = zipfile.ZipInfo(arc + "/", fixed)
    zi.create_system = 3
    zi.external_attr = (0o40755 << 16) | 0o040000
    zi.compress_type = zipfile.ZIP_STORED
    zf.writestr(zi, b"")

entries = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames.sort(); filenames.sort()
    rel = os.path.relpath(dirpath, build)
    if rel != ".":
        entries.append(("dir", rel, None))
    for fn in filenames:
        full = os.path.join(dirpath, fn)
        entries.append(("file", os.path.relpath(full, build), full))
entries.sort(key=lambda e: (e[1].count("/"), e[1]))
with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9, allowZip64=False) as zf:
    seen = set()
    for kind, arc, full in entries:
        parts = arc.split("/")[:-1]
        for i in range(len(parts)):
            d = "/".join(parts[:i+1])
            if d not in seen: add_dir(zf, d); seen.add(d)
        if kind == "dir":
            if arc not in seen: add_dir(zf, arc); seen.add(arc)
            continue
        zi = zipfile.ZipInfo(arc, fixed)
        zi.create_system = 3
        base = os.path.basename(arc)
        mode = 0o755 if base in exec_names else 0o644
        zi.external_attr = (mode << 16) | 0o100000
        zi.compress_type = zipfile.ZIP_DEFLATED
        with open(full, "rb") as f:
            zf.writestr(zi, f.read(), compress_type=zipfile.ZIP_DEFLATED)
with zipfile.ZipFile(out) as z:
    bad = z.testzip(); assert bad is None, f"坏条目 {bad}"
    n = len(z.namelist())
raw = open(out, "rb").read()
assert raw.rfind(b"PK\x05\x06") == len(raw) - 22, "EOCD 不在末尾"
assert b"PK\x06\x06" not in raw, "不应含 zip64"
print(f"  规范化 zip：{n} 条目，EOCD 在末尾，无 zip64")
PY
echo "✅ 完成: ${OUT_IPA}"
ls -lh "$OUT_IPA"
shasum -a 256 "$OUT_IPA" | awk '{print "SHA256:",$1}'
