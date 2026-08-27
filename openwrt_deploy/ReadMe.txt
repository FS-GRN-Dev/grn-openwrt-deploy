openwrt_deploy.zip 是用于在openwrt上部署grn-client的压缩包

openwrt_deploy目录结构如下：
    root@GL-MT6000:~/openwrt_deploy# ls -l
    -rw-r--r--    1 root     root       4540896 Aug 27 15:27 GRN_Node.zip
    -rw-r--r--    1 root     root          7997 Aug 27 17:07 ReadMe.txt
    drwxr-xr-x    2 root     root          3488 Jun  2 15:46 certs
    -rw-r--r--    1 root     root         89425 Aug 19 09:48 dist.zip
    -rw-r--r--    1 root     root      17878421 Aug 19 20:54 docker-compose_2.39.1-r1_aarch64_cortex-a53.ipk
    -rw-r--r--    1 root     root       8519300 Aug 19 20:50 docker_27.3.1-r1_aarch64_cortex-a53.ipk
    -rw-r--r--    1 root     root      20557780 Aug 19 20:48 dockerd_27.3.1-r3_aarch64_cortex-a53.ipk
    -r--r--r--    1 root     root      70931456 Aug 18 17:00 grn-tor.tar
    -rw-r--r--    1 root     root      64339387 May 12 09:26 mt6000-op-4.8.3-op24_beta1-911-1108-1762535859.bin
    -rw-r--r--    1 root     root          2166 Aug 19 17:09 openwrt-nginx.conf
    -rw-r--r--    1 root     root     218303504 May 13 16:04 openwrt-sdk-24.10.4-mediatek-filogic_gcc-13.3.0_musl.Linux-x86_64.tar.zst
    -rw-r--r--    1 root     root         27693 Aug 20 18:40 openwrt_grn_deploy.sh
    -rw-r--r--    1 root     root        222326 Aug 20 15:36 python3-base_3.11.14-r1_aarch64_cortex-a53.ipk
    -rw-r--r--    1 root     root         69776 May 13 17:44 python3-curl_7.45.2-r3_aarch64_cortex-a53.ipk
    -rw-r--r--    1 root     root       2886561 Aug 20 15:37 python3-light_3.11.14-r1_aarch64_cortex-a53.ipk
    -rw-r--r--    1 root     root         85150 Aug 20 15:37 python3-logging_3.11.14-r1_aarch64_cortex-a53.ipk
    -rw-r--r--    1 root     root       2847130 Aug 20 15:37 python3-pip_23.3.1-r1_aarch64_cortex-a53.ipk
    -rw-r--r--    1 root     root          1469 Aug 20 15:17 python3_3.11.14-r1_aarch64_cortex-a53.ipk
    -rw-r--r--    1 root     root      14472165 Aug 19 16:12 sing-box_1.12.22-r1_aarch64_cortex-a53.ipk
    root@GL-MT6000:~/openwrt_deploy#



openwrt_grn_deploy.sh：部署撤收脚本

管理面后端IP、Http端口、grpc 端口, 例如：36.134.47.29 8888　50051

部署命令：sh openwrt_grn_deploy.sh deploy 36.134.47.29 8888 50051

无痕撤收命令：sh openwrt_grn_deploy.sh cleanup






下面是各个部署步骤用到的命令：


1. 部署本地前端
    a> mkdir -p /www/grn_client
    b> chmod -R 755 /www/grn_client
    c> cd /www/grn_client
    d> cp /root/openwrt_deploy/dist.zip /www/grn_client
    e> unzip dist.zip


2. 创建 Nginx 配置
    a> cp /root/openwrt_deploy/openwrt-nginx.conf /etc/nginx/conf.d
    b> cd /etc/nginx/conf.d
    c> mv openwrt-nginx.conf grn_client.conf
    d> sed -i 's/your_server_ip:8080/36.134.205.22:8888/g' /etc/nginx/conf.d/grn_client.conf


3. 生成 Nginx TLS 证书
    a> mkdir -p /etc/nginx/ssl
    b> cd /etc/nginx/ssl
    c> openssl ecparam -genkey -name secp256r1 -out nginx.key -noout
    d> chmod 600 nginx.key
    e> openssl req -new -key nginx.key -out nginx.csr -subj "/C=CN/ST=Henan/L=Zhengzhou/O=GRN/OU=IT/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:192.168.8.1"
    f> openssl x509 -req -in nginx.csr -CA /root/openwrt_deploy/certs/ca.crt -CAkey /root/openwrt_deploy/certs/ca.key -CAcreateserial -out nginx.crt -days 3650 -sha256 -extfile <(echo "subjectAltName=DNS:localhost,IP:192.168.8.1")
    g> nginx -t
    h> /etc/init.d/nginx restart


