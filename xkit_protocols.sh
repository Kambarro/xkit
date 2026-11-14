#!/bin/bash
# XKIT v7.5.13 — профили доступа: REALITY/XHTTP через 3X-UI; AWG/Hy2 — отдельной
# службой ИЛИ инбаундами панели (панельный режим v6.0.0, src/25_panel_protocols.sh).
# v7.2.7: AmneziaWG 3.1 (Header Protection) в обоих режимах; панельный режим —
# рекомендуемый путь для AWG (предлагается первым). Генератор параметров 3.1
# (awg31_gen_params) живёт в xkit.sh и доступен здесь после загрузки ядра.
# v7.4.2: Hy2 — тоже панель-первым (проба ядра + предложение инбаунда);
# ссылка отдельной службы добавляется в общие подписки (sub_standalone_hy2_link).
# Подключается только из xkit.sh. Секреты не выводятся в status/list --json.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "Это модуль XKIT — запускайте: xkit protocols" >&2
  exit 1
fi

XKIT_PROTOCOLS_ENV="${XKIT_PROTOCOLS_ENV:-/etc/xkit/protocols.env}"
XKIT_HY2_BIN="${XKIT_HY2_BIN:-/usr/local/bin/xkit-hysteria2}"
XKIT_HY2_CONF="${XKIT_HY2_CONF:-/etc/xkit/hysteria2/config.yaml}"
XKIT_HY2_UNIT="${XKIT_HY2_UNIT:-/etc/systemd/system/xkit-hysteria2.service}"
XKIT_AWG_CONF="${XKIT_AWG_CONF:-/etc/amnezia/amneziawg/awg0.conf}"
XKIT_AWG_CLIENTS_DIR="${XKIT_AWG_CLIENTS_DIR:-/root/xkit-awg}"
XKIT_AWG_STATE="${XKIT_AWG_STATE:-/etc/xkit/awg-clients.tsv}"
XKIT_AWG_SYSCTL="${XKIT_AWG_SYSCTL:-/etc/sysctl.d/99-xkit-awg.conf}"

proto_service_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

# TCP и UDP имеют независимые пространства портов: UDP 443/8443 не мешают
# REALITY или nginx на TCP 443. Проверяем именно UDP-слушателей.
proto_default_udp_port() { # $1 preferred -> свободный preferred или случайный
  local p="$1"
  if proto_udp_free "$p" 2>/dev/null; then printf '%s' "$p"; else rand_free_port 20000 60000; fi
}
proto_port_profile_pick() { # -> PROTO_HY2_PORT_DEFAULT / PROTO_AWG_PORT_DEFAULT
  echo 'Профиль UDP-портов:'
  echo ' 1) Balanced: AmneziaWG UDP 443 + Hysteria 2 UDP 8443'
  echo ' 2) Hysteria priority: Hysteria 2 UDP 443 + AmneziaWG UDP 51820'
  echo ' 3) Random high ports'
  local c; read -r -p 'Профиль [1]: ' c || return 1
  case "${c:-1}" in
    1) PROTO_AWG_PORT_DEFAULT="$(proto_default_udp_port 443)"; PROTO_HY2_PORT_DEFAULT="$(proto_default_udp_port 8443)" ;;
    2) PROTO_HY2_PORT_DEFAULT="$(proto_default_udp_port 443)"; PROTO_AWG_PORT_DEFAULT="$(proto_default_udp_port 51820)" ;;
    3) PROTO_HY2_PORT_DEFAULT="$(rand_free_port 20000 60000)"; PROTO_AWG_PORT_DEFAULT="$(rand_free_port 20000 60000)" ;;
    *) err 'Неизвестный профиль'; return 1 ;;
  esac
  [ -n "$PROTO_HY2_PORT_DEFAULT" ] && [ -n "$PROTO_AWG_PORT_DEFAULT" ] && [ "$PROTO_HY2_PORT_DEFAULT" != "$PROTO_AWG_PORT_DEFAULT" ]
}
proto_ports_list() {
  echo 'Профили (TCP 443 REALITY/nginx не конфликтует с этими UDP-портами):'
  echo '  balanced   AWG UDP 443    + Hysteria 2 UDP 8443'
  echo '  hy2-first  AWG UDP 51820  + Hysteria 2 UDP 443'
  echo '  random     два независимых высоких UDP-порта'
  proto_state_load 2>/dev/null || true
  echo "Текущие: AWG=${AWG_PORT:-${PANEL_AWG_PORT:-—}}/udp, Hysteria 2=${HY2_PORT:-${PANEL_HY2_PORT:-—}}/udp"
}
proto_hy2_masquerade_probe() { # $1 UDP port; 2 = локальный curl без HTTP/3
  local port="$1" body code
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  curl --version 2>/dev/null | grep -q 'HTTP3' || return 2
  body="$(mktemp /tmp/.xkit-hy2-probe.XXXXXX)" || return 1
  code="$(curl -k -sS --http3-only --max-time 8 --resolve "${XKIT_HOST}:${port}:127.0.0.1" \
    -o "$body" -w '%{http_code}' "https://${XKIT_HOST}:${port}/" 2>/dev/null)" || { rm -f "$body"; return 1; }
  [ "$code" = "200" ] && [ -s "$body" ] && grep -qi '<html' "$body"
  local rc=$?; rm -f "$body"; return "$rc"
}
proto_hy2_camo_check() {
  load_xkit_env 2>/dev/null || return 1; proto_state_load 2>/dev/null || true
  local p="${1:-${PANEL_HY2_PORT:-${HY2_PORT:-}}}"
  [ -n "$p" ] || { err 'Hysteria 2 не настроен'; return 1; }
  if proto_hy2_masquerade_probe "$p"; then ok "Masquerade HTTP/3 отвечает 200 и HTML: UDP $p";
  else local rc=$?; [ "$rc" = 2 ] && warn 'Проверка недоступна: системный curl собран без HTTP/3' || { err "Masquerade не прошёл активную HTTP/3-проверку на UDP $p"; return 1; }; fi
  warn 'Локальный masquerade probe не доказывает работоспособность Hysteria 2 или обход DPI из внешней сети.'
}
proto_json_status() { # id title kind installed status details
  jq -nc --arg id "$1" --arg title "$2" --arg kind "$3" --arg installed "$4" \
    --arg status "$5" --arg details "$6" \
    '{id:$id,title:$title,kind:$kind,installed:($installed=="1" or $installed=="true"),status:$status,details:$details}'
}

