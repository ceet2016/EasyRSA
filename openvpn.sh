#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH
# Detect Debian users running the script with "sh" instead of bash
if readlink /proc/$$/exe | grep -qs "dash"; then
	echo "这个脚本需要使用bash运行，而不是sh"
	exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
	echo "请使用root用户来运行此脚本"
	exit 2
fi

if [[ ! -e /dev/net/tun ]]; then
	echo "TUN设备不可用，在运行此脚本之前，需要启用TUN"
	exit 3
fi

if grep -qs "CentOS release 5" "/etc/redhat-release"; then
	echo "CentOS 5 太老了，已经不支持了，换一个高一点的版本吧！"
	exit 4
fi
if [[ -e /etc/debian_version ]]; then
	OS=debian
	GROUPNAME=nogroup
	RCLOCAL='/etc/rc.local'
elif [[ -e /etc/centos-release || -e /etc/redhat-release ]]; then
	OS=centos
	GROUPNAME=nobody
	RCLOCAL='/etc/rc.d/rc.local'
else
	echo "请使用  Debian, Ubuntu, CentOS来运行此脚本"
	exit 5
fi

newclient () {
	# Generates the custom client.ovpn
	cp /etc/openvpn/client-common.txt ~/$1.ovpn
	echo "<ca>" >> ~/$1.ovpn
	cat /etc/openvpn/easy-rsa/pki/ca.crt >> ~/$1.ovpn
	echo "</ca>" >> ~/$1.ovpn
	echo "<cert>" >> ~/$1.ovpn
	cat /etc/openvpn/easy-rsa/pki/issued/$1.crt >> ~/$1.ovpn
	echo "</cert>" >> ~/$1.ovpn
	echo "<key>" >> ~/$1.ovpn
	cat /etc/openvpn/easy-rsa/pki/private/$1.key >> ~/$1.ovpn
	echo "</key>" >> ~/$1.ovpn
	echo "<tls-auth>" >> ~/$1.ovpn
	cat /etc/openvpn/ta.key >> ~/$1.ovpn
	echo "</tls-auth>" >> ~/$1.ovpn
}

# Try to get our IP from the system and fallback to the Internet.
# I do this to make the script compatible with NATed servers (lowendspirit.com)
# and to avoid getting an IPv6.
# Get the PRIMARY interface IP (used for SNAT/NAT rules)
IP=$(ip addr | grep 'inet' | grep -v inet6 | grep -vE '127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | grep -o -E '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -1)
if [[ "$IP" = "" ]]; then
		IP=$(wget -4qO- "ipv4.icanhazip.com/")
# 		IP='curl ipv4.icanhazip.com'
fi
# Get the external/public IP for client config (may differ from $IP on cloud NAT)
EXTERNALIP=$(wget -4qO- "ipv4.icanhazip.com/" 2>/dev/null)
if [[ "$EXTERNALIP" = "" ]]; then
	EXTERNALIP=$IP
fi

