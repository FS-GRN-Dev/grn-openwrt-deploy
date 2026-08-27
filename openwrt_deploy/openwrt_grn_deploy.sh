#!/bin/sh
# OpenWrt GRN 一键部署 / 无痕撤收脚本
# 用法:
#   ./openwrt_grn_deploy.sh deploy  <管理面IP> <HTTP端口> <gRPC端口>
#   ./openwrt_grn_deploy.sh cleanup
# 示例:
#   ./openwrt_grn_deploy.sh deploy 36.134.205.22 8888 50051
#   ./openwrt_grn_deploy.sh cleanup
#
# cleanup = 无痕撤收：卸载部署安装的全部包，并删除部署/运行创建的全部目录与文件
# （含 /www/grn_client、/etc/nginx/ssl、/root/GRN_Node、/root/venv、
#  /home（node_client 运行日志）、/etc/supervisor、Docker 数据目录、
#  /opt/local、/tmp/grn-sing-box 等）
# 保留部署源包目录 /root/openwrt_deploy（及本脚本本身）

set -eu

ACTION="${1:-}"
MGMT_IP="${2:-}"
HTTP_PORT="${3:-}"
GRPC_PORT="${4:-}"
HTTP_BACKEND=""
GRPC_BACKEND=""

DEPLOY_ROOT="/root/openwrt_deploy"
WWW_DIR="/www/grn_client"
NGINX_CONF_SRC="${DEPLOY_ROOT}/openwrt-nginx.conf"
NGINX_CONF_DST="/etc/nginx/conf.d/grn_client.conf"
NGINX_SSL_DIR="/etc/nginx/ssl"
CA_CRT="${DEPLOY_ROOT}/certs/ca.crt"
CA_KEY="${DEPLOY_ROOT}/certs/ca.key"
GRN_ZIP="${DEPLOY_ROOT}/GRN_Node.zip"
GRN_DIR="/root/GRN_Node"
VENV_DIR="/root/venv"
TOR_TAR="${DEPLOY_ROOT}/grn-tor.tar"
CURL_IPK="${DEPLOY_ROOT}/python3-curl_7.45.2-r3_aarch64_cortex-a53.ipk"
CONFIG_PY="${GRN_DIR}/src/config/config.py"
REQ_TXT="${GRN_DIR}/requirements.txt"
SUPERVISORD_CONF="/etc/supervisor/supervisord.conf"
NODE_CLIENT_CONF="/etc/supervisor/conf.d/node_client.conf"
SUPERVISORD_INIT="/etc/init.d/supervisord"
NODE_CLIENT_PY="${GRN_DIR}/src/core/node_client.py"
# 部署状态文件：记录本次创建的目录/文件，供无痕 cleanup
STATE_FILE="/root/.grn_deploy_state"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo
}

# OpenWrt / GL.iNet 的 /etc/init.d/* 常会打印 "uci: Entry not found"
#（脚本里用 uci get 读可选配置，项不存在就报这句）。多数可忽略；
# 本脚本开了 set -e，若不吞掉会导致 deploy 中途退出。
run_initd() {
    set +e
    _out="$("$@" 2>&1)"
    _rc=$?
    set -e
    if [ -n "${_out}" ]; then
        printf '%s\n' "${_out}"
    fi
    if [ "${_rc}" -eq 0 ]; then
        return 0
    fi
    _filtered="$(printf '%s\n' "${_out}" | grep -v 'uci: Entry not found' | grep -v '^[[:space:]]*$' || true)"
    if [ -z "${_filtered}" ]; then
        log "WARN: $* 仅有 uci: Entry not found（可忽略），继续"
        return 0
    fi
    return "${_rc}"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
用法:
  openwrt_grn_deploy.sh deploy  <管理面IP> <HTTP端口> <gRPC端口>
  openwrt_grn_deploy.sh cleanup

参数说明:
  管理面IP   例如 36.134.205.22
  HTTP端口   Nginx 反代到管理面 HTTP 的端口，例如 8888
  gRPC端口   node_client 连接管理面 gRPC 的端口，例如 50051

示例:
  ./openwrt_grn_deploy.sh deploy 36.134.205.22 8888 50051
  ./openwrt_grn_deploy.sh cleanup

前提:
  部署包目录已存在: /root/openwrt_deploy
  且包含 dist.zip / openwrt-nginx.conf / certs / GRN_Node.zip /
       grn-tor.tar / python3-curl_*.ipk 等文件
  可选离线 ipk（有则优先本地安装，无则 opkg 在线）:
       docker_*.ipk / dockerd_*.ipk / docker-compose_*.ipk
       python3-base_*.ipk / python3-light_*.ipk / python3_*.ipk /
       python3-logging_*.ipk / python3-pip_*.ipk
       sing-box_*.ipk

cleanup 无痕撤收会删除:
  /www/grn_client, /etc/nginx/ssl, /etc/nginx/conf.d/grn_client.conf,
  /root/GRN_Node, /root/venv, /home（含 /home/node-test 运行日志）,
  /etc/supervisor, Docker 数据目录, /opt/local, /tmp/grn-sing-box 等
  （保留 /root/openwrt_deploy）
EOF
}

