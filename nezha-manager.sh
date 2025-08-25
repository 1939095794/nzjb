#!/bin/sh

# 哪吒监控客户端管理脚本（多系统支持版）
# 自动识别Alpine、OpenWRT和普通Linux系统

# 全局变量
SERVICE_NAME="nezha-agent"
SERVICE_SCRIPT=""
INSTALL_DIR=""
AGENT_BIN_NAME="nezha-agent"
CONFIG_FILE_NAME="config.yml"
CONFIG_FILE_PATH=""
BASE_DOWNLOAD_URL="https://github.com/nezhahq/agent/releases/"
DEFAULT_VERSION="v0.18.10"
SYSTEM_TYPE=""  # alpine, openwrt, linux

# 从一键命令中解析出的配置
PARSED_SERVER=""
PARSED_TLS="false"
PARSED_SECRET=""

# 生成UUID
generate_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen
    else
        cat /proc/sys/kernel/random/uuid 2>/dev/null || \
        printf "%04x%04x-%04x-%04x-%04x-%04x%04x%04x\n" $(awk 'BEGIN{srand();for(i=1;i<=8;i++)printf "%x ",rand()*65535}')
    fi
}

# 解析一键安装命令
parse_oneclick_command() {
    local command="$1"
    
    # 重置解析结果
    PARSED_SERVER=""
    PARSED_TLS="false"
    PARSED_SECRET=""
    
    # 提取NZ_SERVER
    local server=$(echo "$command" | grep -oE 'NZ_SERVER=[^ ]+' | cut -d'=' -f2)
    if [ -n "$server" ]; then
        PARSED_SERVER="$server"
    fi
    
    # 提取NZ_TLS
    local tls=$(echo "$command" | grep -oE 'NZ_TLS=[^ ]+' | cut -d'=' -f2 | tr '[:upper:]' '[:lower:]')
    if [ "$tls" = "true" ] || [ "$tls" = "1" ]; then
        PARSED_TLS="true"
    fi
    
    # 提取NZ_CLIENT_SECRET
    local secret=$(echo "$command" | grep -oE 'NZ_CLIENT_SECRET=[^ ]+' | cut -d'=' -f2)
    if [ -n "$secret" ]; then
        PARSED_SECRET="$secret"
    fi
    
    # 检查是否解析到有效信息
    if [ -n "$PARSED_SERVER" ] && [ -n "$PARSED_SECRET" ]; then
        return 0
    else
        return 1
    fi
}

# 检测系统类型
detect_system() {
    echo "正在检测系统类型..."
    
    # 检测Alpine特征
    if [ -f "/etc/alpine-release" ] || command -v apk >/dev/null 2>&1; then
        SYSTEM_TYPE="alpine"
        return 0
    fi
    
    # 检测OpenWRT特征
    if [ -f "/etc/openwrt_release" ] || [ -f "/etc/rc.common" ] || command -v opkg >/dev/null 2>&1; then
        SYSTEM_TYPE="openwrt"
        return 0
    fi
    
    # 检测普通Linux系统（systemd）
    if command -v systemctl >/dev/null 2>&1 && [ -d "/etc/systemd/system" ]; then
        SYSTEM_TYPE="linux"
        return 0
    fi
    
    echo "错误: 无法识别的系统类型"
    echo "支持的系统: Alpine Linux, OpenWRT, 带有systemd的Linux系统"
    exit 1
}

# 初始化系统特定配置
init_system_config() {
    if [ "$SYSTEM_TYPE" = "alpine" ]; then
        # Alpine Linux配置 (OpenRC)
        SERVICE_SCRIPT="/etc/init.d/$SERVICE_NAME"
        INSTALL_DIR="/opt/nezha/agent"
    elif [ "$SYSTEM_TYPE" = "openwrt" ]; then
        # OpenWRT配置
        SERVICE_SCRIPT="/etc/init.d/$SERVICE_NAME"
        INSTALL_DIR="/root/nezha-agent"
    else
        # 普通Linux配置（systemd）
        SERVICE_SCRIPT="/etc/systemd/system/$SERVICE_NAME.service"
        INSTALL_DIR="/opt/nezha/agent"
    fi
    CONFIG_FILE_PATH="$INSTALL_DIR/$CONFIG_FILE_NAME"
}

# 清屏并显示标题
show_title() {
    clear
    echo "=============================================="
    echo "        哪吒监控客户端管理工具                 "
    echo "        系统类型: $SYSTEM_TYPE                 "
    echo "=============================================="
    echo "当前配置:"
    echo "  服务脚本: $SERVICE_SCRIPT"
    echo "  安装目录: $INSTALL_DIR"
    echo "  配置文件: $CONFIG_FILE_PATH"
    echo "  默认版本: $DEFAULT_VERSION"
    echo "=============================================="
    echo
}