if [[ -e /etc/openvpn/server.conf ]]; then
	while :
	do
	clear
		echo "OpenVpn管理面板"
		echo "脚本来源合肥市小桂子网络科技有限公司"
		echo "-----------------------------------------------"
		echo "   1) 添加新用户"
		echo "   2) 删除用户"
		echo "   3) 删除OPENVPN"
		echo "   4) 退出"
		read -p "选着数字然后按回车 [1-4]: " option
		case $option in
			1) 
			echo ""
			echo "告诉我客户端证书的名称"
			echo "请只使用一个单词，不要使用特殊字符"
			read -p "客户端名称: " -e -i client CLIENT
			cd /etc/openvpn/easy-rsa/
			./easyrsa build-client-full $CLIENT nopass
			# Generates the custom client.ovpn
			newclient "$CLIENT"
			echo ""
			echo "客户端 $CLIENT 已添加, 配置文件在" ~/"$CLIENT.ovpn"
			exit
			;;
			2)
			# This option could be documented a bit better and maybe even be simplimplified
			# ...but what can I say, I want some sleep too
			NUMBEROFCLIENTS=$(tail -n +2 /etc/openvpn/easy-rsa/pki/index.txt | grep -c "^V")
			if [[ "$NUMBEROFCLIENTS" = '0' ]]; then
				echo ""
				echo "您没有能够删除的客户端！"
				exit 6
			fi
			echo ""
			echo "选择要吊销的证书"
			tail -n +2 /etc/openvpn/easy-rsa/pki/index.txt | grep "^V" | cut -d '=' -f 2 | nl -s ') '
			if [[ "$NUMBEROFCLIENTS" = '1' ]]; then
				read -p "选择一个客户端 [1]: " CLIENTNUMBER
			else
				read -p "选择一个客户 [1-$NUMBEROFCLIENTS]: " CLIENTNUMBER
			fi
			CLIENT=$(tail -n +2 /etc/openvpn/easy-rsa/pki/index.txt | grep "^V" | cut -d '=' -f 2 | sed -n "$CLIENTNUMBER"p)
			cd /etc/openvpn/easy-rsa/
			./easyrsa --batch revoke $CLIENT
			EASYRSA_CRL_DAYS=3650 ./easyrsa gen-crl
			rm -rf pki/reqs/$CLIENT.req
			rm -rf pki/private/$CLIENT.key
			rm -rf pki/issued/$CLIENT.crt
			rm -rf /etc/openvpn/crl.pem
			cp /etc/openvpn/easy-rsa/pki/crl.pem /etc/openvpn/crl.pem
			# CRL is read with each client connection, when OpenVPN is dropped to nobody
			chown nobody:$GROUPNAME /etc/openvpn/crl.pem
			echo ""
			echo "证书 $CLIENT 已被吊销"
			exit
			;;
			3) 
			echo ""
			read -p "您是否确认删除 OpenVPN? [y/n]: " -e -i n REMOVE
			if [[ "$REMOVE" = 'y' ]]; then
				PORT=$(grep '^port ' /etc/openvpn/server.conf | cut -d " " -f 2)
				PROTOCOL=$(grep '^proto ' /etc/openvpn/server.conf | cut -d " " -f 2)
				if pgrep firewalld; then
					IP=$(firewall-cmd --direct --get-rules ipv4 nat POSTROUTING | grep '\-s 10.8.0.0/24 '"'"'!'"'"' -d 10.8.0.0/24 -j SNAT --to ' | cut -d " " -f 10)
					# Using both permanent and not permanent rules to avoid a firewalld reload.
					firewall-cmd --zone=public --remove-port=$PORT/$PROTOCOL
					firewall-cmd --zone=trusted --remove-source=10.8.0.0/24
					firewall-cmd --permanent --zone=public --remove-port=$PORT/$PROTOCOL
					firewall-cmd --permanent --zone=trusted --remove-source=10.8.0.0/24
					firewall-cmd --direct --remove-rule ipv4 nat POSTROUTING 0 -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to $IP
					firewall-cmd --permanent --direct --remove-rule ipv4 nat POSTROUTING 0 -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to $IP
				else
					iptables -t nat -D POSTROUTING -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j MASQUERADE 2>/dev/null
					sed -i '/iptables -t nat -A POSTROUTING -s 10.8.0.0\/24 ! -d 10.8.0.0\/24 -j MASQUERADE/d' $RCLOCAL
					# Also clean up old SNAT-style rules
					iptables -t nat -D POSTROUTING -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to 2>/dev/null
					sed -i '/iptables -t nat -A POSTROUTING -s 10.8.0.0\/24 ! -d 10.8.0.0\/24 -j SNAT --to /d' $RCLOCAL
					iptables -D INPUT -p $PROTOCOL --dport $PORT -j ACCEPT 2>/dev/null
					iptables -D FORWARD -s 10.8.0.0/24 -j ACCEPT 2>/dev/null
					iptables -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
					sed -i "/iptables -I INPUT -p $PROTOCOL --dport $PORT -j ACCEPT/d" $RCLOCAL
					sed -i "/iptables -I FORWARD -s 10.8.0.0\/24 -j ACCEPT/d" $RCLOCAL
					sed -i "/iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT/d" $RCLOCAL
				fi
				if hash sestatus 2>/dev/null; then
					if sestatus | grep "Current mode" | grep -qs "enforcing"; then
						if [[ "$PORT" != '56666' || "$PROTOCOL" = 'tcp' ]]; then
							semanage port -d -t openvpn_port_t -p $PROTOCOL $PORT
						fi
					fi
				fi
				if [[ "$OS" = 'debian' ]]; then
					apt-get remove --purge -y openvpn
				else
					yum remove openvpn -y
				fi
				rm -rf /etc/openvpn
				echo ""
				echo "OpenVPN 已经成功移除"
			else
				echo ""
				echo "移除OpenVpn失败，请手动删除"
			fi
			exit
			;;
			4) exit;;
		esac
	done