require_file() {
    [ -f "$1" ] || die "缺少文件: $1"
}

require_dir() {
    [ -d "$1" ] || die "缺少目录: $1"
}

# 探测对端 TCP 端口（BusyBox nc 仅支持: nc IP PORT，不能加 -w 等参数）
# - 不通：立刻 Connection refused，nc 非 0 退出
# - 通且挂住：进程仍在 → 可达
# - 通但对端马上断开（HTTP 常见）：nc 以 0 退出 → 也算可达
tcp_port_open() {
    _host="$1"
    _port="$2"
    [ -n "${_host}" ] && [ -n "${_port}" ] || return 1

    if ! command -v nc >/dev/null 2>&1; then
        return 2
    fi

    nc "${_host}" "${_port}" </dev/null >/dev/null 2>&1 &
    _ncpid=$!
    sleep 1
    if kill -0 "${_ncpid}" 2>/dev/null; then
        # 仍在跑 = 已连上（与手工 nc 挂住一致）
        kill "${_ncpid}" 2>/dev/null || true
        wait "${_ncpid}" 2>/dev/null || true
        return 0
    fi
    # 已退出：看退出码。0=曾连通（对端立刻关连接）；非 0=拒绝/失败
    set +e
    wait "${_ncpid}"
    _ncrc=$?
    set -e
    if [ "${_ncrc}" -eq 0 ]; then
        return 0
    fi
    return 1
}

# 探测对端 IP 是否通（ping）
peer_ip_reachable() {
    _host="$1"
    [ -n "${_host}" ] || return 1
    if ! command -v ping >/dev/null 2>&1; then
        return 2
    fi
    # BusyBox: -c 次数, -W 单次等待秒数
    ping -c 2 -W 2 "${_host}" >/dev/null 2>&1
}

# 先查 IP，再查 HTTP/gRPC 端口；任一失败则部署中止
require_peer_ports_open() {
    [ -n "${MGMT_IP}" ] || die "管理面 IP 为空"
    [ -n "${HTTP_PORT}" ] || die "HTTP 端口为空"
    [ -n "${GRPC_PORT}" ] || die "gRPC 端口为空"

    log "检查对端 IP 是否可达: ${MGMT_IP}"
    set +e
    peer_ip_reachable "${MGMT_IP}"
    _ip_rc=$?
    set -e
    if [ "${_ip_rc}" -eq 2 ]; then
        die "无法检测 IP：系统缺少 ping 命令"
    fi
    if [ "${_ip_rc}" -ne 0 ]; then
        die "IP 不通: ${MGMT_IP}（可能输入了错误的管理面 IP，或对端禁 ping/网络不通）"
    fi
    log "对端 IP ${MGMT_IP} 可达"

    if ! command -v nc >/dev/null 2>&1; then
        die "无法检测端口：系统缺少 nc 命令"
    fi

    log "检查对端端口是否开启: ${MGMT_IP}:${HTTP_PORT} / ${MGMT_IP}:${GRPC_PORT}"
    _http_ok=0
    _grpc_ok=0
    _failed=""

    if tcp_port_open "${MGMT_IP}" "${HTTP_PORT}"; then
        log "对端 HTTP ${MGMT_IP}:${HTTP_PORT} 可达"
        _http_ok=1
    else
        log "对端 HTTP ${MGMT_IP}:${HTTP_PORT} 不可达，可能输入了错误的 HTTP 端口"
        _failed="${_failed} ${MGMT_IP}:${HTTP_PORT}"
    fi

    if tcp_port_open "${MGMT_IP}" "${GRPC_PORT}"; then
        log "对端 gRPC ${MGMT_IP}:${GRPC_PORT} 可达"
        _grpc_ok=1
    else
        log "对端 gRPC ${MGMT_IP}:${GRPC_PORT} 不可达，可能输入了错误的 gRPC 端口"
        _failed="${_failed} ${MGMT_IP}:${GRPC_PORT}"
    fi

    if [ "${_http_ok}" -eq 0 ] || [ "${_grpc_ok}" -eq 0 ]; then
        die "端口未开启:${_failed}（请核对 deploy 参数中的 HTTP/gRPC 端口是否正确）"
    fi
}

