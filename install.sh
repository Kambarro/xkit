#!/bin/bash
#==============================================================================
#  XKIT installer — установка xkit.sh одной командой (XKIT v9.0.0)
#
#  GitHub (рекомендуемый вариант, все компоненты релиза в одном репо):
#    curl -fsSL https://raw.githubusercontent.com/kambarro/xkit/main/install.sh | sudo bash
#
#  Свой сервер (ядро, меню, протоколы, TUI и пломба в одной папке за nginx):
#    curl -fsSL https://ВАШ_ДОМЕН/xkit/install.sh | sudo bash
#
#  Скачанный заранее файл:
#    sudo bash install.sh          # полная установка
#    bash install.sh status        # любая субкоманда xkit (help, status...)
#
#  Можно переопределить источник:  XKIT_BASE=https://... bash install.sh
#  или передать URL первым аргументом: bash install.sh https://.../xkit.sh
#
#  Неинтерактивно (CI/cloud-init): флаги после -- в пайпе (иначе bash
#  съест -y как СВОЙ аргумент и до скрипта он не дойдёт):
#    curl -fsSL https://.../install.sh | sudo bash -s -- -y
#==============================================================================

# Ник репозитория уже вписан (kambarro) — установка одной строкой работает без правок.
# Форкнули/переименовали? Замените ник ниже или задайте XKIT_BASE/URL при запуске:
XKIT_BASE="${XKIT_BASE:-https://raw.githubusercontent.com/kambarro/xkit/main}"

# (K-02, аудит №2) pin-хэши релиза: подставляются при сборке. Placeholder =
# dev-режим — тогда сумма берётся из xkit.sh.sha256; нет ни того ни другого — отказ
XKIT_PIN_SHA256="3791eb3f1b3c5684b2ec7602c72534e06bfb7ffd948bb39550933f20655685cd"
XKIT_PIN_MENU_SHA256="30afd95204641019a5c731b11aa606316347a1dfeee770c840dc25b432894e46"
XKIT_PIN_PROTOCOLS_SHA256="1714b6442c352a1c63b33191ea3d268a0d2525abca3c1192a090ae8ee4a83719"
XKIT_PIN_TUI_AMD64_SHA256="71406325e21596749b3106dd7284dda51ec3887ce2f03e22f1f146131e508d90"
XKIT_PIN_TUI_ARM64_SHA256="8a6f5b9a875ffb162cdf71b118505bd921cff89cd5e2829ece926e70bf00c37a"
XKIT_PIN_SITEGEN_SHA256="84f82f4b28463a7891eca56d2f4fc7446bb7959d226dfa50fa7e0fbf71c3aa37"
XKIT_PIN_CAMO_SITEGEN_SHA256="027d25c44a0a4f80afb9129cf3dc09dd4202238afa3d77ded0e084def76f8026"
XKIT_PIN_BENCH_SHA256="fbc7d7ec27f59939ba798f456ed3d31931c6d3d4604a63e6d563b19a4974ae04"
XKIT_PIN_IPREGION_SHA256="14d0ced7771aba1e721054fec3dfbfcb0a8455158e0b7966125345d0d05c0770"

# v6.0.0: Ed25519-подпись релиза (ssh-keygen -Y, namespace xkit-release).
# Подставляется сборкой из ключей релиза; placeholder = dev-режим (фолбэк на пин-книгу).
# Ротация ключа: в переходный релиз вшиваем СТАРЫЙ ключ во вторую переменную,
# в следующем — убираем (см. §14 CHANGES.md).
XKIT_SIGN_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIONDF2O6OM2hoByRNYEV43lEc0RFyO2mlUMQruOPRVgn"
XKIT_SIGN_PUBKEY_PREV="@@XKIT_SIGN_PUBKEY_PREV@@"

