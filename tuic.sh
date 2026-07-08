#!/bin/bash

export LANG=en_US.UTF-8

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

red(){
    echo -e "\033[31m\033[01m$1\033[0m"
}

green(){
    echo -e "\033[32m\033[01m$1\033[0m"
}

yellow(){
    echo -e "\033[33m\033[01m$1\033[0m"
}

# Detect the system and define package management commands.
REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora")
PACKAGE_UPDATE=("apt-get update" "apt-get update" "yum -y update" "yum -y update" "yum -y update")
PACKAGE_INSTALL=("apt -y install" "apt -y install" "yum -y install" "yum -y install" "yum -y install")
PACKAGE_REMOVE=("apt -y remove" "apt -y remove" "yum -y remove" "yum -y remove" "yum -y remove")
PACKAGE_UNINSTALL=("apt -y autoremove" "apt -y autoremove" "yum -y autoremove" "yum -y autoremove" "yum -y autoremove")

[[ $EUID -ne 0 ]] && red "Note: Please run the script as root." && exit 1

CMD=("$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)" "$(lsb_release -sd 2>/dev/null)" "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)" "$(grep . /etc/redhat-release 2>/dev/null)" "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')")

for i in "${CMD[@]}"; do
    SYS="$i" && [[ -n $SYS ]] && break
done

for ((int = 0; int < ${#REGEX[@]}; int++)); do
    [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]] && SYSTEM="${RELEASE[int]}" && [[ -n $SYSTEM ]] && break
done

[[ -z $SYSTEM ]] && red "Currently, your VPS operating system is not supported!" && exit 1

if [[ -z $(type -P curl) ]]; then
    if [[ ! $SYSTEM == "CentOS" ]]; then
        ${PACKAGE_UPDATE[int]}
    fi
    ${PACKAGE_INSTALL[int]} curl
fi

archAffix(){
    case "$(uname -m)" in
        x86_64 | amd64 ) echo 'amd64' ;;
        armv8 | arm64 | aarch64 ) echo 'arm64' ;;
        * ) red "Unsupported CPU architecture!" && exit 1 ;;
    esac
}

realip(){
    ip=$(curl -s4m8 ip.sb -k) || ip=$(curl -s6m8 ip.sb -k)
}

tuic_self_signed_cert(){
    cert_path="/root/tuic/selfsigned/cert.crt"
    key_path="/root/tuic/selfsigned/private.key"
    mkdir -p /root/tuic/selfsigned

    local openssl_conf="/root/tuic/selfsigned/openssl.cnf"
    local cert_cn="${ip:-localhost}"
    local ipv4=""
    local ipv6=""
    local alt_names=""
    local alt_index=1

    if [[ $cert_cn == *:* ]]; then
        ipv6="$cert_cn"
        ipv4=$(curl -s4m8 ip.sb -k)
    else
        ipv4="$cert_cn"
        ipv6=$(curl -s6m8 ip.sb -k)
    fi

    if [[ -n $ipv4 ]]; then
        alt_names+="IP.$alt_index = $ipv4"
        alt_names+=$'\n'
        ((alt_index++))
    fi

    if [[ -n $ipv6 && $ipv6 != $ipv4 ]]; then
        alt_names+="IP.$alt_index = $ipv6"
        alt_names+=$'\n'
        ((alt_index++))
    fi

    if [[ -z $alt_names ]]; then
        alt_names="IP.1 = 127.0.0.1"
    fi

    cat > "$openssl_conf" <<EOF
[ req ]
default_bits = 256
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = v3_req

[ dn ]
CN = $cert_cn

[ v3_req ]
subjectAltName = @alt_names

[ alt_names ]
$alt_names
EOF

    openssl ecparam -genkey -name prime256v1 -out "$key_path"
    openssl req -new -x509 -days 3650 -key "$key_path" -out "$cert_path" -config "$openssl_conf" -extensions v3_req

    if [[ ! -s $cert_path || ! -s $key_path ]]; then
        red "Failed to generate the local self-signed certificate."
        exit 1
    fi

    domain="$cert_cn"
}