protocols_snapshot_json() {
  local reality=0 xhttp=0 inbounds="" awg_i=false hy2_i=false awg_s="not-installed" hy2_s="not-installed"
  local awg_d="PPA AmneziaWG" hy2_d="UDP + Salamander" r_d="3X-UI / TCP" x_d="3X-UI / XHTTP"
  if kit_session >/dev/null 2>&1; then
    inbounds="$(api_list 2>/dev/null || true)"
    if jq -e '[.[]?|select(.protocol=="vless")|(.streamSettings|fromjson?)|select(.security=="reality" and (.network=="tcp" or .network=="raw"))]|length>0' <<<"$inbounds" >/dev/null 2>&1; then reality=1; r_d="3X-UI / TCP / Vision"; fi
    if jq -e '[.[]?|select(.protocol=="vless")|(.streamSettings|fromjson?)|select(.security=="reality" and (.network=="xhttp" or .network=="splithttp"))]|length>0' <<<"$inbounds" >/dev/null 2>&1; then xhttp=1; x_d="3X-UI / XHTTP / REALITY"; fi
  fi
  # v6.0.0: панельный режим — инбаунды hysteria/amneziawg в самой панели
  local p_hy=0 p_awg=0 p_mode=""
  if [ -n "$inbounds" ]; then
    p_hy="$(jq -r '[.[]?|select(.protocol=="hysteria" and .enable != false)]|length' <<<"$inbounds" 2>/dev/null || echo 0)"
    p_awg="$(jq -r '[.[]?|select(.protocol=="amneziawg" and .enable != false)]|length' <<<"$inbounds" 2>/dev/null || echo 0)"
  fi
  if [ "${p_hy:-0}" -gt 0 ] || [ "${p_awg:-0}" -gt 0 ]; then p_mode="panel"; fi
  [ -f "$XKIT_AWG_CONF" ] && { awg_i=true; awg_d="AWG / UDP (служба)"; }
  [ -f "$XKIT_HY2_CONF" ] && { hy2_i=true; hy2_d="Hy2 / UDP / Salamander (служба)"; }
  if [ "$p_mode" = "panel" ]; then
    [ "${p_hy:-0}" -gt 0 ] && { hy2_i=true; hy2_d="Hy2 / UDP / панель (инбаунд)"; hy2_s="active"; }
    if [ "${p_awg:-0}" -gt 0 ]; then
      awg_i=true; awg_d="AWG / UDP / панель (инбаунд)"; awg_s="active"
      # v7.2.7: помечаем профиль 3.1, если инбаунд несёт HeaderProtectionKey
      if jq -e '[.[]?|select(.protocol=="amneziawg" and .enable != false)|(.settings|if type=="string" then fromjson else . end)|.server.headerProtectionKey // ""|length>0]|any' <<<"$inbounds" >/dev/null 2>&1; then
        awg_d="AWG 3.1 / UDP / панель (инбаунд)"
      fi
    fi
  fi
  if [ "$awg_i" = true ] && [ "$p_mode" != "panel" ]; then proto_service_active awg-quick@awg0 && awg_s="active" || awg_s="inactive"; fi
  if [ "$hy2_i" = true ] && [ "$p_mode" != "panel" ]; then proto_service_active xkit-hysteria2 && hy2_s="active" || hy2_s="inactive"; fi
  jq -n \
    --argjson reality "$(proto_json_status reality 'VLESS REALITY Vision' xray "$reality" "$([ "$reality" = 1 ] && echo configured || echo available)" "$r_d")" \
    --argjson xhttp "$(proto_json_status xhttp 'VLESS XHTTP REALITY' xray "$xhttp" "$([ "$xhttp" = 1 ] && echo configured || echo available)" "$x_d")" \
    --argjson awg "$(proto_json_status awg AmneziaWG service "$awg_i" "$awg_s" "$awg_d")" \
    --argjson hy2 "$(proto_json_status hy2 'Hysteria 2' service "$hy2_i" "$hy2_s" "$hy2_d")" \
    '[$reality,$xhttp,$awg,$hy2]'
}

protocols_list() {
  local j; j="$(protocols_snapshot_json)"
  if [ "${1:-}" = "--json" ]; then printf '%s\n' "$j"; return; fi
  printf '%-14s %-18s %-16s %s\n' ID ТИП СТАТУС ПРОФИЛЬ
  jq -r '.[]|[.id,.kind,.status,.details]|@tsv' <<<"$j" | while IFS=$'\t' read -r id kind st details; do
    printf '%-14s %-18s %-16s %s\n' "$id" "$kind" "$st" "$details"
  done
}

# Общий выбор dest/SNI для REALITY; результаты PROTO_DEST и PROTO_SNI.
proto_reality_target_pick() {
  echo "1) Свой сайт и сертификат XKIT"
  echo "2) Скан подсети"
  echo "3) Проверенный список"
  echo "4) Вручную"
  read -r -p "Источник REALITY [1-4]: " c || return 1
  PROTO_DEST=""; PROTO_SNI=""
  case "$c" in
    1)
      [ "$(host_kind "${XKIT_HOST:-}")" = domain ] && [ -f "${XKIT_CRT:-}" ] || { err "Нужен домен и сертификат"; return 1; }
      camo_site_install || return 1
      XKIT_REALITY_INTERNAL=1; save_xkit_env; regen_conf_and_apply || return 1
      PROTO_DEST="127.0.0.1:8444"; PROTO_SNI="$XKIT_HOST" ;;
    2) reality_scan_pick || return 1; PROTO_DEST="$RDEST"; PROTO_SNI="$RSNI" ;;
    3) reality_known_pick || return 1; PROTO_DEST="$RDEST"; PROTO_SNI="$RSNI" ;;
    4)
      local dh dp
      dh="$(read_host 'dest (IP или домен) -> ')" || return 1
      read -r -p 'Порт dest [443]: ' dp; dp="${dp:-443}"; is_port "$dp" || return 1
      PROTO_SNI="$(read_host 'SNI -> ')" || return 1; PROTO_DEST="${dh}:${dp}" ;;
    *) return 1 ;;
  esac
}

