#!/bin/sh
# ---------------------------------------------------------
# HomeProxy 幽灵监控与 Telegram 统一告警脚本 (v2.0 全局版)
# 用法: hp_notifier.sh [任务类型] [状态] [具体消息]
# 示例: hp_notifier.sh "subscription" "success" "更新成功"
# ---------------------------------------------------------

TASK_TYPE=$1
STATUS=$2
export MSG_TEXT="$3"

# 1. 从全局(config)读取设置
export TG_ENABLED=$(uci -q get homeproxy.config.tg_notify_enabled)
export TG_MODE=$(uci -q get homeproxy.config.tg_notify_mode)
export TG_TOKEN=$(uci -q get homeproxy.config.tg_token)
export TG_CHAT_ID=$(uci -q get homeproxy.config.tg_chat_id)
export LOCATION_NAME=$(uci -q get homeproxy.config.location_name)
[ -z "$LOCATION_NAME" ] && LOCATION_NAME="HomeProxy"

# 如果没开启或信息不全，直接静默退出
if [ "$TG_ENABLED" != "1" ] || [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
    exit 0
fi

# 2. 核心监控逻辑 (仅对订阅更新的成功状态进行 20 秒安全校验)
if [ "$TASK_TYPE" = "subscription" ] && [ "$STATUS" = "success" ]; then
    sleep 20
    if ! pgrep -f "sing-box" > /dev/null; then
        if [ -f /tmp/homeproxy.bak ]; then
            cp /tmp/homeproxy.bak /etc/config/homeproxy
            /etc/init.d/homeproxy restart
        fi
        STATUS="fail"
        export MSG_TEXT="🚨 <b>严重告警</b>：节点更新后服务崩溃。<br>🛡️ <b>已自动物理回滚</b>至健康配置并重启！"
    else
        export MSG_TEXT="✅ <b>订阅更新成功</b><br>节点已拉取重组完毕，当前服务平稳运行中。"
    fi
elif [ "$STATUS" = "fail" ]; then
    export MSG_TEXT="⚠️ <b>任务中断或异常</b><br>原因：${MSG_TEXT}"
fi

# 3. 业务标题定制 (统一冠以路由器名称)
TITLE_PREFIX="[${LOCATION_NAME}]"
if [ "$TASK_TYPE" = "subscription" ]; then TITLE_PREFIX="${TITLE_PREFIX} 📡 <b>订阅管理</b>"; fi
if [ "$TASK_TYPE" = "ruleset" ]; then TITLE_PREFIX="${TITLE_PREFIX} 🗂️ <b>规则资产</b>"; fi
if [ "$TASK_TYPE" = "kernel" ]; then TITLE_PREFIX="${TITLE_PREFIX} 🚀 <b>内核管理</b>"; fi

# 4. 根据模式决定是否静默
if [ "$STATUS" = "success" ] && [ "$TG_MODE" = "fail_only" ]; then
    exit 0
fi

# 组合最终消息
export MSG_TEXT="${TITLE_PREFIX}<br>${MSG_TEXT}"

# 5. 通过 UCODE 安全构建 JSON 并发送 TG 消息 (免疫特殊字符)
ucode -e '
    let fs = require("fs");
    
    let token = getenv("TG_TOKEN");
    let chat_id = getenv("TG_CHAT_ID");
    let text = getenv("MSG_TEXT");
    
    // 把 <br> 换成 Telegram 支持的换行符
    text = replace(text, /<br>/g, "\n");
    
    let url = "https://api.telegram.org/bot" + token + "/sendMessage";
    let payload = { 
        chat_id: chat_id, 
        text: text, 
        parse_mode: "HTML",
        disable_web_page_preview: true
    };
    
    // 生成临时 payload 文件，绝对防止 Shell 逃逸
    let tmp_file = "/tmp/tg_payload_" + time() + ".json";
    let f = fs.open(tmp_file, "w");
    f.write(sprintf("%J", payload));
    f.close();
    
    // 调用 wget 发送 POST 请求
    system(sprintf(`wget -qO- --header="Content-Type: application/json" --post-file=%s "%s" >/dev/null 2>&1`, tmp_file, url));
    
    // 清理痕迹
    system("rm -f " + tmp_file);
'
