#!/usr/bin/env bash
# 管理指定网卡上的附加 IPv6 地址。
set -o pipefail

CONFIG_DIR=/etc/ipv6-manager
CONFIG=$CONFIG_DIR/addresses
INTERFACE_FILE=$CONFIG_DIR/interface
PROGRAM=/usr/local/sbin/ipv6-manager
SERVICE=/etc/systemd/system/ipv6-manager.service

cyan= green= yellow= red= bold= reset=
if [[ -t 1 && ${TERM:-dumb} != dumb && ! ${NO_COLOR+x} ]]; then
    cyan=$'\033[36m' green=$'\033[32m' yellow=$'\033[33m'
    red=$'\033[31m' bold=$'\033[1m' reset=$'\033[0m'
fi

fail() { printf '%s错误：%s%s\n' "$red" "$*" "$reset" >&2; return 1; }

show_page() {
    if [[ -t 0 && -t 1 && ${TERM:-dumb} != dumb ]]; then
        printf '\033[2J\033[H'
    fi
    printf '\n%s%s  %s%s\n' "$bold" "$cyan" "$1" "$reset"
    printf '%s  ──────────────────────────────────%s\n\n' "$cyan" "$reset"
}

check_address() {
    [[ $1 =~ ^[0-9a-fA-F:]+/[0-9]{1,3}$ && ${1%/*} == *:* ]] || return 1
    (( 10#${1#*/} <= 128 ))
}

interface_exists() { ip link show dev "$1" >/dev/null 2>&1; }

address_info() {
    ip -6 -o addr show dev "$interface" to "${1%/*}/128" 2>/dev/null
}

wait_ready() {
    local address=$1 info n
    for ((n=0; n<60; n++)); do
        info=$(address_info "$address") || return 1
        if [[ $info == *dadfailed* ]]; then
            fail "$address 重复地址检测失败"
            return 1
        fi
        if [[ -n $info && $info != *tentative* ]]; then return 0; fi
        sleep 0.5
    done
    fail "$address 等待就绪超时"
}

load_config() {
    interface=
    [[ ! -f $INTERFACE_FILE ]] || IFS= read -r interface < "$INTERFACE_FILE" || true
    [[ -z $interface || $interface =~ ^[a-zA-Z0-9_.-]{1,15}$ ]] || fail '网卡配置无效'
}