# 显示主菜单
show_main_menu() {
    show_title
    echo "请选择操作:"
    echo " 1. 安装哪吒监控客户端"
    echo " 2. 卸载哪吒监控客户端"
    echo " 3. 启动服务"
    echo " 4. 停止服务"
    echo " 5. 重启服务"
    echo " 6. 查看服务状态"
    echo " 7. 启用开机自启动"
    echo " 8. 禁用开机自启动"
    echo " 9. 修改安装路径"
    echo "10. 编辑配置文件"
    echo "11. 切换TLS加密状态"
    echo "12. 通过一键命令导入配置"
    echo "13. 修复服务配置"
    echo "14. 退出"
    echo
    read -p "请输入选项 [1-14]: " CHOICE
}

# 检查依赖
check_dependencies() {
    local missing=0
    echo "检查必要依赖..."
    
    # 检查下载工具
    if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
        echo "缺少必要工具: wget或curl"
        missing=1
    fi
    
    # 检查unzip
    if ! command -v unzip >/dev/null 2>&1; then
        echo "缺少必要工具: unzip"
        missing=1
    fi
    
    # 检查编辑器
    if ! command -v vi >/dev/null 2>&1 && ! command -v nano >/dev/null 2>&1; then
        echo "警告: 未找到文本编辑器，可能无法编辑配置文件"
    fi
    
    # Alpine特有的依赖检查 (openrc)
    if [ "$SYSTEM_TYPE" = "alpine" ] && ! command -v rc-update >/dev/null 2>&1; then
        echo "缺少必要工具: openrc"
        missing=1
    fi
    
    # 安装缺失依赖
    if [ $missing -eq 1 ]; then
        read -p "是否自动安装缺失依赖? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            if [ "$SYSTEM_TYPE" = "alpine" ] && command -v apk >/dev/null 2>&1; then
                apk update
                apk add wget curl unzip openrc
            elif [ "$SYSTEM_TYPE" = "openwrt" ] && command -v opkg >/dev/null 2>&1; then
                opkg update
                opkg install wget unzip
            elif command -v apt >/dev/null 2>&1; then
                sudo apt update
                sudo apt install -y wget unzip
            elif command -v yum >/dev/null 2>&1; then
                sudo yum install -y wget unzip
            elif command -v dnf >/dev/null 2>&1; then
                sudo dnf install -y wget unzip
            else
                echo "错误: 无法识别的包管理器，无法自动安装依赖"
                return 1
            fi
        else
            return 1
        fi
    fi
    return 0
}

# 修改安装路径
modify_install_path() {
    show_title
    echo "当前安装目录: $INSTALL_DIR"
    read -p "请输入新的安装目录: " NEW_INSTALL_DIR
    if [ -n "$NEW_INSTALL_DIR" ]; then
        INSTALL_DIR="$NEW_INSTALL_DIR"
        CONFIG_FILE_PATH="$INSTALL_DIR/$CONFIG_FILE_NAME"
        echo "安装目录已更新为: $INSTALL_DIR"
    fi
    read -p "按回车键返回主菜单..."
}

# 验证服务脚本是否存在
validate_service_script() {
    if [ ! -f "$SERVICE_SCRIPT" ]; then
        echo "错误: 服务脚本不存在 - $SERVICE_SCRIPT"
        echo "请先执行安装操作"
        return 1
    fi
    return 0
}

# 验证配置文件是否存在
validate_config_file() {
    if [ ! -f "$CONFIG_FILE_PATH" ]; then
        echo "错误: 配置文件不存在 - $CONFIG_FILE_PATH"
        echo "请先执行安装操作"
        return 1
    fi
    return 0
}

# 获取当前TLS状态
get_tls_status() {
    if [ ! -f "$CONFIG_FILE_PATH" ]; then
        echo "false"
        return
    fi
    
    local tls_status=$(grep "^tls:" "$CONFIG_FILE_PATH" | awk '{print $2}')
    echo "${tls_status:-false}"
}

