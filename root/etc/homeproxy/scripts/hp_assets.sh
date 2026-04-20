#!/bin/sh
# --- [ HomeProxy Native: 规则资产管理引擎 (Assets Engine) ] ---
# 职责：规则集下载、增量更新、断网自愈、TG通知、动态回滚、UCI自动注册

export PATH='/usr/sbin:/usr/bin:/sbin:/bin'
export LD_LIBRARY_PATH='/usr/lib:/lib'

# ==========================================
# 1. 基础配置与 UCI 读取
# ==========================================
HP_CONF_FILE="/etc/config/homeproxy"
RULE_DIR="/etc/homeproxy/ruleset"
TEMP_DIR="/tmp/hp_assets_temp"
BACKUP_DIR="/etc/homeproxy/ruleset_backup"

mkdir -p "$RULE_DIR" "$TEMP_DIR"

# 从 UCI 动态读取前端配置
BASE_URL=$(uci -q get homeproxy.assets.base_url)
[ -z "$BASE_URL" ] && BASE_URL="https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing"
SRC_PRIVATE=$(uci -q get homeproxy.assets.private_repo)

LOCATION_NAME=$(uci -q get homeproxy.assets.location_name)
[ -z "$LOCATION_NAME" ] && LOCATION_NAME="HomeProxy"

TG_BOT_TOKEN=$(uci -q get homeproxy.assets.tg_bot_token)
TG_CHAT_ID=$(uci -q get homeproxy.assets.tg_chat_id)

# ==========================================
# 2. 核心工具库 (Utils)
# ==========================================
C_ERR='\033[31m'; C_OK='\033[32m'; C_WARN='\033[33m'; C_INFO='\033[36m'; C_RESET='\033[0m'
log_info()    { printf "${C_INFO}[INFO]${C_RESET} %s\n" "$1"; }
log_success() { printf "${C_OK}[SUCCESS]${C_RESET} %s\n" "$1"; }
log_warn()    { printf "${C_WARN}[WARN]${C_RESET} %s\n" "$1"; }
log_err()     { printf "${C_ERR}[ERROR]${C_RESET} %s\n" "$1"; }

tg_send() {
    [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ] && return 0
    local msg="$1"
    curl -sk -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
        -d "chat_id=$TG_CHAT_ID" -d "parse_mode=HTML" -d "text=$msg" > /dev/null 2>&1 &
}

safe_download() {
    local url="$1"; local dest="$2"
    if curl -skL --connect-timeout 15 --max-time 30 --retry 2 -f "$url" -o "$dest"; then
        if [ -s "$dest" ] && ! head -n 1 "$dest" | grep -qiE "<!DOCTYPE|<html"; then
            return 0
        fi
    fi
    rm -f "$dest"
    return 1
}

