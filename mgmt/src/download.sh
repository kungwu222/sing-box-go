get_latest_version() {
    case $1 in
    core)
        name=$is_core_name
        url="https://api.github.com/repos/${is_core_repo}/releases/latest?v=$RANDOM"
        ;;
    sh)
        name="$is_core_name 脚本"
        url="https://api.github.com/repos/$is_sh_repo/releases/latest?v=$RANDOM"
        ;;
    caddy)
        name="Caddy"
        url="https://api.github.com/repos/$is_caddy_repo/releases/latest?v=$RANDOM"
        ;;
    esac
    latest_ver=$(_wget -qO- $url | grep tag_name | grep -E -o 'v([0-9.]+)')
    [[ ! $latest_ver ]] && {
        err "获取 ${name} 最新版本失败."
    }
    unset name url
}
download() {
    if [[ "$1" == sh ]]; then
        command -v sbgo >/dev/null 2>&1 || { err "vendored bundle updates require sbgo install-mgmt"; return 1; }
        sbgo install-mgmt
        return $?
    fi
    latest_ver=$2
    [[ ! $latest_ver ]] && get_latest_version $1
    # tmp dir
    local tmpdir tmpfile link repo asset binary target unit metadata digest installed active=false replacement
    tmpdir=$(mktemp -d) || { err "cannot create download staging directory"; return 1; }
    case $1 in
    core)
        name=$is_core_name
        tmpfile=$tmpdir/$is_core.tar.gz
        link="https://github.com/${is_core_repo}/releases/download/${latest_ver}/${is_core}-${latest_ver:1}-linux-${is_arch}.tar.gz"
        repo=$is_core_repo; target=$is_core_bin; unit=$is_core
        ;;
    caddy)
        name="Caddy"
        tmpfile=$tmpdir/caddy.tar.gz
        # https://github.com/caddyserver/caddy/releases/download/v2.6.4/caddy_2.6.4_linux_amd64.tar.gz
        link="https://github.com/${is_caddy_repo}/releases/download/${latest_ver}/caddy_${latest_ver:1}_linux_${is_arch}.tar.gz"
        repo=$is_caddy_repo; target=$is_caddy_bin; unit=caddy
        ;;
    *)
        rm -rf "$tmpdir"; err "unknown download component: $1"; return 1
        ;;
    esac
    download_file || return 1
    asset=${link##*/}
    metadata=$(_wget -qO- "https://api.github.com/repos/$repo/releases/tags/$latest_ver") \
        || { rm -rf "$tmpdir"; err "cannot fetch release checksum metadata"; return 1; }
    digest=$(jq -er --arg name "$asset" '.assets[] | select(.name == $name) | .digest | select(type == "string" and startswith("sha256:")) | ltrimstr("sha256:")' <<<"$metadata") \
        || { rm -rf "$tmpdir"; err "release has no published SHA256 checksum"; return 1; }
    installed=$(openssl dgst -sha256 "$tmpfile") || { rm -rf "$tmpdir"; return 1; }
    [[ "$digest" =~ ^[[:xdigit:]]{64}$ && "${installed##* }" == "${digest,,}" ]] \
        || { rm -rf "$tmpdir"; err "download checksum mismatch"; return 1; }
    local entry listing
    listing=$(tar tzf "$tmpfile") || { rm -rf "$tmpdir"; return 1; }
    while IFS= read -r entry; do
        [[ "$entry" != /* && "$entry" != *\\* && "/$entry/" != *"/../"* ]] \
            || { rm -rf "$tmpdir"; err "unsafe archive member"; return 1; }
    done <<<"$listing"
    listing=$(tar tvzf "$tmpfile") || { rm -rf "$tmpdir"; return 1; }
    if grep -qE '^[lh]' <<<"$listing"; then rm -rf "$tmpdir"; err "archive links are not supported"; return 1; fi
    mkdir -p "$tmpdir/pkg" || return 1
    if [[ "$1" == core ]]; then
        tar zxf "$tmpfile" --strip-components 1 -C "$tmpdir/pkg" || { rm -rf "$tmpdir"; return 1; }
        binary="$tmpdir/pkg/$is_core"
        "$binary" check -c "$is_config_json" -C "$is_conf_dir" > "$tmpdir/check.log" 2>&1 \
            || { cat "$tmpdir/check.log" >&2; rm -rf "$tmpdir"; err "new core does not accept installed configuration"; return 1; }
    else
        tar zxf "$tmpfile" -C "$tmpdir/pkg" || { rm -rf "$tmpdir"; return 1; }
        binary="$tmpdir/pkg/caddy"
        if [[ -f "$is_caddyfile" ]]; then
            "$binary" validate --config "$is_caddyfile" --adapter caddyfile > "$tmpdir/check.log" 2>&1 \
                || { cat "$tmpdir/check.log" >&2; rm -rf "$tmpdir"; err "new Caddy configuration check failed"; return 1; }
        fi
    fi
    [[ -x "$binary" ]] || { rm -rf "$tmpdir"; err "downloaded binary missing"; return 1; }
    load service.sh || { rm -rf "$tmpdir"; err "service readiness helper unavailable"; return 1; }
    if [[ -f "$target" ]]; then cp -a "$target" "$tmpdir/previous" || return 1; fi
    systemctl is-active --quiet "$unit" && active=true
    replacement=$(mktemp "${target}.XXXXXX") || return 1
    cp -f "$binary" "$replacement" && chmod +x "$replacement" && mv -f "$replacement" "$target" \
        || { rm -f "$replacement"; rm -rf "$tmpdir"; err "binary installation failed"; return 1; }
    if [[ "$active" == true ]] && { ! systemctl restart "$unit" || ! wait_service_ready "$unit"; }; then
        if [[ -f "$tmpdir/previous" ]]; then
            replacement=$(mktemp "${target}.XXXXXX") || return 1
            cp -a "$tmpdir/previous" "$replacement" && mv -f "$replacement" "$target" \
                || { err "binary rollback failed; backup: $tmpdir"; return 1; }
            systemctl restart "$unit" && wait_service_ready "$unit" \
                || { err "previous binary restored, restart failed; backup: $tmpdir"; return 1; }
        else rm -f "$target"; fi
        rm -rf "$tmpdir"; err "update activation failed; previous binary restored"; return 1
    fi
    rm -rf "$tmpdir"
    unset latest_ver
    return 0
}
download_file() {
    if ! _wget -t 5 -c $link -O $tmpfile; then
        rm -rf $tmpdir
        err "\n下载 ${name} 失败.\n"
    fi
}
