# potato_module
menganti welcome di server id
```bash
bash <(curl -sSL https://raw.githubusercontent.com/arivpnstores/potato_module/main/welcome.sh)
```
Lock Dropbear Potato
```bash
dropbear -V && apt-mark hold dropbear && chattr +i /usr/sbin/dropbear
```
style-potato v2
```bash
apt install -y wget && wget https://raw.githubusercontent.com/arivpnstores/potato_module/refs/heads/main/style-potato.sh -O /usr/sbin/potatonc/style/style-potato.sh && chmod +x /usr/sbin/potatonc/style/style-potato.sh
```
DNS SET + IPV4 ONLY LANGSUNG  
```bash
#!/bin/bash

echo "🚀 RESET + SET DNS + DISABLE IPV6"

# ================= UNLOCK =================
chattr -i /etc/resolv.conf 2>/dev/null
chattr -i /etc/sysctl.conf 2>/dev/null

# ================= RESET OLD CONFIG =================
sed -i '/disable_ipv6/d' /etc/sysctl.conf
sed -i '/tcp_congestion_control/d' /etc/sysctl.conf
sed -i '/default_qdisc/d' /etc/sysctl.conf

rm -f /etc/resolv.conf

# ================= DNS =================
cat <<EOF > /etc/resolv.conf
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 9.9.9.9
EOF

echo "✅ DNS UPDATED"

# ================= DISABLE IPV6 =================
cat <<EOF >> /etc/sysctl.conf

# DISABLE IPV6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1

EOF

# ================= APPLY =================
sysctl -p > /dev/null 2>&1

echo "🔥 DONE! CLEAN CONFIG + FAST DNS"
```
