#!/bin/bash

export DEBIAN_FRONTEND=noninteractive

echo "=== UPDATE SYSTEM ==="
apt update -y && apt-get -y -o Dpkg::Options::="--force-confold" upgrade

echo "=== INSTALL DOCKER ==="
apt install -y docker.io curl

systemctl enable docker
systemctl start docker

echo "=== DETECT PUBLIC IPV4 ==="
WG_HOST=$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip)

echo "Detected IPv4: $WG_HOST"

echo "=== OPEN FIREWALL (UFW) ==="
ufw allow 51820/udp >/dev/null 2>&1
ufw allow 51821/tcp >/dev/null 2>&1

echo "=== STOP OLD WG (IF EXISTS) ==="
systemctl stop wg-quick@wg0 >/dev/null 2>&1

echo "=== RUN WG-EASY CONTAINER ==="

docker run -d \
  --name=wg-easy \
  -e WG_HOST=$WG_HOST \
  -e PASSWORD=wireguardpass \
  -v ~/.wg-easy:/etc/wireguard \
  -p 51820:51820/udp \
  -p 51821:51821/tcp \
  --cap-add=NET_ADMIN \
  --cap-add=SYS_MODULE \
  --restart=unless-stopped \
  weejewel/wg-easy

echo ""
echo "=== DONE ==="
echo "Panel: http://$WG_HOST:51821"
echo "Password: wireguardpass"