# VLESS + XHTTP + REALITY. Vision специально не добавляем: он для TCP/RAW.
proto_xhttp_create() {
  require_root; load_xkit_env || die "Сначала установка XKIT"; kit_session || return 1
  proto_reality_target_pick || return 1
  local p path uuid subid email sid priv pub
  p="$(rand_free_port 10000 60000)" || return 1
  read -r -p "Публичный порт XHTTP [${p}]: " pin; p="${pin:-$p}"
  is_port "$p" || { err "Некорректный порт"; return 1; }
  ! port_busy "$p" || { err "Порт $p занят"; return 1; }
  path="/xh-$(rand_str 8)"
  read -r -p "XHTTP path [${path}]: " pin; path="${pin:-$path}"
  is_nginx_path "$path" || { err "Небезопасный XHTTP path"; return 1; }
  read -r priv pub <<<"$(api_get_new_x25519)"
  [ -n "$priv" ] && [ -n "$pub" ] || { err "Нет ключей x25519"; return 1; }
  uuid="$(new_uuid)"; subid="$(rand_str 16)"; email="xhttp-$(rand_hex 2)"; sid="$(rand_hex 4)"
  local settings stream ib so
  so='{}'; sockopt_enabled && so="$(sockopt_obj)"   # v7.4.3: TFO+TCP_NODELAY
  settings='{"clients":[],"decryption":"none","fallbacks":[]}' 
  stream="$(jq -nc --arg dest "$PROTO_DEST" --arg sni "$PROTO_SNI" --arg priv "$priv" --arg sid "$sid" --arg pub "$pub" --arg path "$path" --argjson so "$so" '
    {network:"xhttp",security:"reality",
     xhttpSettings:{path:$path,host:"",mode:"auto"},
     realitySettings:{show:false,xver:0,dest:$dest,serverNames:[$sni],privateKey:$priv,
       minClient:"",maxClient:"",maxTimeDiff:0,shortIds:[$sid],
       settings:{publicKey:$pub,fingerprint:"chrome",serverName:""}}}
    + (if (($so|length) > 0) then {sockopt:$so} else {} end)')"
  ib="$(jq -nc --arg port "$p" --arg tag "inbound-${p}" --arg remark "xhttp-reality-${PROTO_SNI}" --arg s "$settings" --arg st "$stream" '
    {up:0,down:0,total:0,remark:$remark,enable:true,expiryTime:0,listen:"",port:($port|tonumber),protocol:"vless",settings:$s,streamSettings:$st,
     sniffing:"{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"]}",allocate:"{\"strategy\":\"always\",\"refresh\":5,\"concurrency\":-1}",tag:$tag}')"
  api_add_inbound "$ib" || return 1
  if [ "$so" != "{}" ]; then sockopt_tfo_sysctl_apply || true; fi   # v7.4.3: серверный бит TFO
  local ibid fresh
  ibid="$(jq -r --arg t "inbound-${p}" '[.[]|select(.tag==$t)][0].id // empty' <<<"$(api_list 2>/dev/null)")"
  [ -n "$ibid" ] || { err "Inbound создан, но не найден для проверки"; return 1; }
  fresh="$(api_get_inbound "$ibid")" || { api_del_inbound "$ibid" >/dev/null 2>&1 || true; err "Проверка не удалась — inbound удалён"; return 1; }
  if [ "$API_V3" = 1 ]; then v3_host_upsert "$ibid" "$XKIT_HOST" "$p" same || warn "Host-группу настройте в панели"; else
    fresh="$(jq -c --arg d "$XKIT_HOST" --argjson p "$p" '.externalProxy=[{dest:$d,port:$p,remark:"xkit"}]' <<<"$fresh")"
    api_update_inbound "$ibid" "$fresh" >/dev/null || { api_del_inbound "$ibid" >/dev/null 2>&1 || true; err "externalProxy не применён — откат"; return 1; }
    fresh="$(api_get_inbound "$ibid")" || return 1
  fi
  xkit_fw_add xhttp "$p" tcp || { api_del_inbound "$ibid" >/dev/null 2>&1 || true; err 'Не удалось открыть TCP-порт XHTTP — inbound удалён'; return 1; }
  ok "XHTTP + REALITY создан: ${XKIT_HOST}:${p}${path}"
  sub_regen_quiet || true
  ok "Автоматических пользователей нет — добавьте своего через «Пользователи»"
}

proto_state_load() { [ -r "$XKIT_PROTOCOLS_ENV" ] && . "$XKIT_PROTOCOLS_ENV"; }
proto_state_save() {
  mkdir -p "$(dirname "$XKIT_PROTOCOLS_ENV")" || return 1
  local t; t="$(mktemp "${XKIT_PROTOCOLS_ENV}.new.XXXXXX")" || return 1
  chmod 600 "$t"
  { printf 'HY2_PORT=%q\n' "${HY2_PORT:-}"; printf 'HY2_AUTH=%q\n' "${HY2_AUTH:-}"; printf 'HY2_OBFS=%q\n' "${HY2_OBFS:-}";
    printf 'AWG_PORT=%q\n' "${AWG_PORT:-}"; printf 'AWG_SERVER_PUB=%q\n' "${AWG_SERVER_PUB:-}"; printf 'AWG_DEV=%q\n' "${AWG_DEV:-}";
    # v6.0.0: панельный режим (инбаунды панели вместо отдельных служб)
    printf 'PROTO_MODE=%q\n' "${PROTO_MODE:-}";
    printf 'PANEL_HY2_PORT=%q\n' "${PANEL_HY2_PORT:-}"; printf 'PANEL_AWG_PORT=%q\n' "${PANEL_AWG_PORT:-}";
    printf 'PANEL_HY2_CAMO_MODE=%q\n' "${PANEL_HY2_CAMO_MODE:-string}";
    # v7.2.7: профиль обфускации AWG (awg31 | classic) в обоих режимах
    printf 'AWG_PROFILE=%q\n' "${AWG_PROFILE:-}"; printf 'PANEL_AWG_PROFILE=%q\n' "${PANEL_AWG_PROFILE:-}"; } >"$t" && mv -f "$t" "$XKIT_PROTOCOLS_ENV"
}

proto_hy2_download() { # $1 destination
  local meta tag asset base sums want got arch
  arch="$(uname -m)"; case "$arch" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) err "Hysteria 2: неподдерживаемая архитектура $arch"; return 1 ;; esac
  meta="$(mktemp /tmp/.xkit-hy2-meta.XXXXXX)" || return 1
  curl -fsSL --max-time 30 'https://api.github.com/repos/apernet/hysteria/releases/latest' -o "$meta" || { rm -f "$meta"; return 1; }
  tag="$(jq -r '.tag_name // empty' "$meta")"; asset="hysteria-linux-${arch}"
  base="$(jq -r --arg n "$asset" '.assets[]|select(.name==$n)|.browser_download_url' "$meta" | head -n1)"
  [ -n "$tag" ] && [ -n "$base" ] || { rm -f "$meta"; err "Не найден официальный бинарник $asset"; return 1; }
  sums="$(mktemp /tmp/.xkit-hy2-sums.XXXXXX)" || { rm -f "$meta"; return 1; }
  curl -fsSL "${base%/*}/hashes.txt" -o "$sums" || { rm -f "$meta" "$sums"; return 1; }
  want="$(awk -v n="$asset" '$2==n || $2=="*"n {print $1;exit}' "$sums")"
  [ -n "$want" ] || { rm -f "$meta" "$sums"; err "В hashes.txt нет $asset — установка отменена"; return 1; }
  curl -fsSL "$base" -o "$1" || { rm -f "$meta" "$sums"; return 1; }
  got="$(sha256sum "$1" | awk '{print $1}')"
  rm -f "$meta" "$sums"
  [ "$want" = "$got" ] || { err "SHA-256 Hysteria 2 не совпал"; return 1; }
  ok "Hysteria 2 ${tag}: SHA-256 проверен"
}