run_or_warn() {
    # cleanup 场景：单步失败不中断，且不刷屏
    if "$@" >/dev/null 2>&1; then
        return 0
    fi
    log "WARN: 命令失败(忽略继续): $*"
    return 0
}

pkg_installed() {
    opkg list-installed 2>/dev/null | awk '{print $1}' | grep -qx "$1"
}

opkg_remove_if_installed() {
    _any=0
    for _pkg in "$@"; do
        if pkg_installed "${_pkg}"; then
            log "卸载包: ${_pkg}"
            _any=1
        fi
    done
    if [ "${_any}" -eq 0 ]; then
        return 0
    fi
    opkg remove --force-depends "$@" >/dev/null 2>&1 || true
}

# 在 DEPLOY_ROOT 下按包名查找离线 ipk：<name>_*.ipk
find_deploy_ipk() {
    _name="$1"
    _found=""
    for _f in "${DEPLOY_ROOT}/${_name}_"*.ipk; do
        [ -f "${_f}" ] || continue
        _found="${_f}"
        break
    done
    if [ -n "${_found}" ]; then
        printf '%s\n' "${_found}"
        return 0
    fi
    return 1
}

# 临时关掉 opkg 源，避免离线装包时仍去 downloads.openwrt.org 拉同名包
opkg_feeds_disable() {
    for _feed in /etc/opkg/distfeeds.conf /etc/opkg/customfeeds.conf; do
        if [ -f "${_feed}" ]; then
            mv -f "${_feed}" "${_feed}.grn-bak"
        fi
    done
}

opkg_feeds_restore() {
    for _bak in /etc/opkg/distfeeds.conf.grn-bak /etc/opkg/customfeeds.conf.grn-bak; do
        if [ -f "${_bak}" ]; then
            mv -f "${_bak}" "${_bak%.grn-bak}"
        fi
    done
}

# 优先离线安装 DEPLOY_ROOT 中的 ipk；缺的再 opkg 在线安装。
# 参数：按依赖顺序传入包名，例如: dockerd docker docker-compose
opkg_install_prefer_local() {
    _label="$1"
    shift
    [ "$#" -gt 0 ] || die "opkg_install_prefer_local: 未指定包名"

    # 若上次异常中断留下了 .grn-bak，先恢复
    opkg_feeds_restore

    _online_list=""
    _pkg=""
    _ipk=""
    _had_local=0

    # 先逐个装本地 ipk（关掉 feeds，防止同名包被在线覆盖/下载）
    for _pkg in "$@"; do
        if _ipk="$(find_deploy_ipk "${_pkg}")"; then
            if [ "${_had_local}" -eq 0 ]; then
                opkg_feeds_disable
                _had_local=1
            fi
            log "[${_label}] 离线安装 ${_pkg} <- ${_ipk}"
            # --force-depends：依赖包若稍后才装本地 ipk，避免因已关 feeds 解析失败
            if ! opkg install --force-depends "${_ipk}"; then
                opkg_feeds_restore
                die "[${_label}] 离线安装失败: ${_ipk}"
            fi
        else
            log "[${_label}] 未找到 ${_pkg} 离线包，将在线安装"
            _online_list="${_online_list} ${_pkg}"
        fi
    done
    if [ "${_had_local}" -eq 1 ]; then
        opkg_feeds_restore
    fi

    if [ -n "${_online_list}" ]; then
        opkg update || log "WARN: opkg update 失败，仍尝试在线安装"
        # shellcheck disable=SC2086
        opkg install ${_online_list} || die "[${_label}] 在线安装失败:${_online_list}"
    fi
}

