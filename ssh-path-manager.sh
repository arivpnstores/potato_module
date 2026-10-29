#!/usr/bin/env bash
#
# PATH SSH MANAGER
# Kelola path SSH WS (custom path) pada config muxer HAProxy.
#
#   muxer  : /usr/sbin/library   (backend HAProxy)
#   config : /libc64/module      (frontend "proxy" -> backend to_ng)
#   unit   : local.service
#
# Pemakaian:
#   bash /root/ssh-path-manager.sh
#
# Override lewat environment bila perlu, contoh:
#   MUXER_CONF=/libc64/module FRONTEND=proxy BACKEND=to_ng \
#     TEST_HOST=domainkamu.com bash /root/ssh-path-manager.sh

set -u
set -o pipefail
umask 022

# ======================= KONFIGURASI =======================
MUXER_CONF="${MUXER_CONF:-/libc64/module}"
MUXER_BIN="${MUXER_BIN:-/usr/sbin/library}"
MUXER_SERVICE="${MUXER_SERVICE:-local.service}"
MUXER_EXTRAOPTS="${MUXER_EXTRAOPTS:--S /run/fetch.pull}"
FRONTEND="${FRONTEND:-proxy}"
BACKEND="${BACKEND:-to_ng}"
BACKEND_ADDR="${BACKEND_ADDR:-127.0.0.1:2996}"

STATE_DIR="${STATE_DIR:-/etc/ssh-path-manager}"
STATE_FILE="$STATE_DIR/paths.list"
BACKUP_DIR="${BACKUP_DIR:-/root/backup_vps}"
BACKUP_TARGETS=(libc64/module etc/ssh-path-manager)

TEST_HOST="${TEST_HOST:-$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo 127.0.0.1)}"
TEST_PORTS="${TEST_PORTS:-80 443}"
TEST_TIMEOUT="${TEST_TIMEOUT:-8}"

# ======================= WARNA =======================
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_CYN=$'\033[36m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_BLD=""; C_RST=""
fi

ok()   { printf '%s[OK]%s %s\n'   "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[!]%s  %s\n'   "$C_YEL" "$C_RST" "$*"; }
err()  { printf '%s[X]%s  %s\n'   "$C_RED" "$C_RST" "$*" >&2; }
info() { printf '%s[i]%s  %s\n'   "$C_CYN" "$C_RST" "$*"; }

# ======================= UTIL =======================
require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "Jalankan sebagai root: sudo bash $0"
    exit 1
  fi
}

require_muxer() {
  if [[ ! -x "$MUXER_BIN" ]]; then
    err "Muxer tidak ditemukan / tidak executable: $MUXER_BIN"
    exit 1
  fi
  if [[ ! -f "$MUXER_CONF" ]]; then
    err "Config muxer tidak ditemukan: $MUXER_CONF"
    exit 1
  fi
}

ensure_dirs() {
  mkdir -p "$STATE_DIR" "$BACKUP_DIR"
  [[ -f "$STATE_FILE" ]] || : > "$STATE_FILE"
}

now_stamp() { date +%Y%m%d-%H%M%S; }

# ======================= STATE (custom path) =======================
state_get_path() {
  awk -F'|' -v n="$1" '$1==n{print $2; exit}' "$STATE_FILE"
}

state_has_name() {
  awk -F'|' -v n="$1" '$1==n{found=1} END{exit !found}' "$STATE_FILE"
}

state_add() {
  printf '%s|%s\n' "$1" "$2" >> "$STATE_FILE"
}

state_del() {
  local name="$1" tmp
  tmp="$(mktemp)"
  awk -F'|' -v n="$name" '$1!=n' "$STATE_FILE" > "$tmp"
  cat "$tmp" > "$STATE_FILE"
  rm -f "$tmp"
}

# ======================= BAGIAN FRONTEND DI CONFIG =======================
section_bounds() {
  SEC_START="$(awk -v fe="$FRONTEND" '
    BEGIN { p = "^frontend[ \t]+" fe "([ \t]|$)" }
    $0 ~ p { print NR; exit }
  ' "$MUXER_CONF")"

  if [[ -z "${SEC_START:-}" ]]; then
    err "Frontend '$FRONTEND' tidak ditemukan di $MUXER_CONF"
    return 1
  fi

  SEC_END="$(awk -v s="$SEC_START" '
    NR > s && /^(frontend|backend|listen|global|defaults)[ \t]/ { print NR; exit }
  ' "$MUXER_CONF")"
  [[ -n "${SEC_END:-}" ]] || SEC_END=$(( $(wc -l < "$MUXER_CONF") + 1 ))
  return 0
}

