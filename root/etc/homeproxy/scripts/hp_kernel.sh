#!/bin/sh
# --- [ HomeProxy Native: 内核动力管理引擎 ] ---

export PATH='/usr/sbin:/usr/bin:/sbin:/bin'

GH_API="https://api.github.com/repos/SagerNet/sing-box/releases"
TOKEN=$(uci -q get homeproxy.config.github_token)
AUTH_HEADER=""
[ -n "$TOKEN" ] && AUTH_HEADER="-H \"Authorization: token $TOKEN\""

# ==========================================
# 独立探针模式：只查版本不下载
# ==========================================
if [ "$1" = "--check" ]; then
    LOCAL_VER=$(sing-box version 2>/dev/null | grep 'sing-box version' | awk '{print $3}')
    [ -z "$LOCAL_VER" ] && LOCAL_VER="unknown"
    
    # 抓取最新稳定版
    STABLE_TAG=$(curl -sSL --connect-timeout 10 $AUTH_HEADER "$GH_API/latest" | grep '"tag_name":' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')
    # 抓取最新测试版 (拉取列表第一个)
    BETA_TAG=$(curl -sSL --connect-timeout 10 $AUTH_HEADER "$GH_API" | grep '"tag_name":' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')
    
    # 返回 JSON 给前端
    printf '{"local":"%s","stable":"%s","beta":"%s"}\n' "${LOCAL_VER#v}" "${STABLE_TAG#v}" "${BETA_TAG#v}"
    exit 0
fi

# ==========================================
# 更新与替换模式 (原逻辑)
# ==========================================
C_ERR='\033[31m'; C_OK='\033[32m'; C_WARN='\033[33m'; C_INFO='\033[36m'; C_RESET='\033[0m'
log_info()    { printf "${C_INFO}[INFO]${C_RESET} %s\n" "$1"; }
log_success() { printf "${C_OK}[SUCCESS]${C_RESET} %s\n" "$1"; }
log_warn()    { printf "${C_WARN}[WARN]${C_RESET} %s\n" "$1"; }
log_err()     { printf "${C_ERR}[ERROR]${C_RESET} %s\n" "$1"; }

TRACK="$1"
[ -z "$TRACK" ] && TRACK="stable"

log_info "正在执行环境安全检测..."
TMP_AVAIL=$(df -k /tmp | awk 'NR==2 {print $4}')
if [ -n "$TMP_AVAIL" ] && [ "$TMP_AVAIL" -lt 25000 ]; then
    log_err "/tmp 内存空间不足 25MB，已终止下载防爆内存。"
    exit 1
fi

OWRT_ARCH=$(opkg print-architecture | awk '{print $2}' | grep -vE '^all$|^noarch$' | tail -n 1)
[ -z "$OWRT_ARCH" ] && OWRT_ARCH=$(uname -m)
log_success "硬件识别完成: 匹配 OpenWrt 专属架构 -> [$OWRT_ARCH]"

log_info "正在连接 GitHub 获取 [$TRACK] 轨道版本..."
if [ "$TRACK" = "stable" ]; then
    TAG=$(curl -sSL $AUTH_HEADER "$GH_API/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
else
    TAG=$(curl -sSL $AUTH_HEADER "$GH_API" | grep '"tag_name":' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')
fi

[ -z "$TAG" ] && { log_err "无法获取版本号！请检查网络或 Token。"; exit 1; }
VERSION_NUM=$(echo "$TAG" | sed 's/^v//')
log_success "准备下载版本: $TAG"

DOWNLOAD_URL=$(curl -sSL $AUTH_HEADER "$GH_API/tags/$TAG" | grep '"browser_download_url":' | grep '\.ipk"' | grep "_${OWRT_ARCH}\.ipk" | cut -d '"' -f 4 | head -n 1)
if [ -z "$DOWNLOAD_URL" ] && echo "$OWRT_ARCH" | grep -q "aarch64"; then
    DOWNLOAD_URL=$(curl -sSL $AUTH_HEADER "$GH_API/tags/$TAG" | grep '"browser_download_url":' | grep '\.ipk"' | grep "aarch64_generic" | cut -d '"' -f 4 | head -n 1)
fi

[ -z "$DOWNLOAD_URL" ] && { log_err "未找到匹配 $OWRT_ARCH 架构的 IPK！"; exit 1; }

FILE_NAME=$(basename "$DOWNLOAD_URL")
TMP_DIR="/tmp/hp_kernel_update"
mkdir -p "$TMP_DIR" && cd "$TMP_DIR" || exit 1

log_info "🚀 开始拉取专属内核 ($FILE_NAME)..."
if ! curl -L -# --connect-timeout 15 --max-time 300 -o "$FILE_NAME" "$DOWNLOAD_URL"; then
    log_err "下载失败！"; rm -rf "$TMP_DIR"; exit 1
fi

TARGET_BIN="/usr/bin/sing-box"
[ -f "$TARGET_BIN" ] && cp "$TARGET_BIN" "${TARGET_BIN}.bak"

log_info "启动 opkg 安装..."
if opkg install --force-reinstall --force-overwrite "$FILE_NAME" > opkg_install.log 2>&1; then
    log_success "包管理器已成功更新二进制文件。"
else
    log_warn "包管理器依赖冲突，尝试暴力提取..."
    tar -xzf "$FILE_NAME" 2>/dev/null
    if [ -f data.tar.zst ]; then tar -I zstd -xf data.tar.zst ./usr/bin/sing-box 2>/dev/null;
    elif [ -f data.tar.gz ]; then tar -xzf data.tar.gz ./usr/bin/sing-box 2>/dev/null; fi
    
    if [ -f "./usr/bin/sing-box" ]; then
        cp "./usr/bin/sing-box" "$TARGET_BIN"
        chmod +x "$TARGET_BIN"
        log_info "底层二进制文件提取替换成功。"
    else
        log_err "提取失败，恢复旧内核..."; [ -f "${TARGET_BIN}.bak" ] && mv "${TARGET_BIN}.bak" "$TARGET_BIN"; rm -rf "$TMP_DIR"; exit 1
    fi
fi

# ==========================================
# 5. 防砖测试：架构校验 & 语法校验 (双重防线)
# ==========================================
log_info "🛡️ [防线 1/2] 正在执行新内核架构运行测试..."
if ! "$TARGET_BIN" version > /dev/null 2>&1; then
    log_err "防砖机制触发：新内核无法在当前系统运行 (架构错误或依赖缺失)。"
    log_warn "正在自动恢复稳定版旧内核..."
    [ -f "${TARGET_BIN}.bak" ] && mv "${TARGET_BIN}.bak" "$TARGET_BIN"
    rm -rf "$TMP_DIR"; exit 1
fi
log_success "架构测试通过，二进制工作正常。"

log_info "🛡️ [防线 2/2] 正在校验当前配置与新内核的语法兼容性..."
# 获取 HomeProxy 正在运行的客户端配置路径
HP_CONF_C="/var/run/homeproxy/sing-box-c.json"

if [ -f "$HP_CONF_C" ]; then
    # 让新内核干跑 (check) 当前的配置文件
    if ! "$TARGET_BIN" check -c "$HP_CONF_C" > /dev/null 2>&1; then
        log_err "致命冲突！新版内核不支持当前的 HomeProxy 配置文件格式！"
        log_warn "如果强行升级将导致服务无法启动。正在拦截并回滚至旧版内核..."
        [ -f "${TARGET_BIN}.bak" ] && mv "${TARGET_BIN}.bak" "$TARGET_BIN"
        rm -rf "$TMP_DIR"; exit 1
    fi
    log_success "语法兼容性测试通过！新内核完美适配当前配置。"
else
    log_warn "HomeProxy 服务当前未运行，无法执行语法校验，已跳过。"
fi

log_success "🎉 核心动力热替换成功！"
log_warn "⚠️ 提示: 请在页面手动点击 [保存/应用] 以让 HomeProxy 挂载新内核。"

rm -rf "$TMP_DIR"
exit 0