proto_hy2_install() {
  require_root; load_xkit_env || die "Сначала установка XKIT"
  [ -n "${XKIT_HOST:-}" ] && [ -r "${XKIT_CRT:-}" ] && [ -r "${XKIT_KEY:-}" ] || { err "Нужны XKIT_HOST и сертификат"; return 1; }
  if [ -f "$XKIT_HY2_CONF" ]; then warn "Hysteria 2 уже настроен"; return 0; fi
  # (v7.4.2) ПАНЕЛЬ-ПЕРВЫМ — паритет с AmneziaWG: если ядро панели умеет hysteria2,
  # панельный инбаунд рекомендован (единые пользователи/подписки/учёт трафика),
  # отдельная служба — осознательный выбор. Раньше меню сразу ставило службу —
  # вводило в заблуждение («в панели рекомендуется», а ставится отдельно).
  if kit_session >/dev/null 2>&1; then
    local p_hy=0
    p_hy="$(jq -r '[.[]|select(.protocol=="hysteria")]|length' <<<"${INBOUNDS:-}" 2>/dev/null || echo 0)"
    if [ "${p_hy:-0}" -eq 0 ]; then
      if proto_core_supports hysteria; then
        echo ""
        log "Ядро панели умеет Hysteria 2."
        if confirm "Включить ПАНЕЛЬНЫЙ режим Hysteria 2 (рекомендуется: единые пользователи, подписки, учёт трафика)? [Y/n]" y; then
          if proto_panel_install hy2; then return 0; fi
          warn "Панельный режим не удался — продолжаю отдельной службой"
        else
          log "Панельный режим отклонён — ставлю отдельной службой"
        fi
      fi
    else
      log "Панельный Hysteria 2 уже включён — отдельная служба не нужна (xkit protocols panel status)"
      return 0
    fi
  fi
  local p; p="$(proto_default_udp_port 8443)" || return 1
  read -r -p "UDP-порт Hysteria 2 [${p}]: " pin; p="${pin:-$p}"; is_port "$p" || return 1
  proto_udp_free "$p" || { err "UDP-порт $p уже занят"; return 1; }
  camo_site_install || { err 'Локальный camo для Hysteria 2 не создан'; return 1; }
  HY2_PORT="$p"; HY2_AUTH="$(rand_str 24)"; HY2_OBFS="$(rand_str 24)"
  local tmp; tmp="$(mktemp /tmp/.xkit-hy2-bin.XXXXXX)" || return 1
  proto_hy2_download "$tmp" || { rm -f "$tmp"; return 1; }
  mkdir -p "$(dirname "$XKIT_HY2_CONF")" || { rm -f "$tmp"; return 1; }
  install -m 755 "$tmp" "$XKIT_HY2_BIN" || { rm -f "$tmp"; return 1; }; rm -f "$tmp"
  local ctmp; ctmp="$(mktemp /tmp/.xkit-hy2-conf.XXXXXX)" || return 1
  cat >"$ctmp" <<EOF
listen: :${HY2_PORT}
tls:
  cert: ${XKIT_CRT}
  key: ${XKIT_KEY}
auth:
  type: password
  password: ${HY2_AUTH}
obfs:
  type: salamander
  salamander:
    password: ${HY2_OBFS}
masquerade:
  type: file
  file:
    dir: ${CAMO_DIR:-/var/www/camo}
EOF
  install -m 600 "$ctmp" "$XKIT_HY2_CONF" || { rm -f "$ctmp"; return 1; }; rm -f "$ctmp"
  cat >"$XKIT_HY2_UNIT" <<EOF
[Unit]
Description=XKIT Hysteria 2
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=${XKIT_HY2_BIN} server -c ${XKIT_HY2_CONF}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
  chmod 600 "$XKIT_HY2_UNIT"
  systemctl daemon-reload && systemctl enable --now xkit-hysteria2 || { systemctl disable xkit-hysteria2 >/dev/null 2>&1 || true; rm -f "$XKIT_HY2_CONF" "$XKIT_HY2_UNIT"; return 1; }
  sleep 1; proto_service_active xkit-hysteria2 || { journalctl -u xkit-hysteria2 -n 20 --no-pager; err "Служба не запустилась — конфиг удалён, бинарник оставлен"; systemctl disable --now xkit-hysteria2 >/dev/null 2>&1 || true; rm -f "$XKIT_HY2_CONF" "$XKIT_HY2_UNIT"; return 1; }
  if ! xkit_fw_add hysteria2 "$HY2_PORT" udp; then
    systemctl disable --now xkit-hysteria2 >/dev/null 2>&1 || true
    rm -f "$XKIT_HY2_CONF" "$XKIT_HY2_UNIT"; systemctl daemon-reload
    err 'Не удалось открыть UDP-порт Hysteria 2 — установка откачена'; return 1
  fi
  if ! proto_state_save; then
    systemctl disable --now xkit-hysteria2 >/dev/null 2>&1 || true
    xkit_fw_remove hysteria2 "$HY2_PORT" udp >/dev/null 2>&1 || true
    rm -f "$XKIT_HY2_CONF" "$XKIT_HY2_UNIT"; systemctl daemon-reload
    err 'Не удалось сохранить состояние Hysteria 2 — установка откачена'; return 1
  fi
  ok "Hysteria 2 запущен: UDP ${HY2_PORT}, Salamander включён, локальный camo"
  proto_hy2_camo_check "$HY2_PORT" || warn 'Активная проверка masquerade не пройдена — проверьте журнал и camo'
  proto_hy2_link
}

proto_hy2_link() {
  proto_state_load; [ -n "${HY2_PORT:-}" ] && [ -n "${HY2_AUTH:-}" ] || { err "Hysteria 2 не настроен"; return 1; }
  load_xkit_env || return 1
  local q="obfs=salamander&obfs-password=$(enc_uri "$HY2_OBFS")"
  [ "${XKIT_CERT_MODE:-}" = 4 ] && q+="&insecure=1" || q+="&sni=$(enc_uri "$XKIT_HOST")"
  printf 'hy2://%s@%s:%s?%s#%s\n' "$(enc_uri "$HY2_AUTH")" "$XKIT_HOST" "$HY2_PORT" "$q" "$(enc_uri 'XKIT-Hysteria2')"
}

proto_hy2_uninstall() {
  require_root; proto_state_load
  confirm "Остановить и удалить XKIT Hysteria 2?" || return 0
  systemctl disable --now xkit-hysteria2 >/dev/null 2>&1 || true
  rm -f "$XKIT_HY2_UNIT" "$XKIT_HY2_CONF"; systemctl daemon-reload
  [ -z "${HY2_PORT:-}" ] || xkit_fw_remove hysteria2 "$HY2_PORT" udp || warn 'Не удалось удалить правило XKIT Hysteria 2'
  HY2_PORT=""; HY2_AUTH=""; HY2_OBFS=""; proto_state_save
  ok "Служба и конфиг удалены; бинарник $XKIT_HY2_BIN оставлен"
}

proto_hy2_menu() {
  while :; do
    echo "1) Установить  2) Ссылка  3) Статус  4) Журнал  5) Проверить сайт-прикрытие  6) Удалить  0) Назад"
    read -r -p 'Hysteria 2: ' c || return
    case "$c" in
      1) proto_hy2_install ;; 2) proto_hy2_link ;;
      3) systemctl status xkit-hysteria2 --no-pager ;;
      4) journalctl -u xkit-hysteria2 -n 50 --no-pager ;;
      5) proto_hy2_camo_check ;;
      6) proto_hy2_uninstall ;; 0) return ;; *) warn 'Нет такого пункта' ;;
    esac
  done
}