else
	clear
	echo "欢迎使用OpenVpn一键搭建脚本"
	echo "------------------------------------------------"
	echo " 脚本来源：合肥市小桂子网络科技有限公司"
	echo " 汉化：桂祥钟"
	echo "------------------------------------------------"
	# OpenVPN setup and first user creation
	echo "在开始准备之前我需要问你几个问题"
	echo "1.是否知晓中华人民共和国禁止通过一切手段访问境外网址，并且同意此协议"
	echo "2.保证不使用此脚本进行违反或挑衅中国人民共和国任意法律"
	echo "3.您在以下输入y后，将安装此脚本提供的软件程序，并且同意以上所有条款"
	read -p "您是否确认安装? [y/n]: " -e -i n REMBE
	if [[ "$REMBE" != 'y' ]]; then exit;
    fi
	echo "您可以保留默认选项，如果您对它们没有问题，只需按回车键"
	echo ""
	echo "首先我需要知道你想要OpenVPN的网络接口的IPv4地址"
	echo "开始搭建"
	read -p "IP address: " -e -i $IP IP
	echo ""
	echo "选着要用的传输方式，建议使用UDP速度更快"
	echo "   1) UDP (recommended)"
	echo "   2) TCP"
	read -p "Protocol [1-2]: " -e -i 1 PROTOCOL
	case $PROTOCOL in
		1) 
		PROTOCOL=udp
		;;
		2) 
		PROTOCOL=tcp
		;;
	esac
	echo ""
	echo "选着需要的端口（默认10088）?"
	read -p "Port: " -e -i 10088 PORT
	echo ""
	echo "选着需要的DNS（默认本机DNS)"
	echo "   1) 当前系统DNS"
	echo "   2) GoogleDNS"
	echo "   3) OpenDNS"
	echo "   4) NTT"
	echo "   5) Hurricane Electric"
	echo "   6) Verisign"
	read -p "DNS [1-6]: " -e -i 1 DNS
	echo ""
	echo "请输入需要创建的客户端用户"
	echo "请别输入特殊符号和空格"
	read -p "Client name: " -e -i client CLIENT
	echo ""
	echo "好的，这就是我想要的。我们现在已经准备好设置OpenVPN服务器了"
	read -n1 -r -p "请按任意键继续..."
	if [[ "$OS" = 'debian' ]]; then
		apt-get update
		apt-get install openvpn iptables openssl ca-certificates -y
	else
		# Else, the distro is CentOS
		yum install epel-release -y
		yum install openvpn iptables openssl wget ca-certificates -y
	fi
	# An old version of easy-rsa was available by default in some openvpn packages
	if [[ -d /etc/openvpn/easy-rsa/ ]]; then
		rm -rf /etc/openvpn/easy-rsa/
	fi
	yum install -y lrzsz
	# Get easy-rsa
	wget -O ~/EasyRSA-3.0.4.tgz "https://cnb.cool/uniomo/EasyRSA/-/git/raw/main/EasyRSA-3.0.4.tgz"
	tar xzf ~/EasyRSA-3.0.4.tgz -C ~/
	mv ~/EasyRSA-3.0.4/ /etc/openvpn/
	mv /etc/openvpn/EasyRSA-3.0.4/ /etc/openvpn/easy-rsa/
	chown -R root:root /etc/openvpn/easy-rsa/
	rm -rf ~/EasyRSA-3.0.4.tgz
	cd /etc/openvpn/easy-rsa/
	# Create the PKI, set up the CA, the DH params and the server + client certificates
	./easyrsa init-pki
	./easyrsa --batch build-ca nopass
	./easyrsa gen-dh
	./easyrsa build-server-full server nopass
	./easyrsa build-client-full $CLIENT nopass
	EASYRSA_CRL_DAYS=3650 ./easyrsa gen-crl
	# Move the stuff we need
	cp pki/ca.crt pki/private/ca.key pki/dh.pem pki/issued/server.crt pki/private/server.key pki/crl.pem /etc/openvpn
	# CRL is read with each client connection, when OpenVPN is dropped to nobody
	chown nobody:$GROUPNAME /etc/openvpn/crl.pem
	# Generate key for tls-auth
	openvpn --genkey --secret /etc/openvpn/ta.key
	# Generate server.conf
	echo "port $PORT
