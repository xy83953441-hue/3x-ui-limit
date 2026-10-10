#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

#Add some basic function here
function LOGD() {
    echo -e "${yellow}[DEG] $* ${plain}"
}

function LOGE() {
    echo -e "${red}[ERR] $* ${plain}"
}

function LOGI() {
    echo -e "${green}[INF] $* ${plain}"
}

# Port helpers: detect listener and owning process (best effort)
is_port_in_use() {
    local port="$1"
    if command -v ss > /dev/null 2>&1; then
        ss -ltn 2> /dev/null | awk -v p=":${port}$" '$4 ~ p {exit 0} END {exit 1}'
        return
    fi
    if command -v netstat > /dev/null 2>&1; then
        netstat -lnt 2> /dev/null | awk -v p=":${port} " '$4 ~ p {exit 0} END {exit 1}'
        return
    fi
    if command -v lsof > /dev/null 2>&1; then
        lsof -nP -iTCP:${port} -sTCP:LISTEN > /dev/null 2>&1 && return 0
    fi
    return 1
}

# Simple helpers for domain/IP validation
is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0 || return 1
}
is_ipv6() {
    [[ "$1" =~ : ]] && return 0 || return 1
}
is_ip() {
    is_ipv4 "$1" || is_ipv6 "$1"
}
is_domain() {
    [[ "$1" =~ ^([A-Za-z0-9](-*[A-Za-z0-9])*\.)+(xn--[a-z0-9]{2,}|[A-Za-z]{2,})$ ]] && return 0 || return 1
}

# check root
[[ $EUID -ne 0 ]] && LOGE "ERROR: You must be root to run this script! \n" && exit 1

# Check OS and set release variable
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    echo "Failed to check the system OS, please contact the author!" >&2
    exit 1
fi
echo "操作系统： $release"

os_version=""
os_version=$(grep "^VERSION_ID" /etc/os-release | cut -d '=' -f2 | tr -d '"' | tr -d '.')

# Declare Variables
xui_folder="${XUI_MAIN_FOLDER:=/usr/local/x-ui}"
xui_service="${XUI_SERVICE:=/etc/systemd/system}"
log_folder="${XUI_LOG_FOLDER:=/var/log/x-ui}"
mkdir -p "${log_folder}"
iplimit_log_path="${log_folder}/3xipl.log"
iplimit_banned_log_path="${log_folder}/3xipl-banned.log"