proto_rand_range() { local min=$1 max=$2; awk -v s="$RANDOM$RANDOM" -v a="$min" -v b="$max" 'BEGIN{srand(s);print int(a+rand()*(b-a+1))}'; }
proto_awg_params() {
  AWG_S1="$(proto_rand_range 15 150)"; AWG_S2="$(proto_rand_range 15 150)"
  # (v7.2.7) S2=150 не должен выталкиваться в 151 при защите S1+56 != S2
  [ $((AWG_S1+56)) -ne "$AWG_S2" ] || { AWG_S2=$((AWG_S2+1)); [ "$AWG_S2" -le 150 ] || AWG_S2=$((AWG_S2-2)); }
  AWG_H1="$(proto_rand_range 5 2147483647)"; AWG_H2="$(proto_rand_range 5 2147483647)"
  AWG_H3="$(proto_rand_range 5 2147483647)"; AWG_H4="$(proto_rand_range 5 2147483647)"
  while [ "$AWG_H2" = "$AWG_H1" ]; do AWG_H2="$(proto_rand_range 5 2147483647)"; done
  while [ "$AWG_H3" = "$AWG_H1" ] || [ "$AWG_H3" = "$AWG_H2" ]; do AWG_H3="$(proto_rand_range 5 2147483647)"; done
  while [ "$AWG_H4" = "$AWG_H1" ] || [ "$AWG_H4" = "$AWG_H2" ] || [ "$AWG_H4" = "$AWG_H3" ]; do AWG_H4="$(proto_rand_range 5 2147483647)"; done
}

#--- v7.2.7: AmneziaWG 3.1 (отдельная служба) -----------------------------------
# PPA amnezia раздаёт AWG 3.1 с 12.08.2026 — «поставил амнезию, а конфиг у кита
# маленький и без новых аргументов» больше не воспроизводится: профиль выбирается
# по реальной версии инструментов (awg --version), а не по версии apt-пакета
# (amneziawg-dkms числится 1.0.0-0~…, содержимое — в суффиксе с хешем коммита).
proto_awg_tools_major() { # старший номер amneziawg-tools («v3.1.20260812» -> 3); 0 = awg нет
  local v m
  v="$(awg --version 2>/dev/null)" || { printf '0'; return; }
  m="$(sed -n 's/.*v\([0-9][0-9]*\)\..*/\1/p' <<<"$v" | head -n1)"
  printf '%s' "${m:-0}"
}

# Ключи обфускации [Interface], которые ОБЯЗАНЫ попадать из конфига сервера в
# клиентский: S1-S4 и H1-H4 (must match), I1-I5, HeaderProtectionKey,
# ContentPaddingAddition, тайминги и MTU. Единый список — новые ключи AWG
# начинают наследоваться клиентами без правки proto_awg_add.
PROTO_AWG_OBF_RE='^(Jc|Jmin|Jmax|S1|S2|S3|S4|H1|H2|H3|H4|I1|I2|I3|I4|I5|HeaderProtectionKey|ContentPaddingAddition|RekeyAfterTime|RekeyTimeout|RejectAfterTime|KeepaliveTimeout|MaxHandshakeAttempts|MTU) = '
proto_awg_obf_block() { # $1 конфиг сервера -> блок обфускации в stdout
  grep -E "$PROTO_AWG_OBF_RE" "$1" 2>/dev/null || true
}
proto_awg_is_31() { [ -f "$1" ] && grep -q '^HeaderProtectionKey = ' "$1" 2>/dev/null; }