# проверка подписанного SHA256SUMS: 0 = ок; 1 = подписи/ключа нет (фолбэк на пины); 2 = БИТАЯ
sig_verify_dir() { # $1 каталог с SHA256SUMS(+.sig) и файлами
  local d="$1"
  [ -f "$d/SHA256SUMS" ] && [ -f "$d/SHA256SUMS.sig" ] || return 1
  [ "$XKIT_SIGN_PUBKEY" != "@@XKIT_SIGN_PUBKEY@@" ] || return 1
  command -v ssh-keygen >/dev/null 2>&1 || { warn "ssh-keygen не найден — подпись релиза пропущена"; return 1; }
  local as rc=0 line
  as="$(mktemp)" || return 1
  # allowed_signers: principal + keytype + blob (комментарий в хвосте срезаем —
  # формат allowed_signers лишних полей не прощает)
  for line in "$XKIT_SIGN_PUBKEY" ${XKIT_SIGN_PUBKEY_PREV:+"$XKIT_SIGN_PUBKEY_PREV"}; do
    [ -n "$line" ] && [ "$line" != "@@XKIT_SIGN_PUBKEY@@" ] && [ "$line" != "@@XKIT_SIGN_PUBKEY_PREV@@" ] \
      && printf 'xkit-release %s %s\n' "$(printf '%s' "$line" | awk '{print $1}')" "$(printf '%s' "$line" | awk '{print $2}')" >> "$as"
  done
  ssh-keygen -Y verify -f "$as" -I xkit-release -n xkit-release -s "$d/SHA256SUMS.sig" < "$d/SHA256SUMS" >/dev/null 2>&1 || rc=1
  rm -f "$as"
  [ "$rc" -eq 0 ] || return 2
  # содержимое подписанного манифеста обязано сходиться с локальными файлами
  ( cd "$d" && sha256sum -c --ignore-missing SHA256SUMS >/dev/null 2>&1 ) || return 2
  return 0
}

set -u
# TTY-детект (ревью v4.7): при не-терминале (curl|bash | tee log) цвета гаснут —
# в логах не остаётся сырых \033[ кодов
if [ -t 1 ] && [ -t 2 ] && [ -z "${XKIT_NO_COLOR:-}" ]; then
  C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_N='\033[0m'; IS_TTY=1
else
  C_G=''; C_Y=''; C_R=''; C_N=''; IS_TTY=0
fi
log(){ echo -e "${C_G}[i]${C_N} $*"; }
# warn — в stderr (симметрия с xkit.sh, ревью v4.7.0): диагностика не должна
# попадать в пайпы/захват stdout, даже если сегодня тут никто не захватывает
warn(){ echo -e "${C_Y}[!]${C_N} $*" >&2; }
err(){ echo -e "${C_R}[x] $*${C_N}" >&2; }