confirm() {
    if [[ $# > 1 ]]; then
        echo && read -rp "$1 [Default $2]: " temp
        if [[ "${temp}" == "" ]]; then
            temp=$2
        fi
    else
        read -rp "$1 [y/n]: " temp
    fi
    if [[ "${temp}" == "y" || "${temp}" == "Y" ]]; then
        return 0
    else
        return 1
    fi
}

confirm_restart() {
    confirm "重启面板也会重启 Xray，确认继续" "y"
    if [[ $? == 0 ]]; then
        restart
    else
        show_menu
    fi
}

before_show_menu() {
    echo && echo -n -e "${yellow}按回车键返回主菜单：${plain}" && read -r temp
    show_menu
}

install() {
    bash <(curl -Ls https://raw.githubusercontent.com/xy83953441-hue/3x-ui-limit/main/install.sh)
    if [[ $? == 0 ]]; then
        if [[ $# == 0 ]]; then
            start
        else
            start 0
        fi
    fi
}

update() {
    confirm "将下载校验安装包，备份后更新；启动失败会尝试恢复。是否继续？" "y"
    if [[ $? != 0 ]]; then
        LOGE "已取消"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi
    bash <(curl -Ls https://raw.githubusercontent.com/xy83953441-hue/3x-ui-limit/main/update.sh)
    if [[ $? == 0 ]]; then
        LOGI "更新完成，面板已重启"
        before_show_menu
    fi
}

update_menu() {
    local tmp
    tmp=$(mktemp /usr/bin/.x-ui-menu.XXXXXX) || return 1
    if curl -fLsS --connect-timeout 15 --max-time 120 \
        https://raw.githubusercontent.com/xy83953441-hue/3x-ui-limit/main/x-ui.sh -o "$tmp" &&
        bash -n "$tmp" && chmod 755 "$tmp" && mv "$tmp" /usr/bin/x-ui; then
        echo '菜单更新成功，重新执行 x-ui 即可。'
    else
        rm -f "$tmp"
        echo '菜单更新失败，原菜单已保留。'
        return 1
    fi
}

legacy_version() {
    echo '旧版本可能无法读取升级后的数据库。请使用更新前保留的备份人工恢复。'
    echo '自动降级暂不执行，避免覆盖节点数据或误装上游版本。'
    return 1
}

# Function to handle the deletion of the script file
delete_script() {
    rm "$0" # Remove the script file itself
    exit 1
}

uninstall() {
    confirm "确认卸载面板和 Xray？节点和面板数据将被删除！" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi

    if [[ $release == "alpine" ]]; then
        rc-service x-ui stop
        rc-update del x-ui
        rm /etc/init.d/x-ui -f
    else
        systemctl stop x-ui
        systemctl disable x-ui
        rm ${xui_service}/x-ui.service -f
        systemctl daemon-reload
        systemctl reset-failed
    fi

    rm /etc/x-ui/ -rf
    rm ${xui_folder}/ -rf

    echo ""
    echo -e "卸载成功。\n"
    echo "重新安装可使用以下命令："
    echo -e "${green}bash <(curl -Ls https://raw.githubusercontent.com/xy83953441-hue/3x-ui-limit/main/install.sh)${plain}"
    echo ""
    # Trap the SIGTERM signal
    trap delete_script SIGTERM
    delete_script
}

reset_user() {
    confirm "Are you sure to reset the username and password of the panel?" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi

    read -rp "Please set the login username [default is a random username]: " config_account
    [[ -z $config_account ]] && config_account=$(gen_random_string 10)
    read -rp "Please set the login password [default is a random password]: " config_password
    [[ -z $config_password ]] && config_password=$(gen_random_string 18)

    read -rp "Do you want to disable currently configured two-factor authentication? (y/n): " twoFactorConfirm
    if [[ $twoFactorConfirm != "y" && $twoFactorConfirm != "Y" ]]; then
        ${xui_folder}/x-ui setting -username "${config_account}" -password "${config_password}" -resetTwoFactor false > /dev/null 2>&1
    else
        ${xui_folder}/x-ui setting -username "${config_account}" -password "${config_password}" -resetTwoFactor true > /dev/null 2>&1
        echo -e "Two factor authentication has been disabled."
    fi

    echo -e "面板账号已重置为： ${green} ${config_account} ${plain}"
    echo -e "面板密码已重置为： ${green} ${config_password} ${plain}"
    echo -e "${green} Please use the new login username and password to access the X-UI panel. Also remember them! ${plain}"
    confirm_restart
}

gen_random_string() {
    local length="$1"
    openssl rand -base64 $((length * 2)) \
        | tr -dc 'a-zA-Z0-9' \
        | head -c "$length"
}

reset_webbasepath() {
    echo -e "${yellow}Resetting Web Base Path${plain}"

    read -rp "确认重置面板访问路径？(y/n)： " confirm
    if [[ $confirm != "y" && $confirm != "Y" ]]; then
        echo -e "${yellow}Operation canceled.${plain}"
        return
    fi

    config_webBasePath=$(gen_random_string 18)

    # Apply the new web base path setting
    ${xui_folder}/x-ui setting -webBasePath "${config_webBasePath}" > /dev/null 2>&1

    echo -e "访问路径已重置为： ${green}${config_webBasePath}${plain}"
    echo -e "${green}Please use the new web base path to access the panel.${plain}"
    restart
}

reset_config() {
    confirm "确认重置面板设置？账号、密码和用户数据保留" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi
    ${xui_folder}/x-ui setting -reset
    echo -e "面板设置已恢复默认。"
    restart
}

check_config() {
    "$xui_folder/x-ui" setting -show true || return 1
    "$xui_folder/x-ui" setting -getCert true || return 1
    echo '上方 port 为面板端口，subPort 为订阅端口。路径区分大小写。'
    echo '密码不可恢复为明文，忘记时请选择菜单 6 重置。证书详情请选择菜单 27。'
    [[ $# == 0 ]] && before_show_menu
    return 0
}

set_port() {
    echo -n "请输入端口号 [1—65535]： "
    read -r port
    if [[ -z "${port}" ]]; then
        LOGD "已取消"
        before_show_menu
    else
        [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || { echo "端口无效。"; return 1; }
        "${xui_folder}/x-ui" setting -port "$port" || return 1
        echo -e "端口已保存，请重启面板，然后使用新端口 ${green}${port}${plain} 访问面板"
        confirm_restart
    fi
}

start() {
    check_status
    if [[ $? == 0 ]]; then
        echo ""
        LOGI "面板已运行，如需重启请选择重启菜单"
    else
        if [[ $release == "alpine" ]]; then
            rc-service x-ui start
        else
            systemctl start x-ui
        fi
        sleep 2
        check_status
        if [[ $? == 0 ]]; then
            LOGI "x-ui Started Successfully"
        else
            LOGE "panel Failed to start, Probably because it takes longer than two seconds to start, Please check the log information later"
        fi
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

stop() {
    check_status
    if [[ $? == 1 ]]; then
        echo ""
        LOGI "面板已停止。"
    else
        if [[ $release == "alpine" ]]; then
            rc-service x-ui stop
        else
            systemctl stop x-ui
        fi
        sleep 2
        check_status
        if [[ $? == 1 ]]; then
            LOGI "x-ui and xray stopped successfully"
        else
            LOGE "面板尚未确认停止，请检查运行日志"
        fi
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

restart() {
    if [[ $release == "alpine" ]]; then
        rc-service x-ui restart
    else
        systemctl restart x-ui
    fi
    sleep 2
    check_status
    if [[ $? == 0 ]]; then
        LOGI "x-ui and xray Restarted successfully"
    else
        LOGE "面板尚未确认启动，请检查运行日志"
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

restart_xray() {
    if [[ $release == "alpine" ]]; then
        rc-service x-ui reload
    else
        systemctl reload x-ui
    fi
    LOGI "xray-core Restart signal sent successfully, Please check the log information to confirm whether xray restarted successfully"
    sleep 2
    show_xray_status
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

status() {
    if [[ $release == "alpine" ]]; then
        rc-service x-ui status
    else
        systemctl status x-ui -l
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

enable() {
    if [[ $release == "alpine" ]]; then
        rc-update add x-ui default
    else
        systemctl enable x-ui
    fi
    if [[ $? == 0 ]]; then
        LOGI "x-ui Set to boot automatically on startup successfully"
    else
        LOGE "x-ui Failed to set Autostart"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

disable() {
    if [[ $release == "alpine" ]]; then
        rc-update del x-ui
    else
        systemctl disable x-ui
    fi
    if [[ $? == 0 ]]; then
        LOGI "已关闭 x-ui 开机自启"
    else
        LOGE "x-ui Failed to cancel autostart"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

show_log() {
    if [[ $release == "alpine" ]]; then
        echo -e "${green}\t1.${plain} 查看运行日志"
        echo -e "${green}\t0.${plain} 返回主菜单"
        read -rp "请选择： " choice

        case "$choice" in
            0)
                show_menu
                ;;
            1)
                grep -F 'x-ui[' /var/log/messages
                if [[ $# == 0 ]]; then
                    before_show_menu
                fi
                ;;
            *)
                echo -e "${red}选项无效，请输入有效编号。${plain}\n"
                show_log
                ;;
        esac
    else
        echo -e "${green}\t1.${plain} 查看运行日志"
        echo -e "${green}\t2.${plain} 清理历史日志"
        echo -e "${green}\t0.${plain} 返回主菜单"
        read -rp "请选择： " choice

        case "$choice" in
            0)
                show_menu
                ;;
            1)
                journalctl -u x-ui -e --no-pager -f -p debug
                if [[ $# == 0 ]]; then
                    before_show_menu
                fi
                ;;
            2)
                sudo journalctl --rotate
                sudo journalctl --vacuum-time=1s
                echo "历史日志已清理。"
                restart
                ;;
            *)
                echo -e "${red}选项无效，请输入有效编号。${plain}\n"
                show_log
                ;;
        esac
    fi
}

bbr_menu() {
    echo -e "${green}\t1.${plain} 启用 BBR"
    echo -e "${green}\t2.${plain} 禁用 BBR"
    echo -e "${green}\t0.${plain} 返回主菜单"
    read -rp "请选择： " choice
    case "$choice" in
        0)
            show_menu
            ;;
        1)
            enable_bbr
            bbr_menu
            ;;
        2)
            disable_bbr
            bbr_menu
            ;;
        *)
            echo -e "${red}选项无效，请输入有效编号。${plain}\n"
            bbr_menu
            ;;
    esac
}

disable_bbr() {

    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) != "bbr" ]] || [[ ! $(sysctl -n net.core.default_qdisc) =~ ^(fq|cake)$ ]]; then
        echo -e "${yellow}BBR is not currently enabled.${plain}"
        before_show_menu
    fi

    if [ -f "/etc/sysctl.d/99-bbr-x-ui.conf" ]; then
        old_settings=$(head -1 /etc/sysctl.d/99-bbr-x-ui.conf | tr -d '#')
        sysctl -w net.core.default_qdisc="${old_settings%:*}"
        sysctl -w net.ipv4.tcp_congestion_control="${old_settings#*:}"
        rm /etc/sysctl.d/99-bbr-x-ui.conf
        sysctl --system
    else
        # Replace BBR with CUBIC configurations
        if [ -f "/etc/sysctl.conf" ]; then
            sed -i 's/net.core.default_qdisc=fq/net.core.default_qdisc=pfifo_fast/' /etc/sysctl.conf
            sed -i 's/net.ipv4.tcp_congestion_control=bbr/net.ipv4.tcp_congestion_control=cubic/' /etc/sysctl.conf
            sysctl -p
        fi
    fi

    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) != "bbr" ]]; then
        echo -e "${green}BBR has been replaced with CUBIC successfully.${plain}"
    else
        echo -e "${red}Failed to replace BBR with CUBIC. Please check your system configuration.${plain}"
    fi
}

enable_bbr() {
    if ! sysctl -n net.ipv4.tcp_available_congestion_control | grep -qw bbr; then
        modprobe tcp_bbr 2>/dev/null || true
    fi
    if ! sysctl -n net.ipv4.tcp_available_congestion_control | grep -qw bbr; then
        echo '当前内核不支持 BBR，未修改配置；节点仍可正常使用。'
        return 1
    fi
    local old_q old_c
    old_q=$(sysctl -n net.core.default_qdisc)
    old_c=$(sysctl -n net.ipv4.tcp_congestion_control)
    [[ "$old_c" == bbr ]] && { echo 'BBR 已启用。'; return 0; }
    if sysctl -w net.core.default_qdisc=fq && sysctl -w net.ipv4.tcp_congestion_control=bbr; then
        mkdir -p /etc/sysctl.d
        printf '#%s:%s\nnet.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' "$old_q" "$old_c" > /etc/sysctl.d/99-bbr-x-ui.conf || return 1
        echo 'BBR 已启用并保存。'
    else
        sysctl -w "net.core.default_qdisc=$old_q" "net.ipv4.tcp_congestion_control=$old_c"
        echo '启用失败，已恢复运行参数。'
        return 1
    fi
}

update_shell() {
    update_menu
}

check_status() {
    if [[ $release == "alpine" ]]; then
        if [[ ! -f /etc/init.d/x-ui ]]; then
            return 2
        fi
        if [[ $(rc-service x-ui status | grep -F 'status: started' -c) == 1 ]]; then
            return 0
        else
            return 1
        fi
    else
        if [[ ! -f ${xui_service}/x-ui.service ]]; then
            return 2
        fi
        temp=$(systemctl status x-ui | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
        if [[ "${temp}" == "running" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

check_enabled() {
    if [[ $release == "alpine" ]]; then
        if [[ $(rc-update show | grep -F 'x-ui' | grep default -c) == 1 ]]; then
            return 0
        else
            return 1
        fi
    else
        temp=$(systemctl is-enabled x-ui)
        if [[ "${temp}" == "enabled" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

check_uninstall() {
    check_status
    if [[ $? != 2 ]]; then
        echo ""
        LOGE "面板已安装，请勿重复安装"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

check_install() {
    check_status
    if [[ $? == 2 ]]; then
        echo ""
        LOGE "请先安装面板"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

show_status() {
    check_status
    case $? in
        0)
            echo -e "面板状态：${green}运行中${plain}"
            show_enable_status
            ;;
        1)
            echo -e "面板状态：${yellow}未运行${plain}"
            show_enable_status
            ;;
        2)
            echo -e "面板状态：${red}未安装${plain}"
            ;;
    esac
    show_xray_status
}

show_enable_status() {
    check_enabled
    if [[ $? == 0 ]]; then
        echo -e "开机自启：${green}已启用${plain}"
    else
        echo -e "开机自启：${red}已关闭${plain}"
    fi
}

check_xray_status() {
    count=$(ps -ef | grep "xray-linux" | grep -v "grep" | wc -l)
    if [[ count -ne 0 ]]; then
        return 0
    else
        return 1
    fi
}

show_xray_status() {
    check_xray_status
    if [[ $? == 0 ]]; then
        echo -e "Xray 状态：${green}运行中${plain}"
    else
        echo -e "Xray 状态：${red}未运行${plain}"
    fi
}

firewall_menu() {
    if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
        local choice port zone answer
        echo '1.查看规则  2.放行节点 TCP 端口  0.返回'
        read -rp '请选择：' choice
        case "$choice" in
            1) firewall-cmd --get-active-zones; firewall-cmd --list-all;;
            2) open_node_port;;
            0) return;;
            *) echo '无效选项。';;
        esac
        return
    fi

    echo -e "${green}\t1.${plain} ${green}Install${plain} 防火墙"
    echo -e "${green}\t2.${plain} 端口规则列表（含编号）"
    echo -e "${green}\t3.${plain} ${green}Open${plain} Ports"
    echo -e "${green}\t4.${plain} ${red}Delete${plain} 端口规则"
    echo -e "${green}\t5.${plain} ${green}Enable${plain} 防火墙"
    echo -e "${green}\t6.${plain} ${red}Disable${plain} 防火墙"
    echo -e "${green}\t7.${plain} 防火墙状态"
    echo -e "${green}\t0.${plain} 返回主菜单"
    read -rp "请选择： " choice
    case "$choice" in
        0)
            show_menu
            ;;
        1)
            install_firewall
            firewall_menu
            ;;
        2)
            ufw status numbered
            firewall_menu
            ;;
        3)
            open_ports
            firewall_menu
            ;;
        4)
            delete_ports
            firewall_menu
            ;;
        5)
            ufw enable
            firewall_menu
            ;;
        6)
            ufw disable
            firewall_menu
            ;;
        7)
            ufw status verbose
            firewall_menu
            ;;
        *)
            echo -e "${red}选项无效，请输入有效编号。${plain}\n"
            firewall_menu
            ;;
    esac
}