# 补齐 dockerd UCI（GL 上 Configuring 时常见 uci: Entry not found，导致起不来）
ensure_dockerd_ready() {
    mkdir -p /opt/docker /var/run
    track_dir /opt/docker

    if [ ! -f /etc/config/dockerd ]; then
        log "写入默认 /etc/config/dockerd"
        cat > /etc/config/dockerd <<'EOF'
config globals 'globals'
	option data_root '/opt/docker'
	option log_level 'warn'
	option bip '172.18.0.1/24'
	list hosts 'unix:///var/run/docker.sock'
EOF
    fi

    # 确保关键字段存在（已有配置则 uci set 覆盖/补齐）
    uci -q set dockerd.globals=globals || true
    uci -q set dockerd.globals.data_root='/opt/docker' || true
    uci -q set dockerd.globals.log_level='warn' || true
    if ! uci -q get dockerd.globals.hosts >/dev/null 2>&1; then
        uci -q add_list dockerd.globals.hosts='unix:///var/run/docker.sock' || true
    fi
    uci -q commit dockerd || true

    run_initd /etc/init.d/dockerd enable || true
    run_initd /etc/init.d/dockerd restart || run_initd /etc/init.d/dockerd start || true

    _i=0
    while [ "${_i}" -lt 15 ]; do
        if docker info >/dev/null 2>&1; then
            log "dockerd 已就绪"
            return 0
        fi
        _i=$((_i + 1))
        sleep 2
    done

    log "dockerd 诊断信息："
    /etc/init.d/dockerd status 2>&1 || true
    docker info 2>&1 || true
    logread 2>/dev/null | grep -i docker | tail -n 40 || true
    die "dockerd 未就绪（docker info 失败）"
}

state_reset() {
    rm -f "${STATE_FILE}"
    touch "${STATE_FILE}"
}

# 若路径原先不存在，mkdir 后记入状态，cleanup 时整目录删除
ensure_dir_tracked() {
    _path="$1"
    if [ ! -e "${_path}" ]; then
        mkdir -p "${_path}"
        echo "DIR|${_path}" >> "${STATE_FILE}"
    else
        mkdir -p "${_path}"
    fi
}

# 记录本脚本将创建/覆盖的文件（cleanup 时删除）
track_file() {
    echo "FILE|$1" >> "${STATE_FILE}"
}

# 记录本脚本管理的目录（cleanup 时 rm -rf）
track_dir() {
    echo "DIR|$1" >> "${STATE_FILE}"
}

rm_path_logged() {
    _p="$1"
    if [ -e "${_p}" ] || [ -L "${_p}" ]; then
        rm -rf "${_p}"
        log "已删除 ${_p}"
    fi
}

# 按状态文件 + 固定清单做无痕清理
cleanup_tracked_paths() {
    log "=== [cleanup] 清理部署创建的目录/文件 ==="

    # 1) 状态文件记录（后写先删）
    if [ -f "${STATE_FILE}" ]; then
        # 倒序处理
        awk '{a[NR]=$0} END{for(i=NR;i>=1;i--) print a[i]}' "${STATE_FILE}" | while IFS= read -r line; do
            _kind="${line%%|*}"
            _path="${line#*|}"
            [ -n "${_path}" ] || continue
            case "${_kind}" in
                DIR|FILE)
                    rm_path_logged "${_path}"
                    ;;
            esac
        done
    fi

    # 2) 固定清单兜底（即使状态文件丢失也能无痕）
    #    覆盖：部署脚本创建的目录 + 节点运行后产生的目录
    for _p in \
        "${WWW_DIR}" \
        "${NGINX_CONF_DST}" \
        /etc/nginx/conf.d/openwrt-nginx.conf \
        "${NGINX_SSL_DIR}" \
        "${GRN_DIR}" \
        "${VENV_DIR}" \
        /root/GRN_Node.zip \
        /etc/supervisor \
        /var/log/supervisor \
        /var/run/supervisor.sock \
        /var/run/supervisord.pid \
        "${SUPERVISORD_INIT}" \
        /etc/sing-box \
        /etc/config/sing-box \
        /opt/docker \
        /var/lib/docker \
        /etc/docker \
        /opt/local \
        /tmp/grn-sing-box \
        /tmp/grn_nginx_san.ext \
        /root/.cache/pip \
        /root/.local \
        /home \
        "${STATE_FILE}"
    do
        rm_path_logged "${_p}"
    done
}

########################################
# 1. 本地前端
########################################
deploy_frontend() {
    log "=== [1/6] 部署本地前端 ==="
    require_file "${DEPLOY_ROOT}/dist.zip"
    ensure_dir_tracked "${WWW_DIR}"
    track_dir "${WWW_DIR}"
    chmod -R 755 "${WWW_DIR}"
    cp -f "${DEPLOY_ROOT}/dist.zip" "${WWW_DIR}/"
    cd "${WWW_DIR}"
    unzip -o dist.zip
    chmod -R 755 "${WWW_DIR}"
    log "前端已部署到 ${WWW_DIR}（nginx root 指向 ${WWW_DIR}/dist）"
}

