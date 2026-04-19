# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2022-2023 ImmortalWrt.org

include $(TOPDIR)/rules.mk

LUCI_TITLE:=The modern ImmortalWrt proxy platform for ARM64/AMD64
LUCI_PKGARCH:=all
LUCI_DEPENDS:=+sing-box +firewall4 +kmod-nft-tproxy +ucode-mod-digest +curl

PKG_NAME:=luci-app-homeproxy

define Package/luci-app-homeproxy/conffiles
/etc/config/homeproxy
/etc/homeproxy/certs/
/etc/homeproxy/ruleset/
/etc/homeproxy/resources/direct_list.txt
/etc/homeproxy/resources/proxy_list.txt
endef

include $(TOPDIR)/feeds/luci/luci.mk

# 🌟 核心改进：直接在标准安装流程中定义权限
define Package/luci-app-homeproxy/install
	# 调用默认安装流程
	$(call Package/luci-app-homeproxy/Default/install,$(1))
	
	# 显式创建目录并安装脚本，使用 $(INSTALL_BIN) 宏（系统会自动赋予 0755）
	$(INSTALL_DIR) $(1)/etc/homeproxy/scripts
	$(INSTALL_BIN) ./root/etc/homeproxy/scripts/hp_assets.sh $(1)/etc/homeproxy/scripts/hp_assets.sh
	$(INSTALL_BIN) ./root/etc/homeproxy/scripts/hp_kernel.sh $(1)/etc/homeproxy/scripts/hp_kernel.sh
	
	$(INSTALL_DIR) $(1)/usr/share/homeproxy
	$(INSTALL_BIN) ./root/etc/homeproxy/scripts/generate_node_groups.uc $(1)/etc/homeproxy/scripts/generate_node_groups.uc
endef

# 🌟 保留 postinst 作为双重保险
define Package/luci-app-homeproxy/postinst
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	chmod 755 /etc/homeproxy/scripts/hp_assets.sh 2>/dev/null
	chmod 755 /etc/homeproxy/scripts/hp_kernel.sh 2>/dev/null
	chmod 755 /etc/homeproxy/scripts/generate_node_groups.uc 2>/dev/null
	# 物理注册 UCI
	if ! uci -q get homeproxy.assets >/dev/null; then
		uci set homeproxy.assets=assets
		uci commit homeproxy
	fi
fi
exit 0
endef

# call BuildPackage - OpenWrt buildroot signature