install_firewall() {
    if ! command -v ufw &> /dev/null; then
        echo "尚未安装 UFW，正在安装……"
        apt-get update
        apt-get install -y ufw
    else
        echo "UFW 已安装"
    fi

    # Check if the firewall is inactive
    if ufw status | grep -q "Status: active"; then
        echo "防火墙已启用"
    else
        echo "正在启用防火墙……"
        # Open the necessary ports
        ufw allow ssh
        ufw allow http
        ufw allow https
        ufw allow 2053/tcp #webPort
        ufw allow 2096/tcp #subport

        # Enable the firewall
        ufw --force enable
    fi
}

open_ports() {
    # Prompt the user to enter the ports they want to open
    read -rp "输入要放行的端口（例如 80,443 或 400-500）： " ports

    # Check if the input is valid
    if ! [[ $ports =~ ^([0-9]+|[0-9]+-[0-9]+)(,([0-9]+|[0-9]+-[0-9]+))*$ ]]; then
        echo "输入无效，请输入逗号分隔端口或端口范围（例如 80,443 或 400-500）。" >&2
        exit 1
    fi

    # Open the specified ports using ufw
    IFS=',' read -ra PORT_LIST <<< "$ports"
    for port in "${PORT_LIST[@]}"; do
        if [[ $port == *-* ]]; then
            # Split the range into start and end ports
            start_port=$(echo $port | cut -d'-' -f1)
            end_port=$(echo $port | cut -d'-' -f2)
            # Open the port range
            ufw allow $start_port:$end_port/tcp
            ufw allow $start_port:$end_port/udp
        else
            # Open the single port
            ufw allow "$port"
        fi
    done

    # Confirm that the ports are opened
    echo "已放行端口："
    for port in "${PORT_LIST[@]}"; do
        if [[ $port == *-* ]]; then
            start_port=$(echo $port | cut -d'-' -f1)
            end_port=$(echo $port | cut -d'-' -f2)
            # Check if the port range has been successfully opened
            (ufw status | grep -q "$start_port:$end_port") && echo "$start_port-$end_port"
        else
            # Check if the individual port has been successfully opened
            (ufw status | grep -q "$port") && echo "$port"
        fi
    done
}

