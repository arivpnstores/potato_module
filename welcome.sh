#!/bin/bash

# Tulis ke /root/.profile
cat <<EOF > /root/.profile
# ~/.profile: executed by Bourne-compatible login shells.

if [ "\$BASH" ]; then
  if [ -f ~/.bashrc ]; then
    . ~/.bashrc
  fi
fi

mesg n || true
ln -fs /usr/share/zoneinfo/Asia/Jakarta /etc/localtime
desain p0t4t0
$WEB_SERVER
EOF

echo "✅ /root/.profile berhasil di-set!"
