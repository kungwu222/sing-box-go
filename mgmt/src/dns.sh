is_dns_list=(
    1.1.1.1
    8.8.8.8
    h3://dns.google/dns-query
    h3://cloudflare-dns.com/dns-query
    h3://family.cloudflare-dns.com/dns-query
    set
    none
)
dns_set() {
    if [[ $(echo -e "1.11.99\n$is_core_ver" | sort -V | head -n1) == '1.11.99' ]]; then
        is_dns_new=1
    fi
    if [[ $1 ]]; then
        case ${1,,} in
        11 | 1111)
            is_dns_use=${is_dns_list[0]}
            ;;
        88 | 8888)
            is_dns_use=${is_dns_list[1]}
            ;;
        gg | google)
            is_dns_use=${is_dns_list[2]}
            ;;
        cf | cloudflare)
            is_dns_use=${is_dns_list[3]}
            ;;
        nosex | family)
            is_dns_use=${is_dns_list[4]}
            ;;
        set)
            if [[ $2 ]]; then
                is_dns_use=${2,,}
            else
                ask string is_dns_use "请输入 DNS: "
            fi
            ;;
        none)
            is_dns_use=none
            ;;
        *)
            err "无法识别 DNS 参数: $@"
            ;;
        esac
    else
        is_tmp_list=(${is_dns_list[@]})
        ask list is_dns_use null "\n请选择 DNS:\n"
        if [[ $is_dns_use == "set" ]]; then
            ask string is_dns_use "请输入 DNS: "
        fi
    fi
    is_dns_use_bak=$is_dns_use
    local json
    if [[ $is_dns_use == "none" ]]; then
        json=$(jq '.dns={}' "$is_config_json") || { err "cannot generate DNS configuration"; return 1; }
    else
        if [[ $is_dns_new ]]; then
            dns_set_server $is_dns_use
            [[ "$is_dns_type" != h3 ]] || is_dns_type=http3
            json=$(jq --arg type "$is_dns_type" --arg server "$is_dns_use" '.dns.servers=[{type:$type,server:$server,domain_resolver:"local"},{tag:"local",type:"local"}]' "$is_config_json") || { err "cannot generate DNS configuration"; return 1; }
        else
            json=$(jq --arg address "$is_dns_use" '.dns.servers=[{address:$address,address_resolver:"local"},{tag:"local",address:"local"}]' "$is_config_json") || { err "cannot generate DNS configuration"; return 1; }
        fi
    fi
    replace_config "$is_config_json" "$json" || return 1
    msg "\n已更新 DNS 为: $(_green $is_dns_use_bak)\n"
}
dns_set_server() {
    if [[ $(grep '://' <<<$1) ]]; then
        is_tmp_dns_set=($(awk -F '://|/' '{print $1, $2}' <<<${1,,}))
        case ${is_tmp_dns_set[0]} in
        tcp | udp | tls | https | quic | h3)
            is_dns_use=${is_tmp_dns_set[1]}
            is_dns_type=${is_tmp_dns_set[0]}
            ;;
        *)
            err "无法识别 DNS 类型!"
            ;;
        esac
    else
        is_dns_use=$1
        is_dns_type=udp
    fi
}