# 切换TLS状态
toggle_tls() {
    show_title
    if ! validate_config_file; then
        read -p "按回车键返回主菜单..."
        return 1
    fi
    
    local current_tls=$(get_tls_status)
    echo "当前TLS状态: $(if [ "$current_tls" = "true" ]; then echo "启用"; else echo "禁用"; fi)"
    
    read -p "是否$(if [ "$current_tls" = "true" ]; then echo "禁用"; else echo "启用"; fi)TLS加密? [y/N] " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "取消操作"
        read -p "按回车键返回主菜单..."
        return 0
    fi
    
    local new_tls=$(if [ "$current_tls" = "true" ]; then echo "false"; else echo "true"; fi)
    
    # 更新配置文件中的tls选项
    if grep -q "^tls:" "$CONFIG_FILE_PATH"; then
        sed -i "s/^tls:.*/tls: $new_tls/" "$CONFIG_FILE_PATH"
    else
        echo "tls: $new_tls" >> "$CONFIG_FILE_PATH"
    fi
    
    # 处理insecure_tls选项
    if [ "$new_tls" = "true" ]; then
        read -p "是否允许不安全的TLS证书? (用于自签名证书) [y/N] " -n 1 -r
        echo
        local insecure_tls="false"
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            insecure_tls="true"
        fi
        
        if grep -q "^insecure_tls:" "$CONFIG_FILE_PATH"; then
            sed -i "s/^insecure_tls:.*/insecure_tls: $insecure_tls/" "$CONFIG_FILE_PATH"
        else
            echo "insecure_tls: $insecure_tls" >> "$CONFIG_FILE_PATH"
        fi
    fi
    
    echo "TLS状态已$(if [ "$new_tls" = "true" ]; then echo "启用"; else echo "禁用"; fi)"
    
    read -p "是否重启服务使配置生效? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        restart_service
    else
        read -p "按回车键返回主菜单..."
    fi
}

# 通过一键命令导入配置
import_from_oneclick() {
    show_title
    echo "通过一键命令导入配置"
    echo "请粘贴完整的哪吒监控一键安装命令（例如：curl -L ...）"
    echo "按Ctrl+D结束输入"
    echo
    
    # 读取用户输入的命令
    echo "请输入一键命令:"
    ONE_CLICK_COMMAND=$(cat)
    
    if [ -z "$ONE_CLICK_COMMAND" ]; then
        echo "未输入任何命令"
        read -p "按回车键返回主菜单..."
        return 1
    fi
    
    # 解析命令
    echo "正在解析命令..."
    if parse_oneclick_command "$ONE_CLICK_COMMAND"; then
        echo "解析成功:"
        echo "  服务器地址: $PARSED_SERVER"
        echo "  TLS加密: $(if [ "$PARSED_TLS" = "true" ]; then echo "启用"; else echo "禁用"; fi)"
        echo "  客户端密钥: $PARSED_SECRET"
        
        # 询问是否应用这些配置
        read -p "是否应用这些配置? [y/N] " -n 1 -r
        echo
        
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            # 确保安装目录存在
            if [ ! -d "$INSTALL_DIR" ]; then
                mkdir -p "$INSTALL_DIR" || {
                    echo "创建目录失败"
                    read -p "按回车键返回主菜单..."
                    return 1
                }
            fi
            
            # 创建或更新配置文件
            local UUID=""
            local INSECURE_TLS="false"
            
            # 如果配置文件已存在，保留现有UUID
            if [ -f "$CONFIG_FILE_PATH" ]; then
                UUID=$(grep "^uuid:" "$CONFIG_FILE_PATH" | awk '{print $2}')
                INSECURE_TLS=$(grep "^insecure_tls:" "$CONFIG_FILE_PATH" | awk '{print $2}')
            else
                UUID=$(generate_uuid)
            fi
            
            # 写入配置文件
            cat > "$CONFIG_FILE_PATH" <<EOL
client_secret: "$PARSED_SECRET"
server: "$PARSED_SERVER"
uuid: "$UUID"
debug: false
disable_auto_update: false
disable_command_execute: false
disable_force_update: false
disable_nat: false
disable_send_query: false
gpu: false
insecure_tls: $INSECURE_TLS
ip_report_period: 1800
report_delay: 3
self_update_period: 0
skip_connection_count: false
skip_procs_count: false
temperature: false
tls: $PARSED_TLS
use_gitee_to_upgrade: false
use_ipv6_country_code: false
EOL
            
            echo "配置已更新: $CONFIG_FILE_PATH"
            
            # 如果服务已存在，询问是否重启
            if [ -f "$SERVICE_SCRIPT" ]; then
                read -p "配置已更新，是否重启服务使配置生效? [y/N] " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    restart_service
                    return 0
                fi
            else
                echo "注意: 配置已导入，但服务尚未安装"
                read -p "是否立即安装服务? [y/N] " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    install_service
                    return 0
                fi
            fi
        else
            echo "已取消应用配置"
        fi
    else
        echo "解析失败，请检查命令格式是否正确"
        echo "支持的命令格式示例:"
        echo "curl -L https://raw.githubusercontent.com/nezhahq/scripts/main/agent/install.sh -o agent.sh && chmod +x agent.sh && env NZ_SERVER=域名:端口 NZ_TLS=true NZ_CLIENT_SECRET=密钥 ./agent.sh"
    fi
    
    read -p "按回车键返回主菜单..."
}