delete_ports() {
    # Display current rules with numbers
    echo "当前 UFW 规则："
    ufw status numbered

    # Ask the user how they want to delete rules
    echo "请选择删除方式："
    echo "1) 规则编号"
    echo "2) Ports"
    read -rp "请选择 1 或 2： " choice

    if [[ $choice -eq 1 ]]; then
        # Deleting by rule numbers
        read -rp "请输入要删除的规则编号（用逗号分隔）： " rule_numbers

        # Validate the input
        if ! [[ $rule_numbers =~ ^([0-9]+)(,[0-9]+)*$ ]]; then
            echo "输入无效，请使用逗号分隔规则编号。" >&2
            exit 1
        fi

        # Split numbers into an array
        IFS=',' read -ra RULE_NUMBERS <<< "$rule_numbers"
        for rule_number in "${RULE_NUMBERS[@]}"; do
            # Delete the rule by number
            ufw delete "$rule_number" || echo "删除规则失败，编号 $rule_number"
        done

        echo "所选规则已删除。"

    elif [[ $choice -eq 2 ]]; then
        # Deleting by ports
        read -rp "输入要删除规则的端口（例如 80,443 或 400-500）： " ports

        # Validate the input
        if ! [[ $ports =~ ^([0-9]+|[0-9]+-[0-9]+)(,([0-9]+|[0-9]+-[0-9]+))*$ ]]; then
            echo "输入无效，请输入逗号分隔端口或端口范围（例如 80,443 或 400-500）。" >&2
            exit 1
        fi

        # Split ports into an array
        IFS=',' read -ra PORT_LIST <<< "$ports"
        for port in "${PORT_LIST[@]}"; do
            if [[ $port == *-* ]]; then
                # Split the port range
                start_port=$(echo $port | cut -d'-' -f1)
                end_port=$(echo $port | cut -d'-' -f2)
                # Delete the port range
                ufw delete allow $start_port:$end_port/tcp
                ufw delete allow $start_port:$end_port/udp
            else
                # Delete a single port
                ufw delete allow "$port"
            fi
        done

        # Confirmation of deletion
        echo "已删除端口规则："
        for port in "${PORT_LIST[@]}"; do
            if [[ $port == *-* ]]; then
                start_port=$(echo $port | cut -d'-' -f1)
                end_port=$(echo $port | cut -d'-' -f2)
                # Check if the port range has been deleted
                (ufw status | grep -q "$start_port:$end_port") || echo "$start_port-$end_port"
            else
                # Check if the individual port has been deleted
                (ufw status | grep -q "$port") || echo "$port"
            fi
        done
    else
        echo "${red}Error:${plain} 选项无效，请输入 1 或 2。" >&2
        exit 1
    fi
}

update_all_geofiles() {
    update_geofiles "main"
    update_geofiles "IR"
    update_geofiles "RU"
}

update_geofiles() {
    case "${1}" in
        "main")
            dat_files=(geoip geosite)
            dat_source="Loyalsoldier/v2ray-rules-dat"
            ;;
        "IR")
            dat_files=(geoip_IR geosite_IR)
            dat_source="chocolate4u/Iran-v2ray-rules"
            ;;
        "RU")
            dat_files=(geoip_RU geosite_RU)
            dat_source="runetfreedom/russia-v2ray-rules-dat"
            ;;
    esac
    for dat in "${dat_files[@]}"; do
        # Remove suffix for remote filename (e.g., geoip_IR -> geoip)
        remote_file="${dat%%_*}"
        curl -fLRo ${xui_folder}/bin/${dat}.dat -z ${xui_folder}/bin/${dat}.dat \
            https://github.com/${dat_source}/releases/latest/download/${remote_file}.dat
    done
}

update_geo() {
    echo -e "${green}\t1.${plain} Loyalsoldier (geoip.dat, geosite.dat)"
    echo -e "${green}\t2.${plain} chocolate4u (geoip_IR.dat, geosite_IR.dat)"
    echo -e "${green}\t3.${plain} runetfreedom (geoip_RU.dat, geosite_RU.dat)"
    echo -e "${green}\t4.${plain} 全部"
    echo -e "${green}\t0.${plain} 返回主菜单"
    read -rp "请选择： " choice

    case "$choice" in
        0)
            show_menu
            ;;
        1)
            update_geofiles "main"
            echo -e "${green}Loyalsoldier 数据文件更新成功！${plain}"
            restart
            ;;
        2)
            update_geofiles "IR"
            echo -e "${green}chocolate4u 数据文件更新成功！${plain}"
            restart
            ;;
        3)
            update_geofiles "RU"
            echo -e "${green}runetfreedom 数据文件更新成功！${plain}"
            restart
            ;;
        4)
            update_all_geofiles
            echo -e "${green}全部 Geo 数据文件更新成功！${plain}"
            restart
            ;;
        *)
            echo -e "${red}选项无效，请输入有效编号。${plain}\n"
            update_geo
            ;;
    esac

    before_show_menu
}

ssl_cert_issue_CF() {
    load_ssl_helpers || return 1
    setup_cloudflare_certificate
}