# Перевод ЖИВОЙ классической установки на профиль 3.1: перегенерация блока
# обфускации сервера и ВСЕХ клиентских конфигов (ключи сервера/пиров и psk
# сохраняются), рестарт с проверкой, при незапуске — откат к бэкапам.
proto_awg_upgrade31() {
  require_root; [ -f "$XKIT_AWG_CONF" ] || { err 'Сначала установите AmneziaWG'; return 1; }
  [ "$(proto_awg_tools_major)" -ge 3 ] || { err "Инструменты AWG < 3.x ($(awg --version 2>/dev/null || echo 'awg не найден')) — профиль 3.1 недоступен (PPA раздаёт 3.1: apt-get update && apt-get install --only-upgrade amneziawg)"; return 1; }
  proto_awg_is_31 "$XKIT_AWG_CONF" && { ok 'Уже профиль 3.1 (Header Protection)'; return 0; }
  confirm "Перевести AmneziaWG на профиль 3.1 (Header Protection)? Клиентские конфиги нужно раздать заново" || return 0
  load_xkit_env || return 1; proto_state_load
  local stamp tmp iface_base peers_part obf f
  stamp="$(date +%Y%m%d%H%M%S)"
  cp -f "$XKIT_AWG_CONF" "${XKIT_AWG_CONF}.bak-${stamp}" || return 1
  awg31_gen_params # из xkit.sh (src/25_panel_protocols.sh)
  iface_base="$(awk 'BEGIN{sec=0} /^\[Peer\]/{sec=1} !sec{print}' "$XKIT_AWG_CONF" | grep -v -E "$PROTO_AWG_OBF_RE")"
  peers_part="$(awk 'BEGIN{sec=0} /^\[Peer\]/{sec=1} sec{print}' "$XKIT_AWG_CONF")"
  obf="$(cat <<EOF
MTU = ${AWG31_MTU}
Jc = ${AWG31_JC}
Jmin = ${AWG31_JMIN}
Jmax = ${AWG31_JMAX}
S1 = ${AWG31_S1}
S2 = ${AWG31_S2}
S3 = ${AWG31_S3}
S4 = ${AWG31_S4}
H1 = ${AWG31_H1}
H2 = ${AWG31_H2}
H3 = ${AWG31_H3}
H4 = ${AWG31_H4}
I1 = ${AWG31_I1}
HeaderProtectionKey = ${AWG31_HPK}
ContentPaddingAddition = ${AWG31_CPA}
RekeyAfterTime = ${AWG31_RKAT}
RekeyTimeout = ${AWG31_RT}
RejectAfterTime = ${AWG31_RJT}
KeepaliveTimeout = ${AWG31_KAT}
MaxHandshakeAttempts = ${AWG31_MHA}
EOF
)"
  tmp="$(mktemp /tmp/.xkit-awg31.XXXXXX)" || return 1
  { printf '%s\n' "$iface_base"; printf '%s\n' "$obf"; [ -n "$peers_part" ] && printf '\n%s\n' "$peers_part"; } >"$tmp"
  install -m 600 "$tmp" "$XKIT_AWG_CONF" || { rm -f "$tmp"; cp -f "${XKIT_AWG_CONF}.bak-${stamp}" "$XKIT_AWG_CONF"; return 1; }; rm -f "$tmp"
  # клиентские конфиги: тот же блок обфускации, ключи/пиры не трогаем
  local up_cl=0
  for f in "$XKIT_AWG_CLIENTS_DIR"/*.conf; do
    [ -f "$f" ] || continue
    cp -f "$f" "${f}.bak-${stamp}" || continue
    local ci cp_peers
    ci="$(awk 'BEGIN{sec=0} /^\[Peer\]/{sec=1} !sec{print}' "$f" | grep -v -E "$PROTO_AWG_OBF_RE")"
    cp_peers="$(awk 'BEGIN{sec=0} /^\[Peer\]/{sec=1} sec{print}' "$f")"
    { printf '%s\n' "$ci"; printf '%s\n' "$obf"; [ -n "$cp_peers" ] && printf '\n%s\n' "$cp_peers"; } >"$f"
    chmod 600 "$f"; up_cl=$((up_cl+1))
  done
  systemctl restart awg-quick@awg0 && sleep 1 && proto_service_active awg-quick@awg0 || {
    cp -f "${XKIT_AWG_CONF}.bak-${stamp}" "$XKIT_AWG_CONF"
    for f in "$XKIT_AWG_CLIENTS_DIR"/*.conf; do [ -f "${f}.bak-${stamp}" ] && cp -f "${f}.bak-${stamp}" "$f"; done
    systemctl restart awg-quick@awg0 >/dev/null 2>&1 || true
    err 'AWG не запустился с профилем 3.1 — откачено. Проверьте модуль: dkms status (нужна третья линия; PPA — 3.1 с 12.08.2026, возможно нужен перезапуск после пересборки модуля)'
    return 1
  }
  AWG_PROFILE="awg31"; proto_state_save >/dev/null 2>&1 || true
  ok "AmneziaWG переведён на профиль 3.1 (Header Protection), MTU ${AWG31_MTU}; клиентских конфигов обновлено: ${up_cl}"
  warn 'Раздайте обновлённые конфиги заново (клиенты 3.1: AmneziaVPN >= 5.0.1.5, AmneziaWG >= 3.1, WG Tunnel >= 5.6) — со старыми конфигами подключения не будет'
}

proto_awg_rollback_install() {
  systemctl disable --now awg-quick@awg0 >/dev/null 2>&1 || true
  xkit_awg_route_remove "${AWG_DEV:-}" >/dev/null 2>&1 || true
  [ -z "${AWG_PORT:-}" ] || xkit_fw_remove awg "$AWG_PORT" udp >/dev/null 2>&1 || true
  rm -f "$XKIT_AWG_CONF" "$XKIT_AWG_SYSCTL"
}

proto_awg_install() {
  require_root; load_xkit_env || die "Сначала установка XKIT"
  # (v7.2.7) ПАНЕЛЬ-ПЕРВЫМ: если ядро панели умеет amneziawg — панельный режим
  # рекомендован (единые пользователи/подписки/учёт трафика), отдельная служба —
  # осознанный выбор. Сбой панельного пути — честный откат к отдельной службе.
  if kit_session >/dev/null 2>&1; then
    local p_awg=0
    p_awg="$(jq -r '[.[]|select(.protocol=="amneziawg")]|length' <<<"${INBOUNDS:-}" 2>/dev/null || echo 0)"
    if [ "${p_awg:-0}" -eq 0 ]; then
      if proto_awg31_supported || proto_core_supports amneziawg; then
        echo ""
        log "Ядро панели умеет AmneziaWG."
        if confirm "Включить ПАНЕЛЬНЫЙ режим AmneziaWG (рекомендуется: единые пользователи, подписки, учёт трафика)? [Y/n]" y; then
          if proto_panel_install awg; then return 0; fi
          warn "Панельный режим не удался — продолжаю отдельной службой"
        else
          log "Панельный режим отклонён — ставлю отдельной службой"
        fi
      fi
    else
      log "Панельный AmneziaWG уже включён — отдельная служба не нужна (xkit protocols panel status)"
    fi
  fi
  [ -f "$XKIT_AWG_CONF" ] && {
    warn 'AmneziaWG уже настроен'
    if proto_awg_is_31 "$XKIT_AWG_CONF"; then
      ok 'Профиль: 3.1 (Header Protection)'
    elif [ "$(proto_awg_tools_major)" -ge 3 ]; then
      echo ''
      log 'Обнаружен классический профиль (без Header Protection), инструменты AWG >= 3.x.'
      confirm 'Перевести на профиль 3.1 (Header Protection)? Клиентские конфиги нужно раздать заново [y/N]' && proto_awg_upgrade31
    fi
    return 0
  }
  command -v awg >/dev/null 2>&1 && command -v awg-quick >/dev/null 2>&1 || {
    log 'Установка официального пакета AmneziaWG из PPA...'
    apt-get update && apt-get install -y software-properties-common python3-launchpadlib gnupg2 || return 1
    # (мелочь №9, аудит v5.2.1): у -cloud/-HWE ядер заголовков точной версии может
    # не быть в репо — пробуем точную, иначе generic
    apt-get install -y "linux-headers-$(uname -r)" 2>/dev/null || {
      warn "linux-headers-$(uname -r) недоступны в репозитории — ставлю linux-headers-generic"
      apt-get install -y linux-headers-generic || return 1
    }
    add-apt-repository -y ppa:amnezia/ppa && apt-get update && apt-get install -y amneziawg || return 1
  }
  # (v7.2.7) профиль обфускации — по РЕАЛЬНОЙ версии инструментов: PPA раздаёт
  # 3.1 с 12.08.2026, apt-версии пакета не отражают линию протокола
  local tools_major profile="classic"
  tools_major="$(proto_awg_tools_major)"
  if [ "$tools_major" -ge 3 ]; then
    echo ''
    echo 'Профиль обфускации AmneziaWG (инструменты >= 3.x):'
    echo ' 1) Полный AWG 3.1 — Header Protection, паддинги S1-S4, тайминг-джиттер (рекомендуется;'
    echo '    клиенты: AmneziaVPN >= 5.0.1.5, AmneziaWG >= 3.1, WG Tunnel >= 5.6, свежий Mihomo)'
    echo ' 2) Классический — как в прошлых версиях XKIT (старые клиенты, роутеры Keenetic)'
    local pc; read -r -p 'Профиль [1]: ' pc || return 1
    case "${pc:-1}" in
      1) profile="awg31" ;;
      2) profile="classic" ;;
      *) err 'Нет такого профиля'; return 1 ;;
    esac
  else
    warn "Инструменты AmneziaWG < 3.x ($(awg --version 2>/dev/null || echo 'awg не найден')) — ставлю классический профиль"
    warn 'PPA amnezia раздаёт 3.1 с 12.08.2026: apt-get update && apt-get install --only-upgrade amneziawg'
  fi
  local p; p="$(proto_default_udp_port 443)" || return 1
  read -r -p "UDP-порт AmneziaWG [${p}]: " pin; p="${pin:-$p}"; is_port "$p" || return 1
  proto_udp_free "$p" || { err "UDP-порт $p уже занят"; return 1; }
  local dev priv pub psk old_dev
  dev="$(ip route show default 2>/dev/null | awk '/default/{print $5;exit}')"
  [[ "$dev" =~ ^[A-Za-z0-9_.-]+$ ]] || { err 'Не удалось определить внешний интерфейс'; return 1; }
  # (баг №4, аудит v5.2.1): запоминаем прежний внешний интерфейс до перезаписи
  old_dev=""
  [ -n "${XKIT_PROTOCOLS_ENV:-}" ] && [ -f "$XKIT_PROTOCOLS_ENV" ] && \
    old_dev="$(. "$XKIT_PROTOCOLS_ENV" 2>/dev/null; printf '%s' "${AWG_DEV:-}")"
  priv="$(awg genkey)" || return 1; pub="$(printf '%s' "$priv" | awg pubkey)" || return 1; psk="$(awg genpsk)" || return 1
  AWG_PORT="$p"; AWG_SERVER_PUB="$pub"; AWG_DEV="$dev"; AWG_PROFILE="$profile"
  if [ "$profile" = "awg31" ]; then
    awg31_gen_params # из xkit.sh (src/25_panel_protocols.sh)
  else
    proto_awg_params
  fi
  mkdir -p "$(dirname "$XKIT_AWG_CONF")" "$XKIT_AWG_CLIENTS_DIR" "$(dirname "$XKIT_AWG_STATE")" || return 1
  chmod 700 "$XKIT_AWG_CLIENTS_DIR"; : >"$XKIT_AWG_STATE"; chmod 600 "$XKIT_AWG_STATE"
  local tmp; tmp="$(mktemp /tmp/.xkit-awg.XXXXXX)" || return 1
  cat >"$tmp" <<EOF
# Managed by XKIT v7.2.8 — резервная копия включается в xkit backup
[Interface]
Address = 10.77.0.1/24
ListenPort = ${AWG_PORT}
PrivateKey = ${priv}
EOF
  if [ "$profile" = "awg31" ]; then
    cat >>"$tmp" <<EOF
MTU = ${AWG31_MTU}
Jc = ${AWG31_JC}
Jmin = ${AWG31_JMIN}
Jmax = ${AWG31_JMAX}
S1 = ${AWG31_S1}
S2 = ${AWG31_S2}
S3 = ${AWG31_S3}
S4 = ${AWG31_S4}
H1 = ${AWG31_H1}
H2 = ${AWG31_H2}
H3 = ${AWG31_H3}
H4 = ${AWG31_H4}
I1 = ${AWG31_I1}
HeaderProtectionKey = ${AWG31_HPK}
ContentPaddingAddition = ${AWG31_CPA}
RekeyAfterTime = ${AWG31_RKAT}
RekeyTimeout = ${AWG31_RT}
RejectAfterTime = ${AWG31_RJT}
KeepaliveTimeout = ${AWG31_KAT}
MaxHandshakeAttempts = ${AWG31_MHA}
EOF
  else
    cat >>"$tmp" <<EOF
Jc = 8
Jmin = 8
Jmax = 80
S1 = ${AWG_S1}
S2 = ${AWG_S2}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}
EOF
  fi
  cat >>"$tmp" <<EOF
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${dev} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${dev} -j MASQUERADE
EOF
  install -m 600 "$tmp" "$XKIT_AWG_CONF" || { rm -f "$tmp"; return 1; }; rm -f "$tmp"
  printf 'net.ipv4.ip_forward=1\n' >"$XKIT_AWG_SYSCTL"; chmod 644 "$XKIT_AWG_SYSCTL"; sysctl --system >/dev/null
  systemctl enable --now awg-quick@awg0 || { rm -f "$XKIT_AWG_CONF"; return 1; }
  sleep 1; proto_service_active awg-quick@awg0 || {
    systemctl disable --now awg-quick@awg0 >/dev/null 2>&1 || true; rm -f "$XKIT_AWG_CONF"
    if [ "$profile" = "awg31" ]; then
      err 'AWG не запустился с профилем 3.1; конфиг удалён. Проверьте модуль: dkms status — нужна третья линия (PPA раздаёт 3.1 с 12.08.2026; после пересборки модуля может понадобиться перезапуск)'
    else
      err 'AWG не запустился; конфиг удалён'
    fi
    return 1
  }
  # (баг №4, аудит v5.2.1): при смене внешнего интерфейса снимаем route-правила
  # старой пары — иначе XKIT:awg-forward остаётся на прошлом dev
  if [ -n "$old_dev" ] && [ "$old_dev" != "$dev" ]; then
    xkit_awg_route_remove "$old_dev" >/dev/null 2>&1 || true
  fi
  if ! xkit_fw_add awg "$AWG_PORT" udp || ! xkit_awg_route_add "$AWG_DEV"; then
    proto_awg_rollback_install
    err 'Не удалось настроить firewall/forwarding AWG — установка откачена'; return 1
  fi
  if ! proto_state_save; then
    proto_awg_rollback_install
    err 'Не удалось сохранить состояние AWG — установка откачена'; return 1
  fi
  if [ "$profile" = "awg31" ]; then
    ok "AmneziaWG запущен: UDP ${AWG_PORT}, профиль 3.1 (Header Protection), MTU ${AWG31_MTU}"
  else
    ok "AmneziaWG запущен: UDP ${AWG_PORT}, классический профиль"
  fi
  proto_awg_add
}

proto_awg_add() {
  require_root; [ -f "$XKIT_AWG_CONF" ] || { err 'Сначала установите AmneziaWG'; return 1; }
  proto_state_load; load_xkit_env || return 1
  local name ipn priv pub psk dns
  read -r -p 'Имя клиента [client1]: ' name; name="${name:-client1}"
  [[ "$name" =~ ^[a-zA-Z0-9_-]{1,32}$ ]] || { err 'Имя: только латиница, цифры, _ и -'; return 1; }
  [ -f "$XKIT_AWG_CLIENTS_DIR/$name.conf" ] && { err 'Клиент уже существует'; return 1; }
  ipn=2; while awk -F'\t' -v n="$ipn" '$2==n{found=1}END{exit !found}' "$XKIT_AWG_STATE" 2>/dev/null; do ipn=$((ipn+1)); done
  [ "$ipn" -le 254 ] || { err 'Пул 10.77.0.0/24 заполнен'; return 1; }
  priv="$(awg genkey)"; pub="$(printf '%s' "$priv" | awg pubkey)"; psk="$(awg genpsk)"
  read -r -p 'DNS клиента [1.1.1.1]: ' dns; dns="${dns:-1.1.1.1}"; is_ip "$dns" || return 1
  local ctmp; ctmp="$(mktemp /tmp/.xkit-awg-client.XXXXXX)" || return 1
  # (v7.2.7) блок обфускации наследуется из awg0.conf целиком (S1-S4, H1-H4,
  # I1-I5, HeaderProtectionKey, ContentPaddingAddition, тайминги, MTU) —
  # «маленький конфиг без аргументов» больше невозможен в любом профиле
  cat >"$ctmp" <<EOF
[Interface]
PrivateKey = ${priv}
Address = 10.77.0.${ipn}/32
DNS = ${dns}
$(proto_awg_obf_block "$XKIT_AWG_CONF")
[Peer]
PublicKey = ${AWG_SERVER_PUB}
PresharedKey = ${psk}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${XKIT_HOST}:${AWG_PORT}
PersistentKeepalive = 25
EOF
  install -m 600 "$ctmp" "$XKIT_AWG_CLIENTS_DIR/$name.conf" || { rm -f "$ctmp"; return 1; }; rm -f "$ctmp"
  cp -f "$XKIT_AWG_CONF" "${XKIT_AWG_CONF}.bak" || return 1
  cat >>"$XKIT_AWG_CONF" <<EOF

[Peer] # xkit:${name}
PublicKey = ${pub}
PresharedKey = ${psk}
AllowedIPs = 10.77.0.${ipn}/32
EOF
  systemctl restart awg-quick@awg0 && proto_service_active awg-quick@awg0 || {
    mv -f "${XKIT_AWG_CONF}.bak" "$XKIT_AWG_CONF"; systemctl restart awg-quick@awg0 >/dev/null 2>&1 || true
    rm -f "$XKIT_AWG_CLIENTS_DIR/$name.conf"; err 'Не удалось применить peer — выполнен откат'; return 1;
  }
  printf '%s\t%s\t%s\n' "$name" "$ipn" "$pub" >>"$XKIT_AWG_STATE"; chmod 600 "$XKIT_AWG_STATE"
  ok "Клиент $name: $XKIT_AWG_CLIENTS_DIR/$name.conf"
}

proto_awg_list() {
  [ -s "$XKIT_AWG_STATE" ] || { warn 'Клиентов нет'; return; }
  awk -F'\t' '{printf "%-24s 10.77.0.%s/32  %s\n",$1,$2,$3}' "$XKIT_AWG_STATE"
}
proto_awg_show() {
  proto_awg_list; read -r -p 'Имя клиента: ' name || return 1
  [[ "$name" =~ ^[a-zA-Z0-9_-]{1,32}$ ]] && [ -f "$XKIT_AWG_CLIENTS_DIR/$name.conf" ] || return 1
  cat "$XKIT_AWG_CLIENTS_DIR/$name.conf"
}
proto_awg_uninstall() {
  require_root; proto_state_load; confirm 'Удалить только конфигурацию XKIT AmneziaWG?' || return 0
  systemctl disable --now awg-quick@awg0 >/dev/null 2>&1 || true
  xkit_awg_route_remove "${AWG_DEV:-}" || warn 'Не удалось удалить route-правила XKIT AWG'
  rm -f "$XKIT_AWG_CONF" "$XKIT_AWG_SYSCTL"
  [ -z "${AWG_PORT:-}" ] || xkit_fw_remove awg "$AWG_PORT" udp || warn 'Не удалось удалить входящее правило XKIT AWG'
  AWG_PORT=""; AWG_SERVER_PUB=""; AWG_DEV=""; AWG_PROFILE=""; proto_state_save
  ok 'Служба XKIT AWG удалена; пакеты и клиентские конфиги сохранены'
}
proto_awg_menu() {
  while :; do
    echo '1) В панели (рекомендуется): инбаунд 3X-UI — единые пользователи и подписки'
    echo '2) Установить отдельной службой (ядро ОС: awg-quick, профиль 3.1 или классический)'
    echo '3) Добавить клиента'
    echo '4) Список клиентов'
    echo '5) Показать конфиг клиента'
    echo '6) Статус службы'
    echo '7) Перевести существующую службу на профиль 3.1 (Header Protection)'
    echo '8) Удалить службу'
    echo '0) Назад'
    read -r -p 'AmneziaWG: ' c || return
    case "$c" in
      1) proto_panel_install awg ;;
      2) proto_awg_install ;; 3) proto_awg_add ;; 4) proto_awg_list ;; 5) proto_awg_show ;;
      6) systemctl status awg-quick@awg0 --no-pager ;; 7) proto_awg_upgrade31 ;; 8) proto_awg_uninstall ;;
      0) return ;; *) warn 'Нет такого пункта' ;; esac
  done
}

protocols_menu() {
  while :; do
    echo; protocols_list
    echo '1) VLESS + REALITY + Vision'
    echo '2) VLESS + XHTTP + REALITY'
    echo '3) AmneziaWG (в панели — рекомендуется; можно отдельной службой, обе умеют AWG 3.1)'
    echo '4) Hysteria 2 (в панели — рекомендуется; можно отдельной службой)'
    echo '5) Панельный режим: AWG + Hy2 как инбаунды панели (вкл/выкл)'
    echo '6) Профили UDP-портов и совместимость'
    echo '7) Удалить протокол (конкретный inbound, с подтверждением)'
    echo '0) Назад'
    read -r -p 'Протоколы: ' c || return
    case "$c" in 1) reality_wizard ;; 2) proto_xhttp_create ;; 3) proto_awg_menu ;; 4) proto_hy2_menu ;; 5) proto_panel_menu ;; 6) proto_ports_list ;; 7) protocol_remove ;; 0) return ;; *) warn 'Нет такого пункта' ;; esac
  done
}

protocols_main() {
  case "${1:-menu}" in
    menu) protocols_menu ;; list) protocols_list "${2:-}" ;; status) protocols_list ;; remove) protocol_remove ;;
    reality) reality_wizard ;; xhttp) proto_xhttp_create ;;
    awg) case "${2:-menu}" in menu) proto_awg_menu ;; install) proto_awg_install ;; add) proto_awg_add ;; list) proto_awg_list ;; show) proto_awg_show ;; upgrade31) proto_awg_upgrade31 ;; status) systemctl status awg-quick@awg0 --no-pager ;; uninstall) proto_awg_uninstall ;; *) return 1 ;; esac ;;
    hysteria2|hy2) case "${2:-menu}" in menu) proto_hy2_menu ;; install) proto_hy2_install ;; link) proto_hy2_link ;; camo-check) proto_hy2_camo_check "${3:-}" ;; status) systemctl status xkit-hysteria2 --no-pager ;; uninstall) proto_hy2_uninstall ;; *) return 1 ;; esac ;;
    ports) proto_ports_list ;;
    panel) case "${2:-menu}" in menu) proto_panel_menu ;; install|on) proto_panel_install "${3:-all}" ;; uninstall|off) proto_panel_uninstall ;; status) proto_panel_status ;; camo-check) proto_hy2_camo_check "${3:-}" ;; *) return 1 ;; esac ;;
    *) err 'xkit protocols [list|status|reality|xhttp|awg|hysteria2|panel]'; return 1 ;;
  esac
}