# 启动服务
start_service() {
    show_title
    if ! validate_service_script; then
        read -p "按回车键返回主菜单..."
        return 1
    fi
    
    echo "正在启动服务..."
    if [ "$SYSTEM_TYPE" = "alpine" ] || [ "$SYSTEM_TYPE" = "openwrt" ]; then
        if $SERVICE_SCRIPT running; then
            echo "服务已在运行中"
            read -p "按回车键返回主菜单..."
            return 0
        fi
        
        if $SERVICE_SCRIPT start; then
            sleep 2
            if $SERVICE_SCRIPT running; then
                echo "服务启动成功"
            else
                echo "服务启动失败，请查看日志: $(if [ "$SYSTEM_TYPE" = "alpine" ]; then echo "journalctl -u $SERVICE_NAME"; else echo "logread | grep nezha-agent"; fi)"
            fi
        else
            echo "启动命令执行失败"
        fi
    else
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            echo "服务已在运行中"
            read -p "按回车键返回主菜单..."
            return 0
        fi
        
        if sudo systemctl start "$SERVICE_NAME"; then
            sleep 2
            if systemctl is-active --quiet "$SERVICE_NAME"; then
                echo "服务启动成功"
            else
                echo "服务启动失败，请查看日志: sudo journalctl -u $SERVICE_NAME -f"
            fi
        else
            echo "启动命令执行失败"
        fi
    fi
    read -p "按回车键返回主菜单..."
}

# 停止服务
stop_service() {
    show_title
    if ! validate_service_script; then
        read -p "按回车键返回主菜单..."
        return 1
    fi
    
    echo "正在停止服务..."
    if [ "$SYSTEM_TYPE" = "alpine" ] || [ "$SYSTEM_TYPE" = "openwrt" ]; then
        if ! $SERVICE_SCRIPT running; then
            echo "服务未在运行"
            read -p "按回车键返回主菜单..."
            return 0
        fi
        
        if $SERVICE_SCRIPT stop; then
            if ! $SERVICE_SCRIPT running; then
                echo "服务已停止"
            else
                echo "服务停止失败"
            fi
        else
            echo "停止命令执行失败"
        fi
    else
        if ! systemctl is-active --quiet "$SERVICE_NAME"; then
            echo "服务未在运行"
            read -p "按回车键返回主菜单..."
            return 0
        fi
        
        if sudo systemctl stop "$SERVICE_NAME"; then
            if ! systemctl is-active --quiet "$SERVICE_NAME"; then
                echo "服务已停止"
            else
                echo "服务停止失败"
            fi
        else
            echo "停止命令执行失败"
        fi
    fi
    read -p "按回车键返回主菜单..."
}

# 重启服务
restart_service() {
    show_title
    if ! validate_service_script; then
        read -p "按回车键返回主菜单..."
        return 1
    fi
    
    echo "正在重启服务..."
    if [ "$SYSTEM_TYPE" = "alpine" ] || [ "$SYSTEM_TYPE" = "openwrt" ]; then
        if $SERVICE_SCRIPT restart; then
            sleep 2
            if $SERVICE_SCRIPT running; then
                echo "服务重启成功"
            else
                echo "服务重启失败，请查看日志: $(if [ "$SYSTEM_TYPE" = "alpine" ]; then echo "journalctl -u $SERVICE_NAME"; else echo "logread | grep nezha-agent"; fi)"
            fi
        else
            echo "重启命令执行失败"
        fi
    else
        if sudo systemctl restart "$SERVICE_NAME"; then
            sleep 2
            if systemctl is-active --quiet "$SERVICE_NAME"; then
                echo "服务重启成功"
            else
                echo "服务重启失败，请查看日志: sudo journalctl -u $SERVICE_NAME -f"
            fi
        else
            echo "重启命令执行失败"
        fi
    fi
    read -p "按回车键返回主菜单..."
}

