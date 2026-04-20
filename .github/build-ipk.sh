#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2023 Tianling Shen <cnsztl@immortalwrt.org>

set -o errexit
set -o pipefail

PKG_MGR="${1:-apk}"
RELEASE_TYPE="${2:-snapshot}"

export PKG_SOURCE_DATE_EPOCH="$(date "+%s")"
export SOURCE_DATE_EPOCH="$PKG_SOURCE_DATE_EPOCH"

BASE_DIR="$(cd "$(dirname $0)"; pwd)"
PKG_DIR="$BASE_DIR/.."

function get_mk_value() {
    awk -F "$1:=" '{print $2}' "$PKG_DIR/Makefile" | xargs
}

PKG_NAME="$(get_mk_value "PKG_NAME")"
if [ "$RELEASE_TYPE" == "release" ]; then
    PKG_VERSION="$(get_mk_value "PKG_VERSION")"
else
    PKG_VERSION="$PKG_SOURCE_DATE_EPOCH~$(git rev-parse --short HEAD)"
fi

TEMP_DIR="$(mktemp -d -p $BASE_DIR)"
TEMP_PKG_DIR="$TEMP_DIR/$PKG_NAME"
mkdir -p "$TEMP_PKG_DIR/lib/upgrade/keep.d/"
mkdir -p "$TEMP_PKG_DIR/usr/lib/lua/luci/i18n/"
mkdir -p "$TEMP_PKG_DIR/www/"
if [ "$PKG_MGR" == "apk" ]; then
    mkdir -p "$TEMP_PKG_DIR/lib/apk/packages/"
else
    mkdir -p "$TEMP_PKG_DIR/CONTROL/"
fi