4. 部署GRN_Node
    1> 安装 Docker
        a> opkg update
        b> opkg install docker dockerd docker-compose

    2> 启动 Docker 服务
        a> /etc/init.d/dockerd enable
        b> /etc/init.d/dockerd start

    3> 解压 GRN_Node.zip
        a> cd /root
        b> cp /root/openwrt_deploy/GRN_Node.zip /root
        c> unzip GRN_Node.zip

    4> 安装python3
        a> opkg install python3 python3-pip python3-logging

    5> 安装python虚拟环境
        a> cd /root
        b> pip3 install --no-cache-dir virtualenv
        c> virtualenv venv
        d> source venv/bin/activate

    6> 安装依赖
        a> pip install wheel
        b> pip install grpcio==1.78.0 -i https://mirrors.aliyun.com/pypi/simple/ --extra-index-url https://www.piwheels.org/simple --only-binary=:all: --no-build-isolation
        c> pip install grpcio-tools==1.78.0 -i https://mirrors.aliyun.com/pypi/simple/ --extra-index-url https://www.piwheels.org/simple --only-binary=:all: --no-build-isolation
        d> pip install psutil==7.2.0 -i https://mirrors.aliyun.com/pypi/simple/ --extra-index-url https://www.piwheels.org/simple --only-binary=:all: --no-build-isolation

    7> GRN_Node下的requirements.txt中的pycurl注释掉，修改psutil的版本为7.2.0
        a> cd /root/GRN_Node/
        b> sed -i 's/psutil==7.0.0/psutil==7.2.0/g' requirements.txt
        c> pip install --no-cache-dir -r requirements.txt

    8> openwrt安装python3-curl
        a> cd /root
        b> opkg install /root/openwrt_deploy/python3-curl_7.45.2-r3_aarch64_cortex-a53.ipk

    9> 添加系统模块路径到虚拟环境
        a> cd venv/lib/python3.11/site-packages/
        b> echo "/usr/lib/python3.11/site-packages/" > sys_packages.pth

    10> 导入镜像
        a> cd /root/openwrt_deploy
        b> docker load -i grn-tor.tar

    11> 修改docker网络模式（bridge-->host）
        a> cd /root
        b> sed -i 's/DEFAULT_NETWORK_MODE = "bridge"/DEFAULT_NETWORK_MODE = "host"/g' /root/GRN_Node/src/config/config.py


5. 安装sing-box
    1> 安装sing-box
        a> cd /root
        b> opkg install sing-box


6. 部署Supervisor监控node_client.py运行
    1> 安装Supervisor到venv下
        a> cd /root
        b> source /root/venv/bin/activate
        c> pip install supervisor

    2> 生成supervisor配置目录与主配置
        a> mkdir -p /etc/supervisor/conf.d /var/log/supervisor
        b> /root/venv/bin/echo_supervisord_conf > /etc/supervisor/supervisord.conf

    3> 修改 /etc/supervisor/supervisord.conf
        a> cd /root
        b> sed -i -e 's|file=/tmp/supervisor.sock|file=/var/run/supervisor.sock|' -e 's|;chmod=0700|chmod=0700|' -e 's|logfile=/tmp/supervisord.log|logfile=/var/log/supervisor/supervisord.log|' -e 's|pidfile=/tmp/supervisord.pid|pidfile=/var/run/supervisord.pid|' -e 's|;childlogdir=/tmp|childlogdir=/var/log/supervisor|' -e 's|serverurl=unix:///tmp/supervisor.sock|serverurl=unix:///var/run/supervisor.sock|' -e '/^\[include\]/,/^files =/d' -e '$a\[include]\nfiles = /etc/supervisor/conf.d/*.conf' /etc/supervisor/supervisord.conf

    4> 配置 node_client 程序
        a> cat > /etc/supervisor/conf.d/node_client.conf << 'EOF'
[program:node_client]
command=/root/venv/bin/python /root/GRN_Node/src/core/node_client.py -s 36.134.205.22:50051 -r openwrt
directory=/root/GRN_Node
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
environment=VIRTUAL_ENV="/root/venv",PATH="/root/venv/bin:%(ENV_PATH)s",PYTHONPATH="/root/GRN_Node/src"
EOF
        b> /root/venv/bin/supervisorctl reread
        c> /root/venv/bin/supervisorctl update

    5> 用 OpenWrt procd init 拉起 supervisord（开机自启）
        a> cat > /etc/init.d/supervisord << 'EOF'
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

    6> supervisord添加权限并开机自启
        a> chmod +x /etc/init.d/supervisord
        b> /etc/init.d/supervisord enable
        c> /etc/init.d/supervisord start