# (K-02/V-02) доверие локальным файлам: владелец root, без group/world-write;
# /tmp, /var/tmp, /dev/shm — никогда
install_trust() { # $1 каталог, $2 файл
  local d="$1" f="$2" st myuid
  case "$d" in /tmp|/tmp/*|/var/tmp|/var/tmp/*|/dev/shm|/dev/shm/*) return 1 ;; esac
  myuid="$(id -u 2>/dev/null || echo 0)"
  st="$(stat -Lc '%u %a' "$d" 2>/dev/null)" || return 1
  { [ "${st%% *}" = "0" ] || [ "${st%% *}" = "$myuid" ]; } || return 1
  [ $(( 8#${st#* } & 8#022 )) -eq 0 ] || return 1
  st="$(stat -Lc '%u %a' "$f" 2>/dev/null)" || return 1
  { [ "${st%% *}" = "0" ] || [ "${st%% *}" = "$myuid" ]; } || return 1
  [ $(( 8#${st#* } & 8#022 )) -eq 0 ] || return 1
  return 0
}

# --- разбор аргументов: -y/--yes и --force пробрасываются в xkit (XKIT_YES/
# XKIT_FORCE — неинтерактивный режим/CI), первый http(s)-аргумент = источник,
# остальное = субкоманда xkit
URL_ARG=""; XKIT_ARGS=()
for a in "$@"; do
  case "$a" in
    -y|--yes)  export XKIT_YES=1 ;;
    --force)   export XKIT_FORCE=1 ;;
    *) if [ -z "$URL_ARG" ] && printf '%s' "$a" | grep -q '^https\?://'; then
         URL_ARG="$a"
       else
         XKIT_ARGS+=("$a")
       fi ;;
  esac
done
[ ${#XKIT_ARGS[@]} -eq 0 ] && XKIT_ARGS=(install)

# база репозитория — запомним в xkit.env для `xkit update` (без /xkit.sh на конце)
REPO="${URL_ARG:-$XKIT_BASE}"
REPO="${REPO%/xkit.sh}"
export XKIT_REPO_URL="$REPO"

# (K-02) только https; http:// разрешён ТОЛЬКО для локальных зеркал (тесты)
case "$REPO" in
  http://127.0.0.1*|http://localhost*|http://\[::1\]*) ;;
  http://*) err "K-02: http://-источники запрещены — используйте https://"; exit 1 ;;
esac

# --- источник xkit.sh: сначала ищем рядом с самим install.sh
# basename/readlink с «--» — GNU/BusyBox по-разному едят имена с ведущим «-»
SRC=""
SELF="$0"
if [ -f "$SELF" ] && [ "$(basename -- "$SELF")" != "bash" ] && [ "$(basename -- "$SELF")" != "-bash" ]; then
  D="$(cd "$(dirname -- "$(readlink -f -- "$SELF" 2>/dev/null)" 2>/dev/null)" 2>/dev/null && pwd)" || D=""
  [ -n "$D" ] && [ -f "$D/xkit.sh" ] && SRC="$D/xkit.sh"
fi

# ранняя подсказка (v4.7): xkit уже стоит — установка спросит, что делать
# (обновить/переустановить/починить поверх); скачиваем и отдаём сцену xkit'у
if [ "${XKIT_ARGS[0]}" = "install" ] && [ -f /etc/xkit/xkit.env ] \
   && [ "${XKIT_FORCE:-0}" != "1" ]; then
  warn "Обнаружен установленный xkit (/etc/xkit/xkit.env)."
  warn "Установка предложит: обновить / переустановить чисто / починить поверх."
  warn "Обновить без переустановки:  xkit update   |   Снести:  xkit uninstall"
fi

WORK="$(mktemp -d)" || exit 1
trap 'rm -rf "$WORK"' EXIT
trap 'rm -rf "$WORK"; printf "Прервано.\n" >&2; exit 130' INT TERM

# (K-02/V-02) локальная копия — только из доверенного места и с верным pin
if [ -n "$SRC" ] && ! install_trust "$(dirname -- "$SRC")" "$SRC"; then
  warn "Локальный $SRC не доверенный (owner/mode или /tmp) — игнорирую, качаю из репо"
  SRC=""
fi
# v6.0.0: локальный пак — сначала подпись релиза; битая подпись = отказ (fail-closed)
if [ -n "$SRC" ]; then
  case "$(sig_verify_dir "$(dirname -- "$SRC")")" in
    0) log "Подпись релиза подтверждена (ssh-keygen -Y) — файлы сверены с SHA256SUMS" ;;
    2) err "Подпись релиза НЕ ПРОШЛА — пак изменён или подменён (K-02). Установка отменена"; exit 1 ;;
    *) : ;;  # подписи/ключа нет — дальше работаем по пин-книге
  esac
fi
if [ -n "$SRC" ]; then
  if [ "$XKIT_PIN_SHA256" != "@@XKIT_PIN_SHA256@@" ]; then
    _g="$(sha256sum "$SRC" | awk '{print $1}')"
    [ "$_g" = "$XKIT_PIN_SHA256" ] \
      || { err "Локальный xkit.sh не совпал с pin-хэшем install.sh (K-02) — установка отменена"; exit 1; }
    log "Найден локальный xkit.sh рядом с install.sh (pin совпал): $SRC"
  else
    # (баг №5, аудит v5.2.1): dev-режим (pin — плейсхолдер). Если рядом лежит
    # xkit.sh.sha256 — сверяемся с ним; не совпал — отказ (K-02, fail-closed)
    _sum="$(dirname -- "$SRC")/xkit.sh.sha256"
    if [ -f "$_sum" ]; then
      _want="$(awk 'NR==1{print $1}' "$_sum")"
      [[ "$_want" =~ ^[0-9a-f]{64}$ ]] || _want=""
      _got="$(sha256sum "$SRC" | awk '{print $1}')"
      if [ -n "$_want" ] && [ "$_want" = "$_got" ]; then
        log "Найден локальный xkit.sh рядом с install.sh (сумма совпала с xkit.sh.sha256): $SRC"
      else
        err "Локальный xkit.sh не совпал с xkit.sh.sha256 рядом с install.sh (K-02) — установка отменена"
        exit 1
      fi
    else
      warn "dev-режим: pin — плейсхолдер, xkit.sh.sha256 рядом нет — локальный xkit.sh принят по install_trust без сверки суммы"
      log "Найден локальный xkit.sh рядом с install.sh: $SRC"
    fi
  fi
  cp -f "$SRC" "$WORK/xkit.sh" || exit 1
else
  BASE="${URL_ARG:-$XKIT_BASE}"
  if [[ "$BASE" == *YOUR_USERNAME* ]]; then
    err "Источник не настроен: в install.sh стёрт ник репозитория (YOUR_USERNAME),"
    err "либо задайте XKIT_BASE=https://... или передайте URL первым аргументом:"
    err "  bash install.sh https://raw.githubusercontent.com/kambarro/xkit/main/xkit.sh"
    exit 1
  fi
  case "$BASE" in
    */xkit.sh) RAW="$BASE" ;;
    *)         RAW="$BASE/xkit.sh" ;;
  esac
  log "Скачиваю: $RAW"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$RAW" -o "$WORK/xkit.sh" || { err "Не удалось скачать $RAW"; exit 1; }
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$WORK/xkit.sh" "$RAW" || { err "Не удалось скачать $RAW"; exit 1; }
  else
    err "Нужен curl или wget"; exit 1
  fi

  # контрольная сумма (K-02): подпись релиза (SHA256SUMS+sig из репо) > pin из install.sh > пломба из репо; нет ничего — отказ
  if [ "$XKIT_SIGN_PUBKEY" != "@@XKIT_SIGN_PUBKEY@@" ]; then
    SIG_RC=1
    if curl -fsSL "${REPO}/SHA256SUMS" -o "$WORK/SHA256SUMS" 2>/dev/null \
       || wget -qO "$WORK/SHA256SUMS" "${REPO}/SHA256SUMS" 2>/dev/null; then
      if curl -fsSL "${REPO}/SHA256SUMS.sig" -o "$WORK/SHA256SUMS.sig" 2>/dev/null \
         || wget -qO "$WORK/SHA256SUMS.sig" "${REPO}/SHA256SUMS.sig" 2>/dev/null; then
        sig_verify_dir "$WORK"; SIG_RC=$?
      fi
    fi
    case "$SIG_RC" in
      0) log "Подпись релиза подтверждена (ssh-keygen -Y) — компоненты сверены с SHA256SUMS" ;;
      2) err "Подпись релиза в репозитории НЕ ПРОШЛА — файлы изменены или подменены. Установка отменена (K-02)"; exit 1 ;;
      *) warn "Подписанный SHA256SUMS в репозитории нет — проверяю по pin-книге/пломбе" ;;
    esac
  fi
  WANT=""
  if [ "$XKIT_PIN_SHA256" != "@@XKIT_PIN_SHA256@@" ]; then
    WANT="$XKIT_PIN_SHA256"
    log "Использую pin-хэш релиза из install.sh"
  else
    SUMURL="${RAW%/*}/xkit.sh.sha256"
    if curl -fsSL "$SUMURL" -o "$WORK/xkit.sh.sha256" 2>/dev/null \
       || wget -qO "$WORK/xkit.sh.sha256" "$SUMURL" 2>/dev/null; then
      WANT="$(awk 'NR==1{print $1}' "$WORK/xkit.sh.sha256")"
      # (з.10, аудит v5.2.1): НЕ-hex мусор в пломбе (HTML-ошибка прокси и т.п.) —
      # «нечем сверять»; hex любой длины оставляем — не совпадёт и даст честный
      # «SHA-256 НЕ совпал» вместо вводящего в заблуждение сообщения
      [[ "$WANT" =~ ^[0-9a-f]+$ ]] || WANT=""
    fi
  fi
  GOT="$(sha256sum "$WORK/xkit.sh" | awk '{print $1}')"
  if [ -n "$WANT" ]; then
    if [ "$WANT" = "$GOT" ]; then
      log "SHA-256 проверен: $GOT"
    else
      err "SHA-256 НЕ совпал — файл битый или изменён. Установка отменена."
      exit 1
    fi
  elif [ "${XKIT_ALLOW_UNVERIFIED:-0}" = "1" ]; then
    warn "XKIT_ALLOW_UNVERIFIED=1 — ставлю БЕЗ проверки суммы"
  else
    err "Проверить xkit.sh нечем: pin-хэша нет, xkit.sh.sha256 не найден/не содержит корректной суммы (K-02)."
    err "Осознанный обход: XKIT_ALLOW_UNVERIFIED=1 bash install.sh ..."
    exit 1
  fi