cp -fpR "$PKG_DIR/htdocs"/* "$TEMP_PKG_DIR/www/"
cp -fpR "$PKG_DIR/root"/* "$TEMP_PKG_DIR/"

cat > "$TEMP_PKG_DIR/lib/upgrade/keep.d/$PKG_NAME" <<-EOF
/etc/homeproxy/certs/
/etc/homeproxy/ruleset/
/etc/homeproxy/resources/direct_list.txt
/etc/homeproxy/resources/proxy_list.txt
EOF

po2lmo "$PKG_DIR/po/zh_Hans/homeproxy.po" "$TEMP_PKG_DIR/usr/lib/lua/luci/i18n/homeproxy.zh-cn.lmo"

if [ "$PKG_MGR" == "apk" ]; then
    find "$TEMP_PKG_DIR" -type f,l -printf '/%P\n' | sort > "$TEMP_PKG_DIR/lib/apk/packages/$PKG_NAME.list"
    echo "/etc/config/homeproxy" >> "$TEMP_PKG_DIR/lib/apk/packages/$PKG_NAME.conffiles"
    cat "$TEMP_PKG_DIR/lib/apk/packages/$PKG_NAME.conffiles" | while IFS= read -r file; do
        [ -f "$TEMP_PKG_DIR/$file" ] || continue
        sha256sum "$TEMP_PKG_DIR/$file" | sed "s,$TEMP_PKG_DIR/,," >> "$TEMP_PKG_DIR/lib/apk/packages/$PKG_NAME.conffiles_static"
    done

    # 🌟 增强版：APK 格式安装后钩子 (post-install)
    echo -e '#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="'"$PKG_NAME"'"
add_group_and_user
default_postinst
[ -n "${IPKG_INSTROOT}" ] || {
    # 1. 修复权限
    chmod 755 /etc/homeproxy/scripts/hp_assets.sh 2>/dev/null
    chmod 755 /etc/homeproxy/scripts/hp_kernel.sh 2>/dev/null
    chmod 755 /etc/homeproxy/scripts/generate_node_groups.uc 2>/dev/null

    # 2. 物理注册 UCI
    if ! uci -q get homeproxy.assets >/dev/null; then
        uci set homeproxy.assets=assets
        uci set homeproxy.assets.auto_update='\''1'\''
        uci set homeproxy.assets.update_time='\''4'\''
        uci commit homeproxy
    fi

    # 3. 初始化计划任务
    mkdir -p /etc/crontabs
    touch /etc/crontabs/root
    sed -i '\''/hp_assets.sh/d'\'' /etc/crontabs/root 2>/dev/null
    if [ "$(uci -q get homeproxy.assets.auto_update)" = "1" ]; then
        TIME=$(uci -q get homeproxy.assets.update_time || echo "4")
        echo "0 $TIME * * * /bin/sh /etc/homeproxy/scripts/hp_assets.sh --update auto > /var/log/hp_assets_cron.log 2>&1" >> /etc/crontabs/root
        echo "" >> /etc/crontabs/root
    fi
    /etc/init.d/cron restart 2>/dev/null || true

    rm -f /tmp/luci-indexcache.*
    rm -rf /tmp/luci-modulecache/
    killall -HUP rpcd 2>/dev/null
    exit 0
}' > "$TEMP_DIR/post-install"

    # 🌟 增强版：APK 格式升级后钩子 (post-upgrade)
    echo -e '#!/bin/sh
export PKG_UPGRADE=1
#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="'"$PKG_NAME"'"
add_group_and_user
default_postinst
[ -n "${IPKG_INSTROOT}" ] || {
    # 1. 修复权限
    chmod 755 /etc/homeproxy/scripts/hp_assets.sh 2>/dev/null
    chmod 755 /etc/homeproxy/scripts/hp_kernel.sh 2>/dev/null
    chmod 755 /etc/homeproxy/scripts/generate_node_groups.uc 2>/dev/null

    # 2. 物理注册 UCI
    if ! uci -q get homeproxy.assets >/dev/null; then
        uci set homeproxy.assets=assets
        uci set homeproxy.assets.auto_update='\''1'\''
        uci set homeproxy.assets.update_time='\''4'\''
        uci commit homeproxy
    fi

    # 3. 初始化计划任务
    mkdir -p /etc/crontabs
    touch /etc/crontabs/root
    sed -i '\''/hp_assets.sh/d'\'' /etc/crontabs/root 2>/dev/null
    if [ "$(uci -q get homeproxy.assets.auto_update)" = "1" ]; then
        TIME=$(uci -q get homeproxy.assets.update_time || echo "4")
        echo "0 $TIME * * * /bin/sh /etc/homeproxy/scripts/hp_assets.sh --update auto > /var/log/hp_assets_cron.log 2>&1" >> /etc/crontabs/root
        echo "" >> /etc/crontabs/root
    fi
    /etc/init.d/cron restart 2>/dev/null || true

    rm -f /tmp/luci-indexcache.*
    rm -rf /tmp/luci-modulecache/
    killall -HUP rpcd 2>/dev/null
    exit 0
}' > "$TEMP_DIR/post-upgrade"

    echo -e '#!/bin/sh
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="'"$PKG_NAME"'"
default_prerm' > "$TEMP_DIR/pre-deinstall"

    # 🌟 新增：在 APK 依赖中加入 curl
    apk mkpkg \
        --info "name:$PKG_NAME" \
        --info "version:$PKG_VERSION" \
        --info "description:The modern ImmortalWrt proxy platform for ARM64/AMD64" \
        --info "arch:all" \
        --info "origin:https://github.com/immortalwrt/homeproxy" \
        --info "url:" \
        --info "maintainer:Tianling Shen <cnsztl@immortalwrt.org>" \
        --info "provides:" \
        --script "post-install:$TEMP_DIR/post-install" \
        --script "post-upgrade:$TEMP_DIR/post-upgrade" \
        --script "pre-deinstall:$TEMP_DIR/pre-deinstall" \
        --info "depends:libc sing-box firewall4 kmod-nft-tproxy ucode-mod-digest curl" \
        --files "$TEMP_PKG_DIR" \
        --output "$TEMP_DIR/${PKG_NAME}_${PKG_VERSION}.apk"

    mv "$TEMP_DIR/${PKG_NAME}_${PKG_VERSION}.apk" "$BASE_DIR/${PKG_NAME}_${PKG_VERSION}_all.apk"
else
    mkdir -p "$TEMP_PKG_DIR/CONTROL/"

    # 🌟 新增：在 IPK 依赖中加入 curl
    cat > "$TEMP_PKG_DIR/CONTROL/control" <<-EOF
Package: $PKG_NAME
Version: $PKG_VERSION
Depends: libc, sing-box, firewall4, kmod-nft-tproxy, ucode-mod-digest, curl
Source: https://github.com/immortalwrt/homeproxy
SourceName: $PKG_NAME
Section: luci
SourceDateEpoch: $PKG_SOURCE_DATE_EPOCH
Maintainer: Tianling Shen <cnsztl@immortalwrt.org>
Architecture: all
Installed-Size: TO-BE-FILLED-BY-IPKG-BUILD
Description:  The modern ImmortalWrt proxy platform for ARM64/AMD64
EOF
    chmod 0644 "$TEMP_PKG_DIR/CONTROL/control"

    echo -e "/etc/config/homeproxy" > "$TEMP_PKG_DIR/CONTROL/conffiles"

    echo -e '#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_postinst $0 $@' > "$TEMP_PKG_DIR/CONTROL/postinst"
    chmod 0755 "$TEMP_PKG_DIR/CONTROL/postinst"

    # 🌟 增强版：IPK 格式安装后环境配置 (postinst-pkg)
    echo -e "[ -n \"\${IPKG_INSTROOT}\" ] || {
    # 1. 修复权限
    chmod 755 /etc/homeproxy/scripts/hp_assets.sh 2>/dev/null
    chmod 755 /etc/homeproxy/scripts/hp_kernel.sh 2>/dev/null
    chmod 755 /etc/homeproxy/scripts/generate_node_groups.uc 2>/dev/null

    # 2. 物理注册 UCI
    if ! uci -q get homeproxy.assets >/dev/null; then
        uci set homeproxy.assets=assets
        uci set homeproxy.assets.auto_update='1'
        uci set homeproxy.assets.update_time='4'
        uci commit homeproxy
    fi

    # 3. 初始化计划任务
    mkdir -p /etc/crontabs
    touch /etc/crontabs/root
    sed -i '/hp_assets.sh/d' /etc/crontabs/root 2>/dev/null
    if [ \"\$(uci -q get homeproxy.assets.auto_update)\" = \"1\" ]; then
        TIME=\$(uci -q get homeproxy.assets.update_time || echo \"4\")
        echo \"0 \$TIME * * * /bin/sh /etc/homeproxy/scripts/hp_assets.sh --update auto > /var/log/hp_assets_cron.log 2>&1\" >> /etc/crontabs/root
        echo \"\" >> /etc/crontabs/root
    fi
    /etc/init.d/cron restart 2>/dev/null || true

    # 🌟 修复后的安全执行逻辑
    [ -f \"/etc/uci-defaults/$PKG_NAME\" ] && { sh \"/etc/uci-defaults/$PKG_NAME\" && rm -f \"/etc/uci-defaults/$PKG_NAME\"; }
    
    rm -f /tmp/luci-indexcache
    rm -rf /tmp/luci-modulecache/
    exit 0
}" > "$TEMP_PKG_DIR/CONTROL/postinst-pkg"
    chmod 0755 "$TEMP_PKG_DIR/CONTROL/postinst-pkg"

    echo -e '#!/bin/sh
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_prerm $0 $@' > "$TEMP_PKG_DIR/CONTROL/prerm"
    chmod 0755 "$TEMP_PKG_DIR/CONTROL/prerm"

    ipkg-build -m "" "$TEMP_PKG_DIR" "$TEMP_DIR"

    mv "$TEMP_DIR/${PKG_NAME}_${PKG_VERSION}_all.ipk" "$BASE_DIR/${PKG_NAME}_${PKG_VERSION}_all.ipk"
fi

rm -rf "$TEMP_DIR"
