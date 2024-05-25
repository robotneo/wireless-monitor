#!/bin/bash
set -e

# 函数：安装依赖工具
install_dependencies() {
    if [ "$OS" == "ubuntu" ] || [ "$OS" == "debian" ]; then
        apt-get update && apt-get install -y curl wget net-tools
    elif [ "$OS" == "centos" ]; then
        yum update && yum install -y curl wget net-tools
    else
        echo "Unsupported operating system."
        exit 1
    fi
}

# 函数：设置系统服务和用户
setup_system() {
    # 创建vminsert配置文件目录
    mkdir -p /etc/victoriametrics/vminsert

    # 检查victoriametrics组是否存在，不存在则创建
    if ! getent group victoriametrics > /dev/null 2>&1; then
        groupadd --system victoriametrics
    fi

    # 检查victoriametrics用户是否存在，不存在则创建
    if ! id -u victoriametrics > /dev/null 2>&1; then
        useradd --system --home-dir /var/lib/victoriametrics --no-create-home --gid victoriametrics victoriametrics
    fi
}

# 确定操作系统类型
OS="unknown"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
fi

# 安装依赖工具
install_dependencies

# 设置系统服务和用户
setup_system

# 获取VictoriaMetrics集群最新版本
VM_VERSION=$(curl -s "https://api.github.com/repos/VictoriaMetrics/VictoriaMetrics/tags" | grep '"name":' | head -n 1 | awk -F '"' '{print $4}')
# 下载并安装VictoriaMetrics集群
wget https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/${VM_VERSION}/victoria-metrics-linux-amd64-${VM_VERSION}-cluster.tar.gz -O /tmp/vmcluster.tar.gz

cd /tmp && tar -xzvf /tmp/vmcluster.tar.gz vminsert-prod
mv /tmp/vminsert-prod /usr/bin
chmod +x /usr/bin/vminsert-prod

cat> /etc/systemd/system/vminsert.service <<EOF
[Unit]
Description=vminsert - accepts the ingested data and spreads it among vmstorage nodes according to consistent hashing over metric name and all its labels
# https://docs.victoriametrics.com/Cluster-VictoriaMetrics.html
After=network.target

[Service]
Type=simple
User=victoriametrics
Group=victoriametrics
StartLimitBurst=5
StartLimitInterval=0
Restart=on-failure
RestartSec=1
EnvironmentFile=-/etc/victoriametrics/vminsert/vminsert.conf
ExecStart=/usr/bin/vminsert-prod $ARGS
ExecStop=/bin/kill -s SIGTERM $MAINPID
ExecReload=/bin/kill -HUP $MAINPID
# See docs https://docs.victoriametrics.com/Single-server-VictoriaMetrics.html#tuning
LimitNOFILE=1048576
LimitNPROC=1048576
LimitCORE=infinity
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=vminsert
PrivateTmp=yes
ProtectHome=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectControlGroups=true
ProtectKernelModules=true
ProtectKernelTunables=yes


[Install]
WantedBy=multi-user.target
EOF

cat> /etc/victoriametrics/vminsert/vminsert.conf <<EOF
ARGS="-storageNode=127.0.0.1:8400 -replicationFactor=2"
EOF

chown -R victoriametrics:victoriametrics /etc/victoriametrics/vminsert

systemctl enable vminsert.service
systemctl restart vminsert.service
ps aux | grep vminsert

echo "vminsert installation and service setup complete."