check_ip(){
    warpv6=$(curl -s6m8 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
    warpv4=$(curl -s4m8 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
    if [[ $warpv4 =~ on|plus || $warpv6 =~ on|plus ]]; then
        wg-quick down wgcf >/dev/null 2>&1
        systemctl stop warp-go >/dev/null 2>&1
        realip
        systemctl start warp-go >/dev/null 2>&1
        wg-quick up wgcf >/dev/null 2>&1
    else
        realip
    fi
}

tuic_cert(){
    green "TUIC certificate setup options:"
    echo ""
    echo -e " ${GREEN}1.${PLAIN} Automatic self-signed certificate ${YELLOW}(recommended for VPSs without a domain)${PLAIN}"
    echo -e " ${GREEN}2.${PLAIN} ACME certificate with a domain"
    echo -e " ${GREEN}3.${PLAIN} Custom certificate path"
    echo ""
    read -rp "Please choose an option [1-3] [1]: " certInput
    certInput=${certInput:-1}

    if [[ $certInput == 3 ]]; then
        read -rp "Enter the path to the certificate file (crt): " cert_path
        yellow "Certificate file path: $cert_path"
        read -rp "Enter the path to the private key file (key): " key_path
        yellow "Private key file path: $key_path"
        read -rp "Enter the certificate domain or IP: " domain
        [[ -z $domain ]] && domain="$ip"
        yellow "Certificate identity: $domain"
    elif [[ $certInput == 2 ]]; then
        cert_path="/root/cert.crt"
        key_path="/root/private.key"
        if [[ -f /root/cert.crt && -f /root/private.key ]] && [[ -s /root/cert.crt && -s /root/private.key ]] && [[ -f /root/ca.log ]]; then
            domain=$(cat /root/ca.log)
            green "An existing certificate for domain $domain was found and will be reused."
        else
            WARPv4Status=$(curl -s4m8 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
            WARPv6Status=$(curl -s6m8 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
            if [[ $WARPv4Status =~ on|plus ]] || [[ $WARPv6Status =~ on|plus ]]; then
                wg-quick down wgcf >/dev/null 2>&1
                systemctl stop warp-go >/dev/null 2>&1
                realip
                wg-quick up wgcf >/dev/null 2>&1
                systemctl start warp-go >/dev/null 2>&1
            else
                realip
            fi
            
            read -rp "Enter the domain for the certificate: " domain
            if [[ -z $domain ]]; then
                yellow "No domain was entered. Falling back to a local self-signed certificate."
                tuic_self_signed_cert
                finaldomain="$domain"
                snidomain="$domain"
                return
            fi
            green "Entered domain: $domain" && sleep 1
            domainIP=$(dig @8.8.8.8 +time=2 +short "$domain" 2>/dev/null)
            if echo $domainIP | grep -q "network unreachable\|timed out" || [[ -z $domainIP ]]; then
                domainIP=$(dig @2001:4860:4860::8888 +time=2 aaaa +short "$domain" 2>/dev/null)
            fi
            if echo $domainIP | grep -q "network unreachable\|timed out" || [[ -z $domainIP ]] ; then
                red "Failed to resolve the domain IP. Please verify the domain name."
                yellow "Do you want to try a forced match?"
                green "1. Yes, try a forced match"
                green "2. No, exit the script"
                read -rp "Please choose an option [1-2]: " ipChoice
                if [[ $ipChoice == 1 ]]; then
                    yellow "Trying a forced match for the domain certificate application."
                else
                    red "Exiting the script."
                    exit 1
                fi
            fi
            
            if [[ $domainIP == $ip ]]; then
                ${PACKAGE_INSTALL[int]} curl wget sudo socat openssl
                if [[ $SYSTEM == "CentOS" ]]; then
                    ${PACKAGE_INSTALL[int]} cronie
                    systemctl start crond
                    systemctl enable crond
                else
                    ${PACKAGE_INSTALL[int]} cron
                    systemctl start cron
                    systemctl enable cron
                fi
                curl https://get.acme.sh | sh -s email=$(date +%s%N | md5sum | cut -c 1-16)@gmail.com
                source ~/.bashrc
                bash ~/.acme.sh/acme.sh --upgrade --auto-upgrade
                bash ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
                if [[ -n $(echo $ip | grep ":") ]]; then
                    bash ~/.acme.sh/acme.sh --issue -d ${domain} --standalone -k ec-256 --listen-v6 --insecure
                else
                    bash ~/.acme.sh/acme.sh --issue -d ${domain} --standalone -k ec-256 --insecure
                fi
                bash ~/.acme.sh/acme.sh --install-cert -d ${domain} --key-file /root/private.key --fullchain-file /root/cert.crt --ecc
                if [[ -f /root/cert.crt && -f /root/private.key ]] && [[ -s /root/cert.crt && -s /root/private.key ]]; then
                    echo $domain > /root/ca.log
                    sed -i '/--cron/d' /etc/crontab >/dev/null 2>&1
                    echo "0 0 * * * root bash /root/.acme.sh/acme.sh --cron -f >/dev/null 2>&1" >> /etc/crontab
                    green "Certificate installation succeeded. The certificate and private key have been saved under /root."
                    yellow "Certificate file path: /root/cert.crt"
                    yellow "Private key file path: /root/private.key"
                fi
            else
                red "The IP resolved for the domain does not match the actual VPS IP."
                green "Suggestions:"
                yellow "1. Make sure the Cloudflare proxy is disabled (DNS only). The same applies to other CDN or proxy settings."
                yellow "2. Verify that the IP in DNS really points to this VPS."
                yellow "3. The script may be outdated. Consider sharing a screenshot in the GitHub Issues, GitLab Issues, forums, or Telegram groups for help."
            fi
        fi
    else
        tuic_self_signed_cert
    fi

    finaldomain="$domain"
    snidomain="$domain"
}

tuic_port(){
    read -rp "Set the TUIC port [1-65535] (press Enter to choose a random port): " port
    [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)
    until [[ -z $(ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") ]]; do
        if [[ -n $(ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") ]]; then
            echo -e "${RED} $port ${PLAIN} is already in use by another process. Please choose another port."
            read -rp "Set the TUIC port [1-65535] (press Enter to choose a random port): " port
            [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)
        fi
    done
    yellow "The TUIC port will be: $port"
}

inst_tuv4(){
    check_ip

    if [[ ! ${SYSTEM} == "CentOS" ]]; then
        ${PACKAGE_UPDATE}
        ${PACKAGE_INSTALL} bind-utils
    fi
    ${PACKAGE_INSTALL} wget curl sudo dnsutils

    wget https://gitlab.com/Misaka-blog/tuic-script/-/raw/main/files/tuic-latest-linux-$(archAffix) -O /usr/local/bin/tuic
    if [[ -f "/usr/local/bin/tuic" ]]; then
        chmod +x /usr/local/bin/tuic
    else
        red "TUIC V4 core installation failed."
        exit 1
    fi

    tuic_cert
    tuic_port

    read -rp "Set the TUIC token (press Enter to generate a random value): " token
    [[ -z $token ]] && token=$(date +%s%N | md5sum | cut -c 1-8)

    green "Configuring TUIC..."

    mkdir /etc/tuic >/dev/null 2>&1
    cat << EOF > /etc/tuic/tuic.json
{
    "port": $port,
    "token": ["$token"],
    "certificate": "$cert_path",
    "private_key": "$key_path",
    "ip": "::",
    "congestion_controller": "bbr",
    "alpn": ["h3"]
}
EOF
    mkdir /root/tuic >/dev/null 2>&1
    cat << EOF > /root/tuic/tuic-client.json
{
    "relay": {
        "server": "$finaldomain",
        "port": $port,
        "token": "$token",
        "ip": "$ip",
        "congestion_controller": "bbr",
        "udp_relay_mode": "quic",
        "alpn": ["h3"],
        "disable_sni": false,
        "reduce_rtt": false,
        "max_udp_relay_packet_size": 1500
    },
    "local": {
        "port": 6080,
        "ip": "127.0.0.1"
    },
    "log_level": "off"
}
EOF
    cat << EOF > /root/tuic/tuic.txt
Sagernet and Shadowrocket configuration notes (all 6 items are required):
{
    Server address: $finaldomain
    Server port: $port
    Token: $token
    SNI: $snidomain
    ALPN: h3
    UDP relay: enabled
    UDP relay mode: QUIC
    Congestion control: bbr
    Skip server certificate verification: enabled
}
EOF
    cat << EOF > /root/tuic/clash-meta.yaml
mixed-port: 7890
external-controller: 127.0.0.1:9090
allow-lan: false
mode: rule
log-level: debug
ipv6: true
dns:
  enable: true
  listen: 0.0.0.0:53
  enhanced-mode: fake-ip
  nameserver:
    - 8.8.8.8
    - 1.1.1.1
    - 114.114.114.114

proxies:
  - name: Misaka-tuicV4
    server: $finaldomain
    port: $port
    type: tuic
    token: $token
    ip: $ip
    alpn: [h3]
    disable-sni: true
    reduce-rtt: true
    request-timeout: 8000
    udp-relay-mode: quic
    congestion-controller: bbr
    skip-cert-verify: true
    sni: $snidomain

proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - Misaka-tuicV4
      
rules:
  - GEOIP,CN,DIRECT
  - MATCH,Proxy
EOF
    
    url="tuic://$finaldomain:$port?password=$token&alpn=h3&mode=bbr#tuic-misaka"
    {
        echo "$url"
        echo
        echo "TLS certificate (PEM):"
        cat "$cert_path"
        echo
    } > /root/tuic/url.txt

    cat << EOF >/etc/systemd/system/tuic.service
[Unit]
Description=tuic Service
Documentation=https://gitlab.com/Misaka-blog/tuic-script
After=network.target
[Service]
User=root
ExecStart=/usr/local/bin/tuic -c /etc/tuic/tuic.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity
[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable tuic
    systemctl start tuic

    if [[ -n $(systemctl status tuic 2>/dev/null | grep -w active) && -f '/etc/tuic/tuic.json' ]]; then
        green "TUIC service started successfully."
    else
        red "TUIC service failed to start. Run systemctl status tuic, check the service logs, and then retry. The script will exit now." && exit 1
    fi

    showconf
}

unst_tuv4(){
    systemctl stop tuic
    systemctl disable tuic
    rm -f /etc/systemd/system/tuic.service /root/tuic.sh
    rm -rf /usr/local/bin/tuic /etc/tuic /root/tuic
    
    green "TUIC V4 has been completely uninstalled."
}

inst_tuv5(){
    if [[ $(tuic -v) == "0.8.5" ]]; then
        red "TUIC V4 is already installed. Please uninstall it before installing TUIC V5."
        exit 1
    fi

    check_ip

    if [[ ! ${SYSTEM} == "CentOS" ]]; then
        ${PACKAGE_UPDATE}
    fi
    ${PACKAGE_INSTALL} wget curl sudo

    wget https://gitlab.com/Misaka-blog/tuic-script/-/raw/main/files/tuic-server-latest-linux-$(archAffix) -O /usr/local/bin/tuic
    if [[ -f "/usr/local/bin/tuic" ]]; then
        chmod +x /usr/local/bin/tuic
    else
        red "TUIC V5 core installation failed."
        exit 1
    fi

    tuic_cert
    tuic_port

    read -rp "Set the TUIC UUID (press Enter to generate a random UUID): " uuid
    [[ -z $uuid ]] && uuid=$(cat /proc/sys/kernel/random/uuid)
    yellow "The TUIC UUID will be: $uuid"

    read -rp "Set the TUIC password (press Enter to generate a random value): " passwd
    [[ -z $passwd ]] && passwd=$(date +%s%N | md5sum | cut -c 1-8)
    yellow "The TUIC password will be: $passwd"

    green "Configuring TUIC..."

    mkdir /etc/tuic >/dev/null 2>&1
    cat << EOF > /etc/tuic/tuic.json
{
    "server": "[::]:$port",
    "users": {
        "$uuid": "$passwd"
    },
    "certificate": "$cert_path",
    "private_key": "$key_path",
    "congestion_control": "bbr",
    "alpn": ["h3"],
    "log_level": "warn"
}
EOF

    mkdir /root/tuic >/dev/null 2>&1
    cat << EOF > /root/tuic/tuic-client.json
{
    "relay": {
        "server": "$finaldomain:$port",
        "uuid": "$uuid",
        "password": "$passwd",
        "ip": "$ip",
        "congestion_control": "bbr",
        "alpn": ["h3"]
    },
    "local": {
        "server": "127.0.0.1:6080"
    },
    "log_level": "warn"
}
EOF
    cat << EOF > /root/tuic/tuic.txt
Sagernet, Nekobox, and Shadowrocket configuration notes (all 6 items are required):
{
    Server address: $finaldomain
    Server port: $port
    UUID: $uuid
    Password: $passwd
    SNI: $snidomain
    ALPN: h3
    UDP relay: enabled
    UDP relay mode: QUIC
    Congestion control: bbr
    Skip server certificate verification: enabled
}
EOF

    url="tuic://$uuid:$passwd@$finaldomain:$port?congestion_control=bbr&udp_relay_mode=quic&alpn=h3#tuicv5-misaka"
    {
        echo "$url"
        echo
        echo "TLS certificate (PEM):"
        cat "$cert_path"
        echo
    } > /root/tuic/url.txt

    cat << EOF > /root/tuic/clash-meta.yaml
mixed-port: 7890
external-controller: 127.0.0.1:9090
allow-lan: false
mode: rule
log-level: debug
ipv6: true
dns:
  enable: true
  listen: 0.0.0.0:53
  enhanced-mode: fake-ip
  nameserver:
    - 8.8.8.8
    - 1.1.1.1
    - 114.114.114.114

proxies:
  - name: Misaka-tuicV5
    server: $finaldomain
    port: $port
    type: tuic
    uuid: $uuid
    password: $passwd
    ip: $ip
    alpn: [h3]
    disable-sni: true
    reduce-rtt: true
    request-timeout: 8000
    udp-relay-mode: quic
    congestion-controller: bbr
    skip-cert-verify: true
    sni: $snidomain

proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - Misaka-tuicV5
      
rules:
  - GEOIP,CN,DIRECT
  - MATCH,Proxy
EOF

    cat << EOF >/etc/systemd/system/tuic.service
[Unit]
Description=tuic Service
Documentation=https://gitlab.com/Misaka-blog/tuic-script
After=network.target
[Service]
User=root
ExecStart=/usr/local/bin/tuic -c /etc/tuic/tuic.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable tuic
    systemctl start tuic
    
    if [[ -n $(systemctl status tuic 2>/dev/null | grep -w active) && -f '/etc/tuic/tuic.json' ]]; then
        green "TUIC service started successfully."
    else
        red "TUIC service failed to start. Run systemctl status tuic, check the service logs, and then retry. The script will exit now." && exit 1
    fi

    showconf
}

unst_tuv5(){
    systemctl stop tuic
    systemctl disable tuic
    rm -f /etc/systemd/system/tuic.service /root/tuic.sh
    rm -rf /usr/local/bin/tuic /etc/tuic /root/tuic
    
    green "TUIC V5 has been completely uninstalled."
}

starttuic(){
    systemctl start tuic
    systemctl enable tuic >/dev/null 2>&1
}

stoptuic(){
    systemctl stop tuic
    systemctl disable tuic >/dev/null 2>&1
}

tuicswitch(){
    yellow "Choose the action you want:"
    echo ""
    echo -e " ${GREEN}1.${PLAIN} Start TUIC"
    echo -e " ${GREEN}2.${PLAIN} Stop TUIC"
    echo -e " ${GREEN}3.${PLAIN} Restart TUIC"
    echo ""
    read -rp "Please choose an option [0-3]: " switchInput
    case $switchInput in
        1 ) starttuic ;;
        2 ) stoptuic ;;
        3 ) stoptuic && starttuic ;;
        * ) exit 1 ;;
    esac
}

changeport(){
    if [[ $(tuic -v) == "0.8.5" ]]; then
        oldport=$(cat /etc/tuic/tuic.json 2>/dev/null | sed -n 2p | awk '{print $2}'| tr -d ',')

        read -rp "Set the TUIC port [1-65535] (press Enter to choose a random port): " port
        [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)

        until [[ -z $(ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") ]]; do
            if [[ -n $(ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") ]]; then
                echo -e "${RED} $port ${PLAIN} is already in use by another process. Please choose another port."
                read -rp "Set the TUIC port [1-65535] (press Enter to choose a random port): " port
                [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)
            fi
        done

        sed -i "2s/$oldport/$port/g" /etc/tuic/tuic.json
        sed -i "4s/$oldport/$port/g" /root/tuic/tuic-client.json
        sed -i "4s/$oldport/$port/g" /root/tuic/tuic.txt
        sed -i "19s/$oldport/$port/g" /root/tuic/clash-meta.yaml
        sed -i "s/$oldport/$port/g" /root/tuic/url.txt

        stoptuic && starttuic

        green "The TUIC V4 node port has been updated to: $port"
        yellow "Please update the client configuration manually to use the node."
        showconf
    else
        oldport=$(cat /etc/tuic/tuic.json 2>/dev/null | sed -n 2p | awk '{print $2}' | tr -d ',' | awk -F ":" '{print $4}' | tr -d '"')
    
        read -rp "Set the TUIC port [1-65535] (press Enter to choose a random port): " port
        [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)

        until [[ -z $(ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") ]]; do
            if [[ -n $(ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") ]]; then
                echo -e "${RED} $port ${PLAIN} is already in use by another process. Please choose another port."
                read -rp "Set the TUIC port [1-65535] (press Enter to choose a random port): " port
                [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)
            fi
        done

        sed -i "2s/$oldport/$port/g" /etc/tuic/tuic.json
        sed -i "3s/$oldport/$port/g" /root/tuic/tuic-client.json
        sed -i "4s/$oldport/$port/g" /root/tuic/tuic.txt
        sed -i "19s/$oldport/$port/g" /root/tuic/clash-meta.yaml

        stoptuic && starttuic

        green "The TUIC node port has been updated to: $port"
        yellow "Please update the client configuration manually to use the node."
        showconf
    fi
}

changetoken(){
    oldtoken=$(cat /etc/tuic/tuic.json 2>/dev/null | sed -n 3p | awk '{print $2}' | tr -d ',[]"')

    read -rp "Set the TUIC token (press Enter to generate a random value): " token
    [[ -z $token ]] && token=$(date +%s%N | md5sum | cut -c 1-8)

    sed -i "3s/$oldtoken/$token/g" /etc/tuic/tuic.json
    sed -i "5s/$oldtoken/$token/g" /root/tuic/tuic-client.json
    sed -i "5s/$oldtoken/$token/g" /root/tuic/tuic.txt
    sed -i "21s/$oldtoken/$token/g" /root/tuic/clash-meta.yaml
    sed -i "s/$oldtoken/$token/g" /root/tuic/url.txt

    stoptuic && starttuic

    green "The TUIC node token has been updated to: $token"
    yellow "Please update the client configuration manually to use the node."
    showconf
}

changeuuid(){
    olduuid=$(cat /etc/tuic/tuic.json 2>/dev/null | sed -n 4p | awk '{print $1}' | tr -d ':"')

    read -rp "Set the TUIC UUID (press Enter to generate a random UUID): " uuid
    [[ -z $uuid ]] && uuid=$(cat /proc/sys/kernel/random/uuid)

    sed -i "3s/$olduuid/$uuid/g" /etc/tuic/tuic.json
    sed -i "4s/$olduuid/$uuid/g" /root/tuic/tuic-client.json
    sed -i "5s/$olduuid/$uuid/g" /root/tuic/tuic.txt
    sed -i "21s/$olduuid/$uuid/g" /root/tuic/clash-meta.yaml

    stoptuic && starttuic

    green "The TUIC node UUID has been updated to: $uuid"
    yellow "Please update the client configuration manually to use the node."
    showconf
}

changepasswd(){
    oldpasswd=$(cat /etc/tuic/tuic.json 2>/dev/null | sed -n 4p | awk '{print $2}' | tr -d '"')

    read -rp "Set the TUIC password (press Enter to generate a random value): " passwd
    [[ -z $passwd ]] && passwd=$(date +%s%N | md5sum | cut -c 1-8)

    sed -i "3s/$oldpasswd/$passwd/g" /etc/tuic/tuic.json
    sed -i "5s/$oldpasswd/$passwd/g" /root/tuic/tuic-client.json
    sed -i "6s/$oldpasswd/$passwd/g" /root/tuic/tuic.txt
    sed -i "22s/$oldpasswd/$passwd/g" /root/tuic/clash-meta.yaml

    stoptuic && starttuic

    green "The TUIC node password has been updated to: $passwd"
    yellow "Please update the client configuration manually to use the node."
    showconf
}

changeconf(){
    if [[ $(tuic -v) == "0.8.5" ]]; then
        green "TUIC V4 configuration options:"
        echo -e " ${GREEN}1.${PLAIN} Change port"
        echo -e " ${GREEN}2.${PLAIN} Change token"
        echo ""
        read -rp "Please choose an option [1-2]: " confAnswer
        case $confAnswer in
            1 ) changeport ;;
            2 ) changetoken ;;
            * ) exit 1 ;;
        esac
    else
        green "TUIC V5 configuration options:"
        echo -e " ${GREEN}1.${PLAIN} Change port"
        echo -e " ${GREEN}2.${PLAIN} Change UUID"
        echo -e " ${GREEN}3.${PLAIN} Change password"
        echo ""
        read -rp "Please choose an option [1-3]: " confAnswer
        case $confAnswer in
            1 ) changeport ;;
            2 ) changeuuid ;;
            3 ) changepasswd ;;
            * ) exit 1 ;;
        esac
    fi
}

showconf(){
    yellow "The tuic-client.json configuration is shown below and has been saved to /root/tuic/tuic-client.json."
    red "$(cat /root/tuic/tuic-client.json)"
    yellow "The Clash Meta client configuration has been saved to /root/tuic/clash-meta.yaml."
    yellow "The TUIC node configuration in plain text is shown below and has been saved to /root/tuic/tuic.txt."
    red "$(cat /root/tuic/tuic.txt)"
    yellow "The TUIC node link is shown below and has been saved to /root/tuic/url.txt."
    red "$(cat /root/tuic/url.txt)"
}

menu() {
    clear
    echo "#############################################################"
    echo -e "#               ${RED}TUIC One-Click Install Script${PLAIN}               #"
    echo -e "# ${GREEN}Author${PLAIN}: MisakaNo                                          #"
    echo -e "# ${GREEN}Translate & Automated Certification${PLAIN}: Eviau512             #"
    echo -e "# ${GREEN}Blog${PLAIN}: https://blog.misaka.cyou                            #"
    echo -e "# ${GREEN}GitHub project${PLAIN}: https://github.com/Misaka-blog            #"
    echo -e "# ${GREEN}GitLab project${PLAIN}: https://gitlab.com/Misaka-blog            #"
    echo -e "# ${GREEN}Telegram channel${PLAIN}: https://t.me/misakanocchannel           #"
    echo -e "# ${GREEN}Telegram group${PLAIN}: https://t.me/misakanoc                    #"
    echo -e "# ${GREEN}YouTube channel${PLAIN}: https://www.youtube.com/@misaka-blog     #"
    echo "#############################################################"
    echo ""
    echo -e " ${GREEN}1.${PLAIN} Install TUIC V4"
    echo -e " ${GREEN}2.${PLAIN} ${RED}Uninstall TUIC V4${PLAIN}"
    echo " -------------"
    echo -e " ${GREEN}3.${PLAIN} Install TUIC V5"
    echo -e " ${GREEN}4.${PLAIN} ${RED}Uninstall TUIC V5${PLAIN}"
    echo " -------------"
    echo -e " ${GREEN}5.${PLAIN} Stop, start, or restart TUIC"
    echo -e " ${GREEN}6.${PLAIN} Modify TUIC configuration"
    echo -e " ${GREEN}7.${PLAIN} Show TUIC configuration files"
    echo " -------------"
    echo -e " ${GREEN}0.${PLAIN} Exit the script"
    echo ""
    read -rp "Please choose an option [0-7]: " menuInput
    case $menuInput in
        1 ) inst_tuv4 ;;
        2 ) unst_tuv4 ;;
        3 ) inst_tuv5 ;;
        4 ) unst_tuv5 ;;
        5 ) tuicswitch ;;
        6 ) changeconf ;;
        7 ) showconf ;;
        * ) exit 1 ;;
    esac
}

menu