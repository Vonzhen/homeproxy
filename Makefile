# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2022-2023 ImmortalWrt.org

include $(TOPDIR)/rules.mk

LUCI_TITLE:=The modern ImmortalWrt proxy platform for ARM64/AMD64
LUCI_PKGARCH:=all

# 🌟 架构师调整 1：新增 +curl 依赖，保障我们的资产和内核引擎拥有跨国拉取能力
LUCI_DEPENDS:= \
	+sing-box \
	+firewall4 \
	+kmod-nft-tproxy \
	+ucode-mod-digest \
	+curl

PKG_NAME:=luci-app-homeproxy

define Package/luci-app-homeproxy/conffiles
/etc/config/homeproxy
/etc/homeproxy/certs/
/etc/homeproxy/ruleset/
/etc/homeproxy/resources/direct_list.txt
/etc/homeproxy/resources/proxy_list.txt
endef

include $(TOPDIR)/feeds/luci/luci.mk

# 🌟 架构师调整 2：核心提权钩子 (postinst)
# 无论 GitHub 上的文件是什么权限，在 ipk 安装到系统的那一刻，强制赋予它们 0755 可执行权限
define Package/luci-app-homeproxy/postinst
#!/bin/sh
chmod 755 $${IPKG_INSTROOT}/etc/homeproxy/scripts/hp_assets.sh 2>/dev/null
chmod 755 $${IPKG_INSTROOT}/etc/homeproxy/scripts/hp_kernel.sh 2>/dev/null
chmod 755 $${IPKG_INSTROOT}/usr/share/homeproxy/generate_node_groups.uc 2>/dev/null
exit 0
endef

# call BuildPackage - OpenWrt buildroot signature