cleanup_frontend() {
    log "=== [cleanup] 移除本地前端 ==="
    rm_path_logged "${WWW_DIR}"
}

########################################
# 2. Nginx 配置
########################################
deploy_nginx_conf() {
    log "=== [2/6] 创建 Nginx 配置 ==="
    require_file "${NGINX_CONF_SRC}"
    [ -n "${HTTP_BACKEND}" ] || die "HTTP 后端参数为空"

    ensure_dir_tracked /etc/nginx/conf.d
    cp -f "${NGINX_CONF_SRC}" /etc/nginx/conf.d/openwrt-nginx.conf
    mv -f /etc/nginx/conf.d/openwrt-nginx.conf "${NGINX_CONF_DST}"
    track_file "${NGINX_CONF_DST}"
    sed -i "s/your_server_ip:8080/${HTTP_BACKEND}/g" "${NGINX_CONF_DST}"
    log "Nginx 配置已写入 ${NGINX_CONF_DST} -> ${HTTP_BACKEND}"
}

cleanup_nginx_conf() {
    log "=== [cleanup] 移除 Nginx 站点配置 ==="
    rm_path_logged "${NGINX_CONF_DST}"
    rm_path_logged /etc/nginx/conf.d/openwrt-nginx.conf
}

########################################
# 3. Nginx TLS
########################################
deploy_nginx_tls() {
    log "=== [3/6] 生成 Nginx TLS 证书 ==="
    require_file "${CA_CRT}"
    require_file "${CA_KEY}"

    # 整个 ssl 目录由本部署管理，cleanup 时整目录删除（无痕）
    ensure_dir_tracked "${NGINX_SSL_DIR}"
    track_dir "${NGINX_SSL_DIR}"
    cd "${NGINX_SSL_DIR}"

    openssl ecparam -genkey -name secp256r1 -out nginx.key -noout
    chmod 600 nginx.key
    track_file "${NGINX_SSL_DIR}/nginx.key"
    openssl req -new -key nginx.key -out nginx.csr \
        -subj "/C=CN/ST=Henan/L=Zhengzhou/O=GRN/OU=IT/CN=localhost" \
        -addext "subjectAltName=DNS:localhost,IP:192.168.8.1"
    track_file "${NGINX_SSL_DIR}/nginx.csr"

    SAN_EXT="/tmp/grn_nginx_san.ext"
    echo "subjectAltName=DNS:localhost,IP:192.168.8.1" > "${SAN_EXT}"
    openssl x509 -req -in nginx.csr \
        -CA "${CA_CRT}" -CAkey "${CA_KEY}" -CAcreateserial \
        -out nginx.crt -days 3650 -sha256 -extfile "${SAN_EXT}"
    track_file "${NGINX_SSL_DIR}/nginx.crt"
    rm -f "${SAN_EXT}"

    nginx -t
    # GL.iNet nginx init 常刷 "uci: Entry not found"，不代表证书/配置失败
    run_initd /etc/init.d/nginx restart || log "WARN: nginx restart 返回非0，继续检查进程"
    pgrep -x nginx >/dev/null 2>&1 || die "nginx 未在运行，请检查 /etc/init.d/nginx / 配置"
    log "Nginx TLS 已配置并重启"
}

cleanup_nginx_tls() {
    log "=== [cleanup] 移除 Nginx TLS 目录并重启 ==="
    # 无痕：删除整个 ssl 目录（含本部署生成的 nginx.*）
    rm_path_logged "${NGINX_SSL_DIR}"
    rm_path_logged /tmp/grn_nginx_san.ext
    if [ -x /etc/init.d/nginx ]; then
        if nginx -t 2>/dev/null; then
            run_or_warn /etc/init.d/nginx restart
        else
            log "WARN: nginx -t 失败，仍尝试 restart"
            run_or_warn /etc/init.d/nginx restart
        fi
    fi
}