run_speedtest() {
    # Check if Speedtest is already installed
    if ! command -v speedtest &> /dev/null; then
        # If not installed, determine installation method
        if command -v snap &> /dev/null; then
            # Use snap to install Speedtest
            echo "Installing Speedtest using snap..."
            snap install speedtest
        else
            # Fallback to using package managers
            local pkg_manager=""
            local speedtest_install_script=""

            if command -v dnf &> /dev/null; then
                pkg_manager="dnf"
                speedtest_install_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh"
            elif command -v yum &> /dev/null; then
                pkg_manager="yum"
                speedtest_install_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh"
            elif command -v apt-get &> /dev/null; then
                pkg_manager="apt-get"
                speedtest_install_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh"
            elif command -v apt &> /dev/null; then
                pkg_manager="apt"
                speedtest_install_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh"
            fi

            if [[ -z $pkg_manager ]]; then
                echo "Error: Package manager not found. You may need to install Speedtest manually."
                return 1
            else
                echo "Installing Speedtest using $pkg_manager..."
                curl -s $speedtest_install_script | bash
                $pkg_manager install -y speedtest
            fi
        fi
    fi

    speedtest
}

ip_validation() {
    ipv6_regex="^(([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}|::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9]))$"
    ipv4_regex="^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]?|0)\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]?|0)$"
}

iplimit_main() {
    echo -e "\n${green}\t1.${plain} 安装 Fail2ban 并配置 IP 限制"
    echo -e "${green}\t2.${plain} 修改封禁时长"
    echo -e "${green}\t3.${plain} 解除全部封禁"
    echo -e "${green}\t4.${plain} 封禁日志"
    echo -e "${green}\t5.${plain} 封禁指定 IP"
    echo -e "${green}\t6.${plain} 解除指定 IP 封禁"
    echo -e "${green}\t7.${plain} 实时日志"
    echo -e "${green}\t8.${plain} 服务状态"
    echo -e "${green}\t9.${plain} 重启服务"
    echo -e "${green}\t10.${plain} 卸载 Fail2ban 和 IP 限制"
    echo -e "${green}\t0.${plain} 返回主菜单"
    read -rp "请选择： " choice
    case "$choice" in
        0)
            show_menu
            ;;
        1)
            confirm "继续安装 Fail2ban 和 IP 限制？" "y"
            if [[ $? == 0 ]]; then
                install_iplimit
            else
                iplimit_main
            fi
            ;;
        2)
            read -rp "请输入封禁时长，单位分钟 [默认 30]： " NUM
            if [[ $NUM =~ ^[0-9]+$ ]]; then
                create_iplimit_jails ${NUM}
                if [[ $release == "alpine" ]]; then
                    rc-service fail2ban restart
                else
                    systemctl restart fail2ban
                fi
            else
                echo -e "${red}${NUM} is not a number! Please, try again.${plain}"
            fi
            iplimit_main
            ;;
        3)
            confirm "确认解除全部 IP 封禁？" "y"
            if [[ $? == 0 ]]; then
                fail2ban-client reload --restart --unban 3x-ipl
                truncate -s 0 "${iplimit_banned_log_path}"
                echo -e "${green}已解除全部封禁。${plain}"
                iplimit_main
            else
                echo -e "${yellow}已取消.${plain}"
            fi
            iplimit_main
            ;;
        4)
            show_banlog
            iplimit_main
            ;;
        5)
            read -rp "输入要封禁的 IP： " ban_ip
            ip_validation
            if [[ $ban_ip =~ $ipv4_regex || $ban_ip =~ $ipv6_regex ]]; then
                fail2ban-client set 3x-ipl banip "$ban_ip"
                echo -e "${green}IP Address ${ban_ip} has been banned successfully.${plain}"
            else
                echo -e "${red}IP 地址格式无效，请重试。${plain}"
            fi
            iplimit_main
            ;;
        6)
            read -rp "输入要解封的 IP： " unban_ip
            ip_validation
            if [[ $unban_ip =~ $ipv4_regex || $unban_ip =~ $ipv6_regex ]]; then
                fail2ban-client set 3x-ipl unbanip "$unban_ip"
                echo -e "${green}IP Address ${unban_ip} has been unbanned successfully.${plain}"
            else
                echo -e "${red}IP 地址格式无效，请重试。${plain}"
            fi
            iplimit_main
            ;;
        7)
            tail -f /var/log/fail2ban.log
            iplimit_main
            ;;
        8)
            service fail2ban status
            iplimit_main
            ;;
        9)
            if [[ $release == "alpine" ]]; then
                rc-service fail2ban restart
            else
                systemctl restart fail2ban
            fi
            iplimit_main
            ;;
        10)
            remove_iplimit
            iplimit_main
            ;;
        *)
            echo -e "${red}选项无效，请输入有效编号。${plain}\n"
            iplimit_main
            ;;
    esac
}

install_iplimit() {
    if ! command -v fail2ban-client &> /dev/null; then
        echo -e "${green}Fail2ban is not installed. Installing now...!${plain}\n"

        # Install fail2ban together with nftables. Recent fail2ban packages
        # default to `banaction = nftables-multiport` in /etc/fail2ban/jail.conf,
        # but the `nftables` package isn't pulled in as a dependency on most
        # minimal server images (Debian 12+, Ubuntu 24+, fresh RHEL-family).
        # Without `nft` in PATH the default sshd jail fails to ban with
        #   stderr: '/bin/sh: 1: nft: not found'
        # even though our own 3x-ipl jail uses iptables. Bundling the binary
        # at install time prevents that confusing log spam for new installs.
        case "${release}" in
            ubuntu)
                apt-get update
                if [[ "${os_version}" -ge 24 ]]; then
                    apt-get install python3-pip -y
                    python3 -m pip install pyasynchat --break-system-packages
                fi
                apt-get install fail2ban nftables -y
                ;;
            debian)
                apt-get update
                if [ "$os_version" -ge 12 ]; then
                    apt-get install -y python3-systemd
                fi
                apt-get install -y fail2ban nftables
                ;;
            armbian)
                apt-get update && apt-get install fail2ban nftables -y
                ;;
            fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
                dnf -y update && dnf -y install fail2ban nftables
                ;;
            centos)
                if [[ "${VERSION_ID}" =~ ^7 ]]; then
                    yum update -y && yum install epel-release -y
                    yum -y install fail2ban nftables
                else
                    dnf -y update && dnf -y install fail2ban nftables
                fi
                ;;
            arch | manjaro | parch)
                pacman -Syu --noconfirm fail2ban nftables
                ;;
            alpine)
                apk add fail2ban nftables
                ;;
            *)
                echo -e "${red}Unsupported operating system. Please check the script and install the necessary packages manually.${plain}\n"
                exit 1
                ;;
        esac

        if ! command -v fail2ban-client &> /dev/null; then
            echo -e "${red}Fail2ban installation failed.${plain}\n"
            exit 1
        fi

        echo -e "${green}Fail2ban installed successfully!${plain}\n"
    else
        echo -e "${yellow}Fail2ban is already installed.${plain}\n"
    fi

    echo -e "${green}Configuring IP Limit...${plain}\n"

    # make sure there's no conflict for jail files
    iplimit_remove_conflicts

    # Check if log file exists
    if ! test -f "${iplimit_banned_log_path}"; then
        touch ${iplimit_banned_log_path}
    fi

    # Check if service log file exists so fail2ban won't return error
    if ! test -f "${iplimit_log_path}"; then
        touch ${iplimit_log_path}
    fi

    # Create the iplimit jail files
    # we didn't pass the bantime here to use the default value
    create_iplimit_jails

    # Launching fail2ban
    if [[ $release == "alpine" ]]; then
        if [[ $(rc-service fail2ban status | grep -F 'status: started' -c) == 0 ]]; then
            rc-service fail2ban start
        else
            rc-service fail2ban restart
        fi
        rc-update add fail2ban
    else
        if ! systemctl is-active --quiet fail2ban; then
            systemctl start fail2ban
        else
            systemctl restart fail2ban
        fi
        systemctl enable fail2ban
    fi

    echo -e "${green}IP Limit installed and configured successfully!${plain}\n"
    before_show_menu
}

