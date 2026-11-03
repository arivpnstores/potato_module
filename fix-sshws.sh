#!/usr/bin/env bash
# ============================================================
#  fix-sshws.sh  (v2 - 2026-11-03)
#  Perbaikan SSH WS (Potato / tunws@sochs / sochs.py)
#
#  Masalah yang diperbaiki:
#   1. Limit file descriptor 1024 -> 65535
#   2. FD leak di sochs.py (socket tidak ditutup saat koneksi putus)
#   3. Thread accept mati saat "Too many open files"
#   4. potato-ohp.service gagal karena StandardOutput=tty
#      (ini yang bikin port 80/443/2082/2083/8880 mati)
#
#  Pakai:
#    bash fix-sshws.sh               # patch + restart + verifikasi
#    bash fix-sshws.sh --patch-only  # patch saja, tanpa restart
#    bash fix-sshws.sh --verify-only # hanya cek status (tanpa ubah)
#
#  Env opsional:
#    SOCHS_PY=/path/sochs.py         # override lokasi sochs.py
# ============================================================
set -u

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[X]${NC} $*"; }
info() { echo -e "${CYAN}[i]${NC} $*"; }

MODE=full
case "${1:-}" in
  "" )            MODE=full ;;
  --patch-only )  MODE=patch ;;
  --verify-only ) MODE=verify ;;
  -h|--help )
    sed -n '2,30p' "$0"; exit 0 ;;
  * )
    err "Argumen tidak dikenal: $1"
    echo "Pakai: bash $0 [--patch-only|--verify-only]"; exit 1 ;;
esac

if [ "$(id -u)" != "0" ]; then
  err "Harus dijalankan sebagai root."
  exit 1
fi

SOCHS_PY="${SOCHS_PY:-/usr/sbin/sochs.py}"
OHP_UNIT=/etc/systemd/system/potato-ohp.service
TUNWS_INSTANCE=tunws@sochs.service

TS=$(date +%Y%m%d-%H%M%S)
BK="/root/backup-fix-sshws-$TS"

########################################
# helper backup + manifest/restore
########################################
backup_file() {
  local src="$1" name="$2"
  [ -f "$src" ] || return 1
  cp -a "$src" "$BK/$name" 2>/dev/null || return 1
  printf '%s\t%s\n' "$src" "$BK/$name" >> "$BK/manifest.tsv"
  return 0
}

make_restore() {
  [ -f "$BK/manifest.tsv" ] || return 0
  cat > "$BK/restore.sh" <<'EOS'
#!/usr/bin/env bash
# Restore file yang diubah oleh fix-sshws.sh
set -u
D="$(cd "$(dirname "$0")" && pwd)"
[ -f "$D/manifest.tsv" ] || { echo "manifest.tsv tidak ada"; exit 1; }
while IFS=$'\t' read -r src bak; do
  [ -n "${src:-}" ] || continue
  [ -f "${bak:-}" ] || continue
  cp -a "$bak" "$src" && echo "restored: $src"
done < "$D/manifest.tsv"
systemctl daemon-reload 2>/dev/null || true
systemctl restart 'tunws@sochs.service' 2>/dev/null || true
systemctl restart potato-ohp.service 2>/dev/null || true
echo "Selesai restore."
EOS
  chmod +x "$BK/restore.sh"
}

if [ "$MODE" != "verify" ]; then
  mkdir -p "$BK"
  info "Backup disimpan di: $BK"
  : > "$BK/manifest.tsv"
fi

########################################
# 1. systemd tunws -> LimitNOFILE=65535
########################################
patch_unit() {
  local unit="$1"
  [ -f "$unit" ] || return 0
  backup_file "$unit" "$(basename "$unit").bak"
  if grep -qE '^[[:space:]]*LimitNOFILE=' "$unit"; then
    sed -i -E 's/^[[:space:]]*LimitNOFILE=.*/LimitNOFILE=65535/' "$unit"
    ok "LimitNOFILE diset 65535: $unit"
  else
    if grep -qE '^[[:space:]]*Restart=' "$unit"; then
      sed -i -E '/^[[:space:]]*Restart=.*/a LimitNOFILE=65535' "$unit"
    else
      sed -i -E '/^\[Service\]/a LimitNOFILE=65535' "$unit"
    fi
    ok "LimitNOFILE=65535 ditambahkan: $unit"
  fi
}