# Daftar nama acl sesuai urutan config
acl_names() {
  awk -v s="$SEC_START" -v e="$SEC_END" '
    NR > s && NR < e && $0 ~ /^[ \t]*acl[ \t]+/ {
      line = $0
      sub(/^[ \t]*acl[ \t]+/, "", line)
      split(line, a, /[ \t]+/)
      if (a[1] != "") print a[1]
    }
  ' "$MUXER_CONF"
}

acl_expr() {
  awk -v s="$SEC_START" -v e="$SEC_END" -v n="$1" '
    NR > s && NR < e && $0 ~ /^[ \t]*acl[ \t]+/ {
      line = $0
      sub(/^[ \t]*acl[ \t]+/, "", line)
      split(line, a, /[ \t]+/)
      if (a[1] == n) {
        expr = substr(line, length(a[1]) + 1)
        sub(/^[ \t]+/, "", expr)
        print expr
        exit
      }
    }
  ' "$MUXER_CONF"
}

# ACL yang diarahkan ke BACKEND (to_ng)
active_acls() {
  awk -v s="$SEC_START" -v e="$SEC_END" -v be="$BACKEND" '
    NR > s && NR < e && $0 ~ /^[ \t]*use_backend[ \t]+/ {
      line = $0
      sub(/^[ \t]*use_backend[ \t]+/, "", line)
      split(line, a, /[ \t]+/)
      if (a[1] != be) next
      p = index(line, " if ")
      if (p == 0) next
      cond = substr(line, p + 4)
      cnt = split(cond, c, /[ \t]+/)
      for (i = 1; i <= cnt; i++)
        if (c[i] != "" && c[i] != "or" && c[i] != "and" && c[i] != "!")
          print c[i]
    }
  ' "$MUXER_CONF"
}

is_active_acl() {
  local needle="$1" a
  while read -r a; do
    [[ "$a" == "$needle" ]] && return 0
  done < <(active_acls)
  return 1
}

# Ubah ekspresi ACL menjadi path yang bisa dites
derive_path() {
  local expr="$1" r
  r="${expr#* -i }"
  r="${r//\\\//\/}"
  r="${r#^}"
  if [[ "$r" =~ ^/\(\.\*\)/([A-Za-z0-9._-]+) ]]; then
    printf '/x/%s' "${BASH_REMATCH[1]}"
    return
  fi
  if [[ "$r" =~ ^/([A-Za-z0-9._/-]+)\(\.\*\)$ ]]; then
    printf '/%s' "${BASH_REMATCH[1]}"
    return
  fi
  if [[ "$r" == "/" || "$r" == "/(.*)" || -z "$r" ]]; then
    printf '/'
    return
  fi
  printf '%s' "$r"
}

# Prefix yang "dipakai" backend lain (agar path baru tidak bentrok)
reserved_prefix_for() {
  local name="$1" expr path
  expr="$(acl_expr "$name")"
  [[ -n "$expr" ]] || return 0
  path="$(derive_path "$expr")"
  [[ "$path" == "/" || "$path" == */"*"* ]] && return 0
  printf '%s' "$path"
}

# ======================= VALIDASI / RELOAD =======================
validate_file() {
  local file="$1"
  "$MUXER_BIN" -c -q -f "$file" >/tmp/spm-validate.log 2>&1
}

validate_config() {
  if [[ ! -f "$MUXER_CONF" ]]; then
    err "Config tidak ada: $MUXER_CONF"
    return 1
  fi
  info "Validasi config: $MUXER_CONF"
  if validate_file "$MUXER_CONF"; then
    ok "Config valid."
    return 0
  fi
  err "Config TIDAK valid:"
  sed 's/^/    /' /tmp/spm-validate.log >&2
  return 1
}

reload_service() {
  info "Reload $MUXER_SERVICE ..."
  if systemctl reload "$MUXER_SERVICE" 2>/dev/null; then
    ok "Service $MUXER_SERVICE di-reload."
    return 0
  fi
  warn "Reload gagal, mencoba restart $MUXER_SERVICE ..."
  if systemctl restart "$MUXER_SERVICE" 2>/dev/null; then
    ok "Service $MUXER_SERVICE di-restart."
    return 0
  fi
  err "Gagal reload/restart $MUXER_SERVICE."
  return 1
}