# 查看服务状态
check_status() {
    show_title
    if ! validate_service_script; then
        read -p "按回车键返回主菜单..."
        return 1
    fi
    
    echo "服务状态:"
    if [ "$SYSTEM_TYPE" = "alpine" ] || [ "$SYSTEM_TYPE" = "openwrt" ]; then
        $SERVICE_SCRIPT status
    else
        sudo systemctl status "$SERVICE_NAME"
    fi
    
    # 显示TLS状态和服务器地址
    if validate_config_file; then
        local tls_status=$(get_tls_status)
        echo
        echo "TLS加密状态: $(if [ "$tls_status" = "true" ]; then echo "已启用"; else echo "已禁用"; fi)"
        
        local server=$(grep "^server:" "$CONFIG_FILE_PATH" | awk '{print $2}')
        echo "服务器地址: $server"
    fi
    
    echo
    read -p "按回车键返回主菜单..."
}

# 启用开机自启动
enable_service() {
    show_title
    if ! validate_service_script; then
        read -p "按回车键返回主菜单..."
        return 1
    fi
    
    echo "正在启用开机自启动..."
    if [ "$SYSTEM_TYPE" = "alpine" ]; then
        # Alpine使用openrc
        if rc-update show | grep -q "$SERVICE_NAME"; then
            echo "服务已设置为开机自启动"
        elif rc-update add "$SERVICE_NAME" default; then
            echo "开机自启动已启用"
        else
            echo "启用失败"
        fi
    elif [ "$SYSTEM_TYPE" = "openwrt" ]; then
        if $SERVICE_SCRIPT enabled; then
            echo "服务已设置为开机自启动"
        elif $SERVICE_SCRIPT enable; then
            echo "开机自启动已启用"
        else
            echo "启用失败"
        fi
    else
        # 普通Linux (systemd)
        if systemctl is-enabled --quiet "$SERVICE_NAME"; then
            echo "服务已设置为开机自启动"
        elif sudo systemctl enable "$SERVICE_NAME"; then
            echo "开机自启动已启用"
        else
            echo "启用失败"
        fi
    fi
    read -p "按回车键返回主菜单..."
}

# 禁用开机自启动
disable_service() {
    show_title
    if ! validate_service_script; then
        read -p "按回车键返回主菜单..."
        return 1
    fi
    
    echo "正在禁用开机自启动..."
    if [ "$SYSTEM_TYPE" = "alpine" ]; then
        # Alpine使用openrc
        if ! rc-update show | grep -q "$SERVICE_NAME"; then
            echo "服务未设置开机自启动"
        elif rc-update del "$SERVICE_NAME" default; then
            echo "开机自启动已禁用"
        else
            echo "禁用失败"
        fi
    elif [ "$SYSTEM_TYPE" = "openwrt" ]; then
        if ! $SERVICE_SCRIPT enabled; then
            echo "服务未设置开机自启动"
        elif $SERVICE_SCRIPT disable; then
            echo "开机自启动已禁用"
        else
            echo "禁用失败"
        fi
    else
        # 普通Linux (systemd)
        if ! systemctl is-enabled --quiet "$SERVICE_NAME"; then
            echo "服务未设置开机自启动"
        elif sudo systemctl disable "$SERVICE_NAME"; then
            echo "开机自启动已禁用"
        else
            echo "禁用失败"
        fi
    fi
    read -p "按回车键返回主菜单..."
}

# 编辑配置文件
edit_config() {
    show_title
    if [ ! -d "$INSTALL_DIR" ]; then
        echo "安装目录不存在，创建中..."
        mkdir -p "$INSTALL_DIR" || {
            echo "创建目录失败"
            read -p "按回车键返回主菜单..."
            return 1
        }
    fi
    
    # 配置文件不存在则创建
    if [ ! -f "$CONFIG_FILE_PATH" ]; then
        echo "创建默认配置文件..."
        local UUID=$(generate_uuid)
        cat > "$CONFIG_FILE_PATH" <<EOL
client_secret: ""
debug: false
disable_auto_update: false
disable_command_execute: false
disable_force_update: false
disable_nat: false
disable_send_query: false
gpu: false
insecure_tls: false
ip_report_period: 1800
report_delay: 3
self_update_period: 0
server: "127.0.0.1:8008"
skip_connection_count: false
skip_procs_count: false
temperature: false
tls: false
use_gitee_to_upgrade: false
use_ipv6_country_code: false
uuid: "$UUID"
EOL
    fi
    
    echo "编辑配置文件: $CONFIG_FILE_PATH"
    if command -v vi >/dev/null 2>&1; then
        vi "$CONFIG_FILE_PATH"
    elif command -v nano >/dev/null 2>&1; then
        nano "$CONFIG_FILE_PATH"
    else
        echo "错误: 未找到文本编辑器，请手动安装vi或nano"
        read -p "按回车键返回主菜单..."
        return 1
    fi
    
    read -p "是否重启服务使配置生效? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        restart_service
    else
        read -p "按回车键返回主菜单..."
    fi
}