remove_iplimit() {
    echo -e "${green}\t1.${plain} 仅删除 IP 限制配置"
    echo -e "${green}\t2.${plain} 卸载 Fail2ban 和 IP 限制"
    echo -e "${green}\t0.${plain} 返回主菜单"
    read -rp "请选择： " num
    case "$num" in
        1)
            rm -f /etc/fail2ban/filter.d/3x-ipl.conf
            rm -f /etc/fail2ban/action.d/3x-ipl.conf
            rm -f /etc/fail2ban/jail.d/3x-ipl.conf
            if [[ $release == "alpine" ]]; then
                rc-service fail2ban restart
            else
                systemctl restart fail2ban
            fi
            echo -e "${green}IP Limit removed successfully!${plain}\n"
            before_show_menu
            ;;
        2)
            rm -rf /etc/fail2ban
            if [[ $release == "alpine" ]]; then
                rc-service fail2ban stop
            else
                systemctl stop fail2ban
            fi
            case "${release}" in
                ubuntu | debian | armbian)
                    apt-get remove -y fail2ban
                    apt-get purge -y fail2ban -y
                    apt-get autoremove -y
                    ;;
                fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
                    dnf remove fail2ban -y
                    dnf autoremove -y
                    ;;
                centos)
                    if [[ "${VERSION_ID}" =~ ^7 ]]; then
                        yum remove fail2ban -y
                        yum autoremove -y
                    else
                        dnf remove fail2ban -y
                        dnf autoremove -y
                    fi
                    ;;
                arch | manjaro | parch)
                    pacman -Rns --noconfirm fail2ban
                    ;;
                alpine)
                    apk del fail2ban
                    ;;
                *)
                    echo -e "${red}Unsupported operating system. Please uninstall Fail2ban manually.${plain}\n"
                    exit 1
                    ;;
            esac
            echo -e "${green}Fail2ban and IP Limit removed successfully!${plain}\n"
            before_show_menu
            ;;
        0)
            show_menu
            ;;
        *)
            echo -e "${red}选项无效，请输入有效编号。${plain}\n"
            remove_iplimit
            ;;
    esac
}

show_banlog() {
    local system_log="/var/log/fail2ban.log"

    echo -e "${green}Checking ban logs...${plain}\n"

    if [[ $release == "alpine" ]]; then
        if [[ $(rc-service fail2ban status | grep -F 'status: started' -c) == 0 ]]; then
            echo -e "${red}Fail2ban service is not running!${plain}\n"
            return 1
        fi
    else
        if ! systemctl is-active --quiet fail2ban; then
            echo -e "${red}Fail2ban service is not running!${plain}\n"
            return 1
        fi
    fi

    if [[ -f "$system_log" ]]; then
        echo -e "${green}Recent system ban activities from fail2ban.log:${plain}"
        grep "3x-ipl" "$system_log" | grep -E "Ban|Unban" | tail -n 10 || echo -e "${yellow}No recent system ban activities found${plain}"
        echo ""
    fi

    if [[ -f "${iplimit_banned_log_path}" ]]; then
        echo -e "${green}3X-IPL ban log entries:${plain}"
        if [[ -s "${iplimit_banned_log_path}" ]]; then
            grep -v "INIT" "${iplimit_banned_log_path}" | tail -n 10 || echo -e "${yellow}No ban entries found${plain}"
        else
            echo -e "${yellow}Ban log file is empty${plain}"
        fi
    else
        echo -e "${red}Ban log file not found at: ${iplimit_banned_log_path}${plain}"
    fi

    echo -e "\n${green}Current jail status:${plain}"
    fail2ban-client status 3x-ipl || echo -e "${yellow}Unable to get jail status${plain}"
}

create_iplimit_jails() {
    # Use default bantime if not passed => 30 minutes
    local bantime="${1:-30}"

    # Uncomment 'allowipv6 = auto' in fail2ban.conf
    sed -i 's/#allowipv6 = auto/allowipv6 = auto/g' /etc/fail2ban/fail2ban.conf

    # On Debian 12+ fail2ban's default backend should be changed to systemd
    if [[ "${release}" == "debian" && ${os_version} -ge 12 ]]; then
        sed -i '0,/action =/s/backend = auto/backend = systemd/' /etc/fail2ban/jail.conf
    fi

    cat << EOF > /etc/fail2ban/jail.d/3x-ipl.conf
[3x-ipl]
enabled=true
backend=auto
filter=3x-ipl
action=3x-ipl
logpath=${iplimit_log_path}
maxretry=1
findtime=32
bantime=${bantime}m
EOF

    cat << EOF > /etc/fail2ban/filter.d/3x-ipl.conf
[Definition]
datepattern = ^%Y/%m/%d %H:%M:%S
failregex   = \[LIMIT_IP\]\s*Email\s*=\s*<F-USER>.+</F-USER>\s*\|\|\s*Disconnecting OLD IP\s*=\s*<ADDR>\s*\|\|\s*Timestamp\s*=\s*\d+
ignoreregex =
EOF

    cat << EOF > /etc/fail2ban/action.d/3x-ipl.conf
[INCLUDES]
before = iptables-allports.conf

[Definition]
actionstart = <iptables> -N f2b-<name>
              <iptables> -A f2b-<name> -j <returntype>
              <iptables> -I <chain> -p <protocol> -j f2b-<name>

actionstop = <iptables> -D <chain> -p <protocol> -j f2b-<name>
             <actionflush>
             <iptables> -X f2b-<name>

actioncheck = <iptables> -n -L <chain> | grep -q 'f2b-<name>[ \t]'

actionban = <iptables> -I f2b-<name> 1 -s <ip> -j <blocktype>
            echo "\$(date +"%%Y/%%m/%%d %%H:%%M:%%S")   BAN   [Email] = <F-USER> [IP] = <ip> banned for <bantime> seconds." >> ${iplimit_banned_log_path}

actionunban = <iptables> -D f2b-<name> -s <ip> -j <blocktype>
              echo "\$(date +"%%Y/%%m/%%d %%H:%%M:%%S")   UNBAN   [Email] = <F-USER> [IP] = <ip> unbanned." >> ${iplimit_banned_log_path}

[Init]
name = default
protocol = tcp
chain = INPUT
EOF

    echo -e "${green}Ip Limit jail files created with a bantime of ${bantime} minutes.${plain}"
}