########################################
# 4. GRN_Node
########################################
deploy_grn_node() {
    log "=== [4/6] 部署 GRN_Node ==="
    require_file "${GRN_ZIP}"
    require_file "${TOR_TAR}"
    require_file "${CURL_IPK}"

    log "[4.1] 安装 Docker（优先离线 ipk）"
    opkg_install_prefer_local "docker" dockerd docker docker-compose

    log "[4.2] 启动 Docker"
    ensure_dockerd_ready

    log "[4.3] 解压 GRN_Node.zip"
    cd /root
    cp -f "${GRN_ZIP}" /root/
    track_file /root/GRN_Node.zip
    if [ -d "${GRN_DIR}" ]; then
        rm -rf "${GRN_DIR}"
    fi
    unzip -o /root/GRN_Node.zip
    [ -d "${GRN_DIR}" ] || die "解压后未找到 ${GRN_DIR}"
    track_dir "${GRN_DIR}"

    log "[4.4] 安装 python3（优先离线 ipk）"
    # 离线依赖顺序：base -> light -> logging -> python3 元包 -> pip
    # （pip 依赖 python3 元包）
    opkg_install_prefer_local "python" \
        python3-base python3-light python3-logging python3 python3-pip

    log "[4.5] 安装 python 虚拟环境"
    cd /root
    pip3 install --no-cache-dir virtualenv
    if [ -d "${VENV_DIR}" ]; then
        rm -rf "${VENV_DIR}"
    fi
    virtualenv "${VENV_DIR}"
    track_dir "${VENV_DIR}"
    # shellcheck disable=SC1091
    . "${VENV_DIR}/bin/activate"

    log "[4.6] 预装关键 wheel / grpc / psutil 二进制包"
    pip install wheel
    pip install grpcio==1.78.0 \
        -i https://mirrors.aliyun.com/pypi/simple/ \
        --extra-index-url https://www.piwheels.org/simple \
        --only-binary=:all: --no-build-isolation
    pip install grpcio-tools==1.78.0 \
        -i https://mirrors.aliyun.com/pypi/simple/ \
        --extra-index-url https://www.piwheels.org/simple \
        --only-binary=:all: --no-build-isolation
    pip install psutil==7.2.0 \
        -i https://mirrors.aliyun.com/pypi/simple/ \
        --extra-index-url https://www.piwheels.org/simple \
        --only-binary=:all: --no-build-isolation

    log "[4.7] 调整 requirements.txt 并安装依赖"
    cd "${GRN_DIR}"
    # 注释 pycurl（OpenWrt 用系统 python3-curl）
    sed -i -E 's/^[[:space:]]*pycurl/# pycurl/' "${REQ_TXT}"
    sed -i 's/psutil==7.0.0/psutil==7.2.0/g' "${REQ_TXT}"
    pip install --no-cache-dir -r "${REQ_TXT}"

    log "[4.8] 安装系统 python3-curl"
    cd /root
    opkg install "${CURL_IPK}"

    log "[4.9] 将系统 site-packages 挂入 venv"
    PY_SITE="$(ls -d "${VENV_DIR}"/lib/python*/site-packages 2>/dev/null | head -n 1)"
    [ -n "${PY_SITE}" ] || die "未找到 venv site-packages"
    # 探测系统 python3 site-packages
    SYS_SITE="/usr/lib/python3.11/site-packages"
    if [ ! -d "${SYS_SITE}" ]; then
        SYS_SITE="$(ls -d /usr/lib/python3.*/site-packages 2>/dev/null | head -n 1 || true)"
    fi
    [ -n "${SYS_SITE}" ] && [ -d "${SYS_SITE}" ] || die "未找到系统 python site-packages"
    echo "${SYS_SITE}/" > "${PY_SITE}/sys_packages.pth"
    log "已写入 ${PY_SITE}/sys_packages.pth -> ${SYS_SITE}/"

    log "[4.10] 导入 grn-tor 镜像"
    cd "${DEPLOY_ROOT}"
    docker load -i "${TOR_TAR}"
    # dockerd 数据目录
    track_dir /opt/docker
    track_dir /var/lib/docker
    track_dir /etc/docker

    log "[4.11] Docker 网络模式 bridge -> host"
    require_file "${CONFIG_PY}"
    sed -i 's/DEFAULT_NETWORK_MODE = "bridge"/DEFAULT_NETWORK_MODE = "host"/g' "${CONFIG_PY}"
    grep -q 'DEFAULT_NETWORK_MODE = "host"' "${CONFIG_PY}" || \
        die "修改 ${CONFIG_PY} 网络模式失败"

    log "GRN_Node 部署完成"
}