apply_config() {
  local prev="$1"
  if validate_config; then
    if reload_service; then
      rm -f "$prev"
      return 0
    fi
  fi
  err "Rollback config ke kondisi sebelumnya..."
  [[ -n "$prev" && -f "$prev" ]] && cat "$prev" > "$MUXER_CONF"
  validate_config >/dev/null 2>&1 || true
  reload_service >/dev/null 2>&1 || true
  rm -f "$prev"
  return 1
}

# ======================= TEST PATH =======================
test_path_port() {
  local path="$1" port="$2" scheme="http"
  [[ "$port" == "443" || "$port" == "8443" ]] && scheme="https"

  # Jalur cepat: baca status line lalu tutup koneksi. curl menunggu sampai
  # max-time karena koneksi 101 tetap terbuka, jadi probe jadi lambat.
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$TEST_HOST" "$port" "$path" "$TEST_TIMEOUT" <<'PY' 2>/dev/null
import socket, ssl, sys
host, port, path, timeout = sys.argv[1], int(sys.argv[2]), sys.argv[3], float(sys.argv[4])
req = ("GET %s HTTP/1.1\r\nHost: %s\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n"
       "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
       % (path, host))
s = None
try:
    s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    s.settimeout(timeout)
    if port in (443, 8443):
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        s = ctx.wrap_socket(s, server_hostname=host)
    s.sendall(req.encode())
    data = b""
    while b"\r\n" not in data and len(data) < 4096:
        chunk = s.recv(1024)
        if not chunk:
            break
        data += chunk
    parts = data.split(b"\r\n", 1)[0].decode("latin1", "replace").split()
    print(parts[1] if len(parts) >= 2 and parts[0].startswith("HTTP/") else "000")
except Exception:
    print("000")
finally:
    if s is not None:
        try:
            s.close()
        except Exception:
            pass
PY
    return
  fi

  local code
  code="$(curl -k -s -o /dev/null -w '%{http_code}' \
    --http1.1 --max-time "$TEST_TIMEOUT" \
    --resolve "${TEST_HOST}:${port}:127.0.0.1" \
    -H "Host: $TEST_HOST" \
    -H 'Connection: Upgrade' \
    -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    "${scheme}://${TEST_HOST}:${port}${path}" 2>/dev/null)"
  printf '%s' "${code:-000}"
}

declare -A STATUS_CACHE=()