# 修复服务配置
fix_service() {
    show_title
    if [ ! -d "$INSTALL_DIR" ]; then
        echo "安装目录不存在，创建中..."
        mkdir -p "$INSTALL_DIR" || {
            echo "创建目录失败"
            read -p "按回车键返回主菜单..."
            return 1
        }
    fi
    
    # 创建/修复服务脚本
    echo "修复服务脚本: $SERVICE_SCRIPT"
    if [ "$SYSTEM_TYPE" = "alpine" ] || [ "$SYSTEM_TYPE" = "openwrt" ]; then
        # Alpine和OpenWRT使用openrc风格的服务脚本
        cat > "$SERVICE_SCRIPT" <<EOL
#!/sbin/openrc-run
# ${SYSTEM_TYPE}哪吒监控客户端服务脚本

name="$SERVICE_NAME"
description="Nezha Agent Service"
command="$INSTALL_DIR/$AGENT_BIN_NAME"
command_args="-c $CONFIG_FILE_PATH"
pidfile="/var/run/\$name.pid"
command_background=true

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --owner root:root --mode 0755 /var/run/\$name
}
EOL
    else
        # 普通Linux服务脚本（systemd）
        cat > "$SERVICE_SCRIPT" <<EOL
[Unit]
Description=Nezha Agent
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/$AGENT_BIN_NAME -c $CONFIG_FILE_PATH
Restart=always

[Install]
WantedBy=multi-user.target
EOL
    fi
    chmod +x "$SERVICE_SCRIPT"
    
    # 重新加载系统服务配置
    if [ "$SYSTEM_TYPE" = "alpine" ]; then
        rc-update -u
    elif [ "$SYSTEM_TYPE" != "openwrt" ]; then
        sudo systemctl daemon-reload
    fi
    
    # 检查配置文件
    if [ ! -f "$CONFIG_FILE_PATH" ]; then
        echo "配置文件不存在，创建中..."
        local UUID=$(generate_uuid)
        read -p "请输入服务器地址和端口: " SERVER
        read -p "请输入客户端密钥: " SECRET
        
        # 询问TLS设置
        read -p "是否启用TLS加密连接? [y/N] " -n 1 -r
        echo
        local TLS="false"
        local INSECURE_TLS="false"
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            TLS="true"
            read -p "是否允许不安全的TLS证书? (用于自签名证书) [y/N] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                INSECURE_TLS="true"
            fi
        fi
        
        cat > "$CONFIG_FILE_PATH" <<EOL
client_secret: "$SECRET"
server: "$SERVER"
uuid: "$UUID"
debug: false
disable_auto_update: false
disable_command_execute: false
disable_force_update: false
disable_nat: false
disable_send_query: false
gpu: false
insecure_tls: $INSECURE_TLS
ip_report_period: 1800
report_delay: 3
self_update_period: 0
skip_connection_count: false
skip_procs_count: false
temperature: false
tls: $TLS
use_gitee_to_upgrade: false
use_ipv6_country_code: false
EOL
    fi
    
    echo "服务配置修复完成"
    read -p "是否立即启动服务? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        start_service
    else
        read -p "按回车键返回主菜单..."
    fi
}