cleanup_grn_node() {
    log "=== [cleanup] 撤收 GRN_Node / venv / Docker / Python 包 ==="

    if command -v docker >/dev/null 2>&1; then
        docker ps -aq 2>/dev/null | while read -r cid; do
            [ -n "${cid}" ] || continue
            docker stop "${cid}" >/dev/null 2>&1 || true
            docker rm -f "${cid}" >/dev/null 2>&1 || true
        done
        docker images -q 2>/dev/null | while read -r iid; do
            [ -n "${iid}" ] || continue
            docker rmi -f "${iid}" >/dev/null 2>&1 || true
        done
    fi

    if [ -x /etc/init.d/dockerd ]; then
        /etc/init.d/dockerd stop >/dev/null 2>&1 || true
        /etc/init.d/dockerd disable >/dev/null 2>&1 || true
    fi

    rm_path_logged "${GRN_DIR}"
    rm_path_logged "${VENV_DIR}"
    rm_path_logged /root/GRN_Node.zip

    log "卸载 opkg 包: docker / python3 ..."
    opkg_remove_if_installed \
        docker-compose \
        docker \
        dockerd \
        luci-app-dockerman \
        luci-lib-docker \
        python3-curl \
        python3-pip \
        python3-logging \
        python3 \
        python3-light \
        python3-base

    for d in /opt/docker /var/lib/docker /etc/docker /opt/local /tmp/grn-sing-box; do
        rm_path_logged "${d}"
    done
    rm -rf /root/.cache/pip /root/.local 2>/dev/null || true

    log "GRN_Node / Docker / Python 相关清理完成"
}

########################################
# 5. sing-box
########################################
deploy_singbox() {
    log "=== [5/6] 安装 sing-box（优先离线 ipk）"
    opkg_install_prefer_local "sing-box" sing-box
    log "sing-box 安装完成"
}

cleanup_singbox() {
    log "=== [cleanup] 卸载 sing-box ==="
    opkg_remove_if_installed sing-box
    rm_path_logged /etc/sing-box
    rm_path_logged /etc/config/sing-box
    log "sing-box 及残留配置已清理"
}