do_patch_units() {
  shopt -s nullglob
  local units=( /etc/systemd/system/tunws@.service \
                /etc/systemd/system/tunws@*.service \
                /etc/systemd/system/tunws.service )
  shopt -u nullglob
  mapfile -t units < <(printf '%s\n' "${units[@]}" | sort -u)
  local u
  for u in "${units[@]}"; do
    patch_unit "$u"
  done
}

########################################
# 2. Patch sochs.py
########################################
patch_sochs() {
  local f="$1"
  if [ ! -f "$f" ]; then
    warn "Tidak ditemukan: $f (lewati)"
    return 0
  fi
  backup_file "$f" "$(basename "$f").bak"
  info "Memperbaiki: $f"

  /usr/bin/python3 - "$f" <<'PY'
import sys
p = sys.argv[1]
s = open(p, 'r').read()
orig = s

def rep(old, new, label, detect):
    global s
    if detect in s:
        print("  - %s: sudah diperbaiki (skip)" % label)
        return
    if old in s:
        s = s.replace(old, new, 1)
        print("  - %s: dipatch" % label)
    else:
        print("  - %s: pola tidak cocok (skip)" % label)

# a) accept loop jangan mati saat error (mis. Too many open files)
rep(
"""                except socket.timeout:
                    continue
""",
"""                except socket.timeout:
                    continue
                except Exception:
                    time.sleep(1)
                    continue
""",
    "accept loop",
    "except Exception:\n                    time.sleep(1)\n                    continue",
)

# b) removeConn jangan lempar ValueError
rep(
"""            self.threadsLock.acquire()
            self.threads.remove(conn)
""",
"""            self.threadsLock.acquire()
            if conn in self.threads:
                self.threads.remove(conn)
""",
    "removeConn",
    "if conn in self.threads:",
)

# c) close() selalu menutup socket (fix kebocoran FD)
rep(
"""    def close(self):
        try:
            if not self.clientClosed:
                self.client.shutdown(socket.SHUT_RDWR)
                self.client.close()
        except:
            pass
        finally:
            self.clientClosed = True

        try:
            if not self.targetClosed:
                self.target.shutdown(socket.SHUT_RDWR)
                self.target.close()
        except:
            pass
        finally:
            self.targetClosed = True
""",
"""    def close(self):
        if not self.clientClosed:
            try:
                self.client.shutdown(socket.SHUT_RDWR)
            except:
                pass
            try:
                self.client.close()
            except:
                pass
            self.clientClosed = True

        if not self.targetClosed:
            try:
                self.target.shutdown(socket.SHUT_RDWR)
            except:
                pass
            try:
                self.target.close()
            except:
                pass
            self.targetClosed = True
""",
    "close() FD leak",
    "if not self.clientClosed:\n            try:",
)

if s != orig:
    open(p, 'w').write(s)
    print("  - file ditulis ulang")
else:
    print("  - tidak ada perubahan")
PY

  if [ -x /usr/bin/python ]; then
    if ! /usr/bin/python -m py_compile "$f" 2>"$BK/pycompile.err"; then
      err "Syntax error setelah patch, mengembalikan backup..."
      cp -a "$BK/$(basename "$f").bak" "$f"
      cat "$BK/pycompile.err"
    else
      ok "Sintaks sochs.py valid"
    fi
  else
    warn "/usr/bin/python (python2) tidak ada, cek sintaks dilewati"
  fi
}

########################################
# 3. potato-ohp.service: tty -> journal
########################################
patch_ohp() {
  [ -f "$OHP_UNIT" ] || { warn "potato-ohp.service tidak ada (lewati)"; return 0; }
  backup_file "$OHP_UNIT" "potato-ohp.service.bak"
  if grep -qE '^[[:space:]]*StandardOutput=tty' "$OHP_UNIT"; then
    sed -i -E 's/^[[:space:]]*StandardOutput=tty[[:space:]]*$/StandardOutput=journal/' "$OHP_UNIT"
    ok "potato-ohp: StandardOutput=tty -> journal"
  else
    ok "potato-ohp: tidak pakai tty (skip)"
  fi
}