proto $PROTOCOL
dev tun
sndbuf 0
rcvbuf 0
ca ca.crt
cert server.crt
key server.key
dh dh.pem
auth SHA512
tls-auth ta.key 0
topology subnet
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ipp.txt" > /etc/openvpn/server.conf
	echo 'push "redirect-gateway def1 bypass-dhcp"' >> /etc/openvpn/server.conf
	# DNS
	case $DNS in
		1) 
		# Locate the proper resolv.conf
		# Needed for systems running systemd-resolved
		if grep -q "127.0.0.53" "/etc/resolv.conf"; then
			RESOLVCONF='/run/systemd/resolve/resolv.conf'
		else
			RESOLVCONF='/etc/resolv.conf'
		fi
		# Obtain the resolvers from resolv.conf and use them for OpenVPN
		# Skip local/loopback DNS servers (e.g. 127.0.0.53) as they are unreachable from clients
		grep -v '#' $RESOLVCONF | grep 'nameserver' | grep -E -o '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | while read line; do
			if [[ "$line" != "127.0.0.1" && "$line" != "127.0.0.53" && "$line" != "127.0.0.54" ]]; then
				echo "push \"dhcp-option DNS $line\"" >> /etc/openvpn/server.conf
			fi
		done
		;;
		2) 
		echo 'push "dhcp-option DNS 8.8.8.8"' >> /etc/openvpn/server.conf
		echo 'push "dhcp-option DNS 8.8.4.4"' >> /etc/openvpn/server.conf
		;;
		3)
		echo 'push "dhcp-option DNS 208.67.222.222"' >> /etc/openvpn/server.conf
		echo 'push "dhcp-option DNS 208.67.220.220"' >> /etc/openvpn/server.conf
		;;
		4) 
		echo 'push "dhcp-option DNS 129.250.35.250"' >> /etc/openvpn/server.conf
		echo 'push "dhcp-option DNS 129.250.35.251"' >> /etc/openvpn/server.conf
		;;
		5) 
		echo 'push "dhcp-option DNS 74.82.42.42"' >> /etc/openvpn/server.conf
		;;
		6) 
		echo 'push "dhcp-option DNS 64.6.64.6"' >> /etc/openvpn/server.conf
		echo 'push "dhcp-option DNS 64.6.65.6"' >> /etc/openvpn/server.conf
		;;
	esac
	echo "push \"topology subnet\"
keepalive 10 120
cipher AES-256-CBC
comp-lzo
user nobody
group $GROUPNAME
persist-key
persist-tun
status openvpn-status.log
verb 3
crl-verify crl.pem
explicit-exit-notify 1" >> /etc/openvpn/server.conf
	# explicit-exit-notify only works with UDP, set to 0 for TCP
	if [[ "$PROTOCOL" = 'tcp' ]]; then
		sed -i '/^explicit-exit-notify/d' /etc/openvpn/server.conf
	fi
	# Enable net.ipv4.ip_forward for the system
	sed -i '/\<net.ipv4.ip_forward\>/c\net.ipv4.ip_forward=1' /etc/sysctl.conf
	if ! grep -q "\<net.ipv4.ip_forward\>" /etc/sysctl.conf; then
		echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
	fi
	# Avoid an unneeded reboot
	echo 1 > /proc/sys/net/ipv4/ip_forward
	if pgrep firewalld; then
		# Using both permanent and not permanent rules to avoid a firewalld
		# reload.
		# We don't use --add-service=openvpn because that would only work with
		# the default port and protocol.
		firewall-cmd --zone=public --add-port=$PORT/$PROTOCOL
		firewall-cmd --zone=trusted --add-source=10.8.0.0/24
		firewall-cmd --permanent --zone=public --add-port=$PORT/$PROTOCOL
		firewall-cmd --permanent --zone=trusted --add-source=10.8.0.0/24
		# Set NAT for the VPN subnet
		firewall-cmd --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j MASQUERADE
		firewall-cmd --permanent --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j MASQUERADE
	else
		# Needed to use rc.local with some systemd distros
		if [[ "$OS" = 'debian' && ! -e $RCLOCAL ]]; then
			echo '#!/bin/sh -e