# ==========================================
# 3. 业务逻辑 (Business Logic)
# ==========================================
backup_rules() {
    rm -rf "$BACKUP_DIR" && mkdir -p "$BACKUP_DIR"
    if [ "$(ls -A $RULE_DIR 2>/dev/null)" ]; then
        cp -a "$RULE_DIR"/* "$BACKUP_DIR"/ 2>/dev/null
    fi
}

restore_rules() {
    if [ -d "$BACKUP_DIR" ] && [ "$(ls -A $BACKUP_DIR)" ]; then
        log_warn "正在执行自动回滚 (Restoring Rules)..."
        rm -rf "$RULE_DIR"/*
        cp -a "$BACKUP_DIR"/* "$RULE_DIR"/
        log_success "规则集已成功恢复至上一次的安全快照。"
        return 0
    fi
    log_err "无可用备份，回滚失败。"
    return 1
}

fetch_to_temp() {
    local name="$1"; local temp_path="$2"
    if [ -n "$SRC_PRIVATE" ]; then
        if safe_download "$SRC_PRIVATE/$name.srs" "$temp_path"; then return 0; fi
    fi
    local type="${name%%-*}"
    local core_name="${name#*-}"
    if safe_download "$BASE_URL/geo/$type/$core_name.srs" "$temp_path"; then return 0; fi
    if safe_download "$BASE_URL/geo-lite/$type/$core_name.srs" "$temp_path"; then return 0; fi
    return 1
}

# 🌟 新增：智能 UCI 注册挂载点
auto_inject_uci() {
    local name="$1"
    local file_path="$RULE_DIR/${name}.srs"
    
    # 查重：扫描配置，如果这个路径已经被引用了，就默默跳过，防止重复添加
    if grep -q "option path '$file_path'" "$HP_CONF_FILE" 2>/dev/null; then
        log_info "检测到该规则已在列表中，跳过注册。"
        return 0
    fi

    log_info "正在为您将规则集注册到 HomeProxy 面板..."
    
    # 生成安全的配置节名称（去除非字母数字字符）
    local safe_name=$(echo "$name" | sed 's/[^a-zA-Z0-9]/_/g')
    local sec_id="assets_${safe_name}"
    
    # 清理可能残留的同名旧节点
    uci -q delete homeproxy."$sec_id"
    
    # 写入标准的本地二进制规则集配置
    uci set homeproxy."$sec_id"=ruleset
    uci set homeproxy."$sec_id".label="$name"
    uci set homeproxy."$sec_id".enabled='1'
    uci set homeproxy."$sec_id".type='local'
    uci set homeproxy."$sec_id".format='binary'
    uci set homeproxy."$sec_id".path="$file_path"
    
    uci commit homeproxy
    log_success "🎉 注册完成！该规则现已在 [规则集] 面板中可用。"
}

download_manual() {
    log_info "准备入库，共检测到 $# 个规则任务..."
    backup_rules
    
    for name in "$@"; do
        [ -z "$name" ] && continue
        local final_path="$RULE_DIR/$name.srs"
        local temp_path="$TEMP_DIR/$name.srs.tmp"

        case "$name" in
            geosite-*|geoip-*) ;;
            *) log_err "[$name] 格式错误！跳过该规则。"; continue ;;
        esac
        
        log_info "-------------------------"
        log_info "⏬ 开始下载: $name"
        if fetch_to_temp "$name" "$temp_path" >/dev/null; then
            mv "$temp_path" "$final_path"
            log_success "✅ 入库成功: $name"
            
            # 🌟 触发自动注册钩子
            auto_inject_uci "$name"
            
        else
            log_err "❌ 下载失败: $name (请检查名称或网络)"
        fi
    done
    
    log_info "-------------------------"
    log_info "🏁 所有手动任务执行完毕！"
}

update_all() {
    local mode="$1"
    log_info "开始全量规则集巡检 (模式: $mode)..."
    [ ! -f "$HP_CONF_FILE" ] && { log_err "未找到 HomeProxy 配置文件。"; return 1; }

    backup_rules
    log_info "已建立安全恢复快照，准备拉取更新..."

    local update_count=0; local fail_count=0; local change_log=""
    
    grep "option path" "$HP_CONF_FILE" | grep -E "\.srs|\.json" | awk -F"'" '{print $2}' | sort | uniq > "$TEMP_DIR/list.txt"
    
    while read -r live_path; do
        local filename=$(basename "$live_path")
        local name=$(echo "$filename" | sed 's/\.srs$//; s/\.json$//')
        local temp_file="$TEMP_DIR/$filename"
        
        if fetch_to_temp "$name" "$temp_file" >/dev/null; then
            local new_md5=$(md5sum "$temp_file" | awk '{print $1}')
            if [ -f "$live_path" ]; then
                local old_md5=$(md5sum "$live_path" | awk '{print $1}')
                if [ "$new_md5" != "$old_md5" ]; then
                    update_count=$((update_count + 1))
                    change_log="${change_log}%0A🔹 <b>$name</b> (已更新)"
                    mv "$temp_file" "$live_path"
                    log_success "更新完成: $name"
                else
                    rm -f "$temp_file"
                    log_info "无需更新: $name"
                fi
            else
                update_count=$((update_count + 1))
                change_log="${change_log}%0A✨ <b>$name</b> (新入库)"
                mv "$temp_file" "$live_path"
                log_success "新入库: $name"
            fi
        else
            fail_count=$((fail_count + 1))
            change_log="${change_log}%0A❌ <b>$name</b> (下载失败)"
            log_err "下载失败: $name"
        fi
    done < "$TEMP_DIR/list.txt"

    local status_msg=""
    if [ "$update_count" -gt 0 ]; then
        if [ "$mode" = "auto" ] || [ "$mode" = "manual" ]; then
            log_info "触发 HomeProxy 服务重启以应用新规则..."
            if /etc/init.d/homeproxy restart; then
                status_msg="%0A♻️ 服务重启: <b>成功</b>"
                log_success "服务已成功重启并加载最新规则。"
                log_info "等待 15 秒以便代理网络稳固，准备发送战报..."
                sleep 15
            else
                log_err "重启失败！新规则可能存在致命错误！"
                log_warn "触发紧急回滚机制..."
                restore_rules
                /etc/init.d/homeproxy restart
                status_msg="%0A🛡️ 重启失败，已自动执行<b>安全回滚</b>并恢复服务。"
                log_info "等待 15 秒以便回滚网络稳固，准备发送战报..."
                sleep 15
            fi
        fi
    else
        log_info "所有规则集均是最新版本。"
        status_msg="%0A💤 所有规则集均是最新版本，无需更新。"
    fi

    local msg="📊 <b>[${LOCATION_NAME}] 规则巡检报告</b>%0A"
    msg="${msg}--------------------------------%0A"
    msg="${msg}📦 更新数量: <b>$update_count</b>%0A"
    [ -n "$change_log" ] && msg="${msg}📝 详细清单: ${change_log}%0A"
    msg="${msg}${status_msg}"
    tg_send "$msg"
}

# ==========================================
# 4. 路由入口
# ==========================================
case "$1" in
    --update)   update_all "$2" ;;
    --download) shift; download_manual "$@" ;;
    --restore)  restore_rules; /etc/init.d/homeproxy restart ;;
    *) echo "Usage: $0 {--update [auto/manual] | --download <name1> <name2> | --restore}" ;;
esac