# 安装客户端
install_service() {
    show_title
    
    if ! check_dependencies; then
        echo "依赖检查失败，无法继续安装"
        read -p "按回车键返回主菜单..."
        return 1
    fi
    
    # 检查是否已安装
    if [ -f "$SERVICE_SCRIPT" ] && [ -f "$INSTALL_DIR/$AGENT_BIN_NAME" ]; then
        echo "检测到已安装客户端"
        read -p "是否重新安装? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "取消安装"
            read -p "按回车键返回主菜单..."
            return 0
        fi
        # 停止现有服务
        if [ "$SYSTEM_TYPE" = "alpine" ] || [ "$SYSTEM_TYPE" = "openwrt" ]; then
            $SERVICE_SCRIPT stop >/dev/null 2>&1
        else
            sudo systemctl stop "$SERVICE_NAME" >/dev/null 2>&1
        fi
    fi
    
    # 创建安装目录
    echo "创建安装目录: $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR" || {
        echo "创建目录失败"
        read -p "按回车键返回主菜单..."
        return 1
    }
    
    # 检测系统架构
    echo "检测系统架构..."
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            ARCH="amd64"
            ;;
        i386|i686)
            ARCH="386"
            ;;
        armv7l|armv8l)
            ARCH="arm"
            ;;
        aarch64)
            ARCH="arm64"
            ;;
        mips)
            ARCH="mips"
            ;;
        mipsel)
            ARCH="mipsle"
            ;;
        *)
            echo "未识别的架构: $ARCH"
            read -p "请手动输入架构(如amd64/arm/arm64): " ARCH
            if [ -z "$ARCH" ]; then
                echo "架构不能为空"
                read -p "按回车键返回主菜单..."
                return 1
            fi
            ;;
    esac
    echo "检测到架构: $ARCH"
    
    # 获取版本号
    read -p "请输入安装版本(默认$DEFAULT_VERSION): " VERSION
    VERSION="${VERSION:-$DEFAULT_VERSION}"
    
    # 下载客户端
    echo "正在下载客户端 ($VERSION)..."
    FILE_NAME="nezha-agent_linux_$ARCH.zip"
    DOWNLOAD_URL="${BASE_DOWNLOAD_URL}download/${VERSION}/${FILE_NAME}"
    TEMP_FILE="/tmp/$FILE_NAME"
    
    if command -v wget >/dev/null 2>&1; then
        wget -q -O "$TEMP_FILE" "$DOWNLOAD_URL" || {
            echo "下载失败，请检查网络或版本号"
            rm -f "$TEMP_FILE"
            read -p "按回车键返回主菜单..."
            return 1
        }
    else
        curl -s -o "$TEMP_FILE" "$DOWNLOAD_URL" || {
            echo "下载失败，请检查网络或版本号"
            rm -f "$TEMP_FILE"
            read -p "按回车键返回主菜单..."
            return 1
        }
    fi
    
    # 解压安装
    echo "正在安装..."
    unzip -q -o "$TEMP_FILE" -d "$INSTALL_DIR" || {
        echo "解压失败"
        rm -f "$TEMP_FILE"
        read -p "按回车键返回主菜单..."
        return 1
    }
    rm -f "$TEMP_FILE"
    
    # 赋予执行权限
    chmod +x "$INSTALL_DIR/$AGENT_BIN_NAME" || {
        echo "设置执行权限失败"
        read -p "按回车键返回主菜单..."
        return 1
    }
    
    # 创建配置文件
    echo
    read -p "是否通过一键命令导入配置? [y/N] " -n 1 -r
    echo
    local SERVER=""
    local SECRET=""
    local TLS="false"
    local INSECURE_TLS="false"
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "请粘贴一键安装命令:"
        ONE_CLICK_COMMAND=$(cat)
        
        if parse_oneclick_command "$ONE_CLICK_COMMAND"; then
            echo "解析成功，将使用以下配置:"
            echo "  服务器地址: $PARSED_SERVER"
            echo "  TLS加密: $(if [ "$PARSED_TLS" = "true" ]; then echo "启用"; else echo "禁用"; fi)"
            echo "  客户端密钥: $PARSED_SECRET"
            
            SERVER="$PARSED_SERVER"
            SECRET="$PARSED_SECRET"
            TLS="$PARSED_TLS"
            
            # 如果启用了TLS，询问是否允许不安全证书
            if [ "$TLS" = "true" ]; then
                read -p "是否允许不安全的TLS证书? (用于自签名证书) [y/N] " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    INSECURE_TLS="true"
                fi
            fi
        else
            echo "解析失败，将手动输入配置"
            read -p "请输入服务器地址和端口: " SERVER
            read -p "请输入客户端密钥: " SECRET
            
            # TLS设置
            read -p "是否启用TLS加密连接? [y/N] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                TLS="true"
                read -p "是否允许不安全的TLS证书? (用于自签名证书) [y/N] " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    INSECURE_TLS="true"
                fi
            fi
        fi
    else
        # 手动输入配置
        read -p "请输入服务器地址和端口: " SERVER
        read -p "请输入客户端密钥: " SECRET
        
        # TLS设置
        read -p "是否启用TLS加密连接? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            TLS="true"
            read -p "是否允许不安全的TLS证书? (用于自签名证书) [y/N] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                INSECURE_TLS="true"
            fi
        fi
    fi
    
    local UUID=$(generate_uuid)
    
    cat > "$CONFIG_FILE_PATH" <<EOL
client_secret: "$SECRET"
server: "$SERVER"
uuid: "$UUID"
debug: false
disable_auto_update: false
disable_command_execute: false
disable_force_update: false
disable_nat: false
disable_send_query: false
gpu: false
insecure_tls: $INSECURE_TLS
ip_report_period: 1800
report_delay: 3
self_update_period: 0
skip_connection_count: false
skip_procs_count: false
temperature: false
tls: $TLS
use_gitee_to_upgrade: false
use_ipv6_country_code: false
EOL
    
    # 创建服务脚本
    echo "创建服务脚本: $SERVICE_SCRIPT"
    if [ "$SYSTEM_TYPE" = "alpine" ] || [ "$SYSTEM_TYPE" = "openwrt" ]; then
        # Alpine和OpenWRT使用openrc风格的服务脚本
        cat > "$SERVICE_SCRIPT" <<EOL