fi

# --- санитарная проверка перед запуском от root
bash -n "$WORK/xkit.sh" || { err "Синтаксическая ошибка в xkit.sh — установка отменена"; exit 1; }
chmod 700 "$WORK/xkit.sh"

# --- модуль меню (v5.0.0): UI-слой xkit живёт в отдельном файле xkit_menu.sh.
# Кладём его в WORK рядом с xkit.sh — one_step_install сам перенесёт его
# в /usr/local/lib/xkit. Если файл не доедет — xkit при первом запуске
# докачает меню сам (XKIT_REPO_URL + сверка SHA-256)
MENU_OK=1
SRCDIR=""
[ -n "$SRC" ] && SRCDIR="$(cd "$(dirname -- "$SRC")" 2>/dev/null && pwd)"
USE_LOCAL_MENU=0
if [ -n "$SRCDIR" ] && [ -f "$SRCDIR/xkit_menu.sh" ]; then
  # (K-02/V-02) локальное меню — доверенное место + pin; иначе качаем из репо
  if ! install_trust "$SRCDIR" "$SRCDIR/xkit_menu.sh"; then
    warn "Локальный xkit_menu.sh не доверенный (owner/mode или /tmp) — качаю из репо"
  elif [ "$XKIT_PIN_MENU_SHA256" != "@@XKIT_PIN_MENU_SHA256@@" ]; then
    _gm="$(sha256sum "$SRCDIR/xkit_menu.sh" | awk '{print $1}')"
    [ "$_gm" = "$XKIT_PIN_MENU_SHA256" ] \
      || { err "Локальный xkit_menu.sh не совпал с pin-хэшем (K-02) — установка отменена"; exit 1; }
    USE_LOCAL_MENU=1
  else
    USE_LOCAL_MENU=1
  fi
  if [ "$USE_LOCAL_MENU" = "1" ]; then
    cp -f "$SRCDIR/xkit_menu.sh" "$WORK/xkit_menu.sh" || exit 1
    log "Модуль меню найден рядом: $SRCDIR/xkit_menu.sh"
  fi