iplimit_remove_conflicts() {
    local jail_files=(
        /etc/fail2ban/jail.conf
        /etc/fail2ban/jail.local
    )

    for file in "${jail_files[@]}"; do
        # Check for [3x-ipl] config in jail file then remove it
        if test -f "${file}" && grep -qw '3x-ipl' ${file}; then
            sed -i "/\[3x-ipl\]/,/^$/d" ${file}
            echo -e "${yellow}Removing conflicts of [3x-ipl] in jail (${file})!${plain}\n"
        fi
    done
}

SSH_port_forwarding() {
    local URL_lists=(
        "https://api4.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://v4.api.ipinfo.io/ip"
        "https://ipv4.myexternalip.com/raw"
        "https://4.ident.me"
        "https://check-host.net/ip"
    )
    local server_ip=""
    for ip_address in "${URL_lists[@]}"; do
        local response=$(curl -s -w "\n%{http_code}" --max-time 3 "${ip_address}" 2> /dev/null)
        local http_code=$(echo "$response" | tail -n1)
        local ip_result=$(echo "$response" | head -n-1 | tr -d '[:space:]"')
        if [[ "${http_code}" == "200" && "${ip_result}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            server_ip="${ip_result}"
            break
        fi
    done

    if [[ -z "$server_ip" ]]; then
        echo -e "${yellow}Could not auto-detect server IP from any provider.${plain}"
        while [[ -z "$server_ip" ]]; do
            read -rp "请输入服务器公网 IPv4 地址： " server_ip
            server_ip="${server_ip// /}"
            if [[ ! "$server_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo -e "${red}Invalid IPv4 address. Please try again.${plain}"
                server_ip=""
            fi
        done
    fi

    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    local existing_listenIP=$(${xui_folder}/x-ui setting -getListen true | grep -Eo 'listenIP: .+' | awk '{print $2}')
    local existing_cert=$(${xui_folder}/x-ui setting -getCert true | grep -Eo 'cert: .+' | awk '{print $2}')
    local existing_key=$(${xui_folder}/x-ui setting -getCert true | grep -Eo 'key: .+' | awk '{print $2}')

    local config_listenIP=""
    local listen_choice=""

    if [[ -n "$existing_cert" && -n "$existing_key" ]]; then
        echo -e "${green}Panel is secure with SSL.${plain}"
        before_show_menu
    fi
    if [[ -z "$existing_cert" && -z "$existing_key" && (-z "$existing_listenIP" || "$existing_listenIP" == "0.0.0.0") ]]; then
        echo -e "\n${red}Warning: No Cert and Key found! The panel is not secure.${plain}"
        echo "请先配置证书或 SSH 端口转发。"
    fi

    if [[ -n "$existing_listenIP" && "$existing_listenIP" != "0.0.0.0" && (-z "$existing_cert" && -z "$existing_key") ]]; then
        echo -e "\n${green}Current SSH Port Forwarding Configuration:${plain}"
        echo -e "SSH 命令："
        echo -e "${yellow}ssh -L 2222:${existing_listenIP}:${existing_port} root@${server_ip}${plain}"
        echo -e "\nIf using SSH key:"
        echo -e "${yellow}ssh -i <sshkeypath> -L 2222:${existing_listenIP}:${existing_port} root@${server_ip}${plain}"
        echo -e "\nAfter connecting, access the panel at:"
        echo -e "${yellow}http://localhost:2222${existing_webBasePath}${plain}"
    fi

    echo -e "\n请选择："
    echo -e "${green}1.${plain} Set listen IP"
    echo -e "${green}2.${plain} Clear listen IP"
    echo -e "${green}0.${plain} 返回主菜单"
    read -rp "请选择： " num

    case "$num" in
        1)
            if [[ -z "$existing_listenIP" || "$existing_listenIP" == "0.0.0.0" ]]; then
                echo -e "\nNo listenIP configured. 请选择："
                echo -e "1. 使用默认地址（127.0.0.1）"
                echo -e "2. Set a custom IP"
                read -rp "请选择 1 或 2： " listen_choice

                config_listenIP="127.0.0.1"
                [[ "$listen_choice" == "2" ]] && read -rp "请输入监听 IP： " config_listenIP

                ${xui_folder}/x-ui setting -listenIP "${config_listenIP}" > /dev/null 2>&1
                echo -e "${green}listen IP has been set to ${config_listenIP}.${plain}"
                echo -e "\n${green}SSH Port Forwarding Configuration:${plain}"
                echo -e "SSH 命令："
                echo -e "${yellow}ssh -L 2222:${config_listenIP}:${existing_port} root@${server_ip}${plain}"
                echo -e "\nIf using SSH key:"
                echo -e "${yellow}ssh -i <sshkeypath> -L 2222:${config_listenIP}:${existing_port} root@${server_ip}${plain}"
                echo -e "\nAfter connecting, access the panel at:"
                echo -e "${yellow}http://localhost:2222${existing_webBasePath}${plain}"
                restart
            else
                config_listenIP="${existing_listenIP}"
                echo -e "${green}Current listen IP is already set to ${config_listenIP}.${plain}"
            fi
            ;;
        2)
            ${xui_folder}/x-ui setting -listenIP 0.0.0.0 > /dev/null 2>&1
            echo -e "${green}Listen IP has been cleared.${plain}"
            restart
            ;;
        0)
            show_menu
            ;;
        *)
            echo -e "${red}选项无效，请输入有效编号。${plain}\n"
            SSH_port_forwarding
            ;;
    esac
}

show_usage() {
    echo -e "┌────────────────────────────────────────────────────────────────┐
│  ${blue}x-ui control menu usages (subcommands):${plain}                       │
│                                                                │
│  ${blue}x-ui${plain}                       - Admin Management Script          │
│  ${blue}x-ui start${plain}                 - Start                            │
│  ${blue}x-ui stop${plain}                  - Stop                             │
│  ${blue}x-ui restart${plain}               - Restart                          │
|  ${blue}x-ui restart-xray${plain}          - Restart Xray                     │
│  ${blue}x-ui status${plain}                - Current Status                   │
│  ${blue}x-ui settings${plain}              - Current Settings                 │
│  ${blue}x-ui enable${plain}                - Enable Autostart on OS Startup   │
│  ${blue}x-ui disable${plain}               - Disable Autostart on OS Startup  │
│  ${blue}x-ui log${plain}                   - Check logs                       │
│  ${blue}x-ui banlog${plain}                - Check Fail2ban ban logs          │
│  ${blue}x-ui update${plain}                - Update                           │
│  ${blue}x-ui update-all-geofiles${plain}   - Update all geo files             │
│  ${blue}x-ui legacy${plain}                - Legacy version                   │
│  ${blue}x-ui install${plain}               - Install                          │
│  ${blue}x-ui uninstall${plain}             - Uninstall                        │
└────────────────────────────────────────────────────────────────┘"
}