#!/sbin/openrc-run
# ${SYSTEM_TYPE}哪吒监控客户端服务脚本

name="$SERVICE_NAME"
description="Nezha Agent Service"
command="$INSTALL_DIR/$AGENT_BIN_NAME"
command_args="-c $CONFIG_FILE_PATH"
pidfile="/var/run/\$name.pid"
command_background=true

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --owner root:root --mode 0755 /var/run/\$name
}
EOL
    else
        # 普通Linux服务脚本（systemd）
        cat > "$SERVICE_SCRIPT" <<EOL
[Unit]
Description=Nezha Agent
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/$AGENT_BIN_NAME -c $CONFIG_FILE_PATH
Restart=always

[Install]
WantedBy=multi-user.target
EOL
    fi
    chmod +x "$SERVICE_SCRIPT"
    
    # 重新加载系统服务配置
    if [ "$SYSTEM_TYPE" = "alpine" ]; then
        rc-update -u
    elif [ "$SYSTEM_TYPE" != "openwrt" ]; then
        sudo systemctl daemon-reload
    fi
    
    echo
    echo "安装完成！"
    read -p "是否立即启动服务并设置开机自启动? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if [ "$SYSTEM_TYPE" = "alpine" ]; then
            rc-update add "$SERVICE_NAME" default
            $SERVICE_SCRIPT start
        elif [ "$SYSTEM_TYPE" = "openwrt" ]; then
            $SERVICE_SCRIPT enable
            $SERVICE_SCRIPT start
        else
            sudo systemctl enable "$SERVICE_NAME"
            sudo systemctl start "$SERVICE_NAME"
        fi
        echo "服务已启动并设置为开机自启动"
    fi
    read -p "按回车键返回主菜单..."
}

# 卸载客户端
uninstall_service() {
    show_title
    if [ ! -f "$SERVICE_SCRIPT" ] && [ ! -d "$INSTALL_DIR" ]; then
        echo "未检测到客户端安装"
        read -p "按回车键返回主菜单..."
        return 0
    fi
    
    echo "警告: 即将卸载哪吒监控客户端"
    read -p "确定要卸载吗? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "取消卸载"
        read -p "按回车键返回主菜单..."
        return 0
    fi
    
    # 停止服务并禁用自启动
    if [ -f "$SERVICE_SCRIPT" ]; then
        if [ "$SYSTEM_TYPE" = "alpine" ]; then
            $SERVICE_SCRIPT stop >/dev/null 2>&1
            rc-update del "$SERVICE_NAME" default >/dev/null 2>&1
        elif [ "$SYSTEM_TYPE" = "openwrt" ]; then
            $SERVICE_SCRIPT stop >/dev/null 2>&1
            $SERVICE_SCRIPT disable >/dev/null 2>&1
        else
            sudo systemctl stop "$SERVICE_NAME" >/dev/null 2>&1
            sudo systemctl disable "$SERVICE_NAME" >/dev/null 2>&1
        fi
        rm -f "$SERVICE_SCRIPT"
        
        # 重新加载系统服务配置
        if [ "$SYSTEM_TYPE" = "alpine" ]; then
            rc-update -u
        elif [ "$SYSTEM_TYPE" != "openwrt" ]; then
            sudo systemctl daemon-reload
        fi
    fi
    
    # 删除安装目录
    if [ -d "$INSTALL_DIR" ]; then
        echo "删除安装目录: $INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    fi
    
    echo "卸载完成"
    read -p "按回车键返回主菜单..."
}

# 主逻辑
detect_system
init_system_config

while true; do
    show_main_menu
    case $CHOICE in
        1)
            install_service
            ;;
        2)
            uninstall_service
            ;;
        3)
            start_service
            ;;
        4)
            stop_service
            ;;
        5)
            restart_service
            ;;
        6)
            check_status
            ;;
        7)
            enable_service
            ;;
        8)
            disable_service
            ;;
        9)
            modify_install_path
            ;;
        10)
            edit_config
            ;;
        11)
            toggle_tls
            ;;
        12)
            import_from_oneclick
            ;;
        13)
            fix_service
            ;;
        14)
            show_title
            echo "感谢使用，再见！"
            exit 0
            ;;
        *)
            show_title
            echo "无效选项，请输入1-14之间的数字"
            read -p "按回车键返回主菜单..."
            ;;
    esac
done
