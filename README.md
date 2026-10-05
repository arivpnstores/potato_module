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