apply_addresses() {
    local address info added
    load_config || return 1
    [[ -n $interface ]] || return 0
    interface_exists "$interface" || { fail "网卡 $interface 不存在"; return 1; }
    [[ -f $CONFIG ]] || return 0
    while IFS= read -r address || [[ -n $address ]]; do
        [[ -n $address ]] || continue
        check_address "$address" || { fail "配置中地址无效：$address"; return 1; }
        info=$(address_info "$address") || return 1
        added=0
        if [[ -n $info ]]; then
            # 已存在的地址必须与保存的前缀长度一致。
            [[ $info =~ inet6[[:space:]]+[^[:space:]]+/${address#*/}[[:space:]] ]] || {
                fail "$address 已存在但前缀长度不同"; return 1;
            }
        else
            ip -6 addr add "$address" dev "$interface" || return 1
            added=1
        fi
        if ! wait_ready "$address"; then
            (( added == 0 )) || ip -6 addr del "$address" dev "$interface" || true
            return 1
        fi
    done < "$CONFIG"
}

install_tool() {
    local source_path
    source_path=$(readlink -f -- "$0") || return 1
    if [[ -e $PROGRAM && $source_path != "$PROGRAM" ]] &&
       ! grep -Fq '# 管理指定网卡上的附加 IPv6 地址。' "$PROGRAM"; then
        fail "$PROGRAM 已存在，请检查文件后再安装"; return 1
    fi
    if [[ -e $SERVICE ]] && ! grep -Fxq 'Description=IPv6 manager persistent addresses' "$SERVICE"; then
        fail "$SERVICE 已存在，请检查文件后再安装"; return 1
    fi
    mkdir -p -m 700 "$CONFIG_DIR" || return 1
    if [[ $source_path != "$PROGRAM" ]]; then
        install -m 755 -- "$source_path" "$PROGRAM" || return 1
    fi
    cat > "$SERVICE" <<'EOF'
[Unit]
Description=IPv6 manager persistent addresses
Wants=networking.service
After=networking.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ipv6-manager --apply
RemainAfterExit=yes
TimeoutStartSec=infinity

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable ipv6-manager.service
}

manage() {
    local choice value address info selected temp index installed show_result=0
    while true; do
        if [[ -t 0 && -t 1 ]]; then
            if (( show_result )); then
                printf '\n'
                read -r -p '  按回车返回主菜单...' value || return 0
            fi
        fi
        show_result=0
        load_config || return 1
        show_page 'IPv6 地址管理'
        if [[ -n $interface ]]; then
            printf '  网卡     %s%s%s\n' "$bold" "$interface" "$reset"
        else
            printf '  网卡     %s未设置%s\n' "$yellow" "$reset"
        fi
        if [[ -f $SERVICE ]] && grep -Fxq 'Description=IPv6 manager persistent addresses' "$SERVICE"; then
            installed=1
            printf '  状态     %s已安装%s\n' "$green" "$reset"
        else
            installed=0
            printf '  状态     %s未安装%s\n' "$yellow" "$reset"
        fi
        printf '%s  ──────────────────────────────────%s\n' "$cyan" "$reset"
        printf '  %s1%s  查看地址\n  %s2%s  添加地址\n  %s3%s  删除地址\n' "$cyan" "$reset" "$cyan" "$reset" "$cyan" "$reset"
        printf '  %s4%s  设置网卡\n  %s5%s  重新应用\n' "$cyan" "$reset" "$cyan" "$reset"
        printf '\n'
        if (( installed )); then
            printf '  %s7%s  完全卸载\n' "$cyan" "$reset"
        else
            printf '  %s6%s  安装\n' "$cyan" "$reset"
        fi
        printf '  %s0%s  退出\n\n' "$cyan" "$reset"
        read -r -p '  请选择：' choice || return 0
        show_result=1
        case $choice in
            1) show_page '查看地址' ;;
            2) show_page '添加地址' ;;
            3) show_page '删除地址' ;;
            4) show_page '设置网卡' ;;
            5) show_page '重新应用地址' ;;
            6) show_page '安装' ;;
            7) show_page '完全卸载' ;;
        esac
        if [[ $choice =~ ^[2345]$ ]] && { [[ ! -f $SERVICE ]] || ! grep -Fxq 'Description=IPv6 manager persistent addresses' "$SERVICE"; }; then
            printf '请先选择 6 安装。\n'; continue
        fi
        case $choice in
        0) return 0 ;;
        6)
            (( installed == 0 )) || { printf '已经安装。\n'; continue; }
            read -r -p '安装命令及开机服务？[y/N]：' value || return 0
            [[ $value == [yY] ]] || { show_result=0; continue; }
            if install_tool; then printf '%s安装完成。%s\n' "$green" "$reset"; else printf '%s安装失败，请检查上面的错误。%s\n' "$red" "$reset"; fi ;;
        7)
            (( installed )) || { printf '未发现本工具安装的服务。\n'; continue; }
            if systemctl show -p Requires -p Wants --value warp-go.service wg-quick@wgcf.service 2>/dev/null | grep -qw 'ipv6-manager.service'; then
                printf 'WARP 服务正在依赖此服务，请先在 cf 的开机 IPv6 兼容菜单关闭关联。\n'; continue
            fi
            printf '将删除本工具管理的地址、配置、命令和开机服务。\n'
            read -r -p '确认完全卸载？[y/N]：' value || return 0
            [[ $value == [yY] ]] || { show_result=0; continue; }
            if [[ -s $CONFIG ]]; then
                [[ -n $interface ]] && interface_exists "$interface" || { printf '网卡不可用，请恢复网卡后重试。\n'; continue; }
                while IFS= read -r address || [[ -n $address ]]; do
                    [[ -n $address ]] || continue
                    check_address "$address" || { fail '地址配置无效'; break; }
                    info=$(address_info "$address") || break
                    if [[ -n $info ]]; then
                        [[ $info =~ inet6[[:space:]]+[^[:space:]]+/${address#*/}[[:space:]] ]] || { fail "$address 前缀已变化"; break; }
                        ip -6 addr del "$address" dev "$interface" || break
                    fi
                done < "$CONFIG"
                if [[ -n $address ]]; then printf '地址清理未完成，请检查后重试。\n'; continue; fi
            fi
            systemctl disable --now ipv6-manager.service || { printf '服务停用失败。\n'; continue; }
            rm -f -- "$SERVICE" "$PROGRAM" "$CONFIG" "$INTERFACE_FILE" || { printf '文件清理失败。\n'; continue; }
            rmdir -- "$CONFIG_DIR" 2>/dev/null || true
            systemctl daemon-reload || { printf 'systemd 重载失败。\n'; continue; }
            printf '%s卸载完成。%s\n' "$green" "$reset"
            return 0 ;;
        1)
            printf '本工具管理的地址：\n'
            if [[ -s $CONFIG ]]; then nl -ba "$CONFIG"; else printf '  暂无\n'; fi
            if [[ -n $interface ]]; then
                printf '\n网卡当前 IPv6：\n'
                ip -6 -br addr show dev "$interface"
            fi ;;
        4)
            if [[ -s $CONFIG ]]; then
                printf '请先删除本工具管理的全部地址，再更换网卡。\n'; continue
            fi
            read -r -p '网卡名称 [eth0]：' value || return 0
            value=${value:-eth0}
            if [[ ! $value =~ ^[a-zA-Z0-9_.-]{1,15}$ ]] || ! interface_exists "$value"; then
                printf '网卡不存在或名称无效。\n'; continue
            fi
            temp=$(mktemp "$CONFIG_DIR/.interface.XXXXXX") || continue
            if printf '%s\n' "$value" > "$temp" && mv -f -- "$temp" "$INTERFACE_FILE"; then
                printf '%s网卡已设置为 %s。%s\n' "$green" "$value" "$reset"
            else
                rm -f -- "$temp"
                fail '保存网卡设置失败'
            fi
            ;;
        2)
            [[ -n $interface ]] || { printf '请先设置网卡。\n'; continue; }
            read -r -p 'IPv6 地址（不填前缀默认 /128）：' address || return 0
            [[ $address == */* ]] || address+=/128
            check_address "$address" || { printf '地址或前缀格式无效。\n'; continue; }
            info=$(address_info "$address") || { printf '读取网卡失败。\n'; continue; }
            [[ -z $info ]] || { printf '地址已在网卡上，本工具不会接管。\n'; continue; }
            ip -6 addr add "$address" dev "$interface" || continue
            if ! wait_ready "$address"; then
                ip -6 addr del "$address" dev "$interface" || true; continue
            fi
            temp=$(mktemp "$CONFIG_DIR/.addresses.XXXXXX") || {
                ip -6 addr del "$address" dev "$interface"; continue;
            }
            if { [[ ! -f $CONFIG ]] || cat "$CONFIG"; } > "$temp" &&
               printf '%s\n' "$address" >> "$temp" && mv -f -- "$temp" "$CONFIG"; then
                printf '%s地址已添加并保存。%s\n' "$green" "$reset"
            else
                rm -f -- "$temp"; ip -6 addr del "$address" dev "$interface"
                printf '保存失败，已尝试撤销添加。\n'
            fi ;;
        3)
            [[ -s $CONFIG ]] || { printf '没有可删除的地址。\n'; continue; }
            nl -ba "$CONFIG"
            read -r -p '选择删除的编号（回车取消）：' selected || return 0
            [[ -n $selected ]] || { show_result=0; continue; }
            [[ $selected =~ ^[1-9][0-9]{0,5}$ ]] || { printf '请输入有效编号。\n'; continue; }
            address=$(sed -n "${selected}p" "$CONFIG")
            [[ -n $address ]] && check_address "$address" || { printf '编号或配置无效。\n'; continue; }
            read -r -p "删除 $address？[y/N]：" value || return 0
            [[ $value == [yY] ]] || { show_result=0; continue; }
            info=$(address_info "$address") || continue
            if [[ -n $info ]]; then
                [[ $info =~ inet6[[:space:]]+[^[:space:]]+/${address#*/}[[:space:]] ]] || { printf '地址前缀已变化，停止删除。\n'; continue; }
                ip -6 addr del "$address" dev "$interface" || continue
            fi
            temp=$(mktemp "$CONFIG_DIR/.addresses.XXXXXX") || {
                [[ -z $info ]] || ip -6 addr add "$address" dev "$interface"; continue;
            }
            if sed "${selected}d" "$CONFIG" > "$temp" && mv -f -- "$temp" "$CONFIG"; then
                printf '%s地址已删除并保存。%s\n' "$green" "$reset"
            else
                rm -f -- "$temp"
                [[ -z $info ]] || ip -6 addr add "$address" dev "$interface"
                printf '保存失败，已尝试恢复地址。\n'
            fi ;;
        5) apply_addresses && printf '%s已重新应用。%s\n' "$green" "$reset" ;;
        *) printf '请选择菜单中的数字。\n' ;;
        esac
    done
}

[[ $EUID == 0 ]] || { fail '请使用 root 运行'; exit 1; }
command -v ip >/dev/null && command -v systemctl >/dev/null && command -v flock >/dev/null || {
    fail '需要 ip、systemctl 和 flock'; exit 1;
}
exec 9>/run/ipv6-manager.lock || exit 1
flock -x 9 || exit 1
case ${1:-} in
    --apply) apply_addresses ;;
    '') manage ;;
    *) fail '用法：ipv6-manager [--apply]'; exit 1 ;;
esac
