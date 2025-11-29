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
apt update && apt install -y screen curl wget python3-pip && pip install gdown --break-system-packages && gdown '1CWSzSa823zcWmorjrGutZwJo10V8rTt4' -O /usr/sbin/potatonc/style/style-potato.sh && chmod +x /usr/sbin/potatonc/style/style-potato.sh
```
BUNUH UDP 
```bash
systemctl stop udp-server && systemctl disable udp-server && sudo rm -f /etc/systemd/system/udp-server.service && sudo systemctl daemon-reload && sudo systemctl reset-failed && sudo rm -f /usr/sbin/potatonc/udp/udp-server
```
config ssh unlock untuk Indonesia 
```bash
wget -O config-Indonesia.zip https://github.com/arivpnstores/potato_module/raw/main/config-Indonesia.zip && sudo mv config-Indonesia.zip /var/www/html/ 
```