compute_statuses() {
  local -a targets=("$@")
  [[ ${#targets[@]} -gt 0 ]] || return 0
  local path port code attempt i found

  # Uji satu per satu (bukan paralel). Probe paralel ke frontend SSL bisa
  # membuat handshake saling berebut dan timeout, sehingga path yang
  # sebenarnya hidup tampil OFF.
  for i in "${!targets[@]}"; do
    path="${targets[$i]}"
    local -a active=()
    for port in $TEST_PORTS; do
      found=0
      for attempt in 1 2; do
        code="$(test_path_port "$path" "$port")"
        if [[ "$code" == "101" ]]; then found=1; break; fi
        [[ "$attempt" -eq 1 ]] && sleep 0.2
      done
      [[ "$found" -eq 1 ]] && active+=("$port")
    done
    if [[ ${#active[@]} -gt 0 ]]; then
      STATUS_CACHE["$path"]="${C_GRN}AKTIF ($(IFS=,; echo "${active[*]}"))${C_RST}"
    else
      STATUS_CACHE["$path"]="${C_RED}OFF${C_RST}"
    fi
  done
}

status_label() {
  local path="$1"
  if [[ -n "${STATUS_CACHE[$path]:-}" ]]; then
    printf '%s' "${STATUS_CACHE[$path]}"
  else
    compute_statuses "$path"
    printf '%s' "${STATUS_CACHE[$path]:-${C_RED}OFF${C_RST}}"
  fi
}

test_path_interactive() {
  local path
  read -rp "Path yang dites (contoh /ssh): " path
  path="${path//[[:space:]]/}"
  if [[ -z "$path" ]]; then err "Path kosong."; return; fi
  [[ "$path" == /* ]] || path="/$path"
  info "Test $path (harus 101) via $TEST_HOST ..."
  local port code
  for port in $TEST_PORTS; do
    code="$(test_path_port "$path" "$port")"
    printf '  %-6s : %s\n' "$port" "$code"
  done
}

# ======================= STATUS / HEADER =======================
show_status() {
  local mtime
  mtime="$(date -r "$MUXER_CONF" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '-')"
  echo -e "${C_BLD}${C_CYN}════════════════ PATH SSH MANAGER ════════════════${C_RST}"
  printf ' %-18s: %s\n' "muxer" "$MUXER_BIN"
  printf ' %-18s: %s\n' "config" "$MUXER_CONF"
  printf ' %-18s: %s\n' "unit" "$MUXER_SERVICE"
  printf ' %-18s: %s\n' "backend nginx ws" "$BACKEND ($BACKEND_ADDR)"
  printf ' %-18s: %s\n' "frontend acl" "$FRONTEND"
  printf ' %-18s: %s\n' "config mtime" "$mtime"
  echo "───────────────────────────────────────────────────────────────"
  printf ' %-16s %-20s %-18s %-9s %s\n' "NAMA" "PATH" "STATUS" "MODE" "ASAL"
  echo "───────────────────────────────────────────────────────────────"

  local -a names=() paths=() origins=()
  local -a miss_names=() miss_paths=()
  local name expr path origin

  while read -r name; do
    [[ -n "$name" ]] || continue
    is_active_acl "$name" || continue
    expr="$(acl_expr "$name")"
    path="$(state_get_path "$name")"
    [[ -n "$path" ]] || path="$(derive_path "$expr")"
    if state_has_name "$name"; then origin="CUSTOM"; else origin="DEFAULT"; fi
    names+=("$name"); paths+=("$path"); origins+=("$origin")
  done < <(acl_names)

  # custom yang sudah tidak ada di config
  local sname spath
  while IFS='|' read -r sname spath; do
    [[ -n "${sname:-}" ]] || continue
    is_active_acl "$sname" && continue
    miss_names+=("$sname"); miss_paths+=("$spath")
  done < "$STATE_FILE"

  STATUS_CACHE=()
  compute_statuses "${paths[@]}"

  local i
  for i in "${!names[@]}"; do
    printf ' %-16s %-20s %-18b %-9s %s\n' "${names[$i]}" "${paths[$i]}" "$(status_label "${paths[$i]}")" "proxy" "${origins[$i]}"
  done
  for i in "${!miss_names[@]}"; do
    printf ' %-16s %-20s %-18s %-9s %s\n' "${miss_names[$i]}" "${miss_paths[$i]}" "MISSING" "proxy" "CUSTOM"
  done

  if [[ ${#names[@]} -eq 0 && ${#miss_names[@]} -eq 0 ]]; then
    echo " (belum ada path yang diarahkan ke $BACKEND)"
  fi
  echo "═══════════════════════════════════════════════════════════════"
}

# ======================= EDIT CONFIG =======================
insert_after_line() {
  local file="$1" line="$2" text="$3"
  LINE="$line" TEXT="$text" awk '
    NR == ENVIRON["LINE"] { print; printf "%s\n", ENVIRON["TEXT"]; next }
    { print }
  ' "$file" > "$file.spm.tmp" && cat "$file.spm.tmp" > "$file" && rm -f "$file.spm.tmp"
}

insert_before_line() {
  local file="$1" line="$2" text="$3"
  LINE="$line" TEXT="$text" awk '
    NR == ENVIRON["LINE"] { printf "%s\n", ENVIRON["TEXT"]; print; next }
    { print }
  ' "$file" > "$file.spm.tmp" && cat "$file.spm.tmp" > "$file" && rm -f "$file.spm.tmp"
}

add_lines_to() {
  local file="$1" acl_name="$2" regex="$3" before_line="${4:-}"
  local acl_line ub_line
  acl_line="$(awk -v s="$SEC_START" -v e="$SEC_END" '
    NR > s && NR < e && $0 ~ /^[ \t]*acl[ \t]+/ { n = NR }
    END { print n + 0 }
  ' "$file")"
  [[ "$acl_line" -eq 0 ]] && acl_line="$SEC_START"

  local acl_text="  acl $acl_name path_reg -i $regex"
  local ub_text="  use_backend $BACKEND if $acl_name"

  # Ada ACL lain yang prefix-nya lebih luas: taruh use_backend kita di
  # depannya supaya menang duluan (HAProxy memakai rule pertama yang cocok).
  if [[ -n "$before_line" && "$before_line" =~ ^[0-9]+$ && "$before_line" -gt 0 ]]; then
    insert_before_line "$file" "$before_line" "$ub_text"
    [[ "$acl_line" -ge "$before_line" ]] && acl_line=$((acl_line + 1))
    insert_after_line "$file" "$acl_line" "$acl_text"
    return
  fi

  ub_line="$(awk -v s="$SEC_START" -v e="$SEC_END" -v be="$BACKEND" '
    BEGIN { p = "^[ \t]*use_backend[ \t]+" be "([ \t]|$)" }
    NR > s && NR < e && $0 ~ p { n = NR }
    END { print n + 0 }
  ' "$file")"
  [[ "$ub_line" -eq 0 ]] && ub_line="$acl_line"

  if [[ "$ub_line" -ge "$acl_line" ]]; then
    insert_after_line "$file" "$ub_line" "$ub_text"
    insert_after_line "$file" "$acl_line" "$acl_text"
  else
    insert_after_line "$file" "$acl_line" "$acl_text"
    insert_after_line "$file" "$ub_line" "$ub_text"
  fi
}

remove_lines_from() {
  local file="$1" acl_name="$2" tmp
  tmp="$(mktemp)"
  awk -v s="$SEC_START" -v e="$SEC_END" -v n="$acl_name" '
    NR > s && NR < e {
      if ($0 ~ /^[ \t]*acl[ \t]+/) {
        line = $0
        sub(/^[ \t]*acl[ \t]+/, "", line)
        split(line, a, /[ \t]+/)
        if (a[1] == n) next
      }
      if ($0 ~ /^[ \t]*use_backend[ \t]+/) {
        line = $0
        sub(/^[ \t]*use_backend[ \t]+/, "", line)
        p = index(line, " if ")
        if (p > 0) {
          cond = substr(line, p + 4)
          gsub(/^[ \t]+|[ \t]+$/, "", cond)
          if (cond == n) next
        }
      }
    }
    { print }
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

slugify() {
  printf '%s' "$1" \
    | sed -e 's#^/##' -e 's#/#_#g' -e 's/[^A-Za-z0-9_.-]/_/g' \
    | sed -e 's/__*/_/g' -e 's/^_//' -e 's/_$//'
}

normalize_path() {
  local p="$1"
  p="${p//[[:space:]]/}"
  [[ "$p" == /* ]] || p="/$p"
  while [[ "$p" == *"//"* ]]; do p="${p//\/\//\/}"; done
  [[ "$p" != "/" && "$p" == */ ]] && p="${p%/}"
  printf '%s' "$p"
}

regex_for_path() {
  local p="${1#/}"
  p="${p//./\\.}"
  p="${p//\//\\/}"
  printf '^\\/%s(.*)' "$p"
}

valid_path() {
  local p="$1"
  [[ -n "$p" ]] || return 1
  [[ "$p" == /* ]] || return 1
  [[ "$p" != "/" ]] || return 1
  [[ "$p" != *".."* ]] || return 1
  [[ "$p" =~ ^/[A-Za-z0-9._/-]+$ ]] || return 1
  return 0
}

make_name() {
  local path="$1" base candidate n
  base="path_$(slugify "$path")"
  [[ "$base" == "path_" ]] && base="path_custom"
  candidate="$base"; n=1
  while state_has_name "$candidate" || acl_name_taken "$candidate"; do
    n=$((n + 1))
    candidate="${base}${n}"
  done
  printf '%s' "$candidate"
}

acl_name_taken() {
  local n="$1"
  [[ -n "$(acl_expr "$n")" ]]
}

# Cek bentrok yang TIDAK bisa diselesaikan dengan urutan use_backend:
#   - path sama persis dengan backend lain, atau
#   - path baru lebih luas dari path backend lain (mis. /vm saat ada /vmess).
# Path baru yang lebih spesifik (mis. /vmess/ssh saat ada /vm) DIIZINKAN;
# urutannya diatur oleh shadowing_acls/priority_line_for.
path_conflicts() {
  local path lower name expr prefix plower
  path="$1"
  lower="${path,,}"
  while read -r name; do
    [[ -n "$name" ]] || continue
    is_active_acl "$name" && continue
    expr="$(acl_expr "$name")"
    [[ -n "$expr" ]] || continue
    prefix="$(derive_path "$expr")"
    [[ "$prefix" == "/" || "$prefix" == "/x/"* ]] && continue
    plower="${prefix,,}"
    # ACL backend lain memakai regex prefix (^\/vm(.*)), jadi cek prefix mentah
    if [[ "$plower" == "$lower"* ]]; then
      printf '%s' "$name"
      return 0
    fi
  done < <(acl_names)
  return 1
}

# ACL backend lain yang prefix-nya lebih luas dari path baru. use_backend
# untuk path baru harus diletakkan SEBELUM use_backend ACL-ACL ini, kalau
# tidak, request akan "tertelan" oleh ACL yang lebih luas (mis. ^\/vm(.*)).
shadowing_acls() {
  local path lower name expr prefix plower
  path="$1"
  lower="${path,,}"
  while read -r name; do
    [[ -n "$name" ]] || continue
    is_active_acl "$name" && continue
    expr="$(acl_expr "$name")"
    [[ -n "$expr" ]] || continue
    prefix="$(derive_path "$expr")"
    [[ "$prefix" == "/" || "$prefix" == "/x/"* ]] && continue
    plower="${prefix,,}"
    [[ "$lower" == "$plower"* && "$lower" != "$plower" ]] || continue
    printf '%s\n' "$name"
  done < <(acl_names)
}

# Baris use_backend (backend apa pun) yang memakai ACL $1 sebagai kondisi.
any_use_backend_line() {
  awk -v s="$SEC_START" -v e="$SEC_END" -v n="$1" '
    NR > s && NR < e && $0 ~ /^[ \t]*use_backend[ \t]+/ {
      line = $0
      p = index(line, " if ")
      if (p == 0) next
      cond = substr(line, p + 4)
      cnt = split(cond, a, /[ \t]+/)
      for (i = 1; i <= cnt; i++)
        if (a[i] == n) { print NR; exit }
    }
  ' "$MUXER_CONF"
}

# Baris paling awal tempat use_backend path baru harus disisipkan (0 = bebas).
priority_line_for() {
  local path="$1" name ln best=0
  while read -r name; do
    [[ -n "$name" ]] || continue
    ln="$(any_use_backend_line "$name")"
    [[ -n "$ln" ]] || continue
    if [[ "$best" -eq 0 || "$ln" -lt "$best" ]]; then
      best="$ln"
    fi
  done < <(shadowing_acls "$path")
  printf '%s' "$best"
}

path_duplicate() {
  local wanted="$1" name expr p
  while read -r name; do
    [[ -n "$name" ]] || continue
    is_active_acl "$name" || continue
    expr="$(acl_expr "$name")"
    p="$(state_get_path "$name")"
    [[ -n "$p" ]] || p="$(derive_path "$expr")"
    [[ "$p" == "$wanted" ]] && { printf '%s' "$name"; return 0; }
  done < <(acl_names)
  return 1
}

# ======================= AKSI: TAMBAH =======================
preview_add_lines() {
  local acl_name="$1" regex="$2"
  echo "  acl $acl_name path_reg -i $regex"
  echo "  use_backend $BACKEND if $acl_name"
}

add_path_common() {
  local raw="$1" requested_name="$2" path regex acl_name prev conflict dup before
  path="$(normalize_path "$raw")"

  if ! valid_path "$path"; then
    err "Path tidak valid: '$raw' (contoh: /ssh, /x/ssh, /naytra)"
    return 1
  fi
  if dup="$(path_duplicate "$path")"; then
    err "Path $path sudah aktif sebagai '$dup'."
    return 1
  fi
  if conflict="$(path_conflicts "$path")"; then
    err "Path $path bentrok dengan ACL '$conflict' (backend lain)."
    err "Pilih path lain, misal /${path#/}-ssh atau /ssh-${path#/}."
    return 1
  fi

  regex="$(regex_for_path "$path")"
  before="$(priority_line_for "$path")"
  if [[ -n "$requested_name" ]]; then
    requested_name="${requested_name//[[:space:]]/}"
    if ! [[ "$requested_name" =~ ^[A-Za-z0-9_.-]+$ ]]; then
      err "Nama tidak valid (hanya huruf/angka/._-)."
      return 1
    fi
    if state_has_name "$requested_name" || acl_name_taken "$requested_name"; then
      err "Nama '$requested_name' sudah dipakai."
      return 1
    fi
    acl_name="$requested_name"
  else
    acl_name="$(make_name "$path")"
  fi

  prev="$(mktemp)"
  cp -a "$MUXER_CONF" "$prev"

  add_lines_to "$MUXER_CONF" "$acl_name" "$regex" "$before"
  info "Menambahkan: $acl_name -> $path"
  if [[ -n "$before" && "$before" -gt 0 ]]; then
    info "Path bersarang: rule diprioritaskan (baris $before) agar tidak tertelan ACL yang lebih luas."
  fi
  preview_add_lines "$acl_name" "$regex" | sed 's/^/    /'

  if apply_config "$prev"; then
    state_add "$acl_name" "$path"
    ok "Path $path aktif ($acl_name)."
    return 0
  fi
  err "Gagal menambahkan path, config dikembalikan."
  return 1
}

add_path() {
  local raw name
  read -rp "Path baru (contoh /ssh atau /x/ssh): " raw
  read -rp "Nama ACL (kosongkan untuk otomatis): " name
  add_path_common "$raw" "$name"
}

dry_run_add() {
  local raw name path regex acl_name tmp dup conflict before
  read -rp "Dry-run path baru: " raw
  read -rp "Nama ACL (kosongkan untuk otomatis): " name
  path="$(normalize_path "$raw")"

  if ! valid_path "$path"; then err "Path tidak valid."; return; fi
  if dup="$(path_duplicate "$path")"; then err "Path sudah aktif sebagai '$dup'."; return; fi
  if conflict="$(path_conflicts "$path")"; then err "Bentrok dengan ACL '$conflict'."; return; fi

  regex="$(regex_for_path "$path")"
  before="$(priority_line_for "$path")"
  name="${name//[[:space:]]/}"
  if [[ -n "$name" ]]; then
    if state_has_name "$name" || acl_name_taken "$name"; then err "Nama '$name' sudah dipakai."; return; fi
    acl_name="$name"
  else
    acl_name="$(make_name "$path")"
  fi

  tmp="$(mktemp /tmp/spm-dryrun.XXXXXX.conf)"
  cp -a "$MUXER_CONF" "$tmp"
  add_lines_to "$tmp" "$acl_name" "$regex" "$before"

  echo "Preview baris yang akan ditambahkan:"
  preview_add_lines "$acl_name" "$regex" | sed 's/^/    /'
  if [[ -n "$before" && "$before" -gt 0 ]]; then
    echo "    (use_backend diletakkan sebelum baris $before agar diprioritaskan)"
  fi
  echo

  if validate_file "$tmp"; then
    ok "Dry-run VALID. Config asli tidak diubah."
    rm -f "$tmp"
    return 0
  fi
  err "Dry-run GAGAL:"
  sed 's/^/    /' /tmp/spm-validate.log >&2
  rm -f "$tmp"
  return 1
}

# ======================= AKSI: HAPUS =======================
delete_path() {
  local -a names=() paths=() origins=()
  local name expr p
  while read -r name; do
    [[ -n "$name" ]] || continue
    is_active_acl "$name" || continue
    expr="$(acl_expr "$name")"
    p="$(state_get_path "$name")"
    [[ -n "$p" ]] || p="$(derive_path "$expr")"
    names+=("$name"); paths+=("$p")
    if state_has_name "$name"; then origins+=("CUSTOM"); else origins+=("DEFAULT"); fi
  done < <(acl_names)

  if [[ ${#names[@]} -eq 0 ]]; then warn "Belum ada path aktif."; return; fi

  local i choice
  echo "Daftar path aktif:"
  for i in "${!names[@]}"; do
    printf '  %2d) %-16s %-20s [%s]\n' "$((i + 1))" "${names[$i]}" "${paths[$i]}" "${origins[$i]}"
  done
  read -rp "Nomor yang dihapus (0=batal): " choice
  [[ "$choice" =~ ^[0-9]+$ ]] || { err "Input tidak valid."; return; }
  [[ "$choice" -eq 0 ]] && return
  [[ "$choice" -ge 1 && "$choice" -le ${#names[@]} ]] || { err "Nomor tidak ada."; return; }

  name="${names[$((choice - 1))]}"
  p="${paths[$((choice - 1))]}"
  if [[ "${origins[$((choice - 1))]}" == "DEFAULT" ]]; then
    warn "Ini path DEFAULT (bawaan config). Menghapus bisa memutus layanan!"
    read -rp "Yakin hapus $name ($p)? [y/N]: " ans
    [[ "${ans,,}" == "y" ]] || { info "Dibatalkan."; return; }
  fi

  local prev
  prev="$(mktemp)"
  cp -a "$MUXER_CONF" "$prev"
  remove_lines_from "$MUXER_CONF" "$name"

  info "Menghapus $name ($p) ..."
  if apply_config "$prev"; then
    state_del "$name"
    ok "Path $name dihapus."
  else
    err "Gagal menghapus, config dikembalikan."
  fi
}

# ======================= BACKUP / RESTORE =======================
backup_now() {
  ensure_dirs
  local host ip stamp archive target existing=()
  host="$(hostname -s 2>/dev/null || echo vps)"
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -n "$ip" ]] || ip="$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo 0.0.0.0)"
  stamp="$(date +%d_%m_%y-%H%M%S)"

  for target in "${BACKUP_TARGETS[@]}"; do
    [[ -e "/$target" ]] && existing+=("$target")
  done
  if [[ ${#existing[@]} -eq 0 ]]; then
    err "Tidak ada target backup yang ditemukan."
    return 1
  fi

  if command -v zip >/dev/null 2>&1; then
    archive="$BACKUP_DIR/${host}-${ip}-${stamp}.zip"
    info "Membuat backup: $archive"
    if (cd / && zip -qr "$archive" "${existing[@]}"); then
      ok "Backup selesai ($(du -h "$archive" | awk '{print $1}'))."
      return 0
    fi
    rm -f "$archive"; err "Backup zip gagal."; return 1
  fi

  archive="$BACKUP_DIR/${host}-${ip}-${stamp}.tar.gz"
  info "Membuat backup: $archive"
  if (cd / && tar -czf "$archive" "${existing[@]}"); then
    ok "Backup selesai ($(du -h "$archive" | awk '{print $1}'))."
    return 0
  fi
  rm -f "$archive"; err "Backup gagal."; return 1
}

backup_files() {
  ensure_dirs
  shopt -s nullglob
  BACKUP_FILES=("$BACKUP_DIR"/*.zip "$BACKUP_DIR"/*.tar.gz "$BACKUP_DIR"/*.tgz)
  shopt -u nullglob
}

list_backups() {
  backup_files
  if [[ ${#BACKUP_FILES[@]} -eq 0 ]]; then
    warn "Belum ada backup di $BACKUP_DIR"
    return 1
  fi
  local i f
  for i in "${!BACKUP_FILES[@]}"; do
    f="${BACKUP_FILES[$i]}"
    printf '  %2d) %-60s %s\n' "$((i + 1))" "$(basename "$f")" "$(du -h "$f" | awk '{print $1}')"
  done
}

restore_backup() {
  backup_files
  if [[ ${#BACKUP_FILES[@]} -eq 0 ]]; then warn "Belum ada backup."; return; fi
  local i
  echo "Daftar backup:"
  for i in "${!BACKUP_FILES[@]}"; do
    printf '  %2d) %s\n' "$((i + 1))" "$(basename "${BACKUP_FILES[$i]}")"
  done
  local choice f ans
  read -rp "Nomor yang direstore (0=batal): " choice
  [[ "$choice" =~ ^[0-9]+$ ]] || { err "Input tidak valid."; return; }
  [[ "$choice" -eq 0 ]] && return
  [[ "$choice" -ge 1 && "$choice" -le ${#BACKUP_FILES[@]} ]] || { err "Nomor tidak ada."; return; }
  f="${BACKUP_FILES[$((choice - 1))]}"

  read -rp "Backup config sekarang dulu? [Y/n]: " ans
  if [[ "${ans,,}" != "n" ]]; then backup_now || warn "Backup gagal, lanjut restore..."; fi

  info "Restore $(basename "$f") ..."
  if [[ "$f" == *.zip ]]; then
    (cd / && unzip -oq "$f") || { err "Restore gagal."; return; }
  else
    (cd / && tar -xzf "$f") || { err "Restore gagal."; return; }
  fi

  ensure_dirs
  ok "Restore selesai."
  if validate_config; then
    read -rp "Reload $MUXER_SERVICE sekarang? [Y/n]: " ans
    [[ "${ans,,}" != "n" ]] && reload_service
  fi
}

# ======================= MENU =======================
main_menu() {
  local pilihan
  while true; do
    echo
    show_status
    echo
    echo "1) Tambah path custom"
    echo "2) Hapus path"
    echo "3) Test path (harus 101)"
    echo "4) Dry-run tambah path"
    echo "5) Daftar backup"
    echo "6) Restore backup"
    echo "7) Backup sekarang"
    echo "8) Validasi config"
    echo "9) Reload service"
    echo "0) Keluar"
    read -rp "Pilih: " pilihan || break
    echo
    case "$pilihan" in
      1) add_path ;;
      2) delete_path ;;
      3) test_path_interactive ;;
      4) dry_run_add ;;
      5) list_backups ;;
      6) restore_backup ;;
      7) backup_now ;;
      8) validate_config ;;
      9) reload_service ;;
      0|q|Q) info "Keluar."; break ;;
      *) warn "Pilihan tidak dikenal." ;;
    esac
    read -rp "Tekan Enter untuk lanjut..." _ || break
  done
}

bootstrap() {
  require_root
  require_muxer
  ensure_dirs
  if ! section_bounds; then
    err "Pastikan FRONTEND=$FRONTEND ada di $MUXER_CONF."
    exit 1
  fi
  if ! validate_file "$MUXER_CONF"; then
    warn "Config saat ini gagal validasi. Perbaiki dulu sebelum mengubah path."
    sed 's/^/    /' /tmp/spm-validate.log >&2
  fi
}

bootstrap
main_menu "$@"