fi
if [ "$USE_LOCAL_MENU" != "1" ]; then
  MENUURL="${REPO}/xkit_menu.sh"   # REPO уже без /xkit.sh на конце
  log "Скачиваю: $MENUURL"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$MENUURL" -o "$WORK/xkit_menu.sh" || MENU_OK=0
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$WORK/xkit_menu.sh" "$MENUURL" || MENU_OK=0
  else
    err "Нужен curl или wget"; exit 1
  fi
  # сумма меню (K-02): pin из install.sh > строка 2 пломбы; нет — отказ
  WANTM=""
  if [ "$XKIT_PIN_MENU_SHA256" != "@@XKIT_PIN_MENU_SHA256@@" ]; then
    WANTM="$XKIT_PIN_MENU_SHA256"
  elif [ -s "$WORK/xkit.sh.sha256" ]; then
    WANTM="$(awk '$2=="xkit_menu.sh"{print $1; exit}' "$WORK/xkit.sh.sha256")"
  fi
  if [ "$MENU_OK" = "1" ] && [ -s "$WORK/xkit_menu.sh" ]; then
    if [ -n "$WANTM" ]; then
      GOTM="$(sha256sum "$WORK/xkit_menu.sh" | awk '{print $1}')"
      if [ "$WANTM" != "$GOTM" ]; then
        err "SHA-256 xkit_menu.sh НЕ совпал — файл битый или изменён. Установка отменена."
        exit 1
      fi
      log "SHA-256 xkit_menu.sh проверен: $GOTM"
    elif [ "${XKIT_ALLOW_UNVERIFIED:-0}" = "1" ]; then
      warn "XKIT_ALLOW_UNVERIFIED=1 — меню без проверки суммы"
    else
      err "Проверить xkit_menu.sh нечем: pin и пломбы нет (K-02). Осознанный обход: XKIT_ALLOW_UNVERIFIED=1"
      exit 1
    fi
  fi