show_menu() {
    echo -e "
╔────────────────────────────────────────────────╗
│   ${green}3X-UI 面板管理脚本${plain}                           │
│   ${green}0.${plain} 退出脚本                                  │
│────────────────────────────────────────────────│
│   ${green}1.${plain} 安装面板                                  │
│   ${green}2.${plain} 更新面板                                  │
│   ${green}3.${plain} 更新管理菜单                              │
│   ${green}4.${plain} 安装指定历史版本                          │
│   ${green}5.${plain} 卸载面板                                  │
│────────────────────────────────────────────────│
│   ${green}6.${plain} 重置用户名和密码                          │
│   ${green}7.${plain} 重置面板访问路径                          │
│   ${green}8.${plain} 重置面板设置                              │
│   ${green}9.${plain} 修改面板端口                              │
│  ${green}10.${plain} 查看当前设置                              │
│────────────────────────────────────────────────│
│  ${green}11.${plain} 启动面板                                  │
│  ${green}12.${plain} 停止面板                                  │
│  ${green}13.${plain} 重启面板                                  │
│  ${green}14.${plain} 重启 Xray                                 │
│  ${green}15.${plain} 查看运行状态                              │
│  ${green}16.${plain} 日志管理                                  │
│────────────────────────────────────────────────│
│  ${green}17.${plain} 启用开机自启                              │
│  ${green}18.${plain} 关闭开机自启                              │
│────────────────────────────────────────────────│
│  ${green}19.${plain} SSL 证书管理                              │
│  ${green}20.${plain} Cloudflare SSL 证书                       │
│  ${green}21.${plain} IP 限制管理                               │
│  ${green}22.${plain} 防火墙管理                                │
│  ${green}23.${plain} SSH 端口转发管理                          │
│────────────────────────────────────────────────│
│  ${green}24.${plain} 启用 BBR                                  │
│  ${green}25.${plain} 更新 Geo 数据文件                         │
│  ${green}26.${plain} Ookla 网络测速                            │
╚────────────────────────────────────────────────╝
"
    echo " 27. 一键诊断（含证书与续期状态）"
    echo " 28. 放行指定节点 TCP 端口"
    show_status
    echo && read -rp "请输入选项编号 [0-28]：" num

    case "${num}" in
        0)
            exit 0
            ;;
        1)
            check_uninstall && install
            ;;
        2)
            check_install && update
            ;;
        3)
            check_install && update_menu
            ;;
        4)
            check_install && legacy_version
            ;;
        5)
            check_install && uninstall
            ;;
        6)
            check_install && reset_user
            ;;
        7)
            check_install && reset_webbasepath
            ;;
        8)
            check_install && reset_config
            ;;
        9)
            check_install && set_port
            ;;
        10)
            check_install && check_config
            ;;
        11)
            check_install && start
            ;;
        12)
            check_install && stop
            ;;
        13)
            check_install && restart
            ;;
        14)
            check_install && restart_xray
            ;;
        15)
            check_install && status
            ;;
        16)
            check_install && show_log
            ;;
        17)
            check_install && enable
            ;;
        18)
            check_install && disable
            ;;
        19)
            ssl_cert_issue_main
            ;;
        20)
            ssl_cert_issue_CF
            ;;
        21)
            iplimit_main
            ;;
        22)
            firewall_menu
            ;;
        23)
            SSH_port_forwarding
            ;;
        24)
            bbr_menu
            ;;
        25)
            update_geo
            ;;
        27) diagnose; before_show_menu ;;
        28) open_node_port; before_show_menu ;;
        26)
            run_speedtest
            ;;
        *)
            LOGE "请输入正确的编号 [0-28]"
            ;;
    esac
}

load_ssl_helpers() {
    local lib="$xui_folder/scripts/lib/ssl.sh"
    [[ -s "$lib" ]] || { echo '缺少证书组件，请先选择菜单 2 完整更新。'; return 1; }
    source "$lib"
}

ssl_cert_issue_main() {
    load_ssl_helpers || return 1
    local info port path host
    info=$("$xui_folder/x-ui" setting -show true) || return 1
    port=$(printf '%s\n' "$info" | sed -n 's/^port: *//p')
    path=$(printf '%s\n' "$info" | sed -n 's/^webBasePath: *//p')
    read -rp '请输入本机公网 IPv4 地址：' host
    if prompt_and_setup_ssl "$port" "$path" "$host"; then
        if [[ "$release" == alpine ]]; then rc-service x-ui restart; else systemctl restart x-ui; fi
    else
        echo '证书设置未完成，现有服务未主动停止。'
        return 1
    fi
}

diagnose() {
    bash "$xui_folder/scripts/diagnose.sh"
}

open_node_port() {
    load_ssl_helpers || return 1
    local port answer
    read -rp '需要放行的 TCP 节点端口（1—65535）：' port
    [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || { echo '端口无效。'; return 1; }
    read -rp "确认永久放行 TCP $port？[y/N]：" answer
    [[ "$answer" == y || "$answer" == Y ]] || return 0
    open_ssl_port "$port"
}

if [[ $# > 0 ]]; then
    case $1 in
        "diagnose") diagnose ;;
        "open-node-port") open_node_port ;;
        "start")
            check_install 0 && start 0
            ;;
        "stop")
            check_install 0 && stop 0
            ;;
        "restart")
            check_install 0 && restart 0
            ;;
        "restart-xray")
            check_install 0 && restart_xray 0
            ;;
        "status")
            check_install 0 && status 0
            ;;
        "settings")
            check_install 0 && check_config 0
            ;;
        "enable")
            check_install 0 && enable 0
            ;;
        "disable")
            check_install 0 && disable 0
            ;;
        "log")
            check_install 0 && show_log 0
            ;;
        "banlog")
            check_install 0 && show_banlog 0
            ;;
        "update")
            check_install 0 && update 0
            ;;
        "legacy")
            check_install 0 && legacy_version 0
            ;;
        "install")
            check_uninstall 0 && install 0
            ;;
        "uninstall")
            check_install 0 && uninstall 0
            ;;
        "update-all-geofiles")
            check_install 0 && update_all_geofiles 0 && restart 0
            ;;
        *) show_usage ;;
    esac
else
    show_menu
fi