exit 0' > $RCLOCAL
		fi
		chmod +x $RCLOCAL
		# Set NAT for the VPN subnet - use MASQUERADE for cloud/NAT compatibility
		iptables -t nat -A POSTROUTING -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j MASQUERADE
		sed -i "1 a\iptables -t nat -A POSTROUTING -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j MASQUERADE" $RCLOCAL
		# Always add FORWARD and INPUT rules (not just when REJECT/DROP detected)
		# This ensures VPN traffic can flow through the server
		iptables -I INPUT -p $PROTOCOL --dport $PORT -j ACCEPT
		iptables -I FORWARD -s 10.8.0.0/24 -j ACCEPT
		iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
		sed -i "1 a\iptables -I INPUT -p $PROTOCOL --dport $PORT -j ACCEPT" $RCLOCAL
		sed -i "1 a\iptables -I FORWARD -s 10.8.0.0/24 -j ACCEPT" $RCLOCAL
		sed -i "1 a\iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT" $RCLOCAL
	fi
	# If SELinux is enabled and a custom port or TCP was selected, we need this
	if hash sestatus 2>/dev/null; then
		if sestatus | grep "Current mode" | grep -qs "enforcing"; then
			if [[ "$PORT" != '56666' || "$PROTOCOL" = 'tcp' ]]; then
				# semanage isn't available in CentOS 6 by default
				if ! hash semanage 2>/dev/null; then
					yum install policycoreutils-python -y
				fi
				semanage port -a -t openvpn_port_t -p $PROTOCOL $PORT
			fi
		fi
	fi
	# Add NET_ADMIN capability for OpenVPN 2.4+ (needed after dropping privileges)
	if pgrep systemd-journal; then
		mkdir -p /etc/systemd/system/openvpn@server.service.d
		echo "[Service]
AmbientCapabilities=CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_ADMIN" > /etc/systemd/system/openvpn@server.service.d/override.conf
		systemctl daemon-reload
	fi
	# And finally, restart OpenVPN
	if [[ "$OS" = 'debian' ]]; then
		# Little hack to check for systemd
		if pgrep systemd-journal; then
			systemctl restart openvpn@server.service
		else
			/etc/init.d/openvpn restart
		fi
	else
		if pgrep systemd-journal; then
			systemctl restart openvpn@server.service
			systemctl enable openvpn@server.service
		else
			service openvpn restart
			chkconfig openvpn on
		fi
	fi
	# Try to detect a NATed connection and ask about it to potential LowEndSpirit users
	if [[ "$IP" != "$EXTERNALIP" ]]; then
		echo ""
		echo "检测到服务器可能处于 NAT 环境中（云服务器）"
		echo "内网 IP: $IP"
		echo "公网 IP: $EXTERNALIP"
		echo ""
		echo "SNAT 将使用内网 IP ($IP)，客户端将使用公网 IP ($EXTERNALIP) 连接"
		CLIENTIP=$EXTERNALIP
	else
		CLIENTIP=$IP
	fi
	# client-common.txt is created so we have a template to add further users later
	echo "client
dev tun
proto $PROTOCOL
sndbuf 0
rcvbuf 0
remote $CLIENTIP $PORT
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA512
cipher AES-256-CBC
comp-lzo
setenv opt block-outside-dns
key-direction 1
verb 3" > /etc/openvpn/client-common.txt
	# Generates the custom client.ovpn
	newclient "$CLIENT"
	echo   "OPENVPN"
	echo   "恭喜安装成功!"
	
	echo  "客户端配置文件在当前目录下，请使用XFTP下好后导入OpenVpn客户端就可以了" ~/"$CLIENT.ovpn"
	echo  "重新允许此脚本可以添加用户删除用户，如果要提升网速可以顺带安装bbr"
        echo " 祝愿大家天天开心！！"
        echo " 脚本来源于网络"
	
fi
