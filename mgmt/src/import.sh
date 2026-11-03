is_xray_sh=/etc/xray/sh/src/core.sh
is_v2ray_sh=/etc/v2ray/sh/src/core.sh
is_xray_conf=/etc/xray/conf
is_v2ray_conf=/etc/v2ray/conf
in_conf() {
    local input="$1" source_security v
    unset is_config_file is_new_protocol json_str is_add_public_key is_use_tls is_socks is_reality
    is_conf_args=$(jq -c '[.inbounds[0]|.protocol,.port,(.settings|(.clients[0]|.id,.password),.method,.password,.port,.address,(.accounts[0]|.user,.pass)),(.streamSettings|.network,.security,.tcpSettings.header.type,(.wsSettings|.path,.headers.Host),(.httpSettings|.path,.host[0]),(.realitySettings|.serverNames[0],.publicKey,.privateKey)),.tag]' "$input") \
        || { warn "无法读取此文件: $input"; return 1; }
    is_up_var_set=(is_protocol port uuid trojan_password ss_method ss_password door_port door_addr is_socks_user is_socks_pass net source_security net_type ws_path ws_host h2_path h2_host is_servername is_public_key is_private_key is_node_name)
    i=0
    for v in "${is_up_var_set[@]}"; do
        printf -v "$v" '%s' "$(jq -r --argjson i "$i" '.[$i] // empty' <<<"$is_conf_args")"
        ((i++))
    done
    [[ -n "$is_node_name" ]] || is_node_name=$(basename "$input" .json)
    password="$trojan_password"
    path="${ws_path}${h2_path}"
    host="${ws_host}${h2_host}"
    [[ ! $uuid ]] && uuid=$trojan_password
    if [[ $host ]]; then
        if [[ $is_caddy && -f $is_caddy_conf/$host.conf ]]; then
            tmp_tlsport=$(grep -E -o "$host:[1-9][0-9]?+" $is_caddy_conf/$host.conf | sed s/.*://)
        fi
        [[ $tmp_tlsport ]] && https_port=$tmp_tlsport
        add "$is_protocol-$net-tls" "$host" "$uuid" "$path" || { warn "导入失败，保留: $input"; return 1; }
    else
        case $is_protocol in
        vmess | vless)
            [[ $net_type == "http" ]] && {
                net=http
                is_tips_msg="新配置文件名: (VMess-HTTP-$port.json)"
            }
            if [[ "$source_security" == reality ]]; then net=reality
            elif [[ "$is_protocol" == vless && "$net" == tcp ]]; then net=vlesstcp; fi
            add "$net" "$port" || { warn "导入失败，保留: $input"; return 1; }
            ;;
        dokodemo-door)
            add door "$port" || { warn "导入失败，保留: $input"; return 1; }
            is_tips_msg="新配置文件名: (Direct-$port.json)"
            ;;
        *socks*)
            add "$is_protocol" "$port" || { warn "导入失败，保留: $input"; return 1; }
            ;;
        *)
            warn "不支持导入 $input"
            return 1
            ;;

        esac
    fi
    rm -f "$input" || return 1
    msg "导入: $input $is_tips_msg"
    return 0
}
is_change=1
is_dont_auto_exit=1
is_dont_test_host=1
if [[ -f $is_xray_sh && -d $is_xray_conf ]]; then
    is_list=($(ls $is_xray_conf | grep .json | grep -E -iv 'kcp|grpc|dynamic|quic' | sed "s#^#$is_xray_conf/#"))
fi
if [[ -f $is_v2ray_sh && -d $is_v2ray_conf ]]; then
    is_list+=($(ls $is_v2ray_conf | grep .json | grep -E -iv 'kcp|grpc|dynamic|quic' | sed "s#^#$is_v2ray_conf/#"))
fi
[[ ${is_list[@]} =~ "xray" ]] && is_xray_in=1
[[ ${is_list[@]} =~ "v2ray" ]] && is_v2ray_in=1
[[ $is_xray_in ]] && xray stop
[[ $is_v2ray_in ]] && v2ray stop
if [[ ${is_list[@]} ]]; then
    msg "开始导入配置..."
    is_import_failed=0
    for i in "${is_list[@]}"; do
        # Each conversion owns one complete validate/replace/activate transaction.
        (in_conf "$i") || is_import_failed=1
    done
    is_dont_auto_exit=
    manage restart &
    [[ $is_xray_in ]] && xray restart &
    [[ $is_v2ray_in ]] && v2ray restart &
    [[ ${is_list[@],,} =~ "tls" && $is_caddy ]] && manage restart caddy &
    [[ "$is_import_failed" == 0 ]] || return 1

else
    err "没有找到可导入的配置..."
fi