fi
if [ -s "$WORK/xkit_menu.sh" ]; then
  bash -n "$WORK/xkit_menu.sh" || { err "Синтаксическая ошибка в xkit_menu.sh — установка отменена"; exit 1; }
  chmod 700 "$WORK/xkit_menu.sh"
else
  warn "xkit_menu.sh не скачался — xkit докачает меню при первом запуске (xkit update)"
fi

# --- v5.2: модуль протоколов и TUI. Каждый файл проверяется отдельно.
# В WORK они нужны одношаговому установщику; при V-02-запрете /tmp ядро
# повторно скачает их через xkit_component_fetch с той же пломбой.
# v9.0.0: культурная раскладка репо — инструменты в tools/, TUI-бинари в bin/,
# остальное (ядро/меню/протоколы/пломба/подпись) в корне. Пломба xkit.sh.sha256
# хранит имена С путями (tools/sitegen.py, bin/xkit-tui-linux-amd64).
xkit_repo_relpath() { # $1 имя компонента -> относительный путь в репо
  case "$1" in
    sitegen.py|camo_sitegen.py|bench.sh|ipregion.sh) printf 'tools/%s' "$1" ;;
    xkit-tui-linux-*) printf 'bin/%s' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}
fetch_release_component() { # $1 имя, $2 pin
  local name="$1" pin="$2" want="" got="" rel
  # v9.0.0: культурная раскладка репо — инструменты в tools/, TUI-бинари в bin/.
  rel="$(xkit_repo_relpath "$name")"
  if [ -n "$SRCDIR" ] && [ -f "$SRCDIR/$rel" ] && install_trust "$(dirname "$SRCDIR/$rel")" "$SRCDIR/$rel"; then
    if [[ "$pin" != @@*@@ ]]; then
      got="$(sha256sum "$SRCDIR/$rel" | awk '{print $1}')"
      [ "$got" = "$pin" ] || { err "Локальный $name не совпал с pin-хэшем — установка отменена"; exit 1; }
    fi
    mkdir -p "$(dirname "$WORK/$rel")"
    cp -f "$SRCDIR/$rel" "$WORK/$rel" || exit 1
  else
    log "Скачиваю: ${REPO}/${rel}"
    mkdir -p "$(dirname "$WORK/$rel")"
    curl -fsSL "${REPO}/${rel}" -o "$WORK/$rel" || { err "Не удалось скачать $name"; exit 1; }
    if [[ "$pin" != @@*@@ ]]; then want="$pin"; fi
    if [ -z "$want" ]; then
      [ -s "$WORK/xkit.sh.sha256" ] || curl -fsSL "${REPO}/xkit.sh.sha256" -o "$WORK/xkit.sh.sha256" || true
      want="$(awk -v n="$rel" '$2==n{print $1;exit}' "$WORK/xkit.sh.sha256" 2>/dev/null)"
    fi
    got="$(sha256sum "$WORK/$rel" | awk '{print $1}')"
    if [ -n "$want" ] && [ "$want" != "$got" ]; then err "SHA-256 $name не совпал — установка отменена"; exit 1; fi
    if [ -z "$want" ] && [ "${XKIT_ALLOW_UNVERIFIED:-0}" != 1 ]; then err "Нет SHA-256 для $name (K-02)"; exit 1; fi
  fi
  case "$name" in *.sh) bash -n "$WORK/$rel" || exit 1 ;; esac
  chmod 700 "$WORK/$rel"
}
fetch_release_component xkit_protocols.sh "$XKIT_PIN_PROTOCOLS_SHA256"
# v8.2.0: camo-движок sitegen (движок + обёртка кластера). SHA из пломбы xkit.sh.sha256.
fetch_release_component sitegen.py "${XKIT_PIN_SITEGEN_SHA256:-@@sitegen@@}"
fetch_release_component camo_sitegen.py "${XKIT_PIN_CAMO_SITEGEN_SHA256:-@@camo_sitegen@@}"
# v8.3.0: вендоренные утилиты тестирования сервера (bench.sh / ipregion.sh).
# SHA из пломбы; ipregion — копия XKIT с вырезанной отправкой debug-лога.
fetch_release_component bench.sh "${XKIT_PIN_BENCH_SHA256:-@@bench@@}"
fetch_release_component ipregion.sh "${XKIT_PIN_IPREGION_SHA256:-@@ipregion@@}"
case "$(uname -m)" in
  x86_64) fetch_release_component xkit-tui-linux-amd64 "$XKIT_PIN_TUI_AMD64_SHA256" ;;
  aarch64|arm64) fetch_release_component xkit-tui-linux-arm64 "$XKIT_PIN_TUI_ARM64_SHA256" ;;
  *) warn "TUI для архитектуры $(uname -m) не поставляется; останется классическое меню" ;;