########################################
# 6. Supervisor
########################################
deploy_supervisor() {
    log "=== [6/6] 部署 Supervisor 监控 node_client ==="
    [ -n "${GRPC_BACKEND}" ] || die "gRPC 后端参数为空"
    [ -x "${VENV_DIR}/bin/pip" ] || die "venv 不存在，请先完成 GRN_Node 部署"
    [ -f "${NODE_CLIENT_PY}" ] || die "缺少 ${NODE_CLIENT_PY}"

    # shellcheck disable=SC1091
    . "${VENV_DIR}/bin/activate"
    pip install supervisor

    ensure_dir_tracked /etc/supervisor/conf.d
    ensure_dir_tracked /var/log/supervisor
    mkdir -p /var/run
    track_dir /etc/supervisor
    track_dir /var/log/supervisor

    "${VENV_DIR}/bin/echo_supervisord_conf" > "${SUPERVISORD_CONF}"
    track_file "${SUPERVISORD_CONF}"

    sed -i \
        -e 's|file=/tmp/supervisor.sock|file=/var/run/supervisor.sock|' \
        -e 's|;chmod=0700|chmod=0700|' \
        -e 's|logfile=/tmp/supervisord.log|logfile=/var/log/supervisor/supervisord.log|' \
        -e 's|pidfile=/tmp/supervisord.pid|pidfile=/var/run/supervisord.pid|' \
        -e 's|;childlogdir=/tmp|childlogdir=/var/log/supervisor|' \
        -e 's|serverurl=unix:///tmp/supervisor.sock|serverurl=unix:///var/run/supervisor.sock|' \
        -e '/^\[include\]/,/^files =/d' \
        "${SUPERVISORD_CONF}"
    printf '\n[include]\nfiles = /etc/supervisor/conf.d/*.conf\n' >> "${SUPERVISORD_CONF}"

    cat > "${NODE_CLIENT_CONF}" <<EOF
[program:node_client]
command=${VENV_DIR}/bin/python ${NODE_CLIENT_PY} -s ${GRPC_BACKEND} -r openwrt
directory=${GRN_DIR}
autostart=true
autorestart=true
startsecs=5
startretries=10
stopwaitsecs=20
stopsignal=TERM
stopasgroup=true
killasgroup=true
redirect_stderr=true
stdout_logfile=/var/log/supervisor/node_client.log
stdout_logfile_maxbytes=5MB
stdout_logfile_backups=5
environment=VIRTUAL_ENV="${VENV_DIR}",PATH="${VENV_DIR}/bin:%(ENV_PATH)s",PYTHONPATH="${GRN_DIR}/src"
EOF
    track_file "${NODE_CLIENT_CONF}"

    cat > "${SUPERVISORD_INIT}" <<'EOF'
#!/bin/sh /etc/rc.common

START=99
STOP=10
USE_PROCD=1

BIN="/root/venv/bin/supervisord"
CONF="/etc/supervisor/supervisord.conf"

start_service() {
    mkdir -p /var/log/supervisor /var/run

    procd_open_instance
    procd_set_param command "$BIN" -n -c "$CONF"
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF
    track_file "${SUPERVISORD_INIT}"

    chmod +x "${SUPERVISORD_INIT}"

    run_initd /etc/init.d/supervisord enable || true
    run_initd /etc/init.d/supervisord start || die "supervisord 启动失败"
    sleep 2

    "${VENV_DIR}/bin/supervisorctl" reread || true
    "${VENV_DIR}/bin/supervisorctl" update || true
    "${VENV_DIR}/bin/supervisorctl" status || true

    log "Supervisor / node_client 已启动 (gRPC -> ${GRPC_BACKEND})"
}

cleanup_supervisor() {
    log "=== [cleanup] 停止并移除 Supervisor ==="

    if [ -x "${VENV_DIR}/bin/supervisorctl" ]; then
        "${VENV_DIR}/bin/supervisorctl" stop node_client >/dev/null 2>&1 || true
        "${VENV_DIR}/bin/supervisorctl" shutdown >/dev/null 2>&1 || true
    fi

    if [ -x "${SUPERVISORD_INIT}" ]; then
        /etc/init.d/supervisord stop >/dev/null 2>&1 || true
        /etc/init.d/supervisord disable >/dev/null 2>&1 || true
    fi

    rm_path_logged "${SUPERVISORD_INIT}"
    rm_path_logged /etc/supervisor
    rm_path_logged /var/log/supervisor
    rm_path_logged /var/run/supervisor.sock
    rm_path_logged /var/run/supervisord.pid
    # node_client.py 运行日志在 /home/node-test，无痕撤收直接清掉 /home
    rm_path_logged /home

    log "Supervisor 已撤收"
}

########################################
# 主流程
########################################
do_deploy() {
    [ -n "${MGMT_IP}" ] || die "deploy 需要管理面 IP，例如 36.134.205.22"
    [ -n "${HTTP_PORT}" ] || die "deploy 需要 HTTP 端口，例如 8888"
    [ -n "${GRPC_PORT}" ] || die "deploy 需要 gRPC 端口，例如 50051"
    HTTP_BACKEND="${MGMT_IP}:${HTTP_PORT}"
    GRPC_BACKEND="${MGMT_IP}:${GRPC_PORT}"
    require_dir "${DEPLOY_ROOT}"

    state_reset
    log "开始部署 IP=${MGMT_IP} HTTP=${HTTP_BACKEND} gRPC=${GRPC_BACKEND}"
    require_peer_ports_open
    deploy_frontend
    deploy_nginx_conf
    deploy_nginx_tls
    deploy_grn_node
    deploy_singbox
    track_dir /etc/sing-box
    track_file /etc/config/sing-box
    deploy_supervisor
    log "======= 部署全部完成 ======="
    log "前端目录: ${WWW_DIR}"
    log "Nginx 配置: ${NGINX_CONF_DST}"
    log "Nginx SSL: ${NGINX_SSL_DIR}"
    log "GRN_Node: ${GRN_DIR}"
    log "venv: ${VENV_DIR}"
    log "node_client gRPC: ${GRPC_BACKEND}"
    log "部署状态文件: ${STATE_FILE}"
}

do_cleanup() {
    log "开始无痕撤收（卸载包 + 删除部署/运行创建的全部目录与文件）"
    cleanup_supervisor
    cleanup_singbox
    cleanup_grn_node
    cleanup_nginx_conf
    cleanup_nginx_tls
    cleanup_frontend
    # 兜底：状态文件 + 固定清单（含 /etc/nginx/ssl、/opt/local、/tmp/grn-sing-box 等）
    cleanup_tracked_paths
    log "======= 无痕撤收完成 ======="
}

main() {
    case "${ACTION}" in
        deploy)
            do_deploy
            ;;
        cleanup|clean|undeploy)
            do_cleanup
            ;;
        -h|--help|help|"")
            usage
            [ -n "${ACTION}" ] || exit 1
            exit 0
            ;;
        *)
            usage
            die "未知操作: ${ACTION}"
            ;;
    esac
}

main