########################################
# 4. Verifikasi
########################################
ws_probe() {
  local host="$1" port="$2"
  timeout 6 bash -c "exec 3<>/dev/tcp/$host/$port; \
    printf 'GET / HTTP/1.1\r\nHost: x\r\nX-Real-Host: 127.0.0.1:90\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n' >&3; \
    head -c 64 <&3" 2>/dev/null | tr -d '\r'
}

port_listen() {
  ss -tln 2>/dev/null | grep -qE "[:]$1[[:space:]]"
}

verify() {
  echo
  info "=== Verifikasi ==="

  if systemctl is-active --quiet "$TUNWS_INSTANCE" 2>/dev/null; then
    ok "$TUNWS_INSTANCE: active"
  else
    warn "$TUNWS_INSTANCE tidak aktif (nama instance mungkin beda)"
  fi

  local p
  for p in 1230 9080 9088 9090; do
    port_listen "$p" && ok "port $p listening"
  done

  local out
  out=$(ws_probe 127.0.0.1 1230)
  if printf '%s' "$out" | grep -q '101'; then
    ok "handshake WS 1230: 101 OK"
    if printf '%s' "$out" | grep -qi 'SSH-2.0'; then
      ok "tunnel 1230 -> SSH target OK"
    fi
  else
    warn "handshake WS 1230 gagal/ tidak ada respon 101"
  fi

  for p in 80 443 2082 2083 8880; do
    if port_listen "$p"; then
      out=$(ws_probe 127.0.0.1 "$p")
      if printf '%s' "$out" | grep -q '101'; then
        ok "front port $p: 101 OK"
      else
        warn "front port $p listening tapi belum merespon 101 (cek potato-ohp)"
      fi
    fi
  done

  if systemctl is-active --quiet potato-ohp.service 2>/dev/null; then
    ok "potato-ohp.service: active"
  else
    warn "potato-ohp.service tidak aktif"
  fi

  local PID
  PID=$(systemctl show -p MainPID --value "$TUNWS_INSTANCE" 2>/dev/null)
  if [ -n "${PID:-}" ] && [ "$PID" != "0" ] && [ -r "/proc/$PID/limits" ]; then
    ok "FD limit: $(grep -i 'Max open files' "/proc/$PID/limits" | awk '{print $4}')"
    info "FD terpakai sekarang: $(ls "/proc/$PID/fd" 2>/dev/null | wc -l)"
  fi

  echo
  if systemctl --failed --no-legend 2>/dev/null | grep -q .; then
    warn "Ada unit gagal:"
    systemctl --failed --no-legend 2>/dev/null
  else
    ok "Tidak ada systemd unit yang gagal"
  fi
}

########################################
# Main
########################################
if [ "$MODE" = "verify" ]; then
  verify
  exit 0
fi

do_patch_units
patch_sochs "$SOCHS_PY"
patch_ohp

make_restore

if [ "$MODE" = "patch" ]; then
  echo
  ok "Mode --patch-only: selesai tanpa restart service."
  info "Backup & restore: $BK/restore.sh"
  exit 0
fi

systemctl daemon-reload
ok "systemd daemon-reload"

restarted=0
for svc in $(systemctl list-units --all --type=service --no-legend 'tunws@*.service' 2>/dev/null | awk '{print $1}'); do
  if systemctl restart "$svc" 2>/dev/null; then
    ok "restart $svc"
    restarted=1
  else
    warn "gagal restart $svc"
  fi
done

if [ -f "$SOCHS_PY" ] && [ "$restarted" -eq 0 ]; then
  systemctl enable --now "$TUNWS_INSTANCE" 2>/dev/null && ok "enable+start $TUNWS_INSTANCE"
fi

if [ -f "$OHP_UNIT" ]; then
  systemctl enable potato-ohp.service 2>/dev/null && ok "enable potato-ohp.service"
  systemctl restart potato-ohp.service 2>/dev/null && ok "restart potato-ohp.service" \
    || warn "potato-ohp.service gagal restart"
fi

sleep 2
verify

echo
info "Selesai. Backup & restore: $BK/restore.sh"
info "Rollback: bash $BK/restore.sh"