esac

# --- команды, которым root не нужен (xkit сам проверит root там, где надо)
case "${XKIT_ARGS[0]}" in
  help|status|health) NEED_ROOT=0 ;;
  *)                  NEED_ROOT=1 ;;
esac

# --- запуск: даже при «curl | bash» отдаём установщику настоящий терминал.
# ЕДИНАЯ уборка $WORK — в EXIT-trap (строка выше), поэтому здесь НЕ exec и НЕ
# дублируем rm: с exec ловушка не сработала бы, а второй rm был бы мёртвым кодом
run_xkit() {
  if [ "$(id -u)" -eq 0 ] || [ "$NEED_ROOT" -eq 0 ]; then
    RUN=(bash "$WORK/xkit.sh")
  elif command -v sudo >/dev/null 2>&1 && { sudo -n true 2>/dev/null || [ -r /dev/tty ]; }; then
    log "Нет root — запускаю через sudo"
    # sudo НЕ пробрасывает env (ревью v4.7.0): без этого -y/--force от не-root
    # доезжали до xkit.sh пустыми и установка шла интерактивно. Явный проброс
    # через `sudo env VAR=…` — не зависит от env_keep в sudoers
    RUN=(sudo env XKIT_YES="${XKIT_YES:-0}" XKIT_FORCE="${XKIT_FORCE:-0}" \
           XKIT_NO_COLOR="${XKIT_NO_COLOR:-}" XKIT_NO_ANIM="${XKIT_NO_ANIM:-}" \
           XKIT_TUI="${XKIT_TUI:-1}" XKIT_REPO_URL="$XKIT_REPO_URL" bash "$WORK/xkit.sh")
  else
    RUN=(bash "$WORK/xkit.sh")
    warn "Нет ни root, ни sudo — xkit сам сообщит, что нужен root"
  fi
  if [ -t 0 ]; then
    "${RUN[@]}" "${XKIT_ARGS[@]}"
  elif ( exec true </dev/tty ) 2>/dev/null; then
    "${RUN[@]}" "${XKIT_ARGS[@]}" </dev/tty
  else
    "${RUN[@]}" "${XKIT_ARGS[@]}"   # stdin не терминал — пусть xkit сам скажет, чего не хватает
  fi
}
run_xkit; rc=$?
exit $rc
