#!/bin/bash
#==============================================================================
#  XKIT v7.5.13 — TUI и CLI для nginx + 3X-UI (Ubuntu 24.04+)
#
#  Установка:  curl -fsSL https://raw.githubusercontent.com/kambarro/xkit/main/install.sh | sudo bash
#  Запуск:     xkit (TUI) | xkit --classic | xkit help
#  Документация: README.md
#  История:      CHANGES.md
#
#  ВНИМАНИЕ (v6.0.0): этот файл СОБИРАЕТСЯ из src/ командой `bash build.sh` —
#  правки вносить в src/[0-9][0-9]_*.sh, а не сюда (§8.3 CHANGES.md).
#
#  Для тестов функций: source xkit.sh — main вызывается только при прямом запуске.
#==============================================================================

set -u -o pipefail
export LC_ALL=C

XKIT_VERSION="7.5.13"
# v6.0.0 (по образцу 3X-UI_KIT): рекомендованное закреплённое ядро Xray панели
# (26.6.27 — последняя проверенная в их тест-матрице «протокол × клиент»;
# более новые ломали клиентов на sing-box). Меняется: xkit core-pin <версия>
XKIT_CORE_PIN="${XKIT_XRAY_VERSION:-26.6.27}"
# необязательный пин SHA-256 установщика 3X-UI (задаётся окружением
# XKIT_XUI_SHA256=... перед установкой; актуальное значение — check-upstream.sh)
XKIT_XUI_SHA256=""
# TTY-детект (ревью v4.7.0): при не-терминале (curl|bash, cron, tee, CI) цвета
# гаснут — в логах не остаётся сырых \033[… кодов. XKIT_NO_COLOR=1 — ручной
# override; XKIT_NO_ANIM=1 отключает спиннер при живом TTY
if [ -t 1 ] && [ -t 2 ] && [ -z "${XKIT_NO_COLOR:-}" ]; then
  GREEN='\033[0;32m'; BLUE='\033[0;34m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
  IS_TTY=1
else
  GREEN=''; BLUE=''; RED=''; YELLOW=''; NC=''
  IS_TTY=0
fi

log()  { echo -e "${BLUE}[INFO] $*${NC}"; }
ok()   { echo -e "${GREEN}[OK]   $*${NC}"; }
# warn — диагностика, а не данные: ВСЕГДА в stderr. Иначе warn внутри функции,
# чей stdout захватывается ($(...) / with_spinner -o), попадает в значение —
# например PANEL_SCHEME становился "[WARN] …\nhttp" и ломал api_url (ревью v4.7.0)
warn() { echo -e "${YELLOW}[WARN] $*${NC}" >&2; }
err()  { echo -e "${RED}[ERR ] $*${NC}" >&2; }
die()  { err "$*"; exit 1; }

#=========================== UX-ХЕЛПЕРЫ УСТАНОВКИ =============================
# confirm «Вопрос [y/N]: " [y|n] — 0=да.
# v7.2.4 (живой сервер VM-212285): «видимый y» дважды отвергся — принимаем ВСЕ
# разумные «да»/«нет» независимо от регистра и раскладки, а непонятое —
# печатаем в диагностику (%q покажет настоящие байты: IME/полноразмерные
# символы/CRLF-хвосты больше не невидимы):
#   да:  y Y yes yep yeah ok 1 true | д Д да Да ДА ага давай | кириллическая у
#        (визуальный двойник y) | полноразмерные ｙ Ｙ
#   нет: n N no nope not 0 false | н Н нет Нет НЕТ не неа | полноразмерные ｎ Ｎ
# Пробелы/табы/CR (CRLF-терминалы) и пунктуация («да!», «yes,») срезаются.
# Пустой ответ = вариант по умолчанию (второй аргумент, n если не задан).
# EOF (Ctrl-D) = отмена, а не молчаливый дефолт. XKIT_YES=1 (CI) = согласие.
# Нераспознанный НЕпустой ответ = отказ + warn с печатью сырых байт через %q.
# Нормализация БАЙТОВАЯ (tr + явные пары символов) и НЕ ЗАВИСИТ ОТ ЛОКАЛИ:
# в C-локали классы [[:alnum:]]/${,,} не знают кириллицу — «хм» превращалось
# бы в пустую строку и молча принимало дефолт (поймано регрессом v7.2.4).
# (v7.2.8) ремонт ввода: терминалы/веб-консоли провайдеров иногда оставляют
# «осиротевший» ведущий байт UTF-8 — Backspace в них стирает ПОЛкириллического
# символа (один байт из двух). Живой случай (установка 7.2.7, VM оператора):
# набрали «у», стёрли, набрали «y» -> на входе $'\320y' (0xD0 + 'y'); набрали
# «н»… -> $'\321n'. Распознаватель видел мусор и ОТКАЗЫВАЛ, хотя пустой ввод
# означал бы «да» (UFW остался выключен, авто-бэкапы — вопрос решён неверно).
# Ремонт побайтовый (LC_ALL=C): корректные UTF-8-последовательности сохраняются
# («да»/«нет», гомоглиф «у»), обрывки и одинокие continuation-байты — долой.
confirm_utf8_repair() { # $1 сырой ввод -> очищенный ввод в stdout
  local s="$1" out="" i=0 n c d j ok
  while [ "$i" -lt "${#s}" ]; do
    c="$(printf '%d' "'${s:i:1}")"
    case "$c" in
      0|[1-9]|[1-9][0-9]|1[01][0-9]|12[0-7]) out+="${s:i:1}"; i=$((i+1)); continue ;; # ASCII
      19[4-9]|2[01][0-9]|22[0-3]) n=2 ;; # 0xC2..0xDF — ведущий 2-байтной последовательности
      22[4-9]|23[0-9])           n=3 ;; # 0xE0..0xEF
      24[0-4])                   n=4 ;; # 0xF0..0xF4
      *) i=$((i+1)); continue ;;        # 0x80..0xC1, 0xF5..0xFF — мусор
    esac
    ok=1
    for ((j = 1; j < n; j++)); do
      d="$(printf '%d' "'${s:i+j:1}")"   # за концом строки printf даёт 0 — не continuation
      case "$d" in 12[89]|1[3-8][0-9]|19[01]) : ;; *) ok=0; break ;; esac # 0x80..0xBF
    done
    if [ "$ok" = "1" ] && [ $((i + n)) -le "${#s}" ]; then
      out+="${s:i:n}"; i=$((i+n))
    else
      i=$((i+1)) # обрывок — пропускаем ведущий байт
    fi
  done
  printf '%s' "$out"
}

# нормализация ответа confirm(): пунктуация/гомоглифы/регистр -> «низкая» форма
confirm_normalize() { # $1 сырой -> stdout
  local ans
  # 1) пунктуация/пробелы/CR-хвосты — долой (tr байтовый, локаль не важна)
  ans="$(printf '%s' "$1" | tr -d $' \t\r\n\v\f!?.,;:"`\'()+*=#%&@$^~|\\<>[]{}_-')"
  # 2) гомоглифы/раскладки: fullwidth-двойники IME и кириллическая у (= y)
  ans="${ans//ｙ/y}"; ans="${ans//Ｙ/y}"; ans="${ans//ｎ/n}"; ans="${ans//Ｎ/n}"
  ans="${ans//у/y}"
  # 3) регистр вниз: ASCII через tr, кириллицу — явными парами (байтово)
  ans="$(printf '%s' "$ans" | tr 'A-Z' 'a-z')"
  ans="${ans//Д/д}"; ans="${ans//А/а}"; ans="${ans//У/у}"; ans="${ans//Н/н}"
  ans="${ans//Е/е}"; ans="${ans//Т/т}"; ans="${ans//Г/г}"; ans="${ans//В/в}"
  ans="${ans//Й/й}"; ans="${ans//О/о}"; ans="${ans//К/к}"
  printf '%s' "$ans"
}

confirm_class() { # $1 нормализованный -> 0 = да, 1 = нет, 2 = не распознано
  case "$1" in
    y|yes|yep|yeah|ok|1|true|д|да|ага|давай) return 0 ;;
    n|no|nope|not|0|false|н|нет|не|неа)      return 1 ;;
    *)                                       return 2 ;;
  esac
}

confirm() {
  local prompt="$1" default="${2:-n}" ans orig low rep cls try
  [ "${XKIT_YES:-0}" = "1" ] && return 0
  # (v7.2.8) до 3 попыток на TTY: нераспознанный НЕпустой ответ — повтор вопроса
  # (раньше молча считался отказом — опасно на «[Y/n]»-вопросах вроде UFW).
  # EOF и не-TTY — по одному разу, как раньше (детерминизм для автоматизации).
  for try in 1 2 3; do
    read -r -p "$prompt" ans || return 1   # EOF = отказ
    orig="$ans"
    low="$(confirm_normalize "$orig")"
    confirm_class "$low"; cls=$?
    if [ "$cls" = "2" ] && [ -n "$low" ]; then
      # ремонт обрывков UTF-8: $'\320y' -> «y», $'\321n' -> «n»
      rep="$(confirm_utf8_repair "$orig")"
      if [ "$rep" != "$orig" ]; then
        low="$(confirm_normalize "$rep")"
        confirm_class "$low"; cls=$?
        if [ "$cls" != "2" ]; then
          warn "Ввод содержал обрывок UTF-8 — принят как «${low}»"
        fi
      fi
    fi
    [ "$cls" = "0" ] && return 0
    [ "$cls" = "1" ] && return 1
    if [ -n "$low" ]; then
      if [ -t 0 ] && [ "$try" -lt 3 ]; then
        warn "Ответ не распознан (получено: $(printf '%q' "$orig")) — повторите: y/yes/ok/1/д/да = да; n/no/0/н/нет = нет; пусто = по умолчанию"
        continue
      fi
      warn "Ответ не распознан (получено: $(printf '%q' "$orig")) — считаю отказом. Допустимо: y/yes/ok/1/д/да или n/no/0/н/нет; пусто = вариант по умолчанию"
      return 1
    fi
    break # пустой ответ -> вариант по умолчанию
  done
  [ "$default" = "y" ] && return 0
  return 1
}

# v7.2.9: pause_enter определён в ЯДРЕ. История: в v5.0 его вынесли в
# xkit_menu.sh («меню — отдельный модуль»), но nodes/expiry/dash/telegram/
# backup_settings-меню остались в ядре и зовут его внутри своих case-ов.
# При входе через CLI (`xkit nodes`, `xkit expiry`, `xkit dashboard`,
# `xkit telegram`) модуль меню не загружается, и сразу после любой ошибки
# операции падало «pause_enter: command not found» — меню перерисовывалось
# мгновенно, текст ошибки уезжал из глаз (репродукция 7.2.8: добавление ноды).
# Определение в ядре делает безопасным ЛЮБОЙ путь вызова; xkit_menu.sh
# определяет то же тело — дубль безобиден (позднейшее определение выигрывает).
# `|| true`: EOF (Ctrl-D) на паузе — не роняем возврат функции.
pause_enter() { echo ""; read -r -p "Нажмите Enter для возврата в меню..." _ || true; }

# шаги установки: [n/7] + 10-клеточный индикатор (non-TTY — просто текст)
STEP=0; STEPS=7
step() {
  STEP=$((STEP+1))
  local n=$(( STEP * 10 / STEPS )) bar="" i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if [ "$i" -le "$n" ]; then bar+="#"; else bar+="-"; fi
  done
  echo ""
  echo -e "${GREEN}[${STEP}/${STEPS}]${NC} $*  [${bar}]"
}

# временные файлы установки: регистрируются и снимаются trap'ом INT/TERM/EXIT
XKIT_TMPS=()
xkit_tmp_track() { XKIT_TMPS+=("$1"); }
xkit_install_cleanup() {
  xkit_log_capture_off   # v7.2.5: вернуть stdout/stderr даже при die()/INT/EXIT
  local f
  for f in "${XKIT_TMPS[@]:-}"; do [ -n "$f" ] && rm -f "$f" 2>/dev/null; done
  case "${INSTALL_BACKUP_STAGE:-}" in /tmp/*) rm -rf -- "$INSTALL_BACKUP_STAGE" 2>/dev/null ;; esac
  INSTALL_BACKUP_STAGE=""
  return 0
}
xkit_install_traps_on() {
  trap 'xkit_install_cleanup; [ -n "${XKIT_LOG:-}" ] && printf "Прервано. Подробности: %s\n" "$XKIT_LOG" >&2; exit 130' INT TERM
  trap 'xkit_install_cleanup' EXIT
}
xkit_install_traps_off() { trap - INT TERM EXIT; }

# with_spinner "сообщение" cmd [args...] — спиннер на stderr, пока cmd работает;
# вывод cmd пишется в $XKIT_LOG, при ошибке хвост в терминал. Без TTY (или
# XKIT_NO_ANIM=1) — прозрачный прогон без анимации. Опция -o: stdout команды
# Возвращается вызывающему (для функций с результатом: detect_panel_scheme)
with_spinner() {
  local capture=0
  [ "${1:-}" = "-o" ] && { capture=1; shift; }
  local msg="$1"; shift
  if [ "${IS_TTY:-0}" != "1" ] || [ "${XKIT_NO_ANIM:-0}" = "1" ]; then
    "$@"
    return $?
  fi
  local tmplog pid rc=1 i=0
  tmplog="$(mktemp /tmp/xkit-spin.XXXXXX)" || { "$@"; return $?; }
  xkit_tmp_track "$tmplog"
  # -o (захват значения): stderr НЕ заворачиваем в tmplog — иначе диагностика
  # (warn/err) возвращается вызывающему вместе с данными и ломает значение
  # (ревью v4.7.0: PANEL_SCHEME = "[WARN] …\nhttp"). stderr идёт в терминал —
  # то же поведение, что и в non-TTY пути выше. Без -o — тишина: всё в tmplog.
  if [ "$capture" = "1" ]; then
    "$@" >"$tmplog" &
  else
    "$@" >"$tmplog" 2>&1 &
  fi
  pid=$!
  local marks='-\|/'
  # v7.2.4 (живая установка): цвета — ЛИТЕРАЛЬНЫЕ строки '\033[…' (общие с
  # echo -e в log/ok/warn). printf '%s' не интерпретирует эскейпы в АРГУМЕНТЕ
  # — в терминал печаталось сырьё «\033[0;32m[OK]\033[0m». %b интерпретирует
  # аргумент так же, как echo -e, и одинаково работает и с литералом, и с
  # пустой строкой (non-TTY).
  # v7.2.5: кадры спиннера — в /dev/tty, НЕ в stderr. При полном перехвате
  # вывода установки (xkit_log_capture_on) stderr капчурится в лог, и анимация
  # (строка каждые 0.15с) замусорила бы файл. Итоговые [OK]/[ERR] ниже остаются
  # на stderr — они в логе как раз нужны (по одной строке на шаг).
  local tty_ok=0; [ -w /dev/tty ] && tty_ok=1
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$tty_ok" = "1" ]; then
      printf '\r%b[%s]%b %s   ' "$GREEN" "${marks:$i:1}" "$NC" "$msg" >/dev/tty 2>/dev/null || true
    else
      printf '\r%b[%s]%b %s   ' "$GREEN" "${marks:$i:1}" "$NC" "$msg" >&2
    fi
    i=$(( (i+1) % 4 ))
    sleep 0.15
  done
  wait "$pid"; rc=$?
  if [ "$tty_ok" = "1" ]; then
    printf '\r\033[K' >/dev/tty 2>/dev/null || true   # стереть строку спиннера
  else
    printf '\r\033[K' >&2
  fi
  if [ "$capture" = "1" ]; then
    if [ $rc -eq 0 ]; then cat "$tmplog"; else tail -n 10 "$tmplog" >&2; fi
  else
    [ -n "${XKIT_LOG:-}" ] && cat "$tmplog" >>"$XKIT_LOG" 2>/dev/null
    if [ $rc -eq 0 ]; then
      printf '%b[OK]%b   %s\n' "$GREEN" "$NC" "$msg" >&2
    else
      printf '%b[ERR]%b  %s%s\n' "$RED" "$NC" "$msg" "${XKIT_LOG:+ (подробности: $XKIT_LOG)}" >&2
      tail -n 20 "$tmplog" | sed 's/^/       /' >&2
    fi
  fi
  rm -f "$tmplog"
  return $rc
}

# XKIT_LOG — полный лог долгоиграющей операции (установка/переустановка/
# удаление): всё, что оборачивается спиннером, попадает сюда. chmod 600 —
# установщики печатают реквизиты
xkit_log_begin() { # $1 = префикс имени (install|reinstall|uninstall)
  # Первый вызов открывает новый лог. Повторный вызов в том же процессе
  # (reinstall: uninstall -> install) переиспользует уже открытый файл и
  # НЕ очищает его — обе фазы остаются в одном логе, имя — по первой фазе
  # (ревью v4.7.0: раньше `: >` затирало лог фазы удаления).
  if [ -n "${XKIT_LOG:-}" ]; then
    [ -e "$XKIT_LOG" ] || : >"$XKIT_LOG" 2>/dev/null || true
    return 0
  fi
  XKIT_LOG="/var/log/xkit-$1-$(date +%Y%m%d-%H%M%S).log"
  mkdir -p "$(dirname "$XKIT_LOG")" 2>/dev/null || true
  : >"$XKIT_LOG" 2>/dev/null || true
  chmod 600 "$XKIT_LOG" 2>/dev/null || true
}

# v7.2.5: ПОЛНЫЙ лог установки. Раньше в $XKIT_LOG попадал только вывод
# спиннер-обёрнутых команд — файл под надписью «Полный лог установки»
# оставался почти пустым (живой баг v7.2.4 на VM-212285). Теперь вся фаза
# установки капчурится целиком (stdout+stderr -> tee -> лог), TTY-детект
# не ломается: IS_TTY вычислен до включения перехвата, кадры спиннера идут
# в /dev/tty (см. with_spinner).
xkit_log_capture_on() {
  [ -n "${XKIT_LOG:-}" ] || return 0
  [ "${XKIT_LOG_CAPTURE:-0}" = "0" ] || return 0   # уже включён (reinstall -> install)
  exec 3>&1 4>&2
  XKIT_LOG_CAPTURE=1
  exec > >(tee -a "$XKIT_LOG") 2> >(tee -a "$XKIT_LOG" >&2)
}
xkit_log_capture_off() {
  [ "${XKIT_LOG_CAPTURE:-0}" = "1" ] || return 0
  XKIT_LOG_CAPTURE=0
  exec 1>&3 2>&4 3>&- 4>&-
  return 0
}

CERTBOT_MIN_IP="5.3"                 # certbot для --ip-address
XUI_INSTALLER_URL="https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh"

# K-02 (аудит №2): установщик 3X-UI — по тегу ПОСЛЕДНЕГО РЕЛИЗА (master плавает
# и может измениться в любой момент). Переопределить: XKIT_3XUI_TAG=vX.Y.Z
# v7.2.1 (баг: недетерминированная установка): без токена GitHub API ограничен
# 60 запросами/час на IP — на NAT/прокси-адресах часты 403, и установка ТИХО
# скатывалась на master (плавающий). Цепочка источников тега:
# XKIT_3XUI_TAG -> API -> редирект github.com/.../releases/latest (веб-редирект
# без лимитов API) -> master с громким предупреждением.
xui_tag_from_api() {
  curl -fsSL --max-time 10 https://api.github.com/repos/MHSanaei/3x-ui/releases/latest 2>/dev/null \
    | jq -r '.tag_name // ""' 2>/dev/null || true
}
xui_tag_from_redirect() {
  local loc
  loc="$(curl -s --max-time 10 -o /dev/null -w '%{redirect_url}' \
    https://github.com/MHSanaei/3x-ui/releases/latest 2>/dev/null)" || return 1
  [[ "$loc" =~ /tag/(v[0-9][A-Za-z0-9._-]{0,39})$ ]] || return 1
  printf '%s' "${BASH_REMATCH[1]}"
}
xui_install_url() {
  local tag="${XKIT_3XUI_TAG:-}"
  [ -n "$tag" ] || tag="$(xui_tag_from_api)"
  [ -n "$tag" ] || tag="$(xui_tag_from_redirect || true)"
  if [[ "$tag" =~ ^[A-Za-z0-9._-]{1,40}$ ]]; then
    printf 'https://raw.githubusercontent.com/mhsanaei/3x-ui/%s/install.sh' "$tag"
  else
    warn "Тег релиза 3X-UI не определён (API и редирект недоступны) — установка с master НЕдетерминирована. Зафиксируйте: XKIT_3XUI_TAG=vX.Y.Z" >&2
    printf '%s' "$XUI_INSTALLER_URL"
  fi
}
XKIT_DIR="/etc/xkit"
XKIT_ENV="${XKIT_DIR}/xkit.env"
XKIT_ROUTES="${XKIT_DIR}/routes.tsv"
XKIT_NODES="${XKIT_DIR}/nodes.json"
XKIT_EXPIRY="${XKIT_DIR}/expiry.tsv"     # сроки аренды: scope<TAB>id<TAB>date<TAB>note
XKIT_DASH_DIR="/var/lib/xkit/dash"        # веб-дашборд (index.html + data.json)
XKIT_NODES_METRICS="${XKIT_NODES_METRICS:-/var/lib/xkit/nodes-metrics.json}" # общий кэш TUI/дашборда
XKIT_NODES_HISTORY="${XKIT_NODES_HISTORY:-/var/lib/xkit/nodes-history.json}" # sanitized ring buffer, без секретов
XKIT_NODES_HISTORY_MAX="${XKIT_NODES_HISTORY_MAX:-288}"
XKIT_NODES_PARALLEL="${XKIT_NODES_PARALLEL:-4}"
XKIT_NODE_DEADLINE="${XKIT_NODE_DEADLINE:-45}"
XKIT_DASH_HTPASSWD="/etc/nginx/.xkit-dash.htpasswd"  # Basic Auth дашборда
XKIT_INFO_FILE="/root/xkit-info.txt"      # сводка-реквизиты (терминал + файл)
XKIT_NOTIFY_STATE="${XKIT_DIR}/notify.state"  # состояние Telegram-алертов (гистерезис/дедуп)
XKIT_BIN="/usr/local/bin/xkit"
XKIT_MENU_DIR="${XKIT_MENU_DIR:-/usr/local/lib/xkit}"  # модули XKIT
XKIT_PROTOCOLS_FILE="${XKIT_PROTOCOLS_FILE:-${XKIT_MENU_DIR}/xkit_protocols.sh}"
XKIT_TUI_FILE="${XKIT_TUI_FILE:-${XKIT_MENU_DIR}/xkit-tui}"
SUBS_DIR="/var/lib/xkit/subs"
BACKUP_DIR="/var/backups/xkit"
# v7.2.0: политика бэкапов. Всё переопределяется окружением и xkit.env:
#   BACKUP_ENABLED   1|0 — авто-бэкапы по расписанию (manual `xkit backup` всегда доступен)
#   BACKUP_INTERVAL_H интервал авто-бэкапа в часах (24/48/168/свой, 1-8760)
#   BACKUP_KEEP_DAYS сколько дней хранить архивы (плюс ВСЕГДА минимум BACKUP_KEEP_MIN
#                    последних копий, даже если они старше — одна копия не точка отказа)
XKIT_LAST_BACKUP="${XKIT_DIR}/last_backup"   # штамп (epoch) последнего успешного бэкапа
BACKUP_ENABLED="${BACKUP_ENABLED:-1}"
BACKUP_INTERVAL_H="${BACKUP_INTERVAL_H:-24}"
BACKUP_KEEP_DAYS="${BACKUP_KEEP_DAYS:-14}"
BACKUP_KEEP_MIN="${BACKUP_KEEP_MIN:-3}"
# cron-файлы кита — переменные (не хардкод), чтобы uninstall и тесты работали
# с переопределёнными путями
XKIT_CRON_MAIN="/etc/cron.d/xkit"
XKIT_CRON_DASH="/etc/cron.d/xkit-dash"
XKIT_CRON_NOTIFY="/etc/cron.d/xkit-notify"
XKIT_CONF="/etc/nginx/sites-available/xkit.conf"
XKIT_CONF_LINK="/etc/nginx/sites-enabled/xkit.conf"
XUI_RESULT="/etc/x-ui/install-result.env"
XUI_DB="/etc/x-ui/x-ui.db"

#=========================== FIREWALL: ТОЛЬКО ПРАВИЛА XKIT ======================
xkit_ufw_active() {
  local st
  command -v ufw >/dev/null 2>&1 || return 1
  st="$(ufw status 2>/dev/null)" || return 1
  grep -q '^Status: active' <<<"$st"
}

xkit_fw_rule_line() { # $1 port, $2 proto, $3 owner
  [[ "$1" =~ ^[0-9]+$ ]] && is_port "$1" || return 1
  [[ "$2" =~ ^(tcp|udp)$ && "$3" =~ ^[a-z0-9-]+$ ]] || return 1
  ufw status 2>/dev/null | grep -E "^${1}/${2}[[:space:]]+ALLOW[[:space:]].*XKIT:${3}([[:space:]]|$)"
}

xkit_fw_add() { # $1 owner, $2 port, $3 tcp|udp; чужой allow не трогаем
  local owner="$1" port="$2" proto="$3"
  [[ "$owner" =~ ^[a-z0-9-]+$ && "$proto" =~ ^(tcp|udp)$ ]] || return 1
  is_port "$port" || return 1
  xkit_ufw_active || return 0
  xkit_fw_rule_line "$port" "$proto" "$owner" >/dev/null && return 0
  # Уже существующее общее разрешение считаем внешним: повторять/удалять его не надо.
  if ufw status 2>/dev/null | grep -E "^${port}/${proto}[[:space:]]+ALLOW[[:space:]]" >/dev/null; then
    return 0
  fi
  ufw allow "${port}/${proto}" comment "XKIT:${owner}" >/dev/null || return 1
  xkit_fw_rule_line "$port" "$proto" "$owner" >/dev/null
}

xkit_fw_remove() { # $1 owner, $2 port, $3 tcp|udp; без метки XKIT — не удаляем
  local owner="$1" port="$2" proto="$3"
  [[ "$owner" =~ ^[a-z0-9-]+$ && "$proto" =~ ^(tcp|udp)$ ]] || return 1
  is_port "$port" || return 1
  xkit_ufw_active || return 0
  xkit_fw_rule_line "$port" "$proto" "$owner" >/dev/null || return 0
  ufw delete allow "${port}/${proto}" comment "XKIT:${owner}" >/dev/null || return 1
  ! xkit_fw_rule_line "$port" "$proto" "$owner" >/dev/null
}

xkit_awg_route_add() { # $1 внешний интерфейс
  local dev="$1"
  [[ "$dev" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
  xkit_ufw_active || return 0
  if ufw status 2>/dev/null | grep -F 'XKIT:awg-forward' >/dev/null; then
    # (баг №4, аудит v5.2.1): сверяем пару awg0 -> $dev, а не «любое XKIT-правило»;
    # при смене внешнего интерфейса (eth0 -> eth1) старая пара снимается, иначе
    # новый интерфейс навсегда остаётся закрытым
    if ufw status 2>/dev/null | grep -F 'XKIT:awg-forward' | grep -F -- "on $dev" | grep -F 'awg0' >/dev/null; then
      return 0
    fi
    local od
    od="$(ufw status 2>/dev/null | grep -F 'XKIT:awg-forward' | sed -n 's/.*out on \([^ ]*\).*/\1/p' | head -n1)"
    [ -n "$od" ] && xkit_awg_route_remove "$od" >/dev/null 2>&1 || true
  fi
  ufw route allow in on awg0 out on "$dev" comment 'XKIT:awg-forward' >/dev/null || return 1
  ufw route allow in on "$dev" out on awg0 comment 'XKIT:awg-forward' >/dev/null || {
    ufw delete route allow in on awg0 out on "$dev" comment 'XKIT:awg-forward' >/dev/null 2>&1 || true
    return 1
  }
}

xkit_awg_route_remove() { # $1 сохранённый внешний интерфейс
  local dev="$1"
  [[ "$dev" =~ ^[A-Za-z0-9_.-]+$ ]] || return 0
  xkit_ufw_active || return 0
  if ufw status 2>/dev/null | grep -F 'XKIT:awg-forward' >/dev/null; then
    ufw delete route allow in on awg0 out on "$dev" comment 'XKIT:awg-forward' >/dev/null 2>&1 || true
    ufw delete route allow in on "$dev" out on awg0 comment 'XKIT:awg-forward' >/dev/null 2>&1 || true
  fi
}

#=========================== ВАЛИДАЦИЯ ВВОДА ==================================
is_domain() {
  [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]] || return 1
  # TLD должен содержать букву: иначе "999.999.999.999" проходит как домен
  [[ "${1##*.}" =~ [a-zA-Z] ]]
}

is_ipv4() {
  local ip="$1" IFS='.' o
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  for o in $ip; do [ "$((10#$o))" -le 255 ] || return 1; done
  return 0
}

is_ipv6() {
  [[ "$1" =~ ^[0-9a-fA-F:]{2,45}$ ]] && [[ "$1" == *:* ]] || return 1
  # точная валидация inet_pton (regex пропускает a::b::c и «1234:», аудит №10);
  # python3 — зависимость (п.15), без него — фолбэк: двойное «::» невалидно
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import socket,sys; socket.inet_pton(socket.AF_INET6, sys.argv[1])' "$1" >/dev/null 2>&1
  else
    # №7 (аудит №1)/N-04 (№2): getent резолвит литерал ТОЛЬКО если это валидный
    # адрес (charset уже ограничен [0-9a-fA-F:] — DNS-имя сюда попасть не может)
    getent ahosts "$1" >/dev/null 2>&1
  fi
}

is_ip() { is_ipv4 "$1" || is_ipv6 "$1"; }
is_cidr() { # a.b.c.d/NN (0-32) или IPv6/NN (0-128) — для allow-списков nginx
  local ip="${1%%/*}" m="${1##*/}"
  [[ "$1" == */* ]] || return 1
  [[ "$m" =~ ^[0-9]{1,3}$ ]] || return 1
  if is_ipv4 "$ip"; then [ "$m" -le 32 ] 2>/dev/null
  elif is_ipv6 "$ip"; then [ "$m" -le 128 ] 2>/dev/null
  else return 1; fi
}

is_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

is_path() { [[ "$1" =~ ^/[A-Za-z0-9._~/-]*$ ]] && [[ "$1" != *"//"* ]]; }

# Строгий location-путь для генерации nginx (K-01, аудит №2): панель/инбаунд/
# routes.tsv не должны уметь вставить директивы. Запрещены ~ (regex-маркер
# location), .. (alias-эскапада), // и * (модификатор location)
is_nginx_path() {
  [[ "$1" =~ ^/[A-Za-z0-9._/-]*$ ]] || return 1
  [[ "$1" != *"//"* && "$1" != *".."* && "$1" != *"~"* && "$1" != *"*"* ]]
}

# host:port / [v6]:port -> R_HOST/R_PORT (K-01; заодно F-3: IPv6-таргет
# раньше ломал domain_only="${target%%:*}" -> "[2001")
parse_hostport() {
  local s="$1"
  R_HOST=""; R_PORT=""
  case "$s" in
    \[*\]:*)
      R_HOST="${s%%]:*}"; R_HOST="${R_HOST#\[}"
      R_PORT="${s##*]:}"
      ;;
    *:*)
      [[ "$s" == *:*:* ]] && return 1   # голый IPv6 (несколько :) — только в скобках
      R_HOST="${s%%:*}"; R_PORT="${s##*:}"
      ;;
    *) return 1 ;;
  esac
  is_port "$R_PORT" || return 1
  case "$s" in
    \[*) is_ipv6 "$R_HOST" || return 1 ;;
    *)   is_ipv4 "$R_HOST" || is_hostname "$R_HOST" || return 1 ;;
  esac
  return 0
}

safe_conf_name() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }

is_email() { [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; }

# одно-меточное имя хоста без точки (localhost, relay-алиасы) — is_domain требует точку
is_hostname() { is_domain "$1" || [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; }

# СНАЧАЛА IP, потом домен: "1.2.3.4" проходит и доменную регулярку!
host_kind() { if is_ip "$1"; then echo "ip"; elif is_domain "$1"; then echo "domain"; else echo "bad"; fi }

# публичный IP этого сервера; если ответ не валидный IP (подмена/ошибка) — пусто
pubip() {
  local ip
  ip="$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null)"
  is_ip "$ip" || ip=""
  printf '%s' "$ip"
}

normalize_panel_path() {
  local p="$1"
  [ -n "$p" ] || p="/"
  case "$p" in /*) ;; *) p="/${p}" ;; esac
  case "$p" in */) ;; *) p="${p}/" ;; esac
  printf '%s' "$p"
}

read_host() {
  local prompt="$1" v
  while true; do
    read -r -p "$prompt" v || die "Ввод прерван"
    if is_domain "$v" || is_ip "$v"; then printf '%s' "$v"; return 0; fi
    err "Некорректно: '$v'. Нужен домен или IP — без http://, путей и портов"
  done
}

# ревью v4.9.0 (живая установка): адрес сервера раньше просили набрать вслепую —
# реальный IP на экране не показывался. Теперь определяем pubip и показываем его
# как пункт 1 (Enter = согласиться); 2 — свой домен/другой IP вручную.
# Результат — в глобальной CHOSEN_HOST (stdout занят меню, $() не использовать)
choose_host() {
  local prompt="${1:-Адрес этого сервера}" myip a
  myip="$(pubip)"
  if [ -z "$myip" ]; then
    warn "Публичный IP не определился (api.ipify.org недоступен?) — введите адрес вручную"
    CHOSEN_HOST="$(read_host "$prompt (домен/IP) -> ")"
    return 0
  fi
  echo ""
  echo -e "${YELLOW}${prompt}:${NC}"
  echo "1) IP этого сервера — $myip (определён автоматически)"
  echo "2) Свой домен или другой IP (ввести вручную)"
  while true; do
    read -r -p "Ваш выбор [1]: " a || { echo; a="1"; }
    case "${a:-1}" in
      1) CHOSEN_HOST="$myip"; return 0 ;;
      2) CHOSEN_HOST="$(read_host "Домен или IP -> ")"; return 0 ;;
      *) err "Пункт 1 или 2" ;;
    esac
  done
}

read_port() {
  local prompt="$1" v
  while true; do
    read -r -p "$prompt" v || die "Ввод прерван"
    if is_port "$v"; then printf '%s' "$v"; return 0; fi
    err "Порт должен быть числом 1-65535"
  done
}

read_path() {
  local prompt="$1" v
  while true; do
    read -r -p "$prompt" v || die "Ввод прерван"
    if is_path "$v"; then printf '%s' "$v"; return 0; fi
    err "Путь: начинается с /, буквы/цифры/._~/- (без пробелов)"
  done
}

#=========================== СЛУЧАЙНОСТИ ======================================
rand_str() { # [длина] -> [a-zA-Z0-9]; запас входа x3 + доводка циклом: длина всегда точная,
             # head в пайпе нет -> SIGPIPE не роняет цепочку (аудит №9), энтропия base64 сохранена
  local n="${1:-32}" s
  s="$(openssl rand -base64 $(( n * 3 )) 2>/dev/null | tr -dc 'a-zA-Z0-9')"
  while [ "${#s}" -lt "$n" ]; do
    s+="$(openssl rand -base64 $(( n * 3 )) 2>/dev/null | tr -dc 'a-zA-Z0-9')"
  done
  printf '%s' "${s:0:$n}"
}
rand_hex() { openssl rand -hex "$1" 2>/dev/null; }

new_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then cat /proc/sys/kernel/random/uuid
  else
    # fallback в корректном формате UUID 8-4-4-4-12
    printf '%s-%s-%s-%s-%s' "$(rand_hex 4)" "$(rand_hex 2)" "$(rand_hex 2)" "$(rand_hex 2)" "$(rand_hex 6)"
  fi
}

port_busy() { ss -ltnH 2>/dev/null | awk -v p=":$1 " 'index($4, p)' | grep -q .; }

rand_free_port() {
  local lo="${1:-20000}" hi="${2:-60000}" p i
  for i in $(seq 1 100); do
    p=$(shuf -i "${lo}-${hi}" -n 1 2>/dev/null) || return 1
    if ! port_busy "$p"; then printf '%s' "$p"; return 0; fi
  done
  return 1
}

enc_uri() { jq -rn --arg s "$1" '$s|@uri'; }
# как enc_uri, но '/' не кодируется — пути в ссылках остаются читаемыми (/xk-ws-2083/)
enc_uri_path() { jq -rn --arg s "$1" '$s|@uri' | sed 's/%2F/\//gi'; }

#=========================== ХЕЛПЕРЫ NGINX ====================================
nginx_ver() { nginx -v 2>&1 | sed -n 's/.*nginx\/\([0-9.]*\).*/\1/p'; }

ver_ge() { [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]; }

# синтаксис http2 под версию nginx (Ubuntu 24.04 = 1.24 -> старый синтаксис)
# $1 = "v6" -> строка listen для IPv6. ВАЖНО: двоеточие в [::]:443 обязательно
# (без него nginx -t падает — invalid parameter; ревью v4.6.0). «http2 on;»
# (новый синтаксис) выводится ТОЛЬКО в v4-строке: дубль дал бы duplicate
# directive; при старом синтаксисе http2 встроен в сам listen
build_h2_block() {
  local ver addr=""
  [ "${1:-}" = "v6" ] && addr="[::]:"
  ver=$(nginx_ver)
  if [ -n "$ver" ] && ver_ge "$ver" "1.25.1"; then
    if [ -n "$addr" ]; then
      printf '    listen [::]:443 ssl;'
    else
      printf '    listen 443 ssl;\n    http2 on;'
    fi
  else
    printf '    listen %s443 ssl http2;' "$addr"
  fi
}

# слушать ли IPv6 (А3: v6-only клиенты за CGNAT не достучатся без [::]:443):
# глобальный v6-адрес на сервере; XKIT_V6_LISTEN=0|1|auto — принудительно
v6_listen_enabled() {
  case "${XKIT_V6_LISTEN:-auto}" in
    0|false|no)  return 1 ;;
    1|true|yes)  return 0 ;;
  esac
  ip -6 addr show scope global 2>/dev/null | grep -q "inet6"
}

backup_file() {
  local f="$1" b
  [ -f "$f" ] || return 0
  b="${f}.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "$f" "$b" && ok "Бэкап: $b"
  return 0
}

# срезать хвостовые пустые строки (nginx -t их не любит при конкатенации)
trim_blank_tail() {
  sed -i -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}' "$1"
}

# nginx -t + reload; при ошибке — РЕАЛЬНЫЙ откат к последнему бэкапу
apply_config() {
  local f="$1" out b
  trim_blank_tail "$f"
  if out=$(nginx -t 2>&1); then
    if systemctl reload nginx >/dev/null 2>&1; then ok "Nginx перезагружен"; return 0; fi
    if systemctl start nginx >/dev/null 2>&1; then ok "Nginx запущен"; return 0; fi
    err "nginx -t прошёл, но перезапустить nginx не удалось"; return 1
  fi
  err "nginx -t не прошёл:"
  echo "$out" | sed 's/^/    /' >&2
  b=$(ls -1t "${f}".bak.* 2>/dev/null | head -n1)
  if [ -n "$b" ]; then
    warn "Откатываю конфиг к последнему бэкапу: $b"
    cp -a "$b" "$f"
    if nginx -t >/dev/null 2>&1; then
      systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1
      ok "Откат выполнен — nginx работает на старом конфиге"
    else
      warn "Откат тоже битый — правьте вручную: $f"
    fi
  else
    warn "Бэкапа нет — конфиг оставлен как есть: $f"
  fi
  return 1
}

#=========================== СЕРТИФИКАТЫ ======================================
# v7.2.4: command -v обязателен. Без него certbot_version() при ОТСУТСТВУЮЩЕМ
# certbot возвращал мусор из текста «command not found», и ver_ge мог дать
# true — новый поток установки ([1/7] без пакетного certbot) на этом бы
# сломался: upgrade пропущен, серт выпустить нечем.
certbot_version() { certbot --version 2>&1 | awk '{print $2}'; }
certbot_supports_ip() { command -v certbot >/dev/null 2>&1 && ver_ge "$(certbot_version)" "$CERTBOT_MIN_IP"; }

# перед продлением nginx останавливается (standalone занимает порт 80), после — стартует
install_renew_hooks() {
  mkdir -p /etc/letsencrypt/renewal-hooks/pre /etc/letsencrypt/renewal-hooks/post
  cat > /etc/letsencrypt/renewal-hooks/pre/xkit-nginx.sh <<'EOF'
#!/bin/bash
systemctl stop nginx.service 2>/dev/null || true
EOF
  cat > /etc/letsencrypt/renewal-hooks/post/xkit-nginx.sh <<'EOF'
#!/bin/bash
systemctl start nginx.service 2>/dev/null || true
EOF
  chmod +x /etc/letsencrypt/renewal-hooks/pre/xkit-nginx.sh \
           /etc/letsencrypt/renewal-hooks/post/xkit-nginx.sh
  ok "Hooks автопродления установлены (stop/start nginx вокруг certbot renew)"
}

# pip-venv: в репо Ubuntu 24.04 certbot 2.9 без --ip-address, нужен >= 5.3.
# v7.2.4 (дискуссия с оператором «нельзя ли сразу актуальный»): venv —
# ОСНОВНОЙ путь установки, пакетный certbot «сначала, чтобы потом обновить»
# больше не ставится. Версию можно закрепить: XKIT_CERTBOT_VERSION=5.9.0
# (по образцу XKIT_3XUI_TAG). Пути параметризованы для тестов.
certbot_upgrade() {
  local venv="${XKIT_CERTBOT_VENV:-/opt/certbot-venv}"
  local bin="${XKIT_CERTBOT_BIN:-/usr/local/bin/certbot}"
  log "Ставлю certbot в $venv через pip..."
  apt-get install -y -qq python3-venv python3-pip >/dev/null 2>&1 || true
  python3 -m venv "$venv" 2>/dev/null || return 1
  "$venv/bin/pip" install -q --upgrade pip >/dev/null 2>&1 || true
  local spec=""
  if [ -n "${XKIT_CERTBOT_VERSION:-}" ]; then
    if [[ "$XKIT_CERTBOT_VERSION" =~ ^[0-9][0-9A-Za-z._-]{0,29}$ ]]; then
      spec="==$XKIT_CERTBOT_VERSION"
      log "Версия certbot закреплена: $XKIT_CERTBOT_VERSION"
    else
      warn "XKIT_CERTBOT_VERSION='$XKIT_CERTBOT_VERSION' не похожа на версию — ставлю последнюю"
    fi
  fi
  "$venv/bin/pip" install -q "certbot${spec}" >/dev/null 2>&1 || return 1
  [ -x "$venv/bin/certbot" ] || return 1
  ln -sf "$venv/bin/certbot" "$bin"
  certbot_renewal_unit
  hash -r
  return 0
}

# v7.2.4: единая точка настройки автопродления, два режима — ровно ОДИН
# путь продления в любой момент:
#  - пакетный certbot присутствует (был ранее или дотащен инсталлятором
#    3X-UI): его certbot.service перепрошивается drop-in'ом на venv-бинарник,
#    свой таймер xkit-certbot.* снимается (двойной renew недопустим);
#  - пакетного нет (venv-only, новая дефолтная схема): свой таймер с графиком
#    пакетного certbot.timer (дважды в сутки, RandomizedDelay, Persistent).
#    Без него 6-дневные IP-серты вообще нечем продлевать.
certbot_renewal_unit() {
  local venv="${XKIT_CERTBOT_VENV:-/opt/certbot-venv}"
  local sd="${XKIT_SYSTEMD_DIR:-/etc/systemd/system}"
  [ -d "$sd" ] || return 0
  if [ -e "$sd/certbot.service" ] || [ -e /lib/systemd/system/certbot.service ] \
     || [ -e /usr/lib/systemd/system/certbot.service ] \
     || { command -v systemctl >/dev/null 2>&1 && systemctl cat certbot.service >/dev/null 2>&1; }; then
    mkdir -p "$sd/certbot.service.d"
    cat > "$sd/certbot.service.d/override.conf" <<EOF
[Service]
ExecStart=
ExecStart=$venv/bin/certbot -q renew
EOF
    systemctl disable --now xkit-certbot.timer >/dev/null 2>&1 || true
    rm -f "$sd/xkit-certbot.timer" "$sd/xkit-certbot.service" 2>/dev/null
    systemctl daemon-reload >/dev/null 2>&1 || true
    return 0
  fi
  cat > "$sd/xkit-certbot.service" <<EOF
[Unit]
Description=XKIT certbot renew ($venv)
[Service]
Type=oneshot
ExecStart=$venv/bin/certbot -q renew
EOF
  cat > "$sd/xkit-certbot.timer" <<'EOF'
[Unit]
Description=XKIT certbot renew (twice daily)
[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=43200
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now xkit-certbot.timer >/dev/null 2>&1 || true
  return 0
}

le_email_args() {
  local email="$1"
  if [ -n "$email" ]; then
    printf '%s\n' "--email" "$email" "--no-eff-email"
  else
    printf '%s\n' "--register-unsafely-without-email"
  fi
}

issue_cert_le_domain() {
  local d="$1" email="$2" rc=0 extra=()
  mapfile -t extra < <(le_email_args "$email")
  log "Останавливаю nginx для standalone-выпуска (порт 80)..."
  systemctl stop nginx 2>/dev/null || true
  certbot certonly --standalone -d "$d" --non-interactive --agree-tos "${extra[@]}" || rc=$?
  systemctl start nginx 2>/dev/null || true
  if [ $rc -ne 0 ]; then
    err "Certbot не смог выпустить сертификат (nginx снова запущен). Проверьте A-запись и порт 80."
    return 1
  fi
  install_renew_hooks
  ok "Сертификат: /etc/letsencrypt/live/$d/"
  return 0
}

issue_cert_le_ip() {
  local ip="$1" email="$2" rc=0 extra=()
  if ! certbot_supports_ip; then
    # ревью v4.9.0: вопрос убран (застопорил живую установку) — авто-попытка;
    # провал возвращает 1, но choose_certificate теперь показывает меню снова,
    # а не выкидывает из установки
    warn "certbot $(certbot_version) не умеет IP-сертификаты (нужно >= ${CERTBOT_MIN_IP}) — обновляю..."
    if certbot_upgrade; then
      ok "certbot обновлён: $(certbot_version)"
    else
      err "Обновить certbot не удалось (PyPI недоступен?) — выберите самоподписанный серт (пункт 4)"
      return 1
    fi
  fi
  mapfile -t extra < <(le_email_args "$email")
  log "Останавливаю nginx для standalone-выпуска (порт 80)..."
  systemctl stop nginx 2>/dev/null || true
  certbot certonly --standalone --ip-address "$ip" --preferred-profile shortlived \
    --non-interactive --agree-tos "${extra[@]}" || rc=$?
  systemctl start nginx 2>/dev/null || true
  if [ $rc -ne 0 ]; then
    err "Certbot не смог выпустить IP-сертификат (nginx снова запущен). Порт 80 доступен извне?"
    return 1
  fi
  install_renew_hooks
  ok "Сертификат: /etc/letsencrypt/live/$ip/"
  warn "IP-серт shortlived живёт 6 ДНЕЙ — продление настроено (systemd-таймер + hooks)"
  return 0
}

issue_cert_selfsigned() {
  # FIX (v7.1.2, живая установка на Ubuntu 24.04): зависимость $h в ТОМ ЖЕ
  # операторе local — bash 5.2 разворачивает все присваивания ДО создания
  # локальных переменных, при set -u это «h: unbound variable» даже с валидными
  # аргументами. Пломба для dependent-присваиваний — отдельный оператор.
  local h="$1" kind="$2" san
  # FIX (v7.1.3, чистовая комната): валидация ДО mkdir — мусорный ввод больше
  # не оставляет пустых каталогов в /etc/nginx/ssl, а $h со слешем/пробелами
  # не уводит запись за пределы ssl-каталога (dest строится из $h).
  [ -n "$h" ] || { err "issue_cert_selfsigned: адрес не задан"; return 1; }
  case "$kind" in
    ip)     printf '%s' "$h" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[0-9a-fA-F:]{2,45}$' \
              || { err "Некорректный IP-адрес: $h"; return 1; } ;;
    domain) printf '%s' "$h" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$' \
              || { err "Некорректное доменное имя: $h"; return 1; } ;;
    *)      err "issue_cert_selfsigned: kind должен быть ip|domain (получено: $kind)"; return 1 ;;
  esac
  local dest="/etc/nginx/ssl/$h"
  if [ "$kind" = "ip" ]; then san="IP:$h"; else san="DNS:$h"; fi
  mkdir -p "$dest"
  openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$dest/privkey.pem" -out "$dest/fullchain.pem" \
    -days 3650 -subj "/CN=$h" -addext "subjectAltName=$san" 2>/dev/null \
    || { err "openssl не смог создать сертификат"; return 1; }
  chmod 700 "$dest"; chmod 600 "$dest/privkey.pem"; chmod 644 "$dest/fullchain.pem"
  warn "Самоподписанный серт (10 лет): на клиентах allowInsecure=true"
  ok "Сертификат: $dest/fullchain.pem | Ключ: $dest/privkey.pem"
  return 0
}

install_cert_files() {
  # FIX (v7.1.2): same-line зависимость от $h — см. issue_cert_selfsigned
  local h="$1"
  local src="/root/cert/$h" dest="/etc/nginx/ssl/$h"
  [ -f "$src/fullchain.pem" ] && [ -f "$src/privkey.pem" ] \
    || { err "Не найдены $src/fullchain.pem и/или $src/privkey.pem"; return 1; }
  # серт и ключ должны быть парными (одинаковый публичный ключ). (з.7/з.11,
  # аудит v5.2.1): пустой вывод openssl (битые файлы) парностью не считается —
  # иначе «пусто == пусто» проходило как пара
  local _pk1 _pk2
  _pk1="$(openssl x509 -noout -pubkey -in "$src/fullchain.pem" 2>/dev/null)" \
    || { err "fullchain.pem не читается как сертификат (openssl)"; return 1; }
  _pk2="$(openssl pkey -pubout -in "$src/privkey.pem" 2>/dev/null)" \
    || { err "privkey.pem не читается как приватный ключ (openssl)"; return 1; }
  [ -n "$_pk1" ] && [ -n "$_pk2" ] \
    && [ "$(sha256sum <<<"$_pk1" | awk '{print $1}')" = "$(sha256sum <<<"$_pk2" | awk '{print $1}')" ] \
    || { err "fullchain.pem и privkey.pem не парные (разные или битые ключи)"; return 1; }
  mkdir -p "$dest"
  cp "$src/fullchain.pem" "$dest/fullchain.pem"
  cp "$src/privkey.pem"  "$dest/privkey.pem"
  chmod 700 "$dest"; chmod 600 "$dest/privkey.pem"; chmod 644 "$dest/fullchain.pem"
  ok "Скопировано в $dest (ключ 600, каталог 700)"
  return 0
}

#=========================== ПОВТОРНОЕ ИСПОЛЬЗОВАНИЕ СЕРТОВ (v7.2.0) ==========
# Серт — файл: он валиден, пока не истёк срок, ключ парный и SAN покрывает
# адрес. После restore бэкапа / переустановки ОС при НЕСМЕНИВШЕМСЯ адресе
# перевыпуск НЕ нужен: экономит недельные лимиты Let's Encrypt на дубликаты
# и не ломает клиентов с pinned-отпечатком (перевыпуск = новая пара ключей).
cert_pair_ok() { # $1 каталог с fullchain.pem+privkey.pem — 0 = пара живая
  # (зависимые присваивания — отдельным оператором local: bash 5.2 при set -u
  # разворачивает $d ДО создания локальных переменных — см. issue_cert_selfsigned)
  local d="$1"
  local crt="$d/fullchain.pem" key="$d/privkey.pem"
  local p1 p2 end epoch
  [ -r "$crt" ] && [ -r "$key" ] || return 1
  # парность (тот же публичный ключ; «пусто == пусто» парой не считается)
  p1="$(openssl x509 -noout -pubkey -in "$crt" 2>/dev/null)" || return 1
  p2="$(openssl pkey -pubout -in "$key" 2>/dev/null)" || return 1
  [ -n "$p1" ] && [ -n "$p2" ] || return 1
  [ "$(sha256sum <<<"$p1" | awk '{print $1}')" = "$(sha256sum <<<"$p2" | awk '{print $1}')" ] || return 1
  # срок: notAfter строго в будущем («на исходе» предупредит xkit health)
  end="$(openssl x509 -noout -enddate -in "$crt" 2>/dev/null | cut -d= -f2)" || return 1
  [ -n "$end" ] || return 1
  epoch="$(date -d "$end" +%s 2>/dev/null)" || return 1
  [ "${epoch:-0}" -gt "$(date +%s)" ] || return 1
  return 0
}

cert_san_covers() { # $1 серт, $2 адрес, $3 kind (ip|domain)
  local crt="$1" h="$2" kind="$3" san
  if [ "$kind" = "ip" ]; then
    # точное совпадение IP в SAN (grep -F ловил бы 1.2.3.4 внутри 1.2.3.40);
    # exit из тела НЕ должен перебиваться END-блоком — поэтому флаг found
    san="$(openssl x509 -noout -ext subjectAltName -in "$crt" 2>/dev/null | tr ',' '\n' | sed 's/^[[:space:]]*//')" || return 1
    [ -n "$san" ] || return 1
    printf '%s\n' "$san" | awk -F'IP Address:' -v h="$h" \
      '{ for (i=2;i<=NF;i++){ v=$i; sub(/[[:space:]]+$/,"",v); if (v==h) { found=1; exit } } }
       END { exit (found ? 0 : 1) }'
  else
    local out
  out="$(openssl x509 -noout -checkhost "$h" -in "$crt" 2>/dev/null)" || return 1
  [[ "$out" == *"does match certificate"* && "$out" != *"does NOT match"* ]]
  fi
}

cert_find_reusable() { # $1 адрес, $2 kind -> stdout: каталог с сертом; rc 1 = нет
  # корни переопределяемы для тестов (XKIT_SSL_ROOT / XKIT_LE_ROOT)
  local h="$1" kind="$2" d
  for d in "${XKIT_SSL_ROOT:-/etc/nginx/ssl}/$h" "${XKIT_LE_ROOT:-/etc/letsencrypt}/live/$h"; do
    [ -d "$d" ] || continue
    cert_pair_ok "$d" || continue
    cert_san_covers "$d/fullchain.pem" "$h" "$kind" || continue
    printf '%s' "$d"
    return 0
  done
  return 1
}

# выбор сертификата (используется установкой, сокрытием панели и пунктом «перевыпустить»)
# результаты: CERT_MODE, FINAL_CRT, FINAL_KEY, LE_EMAIL
# ревью v4.9.0: провал выпуска серта больше НЕ убивает установку — меню показывается
# снова (лимит 5 попыток, чтобы EOF в цикле не крутился вечно; EOF/Ctrl-D = пункт 4 —
# самоподписанный работает всегда). Раньше return 1 из issue_cert_le_ip обрывал
# one_step_install и выкидывал админа в консоль. Email спрашивается только для LE (1/3)
# v7.2.0: пункт 0 — «использовать найденный действующий серт» (из бэкапа/прошлой
# установки), предлагается автоматически и является дефолтом при EOF
choose_certificate() {
  local host="$1" kind="$2" try=0 found=""
  FINAL_CRT=""; FINAL_KEY=""; LE_EMAIL=""
  while :; do
    try=$((try+1))
    if [ "$try" -gt 5 ]; then
      err "Сертификат не получен за 5 попыток — установка прервана на этом шаге"
      return 1
    fi
    found=""
    found="$(cert_find_reusable "$host" "$kind" || true)"
    echo ""
    echo -e "${YELLOW}Откуда берём SSL-сертификат?${NC}"
    if [ -n "$found" ]; then
      ok "Найден действующий серт для ${host}: ${found} (бэкап/прошлая установка)"
      echo "0) Использовать найденный серт — БЕЗ перевыпуска (адрес тот же; лимиты LE и клиенты не трогаются)"
    fi
    echo "1) Let's Encrypt — для ДОМЕНА (90 дней, авто-продление)"
    echo "2) Свои файлы в /root/cert/$host/ (fullchain.pem + privkey.pem)"
    if certbot_supports_ip; then
      echo "3) Let's Encrypt — для IP (shortlived, 6 дней, авто-продление)"
    else
      echo "3) Let's Encrypt — для IP (сначала авто-обновление certbot; если не выйдет — пункт 4)"
    fi
    echo "4) Самоподписанный — домен или IP (10 лет, allowInsecure=true)"
    if ! read -r -p "Ваш выбор (${found:+0-}4): " CERT_MODE; then
      echo
      if [ -n "$found" ]; then
        warn "Ввод прерван (EOF) — использую найденный действующий серт (без перевыпуска)"
        CERT_MODE="0"
      else
        warn "Ввод прерван (EOF) — беру самоподписанный (пункт 4)"
        CERT_MODE="4"
      fi
    fi
    case "$CERT_MODE" in
      0) [ -n "$found" ] || { warn "Пункт 0 доступен, только когда найден действующий серт"; continue; } ;;
      1|2|3|4) ;;
      *) warn "Нет такого пункта — выберите ${found:+0-}4"; continue ;;
    esac
    LE_EMAIL=""
    case "$CERT_MODE" in
      1|3)
        read -r -p "Email для Let's Encrypt (Enter — пропустить): " LE_EMAIL || { echo; LE_EMAIL=""; }
        if [ -n "$LE_EMAIL" ] && ! is_email "$LE_EMAIL"; then
          warn "Email выглядит некорректно — продолжаю без него"; LE_EMAIL=""
        fi ;;
    esac
    case "$CERT_MODE" in
      0) FINAL_CRT="$found/fullchain.pem"
         FINAL_KEY="$found/privkey.pem"
         ok "Использую существующий серт: $FINAL_CRT (перевыпуск не выполнялся)"
         return 0 ;;
      1) if [ "$kind" != "domain" ]; then
           err "LE-сертификаты на IP не выдаются — выберите пункт 3 или 4"; continue
         fi
         issue_cert_le_domain "$host" "$LE_EMAIL" || { err "Не вышло — исправьте проблему или выберите другой вариант"; continue; }
         FINAL_CRT="/etc/letsencrypt/live/$host/fullchain.pem"
         FINAL_KEY="/etc/letsencrypt/live/$host/privkey.pem" ;;
      2) install_cert_files "$host" || { err "Не вышло — положите fullchain.pem + privkey.pem в /root/cert/$host/ и попробуйте снова"; continue; }
         FINAL_CRT="/etc/nginx/ssl/$host/fullchain.pem"
         FINAL_KEY="/etc/nginx/ssl/$host/privkey.pem" ;;
      3) if [ "$kind" != "ip" ]; then
           err "Пункт 3 — для IP. Для домена выберите пункт 1"; continue
         fi
         issue_cert_le_ip "$host" "$LE_EMAIL" || { err "Не вышло — выберите другой вариант"; continue; }
         FINAL_CRT="/etc/letsencrypt/live/$host/fullchain.pem"
         FINAL_KEY="/etc/letsencrypt/live/$host/privkey.pem" ;;
      4) issue_cert_selfsigned "$host" "$kind" || { err "Не вышло — попробуйте снова"; continue; }
         FINAL_CRT="/etc/nginx/ssl/$host/fullchain.pem"
         FINAL_KEY="/etc/nginx/ssl/$host/privkey.pem" ;;
    esac
    return 0
  done
}

#=========================== ГЕНЕРАЦИЯ LOCATION ===============================
# Возвращает блок с НАСТОЯЩИМИ переводами строк (фикс v1 с буквальными \n)
generate_location_block() {
  local trans_type="$1" path_name="$2" target="$3" is_local="$4"
  local block="" domain_only=""
  # K-01 (аудит №2): в конфиг попадают ТОЛЬКО провалидированные значения.
  # Мусорный путь/таргет из панели/routes.tsv = отказ маршрута (пустой вывод
  # + сообщение в stderr), а не «нормализация»
  if ! is_nginx_path "$path_name"; then
    err "K-01: подозрительный путь «${path_name:0:60}» — маршрут НЕ добавлен в конфиг nginx"
    return 1
  fi
  if ! parse_hostport "$target"; then
    err "K-01: подозрительный таргет «${target:0:60}» — маршрут НЕ добавлен в конфиг nginx"
    return 1
  fi

  if [ "$trans_type" == "1" ]; then
    # === gRPC ===
    block=$(cat <<BLK

    # --- gRPC (${path_name}) ---
    location ${path_name} {
        if (\$content_type !~ "application/grpc") { return 404; }
        client_max_body_size 0;
        access_log off;
        grpc_socket_keepalive on;
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
BLK
)
    if [ "$is_local" == "true" ]; then
      block+="        grpc_pass grpc://${target};
"
    else
      domain_only="$R_HOST"
      block+="        grpc_pass grpcs://${target};
        grpc_ssl_server_name on;
        grpc_ssl_name ${domain_only};
"
    fi
    block+="    }"

  elif [ "$trans_type" == "2" ]; then
    # === WebSocket ===
    block=$(cat <<BLK

    # --- WebSocket (${path_name}) ---
    location ${path_name} {
        if (\$http_upgrade != "websocket") { return 404; }
        access_log off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
BLK
)
    if [ "$is_local" == "true" ]; then
      block+="        proxy_pass http://${target};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Host \$host;
"
    else
      domain_only="$R_HOST"
      block+="        proxy_pass https://${target};
        proxy_ssl_server_name on;
        proxy_ssl_name ${domain_only};
        proxy_set_header Host ${domain_only};
"
    fi
    block+="    }"

  elif [ "$trans_type" == "3" ]; then
    # === XHTTP / SplitHTTP ===
    block=$(cat <<BLK

    # --- XHTTP / SplitHTTP (${path_name}) ---
    location ${path_name} {
        client_max_body_size 0;
        access_log off;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        keepalive_timeout 1h;
BLK
)
    if [ "$is_local" == "true" ]; then
      block+="        proxy_pass http://${target};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Host \$host;
"
    else
      domain_only="$R_HOST"
      block+="        proxy_pass https://${target};
        proxy_ssl_server_name on;
        proxy_ssl_name ${domain_only};
        proxy_set_header Host ${domain_only};
"
    fi
    block+="    }"

  elif [ "$trans_type" == "4" ]; then
    # === TCP (HTTP-обфускация) — обычный HTTP, БЕЗ websocket-проверки ===
    block=$(cat <<BLK

    # --- TCP/HTTP-obfs (${path_name}) ---
    location ${path_name} {
        access_log off;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
        client_max_body_size 0;
BLK
)
    if [ "$is_local" == "true" ]; then
      block+="        proxy_pass http://${target};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Host \$host;
"
    else
      domain_only="$R_HOST"
      block+="        proxy_pass https://${target};
        proxy_ssl_server_name on;
        proxy_ssl_name ${domain_only};
        proxy_set_header Host ${domain_only};
"
    fi
    block+="    }"
  fi

  printf '%s' "$block"
}

# Проксирование веб-приложения (панель) по конфигу из wiki 3X-UI
generate_web_proxy_block() {
  local label="$1" path_name="$2" target="$3" scheme="$4"
  local proto="http"
  [ "$scheme" = "https" ] && proto="https"
  # K-01 (аудит №2): те же гарантии для панели/подписок
  if ! is_nginx_path "$path_name" || ! parse_hostport "$target"; then
    err "K-01: подозрительные путь/таргет (${label}) — блок НЕ добавлен в конфиг nginx"
    return 1
  fi
  cat <<BLK

    # --- ${label} (${path_name} -> ${target}) ---
    location ${path_name} {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Range \$http_range;
        proxy_set_header If-Range \$http_if_range;
        proxy_redirect off;
        access_log off;
        proxy_pass ${proto}://${target};
    }
BLK
}

# Раздача файлов подписок: /s-<token>/<subId> -> /var/lib/xkit/subs/<subId>
# v6.0.0: рядом с base64 (<subId>) отдаётся Clash-YAML (<subId>.yaml) с
# корректным content-type; без расширения — text/plain (base64).
generate_subs_block() {
  cat <<BLK

    # --- подписки xkit (${SUBS_DIR}) ---
    # v7: per-subscription headers генерируются из clientStats; без секретов.
    $([ -r "${XKIT_DIR}/sub-headers.nginx" ] && cat "${XKIT_DIR}/sub-headers.nginx")
    location ^~ ${XKIT_SUB_PATH} {
        alias ${SUBS_DIR}/;
        default_type text/plain;
        types {
            application/yaml yaml;
            application/json json;
            image/svg+xml svg;
            image/png png;
        }
        add_header profile-title "XKIT" always;
        add_header profile-update-interval "6" always;
        add_header Referrer-Policy "no-referrer" always;
        add_header Cache-Control "no-store" always;
        add_header X-Robots-Tag "noindex, nofollow" always;
        access_log off;
    }
BLK
}

#=========================== ПРОВЕРКА ОС ======================================
require_root() { [ "$EUID" -eq 0 ] || die "Запустите от root: sudo bash xkit.sh ..."; }

check_os() {
  local id="" ver=""
  if [ -f /etc/os-release ]; then
    id="$(. /etc/os-release 2>/dev/null; echo "${ID:-}")"
    ver="$(. /etc/os-release 2>/dev/null; echo "${VERSION_ID:-}")"
  fi
  case "$id" in
    ubuntu)
      local major="${ver%%.*}"
      [ -n "$major" ] || major=0
      if [ "$major" -ge 24 ] 2>/dev/null; then
        ok "ОС: Ubuntu $ver — полностью поддерживается"
      else
        warn "ОС: Ubuntu $ver — рекомендован 24.04+, продолжаю"
      fi ;;
    debian) warn "ОС: Debian $ver — скрипт заточен под Ubuntu 24+, скорее всего тоже сработает" ;;
    *)      warn "ОС неопознана (${id} ${ver}) — скрипт рассчитан на Ubuntu 24+" ;;
  esac
  return 0
}

#=========================== 3X-UI: ХЕЛПЕРЫ ===================================
install_3xui_auto() {
  XUI_JUST_INSTALLED=0
  if command -v x-ui >/dev/null 2>&1; then
    # v7.2.5: CLI есть, а systemd-юнита нет — установка сломана (живой случай
    # v7.2.4: uninstall --full не сносил /usr/bin/x-ui; reinstall видел
    # обёртку, считал панель установленной и оставал сервер без x-ui.service
    # и без install-result.env). «Уже установлена» = целая панель.
    if systemctl cat x-ui >/dev/null 2>&1; then
      warn "3X-UI уже установлен — использую текущие настройки"
      return 0
    fi
    warn "Найден CLI x-ui без systemd-юнита — переустанавливаю панель с нуля"
  fi
  log "Скачиваю официальный установщик 3X-UI (K-02: тег релиза, не master)..."
  local u; u="$(xui_install_url)"
  local dl; dl="$(mktemp /tmp/xkit-3xui.XXXXXX)" || die "mktemp не удался"
  curl -fsSL -o "$dl" "$u" \
    || { rm -f "$dl"; die "Не удалось скачать установщик 3X-UI (проверьте сеть)"; }
  bash -n "$dl" || { rm -f "$dl"; die "Скачанный установщик 3X-UI не проходит bash -n — отмена (K-02)"; }
  # v6.0.0 (по образцу 3X-UI_KIT): необязательный пин SHA-256 установщика 3X-UI.
  # Тег релиза — «последний на момент установки», а хеш нельзя передвинуть задним числом.
  # Пин задаётся окружением: XKIT_XUI_SHA256=... bash install.sh; актуальное значение
  # подскажет check-upstream.sh. Несовпадение с пином — отмена без вопросов.
  # v7.2.2 (UX, тупик интерактивного выбора версии): пин не задан + версия выбрана
  # вручную — показываем фактический SHA-256 скачанного install.sh и требуем
  # явного подтверждения (TTY); в неинтерактивном режиме (curl|bash, CI) без пина
  # по-прежнему отказ: молчаливого запуска неподписанной версии нет.
  local _want_pin _got_pin
  _want_pin="${XKIT_XUI_SHA256:-}"
  _got_pin="$(sha256sum "$dl" | awk '{print $1}')"
  if [ -n "$_want_pin" ] && [ "$_want_pin" != "@@XKIT_XUI_SHA256@@" ]; then
    if [ "$_got_pin" = "$_want_pin" ]; then
      ok "Установщик 3X-UI совпал с закреплённым SHA-256"
    else
      warn "SHA-256 установщика 3X-UI изменился: закреплён ${_want_pin:0:12}…, скачан ${_got_pin:0:12}…"
      err "Без совпавшей SHA-256 root-установщик не запускается. Обновите пин только после проверки (check-upstream.sh)."
      rm -f "$dl"; return 1
    fi
  elif [ -n "${XKIT_3XUI_TAG:-}" ]; then
    if [ "${IS_TTY:-0}" = "1" ]; then
      warn "Пин XKIT_XUI_SHA256 не задан — версия ${XKIT_3XUI_TAG} выбрана вручную."
      log "Фактический SHA-256 install.sh: ${_got_pin}"
      confirm "Установщик не закреплён пином. Запустить? [y/N] " n \
        || { rm -f "$dl"; err "Отменено. Для закрепления: XKIT_XUI_SHA256=${_got_pin} XKIT_3XUI_TAG=${XKIT_3XUI_TAG}"; return 1; }
      ok "SHA-256 принят вручную: ${_got_pin}"
    else
      err "Для конкретной версии 3X-UI обязателен XKIT_XUI_SHA256 (SHA-256 install.sh); неинтерактивно без пина установка запрещена"
      rm -f "$dl"; return 1
    fi
  fi
  # (з.6, аудит v5.2.1): установка бежит от root — явное подтверждение, симметрия с node_add
  confirm "Запустить официальный установщик 3X-UI от root? [Y/n] " y \
    || { rm -f "$dl"; warn "Установка 3X-UI отменена"; return 1; }
  log "Устанавливаю 3X-UI в неинтерактивном режиме (случайные креды)..."
  local -a install_args=()
  [ -n "${XKIT_3XUI_TAG:-}" ] && install_args+=("$XKIT_3XUI_TAG")
  if ! XUI_NONINTERACTIVE=1 bash "$dl" "${install_args[@]}" </dev/null; then
    rm -f "$dl"
    err "Установщик 3X-UI завершился с ошибкой"
    return 1
  fi
  rm -f "$dl"
  systemctl enable --now x-ui >/dev/null 2>&1 || true
  XUI_JUST_INSTALLED=1
  ok "3X-UI установлен"
  return 0
}

# v7.2.5: путь к РЕАЛЬНОМУ бинарнику x-ui, а не к обёртке. /usr/bin/x-ui —
# меню-скрипт 3x-ui, и он НЕ форвардит подкоманду setting в бинарник:
# «x-ui setting -username … -password …» попадает в *) show_usage и молча
# выходит с кодом 0 (живой баг v7.2.4 на VM-212285: пароль не менялся,
# а xkit считал успехом). Бинарник ищем по стандартному пути установки и в
# PATH, отсекая скрипты (shebang #!) — ELF-бинарник на них не начинается.
xui_real_bin() {
  local c
  for c in /usr/local/x-ui/x-ui "$(command -v x-ui 2>/dev/null || true)"; do
    [ -n "$c" ] && [ -x "$c" ] && [ -f "$c" ] || continue
    if ! head -c 2 "$c" 2>/dev/null | grep -q '#!'; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 1
}

# После неинтерактивной установки заменяем короткий пароль установщика на 32
# алфавитно-цифровых символа. install-result.env обновляется атомарно: иначе
# следующий read_panel_settings вернёт старый пароль и API-логин сломается.
# v7.2.5: (1) меняем пароль только РЕАЛЬНЫМ бинарником (обёртка молча
# игнорирует setting, см. xui_real_bin); (2) ОБЯЗАТЕЛЬНАЯ верификация —
# логин в API с новым паролем; не прошёл — откат к старому и честная ошибка.
panel_password_strengthen() {
  [ -n "${PANEL_USER:-}" ] && [ -n "${PANEL_PASS:-}" ] || return 0
  local xui new old tmp
  old="$PANEL_PASS"
  new="$(rand_str 32)"
  [ "${#new}" -eq 32 ] || { err "Не удалось сгенерировать пароль панели"; return 1; }
  xui="$(xui_real_bin || true)"
  [ -n "$xui" ] || { err "Не найден бинарник x-ui для усиления пароля (нужен /usr/local/x-ui/x-ui)"; return 1; }
  if ! "$xui" setting -username "$PANEL_USER" -password "$new" >/dev/null 2>&1; then
    err "3X-UI не принял новый пароль — прежние реквизиты сохранены"
    return 1
  fi
  # верификация: панель читает пользователя из БД на каждый логин, рестарт
  # для проверки не нужен (рестарт будет ниже, после обновления result.env)
  local saved="$PANEL_PASS"
  [ -n "${PANEL_SCHEME:-}" ] || PANEL_SCHEME="$(detect_panel_scheme "$PANEL_PORT" 2>/dev/null || echo http)"
  PANEL_PASS="$new"
  if kit_login >/dev/null 2>&1; then
    ok "Пароль панели усилен и ПРОВЕРЕН логином: 32 случайных символа"
  else
    PANEL_PASS="$saved"
    "$xui" setting -username "$PANEL_USER" -password "$old" >/dev/null 2>&1 || true
    err "Новый пароль не применился (проверка логином не прошла) — откат к прежним реквизитам"
    err "Задать вручную: ${xui} setting -username <user> -password <пароль>"
    return 1
  fi
  tmp="$(mktemp "${XUI_RESULT}.new.XXXXXX" 2>/dev/null)" || tmp=""
  if [ -n "$tmp" ] && awk -v p="$new" '
      BEGIN { done=0 }
      /^XUI_PASSWORD=/ { print "XUI_PASSWORD=\"" p "\""; done=1; next }
      { print }
      END { if (!done) print "XUI_PASSWORD=\"" p "\"" }
    ' "$XUI_RESULT" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$XUI_RESULT"; then
    PANEL_PASS="$new"
    systemctl restart x-ui >/dev/null 2>&1 || { err "Пароль сохранён, но x-ui не перезапустился"; return 1; }
    return 0
  fi
  [ -z "$tmp" ] || rm -f "$tmp"
  "$xui" setting -username "$PANEL_USER" -password "$old" >/dev/null 2>&1 || true
  err "Не удалось обновить $XUI_RESULT — новый пароль откачен"
  return 1
}

# PANEL_PORT / PANEL_WBP / PANEL_USER / PANEL_PASS из install-result.env
# (основной источник) или из `x-ui setting -show true` (запасной)
# значение из install-result.env БЕЗ source (аудит №8: файл пишет инсталлятор
# 3X-UI, но source произвольного файла — лишний вектор). Парсим построчно:
# снимаем surrounding-кавычки и CR, внутренности не трогаем
xui_env_val() { # $1 KEY, $2 файл -> значение
  # awk с точным сравнением $1==k: sed "s/^$1=//" трактовал метасимволы (& . * /)
  # в ключе как regex — с текущими статическими ключами безопасно, но awk
  # безопасен всегда (ревью v4.6.0); берём первое вхождение (exit)
  local v
  v="$(awk -F= -v k="$1" '$1==k { sub(/^[^=]*=/, ""); print; exit }' "$2" 2>/dev/null)"
  v="${v%$'\r'}"
  v="${v%\"}"; v="${v#\"}"
  v="${v%\'}"; v="${v#\'}"
  printf '%s' "$v"
}

# v7.2.3: каскад определения порта/webBasePath УЖЕ установленной панели.
# Живой случай v7.2.2: x-ui стоит, install-result.env отсутствует, а
# `x-ui setting -show true` молчит (обёртка без бинарника, другой форк,
# нечитаемая БД) — установка падала на ровном месте. Теперь источников пять:
#   0) XKIT_PANEL_PORT / XKIT_WEB_BASE_PATH — явный override (высший приоритет)
#   1) install-result.env (пишет инсталлятор 3X-UI; парсим без source, №8)
#   2) `x-ui setting -show true` — v3.x печатает «port: N». Анкор от начала
#      строки, чтобы subPort/subJsonPort не подсовывали свой порт; «port: 0»
#      при нечитаемой БД игнорируем (0 — не порт); timeout — CLI не вешает
#      установку
#   3) sqlite3 прямо по БД панели (XUI_DB, $XUI_DB_FOLDER, /usr/local/x-ui/bin)
#      — ключи webPort|port и webBasePath (родня webListen из force_panel_localhost)
#   4) слушающий порт процесса x-ui из ss — ТОЛЬКО подсказка оператору:
#      у панели могут быть соседи (sub-порт), автоматически не применяем
#   5) вопрос оператору при TTY. Не-TTY — честная ошибка с инструкцией,
#      а не тихий неправильный порт
xui_db_candidates() {
  local d
  for d in "${XUI_DB:-/etc/x-ui/x-ui.db}" \
           "${XUI_DB_FOLDER:+${XUI_DB_FOLDER%/}/x-ui.db}" \
           "/usr/local/x-ui/bin/x-ui.db"; do
    [ -n "$d" ] && [ -f "$d" ] && printf '%s\n' "$d"
  done
  return 0
}

xui_db_setting() { # $1 — ключ в settings; печать первого непустого значения
  command -v sqlite3 >/dev/null 2>&1 || return 0
  local db v
  while IFS= read -r db; do
    v="$(sqlite3 "$db" "SELECT value FROM settings WHERE key='$1' ORDER BY rowid LIMIT 1;" 2>/dev/null || true)"
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  done < <(xui_db_candidates)
  return 0
}

xui_port_from_proc() { # слушающий порт процесса x-ui — подсказка, не истина
  command -v ss >/dev/null 2>&1 || return 0
  ss -ltnpH 2>/dev/null | awk '
    /users:\(\("x-ui"/ {
      n = split($4, a, ":")
      if (a[n] ~ /^[0-9]+$/ && a[n]+0 > 0) print a[n]
    }' | sort -un | head -n 1
  return 0
}

read_panel_settings() {
  PANEL_PORT=""; PANEL_WBP=""; PANEL_USER=""; PANEL_PASS=""
  local s _hint
  # 0) явный override — вне конкуренции с автодетектом
  PANEL_PORT="${XKIT_PANEL_PORT:-}"
  PANEL_WBP="${XKIT_WEB_BASE_PATH:-}"
  # 1) install-result.env
  if [ -f "$XUI_RESULT" ]; then
    [ -z "$PANEL_PORT" ] && PANEL_PORT="$(xui_env_val XUI_PANEL_PORT "$XUI_RESULT")"
    [ -z "$PANEL_WBP" ]  && PANEL_WBP="$(xui_env_val XUI_WEB_BASE_PATH "$XUI_RESULT")"
    PANEL_USER="$(xui_env_val XUI_USERNAME "$XUI_RESULT")"
    PANEL_PASS="$(xui_env_val XUI_PASSWORD "$XUI_RESULT")"
    # v7.2.5: API-токен 3X-UI v3.11+ (Authorization: Bearer на /panel/api/*).
    # Уже заданный не перекрываем (operator override / xkit.env).
    if [ -z "${XKIT_XUI_API_TOKEN:-}" ]; then
      XKIT_XUI_API_TOKEN="$(xui_env_val XUI_API_TOKEN "$XUI_RESULT")"
    fi
  fi
  # 2) живая панель: setting -show true (v7.2.5: РЕАЛЬНЫМ бинарником — обёртка
  # /usr/bin/x-ui не форвардит setting и молчит, см. xui_real_bin)
  if [ -z "$PANEL_PORT" ] || [ -z "$PANEL_WBP" ]; then
    local _xui_bin; _xui_bin="$(xui_real_bin || true)"
    if [ -n "$_xui_bin" ]; then
      s=$(timeout 10 "$_xui_bin" setting -show true 2>/dev/null || true)
      if [ -z "$PANEL_PORT" ]; then
        PANEL_PORT=$(echo "$s" | awk '/^[[:space:]]*port[[:space:]]*:/ { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }' | tr -d '[:space:]')
        [ "$PANEL_PORT" = "0" ] && PANEL_PORT=""
      fi
      [ -z "$PANEL_WBP" ] && PANEL_WBP=$(echo "$s" | awk '/^[[:space:]]*webBasePath[[:space:]]*:/ { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }' | tr -d '[:space:]')
    fi
  fi
  # 3) БД панели напрямую (CLI мог промолчать: сломана обёртка / другой форк)
  if [ -z "$PANEL_PORT" ]; then
    PANEL_PORT="$(xui_db_setting webPort)"
    [ -z "$PANEL_PORT" ] && PANEL_PORT="$(xui_db_setting port)"
  fi
  [ -z "$PANEL_WBP" ] && PANEL_WBP="$(xui_db_setting webBasePath)"
  # ранняя валидация: мусорный порт (result.env/БД/override) падает сразу с
  # K-01, а не доехал до вопросов человеку с невнятной ошибкой про путь
  if [ -n "$PANEL_PORT" ]; then
    is_port "$PANEL_PORT" || { err "K-01: порт панели некорректен: ${PANEL_PORT:0:20}"; return 1; }
  fi
  # 4-5) человек: подсказка из ss + вопрос
  if [ -z "$PANEL_PORT" ] || [ -z "$PANEL_WBP" ]; then
    _hint="$(xui_port_from_proc)"
    if [ "${IS_TTY:-0}" = "1" ]; then
      if [ -z "$PANEL_PORT" ]; then
        while :; do
          read -r -p "Порт панели 3X-UI не определён автоматически${_hint:+ (похоже, слушает ${_hint})}. Введите порт: " PANEL_PORT || return 1
          is_port "$PANEL_PORT" && break
          err "Некорректный порт: '${PANEL_PORT:0:20}' (1-65535)"
          PANEL_PORT=""
        done
        ok "Порт панели принят вручную: ${PANEL_PORT}"
      fi
      if [ -z "$PANEL_WBP" ]; then
        read -r -p "webBasePath панели (обычно /; если задан свой — введите как в панели): " PANEL_WBP || return 1
        [ -n "$PANEL_WBP" ] || PANEL_WBP="/"
      fi
    else
      [ -z "$PANEL_PORT" ] && { err "Не удалось определить порт панели 3X-UI: install-result.env, x-ui setting -show true и БД пусты или недоступны. Задайте XKIT_PANEL_PORT=<порт> и повторите"; return 1; }
      err "Не удалось определить webBasePath панели 3X-UI. Задайте XKIT_WEB_BASE_PATH=/путь/ и повторите"; return 1
    fi
  fi
  is_port "$PANEL_PORT" || { err "K-01: порт панели некорректен: ${PANEL_PORT:0:20}"; return 1; }
  PANEL_WBP=$(normalize_panel_path "$PANEL_WBP")
  is_nginx_path "$PANEL_WBP" || { err "K-01: webBasePath панели некорректен: ${PANEL_WBP:0:40}"; return 1; }
  return 0
}

# Панель слушает http или https на 127.0.0.1 (если инсталлятор выдал ей серт)
detect_panel_scheme() {
  local p="$1" code i
  for i in 1 2 3; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${p}${PANEL_WBP}" 2>/dev/null)
    case "$code" in 200|301|302|400|401|403|404) echo "http"; return 0 ;; esac
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 "https://127.0.0.1:${p}${PANEL_WBP}" 2>/dev/null)
    case "$code" in 200|301|302|400|401|403|404) echo "https"; return 0 ;; esac
    sleep 2
  done
  warn "Панель не отвечает на 127.0.0.1:${p} — предполагаю http"
  echo "http"
}

# Панель должна слушать ТОЛЬКО 127.0.0.1 (webListen в БД панели).
# Если не выйдет (postgres / другая схема) — остаётся UFW deny.
force_panel_localhost() {
  local port="$1"
  command -v sqlite3 >/dev/null 2>&1 || return 1
  [ -f "$XUI_DB" ] || return 1
  sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings (key,value) VALUES ('webListen','127.0.0.1');" 2>/dev/null || return 1
  systemctl restart x-ui >/dev/null 2>&1 || return 1
  sleep 2
  # проверяем: слушает ли панель 0.0.0.0? (found=1 -> exit 0 -> exposed)
  if ss -ltnH 2>/dev/null | awk -v p=":${port} " '
      index($4, p) { if ($4 !~ /^127\.0\.0\.1/ && $4 !~ /^\[::1\]/) found=1 }
      END { exit (found ? 0 : 1) }'; then
    return 1
  fi
  return 0
}

#=========================== СОСТОЯНИЕ XKIT ===================================
save_xkit_env() {
  mkdir -p "$(dirname "$XKIT_ENV")" 2>/dev/null || true
  chmod 700 "$(dirname "$XKIT_ENV")" 2>/dev/null || true
  # запись в subshell (симметрично notify_state_set/dash_gen_locked, ревью
  # v4.6.0): umask 077 не утекает в вызывающую оболочку при любом сбое;
  # провал записи теперь честный — err + return 1, а не молчаливый ok
  (
    umask 077
    tmp="$(mktemp "${XKIT_ENV}.new.XXXXXX")" || exit 1
    {
      printf 'XKIT_VERSION=%q\n' "$XKIT_VERSION"
      printf 'XKIT_HOST=%q\n' "${XKIT_HOST:-}"
      printf 'XKIT_CRT=%q\n' "${XKIT_CRT:-}"
      printf 'XKIT_KEY=%q\n' "${XKIT_KEY:-}"
      printf 'XKIT_CERT_MODE=%q\n' "${XKIT_CERT_MODE:-}"
      printf 'XKIT_SUB_TOKEN=%q\n' "${XKIT_SUB_TOKEN:-}"
      printf 'XKIT_UFW=%q\n' "${XKIT_UFW:-0}"
      printf 'XKIT_PANEL_SUB_PORT=%q\n' "${XKIT_PANEL_SUB_PORT:-}"
      printf 'XKIT_PANEL_SUB_PATH=%q\n' "${XKIT_PANEL_SUB_PATH:-}"
      printf 'XKIT_REALITY_INTERNAL=%q\n' "${XKIT_REALITY_INTERNAL:-0}"
      printf 'XKIT_BAL_STRATEGY=%q\n' "${XKIT_BAL_STRATEGY:-leastLoad}"
      printf 'XKIT_POOL_INBOUND=%q\n' "${XKIT_POOL_INBOUND:-}"
      printf 'XKIT_POOL_TAG=%q\n' "${XKIT_POOL_TAG:-}"
      printf 'XKIT_REPO_URL=%q\n' "${XKIT_REPO_URL:-}"
      printf 'XKIT_DASH=%q\n' "${XKIT_DASH:-0}"
      printf 'XKIT_DASH_TOKEN=%q\n' "${XKIT_DASH_TOKEN:-}"
      printf 'XKIT_DASH_ALLOW=%q\n' "${XKIT_DASH_ALLOW:-}"
      printf 'XKIT_DASH_AUTH=%q\n' "${XKIT_DASH_AUTH:-1}"
      printf 'XKIT_DASH_USER=%q\n' "${XKIT_DASH_USER:-}"
      printf 'XKIT_DASH_PASS=%q\n' "${XKIT_DASH_PASS:-}"
      printf 'XKIT_TG_TOKEN=%q\n' "${XKIT_TG_TOKEN:-}"
      printf 'XKIT_TG_CHAT=%q\n' "${XKIT_TG_CHAT:-}"
      printf 'XKIT_TG_PROXY=%q\n' "${XKIT_TG_PROXY:-}"
      printf 'XKIT_TG_ADMINS=%q\n' "${XKIT_TG_ADMINS:-}"
      printf 'BACKUP_ENABLED=%q\n' "${BACKUP_ENABLED:-1}"
      printf 'BACKUP_INTERVAL_H=%q\n' "${BACKUP_INTERVAL_H:-24}"
      printf 'BACKUP_KEEP_DAYS=%q\n' "${BACKUP_KEEP_DAYS:-14}"
      printf 'BACKUP_KEEP_MIN=%q\n' "${BACKUP_KEEP_MIN:-3}"
      printf 'XKIT_XUI_API_TOKEN=%q\n' "${XKIT_XUI_API_TOKEN:-}"
    } > "$tmp"
    mv "$tmp" "$XKIT_ENV"
  ) || { err "Не удалось сохранить $XKIT_ENV"; return 1; }
  chmod 600 "$XKIT_ENV" 2>/dev/null
  ok "Состояние сохранено: $XKIT_ENV"
}

load_xkit_env() {
  # v7.4.4: XKIT_VERSION из xkit.env НЕ должен переопределять версию скрипта —
  # старый env (сохранился от прошлой установки) показывал в сводке «XKIT v7.4.0»
  # под бинарём 7.4.x (живой лог 7.4.2: сводка после «починки поверх»).
  local _script_ver="${XKIT_VERSION:-}"
  XKIT_HOST=""; XKIT_CRT=""; XKIT_KEY=""; XKIT_CERT_MODE=""; XKIT_SUB_TOKEN=""; XKIT_UFW="0"
  XKIT_PANEL_SUB_PORT=""; XKIT_PANEL_SUB_PATH=""; XKIT_REALITY_INTERNAL="0"
  XKIT_BAL_STRATEGY="leastLoad"; XKIT_POOL_INBOUND=""; XKIT_POOL_TAG=""
  XKIT_DASH="0"; XKIT_DASH_TOKEN=""; XKIT_DASH_ALLOW=""
  XKIT_DASH_AUTH="1"; XKIT_DASH_USER=""; XKIT_DASH_PASS=""
  XKIT_TG_TOKEN=""; XKIT_TG_CHAT=""; XKIT_TG_PROXY=""; XKIT_TG_ADMINS=""
  XKIT_XUI_API_TOKEN=""   # v7.2.5: API-токен панели (Bearer); read_panel_settings дополнит из install-result.env
  # v7.2.0: политика бэкапов — дефолты ДО чтения xkit.env (env переопределит)
  : "${BACKUP_ENABLED:=1}"; : "${BACKUP_INTERVAL_H:=24}"
  : "${BACKUP_KEEP_DAYS:=14}"; : "${BACKUP_KEEP_MIN:=3}"
  local _repo="${XKIT_REPO_URL:-}"   # внешнее значение (от install.sh) не теряем
  XKIT_REPO_URL="$_repo"             # №22: фолбэк ДО чтения env — ранний return не теряет
  [ -r "$XKIT_ENV" ] || return 1
  # shellcheck disable=SC1090
  . "$XKIT_ENV"
  [ -n "${XKIT_REPO_URL:-}" ] || XKIT_REPO_URL="$_repo"
  [ -n "$_script_ver" ] && XKIT_VERSION="$_script_ver"
  return 0
}

# XKIT_SUB_PATH зависит от токена
sub_path() {
  printf '/s-%s/' "${XKIT_SUB_TOKEN:-CHANGE_ME}"
}

#=========================== МАРШРУТЫ (routes.tsv) ============================
# Формат: id<TAB>mode<TAB>net<TAB>path<TAB>target<TAB>tag
#   id:    id инбаунда панели (число) или m<rand> для ручных маршрутов
#   mode:  local (127.0.0.1) | relay (внешний сервер) | panel
#   net:   grpc | ws | xhttp | tcp | web
#   path:  внешний путь с слэшами /xk-ws-2083/
#   target:127.0.0.1:PORT | host:443
routes_load() {
  ROUTES=()
  [ -r "$XKIT_ROUTES" ] || return 0
  mapfile -t ROUTES < "$XKIT_ROUTES"
}

routes_upsert() { # $1..$6 поля строки
  local id="$1" line
  mkdir -p "$(dirname "$XKIT_ROUTES")" 2>/dev/null || true
  line="$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4" "$5" "$6")"
  if [ -f "$XKIT_ROUTES" ]; then
    awk -F'\t' -v id="$id" '$1 != id' "$XKIT_ROUTES" > "${XKIT_ROUTES}.tmp"
    mv "${XKIT_ROUTES}.tmp" "$XKIT_ROUTES"
  fi
  printf '%s\n' "$line" >> "$XKIT_ROUTES"
  chmod 600 "$XKIT_ROUTES"
}

routes_del() {
  local id="$1"
  [ -f "$XKIT_ROUTES" ] || return 0
  awk -F'\t' -v id="$id" '$1 != id' "$XKIT_ROUTES" > "${XKIT_ROUTES}.tmp"
  mv "${XKIT_ROUTES}.tmp" "$XKIT_ROUTES"
}

# путь для маршрута инбаунда: детерминированный, по типу транспорта и порту
auto_path_for() { # $1 net (ws|grpc|xhttp|hu|tc)  $2 port
  printf '/xk-%s-%s/' "$1" "$2"
}

#=========================== API ПАНЕЛИ (REST) ================================
# Слой для клиентов/автопроброса/подписок. Все ответы панель отдаёт как
# {"success":true/false,"msg":"...","obj":...}. Всё defensively через jq:
# если формат API когда-нибудь поменяется — увидите понятную ошибку.
#
# ПОКОЛЕНИЯ API (v4.9.1): 3X-UI v3.x (2026) закрыл ВСЕ POST-запросы
# CSRF-мiddleware'ом (без X-CSRF-Token — ответ 403 С ПУСТЫМ телом) и перенёс
# клиентские эндпоинты в /panel/api/clients/*, настройки — в /panel/api/setting/*,
# xray-шаблон — в /panel/api/xray/*. API_V3 определяется в kit_session по
# GET /panel/api/openapi.json (есть только в v3). На v2 всё по-старому.

api_url() { printf '%s://127.0.0.1:%s%s' "${PANEL_SCHEME:-http}" "${PANEL_PORT}" "${PANEL_WBP}"; }

API_V3=0      # 1 = панель 3X-UI v3+ (CSRF + /panel/api/clients|setting|xray/*)
CSRF_TOKEN="" # токен сессии для POST (v3+); пусто = панель v2 — заголовок не ставим

# v7.2.5: API-токен 3X-UI (v3.11+, «Settings -> API Tokens»): Authorization:
# Bearer на ВСЕХ /panel/api/*, CSRF-middleware панели bearer-запросы пропускает
# (api_authed), scope admin = полный доступ. Токен предпочтительнее логина:
# не зависит от пароля панели и двухфактора. Источник — install-result.env
# (XUI_API_TOKEN, пишет инсталлятор) / xkit.env (XKIT_XUI_API_TOKEN).
# Пусто = классический путь: логин + cookie (kit_login).
XKIT_XUI_API_TOKEN=""

# собирает auth-аргументы curl в API_AUTH_ARGS (bearer, если токен задан).
# Вызывать ПЕРЕД использованием массива; при set -u пустой массив безопасен.
api_auth_args() {
  API_AUTH_ARGS=()
  [ -n "${XKIT_XUI_API_TOKEN:-}" ] && API_AUTH_ARGS+=(-H "Authorization: Bearer ${XKIT_XUI_API_TOKEN}")
  return 0
}

# v7.4.1: человекочитаемое сообщение об ошибке API. 3X-UI v3.11 отклоняет POST
# на уровне middleware ПУСТЫМ телом (403 CSRF-middleware для сессии, 401 для
# неверного bearer), а jq считает пустую строку в .msg «истиной» — раньше
# ошибка печаталась как «add inbound: » без единой подсказки. Теперь видно,
# что именно случилось (см. живой лог 7.4.0: «[ERR ] add inbound: »).
api_err_msg() { # $1 тело ответа панели (может быть пустым или не-JSON)
  local r="${1:-}" msg issues
  if [ -z "$r" ]; then
    printf 'пустой ответ панели — POST отклонён middleware (401: неверный API-токен, 403: CSRF-сессия); запрос повторён с обновлённой аутентификацией'
  elif jq -e 'type=="object"' <<<"$r" >/dev/null 2>&1; then
    msg="$(jq -r 'if .success == true then "ok" elif (.msg // "") == "" then "отклонено панелью без пояснения (msg пуст)" else .msg end' <<<"$r" 2>/dev/null | head -c 300)"
    # v7.4.3: валидатор панели (middleware.BindAndValidate) возвращает obj.issues[]
    # с конкретным полем и правилом — без них «request body failed validation»
    # нечувствителен к диагностике. Показываем до 4 первых нарушений.
    issues="$(jq -r '(.obj.issues // [])[:4][] | "\(.field): \(.rule)\(if (.param // "") == "" then "" else "(\(.param))" end)"' <<<"$r" 2>/dev/null \
      | paste -sd'; ' - | head -c 300)"
    [ -n "$issues" ] && printf '%s [%s]' "$msg" "$issues" || printf '%s' "$msg"
  else
    printf 'не-JSON ответ панели: %s' "$(printf '%s' "$r" | tr '\n' ' ' | tr -s ' ' | head -c 150)"
  fi
}

# v7.4.1: восстановление аутентификации панели после пустого/не-JSON ответа на
# POST. Сначала обновляем CSRF-токен текущей сессии (истёк/сброшен панелью);
# если сессии нет или она мертва — полный kit_login (креды из install-result.env).
# Истина = можно повторить запрос. Bearer-путь не трогаем: при невалидном токене
# kit_login создаёт cookie-сессию, и POST уходит уже через неё.
_api_auth_recover() {
  if [ -n "${COOKIE_JAR:-}" ] && [ -f "${COOKIE_JAR:-}" ]; then
    csrf_fetch
    # v7.4.1: только warn (stderr): функция вызывается внутри $(...) — log/ok
    # (stdout) засорили бы ответ панели
    [ -n "${CSRF_TOKEN:-}" ] && { warn "CSRF-токен обновлён — повторяю запрос..."; return 0; }
  fi
  [ -n "${PANEL_USER:-}" ] && [ -n "${PANEL_PASS:-}" ] || return 1
  kit_login >/dev/null 2>&1 || return 1
  [ -n "${CSRF_TOKEN:-}" ] && { warn "Сессия панели восстановлена — повторяю запрос..."; return 0; }
  return 1
}

# проверка токена живой панелью: /panel/api/openapi.json с валидным Bearer =
# HTTP 200 (невалидный токен -> 401, без авторизации -> 404). Токены появились
# в 3x-ui v3.11 — 200 заодно подтверждает поколение API v3.
api_token_ok() {
  [ -n "${XKIT_XUI_API_TOKEN:-}" ] || return 1
  local code
  local -a a=(-s --max-time 8 -o /dev/null -w '%{http_code}')
  [ "${PANEL_SCHEME:-http}" = "https" ] && a+=(-k)
  api_auth_args
  code="$(curl "${a[@]}" "${API_AUTH_ARGS[@]}" "$(api_url)panel/api/openapi.json" 2>/dev/null)" || return 1
  [ "$code" = "200" ]
}

curl_panel() { # curl к панели с учётом схемы (свой/самоподписанный серт = -k)
  local -a a=(-s)
  [ "${PANEL_SCHEME:-http}" = "https" ] && a+=(-k)
  curl "${a[@]}" "$@"
}

csrf_fetch() { # GET <base>/csrf-token -> CSRF_TOKEN (v3+; v2: роута нет, пусто)
  local out
  # -b -c: отправляем текущую сессию И обновляем jar (повторный вызов после
  # логина обязан привязать новый токен к АВТОРИЗОВАННОЙ сессии)
  # v7.2.5: ${COOKIE_JAR:-} — вызов без предварительного kit_login больше не
  # роняет set -u («COOKIE_JAR: unbound variable»)
  out="$(curl_panel --max-time 8 -b "${COOKIE_JAR:-}" -c "${COOKIE_JAR:-}" "$(api_url)csrf-token" 2>/dev/null)" || return 0
  if jq -e '.success == true' <<<"$out" >/dev/null 2>&1; then
    CSRF_TOKEN="$(jq -r '.obj // ""' <<<"$out" 2>/dev/null || true)"
  fi
  return 0
}

kit_login() {
  COOKIE_JAR="$(mktemp /tmp/xkit-ck.XXXXXX)"; chmod 600 "$COOKIE_JAR"
  local url rc code out resp
  url="$(api_url)login"
  # 3X-UI v3+: POST /login без CSRF-токена = 403 с ПУСТЫМ телом. GET /csrf-token
  # создаёт сессию и возвращает токен (как у браузера); v2: 404 — без заголовка
  csrf_fetch
  resp="$(mktemp /tmp/xkit-login.XXXXXX)"; chmod 600 "$resp"
  local -a h=()
  [ -n "$CSRF_TOKEN" ] && h+=(-H "X-CSRF-Token: $CSRF_TOKEN")
  # V-03 (аудит №2): тело через stdin (--data @-) — пароль не светится в argv
  local body
  body="username=$(jq -rn --arg v "${PANEL_USER:-}" '$v|@uri')&password=$(jq -rn --arg v "${PANEL_PASS:-}" '$v|@uri')"
  rc=0
  code="$(printf '%s' "$body" | curl_panel --max-time 8 -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
    -o "$resp" -w '%{http_code}' -X POST "${h[@]}" \
    -H 'Content-Type: application/x-www-form-urlencoded' --data @- "$url")" || rc=$?
  out="$(cat "$resp" 2>/dev/null || true)"; rm -f "$resp"
  if [ "$rc" -ne 0 ]; then
    err "Панель не отвечает (127.0.0.1:${PANEL_PORT}, curl exit ${rc}) — проверьте: systemctl status x-ui"
    return 1
  fi
  if [ "$code" = "403" ]; then
    err "Панель отклонила запрос (403: CSRF-мiddleware) — устаревший xkit для этой версии 3X-UI"
    err "Обновите меню:  xkit update  (или скачайте свежий xkit.sh из репозитория)"
    return 1
  fi
  if ! jq -e '.success == true' <<<"$out" >/dev/null 2>&1; then
    err "Не удалось войти в API панели (127.0.0.1:${PANEL_PORT}${PANEL_WBP}login, HTTP ${code})"
    if [ -n "$out" ]; then
      err "Ответ: $(head -c 300 <<<"$out")"
    else
      err "Тело ответа пустое (HTTP ${code}) — нестандартная сборка 3X-UI или прокси перед панелью"
    fi
    err "Проверьте логин/пароль панели (install-result.env или меню панели x-ui)"
    return 1
  fi
  # v4.9.1: после логина панель ЧИСТИТ сессию (SetLoginUser -> s.Clear()) —
  # CSRF-токен анонимной сессии аннулирован, и все POST вернули бы 403.
  # Переполучаем токен уже от АВТОРИЗОВАННОЙ сессии — как делает и фронтенд панели
  csrf_fetch
  return 0
}

api_get() {
  local url; url="$(api_url)panel/api/inbounds/$1"
  local -a a=(-s --max-time 10)
  [ "${PANEL_SCHEME:-http}" = "https" ] && a+=(-k)
  [ -n "${COOKIE_JAR:-}" ] && a+=(-b "$COOKIE_JAR")
  api_auth_args
  curl "${a[@]}" "${API_AUTH_ARGS[@]}" "$url"
}

# один POST-вызов без восстановления (внутренняя для api_post)
_api_post_once() { # $1 url, $2 JSON-тело (пусто = без тела)
  local -a args=(-s --max-time 15 -X POST)
  [ "${PANEL_SCHEME:-http}" = "https" ] && args+=(-k)
  [ -n "${COOKIE_JAR:-}" ] && args+=(-b "$COOKIE_JAR")
  [ -n "${CSRF_TOKEN:-}" ] && args+=(-H "X-CSRF-Token: $CSRF_TOKEN")
  api_auth_args
  if [ -n "${2:-}" ]; then
    # Тело может содержать пароли и ключи: только stdin, никогда argv процесса.
    printf '%s' "$2" | curl "${args[@]}" "${API_AUTH_ARGS[@]}" -H 'Content-Type: application/json' --data-binary @- "$1"
  else
    # v7.4.1: bearer и в ветке без тела (del/resetTraffic POST-ы без JSON-а —
    # раньше ушли без Authorization и на bearer-сессии возвращали 401)
    curl "${args[@]}" "${API_AUTH_ARGS[@]}" "$1"
  fi
}

# v7.4.1: общий каркас POST с восстановлением аутентификации: вызывает
# $1 = имя функции-исполнителя (остальное — её аргументы); при пустом/не-JSON
# ответе — _api_auth_recover и ОДИН повтор. Валидный JSON не трогаем.
_api_post_guard_run() { # $1 fn, $2.. аргументы fn
  local fn="$1"; shift
  local resp
  resp="$($fn "$@")" || return 1
  if ! jq -e 'type=="object"' <<<"$resp" >/dev/null 2>&1; then
    _api_auth_recover || true
    resp="$($fn "$@")" || return 1
  fi
  printf '%s' "$resp"
}

api_post() { # $1 путь, $2 JSON-тело (пусто = без тела)
  local url; url="$(api_url)panel/api/inbounds/$1"
  _api_post_guard_run _api_post_once "$url" "${2:-}"
}

# v7.4.2: нормализация wire-формата инбаундов. 3X-UI v3 отдаёт поля
# settings/streamSettings/sniffing/allocate ВЛОЖЕННЫМИ ОБЪЕКТАМИ, а не
# JSON-строками (живой лог 7.4.1: инбаунды создаются, но «Подписки: ссылок 0» —
# весь код xkit читает их как '.settings|fromjson' и получал null). Приводим к
# v2-wire (компактные JSON-строки) на входе — вся существующая логика (подписки,
# клиенты, классификация, экспирация) работает одинаково на v2 и v3.
# На запись панели v3 строки по-прежнему принимают (официальные API-docs:
# «legacy callers that send them back as JSON-encoded strings are still
# accepted on write»), поэтому add/update round-trip не меняется.
_ib_wire_v2_norm() { # stdin: один инбаунд ИЛИ массив -> stdout: поля как строки
  jq -c 'def n:
    (if ((.settings // null) | type) == "object"      then .settings      |= tojson else . end)
    | (if ((.streamSettings // null) | type) == "object" then .streamSettings |= tojson else . end)
    | (if ((.sniffing // null) | type) == "object"      then .sniffing      |= tojson else . end)
    | (if ((.allocate // null) | type) == "object"      then .allocate      |= tojson else . end);
    if type == "array" then map(n) else n end'
}

api_list() {
  local out
  out="$(api_get list)" || { err "Панель не отвечает на запрос списка инбаундов"; return 1; }
  if ! jq -e '.success == true' <<<"$out" >/dev/null 2>&1; then
    err "API list: $(api_err_msg "$out" | head -c 200)"
    return 1
  fi
  jq '(.obj // [])' <<<"$out" | _ib_wire_v2_norm
}

# полный JSON одного инбаунда по id
api_get_inbound() {
  local out
  out="$(api_get "get/$1")" || return 1
  jq -e '.success == true' <<<"$out" >/dev/null 2>&1 || return 1
  jq '(.obj // null)' <<<"$out" | _ib_wire_v2_norm
}

# обновить инбаунд целиком (панель применит listen/streamSettings)
api_update_inbound() { # $1 id, $2 полный JSON инбаунда
  local resp
  resp="$(api_post "update/$1" "$2")" || return 1
  if ! jq -e '.success == true' <<<"$resp" >/dev/null 2>&1; then
    err "update инбаунда #$1: $(api_err_msg "$resp" | head -c 200)"
    return 1
  fi
  return 0
}

# удалить инбаунд целиком (3x-ui API: POST /panel/api/inbounds/del/:id)
api_del_inbound() { # $1 id
  local resp
  resp="$(api_post "del/$1" "")" || return 1
  if ! jq -e '.success == true' <<<"$resp" >/dev/null 2>&1; then
    err "del инбаунда #$1: $(api_err_msg "$resp" | head -c 200)"
    return 1
  fi
  return 0
}

_api_post_json_once() { # $1 url, $2 JSON-тело
  local -a args=(-s --max-time 20 -X POST -H 'Content-Type: application/json')
  [ "${PANEL_SCHEME:-http}" = "https" ] && args+=(-k)
  [ -n "${COOKIE_JAR:-}" ] && args+=(-b "$COOKIE_JAR")   # v7.2.5: guard set -u
  [ -n "${CSRF_TOKEN:-}" ] && args+=(-H "X-CSRF-Token: $CSRF_TOKEN")
  api_auth_args
  printf '%s' "$2" | curl "${args[@]}" "${API_AUTH_ARGS[@]}" --data-binary @- "$1"
}

api_post_json() { # $1 путь от base, $2 JSON-тело — для эндпоинтов вне /panel/api/inbounds
  local url; url="$(api_url)${1#/}"
  _api_post_guard_run _api_post_json_once "$url" "${2:-}"
}

# application/x-www-form-urlencoded без секретов в командной строке curl.
_api_post_form_once() { # $1 url, $2 готовое urlencoded-тело
  local -a args=(-s --max-time 20 -X POST -H 'Content-Type: application/x-www-form-urlencoded')
  [ "${PANEL_SCHEME:-http}" = "https" ] && args+=(-k)
  [ -n "${COOKIE_JAR:-}" ] && args+=(-b "$COOKIE_JAR")   # v7.2.5: guard set -u
  [ -n "${CSRF_TOKEN:-}" ] && args+=(-H "X-CSRF-Token: $CSRF_TOKEN")
  api_auth_args
  printf '%s' "$2" | curl "${args[@]}" "${API_AUTH_ARGS[@]}" --data-binary @- "$1"
}

api_post_form() { # $1 путь; далее key=value
  local url; url="$(api_url)${1#/}"
  local body="" kv k v ek ev
  for kv in "${@:2}"; do
    k="${kv%%=*}"; v="${kv#*=}"
    ek="$(jq -rn --arg v "$k" '$v|@uri')" || return 1
    ev="$(jq -rn --arg v "$v" '$v|@uri')" || return 1
    [ -z "$body" ] || body+="&"
    body+="${ek}=${ev}"
  done
  _api_post_guard_run _api_post_form_once "$url" "$body"
}

# v4.9.1: 3X-UI v3 перенёс клиентов в /panel/api/clients/*:
#   add     POST /panel/api/clients/add              {"client":{...},"inboundIds":[id]}
#   del     POST /panel/api/clients/del/:email
#   reset   POST /panel/api/clients/resetTraffic/:email
# (старые v2-пути inbounds/addClient, inbounds/:id/delClient/:cid в v3 УДАЛЕНЫ)
api_normalize_tgid() { # клиент или inbound: пустой tgId отсутствует, числовой — JSON-число
  jq -c 'def n: if .tgId? == "" then del(.tgId) elif (.tgId?|type)=="string" then .tgId = (.tgId | if test("^-?[0-9]+$") then tonumber else error("tgId must be an integer") end) else . end;
    if has("settings") then .settings = ((.settings|fromjson) | .clients |= map(n) | tojson) else n end'
}

api_add_client() { # $1 id инбаунда, $2 JSON ОДНОГО клиента, $3 текущая строка settings (для v2)
  local id="$1" cj="$2" settings="$3" resp
  cj="$(api_normalize_tgid <<<"$cj")" \
    || { err "addClient: tgId должен быть целым числом или отсутствовать"; return 1; }
  if [ "$API_V3" = "1" ]; then
    local body
    body="$(jq -nc --argjson c "$cj" --argjson i "$id" '{client:$c, inboundIds:[$i]}')"
    resp="$(api_post_json "panel/api/clients/add" "$body")" || return 1
  else
    local body new_settings
    new_settings="$(jq -c --argjson c "$cj" '.clients += [$c]' <<<"$settings")" || return 1
    body="$(jq -n --arg id "$id" --arg s "$new_settings" '{"id":($id|tonumber),"settings":$s}')"
    resp="$(api_post addClient "$body")" || return 1
  fi
  if ! jq -e '.success == true' <<<"$resp" >/dev/null 2>&1; then
    err "addClient: $(api_err_msg "$resp" | head -c 200)"
    return 1
  fi
  return 0
}

api_del_client() { # $1 id инбаунда, $2 email, $3 clientId (uuid; нужен только v2)
  local resp
  if [ "$API_V3" = "1" ]; then
    resp="$(api_post_raw "panel/api/clients/del/$2")" || return 1
  else
    resp="$(api_post "$1/delClient/$3" "")" || return 1
  fi
  if ! jq -e '.success == true' <<<"$resp" >/dev/null 2>&1; then
    err "delClient: $(api_err_msg "$resp" | head -c 200)"
    return 1
  fi
  return 0
}

# единая точка входа: залогиниться и получить список инбаундов
# результат в глобальной INBOUNDS (JSON-массив)
kit_session() {
  load_xkit_env || true
  read_panel_settings || return 1
  PANEL_SCHEME=$(detect_panel_scheme "$PANEL_PORT")
  # v7.2.5: быстрый путь через API-токен (3x-ui v3.11+) — без логина, cookie
  # и CSRF. Токен не задан/не принят — классический логин (ниже), он же фолбэк.
  if api_token_ok; then
    API_V3=1
    INBOUNDS="$(api_list)" || return 1
    return 0
  fi
  kit_login || return 1
  api_detect_generation
  INBOUNDS="$(api_list)" || return 1
  return 0
}

# поколение API: GET /panel/api/openapi.json отвечает JSON-ом только в v3+
# (v2: 404/SPA). Лениво и без цензуры: не определили — считаем v2 (старые пути)
api_detect_generation() {
  local out
  API_V3=0
  out="$(api_get_raw "panel/api/openapi.json" 2>/dev/null || true)"
  if jq -e '.openapi' <<<"$out" >/dev/null 2>&1; then
    API_V3=1
    log "Панель 3X-UI v3: клиенты/настройки через /panel/api/clients|setting|xray/*"
  fi
  return 0
}

#=========================== КЛАССИФИКАЦИЯ ИНБАУНДОВ ==========================
# Что можно спрятать за nginx (один порт 443, маршрутизация по путям), а что
# живёт напрямую своим портом (Reality/UDP/raw-TCP — это их дизайн).
# Вывод: "net|sec|mode|reason"   mode: routed | direct
classify_inbound() { # $1 = JSON одного инбаунда
  local net sec hdr proto
  net="$(jq -r '.streamSettings|fromjson?|.network // "tcp"' <<<"$1")"
  sec="$(jq -r '.streamSettings|fromjson?|.security // "none"' <<<"$1")"
  proto="$(jq -r '.protocol // ""' <<<"$1")"

  if [ "$sec" = "reality" ]; then
    printf '%s|%s|direct|Reality сам терминирует TLS и маскируется под сайт — за nginx не прячется, порт прямой' "$net" "$sec"
    return 0
  fi
  case "$proto" in
    vless|vmess|trojan) ;;
    shadowsocks) printf 'tcp|%s|direct|Shadowsocks не умеет ws/grpc-транспорт — порт прямой (либо UFW deny)' "$sec"; return 0 ;;
    *)           printf '%s|%s|direct|протокол %s не мультиплексируется по путям' "$net" "$sec" "$proto"; return 0 ;;
  esac
  case "$net" in
    ws|grpc|xhttp|splithttp|httpupgrade) printf '%s|%s|routed|' "$net" "$sec" ;;
    tcp)
      hdr="$(jq -r '.streamSettings|fromjson?|.tcpSettings.header.type // "none"' <<<"$1")"
      if [ "$hdr" = "http" ]; then printf 'tcp|%s|routed|' "$sec"
      else printf '%s|%s|direct|raw TCP не маршрутизируется по путям на 443' "$net" "$sec"; fi ;;
    *) printf '%s|%s|direct|транспорт %s (UDP/сокет) nginx не проксирует' "$net" "$sec" "$net" ;;
  esac
}

# короткий тег транспорта для канонического пути
net_tag() { case "$1" in ws) echo ws ;; grpc) echo gr ;; xhttp|splithttp) echo xh ;; httpupgrade) echo hu ;; *) echo tc ;; esac }

# текущий путь/имя сервиса инбаунда (то, что задано в streamSettings)
inbound_path() { # $1 inbound JSON, $2 net (ws|grpc|xhttp|httpupgrade|tcp)
  local s='.streamSettings | if type=="string" then (fromjson? // {}) else (. // {}) end'
  case "$2" in
    ws)          jq -r "${s}|.wsSettings.path // \"\"" <<<"$1" ;;
    grpc)        jq -r "${s}|.grpcSettings.serviceName // \"\"" <<<"$1" ;;
    xhttp)       jq -r "${s}|(.xhttpSettings.path // .splithttpSettings.path // \"\")" <<<"$1" ;;
    httpupgrade) jq -r "${s}|.httpupgradeSettings.path // \"\"" <<<"$1" ;;
    tcp)         jq -r "${s}|((.tcpSettings.header.request.path // \"\") | if type==\"array\" then (.[0] // \"\") else . end)" <<<"$1" ;;
  esac
}

# инфо о маршруте инбаунда из routes.tsv: mode|net|path
route_info() { # $1 inbound id
  local row
  row="$(awk -F'\t' -v id="$1" '$1==id{print $2"|"$3"|"$4; exit}' "$XKIT_ROUTES" 2>/dev/null)"
  printf '%s' "${row:-||}"
}

#=========================== АВТОПРОБРОС (ПУНКТ 2) ============================
# Сам находит все инбаунды через API панели, переводит их на 127.0.0.1,
# канонизирует пути и строит единый конфиг nginx. Reality/UDP пропускает.
auto_route() {
  load_xkit_env || die "Сначала выполните установку (пункт 1)"
  [ -n "$XKIT_HOST" ] || die "Не задан XKIT_HOST в $XKIT_ENV"
  command -v jq >/dev/null 2>&1 || die "jq не найден (apt install jq)"
  command -v sqlite3 >/dev/null 2>&1 || true

  log "Подключаюсь к API панели..."
  kit_session || return 1
  routes_load

  local yes="${XKIT_YES:-0}"
  local total=0 routed=0 direct=0 changed=0
  local id port tag proto enable mode net sec reason tag2 path cur_listen cur_path need

  echo ""
  printf '%-4s %-16s %-9s %-6s %-8s %s\n' "ID" "TAG" "PROTO" "PORT" "РЕЖИМ" "ПУТЬ/ПРИЧИНА"
  echo "--------------------------------------------------------------------------------"

  while IFS= read -r ib; do
    [ -z "$ib" ] && continue
    id="$(jq -r '.id' <<<"$ib")"
    port="$(jq -r '.port' <<<"$ib")"
    tag="$(jq -r '.tag // "inbound"' <<<"$ib")"
    proto="$(jq -r '.protocol' <<<"$ib")"
    enable="$(jq -r '.enable // true' <<<"$ib")"
    total=$((total+1))

    if [ "$enable" != "true" ]; then
      routes_del "$id"
      printf '%-4s %-16s %-9s %-6s %-8s %s\n' "$id" "${tag:0:16}" "$proto" "$port" "off" "инбаунд выключен"
      continue
    fi

    # pool-инбаунд xkit (балансировка нод): listen 127.0.0.1 и канонический
    # путь уже на месте — не классифицируем и не переспрашиваем, только
    # подтверждаем маршрут (v4.5: раньше отображался как обычный «ЗА nginx»)
    if [ -n "${XKIT_POOL_INBOUND:-}" ] && [ "$id" = "$XKIT_POOL_INBOUND" ]; then
      local ppath_
      ppath_="$(inbound_path "$ib" ws)"
      [ -n "$ppath_" ] && routes_upsert "$id" local ws "$ppath_" "127.0.0.1:${port}" "$tag"
      printf '%-4s %-16s %-9s %-6s %-8s %s\n' "$id" "${tag:0:16}" "$proto" "$port" "POOL" "инбаунд балансировки нод (не трогаю)"
      continue
    fi

    IFS='|' read -r net sec mode reason <<<"$(classify_inbound "$ib")"

    if [ "$mode" != "routed" ]; then
      routes_del "$id"
      direct=$((direct+1))
      printf '%-4s %-16s %-9s %-6s %-8s %s\n' "$id" "${tag:0:16}" "$proto" "$port" "DIRECT" "${reason:0:60}"
      continue
    fi

    tag2="$(net_tag "$net")"
    if [ "$tag2" = "tc" ]; then
      # tcp+http: путь задаёт пользователь, канонизировать нельзя
      path="$(inbound_path "$ib" tcp)"
      if [ -z "$path" ]; then
        routes_del "$id"; direct=$((direct+1))
        printf '%-4s %-16s %-9s %-6s %-8s %s\n' "$id" "${tag:0:16}" "$proto" "$port" "DIRECT" "tcp+http без пути"
        continue
      fi
      case "$path" in /*) ;; *) path="/$path" ;; esac
      if ! is_nginx_path "$path"; then
        routes_del "$id"; direct=$((direct+1))
        printf '%-4s %-16s %-9s %-6s %-8s %s\n' "$id" "${tag:0:16}" "$proto" "$port" "DIRECT" "путь tcp+http нестандартный — в nginx не добавляю (K-01)"
        continue
      fi
    else
      path="$(auto_path_for "$tag2" "$port")"
    fi

    cur_listen="$(jq -r '.listen // ""' <<<"$ib")"
    cur_path="$(inbound_path "$ib" "$tag2")"
    need=""
    case "$cur_listen" in ""|"0.0.0.0"|"::"|"*") need="listen" ;; esac
    if [ "$tag2" != "tc" ] && [ "$cur_path" != "$path" ]; then need="${need}+path"; fi

    if [ -n "$need" ]; then
      if [ "$yes" != "1" ]; then
        echo ""
        warn "Инбаунд #$id ($tag, порт $port): требуется ${need#+} → путь $path, listen 127.0.0.1"
        confirm "Применить изменения? [Y/n] " y \
          || { warn "Пропущен #$id"; direct=$((direct+1)); continue; }
      fi
      local svc
      svc="${path//\//}"   # xk-gr-2083 (без слэшей) — serviceName для gRPC
      if [ "$tag2" != "tc" ]; then
        local new_ib
        new_ib="$(jq --arg listen "127.0.0.1" --arg p "$path" --arg sn "$svc" '
          .listen=$listen
          | .streamSettings = ((.streamSettings | fromjson?)
              | (if .network=="ws" then .wsSettings.path=$p
                 elif .network=="grpc" then .grpcSettings.serviceName=$sn
                 elif (.network=="xhttp" or .network=="splithttp") then
                   (if (has("xhttpSettings")) then .xhttpSettings.path=$p else .splithttpSettings.path=$p end)
                 elif .network=="httpupgrade" then .httpupgradeSettings.path=$p
                 else . end)
              | tojson)' <<<"$ib")"
      else
        local new_ib
        new_ib="$(jq --arg listen "127.0.0.1" '.listen=$listen' <<<"$ib")"
      fi
      if api_update_inbound "$id" "$new_ib"; then
        changed=$((changed+1))
        ok "#$id: listen=127.0.0.1, путь=$path (панель обновлена)"
      else
        err "#$id: обновление через API не прошло — маршрутизирую как есть (listen $(echo "${cur_listen:-0.0.0.0}" | head -c 12))"
      fi
    fi

    routes_upsert "$id" local "$tag2" "$path" "127.0.0.1:${port}" "$tag"
    routed=$((routed+1))
    printf '%-4s %-16s %-9s %-6s %-8s %s\n' "$id" "${tag:0:16}" "$proto" "$port" "ЗА nginx" "$path"
  done < <(jq -c '.[]' <<<"$INBOUNDS")

  echo "--------------------------------------------------------------------------------"
  ok "Итого: $total инбаундов; за nginx: $routed; прямые порты: $direct; изменений: $changed"

  log "Пересобираю конфиг nginx..."
  regen_conf_and_apply || return 1

  log "Перегенерирую подписки..."
  sub_regen_quiet || true

  echo ""
  log "Снаружи открыт только 443 (и 80 для редиректа). Порты локальных инбаундов не видны:"
  log "  проверить: ss -tlnp | grep -v 127.0.0.1   — там не должно быть портов панели/инбаундов"
  return 0
}

#=========================== ГЕНЕРАЦИЯ КОНФИГА NGINX ==========================
# Полный конфиг строится заново из состояния: панель + подписки + маршруты.
gen_xkit_conf() { # stdout
  local host="${XKIT_HOST:?XKIT_HOST не задан}"
  [ -n "${XKIT_CRT:-}" ] && [ -n "${XKIT_KEY:-}" ] || { err "Не заданы пути к сертификату"; return 1; }
  XKIT_SUB_PATH="$(sub_path)"
  local tls_h2 tls_h2_v6="" l80_v6=""
  # v7.2.5 (маскировка): публичный 443 отдаёт сайт-прикрытие, а не служебную
  # «Welcome!»-страницу — сервер целиком выглядит как обычный статический сайт.
  # ACME-путь остаётся на /var/www/html (location ниже перекрывает root).
  # Camo не создан — откат на прежний root, конфиг не рвём.
  local www_root="/var/www/html"
  [ -f "${CAMO_DIR:-/var/www/camo}/index.html" ] && www_root="${CAMO_DIR:-/var/www/camo}"
  tls_h2="$(build_h2_block)"
  # А3 IPv6: при наличии глобального v6-адреса слушаем и [::] (пустая строка =
  # обычный v4-only конфиг, поведение прежнее)
  if v6_listen_enabled; then
    tls_h2_v6="$(build_h2_block v6)"
    l80_v6="    listen [::]:80;"
  fi

  cat <<EOF
# =========================================================================
# xkit.conf — УПРАВЛЯЕТСЯ XKIT v${XKIT_VERSION}, НЕ редактируйте вручную.
# Пересборка: xkit (меню) -> пункт 2   |   state: $XKIT_ENV, $XKIT_ROUTES
# =========================================================================
map \$http_upgrade \$connection_upgrade { default upgrade; '' ''; }
server {
    listen 80;
${l80_v6}
    server_name ${host};
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
${tls_h2}
${tls_h2_v6}
    server_name ${host};
    ssl_certificate ${XKIT_CRT};
    ssl_certificate_key ${XKIT_KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:XKIT:10m;
    ssl_session_timeout 1h;
    ssl_session_tickets off;
    server_tokens off;
    keepalive_timeout 1h;
    client_max_body_size 0;
    root ${www_root};
    index index.html;
    error_page 404 /404.html;
    location / { try_files \$uri \$uri/ =404; }
EOF

  # --- панель (привязана к 127.0.0.1, наружу не видна) ---
  if [ -n "${PANEL_PORT:-}" ] && [ -n "${PANEL_WBP:-}" ]; then
    if [ "$PANEL_WBP" = "/" ]; then
      warn "Панель на корне (/) — пропускаю её location, иначе конфликт с сайтом-заглушкой"
    else
      generate_web_proxy_block "Панель 3X-UI" "$PANEL_WBP" "127.0.0.1:${PANEL_PORT}" "${PANEL_SCHEME:-http}"
    fi
  fi

  # --- подписки (файлы, формирует xkit) ---
  generate_subs_block

  # --- веб-дашборд (секретный путь, как у панели) ---
  if [ "${XKIT_DASH:-0}" = "1" ] && [ -n "${XKIT_DASH_TOKEN:-}" ]; then
    generate_dash_block
  fi

  # --- нативные подписки самой панели (проксируются через nginx на 443) ---
  if [ -n "${XKIT_PANEL_SUB_PORT:-}" ] && [ -n "${XKIT_PANEL_SUB_PATH:-}" ]; then
    generate_web_proxy_block "Подписки 3X-UI" "$XKIT_PANEL_SUB_PATH" "127.0.0.1:${XKIT_PANEL_SUB_PORT}" "http"
  fi

  # --- маршруты инбаундов / relay ---
  local row r_id r_mode r_net r_path r_target r_tag r_num
  routes_load
  for row in "${ROUTES[@]}"; do
    [ -z "$row" ] && continue
    IFS=$'\t' read -r r_id r_mode r_net r_path r_target r_tag <<<"$row"
    [ -n "$r_path" ] && [ -n "$r_target" ] || continue
    case "$r_net" in
      grpc) r_num=1 ;;
      ws)   r_num=2 ;;
      xhttp)r_num=3 ;;
      tcp)  r_num=4 ;;
      tgweb)r_num=9 ;;
      *)    continue ;;
    esac
    if [ "$r_net" = tgweb ]; then
      generate_tgweb_block "$r_path" "$r_target"
    elif [ "$r_mode" = "relay" ]; then
      generate_location_block "$r_num" "$r_path" "$r_target" "false"
    else
      generate_location_block "$r_num" "$r_path" "$r_target" "true"
    fi
  done

  printf '\n}\n'

  # --- сайт-прикрытие для Reality dest (dest=127.0.0.1:8444, только с localhost) ---
  if [ "${XKIT_REALITY_INTERNAL:-0}" = "1" ]; then
    cat <<EOF

# Внутренний TLS-сайт для Reality: xray проксирует сюда посторонних,
# клиент Reality видит легитимный сайт с сертификатом ${host}.
server {
    listen 127.0.0.1:8444 ssl;
    server_name ${host};
    ssl_certificate ${XKIT_CRT};
    ssl_certificate_key ${XKIT_KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    root /var/www/camo;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
EOF
  fi
  return 0
}

# собрать и применить конфиг: бэкап -> запись -> nginx -t -> reload (откат при ошибке)
regen_conf_and_apply() {
  read_panel_settings || return 1
  PANEL_SCHEME=$(detect_panel_scheme "$PANEL_PORT")
  # v7.2.5 (маскировка): сайт-прикрытие создаётся при каждой пересборке конфига
  # (идемпотентно, seed хранится в $XKIT_CAMO_STATE) — публичная маскировка
  # больше не зависит от того, какая ветка Reality/HY2 была выбрана или дошла
  # ли она до конца. Сбой генерации не срывает применение конфига.
  mkdir -p "$(dirname "${CAMO_DIR:-/var/www/camo}")"
  if ! camo_site_install; then
    warn "Сайт-прикрытие не создан — публичный 443 отдаст служебную заглушку"
  fi
  if [ -f "$XKIT_CONF" ]; then backup_file "$XKIT_CONF" >/dev/null; fi
  mkdir -p /var/www/html
  [ -f /var/www/html/index.html ] || printf '<!doctype html><html><head><title>Welcome</title></head><body><h1>Welcome!</h1><p>This server is up and running.</p></body></html>\n' > /var/www/html/index.html
  if ! gen_xkit_conf > "${XKIT_CONF}.tmp"; then
    rm -f "${XKIT_CONF}.tmp"; err "Генерация конфига не удалась"; return 1
  fi
  mv "${XKIT_CONF}.tmp" "$XKIT_CONF"; chmod 644 "$XKIT_CONF"
  ln -sf "$XKIT_CONF" "$XKIT_CONF_LINK"
  rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default 2>/dev/null
  if ! apply_config "$XKIT_CONF"; then
    err "Конфиг НЕ применён (откат выполнен). Проверьте nginx -t вручную."
    return 1
  fi
  return 0
}

#=========================== ССЫЛКИ-ШАРИНГ (подписки) =========================
# ВАЖНО: подписки формирует сам xkit — в ссылках всегда https://ДОМЕН:443/путь
# для инбаундов за nginx и реальные адреса/порты для direct-инбаундов
# (Reality и т.п.). Ссылки панели с 127.0.0.1 наружу не уходят.

reality_pbk() { # $1 = ТЕКСТ streamSettings (уже объект для jq)
  jq -r '.realitySettings.settings.publicKey // .realitySettings.publicKey // ""' <<<"$1" 2>/dev/null
}
reality_sid() { jq -r '.realitySettings.shortIds[0] // ""' <<<"$1" 2>/dev/null; }
reality_sni() { jq -r '.realitySettings.serverNames[0] // ""' <<<"$1" 2>/dev/null; }

# собирает одну ссылку для клиента
link_for_client() { # $1 inbound JSON, $2 client JSON (settings-объект)
  local ib="$1" cl="$2"
  local id port proto tag2 mode rnet rpath
  id="$(jq -r '.id' <<<"$ib")"; port="$(jq -r '.port' <<<"$ib")"
  proto="$(jq -r '.protocol' <<<"$ib")"
  IFS='|' read -r mode rnet rpath <<<"$(route_info "$id")"

  local stream="" host="" path="" svc="" sni="" pbk="" sid="" flow="" email="" uuid="" pass="" method=""
  stream="$(jq -r '.streamSettings // "{}"' <<<"$ib")"
  host="${XKIT_HOST}"
  email="$(jq -r '.email // "user"' <<<"$cl")"
  flow="$(jq -r '.flow // ""' <<<"$cl")"

  if [ "$mode" = "local" ]; then
    # за nginx: TLS на 443, путь из routes.tsv
    case "$rnet" in
      grpc) svc="$(inbound_path "$ib" grpc)"; [ -n "$svc" ] || svc="xk-gr-${port}" ;;
      ws|xhttp|httpupgrade) path="$(inbound_path "$ib" "$rnet")"; [ -n "$path" ] || path="$rpath" ;;
      tcp) path="$(inbound_path "$ib" tcp)"; [ -n "$path" ] || path="$rpath" ;;
    esac
    _link_proto "$proto" "$email" "$host" 443 "$rnet" "tls" "$path" "$svc" "$host" "" "" "" "$flow" "$cl" "$ib"
  else
    # direct: реальный порт, security из streamSettings ($stream — уже JSON-текст)
    local net="" sec=""
    net="$(jq -r '.network // "tcp"' <<<"$stream" 2>/dev/null)"
    sec="$(jq -r '.security // "none"' <<<"$stream" 2>/dev/null)"
    [ "$sec" = "tls" ] && sni="$host"
    if [ "$sec" = "reality" ]; then
      pbk="$(reality_pbk "$stream")"; sid="$(reality_sid "$stream")"; sni="$(reality_sni "$stream")"
      [ -n "$sni" ] || sni="$host"
    fi
    # v5.2: direct XHTTP/WS/gRPC тоже нуждаются в path/serviceName; раньше
    # direct-ветка всегда передавала пустые значения, и XHTTP-ссылка была неполной.
    case "$net" in
      ws|xhttp|splithttp|httpupgrade) path="$(inbound_path "$ib" "$net")" ;;
      grpc) svc="$(inbound_path "$ib" grpc)" ;;
      tcp) path="$(inbound_path "$ib" tcp)" ;;
    esac
    _link_proto "$proto" "$email" "$host" "$port" "$net" "$sec" "$path" "$svc" "${sni:-}" "$pbk" "$sid" "" "$flow" "$cl" "$ib"
  fi
}

# внутренний сборщик ссылки по протоколу
_link_proto() { # proto email host port net sec path svc sni pbk sid fp flow client ib
  local proto="$1" email="$2" host="$3" port="$4" net="$5" sec="$6" path="${7:-}" svc="${8:-}"
  local sni="${9:-}" pbk="${10:-}" sid="${11:-}" fp="${12:-}" flow="${13:-}" cl="${14}" ib="${15}"
  local q="" e; e="$(enc_uri "$email")"
  local link=""

  case "$proto" in
    vless)
      local uuid; uuid="$(jq -r '.id // ""' <<<"$cl")"
      [ -n "$uuid" ] || return 0
      q="type=${net}&security=${sec}"
      case "$net" in
        ws)          q+="&path=$(enc_uri_path "$path")&host=$(enc_uri "$host")" ;;
        grpc)        q+="&serviceName=$(enc_uri "$svc")&mode=gun" ;;
        xhttp|splithttp) q+="&path=$(enc_uri_path "$path")&mode=auto" ;;
        httpupgrade) q+="&path=$(enc_uri_path "$path")&host=$(enc_uri "$host")" ;;
        tcp)         [ -n "$path" ] && q+="&headerType=http&path=$(enc_uri_path "$path")&host=$(enc_uri "$host")" ;;
      esac
      if [ "$sec" = "tls" ]; then
        q+="&sni=$(enc_uri "${sni:-$host}")&fp=${fp:-chrome}"
      elif [ "$sec" = "reality" ]; then
        q+="&sni=$(enc_uri "$sni")&fp=${fp:-chrome}&pbk=$(enc_uri "$pbk")"
        [ -n "$sid" ] && q+="&sid=$(enc_uri "$sid")"
        [ -n "$flow" ] && q+="&flow=$(enc_uri "$flow")"
      fi
      link="vless://${uuid}@${host}:${port}?${q}#${e}" ;;

    vmess)
      local uuid tls
      uuid="$(jq -r '.id // ""' <<<"$cl")"; [ -n "$uuid" ] || return 0
      [ "$sec" = "tls" ] && tls="tls" || tls=""
      [ "$net" = "xhttp" ] && net="xhttp"
      local cj
      cj="$(jq -nc --arg ps "$email" --arg add "$host" --arg port "$port" --arg id "$uuid" \
        --arg net "$net" --arg host "$host" --arg path "$path" --arg tls "$tls" --arg sni "${sni:-$host}" \
        --arg svc "$svc" --arg sec "$sec" '
        {v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:$net,type:"none",
         host:$host,path:(if $net=="grpc" then $svc else $path end),
         tls:$tls,sni:(if $tls=="tls" then $sni else "" end),
         sn:(if $net=="grpc" then $svc else "" end)}')"
      link="vmess://$(printf '%s' "$cj" | base64 -w0)" ;;

    trojan)
      pass="$(jq -r '.password // .id // ""' <<<"$cl")"; [ -n "$pass" ] || return 0
      q="security=${sec}&type=${net}&sni=$(enc_uri "${sni:-$host}")"
      case "$net" in
        ws)   q+="&path=$(enc_uri_path "$path")&host=$(enc_uri "$host")" ;;
        grpc) q+="&serviceName=$(enc_uri "$svc")&mode=gun" ;;
        xhttp|splithttp) q+="&path=$(enc_uri_path "$path")&mode=auto" ;;
      esac
      link="trojan://$(enc_uri "$pass")@${host}:${port}?${q}#${e}" ;;

    shadowsocks)
      # ss живёт прямым портом; клиент ss в 3x-ui: password в клиенте или в settings
      pass="$(jq -r '.password // ""' <<<"$cl")"
      [ -n "$pass" ] || pass="$(jq -r '.settings|fromjson?|.password // ""' <<<"$ib")"
      [ -n "$pass" ] || return 0
      method="$(jq -r '.settings|fromjson?|.method // "aes-256-gcm"' <<<"$ib")"
      link="ss://$(printf '%s' "${method}:${pass}" | base64 -w0)@${host}:${port}#${e}" ;;

    hysteria)
      # v6.0.0: панельный inbound Hysteria2 (протокол hysteria ядра Xray 26.x).
      # Пароль клиента — в .auth; alpn h3. При self-signed серте — pinSHA256.
      pass="$(jq -r '.auth // ""' <<<"$cl")"; [ -n "$pass" ] || return 0
      local hq hpin
      if [ "${XKIT_CERT_MODE:-}" = "4" ]; then
        hpin="$(clash_cert_pin)"
        hq="insecure=1"; [ -n "$hpin" ] && hq="pinSHA256=$(enc_uri "$hpin")"
      else
        hq="sni=$(enc_uri "${sni:-$host}")"
      fi
      link="hysteria2://$(enc_uri "$pass")@${host}:${port}?${hq}&alpn=h3#${e}" ;;

    amneziawg)
      # v7.4.2: vpn:// (base64 клиентского .conf AmneziaVPN) собираем САМИ —
      # раньше полагались на panel_sub_links, но нативный sub-сервер панели
      # может быть не настроен/изменён, и AmneziaWG-клиент выпадал из подписки.
      # Формат 1:1 с фронтендом 3x-ui (frontend/src/pages/clients/amneziaWGConfig.ts):
      # [Interface] ключи клиента + обфускация СЕРВЕРА, [Peer] PublicKey сервера,
      # Endpoint = наш домен:порт. AllowedIPs туннеля — весь трафик (0.0.0.0/0).
      local st sv cpriv cpsk cip cka conf
      st="$(jq -r '.settings|if type=="string" then (fromjson? // {}) else . end' <<<"$ib")"
      sv="$(jq -c '.server // {}' <<<"$st")"
      cpriv="$(jq -r '.privateKey // .password // ""' <<<"$cl")"
      [ -n "$cpriv" ] || return 0
      cip="$(jq -r '(.allowedIPs // [])[0] // ""' <<<"$cl")"
      [ -n "$cip" ] || cip="10.8.1.2/32"
      cpsk="$(jq -r '.preSharedKey // ""' <<<"$cl")"
      cka="$(jq -r '.keepAlive // 0' <<<"$cl")"
      [[ "$cka" =~ ^[0-9]+$ ]] || cka=0
      conf="$(jq -rn --arg priv "$cpriv" --arg addr "$cip" --arg psk "$cpsk" \
                --argjson ka "$cka" --argjson sv "$sv" --arg rem "${tag:-inbound} - ${email}" \
                --arg host "$host" --arg port "$port" '
        def h($k; $v; $d): "\($k) = \(if ($v // "" | tostring | length) > 0 then ($v|tostring) else $d end)";
        [ "[Interface]",
          "PrivateKey = \($priv)",
          "Address = \($addr)",
          (if ([($sv.primaryDns // ""), ($sv.secondaryDns // "")] | map(select(. != "")) | length) > 0
           then "DNS = \([($sv.primaryDns // ""), ($sv.secondaryDns // "")] | map(select(. != "")) | join(", "))"
           else empty end),
          "MTU = \($sv.mtu // 1280)",
          "Jc = \($sv.jc // 5)",
          "Jmin = \($sv.jmin // 10)",
          "Jmax = \($sv.jmax // 50)",
          "S1 = \($sv.s1 // 30)",
          "S2 = \($sv.s2 // 45)",
          (if ($sv.s3 // 0) != 0 then "S3 = \($sv.s3)" else empty end),
          (if ($sv.s4 // 0) != 0 then "S4 = \($sv.s4)" else empty end),
          h("H1"; $sv.h1; "1"),
          h("H2"; $sv.h2; "2"),
          h("H3"; $sv.h3; "3"),
          h("H4"; $sv.h4; "4"),
          ([$sv.i1, $sv.i2, $sv.i3, $sv.i4, $sv.i5] | to_entries[]
             | select((.value // "") != "") | "I\(.key+1) = \(.value)"),
          ([{k:"HeaderProtectionKey",v:$sv.headerProtectionKey},
             {k:"ContentPaddingAddition",v:$sv.contentPaddingAddition},
             {k:"RekeyAfterTime",v:$sv.rekeyAfterTime},
             {k:"RekeyTimeout",v:$sv.rekeyTimeout},
             {k:"RejectAfterTime",v:$sv.rejectAfterTime},
             {k:"KeepaliveTimeout",v:$sv.keepaliveTimeout},
             {k:"MaxHandshakeAttempts",v:$sv.maxHandshakeAttempts}][]
             | select((.v // "") != "") | "\(.k) = \(.v)"),
          (if ($sv.randomTrailers // false) then "RandomTrailers = on" else empty end),
          (if ($sv.disableCookies // false) then "DisableCookies = on" else empty end),
          "",
          "# \($rem)",
          "[Peer]",
          "PublicKey = \($sv.publicKey // "")",
          (if ($psk != "") then "PresharedKey = \($psk)" else empty end),
          "AllowedIPs = 0.0.0.0/0, ::/0",
          "Endpoint = \($host):\($port)",
          (if $ka > 0 then "PersistentKeepalive = \($ka)" else empty end)
        ] | join("\n")')"
      # пустой PublicKey сервера = битый конфиг — ссылку не отдаём
      [ -n "$(jq -r '.publicKey // ""' <<<"$sv")" ] || return 0
      link="vpn://$(printf '%s' "$conf" | base64 -w0)" ;;

    wireguard)
      # wireguard:// URI рендерит сама панель — попадает в подписку
      # через panel_sub_links; свою реализацию формата не дублируем
      return 0 ;;

    *) return 0 ;;
  esac
  printf '%s\n' "$link"
}


#=========================== v7.4.3: SOCKOPT (TCP Fast Open + TCP_NODELAY) ====
# Рекомендуемые «быстрые» настройки TCP-инбаундов (транспорты tcp/ws/grpc/
# xhttp/httpupgrade; UDP-протоколы Hysteria2/AmneziaWG не затрагиваются).
#   * tcpNoDelay: true    — отключает алгоритм Нейгла (latency);
#   * tcpFastOpen: true   — серверная сторона TFO; требует net.ipv4.tcp_fastopen
#                           с серверным битом (0x2) — xkit ставит sysctl = 3.
# Управление: xkit sockopt on|off|status; XKIT_SOCKOPT=0 — не добавлять при
# создании Reality/XHTTP инбаундов. ВАЖНО: если менять sockopt ВРУЧНУЮ в панели,
# xkit больше не трогает эти инбаунды сам — но форма 3x-ui при правке
# streamSettings требует заново выбрать dest/SNI Reality (особенность UI панели,
# не xkit), поэтому предпочтителен путь `xkit sockopt`.
sockopt_enabled() { [ "${XKIT_SOCKOPT:-1}" = "1" ]; }

sockopt_obj() { # -> JSON sockopt для streamSettings
  jq -nc '{tcpFastOpen:true,tcpNoDelay:true}'
}

sockopt_net_ok() { # $1 network — sockopt осмыслен только для TCP-транспортов
  case "$1" in tcp|raw|ws|grpc|xhttp|splithttp|httpupgrade) return 0 ;; *) return 1 ;; esac
}

sockopt_tfo_sysctl_apply() { # включить серверный бит TFO (net.ipv4.tcp_fastopen=3)
  local cur
  cur="$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo 0)"
  if [ "$((cur & 2))" -ne 2 ]; then
    printf 'net.ipv4.tcp_fastopen = 3\n' > /etc/sysctl.d/99-xkit-tfo.conf
    chmod 644 /etc/sysctl.d/99-xkit-tfo.conf
    sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true
    cur="$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo 0)"
    if [ "$((cur & 2))" -ne 2 ]; then
      warn "ядро не применило net.ipv4.tcp_fastopen=3 — серверная сторона TFO не заработает"
      return 1
    fi
    ok "sysctl: net.ipv4.tcp_fastopen=3 (TFO клиент+сервер), файл /etc/sysctl.d/99-xkit-tfo.conf"
  else
    ok "sysctl: net.ipv4.tcp_fastopen=$cur — серверный бит TFO уже включён"
  fi
  return 0
}

sockopt_patch_stream() { # stdin: streamSettings JSON, $1 on|off -> stdout
  # пустой вывод = изменений не требуется
  local mode="$1" st net
  st="$(cat)"
  net="$(jq -r '.network // ""' <<<"$st" 2>/dev/null)"
  sockopt_net_ok "$net" || return 0
  if [ "$mode" = "on" ]; then
    jq -e '.sockopt.tcpFastOpen == true and .sockopt.tcpNoDelay == true' <<<"$st" >/dev/null 2>&1 && return 0
    jq -c --argjson so "$(sockopt_obj)" '.sockopt = ((.sockopt // {}) + $so)' <<<"$st"
  else
    # off: снимаем ТОЛЬКО наш sockopt (ровно tcpFastOpen+tcpNoDelay, без других
    # ключей) — ручные настройки администратора не трогаем
    jq -e '.sockopt.tcpFastOpen == true and .sockopt.tcpNoDelay == true
           and ([.sockopt | keys_unsorted[]] | length == 2)' <<<"$st" >/dev/null 2>&1 || return 0
    jq -c 'del(.sockopt)' <<<"$st"
  fi
}

sockopt_cmd() { # xkit sockopt [on|off|status]
  local mode="${1:-status}"
  require_root; load_xkit_env || die "Сначала установка (пункт 1)"
  case "$mode" in on|off|status) ;; *) err "xkit sockopt on|off|status"; return 1 ;; esac
  local tfo
  tfo="$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo 0)"
  if [ "$mode" = "status" ]; then
    echo "sysctl net.ipv4.tcp_fastopen = ${tfo} $([ "$((tfo & 2))" -eq 2 ] && echo '(серверный TFO включён)' || echo '(серверный TFO ВЫКЛЮЧЕН — xkit sockopt on)')"
    echo ""
    printf '%-4s %-22s %-8s %-6s %s\n' 'ID' 'TAG' 'NET' 'PORT' 'SOCKOPT'
    kit_session >/dev/null 2>&1 || { err "Нет сессии панели"; return 1; }
    local ib id tag port net st so
    while IFS= read -r ib; do
      [ -z "$ib" ] && continue
      id="$(jq -r '.id' <<<"$ib")"; tag="$(jq -r '.tag' <<<"$ib")"; port="$(jq -r '.port' <<<"$ib")"
      net="$(jq -r '.streamSettings|fromjson?|.network // "-"' <<<"$ib" 2>/dev/null)"
      st="$(jq -r '.streamSettings|fromjson?|.sockopt // {}|c' <<<"$ib" 2>/dev/null)"
      case "$st" in {}|null) so="-" ;; *) so="$st" ;; esac
      printf '%-4s %-22s %-8s %-6s %s\n' "$id" "$tag" "$net" "$port" "$so"
    done < <(jq -c '.[]' <<<"$(api_list 2>/dev/null)" 2>/dev/null)
    return 0
  fi
  kit_session || return 1
  [ "$mode" = "on" ] && sockopt_tfo_sysctl_apply || true
  local ib id tag port patched new n=0 s=0 proto
  log "Применяю sockopt ${mode} к TCP-инбаундам панели..."
  while IFS= read -r ib; do
    [ -z "$ib" ] && continue
    id="$(jq -r '.id' <<<"$ib")"; tag="$(jq -r '.tag' <<<"$ib")"; port="$(jq -r '.port' <<<"$ib")"
    proto="$(jq -r '.protocol' <<<"$ib")"
    case "$proto" in vless|vmess|trojan) ;; *) s=$((s+1)); continue ;; esac
    new="$(jq -r '.streamSettings|fromjson?' <<<"$ib" 2>/dev/null | sockopt_patch_stream "$mode")"
    if [ -z "$new" ]; then s=$((s+1)); continue; fi
    patched="$(jq -c --arg st "$new" '.streamSettings = $st' <<<"$ib")"
    if api_update_inbound "$id" "$patched" >/dev/null 2>&1; then
      ok "#$id ${tag} (${port}/tcp): sockopt ${mode} — применено"
      n=$((n+1))
    else
      err "#$id ${tag}: sockopt ${mode} не применился"
    fi
  done < <(jq -c '.[]' <<<"$(api_list 2>/dev/null)" 2>/dev/null)
  echo ""
  ok "Итого: изменено ${n}, пропущено (UDP-протоколы/уже настроено/чужие правила) ${s}"
  [ "$mode" = "off" ] && warn "sysctl не откатывается автоматически: net.ipv4.tcp_fastopen=${tfo} (xkit sockopt статус sysctl — вручную при желании)"
  return 0
}
#=========================== ПОДПИСКИ =========================================
sub_regen_quiet() { SUB_QUIET=1 sub_regen; }
# v6.0.0: ссылки, которые рендерит САМА панель. Берем из нативной подписки панели
# (127.0.0.1:subPort), вырезаем только валидные схемы ссылок (панель может отдать
# HTML-страницу браузерному UA — мусор в подписки не попадает). Не настроено/
# недоступно — пусто.
# v7.4.2: vpn:// ИСКЛЮЧЁН — AmneziaWG-конфиги xkit теперь собирает сам
# (link_for_client), а дубль «наш vpn:// + панельный vpn://» с разным remark
# показывался бы в клиенте двумя одинаковыми серверами.
panel_sub_links() { # $1 subId -> строки ссылок на stdout
  [ -n "${XKIT_PANEL_SUB_PORT:-}" ] && [ -n "${XKIT_PANEL_SUB_PATH:-}" ] || return 0
  curl -fsS --max-time 8 "http://127.0.0.1:${XKIT_PANEL_SUB_PORT}${XKIT_PANEL_SUB_PATH}${1}" 2>/dev/null \
    | base64 -d 2>/dev/null | tr '\r' '\n' \
    | grep -E '^(vless|vmess|trojan|ss|hysteria2|hy2|tuic|tg|wireguard)://' || return 0
}

# v7.4.2: hy2://-ссылка Hysteria 2 отдельной службы (xkit-hysteria2). Пароль у
# службы один на всех — ссылка общая, добавляется в КАЖДУЮ подписку (в Clash-YAML
# так делает clash_standalone_hy2 с v6.0.0; теперь parity у base64 и sing-box).
sub_standalone_hy2_link() { # -> hy2://... (пусто = службы нет)
  [ -r "${XKIT_PROTOCOLS_ENV:-/etc/xkit/protocols.env}" ] || return 0
  # shellcheck disable=SC1090
  . "${XKIT_PROTOCOLS_ENV:-/etc/xkit/protocols.env}"
  [ -n "${HY2_PORT:-}" ] && [ -n "${HY2_AUTH:-}" ] || return 0
  [ -n "${XKIT_HOST:-}" ] || return 0
  # пути службы — через env с дефолтами (xkit_protocols.sh при `xkit sub` не
  # загружен; те же значения, что XKIT_HY2_BIN/XKIT_HY2_CONF компонента)
  [ -x "${XKIT_HY2_BIN:-/usr/local/bin/xkit-hysteria2}" ] || [ -f "${XKIT_HY2_CONF:-/etc/xkit/hysteria2/config.yaml}" ] || return 0
  local q="obfs=salamander&obfs-password=$(enc_uri "${HY2_OBFS:-}")"
  if [ "${XKIT_CERT_MODE:-}" = "4" ]; then
    q="insecure=1"
  else
    q+="&sni=$(enc_uri "$XKIT_HOST")"
  fi
  printf 'hy2://%s@%s:%s?%s&alpn=h3#%s' "$(enc_uri "$HY2_AUTH")" "$XKIT_HOST" "$HY2_PORT" "$q" "$(enc_uri 'XKIT-Hysteria2')"
}
# flock-обёртка (аудит №5): cron «13 * * * * xkit sub -q» и ручной запуск не должны
# пересекаться — иначе rm -f ${SUBS_DIR}/* + пересборка дают окно 404/битого base64.
# non-blocking: второй процесс тихо пропускает (cron повторит в следующий час).
sub_regen() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  { flock -n 9 || { [ "${SUB_QUIET:-0}" = "1" ] || warn "Подписки уже пересобираются другим процессом — пропуск"; return 0; }
    sub_regen_impl
  } 9>"${XKIT_DIR}/.sub_regen.lock"
}
sub_regen_impl() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  [ -n "$XKIT_HOST" ] || die "Не задан XKIT_HOST"
  log "Формирую подписки из данных панели..."
  kit_session || return 1
  panel_sub_uri_fix || return 1
  routes_load

  mkdir -p "$SUBS_DIR"
  # 750 root:www-data (а не 755): содержимое читает только nginx, не все локальные юзеры
  chgrp www-data /var/lib/xkit "$SUBS_DIR" 2>/dev/null || true
  chmod 750 /var/lib/xkit "$SUBS_DIR" 2>/dev/null || true
  rm -f "${SUBS_DIR:?}"/* 2>/dev/null
  local idx="${XKIT_DIR}/subs.index"
  : > "$idx"; chmod 600 "$idx"

  local n_links=0 n_subs=0 n_json=0
  local sub_headers="${XKIT_DIR}/sub-headers.nginx" sub_headers_new="${XKIT_DIR}/.sub-headers.nginx.new"
  : > "$sub_headers_new"; chmod 600 "$sub_headers_new"
  while IFS= read -r ib; do
    [ -z "$ib" ] && continue
    [ "$(jq -r '.enable // true' <<<"$ib")" = "true" ] || continue
    local id port proto tag
    id="$(jq -r '.id' <<<"$ib")"; port="$(jq -r '.port' <<<"$ib")"
    proto="$(jq -r '.protocol' <<<"$ib")"; tag="$(jq -r '.tag // "inbound"' <<<"$ib")"

    # клиенты инбаунда (+ одиночный пользователь для shadowsocks)
    local -a clients=()
    mapfile -t clients < <(jq -c '.settings|fromjson?|.clients[]?' <<<"$ib")
    if [ "$proto" = "shadowsocks" ] && [ "${#clients[@]}" -eq 0 ]; then
      clients=("$(jq -nc --arg p "$(jq -r '.settings|fromjson?|.password // ""' <<<"$ib")" --arg t "$tag" '{password:$p,email:$t}')")
    fi
    [ "${#clients[@]}" -gt 0 ] || continue

    local cl
    for cl in "${clients[@]}"; do
      local email subid link
      email="$(jq -r '.email // "user"' <<<"$cl")"
      subid="$(jq -r '.subId // ""' <<<"$cl")"
      # subId приходит из существующей панели и является именем файла.
      case "$subid" in *[!A-Za-z0-9_-]*)
        err "Клиент '$email': небезопасный subId пропущен (разрешены A-Z a-z 0-9 _ -)"
        continue ;;
      esac
      link="$(link_for_client "$ib" "$cl")"
      [ -n "$link" ] || continue
      n_links=$((n_links+1))
      if [ -n "$subid" ]; then
        printf '%s\n' "$link" >> "${SUBS_DIR}/.acc.${subid}"
        # v6.0.0: аккумулятор для Clash-YAML (id инбаунда + запись клиента)
        printf '%s\t%s\n' "$id" "$cl" >> "${SUBS_DIR}/.clash.${subid}"
        printf '%s\t%s\t%s\t%s\t%s\n' "$subid" "$email" "${tag:0:20}" "$proto" "$port" >> "$idx"
        if [ "$proto" = amneziawg ]; then
          if amnezia_qr_html "$link" "${SUBS_DIR}/${subid}.amnezia.html" >/dev/null; then
            chgrp www-data "${SUBS_DIR}/${subid}.amnezia.html" 2>/dev/null || true
            chmod 640 "${SUBS_DIR}/${subid}.amnezia.html"
          else
            rm -f "${SUBS_DIR}/${subid}.amnezia.html"
            warn "Amnezia-страница ${subid} не создана: нужен qrencode или python3-qrcode"
          fi
        fi
      fi
    done
  done < <(jq -c '.[]' <<<"$INBOUNDS")

  # баз64-файлы по subId (+ v6.0.0: ссылки панели, + Clash-YAML рядом)
  local acc f subid n_yaml=0 hy2l
  # v7.4.2: Hysteria 2 отдельной службой — общая ссылка в каждую подписку
  hy2l="$(sub_standalone_hy2_link 2>/dev/null || true)"
  [ -n "$hy2l" ] && n_links=$((n_links+1))
  for acc in "${SUBS_DIR}"/.acc.*; do
    [ -e "$acc" ] || break
    subid="${acc##*.acc.}"
    # ссылки, отрендеренные панелью (wireguard:// и др.) — без дублей
    panel_sub_links "$subid" | grep -Fxvf "$acc" >> "$acc" 2>/dev/null || true
    # v7.4.2: hy2 отдельной службы — в raw-подписку (и, следом, в sing-box JSON)
    [ -n "$hy2l" ] && printf '%s\n' "$hy2l" >> "$acc"
    f="${SUBS_DIR}/${subid}"
    sort -u "$acc" | tr '\n' '\n' | base64 -w0 > "$f"
    rm -f "$acc"
    chmod 644 "$f"
    # v7.0.0: sing-box генерируется локально из тех же проверенных URI.
    if singbox_json_gen "$f" "${SUBS_DIR}/${subid}.json" >/dev/null 2>&1; then
      chmod 644 "${SUBS_DIR}/${subid}.json"; n_json=$((n_json+1))
    else
      rm -f "${SUBS_DIR}/${subid}.json"; warn "sing-box: профиль ${subid} не создан"
    fi
    local meta="${XKIT_DIR}/.sub-${subid}.meta"
    subscription_metadata_update "$subid" "$INBOUNDS" > "$meta" 2>/dev/null || printf '{"up":0,"down":0,"total":0,"expire":0}\n' > "$meta"
    subscription_nginx_headers "$subid" "$meta" >> "$sub_headers_new" || true
    rm -f "$meta"
    # v6.0.0: Clash/Mihomo-профиль той же подписки (<subId>.yaml)
    if [ -s "${SUBS_DIR}/.clash.${subid}" ]; then
      clash_yaml_gen "$subid" "${SUBS_DIR}/.clash.${subid}" && n_yaml=$((n_yaml+1)) || rm -f "${SUBS_DIR}/.clash.${subid}" 2>/dev/null
    fi
    n_subs=$((n_subs+1))
  done
  rm -f "${SUBS_DIR}"/.clash.* 2>/dev/null || true
  if ! cmp -s "$sub_headers_new" "$sub_headers" 2>/dev/null; then
    mv -f "$sub_headers_new" "$sub_headers"; chmod 600 "$sub_headers"
    regen_conf_and_apply >/dev/null 2>&1 || warn "Subscription headers обновлены, но nginx не перезагружен"
  else
    rm -f "$sub_headers_new"
  fi

  if [ "${SUB_QUIET:-0}" != "1" ]; then
    ok "Подписки собраны: ссылок $n_links, файлов подписок $n_subs, Clash-YAML $n_yaml, sing-box JSON $n_json"
    sub_show
  else
    ok "Подписки: ссылок $n_links, файлов $n_subs, Clash-YAML $n_yaml, sing-box JSON $n_json"
  fi
  return 0
}

# показать URL подписок (по одному на subId)
sub_show() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  local only="${1:-}" idx="${XKIT_DIR}/subs.index"
  [ -s "$idx" ] || { warn "Подписок ещё нет — создайте пользователей (пункты 4-6) и выполните пункт 2"; return 0; }
  local sp; sp="$(sub_path)"
  echo ""
  log "URL подписок (вставить в клиент: v2rayNG / Streisand / Hiddify / v2rayN):"
  awk -F'\t' '!seen[$1 FS $2]++ {print $1"\t"$2"\t"$3}' "$idx" | while IFS=$'\t' read -r subid email tag; do
    [ -n "$only" ] && [ "$email" != "$only" ] && continue
    printf '  %-18s %-18s https://%s%s%s\n' "${subid:0:18}" "${email}" "$XKIT_HOST" "$sp" "$subid"
    printf '  %-18s %-18s https://%s%s%s.yaml  (Clash/Mihomo)\n' "" "" "$XKIT_HOST" "$sp" "$subid"
    printf '  %-18s %-18s https://%s%s%s.json  (sing-box)\n' "" "" "$XKIT_HOST" "$sp" "$subid"
    if awk -F'\t' -v s="$subid" -v e="$email" '$1==s && $2==e && $4=="amneziawg" {found=1} END {exit !found}' "$idx"; then
      printf '  %-18s %-18s https://%s%s%s/amnezia  (AmneziaVPN: QR + конфиг)\n' "" "" "$XKIT_HOST" "$sp" "$subid"
    fi
  done
  echo ""
  log "Форматы: base64 — v2ray-приложения (v2rayNG/Streisand/Hiddify/v2rayN);"
  log "         <subId>.yaml — приложения на ядре Mihomo (Clash Verge/FlClash)"
}

#=========================== ПОЛЬЗОВАТЕЛИ (клиенты) ===========================
list_inbounds_menu() { # показывает нумерованный список, результат в PICK_IB (JSON)
  local i=0 line
  local -a rows=()
  echo ""
  printf '%-3s %-4s %-22s %-9s %-6s %s\n' "#" "ID" "TAG" "PROTO" "PORT" "РЕЖИМ"
  echo "------------------------------------------------------------------------"
  while IFS= read -r ib; do
    [ -z "$ib" ] && continue
    [ "$(jq -r '.enable // true' <<<"$ib")" = "true" ] || continue
    local rid rmode
    IFS='|' read -r rmode _ _ <<<"$(route_info "$(jq -r '.id' <<<"$ib")")"
    i=$((i+1))
    rows+=("$ib")
    printf '%-3s %-4s %-22s %-9s %-6s %s\n' "$i" "$(jq -r '.id' <<<"$ib")" \
      "$(jq -r '.tag // "inbound"' <<<"$ib" | cut -c1-22)" "$(jq -r '.protocol' <<<"$ib")" \
      "$(jq -r '.port' <<<"$ib")" "$([ "$rmode" = "local" ] && echo "за nginx" || echo "direct")"
  done < <(jq -c '.[]' <<<"$INBOUNDS")
  [ "$i" -eq 0 ] && { warn "Активных инбаундов нет — создайте в панели (пункт 2 потом их пробросит)"; return 1; }
  read -r -p "Номер инбаунда [1-$i]: " n
  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "$i" ] || { err "Нет такого номера"; return 1; }
  PICK_IB="${rows[$((n-1))]}"
  return 0
}

client_add() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  kit_session || return 1
  routes_load
  list_inbounds_menu || return 1
  local ib="$PICK_IB"
  local id port proto sec
  id="$(jq -r '.id' <<<"$ib")"; port="$(jq -r '.port' <<<"$ib")"
  proto="$(jq -r '.protocol' <<<"$ib")"
  sec="$(jq -r '.streamSettings|fromjson?|.security // "none"' <<<"$ib")"

  local settings email uuid subid total=0 days=0 flow=""
  settings="$(jq -r '.settings' <<<"$ib")"
  jq -e . <<<"$settings" >/dev/null 2>&1 || { err "settings инбаунда #$id не парсятся как JSON — обновите 3x-ui"; return 1; }
  read -r -p "Имя (email) пользователя [u$(rand_hex 2)]: " email
  email="${email:-u$(rand_hex 2)}"
  # таб/перевод строки ломают subs.index (awk -F'\t') — вырезаем; остальное — предупреждение
  email="${email//$'\t'/}"; email="${email//$'\r'/}"; email="${email//$'\n'/}"; email="${email// /}"
  [[ "$email" =~ ^[A-Za-z0-9._@+-]{1,64}$ ]] || warn "Имя содержит нестандартные символы — лучше только A-Za-z0-9._@+-"
  read -r -p "Квота трафика, ГБ (0 = без лимита) [0]: " total; total="${total:-0}"
  read -r -p "Срок жизни, дней (0 = бессрочно) [0]: " days; days="${days:-0}"
  local vnet
  vnet="$(jq -r '.streamSettings|if type=="string" then (fromjson? // {}) else . end | .network // "tcp"' <<<"$ib")"
  if [ "$sec" = "reality" ] && [ "$proto" = "vless" ] && { [ "$vnet" = "tcp" ] || [ "$vnet" = "raw" ]; }; then
    read -r -p "Flow [xtls-rprx-vision]: " flow; flow="${flow:-xtls-rprx-vision}"
  fi
  uuid="$(new_uuid)"
  subid="$(rand_str 16)"

  local expiry=0 gb=0
  [ "$days" -gt 0 ] 2>/dev/null && expiry=$(( $(date +%s) * 1000 + days * 86400000 ))
  [ "$total" -gt 0 ] 2>/dev/null && gb=$(( total * 1073741824 ))

  local cj
  if [ "$proto" = "trojan" ] || [ "$proto" = "shadowsocks" ]; then
    cj="$(jq -nc --arg id "$uuid" --arg pass "$uuid" --arg email "$email" --arg sub "$subid" \
      --argjson total "$gb" --argjson exp "$expiry" --arg flow "$flow" '
      {id:$id, password:$pass, flow:$flow, email:$email, limitIp:0, totalGB:$total,
       expiryTime:$exp, enable:true, tgId:"", subId:$sub, reset:0}')"
  else
    cj="$(jq -nc --arg id "$uuid" --arg email "$email" --arg sub "$subid" \
      --argjson total "$gb" --argjson exp "$expiry" --arg flow "$flow" '
      {id:$id, flow:$flow, email:$email, limitIp:0, totalGB:$total,
       expiryTime:$exp, enable:true, tgId:"", subId:$sub, reset:0}')"
  fi

  log "Добавляю пользователя через API панели..."
  if ! api_add_client "$id" "$cj" "$settings"; then return 1; fi
  ok "Пользователь '$email' добавлен в инбаунд #$id"

  # свежая ссылка + подписка
  local link
  link="$(link_for_client "$ib" "$cj")"
  [ -n "$link" ] && { echo ""; ok "Ссылка для клиента (или в подписке ниже):"; printf '  %s\n' "$link"; }
  sub_regen_quiet || true
  local sp; sp="$(sub_path)"
  echo ""
  ok "Подписка этого пользователя: https://${XKIT_HOST}${sp}${subid}"
  return 0
}

client_show() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  kit_session || return 1
  local email="${1:-}" subid
  [ -n "$email" ] || { err "xkit client show <email>"; return 1; }
  subid="$(jq -r --arg email "$email" '[.[].settings|fromjson?|.clients[]?|select(.email==$email)|.subId // empty][0] // empty' <<<"$INBOUNDS")"
  [ -n "$subid" ] || { err "Пользователь '$email' не найден"; return 1; }
  sub_show "$email"
  sub_qr "$subid" svg
}

client_del() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  kit_session || return 1
  routes_load

  local -a users=()
  mapfile -t users < <(jq -r '[.[].settings|fromjson?|.clients[]?|.email // empty]|unique[]' <<<"$INBOUNDS")
  [ "${#users[@]}" -gt 0 ] || { warn "Пользователей нет"; return 0; }
  local requested="${1:-}" assume_yes="${2:-}" i=0 email n
  [ -z "$assume_yes" ] || [ "$assume_yes" = "--yes" ] || { err "xkit client del [email] [--yes]"; return 1; }
  if [ -n "$requested" ]; then
    printf '%s\n' "${users[@]}" | grep -Fxq -- "$requested" || { err "Пользователь '$requested' не найден"; return 1; }
    email="$requested"
  else
    printf '%-3s %s\n' "#" "ПОЛЬЗОВАТЕЛЬ"
    for email in "${users[@]}"; do i=$((i+1)); printf '%-3s %s\n' "$i" "$email"; done
    read -r -p "Номер пользователя для удаления [1-$i] (Enter — отмена): " n
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "$i" ] || { warn "Отменено"; return 0; }
    email="${users[$((n-1))]}"
  fi
  if [ "$assume_yes" != "--yes" ]; then
    confirm "Удалить '$email' из всех протоколов? [y/N] " n || { warn "Отменено"; return 0; }
  fi

  local ib id cid deleted=0 failed=0
  while IFS= read -r ib; do
    [ -n "$ib" ] || continue
    id="$(jq -r '.id' <<<"$ib")"
    cid="$(jq -r --arg email "$email" '.settings|fromjson?|.clients[]?|select(.email==$email)|.id // .password // empty' <<<"$ib" | head -n1)"
    [ -n "$cid" ] || continue
    if api_del_client "$id" "$email" "$cid"; then deleted=$((deleted+1))
    else failed=$((failed+1)); warn "Не удалось удалить '$email' из инбаунда #$id"; fi
  done < <(jq -c '.[]' <<<"$INBOUNDS")
  [ "$deleted" -gt 0 ] && sub_regen_quiet || true
  [ "$failed" -eq 0 ] || { err "Удалено записей: $deleted; ошибок: $failed — проверьте пользователя повторно"; return 1; }
  ok "Пользователь '$email' удалён из всех протоколов ($deleted)"
}

human_bytes() { # $1 байты -> читаемый вид (IEC; ЕДИНСТВЕННАЯ версия — не переопределять)
  awk -v b="${1:-0}" 'BEGIN{
    split("B KiB MiB GiB TiB",u," "); i=1
    while (b>=1024 && i<5){b/=1024;i++}
    printf (i==1?"%d %s":"%.1f %s"), b, u[i]}'
}
human_expiry() { local ms="$1"; if [ "$ms" -gt 0 ] 2>/dev/null; then date -d @$((ms/1000)) '+%Y-%m-%d' 2>/dev/null; else echo "∞"; fi; }

client_list() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  kit_session || return 1
  routes_load
  echo ""
  local any=0 ib cl rmode
  while IFS= read -r ib; do
    [ -z "$ib" ] && continue
    IFS='|' read -r rmode _ _ <<<"$(route_info "$(jq -r '.id' <<<"$ib")")"
    local tag proto port
    tag="$(jq -r '.tag // "inbound"' <<<"$ib")"; proto="$(jq -r '.protocol' <<<"$ib")"
    port="$(jq -r '.port' <<<"$ib")"
    echo -e "${GREEN}── ${tag}  (${proto}, порт ${port}, $([ "$rmode" = "local" ] && echo "за nginx" || echo "direct"))${NC}"
    local -a cls=()
    mapfile -t cls < <(jq -c '.settings|fromjson?|.clients[]?' <<<"$ib")
    if [ "${#cls[@]}" -eq 0 ]; then echo "   (нет клиентов)"; continue; fi
    any=$((any+1))
    printf '   %-26s %-12s %-10s %-11s %s\n' "EMAIL" "QUOTA" "ИСТЕКАЕТ" "ВКЛЮЧЁН" "ТРАФИК (↑+↓)"
    local used
    for cl in "${cls[@]}"; do
      local email subid totalgb exp up down
      email="$(jq -r '.email // "-"' <<<"$cl")"
      subid="$(jq -r '.subId // ""' <<<"$cl")"
      totalgb="$(jq -r '.totalGB // 0 | (tonumber? // 0)' <<<"$cl")"
      exp="$(jq -r '.expiryTime // 0' <<<"$cl")"
      up=0; down=0
      # (баг №1, аудит v5.2.1): в else-ветке точка УЖЕ равна значению .clientStats
      # (массив); обращение .clientStats к массиву давало null -> трафик всегда 0
      up="$(jq -r --arg e "$email" '[(.clientStats | if type=="string" then (fromjson? // []) else (. // []) end)[]? | select(.email==$e) | (.up|tonumber? // 0)] | add // 0' <<<"$ib" 2>/dev/null)"
      down="$(jq -r --arg e "$email" '[(.clientStats | if type=="string" then (fromjson? // []) else (. // []) end)[]? | select(.email==$e) | (.down|tonumber? // 0)] | add // 0' <<<"$ib" 2>/dev/null)"
      used="$(human_bytes $((up+down)))"
      printf '   %-26s %-12s %-10s %-11s %s\n' "${email:0:26}" \
        "$([ "${totalgb:-0}" -gt 0 ] 2>/dev/null && human_bytes "$totalgb" || echo "∞")" \
        "$(human_expiry "${exp:-0}")" "$(jq -r 'if (.enable // true) then "да" else "нет" end' <<<"$cl")" "$used"
    done
  done < <(jq -c '.[]' <<<"$INBOUNDS")
  echo ""
  log "Ссылки подписок показываются отдельной командой: xkit sub"
  return 0
}

#=========================== ПОЛЬЗОВАТЕЛЬ ВО ВСЕ ПРОТОКОЛЫ (v6.0.0) ===========
# Модель 3X-UI_KIT: один пользователь = записи во ВСЕХ инбаундах (REALITY,
# XHTTP, Hysteria2, AmneziaWG...), один subId — одна подписка на всё.
# Свежий секрет на каждый инбаунд (uuid/пароль/ключи), общий лимит и срок.
client_add_all() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  kit_session || return 1
  routes_load
  local total_ibs
  total_ibs="$(jq -r '[.[]|select(.enable // true)]|length' <<<"$INBOUNDS" 2>/dev/null || echo 0)"
  [ "${total_ibs:-0}" -gt 0 ] || { err "Активных инбаундов нет — создайте протоколы (xkit protocols)"; return 1; }

  local email total=0 days=0
  echo "Пользователь будет добавлен во ВСЕ активные протоколы (${total_ibs} инбаундов)."
  read -r -p "Имя (email) пользователя [u$(rand_hex 2)]: " email
  email="${email:-u$(rand_hex 2)}"
  email="${email//$'\t'/}"; email="${email//$'\r'/}"; email="${email//$'\n'/}"; email="${email// /}"
  [[ "$email" =~ ^[A-Za-z0-9._@+-]{1,64}$ ]] || warn "Имя содержит нестандартные символы — лучше только A-Za-z0-9._@+-"
  read -r -p "Квота трафика, ГБ (0 = без лимита) [0]: " total; total="${total:-0}"
  read -r -p "Срок жизни, дней (0 = бессрочно) [0]: " days; days="${days:-0}"

  local subid expiry=0 gb=0
  subid="$(jq -r --arg email "$email" '[.[].settings|fromjson?|.clients[]?|select(.email==$email)|.subId // empty][0] // empty' <<<"$INBOUNDS")"
  [ -n "$subid" ] || subid="$(rand_str 16)"
  [ "$days" -gt 0 ] 2>/dev/null && expiry=$(( $(date +%s) * 1000 + days * 86400000 ))
  [ "$total" -gt 0 ] 2>/dev/null && gb=$(( total * 1073741824 ))

  local added=0 existing=0 failed=0 ib id settings cj link
  echo ""
  while IFS= read -r ib; do
    [ -z "$ib" ] && continue
    [ "$(jq -r '.enable // true' <<<"$ib")" = "true" ] || continue
    id="$(jq -r '.id' <<<"$ib")"
    local proto; proto="$(jq -r '.protocol' <<<"$ib")"
    if jq -e --arg email "$email" '.settings|fromjson?|.clients[]?|select(.email==$email)' <<<"$ib" >/dev/null 2>&1; then
      existing=$((existing+1)); ok "#$id (${proto}): уже добавлен — сохраняю существующую запись"; continue
    fi
    # PAYLOAD/EXTRA_* через глобалы: вызов в $(...) — субшелл, EXTRA_* терялись бы
    if ! client_payload_for "$ib" "$email" "$subid" "$gb" "$expiry"; then
      warn "#$id (${proto}): протокол не поддержан — пропущен"; failed=$((failed+1)); continue
    fi
    cj="${PAYLOAD:-}"
    [ -n "$cj" ] || { warn "#$id (${proto}): пустой payload — пропущен"; failed=$((failed+1)); continue; }
    settings="$(jq -r '.settings' <<<"$ib")"
    if api_add_client "$id" "$cj" "$settings"; then
      added=$((added+1))
      [ -n "$EXTRA_LINK" ] && printf '  %s\n' "$EXTRA_LINK"
      link="$(link_for_client "$ib" "$cj")"
      [ -n "$link" ] && printf '  %s\n' "$link"
      [ -n "$EXTRA_NOTE" ] && printf '  (%s)\n' "$EXTRA_NOTE"
      ok "#$id (${proto}): добавлен"
    else
      failed=$((failed+1)); warn "#$id (${proto}): панель отклонила клиента"
    fi
  done < <(jq -c '.[]' <<<"$INBOUNDS")

  echo ""
  if [ "$failed" -gt 0 ]; then warn "Итог: добавлен в ${added}, уже был в ${existing}, ошибок: ${failed}"
  else ok "Итог: добавлен в ${added}, уже был в ${existing}; единая подписка сохранена"; fi
  [ "$added" -gt 0 ] || [ "$existing" -gt 0 ] || { err "Ни один инбаунд не принял пользователя"; return 1; }
  [ "$added" -eq 0 ] || sub_regen_quiet || true
  local sp; sp="$(sub_path)"
  echo ""
  ok "ЕДИНАЯ подписка пользователя (${email}):"
  printf '  base64:       https://%s%s%s\n' "$XKIT_HOST" "$sp" "$subid"
  printf '  Clash/Mihomo: https://%s%s%s.yaml\n' "$XKIT_HOST" "$sp" "$subid"
  [ "$failed" -eq 0 ]
}

#=========================== РУЧНОЙ РЕЛЕЙ-МАРШРУТ =============================
# Проброс пути на ВНЕШНИЙ сервер (Relay): nginx 443 -> https/грpc upstream.
add_relay_route() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  echo "Транспорт: 1) gRPC  2) WebSocket  3) XHTTP"
  read -r -p "Выбор: " t
  case "$t" in 1) net=grpc ;; 2) net=ws ;; 3) net=xhttp ;; *) die "1-3" ;; esac
  path="$(read_path "Внешний путь (например /relay1/) -> ")"
  [ -n "$path" ] || die "Путь обязателен"
  rh="$(read_host "Внешний сервер (домен/IP backend) -> ")"
  [ -n "$rh" ] || die "Хост обязателен"
  rp=443
  if [ "$net" != "grpc" ]; then
    read -r -p "Порт backend [443]: " rp; rp="${rp:-443}"; is_port "$rp" || die "Порт некорректен"
  fi
  routes_upsert "m$(rand_hex 3)" relay "$net" "$path" "${rh}:${rp}" "manual"
  regen_conf_and_apply || return 1
  ok "Relay-маршрут: $path -> $rh:$rp (TLS до backend, SNI=$rh)"
  warn "Relay-маршруты НЕ попадают в подписки xkit — отдавайте клиенту ссылку вручную"
  return 0
}

#=========================== ПРОВЕРКА ЖИЗНЕСПОСОБНОСТИ ========================
# Что проверяем: сервисы, панель через nginx, серт, каждый маршрут, подписки,
# и главное — ЧТО СВЕТИТСЯ НАРУЖУ (порты на 0.0.0.0/::).
http_code_url() { # $1 url → код или 000
  curl -sk -o /dev/null -w '%{http_code}' --max-time 6 "$1" 2>/dev/null || printf '000'
}

health_check() {
  load_xkit_env || die "Нет состояния xkit — сначала установка (пункт 1)"
  local fails=0 warns=0 oks=0
  local mark_ok mark_bad mark_warn
  sect() { echo ""; echo -e "${BLUE}── $* ${NC}"; }
  okln()  { echo "  [OK]   $*"; oks=$((oks+1)); }
  warnln(){ echo "  [ВНИМ] $*"; warns=$((warns+1)); }
  badln() { echo "  [СБОЙ] $*"; fails=$((fails+1)); }

  sect "Сервисы"
  for s in nginx x-ui; do
    if systemctl is-active --quiet "$s" 2>/dev/null; then okln "$s: работает"
    else badln "$s: НЕ работает (systemctl status $s)"; fi
  done

  sect "Панель за nginx"
  if read_panel_settings >/dev/null 2>&1; then
    local code
    code="$(http_code_url "https://${XKIT_HOST}${PANEL_WBP}")"
    if [ "$code" != "000" ]; then okln "панель отвечает через nginx (HTTP $code): https://${XKIT_HOST}${PANEL_WBP}"
    else badln "панель недоступна через nginx (${PANEL_WBP})"; fi
    # не слушает ли панель снаружи
    if ss -ltnH 2>/dev/null | awk -v p=":${PANEL_PORT} " 'index($4,p) && $4 !~ /^(127\.0\.0\.1|\[::1\]|\[::ffff:127\.0\.0\.1\])/' | grep -q .; then
      warnln "порт панели ${PANEL_PORT} слушает НЕ только 127.0.0.1! Выполните: ufw deny ${PANEL_PORT}/tcp"
    else
      okln "порт панели ${PANEL_PORT} наружу не светится (только 127.0.0.1)"
    fi
  else
    badln "не удалось прочитать настройки панели"
  fi

  sect "Сертификат"
  if [ -f "${XKIT_CRT:-}" ]; then
    local end days
    end="$(openssl x509 -enddate -noout -in "$XKIT_CRT" 2>/dev/null | cut -d= -f2)"
    if [ -n "$end" ]; then
      days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
      if [ "$days" -lt 0 ]; then badln "сертификат ПРОСРОЧЕН"
      elif [ "$days" -lt 3 ] && [ "$XKIT_CERT_MODE" = "3" ]; then warnln "IP-серт живёт $days дн. (shortlived, авто-продление включено)"
      elif [ "$days" -lt 14 ]; then warnln "серт истекает через $days дн."
      else okln "серт действителен ещё $days дн. ($end)"; fi
    else badln "не удалось прочитать $XKIT_CRT"; fi
  else badln "сертификат не найден: ${XKIT_CRT:-не задан}"; fi

  sect "Маршруты инбаундов (любой HTTP-код = живой; 000 = труп)"
  routes_load
  if [ "${#ROUTES[@]}" -eq 0 ]; then warnln "маршрутов нет — выполните пункт 2 после создания инбаундов"
  else
    local row r_id r_mode r_net r_path r_target r_tag
    for row in "${ROUTES[@]}"; do
      IFS=$'\t' read -r r_id r_mode r_net r_path r_target r_tag <<<"$row"
      [ "$r_mode" = "local" ] || continue
      local c
      c="$(http_code_url "https://${XKIT_HOST}${r_path}")"
      if [ "$c" = "000" ]; then badln "$r_path -> $r_target: НЕ отвечает"
      else okln "$r_path -> $r_target: живой (HTTP $c)"; fi
    done
  fi

  sect "Подписки"
  local idx="${XKIT_DIR}/subs.index"
  if [ -s "$idx" ]; then
    local first_sub; first_sub="$(awk -F'\t' '{print $1; exit}' "$idx")"
    local sp c2
    sp="$(sub_path)"
    c2="$(http_code_url "https://${XKIT_HOST}${sp}${first_sub}")"
    if [ "$c2" = "200" ]; then okln "подписки раздаются через nginx (HTTP 200)"
    else badln "файл подписки не читается через nginx (HTTP $c2)"; fi
  else warnln "подписок нет (нет пользователей с subId)"; fi

  sect "Что СВЕТИТСЯ НАРУЖУ (слушатели не на 127.0.0.1/::1)"
  local exposed=0
  while IFS=$'\t' read -r netid addrport proc; do
    local addr port
    addr="${addrport%:*}"; port="${addrport##*:}"
    case "$addr" in "0.0.0.0"|"*"|"::"|"[::]") ;;
      *) continue ;;
    esac
    case "$port" in 80|443) continue ;; esac
    if echo "$proc" | grep -qE "sshd|openssh"; then okln "SSH :$port — нужно для доступа, это нормально"; continue; fi
    if ufw status 2>/dev/null | grep -q "Status: active"; then
      if ufw status 2>/dev/null | grep -qE "^${port}/(tcp|udp)[[:space:]]+ALLOW"; then
        warnln "порт ${netid}/${port} ($proc) открыт И в фаерволе — видно снаружи!"
      else
        warnln "порт ${netid}/${port} ($proc) слушает все интерфейсы, но закрыт фаерволом (ufw)"
      fi
    else
      badln "порт ${netid}/${port} ($proc) слушает все интерфейсы, ufw ВЫКЛЮЧЕН — видно снаружи!"
    fi
    exposed=$((exposed+1))
  done < <(ss -tulpnH 2>/dev/null | awk '{print $1"\t"$5"\t"$7}')
  [ "$exposed" -eq 0 ] && okln "лишних слушателей нет — наружу только 80/443 (+SSH)"

  sect "DNS (для домена)"
  if [ "$(host_kind "$XKIT_HOST")" = "domain" ]; then
    local myip dnsip
    myip="$(pubip)"
    dnsip="$(getent hosts "$XKIT_HOST" 2>/dev/null | awk '{print $1; exit}')"
    if [ -n "$myip" ] && [ -n "$dnsip" ]; then
      if [ "$myip" = "$dnsip" ]; then okln "$XKIT_HOST -> $dnsip (верно)"
      else badln "$XKIT_HOST -> $dnsip, а IP сервера $myip — исправьте A-запись!"; fi
    else warnln "не удалось проверить DNS (нет сети?)"
    fi
  else okln "$XKIT_HOST — IP-режим"; fi

  sect "Итог"
  echo "  OK: $oks | предупреждений: $warns | сбоев: $fails"
  [ "$fails" -eq 0 ] && ok "Всё живо" || err "Есть сбои — см. строки [СБОЙ] выше"
  return 0
}

#=========================== ГЛУБОКАЯ ПРОВЕРКА (v6.0.0) =======================
# Идея 3X-UI_KIT (deep check): порты и «systemctl is-active» не показывают,
# работает ли подключение НА САМОМ ДЕЛЕ. Здесь настоящий клиент Xray панели
# подключается по НАШИМ ЖЕ ссылкам (REALITY/XHTTP/Hysteria2-инбаунд) к
# публичному адресу сервера и открывает страницу через туннель.
# Честная оговорка (как у KIT): проверка идёт с самого сервера — доступность
# из вашей сети она не покажет; для этого откройте адрес сервера в браузере.
health_deep() {
  require_root
  load_xkit_env || die "Нет состояния xkit — сначала установка (пункт 1)"
  local fails=0 oks=0
  okln() { echo "  [OK]   $*"; oks=$((oks+1)); }
  badln() { echo "  [СБОЙ] $*"; fails=$((fails+1)); }
  infoln() { echo "  [i]    $*"; }

  echo ""
  echo -e "${BLUE}── Глубокая проверка: реальное подключение клиентом с самого сервера ${NC}"

  local xrbin
  xrbin="$(ls -1 /usr/local/x-ui/bin/xray-linux-* 2>/dev/null | head -n1)"
  command -v python3 >/dev/null 2>&1 || { err "Нужен python3"; return 1; }
  [ -n "$xrbin" ] || warn "Бинарник xray панели не найден — TCP-протоколы проверить нечем"

  local have_session=0
  if kit_session >/dev/null 2>&1; then have_session=1; else warn "Панель недоступна — пробую только отдельные службы"; fi

  local tmp port=18080 pid ok code tried=0
  tmp="$(mktemp -d /tmp/xkit-deep.XXXXXX)"
  local deep_reality_link="" deep_hy2_link=""

  if [ "$have_session" = "1" ] && [ -n "$xrbin" ]; then
    # первая живая ссылка REALITY (TCP или XHTTP) включённого клиента
    local ib cl
    while IFS= read -r ib; do
      [ -z "$ib" ] && continue
      [ "$(jq -r '.enable // true' <<<"$ib")" = "true" ] || continue
      local sec proto
      proto="$(jq -r '.protocol' <<<"$ib")"
      sec="$(jq -r '.streamSettings|if type=="string" then (fromjson? // {}) else . end | .security // "none"' <<<"$ib")"
      [ "$proto" = "vless" ] && [ "$sec" = "reality" ] || continue
      cl="$(jq -c '.settings|if type=="string" then (fromjson? // {clients:[]}) else . end | [.clients[]? | select(.enable == true and .subId != "")][0] // empty' <<<"$ib")"
      [ -n "$cl" ] || continue
      deep_reality_link="$(link_for_client "$ib" "$cl")"
      [ -n "$deep_reality_link" ] && break
    done < <(jq -c '.[]' <<<"$INBOUNDS")
    # панельный Hysteria2: первая ссылка из клиентских auth
    local hyib hycl hauth
    hyib="$(jq -c '[.[]|select(.protocol=="hysteria" and (.enable // true))][0] // empty' <<<"$INBOUNDS")"
    if [ -n "$hyib" ] && [ "$hyib" != "null" ]; then
      hycl="$(jq -c '.settings|if type=="string" then (fromjson? // {clients:[]}) else . end | [.clients[]? | select((.auth // "") != "")][0] // empty' <<<"$hyib")"
      [ -n "$hycl" ] && deep_hy2_link="$(link_for_client "$hyib" "$hycl")"
    fi
  fi

  # --- клиентский конфиг из ссылки (REALITY tcp/xhttp | hysteria2) ---
  deep_client_config() { # ссылка порт -> JSON на stdout; не 0 = проверять нечем
    python3 - "$1" "$2" <<'PY'
import json, sys
from urllib.parse import urlparse, parse_qs, unquote
u = urlparse(sys.argv[1]); q = {k: v[0] for k, v in parse_qs(u.query).items()}
if u.scheme == "hysteria2":
    tls = {"serverName": q.get("sni", ""), "alpn": ["h3"], "fingerprint": q.get("fp", "chrome")}
    pin = q.get("pinSHA256", "")
    if pin: tls["pinnedPeerCertSha256"] = pin
    if q.get("insecure") == "1": tls["allowInsecure"] = True
    print(json.dumps({"log": {"loglevel": "none"},
        "inbounds": [{"listen": "127.0.0.1", "port": int(sys.argv[2]), "protocol": "socks", "settings": {"udp": False}}],
        "outbounds": [{"protocol": "hysteria", "settings": {"version": 2, "address": u.hostname, "port": u.port},
            "streamSettings": {"network": "hysteria", "security": "tls", "tlsSettings": tls,
                               "hysteriaSettings": {"version": 2, "auth": u.username}}}]}))
    sys.exit(0)
if u.scheme != "vless" or q.get("security") != "reality":
    sys.exit(1)
net = q.get("type", "tcp")
if net == "splithttp": net = "xhttp"
st = {"network": net, "security": "reality", "realitySettings": {
    "serverName": q.get("sni", ""), "fingerprint": q.get("fp", "chrome"), "publicKey": q.get("pbk", ""),
    "shortId": q.get("sid", ""), "spiderX": unquote(q.get("spx", "/"))}}
if net == "xhttp":
    st["xhttpSettings"] = {"path": unquote(q.get("path", "/")), "mode": q.get("mode", "auto")}
user = {"id": u.username, "encryption": "none"}
if q.get("flow"): user["flow"] = q["flow"]
print(json.dumps({"log": {"loglevel": "none"},
    "inbounds": [{"listen": "127.0.0.1", "port": int(sys.argv[2]), "protocol": "socks", "settings": {"udp": False}}],
    "outbounds": [{"protocol": "vless", "settings": {"vnext": [{"address": u.hostname, "port": u.port, "users": [user]}]}, "streamSettings": st}]}))
PY
  }

  deep_probe() { # конфиг имя -> 0/1
    local cfg="$1" name="$2" i=0
    "$xrbin" run -c "$cfg" >/dev/null 2>&1 & pid=$!
    sleep 2; ok=no
    # ядро панели после изменения настроек перезапускается пару секунд — даём 3 попытки
    for i in 1 2 3; do
      code="$(curl -s -m 15 --socks5-hostname "127.0.0.1:$port" -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 2>/dev/null)"
      [ "$code" = "204" ] && { ok=yes; break; }
      sleep 3
    done
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
    [ "$ok" = "yes" ] && okln "$name: клиент подключился и открыл страницу" \
                      || badln "$name: подключение не состоялось (см. xkit health, journalctl -u x-ui -n 30)"
    [ "$ok" = "yes" ]
  }

  if [ -n "$deep_reality_link" ]; then
    tried=$((tried+1)); port=$((port+1))
    deep_client_config "$deep_reality_link" "$port" > "$tmp/$port.json" 2>/dev/null \
      && deep_probe "$tmp/$port.json" "REALITY/XHTTP" \
      || { tried=$((tried-1)); infoln "REALITY/XHTTP: ссылка не разобрана — пропущена"; }
  else
    infoln "REALITY/XHTTP: нет включённых клиентов с subId — нечего проверять"
  fi
  if [ -n "$deep_hy2_link" ]; then
    tried=$((tried+1)); port=$((port+1))
    deep_client_config "$deep_hy2_link" "$port" > "$tmp/$port.json" 2>/dev/null \
      && deep_probe "$tmp/$port.json" "Hysteria2 (панель)" \
      || { tried=$((tried-1)); infoln "Hysteria2 (панель): ссылка не разобрана — пропущена"; }
  else
    infoln "Hysteria2 (панель): инбаунда/клиентов нет — пропущено"
  fi

  # --- отдельные службы ---
  # (xkit health deep идёт без загрузки xkit_protocols.sh — читаем его env напрямую)
  [ -r "${XKIT_PROTOCOLS_ENV:-/etc/xkit/protocols.env}" ] && . "${XKIT_PROTOCOLS_ENV:-/etc/xkit/protocols.env}" 2>/dev/null || true
  if command -v hysteria >/dev/null 2>&1 || [ -x "${XKIT_HY2_BIN:-/nonexistent}" ]; then
    if [ -n "${HY2_PORT:-}" ] && [ -n "${HY2_AUTH:-}" ] && [ -x "${XKIT_HY2_BIN:-}" ]; then
      tried=$((tried+1)); port=$((port+1))
      local hcfg
      hcfg="$tmp/hy2-$port.yaml"
      {
        printf 'server: %s:%s\n' "$XKIT_HOST" "$HY2_PORT"
        printf 'auth: %s\n' "$HY2_AUTH"
        if [ "${XKIT_CERT_MODE:-}" = "4" ]; then
          printf 'tls:\n  sni: %s\n  insecure: true\n' "$XKIT_HOST"
        else
          printf 'tls:\n  sni: %s\n' "$XKIT_HOST"
        fi
        [ -n "${HY2_OBFS:-}" ] && printf 'obfs:\n  type: salamander\n  salamander:\n    password: %s\n' "$HY2_OBFS"
        printf 'socks5:\n  listen: 127.0.0.1:%s\n' "$port"
      } > "$hcfg"
      "$XKIT_HY2_BIN" client -c "$hcfg" >/dev/null 2>&1 & pid=$!
      sleep 2; ok=no
      local i2
      for i2 in 1 2 3; do
        code="$(curl -s -m 15 --socks5-hostname "127.0.0.1:$port" -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 2>/dev/null)"
        [ "$code" = "204" ] && { ok=yes; break; }
        sleep 3
      done
      kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
      [ "$ok" = "yes" ] && okln "Hysteria 2 (служба): клиент подключился и открыл страницу" \
                        || badln "Hysteria 2 (служба): подключение не состоялось"
    fi
  fi
  if command -v awg >/dev/null 2>&1 && systemctl is-active --quiet awg-quick@awg0 2>/dev/null; then
    local newest ts now age best=0
    newest="$(awg show awg0 latest-handshakes 2>/dev/null | awk '{print $2}' | sort -n | tail -n1)"
    if [ -n "$newest" ]; then
      now="$(date +%s)"; age=$((now - newest))
      if [ "$age" -lt 180 ]; then okln "AmneziaWG (служба): рукопожатие ${age} с назад — трафик идёт"
      else warn "AmneziaWG (служба): последнее рукопожатие ${age} с назад — давно не подключались"; fi
    else warn "AmneziaWG (служба): peers без рукопожатий (клиенты ещё не подключались)"; fi
  fi
  # панельный AWG: слушает ли ядро порт (реальное рукопожатие снаружи проверит только клиент)
  if [ "$have_session" = "1" ]; then
    local awgib aport
    awgib="$(jq -r '[.[]|select(.protocol=="amneziawg" and (.enable // true))][0].port // empty' <<<"$INBOUNDS" 2>/dev/null)"
    if [ -n "$awgib" ]; then
      if ss -lunH "sport = :$awgib" 2>/dev/null | grep -q .; then
        okln "AmneziaWG (панель): ядро слушает UDP ${awgib} (рукопожатия увидите в панели: Online/трафик)"
      else
        badln "AmneziaWG (панель): UDP ${awgib} НЕ слушается ядром — проверьте панель"
      fi
    fi
  fi

  rm -rf "$tmp"
  echo ""
  if [ "$tried" -eq 0 ]; then
    warn "Проверять было нечего: нет ни пользователей с subId, ни отдельных служб"
    return 0
  fi
  infoln "Проверка шла С САМОГО СЕРВЕРА — доступность из вашей сети она не показывает."
  infoln "Если клиент не подключается, а здесь всё [OK]: откройте https://${XKIT_HOST}/ в браузере телефона —"
  infoln "открылась страница = сеть доходит, ищите причину в клиенте (время, приложение, протокол)."
  [ "$fails" -eq 0 ] && ok "Глубокая проверка: всё живо (${oks} OK)" || err "Глубокая проверка: сбоев ${fails}"
  return 0
}

#=========================== БЭКАПЫ ===========================================
# v7.2.0: политика бэкапов настраивается (BACKUP_ENABLED / BACKUP_INTERVAL_H /
# BACKUP_KEEP_DAYS / BACKUP_KEEP_MIN — xkit.env или `xkit backup settings`),
# планировщик: cron стреляет ежедневно, интервал гейтится внутри
# `xkit backup auto` (cron не умеет «раз в 48/168 ч»; штамп последнего успеха —
# $XKIT_LAST_BACKUP, он лежит в $XKIT_DIR и сам попадает в архив — интервал
# после восстановления считается от бэкапа). В каждый архив кладутся
# MANIFEST.txt (версии компонентов) и RESTORE.txt (инструкция восстановления).

backup_manifest_write() { # $1 файл-манифест, $2.. члены архива
  local mf="$1"; shift
  local p _os="" _ng="" _xui=""
  _os="$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-unknown}")" || _os="н/д"
  _ng="$(nginx -v 2>&1 | head -n1 | tr -d '\n')" || _ng=""
  _xui="$(x-ui -v 2>/dev/null | head -n1 | tr -d '\n')" || _xui=""
  {
    echo "XKIT MANIFEST — $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "xkit_version: ${XKIT_VERSION:-н/д}"
    echo "host: ${XKIT_HOST:-н/д} (cert_mode: ${XKIT_CERT_MODE:-н/д})"
    echo "os: ${_os:-н/д} | kernel: $(uname -r 2>/dev/null || echo 'н/д')"
    echo "nginx: ${_ng:-не установлен} | panel: ${_xui:-н/д}"
    echo "backup_policy: enabled=${BACKUP_ENABLED:-1} interval_h=${BACKUP_INTERVAL_H:-24} keep_days=${BACKUP_KEEP_DAYS:-14} keep_min=${BACKUP_KEEP_MIN:-3}"
    echo "members:"
    for p in "$@"; do echo "  - $p"; done
    echo "note: при PostgreSQL-панели x-ui.db в архив НЕ входит (см. RESTORE.txt)"
  } > "$mf" 2>/dev/null
  [ -s "$mf" ]
}

backup_restore_doc() { # $1 файл-инструкция по восстановлению
  local mf="$1"
  cat > "$mf" <<EOF
ИНСТРУКЦИЯ ПО ВОССТАНОВЛЕНИЮ (RESTORE) — XKIT v${XKIT_VERSION:-н/д}
Сервер: ${XKIT_HOST:-н/д}; архив создан: $(date '+%Y-%m-%d %H:%M %Z')
======================================================================

ЧТО ВНУТРИ АРХИВА
  etc/xkit/          — состояние xkit (адрес, токен подписок, ноды, expiry)
  var/lib/xkit/subs/ — файлы подписок (base64 / Clash / sing-box)
  var/lib/xkit/dash/ — веб-дашборд (если был включён)
  etc/x-ui/x-ui.db   — БД панели 3X-UI (инбаунды/клиенты; SQLite)
  etc/nginx/ssl/     — сертификаты и ключи (selfsigned и/или LE-копии)
  etc/letsencrypt/   — аккаунт ACME + renewal-конфы + live-серты (если были)
  MANIFEST.txt       — версии компонентов на момент бэкапа
Пути в архиве — без ведущего «/». Если панель на PostgreSQL, x-ui.db в архив
НЕ входит — бэкап панели берите заранее в самой панели (Panel Settings -> Backup).

ЧТО ПОНАДОБИТСЯ
  - Ubuntu 22.04+ / Debian 12+ (точную ОС см. в MANIFEST.txt, поле os)
  - root; доступ к github.com и raw.githubusercontent.com
  - xkit той же или более новой версии, чем xkit_version из MANIFEST.txt
  - сам архив (и пароль age-экспорта, если делали «xkit backup export»)

ШАГИ
  1) Установите xkit (адрес сервера — ТОТ ЖЕ, что в MANIFEST.txt, см. нюанс):
     curl -fsSL https://raw.githubusercontent.com/kambarro/xkit/main/install.sh | sudo bash
  2) Положите архив на сервер и восстановите:
       xkit restore /путь/xkit-ГГГГММДД-ЧЧММСС.tar.gz
     Restore сам распакует, вернёт БД/состояние/подписки/серты, перезапустит
     nginx и панель. Архив вне ${BACKUP_DIR:-/var/backups/xkit} требует явного
     подтверждения YES (защита от чужого архива).
  3) Проверки после восстановления:
       xkit health      — жизнеспособность и «что светится наружу»
       xkit status      — сервисы, порты, маршруты
       openssl x509 -noout -dates -in /etc/nginx/ssl/<адрес>/fullchain.pem
       Панель и креды — см. ${XUI_RESULT:-/etc/x-ui/install-result.env} (chmod 600)

НЮАНСЫ (важно)
  - СЕРТЫ: если адрес сервера НЕ менялся — НЕ перевыпускайте сертификат.
    Серт из бэкапа валиден, пока: не истёк срок, ключ парный, SAN покрывает
    адрес. Установка/restore проверяют это сами и предлагают пункт
    «использовать найденный серт — без перевыпуска». Перевыпуск расходует
    недельные лимиты Let's Encrypt на дубликаты и меняет пару ключей —
    клиенты с pinned-отпечатком отвалятся. Selfsigned (10 лет) восстанавливать
    обязательно; LE-IP (shortlived, 6 дней) восстановится и продлится
    certbot-таймером сам.
  - КЛИЕНТЫ: UUID/ключи/ссылки подписок возвращаются из БД и состояния —
    переконфигурация клиентов НЕ нужна (SUB_TOKEN тот же).
  - PostgreSQL-БД панели восстанавливается отдельно средствами панели/СУБД.
  - Архив содержит приватные ключи: храните офлайн, права 600, не публикуйте.
======================================================================
EOF
  [ -s "$mf" ]
}

backup_retention_apply() {
  # v7.2.0: храним все архивы новее BACKUP_KEEP_DAYS дней; ПЛЮС всегда минимум
  # BACKUP_KEEP_MIN последних копий, даже если они старше («одна копия» не
  # должна быть единственной: сервер лежал месяц — свежих нет, старые целы).
  local f i=0 cutoff
  local -a del=()
  cutoff=$(( $(date +%s) - (${BACKUP_KEEP_DAYS:-14} * 86400) ))
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    i=$((i+1))
    [ "$i" -le "${BACKUP_KEEP_MIN:-3}" ] && continue   # последние N — неприкосновенны
    [ "$(stat -c %Y "$f" 2>/dev/null || echo 0)" -lt "$cutoff" ] && del+=("$f")
  done < <(ls -1t "$BACKUP_DIR"/xkit-*.tar.gz 2>/dev/null)
  local d
  for d in ${del[@]+"${del[@]}"}; do rm -f -- "$d" 2>/dev/null; done
  return 0
}

backup_now() {
  load_xkit_env || true
  mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
  local f="$BACKUP_DIR/xkit-$(date +%Y%m%d-%H%M%S).tar.gz"
  local -a paths=()
  [ -d "$XKIT_DIR" ] && paths+=("$XKIT_DIR")
  [ -f "$XKIT_CONF" ] && paths+=("$XKIT_CONF")
  [ -d "$SUBS_DIR" ] && paths+=("$SUBS_DIR")
  [ -f "$XUI_RESULT" ] && paths+=("$XUI_RESULT")
  [ -f "$XUI_DB" ] && paths+=("$XUI_DB")
  [ -d /etc/nginx/ssl ] && paths+=("/etc/nginx/ssl")
  [ -d /etc/letsencrypt ] && paths+=("/etc/letsencrypt")
  # v5.2: отдельные службы протоколов тоже входят в аварийный архив.
  [ -f /etc/amnezia/amneziawg/awg0.conf ] && grep -q '^# Managed by XKIT' /etc/amnezia/amneziawg/awg0.conf 2>/dev/null && paths+=("/etc/amnezia/amneziawg/awg0.conf")
  [ -f /etc/systemd/system/xkit-hysteria2.service ] && paths+=("/etc/systemd/system/xkit-hysteria2.service")
  [ -f /etc/sysctl.d/99-xkit-awg.conf ] && paths+=("/etc/sysctl.d/99-xkit-awg.conf")
  [ "${#paths[@]}" -eq 0 ] && { warn "Нечего бэкапить"; return 1; }
  # БД панели в PostgreSQL tar'ом не забрать — честно предупреждаем
  if [ -f "$XUI_RESULT" ] && grep -q "XUI_DB_TYPE=postgres" "$XUI_RESULT" 2>/dev/null; then
    warn "БД панели — PostgreSQL: файл x-ui.db в бэкап НЕ попадёт. Бэкап панели делайте в самой панели (Panel Settings -> Backup)."
    local -a kept=() pth
    for pth in "${paths[@]}"; do [ "$pth" = "$XUI_DB" ] || kept+=("$pth"); done
    paths=("${kept[@]}")
  fi
  # v7.2.0: MANIFEST.txt + RESTORE.txt в корень архива (второй -C)
  local stage; stage="$(mktemp -d)"
  local -a tar_args=(-C / "${paths[@]}")
  if backup_manifest_write "$stage/MANIFEST.txt" "${paths[@]}" \
     && backup_restore_doc "$stage/RESTORE.txt"; then
    tar_args+=(-C "$stage" MANIFEST.txt RESTORE.txt)
  else
    warn "MANIFEST/RESTORE не записаны — собираю архив без них"
  fi
  tar czf "$f" "${tar_args[@]}" 2>/dev/null || { err "tar не смог собрать бэкап"; rm -rf "$stage"; return 1; }
  rm -rf "$stage"
  chmod 600 "$f"
  backup_retention_apply
  # штамп последнего УСПЕШНОГО бэкапа (гейт для `xkit backup auto`);
  # { } 2>/dev/null — гасит и ошибку открытия (нет прав/каталога), не мусоря в stderr
  mkdir -p "$(dirname "$XKIT_LAST_BACKUP")" 2>/dev/null || true
  { date +%s > "$XKIT_LAST_BACKUP"; } 2>/dev/null || true
  ok "Бэкап: $f ($(du -h "$f" 2>/dev/null | cut -f1)); MANIFEST+RESTORE внутри; политика: интервал ${BACKUP_INTERVAL_H:-24} ч, хранить ${BACKUP_KEEP_DAYS:-14} дн (мин ${BACKUP_KEEP_MIN:-3} копий)"
  return 0
}

backup_auto() {
  # v7.2.0: плановый бэкап по расписанию. Cron стреляет ежедневно (03:17),
  # здесь — два гейта: включено ли и прошло ли BACKUP_INTERVAL_H часов с
  # последнего успеха. Тихий режим (вызывается из cron).
  load_xkit_env 2>/dev/null || true
  [ "${BACKUP_ENABLED:-1}" = "1" ] || return 0
  local now last interval
  now="$(date +%s)"
  last="$(cat "$XKIT_LAST_BACKUP" 2>/dev/null || true)"
  case "${last:-}" in ''|*[!0-9]*) last=0 ;; esac
  interval=$(( ${BACKUP_INTERVAL_H:-24} * 3600 ))
  [ "$interval" -ge 3600 ] || interval=3600   # защита от мусора в env
  [ $(( now - last )) -ge "$interval" ] || return 0   # не время — тихо
  backup_now
}

backup_settings_set() { # $1 enabled(1|0) $2 interval_h [keep_days] [keep_min]
  local en="$1" ih="$2" kd="${3:-${BACKUP_KEEP_DAYS:-14}}" km="${4:-${BACKUP_KEEP_MIN:-3}}"
  case "$en" in 1|0) ;; *) err "enabled должен быть 1 или 0"; return 1 ;; esac
  case "$ih" in ''|*[!0-9]*) err "интервал — целое число часов"; return 1 ;; esac
  [ "$ih" -ge 1 ] && [ "$ih" -le 8760 ] || { err "интервал: 1-8760 часов"; return 1; }
  case "$kd" in ''|*[!0-9]*) err "keep_days — целое число дней"; return 1 ;; esac
  [ "$kd" -ge 1 ] && [ "$kd" -le 3650 ] || { err "keep_days: 1-3650"; return 1; }
  case "$km" in ''|*[!0-9]*) err "keep_min — целое число копий"; return 1 ;; esac
  [ "$km" -ge 1 ] && [ "$km" -le 100 ] || { err "keep_min: 1-100"; return 1; }
  BACKUP_ENABLED="$en"; BACKUP_INTERVAL_H="$ih"; BACKUP_KEEP_DAYS="$kd"; BACKUP_KEEP_MIN="$km"
  save_xkit_env >/dev/null 2>&1 || { err "не удалось сохранить политику в $XKIT_ENV"; return 1; }
  backup_cron_install
  backup_settings_show
  return 0
}

backup_settings_show() {
  echo "Политика бэкапов: $([ "${BACKUP_ENABLED:-1}" = "1" ] && printf 'включены' || printf 'отключены'), интервал ${BACKUP_INTERVAL_H:-24} ч, хранить ${BACKUP_KEEP_DAYS:-14} дн (минимум ${BACKUP_KEEP_MIN:-3} копий)"
  if [ -r "$XKIT_LAST_BACKUP" ]; then
    local st; st="$(cat "$XKIT_LAST_BACKUP" 2>/dev/null || true)"
    case "${st:-}" in ''|*[!0-9]*) st=0 ;; esac
    echo "Последний успешный: $(date '+%Y-%m-%d %H:%M' -d "@$st" 2>/dev/null || echo 'н/д')"
  else
    echo "Последний успешный: пока не было"
  fi
  echo "Каталог: $BACKUP_DIR ($(ls -1 "$BACKUP_DIR"/xkit-*.tar.gz 2>/dev/null | wc -l) архивов)"
}

backup_setup_on_install() {
  # v7.2.0: вопрос «Использовать бэкапы?» на установке + выбор периодичности.
  # Тихие пути: файл ответов (xkit install --answers) или XKIT_YES=1 (CI).
  if [ -n "${XKIT_ANSWER_BACKUP_INTERVAL_H:-}" ]; then
    backup_settings_set "${XKIT_ANSWER_BACKUP_ENABLED:-1}" "$XKIT_ANSWER_BACKUP_INTERVAL_H" \
      "${XKIT_ANSWER_BACKUP_KEEP_DAYS:-14}" "${XKIT_ANSWER_BACKUP_KEEP_MIN:-3}" \
      >/dev/null 2>&1 || { warn "Политику бэкапов из файла ответов применить не удалось — беру дефолт (24 ч)"; }
    log "Бэкапы (из файла ответов): enabled=${BACKUP_ENABLED:-1}, интервал ${BACKUP_INTERVAL_H:-24} ч"
    return 0
  fi
  if [ "${XKIT_YES:-0}" = "1" ]; then
    log "XKIT_YES: авто-бэкапы по умолчанию (раз в ${BACKUP_INTERVAL_H:-24} ч); изменить: xkit backup settings"
    return 0
  fi
  echo ""
  if ! confirm "Использовать авто-бэкапы? [Y/n] " y; then
    BACKUP_ENABLED="0"
    warn "Авто-бэкапы отключены. Ручной: xkit backup или меню «Бэкап: сделать сейчас»"
    return 0
  fi
  echo "Периодичность бэкапов:"
  echo "  1) раз в сутки (24 ч)"
  echo "  2) раз в 2 суток (48 ч)"
  echo "  3) раз в неделю (168 ч)"
  echo "  4) свой интервал (в часах)"
  read -r -p "Выбор [1]: " a || a=""
  case "${a:-1}" in
    2) BACKUP_INTERVAL_H="48" ;;
    3) BACKUP_INTERVAL_H="168" ;;
    4) local h
       read -r -p "Часов между бэкапами (1-8760): " h || h=""
       case "$h" in ''|*[!0-9]*) h="24" ;; esac
       [ "$h" -ge 1 ] && [ "$h" -le 8760 ] || h="24"
       BACKUP_INTERVAL_H="$h" ;;
    *) BACKUP_INTERVAL_H="24" ;;
  esac
  log "Авто-бэкапы: раз в ${BACKUP_INTERVAL_H} ч; хранение ${BACKUP_KEEP_DAYS:-14} дн, минимум ${BACKUP_KEEP_MIN:-3} копий (изменить: xkit backup settings)"
  return 0
}

backup_settings_menu() {
  while true; do
    echo ""
    echo -e "${YELLOW}=== НАСТРОЙКИ БЭКАПОВ ===${NC}"
    backup_settings_show
    echo " 1) Включить / отключить автоматические резервные копии"
    echo " 2) Интервал: раз в сутки (24 ч)"
    echo " 3) Интервал: раз в 2 суток (48 ч)"
    echo " 4) Интервал: раз в неделю (168 ч)"
    echo " 5) Свой интервал (в часах)"
    echo " 6) Хранение: дней и минимум копий"
    echo " 7) Создать резервную копию сейчас"
    echo " 0) Назад"
    local c
    read -r -p "Выбор: " c || return 0
    case "$c" in
      1) if [ "${BACKUP_ENABLED:-1}" = "1" ]; then
           backup_settings_set 0 "${BACKUP_INTERVAL_H:-24}" && warn "Авто-бэкапы отключены"
         else
           backup_settings_set 1 "${BACKUP_INTERVAL_H:-24}" && ok "Авто-бэкапы включены"
         fi; pause_enter ;;
      2) backup_settings_set 1 24; pause_enter ;;
      3) backup_settings_set 1 48; pause_enter ;;
      4) backup_settings_set 1 168; pause_enter ;;
      5) local h; read -r -p "Часов между бэкапами (1-8760): " h || h=""
         backup_settings_set 1 "$h"; pause_enter ;;
      6) local kd km
         read -r -p "Хранить дней [${BACKUP_KEEP_DAYS:-14}]: " kd || kd=""
         read -r -p "Минимум копий [${BACKUP_KEEP_MIN:-3}]: " km || km=""
         backup_settings_set "${BACKUP_ENABLED:-1}" "${BACKUP_INTERVAL_H:-24}" "${kd:-${BACKUP_KEEP_DAYS:-14}}" "${km:-${BACKUP_KEEP_MIN:-3}}"; pause_enter ;;
      7) backup_now; pause_enter ;;
      0) return 0 ;;
      *) warn "Нет такого пункта" ;;
    esac
  done
}

backup_cron_install() {
  # v7.2.0: строка бэкапа — `backup auto` с гейтом интервала; при выключенных
  # авто-бэкапах строка не пишется (расписание честно отсутствует).
  if [ "${BACKUP_ENABLED:-1}" = "1" ]; then
    cat > "$XKIT_CRON_MAIN" <<EOF
# XKIT: авто-бэкап (гейт интервала внутри auto) + перегенерация подписок каждый час
17 3 * * * root ${XKIT_BIN} backup auto >/dev/null 2>&1
13 * * * * root ${XKIT_BIN} sub -q >/dev/null 2>&1
EOF
    chmod 644 "$XKIT_CRON_MAIN"
    ok "Cron: авто-бэкап ежедневно 03:17 (реальный интервал ${BACKUP_INTERVAL_H:-24} ч внутри auto), подписки ежечасно"
  else
    cat > "$XKIT_CRON_MAIN" <<EOF
# XKIT: авто-бэкапы отключены в политике (xkit backup settings); подписки каждый час
13 * * * * root ${XKIT_BIN} sub -q >/dev/null 2>&1
EOF
    chmod 644 "$XKIT_CRON_MAIN"
    ok "Cron: подписки ежечасно (авто-бэкапы отключены в политике)"
  fi
}

backup_stage() { # $1 архив; проверенная распаковка в BACKUP_STAGE
  local file="$1" a
  case "$(readlink -f -- "$file" 2>/dev/null || echo "$file")" in
    "$BACKUP_DIR"/*) ;;
    *)
      if [ "${XKIT_ALLOW_UNTRUSTED_BACKUP:-0}" != "1" ]; then
        warn "Файл вне ${BACKUP_DIR}: $(basename -- "$file")"
        read -r -p "Чужой бэкап может выполнить команды от root. Точно восстановить? Введите YES (регистр не важен): " a || { echo; return 1; }
        [ "${a^^}" = "YES" ] || { log "Отменено"; return 1; }
      fi ;;
  esac
  if tar -tzf "$file" 2>/dev/null | grep -qE '(^/|(^|/)\.\.(/|$))'; then
    err "Архив содержит небезопасные пути (../ или абсолютные) — восстановление отменено"; return 1
  fi
  BACKUP_STAGE="$(mktemp -d)" || return 1; chmod 700 "$BACKUP_STAGE"
  tar xzf "$file" -C "$BACKUP_STAGE" || { err "Архив битый"; rm -rf "$BACKUP_STAGE"; return 1; }
  local badlink
  badlink="$(find "$BACKUP_STAGE" -type l 2>/dev/null | while read -r l; do
    lt="$(readlink -f "$l" 2>/dev/null || true)"
    case "$lt" in "$BACKUP_STAGE"|"$BACKUP_STAGE"/*) ;; *) echo "$l"; break ;; esac
  done)"
  if [ -n "$badlink" ]; then
    err "Архив содержит symlink наружу (${badlink#"$BACKUP_STAGE"/}) — восстановление отменено (V-06)"
    rm -rf "$BACKUP_STAGE"; return 1
  fi
  if [ -f "$BACKUP_STAGE$XKIT_ENV" ] && grep -qE '`|\$\(|\$\{' "$BACKUP_STAGE$XKIT_ENV" 2>/dev/null; then
    err "xkit.env в архиве содержит командную подстановку — восстановление отменено (V-06)"
    rm -rf "$BACKUP_STAGE"; return 1
  fi
}

backup_env_value() { # $1 staged root, $2 key; env из архива не исполняется
  local v; v="$(sed -n "s/^$2=//p" "$1$XKIT_ENV" 2>/dev/null | head -n1)"
  v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"; printf '%s' "$v"
}

install_backup_offer() {
  INSTALL_RESTORE_CERT=0; INSTALL_RESTORE_PANEL=0; INSTALL_RESTORE_SUBS=0; INSTALL_RESTORE_NODES=0
  INSTALL_BACKUP_STAGE=""
  [ -t 0 ] && [ "${XKIT_YES:-0}" != 1 ] || return 0
  local file choice
  file="$(ls -1t "$BACKUP_DIR"/xkit-*.tar.gz /root/xkit-restore/xkit-*.tar.gz 2>/dev/null | head -n1)"
  [ -n "$file" ] || return 0
  echo ""; ok "Найден бэкап XKIT: $file"
  confirm "Восстановить данные на этом сервере? [y/N] " n || return 0
  echo "  1) Только сертификаты"
  echo "  2) Пользователи и панель"
  echo "  3) Подписки (вместе с пользователями и панелью)"
  echo "  4) Дополнительные серверы и сроки аренды"
  echo "  5) Полный перенос главного сервера (всё перечисленное)"
  echo "  0) Не восстанавливать"
  read -r -p "Выбор [5]: " choice || { echo; return 1; }
  case "${choice:-5}" in
    1) INSTALL_RESTORE_CERT=1 ;;
    2) INSTALL_RESTORE_PANEL=1 ;;
    3) INSTALL_RESTORE_PANEL=1; INSTALL_RESTORE_SUBS=1 ;;
    4) INSTALL_RESTORE_NODES=1 ;;
    5) INSTALL_RESTORE_CERT=1; INSTALL_RESTORE_PANEL=1; INSTALL_RESTORE_SUBS=1; INSTALL_RESTORE_NODES=1 ;;
    0) return 0 ;;
    *) warn "Нет такого пункта"; return 1 ;;
  esac
  backup_stage "$file" || return 1
  INSTALL_BACKUP_STAGE="$BACKUP_STAGE"
  if [ "$INSTALL_RESTORE_PANEL" = 1 ] && [ ! -f "$BACKUP_STAGE$XUI_DB" ]; then
    err "В архиве нет SQLite БД панели; PostgreSQL восстанавливается средствами СУБД"
    rm -rf -- "$INSTALL_BACKUP_STAGE"; INSTALL_BACKUP_STAGE=""; return 1
  fi
}

install_restore_certs() {
  [ "$INSTALL_RESTORE_CERT" = 1 ] || return 0
  local d found=0
  for d in /etc/nginx/ssl /etc/letsencrypt; do
    if [ -d "$INSTALL_BACKUP_STAGE$d" ]; then
      mkdir -p "$d"; cp -a "$INSTALL_BACKUP_STAGE$d/." "$d/" || return 1; found=1
    fi
  done
  [ "$found" = 1 ] || { err "В архиве нет сертификатов"; return 1; }
  ok "Сертификаты восстановлены; установщик проверит домен, срок и ключ перед использованием"
}

install_restore_panel() {
  [ "$INSTALL_RESTORE_PANEL" = 1 ] || return 0
  systemctl stop x-ui 2>/dev/null || true
  [ ! -f "$XUI_DB" ] || cp -a "$XUI_DB" "${XUI_DB}.before-restore" || return 1
  mkdir -p "$(dirname "$XUI_DB")" "$(dirname "$XUI_RESULT")"
  if ! cp "$INSTALL_BACKUP_STAGE$XUI_DB" "$XUI_DB"; then
    [ ! -f "${XUI_DB}.before-restore" ] || cp -a "${XUI_DB}.before-restore" "$XUI_DB"
    err "БД панели не восстановлена; прежняя БД возвращена"; return 1
  fi
  if [ -f "$INSTALL_BACKUP_STAGE$XUI_RESULT" ]; then
    cp "$INSTALL_BACKUP_STAGE$XUI_RESULT" "$XUI_RESULT" || { err "Реквизиты панели не восстановлены"; return 1; }
  fi
  chmod 600 "$XUI_DB" "$XUI_RESULT" 2>/dev/null || true
  systemctl start x-ui || return 1
  ok "Пользователи, инбаунды и БД панели восстановлены; свежая БД сохранена как x-ui.db.before-restore"
}

install_restore_state() {
  [ "$INSTALL_RESTORE_SUBS" = 1 ] || [ "$INSTALL_RESTORE_NODES" = 1 ] || return 0
  local v f key
  if [ "$INSTALL_RESTORE_SUBS" = 1 ]; then
    v="$(backup_env_value "$INSTALL_BACKUP_STAGE" XKIT_SUB_TOKEN)"
    [[ "$v" =~ ^[A-Za-z0-9_-]+$ ]] || { err "SUB_TOKEN в архиве отсутствует или невалиден"; return 1; }
    XKIT_SUB_TOKEN="$v"
  fi
  if [ "$INSTALL_RESTORE_NODES" = 1 ]; then
    jq -e 'type=="array"' "$INSTALL_BACKUP_STAGE$XKIT_NODES" >/dev/null 2>&1 \
      || { err "В архиве нет корректного реестра нод"; return 1; }
    for f in "$XKIT_NODES" "$XKIT_EXPIRY" "$XKIT_DIR/known_hosts"; do
      if [ -f "$INSTALL_BACKUP_STAGE$f" ]; then
        mkdir -p "$(dirname "$f")" || return 1
        cp "$INSTALL_BACKUP_STAGE$f" "$f" && chmod 600 "$f" || return 1
      fi
    done
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      if [ "$(dirname "$key")" != "$XKIT_DIR" ]; then
        warn "Ключ вне $XKIT_DIR не восстанавливается: $key"; continue
      fi
      if [ -f "$INSTALL_BACKUP_STAGE$key" ]; then
        cp "$INSTALL_BACKUP_STAGE$key" "$key" && chmod 600 "$key" || return 1
      fi
    done < <(jq -r '.[].key_path // empty' "$XKIT_NODES" 2>/dev/null)
    if [ "$INSTALL_RESTORE_PANEL" != 1 ]; then
      jq -c 'map(del(.panel_node_id))' "$XKIT_NODES" > "$XKIT_NODES.tmp" \
        && mv "$XKIT_NODES.tmp" "$XKIT_NODES" || { rm -f "$XKIT_NODES.tmp"; return 1; }
    fi
    chmod 600 "$XKIT_NODES" 2>/dev/null || true
    ok "Ноды, SSH-ключи и сроки аренды восстановлены без переустановки нод"
  fi
}

backup_restore() {
  local file="${1:-}"
  [ -z "$file" ] && file="$(ls -1t "$BACKUP_DIR"/xkit-*.tar.gz 2>/dev/null | head -n1)"
  [ -n "$file" ] && [ -f "$file" ] || die "Бэкапы не найдены в $BACKUP_DIR"
  # V-06: доверие к архиву и безопасная распаковка проверяются в backup_stage.
  log "Восстанавливаю из: $file"
  backup_stage "$file" || return 1
  local t="$BACKUP_STAGE"

  systemctl stop x-ui 2>/dev/null || true
  # FIX (v7.1.3, чистовая комната на bash 5.2.37): restore не должен МОЛЧА
  # пропускать членов архива из-за отсутствующих каталогов назначения —
  # живой сценарий «xkit uninstall --full -> xkit restore» (без промежуточной
  # установки): /var/lib/xkit, /etc/xkit, /etc/x-ui не существуют, cp -a падает
  # в никуда, 2>/dev/null гасит ошибку, члены архива теряются без единого
  # предупреждения. Каталоги создаются под каждый восстанавливаемый член;
  # провал копирования теперь честный err, а не тишина (симметрия с
  # backup_cron_install/save_xkit_env: провал записи = err + return 1);
  # хоть один член не восстановился — restore возвращает 1 (честный код для cron/CLI)
  local rc_all=0 certdir
  for certdir in /etc/nginx/ssl /etc/letsencrypt; do
    if [ -d "$t$certdir" ]; then
      mkdir -p "$certdir"
      cp -a "$t$certdir/." "$certdir/" || { err "Сертификаты $certdir НЕ восстановлены"; rc_all=1; }
    fi
  done
  if [ -f "$t${XUI_DB}" ]; then
    mkdir -p "$(dirname "$XUI_DB")" 2>/dev/null || true
    backup_file "$XUI_DB" >/dev/null
    if cp "$t${XUI_DB}" "$XUI_DB"; then ok "БД панели восстановлена"; else err "БД панели НЕ восстановлена (cp провалился)"; rc_all=1; fi
  fi
  if [ -f "$t$XKIT_CONF" ]; then
    mkdir -p "$(dirname "$XKIT_CONF")" 2>/dev/null || true
    backup_file "$XKIT_CONF" >/dev/null
    if cp "$t$XKIT_CONF" "$XKIT_CONF"; then
      chmod 644 "$XKIT_CONF"
      mkdir -p "$(dirname "$XKIT_CONF_LINK")" 2>/dev/null || true   # v7.1.3: ln -sf тоже не должен падать в никуда
      ln -sf "$XKIT_CONF" "$XKIT_CONF_LINK"
      ok "Конфиг nginx восстановлен"
    else
      err "Конфиг nginx НЕ восстановлен (cp провалился)"; rc_all=1
    fi
  fi
  if [ -d "$t$XKIT_DIR" ]; then
    mkdir -p "$XKIT_DIR" 2>/dev/null || true
    backup_file "$XKIT_ENV" >/dev/null
    if cp -a "$t$XKIT_DIR/." "$XKIT_DIR/" 2>/dev/null; then ok "Состояние xkit восстановлено"; else err "Состояние xkit НЕ восстановлено (cp провалился)"; rc_all=1; fi
  fi
  if [ -d "$t$SUBS_DIR" ]; then
    mkdir -p "$SUBS_DIR" 2>/dev/null || true
    if cp -a "$t$SUBS_DIR/." "$SUBS_DIR/" 2>/dev/null; then ok "Файлы подписок восстановлены"; else err "Файлы подписок НЕ восстановлены (cp провалился)"; rc_all=1; fi
  fi
  # v5.2: конфиги отдельных протоколов; бинарники в tar не хранятся.
  local rp
  for rp in /etc/amnezia/amneziawg/awg0.conf /etc/systemd/system/xkit-hysteria2.service /etc/sysctl.d/99-xkit-awg.conf; do
    if [ -f "$t$rp" ]; then mkdir -p "$(dirname "$rp")"; cp -f "$t$rp" "$rp"; fi
  done
  rm -rf "$t"
  systemctl daemon-reload >/dev/null 2>&1 || true
  [ -f /etc/systemd/system/xkit-hysteria2.service ] && systemctl enable --now xkit-hysteria2 >/dev/null 2>&1 || true
  [ -f /etc/amnezia/amneziawg/awg0.conf ] && systemctl enable --now awg-quick@awg0 >/dev/null 2>&1 || true

  if command -v nginx >/dev/null 2>&1; then
    if nginx -t >/dev/null 2>&1; then
      systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
      ok "Nginx перезагружен"
    else
      err "nginx -t не прошёл после восстановления — проверьте конфиг"
    fi
  fi
  # v7.2.0: серты вернулись из бэкапа — напоминание, чтобы не жечь лимиты LE
  if [ -d /etc/nginx/ssl ] || [ -d /etc/letsencrypt ]; then
    log "Серты восстановлены из бэкапа: если адрес сервера НЕ менялся — перевыпуск НЕ нужен"
    log "(проверка: xkit health; при смене адреса — xkit → пункт «Сертификат: перевыпустить»)"
  fi
  systemctl start x-ui 2>/dev/null || true
  sleep 2
  load_xkit_env || true
  if read_panel_settings >/dev/null 2>&1 && detect_panel_scheme "$PANEL_PORT" >/dev/null; then
    COOKIE_JAR="$(mktemp /tmp/xkit-ck.XXXXXX)"; chmod 600 "$COOKIE_JAR"
    if kit_login; then ok "Панель снова отвечает на логин"
    else warn "Панель запущена, но логин не прошёл — проверьте креды"; fi
  fi
  return $rc_all   # v7.1.3: честный итог — 1, если хоть один член архива потерян
}

#=========================== СТАТУС: ЧТО ВИДНО СНАРУЖИ ========================
show_status() {
  load_xkit_env || die "Нет состояния — сначала установка"
  echo ""
  echo -e "${GREEN}==== XKIT v${XKIT_VERSION}: ${XKIT_HOST} ====${NC}"
  echo "  Панель:  https://${XKIT_HOST}$(read_panel_settings >/dev/null 2>&1 && echo "${PANEL_WBP}")"
  echo "  Подписки: https://${XKIT_HOST}$(sub_path)<subId>"
  if [ "${XKIT_DASH:-0}" = "1" ] && [ -n "${XKIT_DASH_TOKEN:-}" ]; then
    echo "  Дашборд: https://${XKIT_HOST}$(dash_path) (данные: cron каждые 5 мин)"
  fi
  # v4.5: явный режим — «мастер» это состояние (nodes.json не пуст), а не отдельная установка
  local ncnt; ncnt="$(nodes_load 2>/dev/null | jq 'length' 2>/dev/null || echo 0)"
  if [ "$ncnt" -gt 0 ]; then
    echo "  Режим:   мастер (${ncnt} нод; балансировка ${XKIT_BAL_STRATEGY:-leastLoad})"
  else
    echo "  Режим:   одиночный сервер (ноды не подключены)"
  fi
  echo ""
  echo "  Сервисы:  nginx=$(systemctl is-active nginx 2>/dev/null)  x-ui=$(systemctl is-active x-ui 2>/dev/null)  ufw=$(ufw status 2>/dev/null | sed -n 's/Status: //p')"
  echo ""
  echo "  Слушатели, видимые снаружи (0.0.0.0/::):"
  local found=0
  while IFS=$'\t' read -r netid addrport proc; do
    local addr port
    addr="${addrport%:*}"; port="${addrport##*:}"
    case "$addr" in "0.0.0.0"|"*"|"::"|"[::]") ;; *) continue ;; esac
    echo "    ${netid}/${port}  ${proc:-?}"
    found=$((found+1))
  done < <(ss -tulpnH 2>/dev/null | awk '{print $1"\t"$5"\t"$7}')
  [ "$found" -eq 0 ] && echo "    (нет)"
  echo ""
  echo "  Локальные (127.0.0.1 — снаружи НЕ видны):"
  ss -tlnpH 2>/dev/null | awk '$4 ~ /^127\.0\.0\.1/ {print "    "$4"  "$7}' | head -n 20
  echo ""
  routes_load
  echo "  Маршруты за nginx: ${#ROUTES[@]}"
  local row
  for row in "${ROUTES[@]}"; do
    IFS=$'\t' read -r _ r_mode r_net r_path r_target _ <<<"$row"
    echo "    $r_path -> $r_target [$r_mode/$r_net]"
  done
  return 0
}

#=========================== УСТАНОВКА ОДНИМ ШАГОМ ============================
setup_ufw() {
  command -v ufw >/dev/null 2>&1 || { warn "ufw не найден — пропускаю настройку фаервола"; return 0; }
  if ufw status 2>/dev/null | head -n1 | grep -q "inactive"; then
    local ssh_port a
    # S-03 (аудит №2): порт SSH из sshd -T/sshd_config, НЕ из ss-парсинга;
    # не определили — UFW НЕ включаем (fallback на 22 = lockout при нестандартном порте)
    ssh_port="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')"
    [ -n "$ssh_port" ] || ssh_port="$(awk 'tolower($1)=="port"{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)"
    [ -n "$ssh_port" ] || ssh_port="$(ss -tlnp 2>/dev/null | awk '/"sshd"/ {n=split($4,a,":"); print a[n]; exit}')"
    if [ -n "$ssh_port" ] && ! is_port "$ssh_port"; then ssh_port=""; fi
    if [ -z "$ssh_port" ]; then
      if [ -t 0 ]; then
        read -r -p "Не смог определить порт SSH. Укажите его вручную (Enter — пропустить ufw): " ssh_port || ssh_port=""
      fi
      is_port "${ssh_port:-}" 2>/dev/null || ssh_port=""
    fi
    if [ -z "$ssh_port" ]; then
      warn "Порт SSH не определён — UFW НЕ включаю (риск заблокировать себя). Вручную: ufw allow <порт>/tcp && ufw enable"
      return 0
    fi
    if ! confirm "Включить ufw (наружу останутся только SSH ${ssh_port}, 80, 443)? [Y/n] " y; then
      warn "UFW не включён — панель/инбаунды на 127.0.0.1 всё равно не видны, но проверьте открытые порты сами"
      return 0
    fi
    ufw allow "${ssh_port}/tcp" >/dev/null 2>&1 || { err "UFW: не удалось разрешить SSH — включение отменено"; return 1; }
    ufw allow 80/tcp  >/dev/null 2>&1 || { err "UFW: не удалось разрешить 80/tcp — включение отменено"; return 1; }
    ufw allow 443/tcp >/dev/null 2>&1 || { err "UFW: не удалось разрешить 443/tcp — включение отменено"; return 1; }
    if ufw --force enable >/dev/null 2>&1; then
      ok "UFW включён: наружу только SSH ${ssh_port}, 80, 443"
      XKIT_UFW=1
    else
      err "UFW не включился — проверьте его состояние вручную"
      XKIT_UFW=0
      return 1
    fi
  else
    ok "UFW уже активен"
    XKIT_UFW=1
  fi
  return 0
}

#=========================== PREFLIGHT (v4.7) ==================================
# Проверки ДО каких-либо изменений: уже установлен / порты / диск / RAM / сеть.
# Раньше повторный `xkit install` молча ставил поверх: env не загружался ->
# НОВЫЙ SUB_TOKEN (все ссылки подписок у клиентов отваливались) + save_xkit_env
# затирал TG/dash-токены нулями. Теперь — явный выбор.
preflight_installed_menu() { # 0 = продолжать установку поверх, 1 = стоп
  local a
  echo ""
  warn "xkit уже установлен: ${XKIT_ENV}"
  echo "  1) Обновить XKIT — настройки, серверы и подписки не меняются"
  echo "  2) Чистая переустановка: бэкап -> полное удаление -> установка с нуля"
  echo "  3) Починить поверх: пакеты/панель/конфиг заново, состояние сохраняется"
  echo "  0) Выход"
  read -r -p "Выбор [0]: " a || { echo; return 1; }   # EOF (cron/pipe) — безопасный выход
  case "${a:-0}" in
    1) xkit_self_update; return 1 ;;
    2) xkit_reinstall; return 1 ;;
    3) warn "Починка поверх: пакеты/панель/конфиг переустановятся, текущее состояние"
       warn "(адрес, путь подписок, Telegram, дашборд) СОХРАНИТСЯ и подхватится."
       confirm "Продолжить? [y/N]: " n || { log "Отменено"; return 1; }
       return 0 ;;
    *) log "Выход без изменений"; return 1 ;;
  esac
}

preflight() { # 0 = можно ставить, 1 = стоп
  # 1) уже установленный xkit: спросить, а не молча перезаписать
  if [ -f "$XKIT_ENV" ]; then
    if [ "${XKIT_FORCE:-0}" = "1" ]; then
      warn "XKIT_FORCE=1: ставлю поверх существующей установки (SUB_TOKEN/TG/dash слетят)"
    else
      preflight_installed_menu || return 1
    fi
  fi

  # 2) порты 80/443 (важно ДО certbot): nginx-оккупант будет перенастроен сам,
  #    чужой процесс (apache/другой vpn) — предупреждение с именем процесса
  local warns=0 p line
  if command -v ss >/dev/null 2>&1; then
    for p in 80 443; do
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        if printf '%s' "$line" | grep -q nginx; then
          log "Порт ${p} уже слушает nginx — xkit перенастроит его сайт"
        else
          warn "Порт ${p} занят: ${line}"
          warns=$((warns+1))
        fi
      done < <(ss -ltnpH "sport = :${p}" 2>/dev/null)
    done
  fi

  # 3) диск: certbot + БД + бэкапы не живут на <500 MB
  local avail_mb
  avail_mb="$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')"
  if [ -n "$avail_mb" ] && [ "$avail_mb" -lt 500 ] 2>/dev/null; then
    err "Свободно ${avail_mb} MB на / — нужно >=500 MB (сертификаты, БД панели, бэкапы)"
    return 1
  fi

  # 4) RAM: x-ui + nginx + certbot на 512 MB впритык
  local mem_mb
  mem_mb="$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)"
  if [ -n "$mem_mb" ] && [ "$mem_mb" -lt 400 ] 2>/dev/null; then
    warn "RAM ${mem_mb} MB — x-ui/nginx/certbot могут упасть по OOM (рекомендую >=512 MB)"
    warns=$((warns+1))
  fi

  # 5) сеть: без этих хостов установка не пройдёт (3X-UI качается с github)
  local u
  for u in https://raw.githubusercontent.com https://api.ipify.org; do
    if command -v curl >/dev/null 2>&1; then
      curl -fsS --max-time 3 -o /dev/null "$u" 2>/dev/null || { warn "Нет доступа к ${u} — часть установки может не пройти"; warns=$((warns+1)); }
    fi
  done

  if [ "$warns" -gt 0 ]; then
    confirm "Продолжить несмотря на предупреждения? [y/N]: " n || { log "Отменено"; return 1; }
  fi
  return 0
}

#=========================== УДАЛЕНИЕ / ПЕРЕУСТАНОВКА =========================
# xkit_uninstall [--full|--purge]: бэкап ОБЯЗАТЕЛЕН (провал = отмена), затем
# чистая зачистка следов кита. --full дополнительно удаляет 3X-UI и
# /etc/nginx/ssl. --purge = --full БЕЗ СОХРАНЕНИЙ (v7.2.4, вопрос оператора
# «вычистить сервер от всех следов»): бэкап НЕ создаётся, дополнительно сносятся
# бэкапы, /etc/letsencrypt (ВСЕ серты), venv certbot + его units/drop-in,
# /var/log/xkit-*.log и пакеты nginx/certbot — ЕСЛИ на nginx нет других сайтов.
# Подтверждение --purge — ввести PURGE (намеренное трение против опечатки).
# Без --purge НИКОГДА не удаляются: бэкапы ($BACKUP_DIR), /etc/letsencrypt, сам
# nginx и чужие сайты, UFW-правила 22/80/443. Ноды (xray на них) не трогаются.
# KEEP_BIN=1 — внутренний флаг reinstall: не удалять $XKIT_BIN (running-скрипт).
xkit_uninstall() {
  local full=0 purge=0 a
  for a in "$@"; do
    case "$a" in
      --full)  full=1 ;;
      --purge) full=1; purge=1 ;;
      *) err "Неизвестный аргумент uninstall: $a (допустимо: --full, --purge)"; return 1 ;;
    esac
  done
  require_root
  load_xkit_env 2>/dev/null || true

  echo ""
  echo -e "${YELLOW}============================================================${NC}"
  warn "УДАЛЕНИЕ XKIT С ЭТОГО СЕРВЕРА"
  echo -e "${YELLOW}============================================================${NC}"
  echo "Удаляется:   cron-задачи xkit (3 шт), nginx-сайт xkit.conf (+reload nginx),"
  echo "             /etc/xkit (состояние, SSH-ключи нод, expiry, алерты),"
  echo "             /var/lib/xkit (подписки, дашборд), htpasswd дашборда,"
  echo "             deny-правило UFW для порта панели, /usr/local/bin/xkit"
  [ "$full" = "1" ] && echo "             + --full: 3X-UI (сервис, /etc/x-ui, /usr/local/x-ui, CLI /usr/bin/x-ui, логи /var/log/x-ui), /etc/nginx/ssl"
  if [ "$purge" = "1" ]; then
    echo "             + --purge: БЕЗ СОХРАНЕНИЙ — бэкапы $BACKUP_DIR, /etc/letsencrypt (ВСЕ серты),"
    echo "                        venv certbot (/opt/certbot-venv) + его units/drop-in, /var/log/xkit-*.log,"
    echo "                        пакеты nginx и certbot — если на nginx нет других сайтов"
    echo "Сохраняется: НИЧЕГО. Восстановление невозможно — бэкап не создаётся по определению --purge"
  else
    echo "Сохраняется: бэкапы $BACKUP_DIR (включая свежий; хранение — политика бэкапов), /etc/letsencrypt,"
    echo "             nginx и другие сайты, UFW-правила SSH/80/443"
  fi
  echo "Ноды продолжат работать автономно — xray на них не трогаем."

  if [ "$purge" = "1" ]; then
    warn "Режим --purge: бэкап НЕ создаётся — после удаления восстановить нечего"
  else
    log "Сначала бэкап — без него удаление не состоится..."
    backup_now || { err "Бэкап не удался — удаление отменено (безопасность)"; return 1; }
  fi

  if [ "${XKIT_YES:-0}" != "1" ]; then
    if [ "$purge" = "1" ]; then
      read -r -p "Вычистить ВСЁ без сохранения? Введите PURGE (регистр не важен): " a || { echo; log "Отменено"; return 2; }
      [ "${a^^}" = "PURGE" ] || { log "Отменено"; return 2; } # rc=2 — отмена пользователем, не сбой
    else
      read -r -p "Удалить xkit? Введите YES (регистр не важен): " a || { echo; log "Отменено"; return 2; }
      [ "${a^^}" = "YES" ] || { log "Отменено"; return 2; } # rc=2 — отмена пользователем, не сбой
    fi
  fi

  xkit_log_begin uninstall
  xkit_install_traps_on

  rm -f "$XKIT_CRON_MAIN" "$XKIT_CRON_DASH" "$XKIT_CRON_NOTIFY" 2>/dev/null
  ok "Cron-задачи xkit удалены"

  if [ -e "$XKIT_CONF" ] || [ -L "$XKIT_CONF_LINK" ]; then
    rm -f "$XKIT_CONF" "$XKIT_CONF_LINK" "$XKIT_DASH_HTPASSWD" 2>/dev/null
    if command -v nginx >/dev/null 2>&1; then
      if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true
        ok "nginx-сайт xkit.conf удалён, nginx перезагружен"
      else
        err "После удаления xkit.conf nginx -t не проходит — проверьте /etc/nginx вручную"
      fi
    else
      ok "nginx-сайт xkit.conf удалён"
    fi
  else
    log "nginx-сайт xkit.conf не найден — пропускаю"
  fi

  # deny порта панели — xkit-специфичное правило; allow 22/80/443 не трогаем:
  # удалить allow 22 = потерять SSH, allow 80/443 безвредны и стандартны
  if [ -n "${PANEL_PORT:-}" ] && command -v ufw >/dev/null 2>&1; then
    ufw delete deny "${PANEL_PORT}/tcp" >/dev/null 2>&1 || true
  fi

  # v5.2: отдельные службы протоколов. Чужой awg0 без метки XKIT не трогаем.
  systemctl disable --now xkit-hysteria2 >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/xkit-hysteria2.service /usr/local/bin/xkit-hysteria2
  if [ -f /etc/amnezia/amneziawg/awg0.conf ] && grep -q '^# Managed by XKIT' /etc/amnezia/amneziawg/awg0.conf 2>/dev/null; then
    systemctl disable --now awg-quick@awg0 >/dev/null 2>&1 || true
    rm -f /etc/amnezia/amneziawg/awg0.conf /etc/sysctl.d/99-xkit-awg.conf
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true

  # Удаляем только правила с меткой XKIT и только для сохранённых портов.
  proto_state_load 2>/dev/null || true
  local fw_port
  for fw_port in "${HY2_PORT:-}" "${AWG_PORT:-}" "${PANEL_HY2_PORT:-}" "${PANEL_AWG_PORT:-}" "${XHTTP_PORT:-}"; do
    is_port "${fw_port:-}" 2>/dev/null || continue
    xkit_fw_remove hysteria2 "$fw_port" udp >/dev/null 2>&1 || true
    xkit_fw_remove awg "$fw_port" udp >/dev/null 2>&1 || true
    xkit_fw_remove xhttp "$fw_port" tcp >/dev/null 2>&1 || true
  done
  xkit_awg_route_remove "${AWG_DEV:-}" >/dev/null 2>&1 || true

  # файлы состояния: /etc/xkit, подписки, дашборд и стандартная база /var/lib/xkit
  # (SUBS_DIR/XKIT_DASH_DIR — переменные, удаляем явно; /var/lib/xkit — база по
  # умолчанию, сносит остатки старых версий, если пути переопределены)
  rm -rf "$XKIT_DIR" "$SUBS_DIR" "$XKIT_DASH_DIR" /var/lib/xkit 2>/dev/null
  rm -f "$XKIT_INFO_FILE" 2>/dev/null
  ok "Файлы xkit удалены ($XKIT_DIR, $SUBS_DIR, $XKIT_DASH_DIR)"

  if [ "$full" = "1" ]; then
    systemctl disable --now x-ui >/dev/null 2>&1 || true
    # v7.2.5 (живой баг «переустановка оставляет хвосты 3X-UI»): 3x-ui v3.x
    # ставит CLI-обёртку в /usr/bin/x-ui (install.sh: mv … /usr/bin/x-ui), а не
    # в /usr/local/bin, и пишет логи в /var/log/x-ui (mkdir -p /var/log/x-ui).
    # Пропуск /usr/bin/x-ui ломал reinstall: install_3xui_auto находил обёртку
    # через `command -v x-ui`, решал «панель уже стоит» и НЕ ставил её заново —
    # сервер оставался без x-ui.service и без install-result.env.
    rm -f /etc/systemd/system/x-ui.service /usr/local/bin/x-ui /usr/bin/x-ui 2>/dev/null
    rm -rf /etc/systemd/system/x-ui.service.d /etc/x-ui /usr/local/x-ui /etc/nginx/ssl /var/log/x-ui 2>/dev/null
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed x-ui >/dev/null 2>&1 || true   # не оставляем failed-огрызок в systemctl
    ok "3X-UI и /etc/nginx/ssl удалены (--full: сервис, /etc/x-ui, /usr/local/x-ui, CLI /usr/bin/x-ui, логи /var/log/x-ui)"
  fi

  # v7.2.4 (--purge): полная зачистка БЕЗ СОХРАНЕНИЙ. Каждый чужой артефакт
  # защищён условием: симлинк certbot и drop-in сносим только если они наши
  # (ссылаются на наш venv), пакеты nginx/certbot — только если на nginx не
  # осталось других сайтов (sites-enabled пуст кроме нашего xkit.conf).
  if [ "$purge" = "1" ]; then
    local venv="${XKIT_CERTBOT_VENV:-/opt/certbot-venv}" sd="${XKIT_SYSTEMD_DIR:-/etc/systemd/system}"
    local cbin="${XKIT_CERTBOT_BIN:-/usr/local/bin/certbot}" f others=0
    rm -rf "$BACKUP_DIR" 2>/dev/null
    # активный лог этого uninstall не трогаем — он ещё пишется
    if [ -n "${XKIT_LOG:-}" ]; then
      find /var/log -maxdepth 1 -name 'xkit-*.log' ! -path "$XKIT_LOG" -delete 2>/dev/null || true
    else
      find /var/log -maxdepth 1 -name 'xkit-*.log' -delete 2>/dev/null || true
    fi
    rm -rf "${XKIT_LE_ROOT:-/etc/letsencrypt}" 2>/dev/null   # ВСЕ серты — включая не-xkit; об этом сказано в баннере
    rm -rf "$venv" 2>/dev/null
    if [ -L "$cbin" ] && [ "$(readlink -f "$cbin" 2>/dev/null)" = "$venv/bin/certbot" ]; then
      rm -f "$cbin"                            # наш симлинк на venv; чужой certbot не трогаем
    fi
    rm -f "$sd/xkit-certbot.service" "$sd/xkit-certbot.timer" 2>/dev/null
    if [ -f "$sd/certbot.service.d/override.conf" ] \
       && grep -q "$venv" "$sd/certbot.service.d/override.conf" 2>/dev/null; then
      rm -rf "$sd/certbot.service.d"           # наш drop-in продления; чужой не трогаем
    fi
    for f in "${XKIT_NGINX_SITES_ENABLED:-/etc/nginx/sites-enabled}"/* \
             "${XKIT_NGINX_CONFD:-/etc/nginx/conf.d}"/*.conf; do
      [ -e "$f" ] || continue
      [ "$(readlink -f "$f" 2>/dev/null)" = "$XKIT_CONF" ] && continue
      others=1; break
    done
    if [ "$others" = "0" ] && command -v apt-get >/dev/null 2>&1; then
      log "Других сайтов на nginx нет — сношу пакеты nginx и certbot..."
      env DEBIAN_FRONTEND=noninteractive apt-get -y -qq purge 'nginx*' certbot 'python3-certbot*' \
        || warn "apt-get purge вернул ошибку — дочистите вручную: apt purge 'nginx*' certbot"
      env DEBIAN_FRONTEND=noninteractive apt-get -y -qq autoremove >/dev/null 2>&1 || true
    else
      [ "$others" = "1" ] && log "На nginx остались другие сайты — пакеты nginx/certbot не трогаю"
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    ok "Полная зачистка: бэкапы, /etc/letsencrypt, venv certbot, логи, пакеты nginx/certbot (чужое не тронуто)"
  fi

  if [ "${KEEP_BIN:-0}" != "1" ]; then
    [ -f "$XKIT_BIN" ] && rm -f "$XKIT_BIN" && ok "Команда xkit удалена"
    [ -d "$XKIT_MENU_DIR" ] && rm -rf "$XKIT_MENU_DIR" && ok "Модуль меню удалён ($XKIT_MENU_DIR)"
  fi

  xkit_install_traps_off
  if [ "$purge" = "1" ]; then
    ok "ГОТОВО. Сервер вычищен от xkit и 3X-UI полностью — восстановить нельзя (режим --purge бэкапов не оставляет)"
  else
    ok "ГОТОВО. Свежий бэкап лежит в $BACKUP_DIR (хранение — политика бэкапов: xkit backup settings)"
    log "Вернуть данные: install.sh -> xkit restore (инбаунды/клиенты панели, маршруты)"
  fi
  return 0
}

# Чистая переустановка: бэкап -> uninstall --full -> one_step_install.
# Бинарник сохраняем (KEEP_BIN=1): one_step_install сам обновит его в конце
# (bash держит fd открытого скрипта, но $0 после rm недоступен для cp)
xkit_reinstall() {
  require_root
  echo ""
  warn "ЧИСТАЯ ПЕРЕУСТАНОВКА: бэкап -> полное удаление (включая панель 3X-UI) -> установка с нуля."
  warn "Инбаунды/клиенты панели будут потеряны (останутся в бэкапе), подписки пересоздадутся."
  confirm "Продолжить? [y/N]: " n || { log "Отменено"; return 1; }
  # имя лога — строго по reinstall, даже если нас вызвали из процесса,
  # где XKIT_LOG уже открыт (напр. preflight-меню поверх one_step_install)
  XKIT_LOG=""
  xkit_log_begin reinstall
  local rc=0
  KEEP_BIN=1 xkit_uninstall --full || rc=$?
  # rc=2 — отмена пользователем на подтверждении: НЕ ошибка, состояние не тронуто
  if [ "$rc" = "2" ]; then
    log "Переустановка отменена пользователем — ничего не удалено, состояние цело"
    return 2
  fi
  [ "$rc" = "0" ] || { err "Переустановка прервана: удаление не удалось"; return 1; }
  # Вложенный one_step_install — намеренно: preflight увидит, что $XKIT_ENV
  # уже удалён, меню не покажет; вложенный xkit_log_begin переиспользует
  # общий лог без очистки (внешний вызов после `return 1` не выполняется).
  one_step_install   # $XKIT_ENV уже удалён — preflight пропустит меню, лог общий
}

# v7.2.4 (вопрос оператора: «нужно ли предварительно накатывать
# security-обновления?»). xkit НЕ делает apt upgrade сам: это потенциальный
# ребут ядра и перезапуск чужих сервисов — решение администратора, а на Ubuntu
# security-патчи обычно уже ставит unattended-upgrades. Но и молчать нельзя:
# честно показываем, что в очереди. Ничего не блокирует.
security_updates_hint() {
  local sim sec=0 reb=0
  sim="$(apt-get -s dist-upgrade 2>/dev/null || true)"
  [ -n "$sim" ] && sec="$(printf '%s\n' "$sim" | grep -c '^Inst .*security' || true)"
  [ -f "${XKIT_REBOOT_FLAG:-/var/run/reboot-required}" ] && reb=1
  [ "${sec:-0}" -gt 0 ] || [ "$reb" = "1" ] || return 0
  warn "Система необновлена: security-обновлений в очереди: ${sec:-0}, ребут запрошен ранее: ${reb}"
  warn "Рекомендуется apt update && apt upgrade (и ребут, если просится) — xkit это не делает сам: ребут ядра и перезапуск сервисов на усмотрение администратора"
  return 0
}

# v7.2.5: обёртка над телом установки — вся фаза капчурится в $XKIT_LOG целиком
# (раньше лог под надписью «Полный лог установки» был почти пуст: в него попадал
# только вывод спиннер-шагов, живой баг v7.2.4). xkit_log_capture_off вернёт
# stdout/stderr при любом исходе — включая die()/INT/TERM (через EXIT-trap в
# xkit_install_cleanup) и ранние return из тела.
one_step_install() {
  local _rc=0
  xkit_install_body || _rc=$?
  xkit_log_capture_off
  return "$_rc"
}

xkit_install_body() {
  require_root
  check_os
  preflight || return 1
  install_backup_offer || return 1
  # ветка «поверх» (или XKIT_FORCE): подхватываем текущее состояние — прежний
  # адрес, SUB_TOKEN (ссылки подписок у клиентов НЕ меняются), TG/dash-токены.
  # При чистой установке/reinstall env отсутствует — load вернёт 1, не страшно
  load_xkit_env 2>/dev/null || true
  xkit_log_begin install
  xkit_install_traps_on
  xkit_log_capture_on   # v7.2.5: с этого места весь вывод — и в терминал, и в лог
  STEP=0

  step "Пакеты (nginx, jq, sqlite3, openssl, ufw, python3) + certbot"
  with_spinner "apt-get update..." apt-get update -qq || warn "apt-get update вернул ошибку — продолжаю"
  security_updates_hint
  with_spinner "Установка пакетов..." env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y -qq nginx curl openssl jq sqlite3 ufw cron python3 \
    python3-venv python3-pip \
    || die "Не удалось установить пакеты — подробности в $XKIT_LOG"
  # v7.2.4 (дискуссия с оператором «нельзя ли сразу актуальный»): certbot —
  # ОДНИМ шагом, сразу актуальный в venv; схема «сначала apt 2.9, потом
  # апгрейд» больше не используется. Пакетный certbot остаётся запасным путём
  # (PyPI недоступен): доменные серты работают и на 2.9, IP-серты — нет, меню
  # серт предложит самоподписанный. Если в репо уже >= CERTBOT_MIN_IP — venv
  # вообще не нужен.
  if certbot_supports_ip; then
    ok "certbot $(certbot_version) — актуальный"
  elif with_spinner "certbot: сразу актуальная версия (pip/venv, 1-2 мин)..." certbot_upgrade; then
    ok "certbot обновлён: $(certbot_version)"
  else
    warn "pip/venv не удался (PyPI недоступен?) — ставлю certbot из репозитория"
    with_spinner "certbot из репозитория..." env DEBIAN_FRONTEND=noninteractive \
      apt-get install -y -qq certbot || die "certbot не установлен — подробности в $XKIT_LOG"
    warn "certbot $(certbot_version) из репозитория: IP-сертификаты недоступны (нужен >= ${CERTBOT_MIN_IP})"
  fi

  step "Домен/IP и SSL-сертификат"
  install_restore_certs || return 1
  if [ -n "${XKIT_HOST:-}" ]; then
    confirm "Использовать прежний адрес ${XKIT_HOST}? [Y/n] " y || XKIT_HOST=""
  fi
  if [ -z "${XKIT_HOST:-}" ]; then
    choose_host "Адрес этого сервера (для сертификата и ссылок)"
    XKIT_HOST="$CHOSEN_HOST"
  fi
  [ -n "$XKIT_HOST" ] || die "Домен/IP обязателен"
  HOST_KIND="$(host_kind "$XKIT_HOST")"
  [ "$HOST_KIND" != "bad" ] || die "Адрес не распознан"
  choose_certificate "$XKIT_HOST" "$HOST_KIND" || return 1
  XKIT_CRT="$FINAL_CRT"; XKIT_KEY="$FINAL_KEY"; XKIT_CERT_MODE="$CERT_MODE"

  # (UX, проверка 7.4.0): вопрос о версиях задаём ДО заголовка шага — иначе
  # «неинтерактивно» в заголовке выглядело противоречием с нашим промптом
  versions_installer_select || return 1
  step "Установка панели 3X-UI (официальный инсталлятор, неинтерактивно)"
  install_3xui_auto || return 1
  # v7.2.4: reconcile продления — инсталлятор 3X-UI мог доставить пакетный
  # certbot; приводим автопродление к ровно одному пути (drop-in вместо
  # своего таймера, если пакетный unit появился)
  certbot_renewal_unit 2>/dev/null || true
  install_restore_panel || return 1
  read_panel_settings || return 1
  if [ -n "${XKIT_XRAY_VERSION:-}" ]; then core_pin_install "$XKIT_XRAY_VERSION" || return 1; fi
  if [ "${XUI_JUST_INSTALLED:-0}" = "1" ] && [ "$INSTALL_RESTORE_PANEL" = 0 ]; then panel_password_strengthen || return 1; fi
  # №17 (аудит): XUI_NONINTERACTIVE зависит от версии инсталлятора 3X-UI — если
  # пароль в install-result.env не попал, пункт 3 (логин в панель) не пройдёт
  if [ -z "$PANEL_PASS" ]; then
    warn "Пароль панели не извлечён из install-result.env (версия установщика 3X-UI?)"
    warn "Задайте вручную:  x-ui setting -username admin -password ВАШ_ПАРОЛЬ  — затем продолжайте"
  fi
  PANEL_SCHEME="$(with_spinner -o "Определяю схему панели (http/https)..." detect_panel_scheme "$PANEL_PORT")" || PANEL_SCHEME="http"
  ok "Панель: 127.0.0.1:${PANEL_PORT}${PANEL_WBP} (upstream ${PANEL_SCHEME})"

  log "Прибиваю панель к 127.0.0.1 (webListen), чтобы порт не светился..."
  if with_spinner "webListen -> 127.0.0.1..." force_panel_localhost "$PANEL_PORT"; then
    ok "Панель слушает только 127.0.0.1:${PANEL_PORT}"
  else
    warn "Не удалось включить webListen через БД (postgres или другая схема)"
    warn "Порт панели закрою фаерволом (ufw deny) — см. шаг фаервола"
  fi
  read_panel_settings >/dev/null 2>&1 || true
  # v7.2.5: честно проговариваем схему TLS — инсталлятор 3X-UI печатает пугающее
  # «Panel will be installed WITHOUT SSL», и кажется, что серт «не подтянулся».
  # Это норма: TLS терминирует nginx, панель специально остаётся HTTP на loopback.
  log "TLS терминирует nginx (${XKIT_CRT:-серт из шага 2}) — панель намеренно HTTP на 127.0.0.1:${PANEL_PORT}; снаружи: https://${XKIT_HOST}${PANEL_WBP}"

  # v6.0.0: нативные подписки панели на 127.0.0.1 — из них в файлы подписок xkit
  # попадают ссылки, которые рендерит сама панель (vpn:// AmneziaWG и др.)
  step "Нативные подписки панели (127.0.0.1, проксируются через nginx)"
  ensure_panel_sub_settings || warn "Не удалось настроить подписки панели — ссылки vpn:// (AWG) не попадут в файлы подписок (повтор: xkit extfix)"

  step "Секретный путь подписок + состояние xkit"
  if [ -z "${XKIT_SUB_TOKEN:-}" ]; then XKIT_SUB_TOKEN="$(rand_str 16)"; fi
  # v7.2.5: mkdir обязан идти раньше touch — на чистом сервере /etc/xkit ещё не
  # существует, и touch падал («cannot touch '/etc/xkit/routes.tsv': No such file
  # or directory», живой баг v7.2.4 в [5/7])
  mkdir -p "$XKIT_DIR"; touch "$XKIT_ROUTES"; chmod 600 "$XKIT_ROUTES"
  install_restore_state || return 1
  save_xkit_env

  step "Конфиг nginx (панель + подписки), перезапуск"
  regen_conf_and_apply || return 1
  if [ "$INSTALL_RESTORE_SUBS" = 1 ]; then sub_regen || warn "Подписки не перегенерированы — повторите: xkit sub"; fi
  systemctl enable nginx >/dev/null 2>&1 || true

  step "Фаервол"
  setup_ufw || true
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw deny "${PANEL_PORT}/tcp" >/dev/null 2>&1 && ok "Порт панели ${PANEL_PORT} закрыт снаружи (страховка)"
  fi
  save_xkit_env

  step "Бэкапы по cron + команда xkit"
  backup_setup_on_install      # v7.2.0: «Использовать бэкапы?» + периодичность 24/48/168/свой/нет
  save_xkit_env >/dev/null 2>&1 || true   # политика бэкапов — в xkit.env
  backup_cron_install
  if [ -f "$0" ] && [ "$(readlink -f "$0" 2>/dev/null)" != "$XKIT_BIN" ]; then
    cp -f "$(readlink -f "$0")" "$XKIT_BIN" && chmod 700 "$XKIT_BIN" \
      && ok "Меню установлено: введите в SSH команду xkit"
  fi
  xkit_menu_install || true   # модуль меню (xkit_menu.sh) — v5.0.0
  xkit_extras_install || warn "TUI/модуль протоколов не установлен — выполните xkit update"
  ops_hygiene_install || warn "Maintenance timer не установлен — позже: xkit maintenance install"

  echo ""
  echo -e "${GREEN}============================================================${NC}"
  if [ "${XKIT_UFW:-0}" = "1" ]; then
    ok "ГОТОВО. UFW активен: разрешены SSH, 80 (redirect) и 443 (TLS)."
  else
    ok "ГОТОВО. nginx настроен на 80 (redirect) и 443 (TLS)."
    warn "UFW не активен: самостоятельно проверьте все внешние listening-порты."
  fi
  ok "Панель:  https://${XKIT_HOST}${PANEL_WBP}"
  [ -n "$PANEL_USER" ] && ok "Логин:   ${PANEL_USER}   Пароль: ${PANEL_PASS}"
  ok "Креды также в ${XUI_RESULT} (chmod 600)"
  echo ""
  log "Дальше:"
  log "  1) Зайдите в панель, создайте инбаунд: Listen IP = 127.0.0.1, порт любой"
  log "  2) Введите xkit -> пункт 2 — он сам всё пробросит за nginx и сделает подписки"
  log "  3) Проверка: xkit -> пункт 7 (жизнеспособность и «что светится»)"
  [ "$CERT_MODE" = "3" ] && warn "IP-серт живёт 6 дней — продление настроено (systemd-таймер + hooks)"
  [ "$CERT_MODE" = "4" ] && warn "Самоподписанный серт: на клиентах allowInsecure=true"
  [ "$CERT_MODE" = "0" ] && ok "Сертификат восстановлен из бэкапа/прошлой установки — перевыпуск не потребовался"
  # v7.2.0: рекомендация BBR (не навязываем — одна команда, если ядро позволяет)
  if command -v sysctl >/dev/null 2>&1; then
    if bbr_active; then
      ok "BBR активен"
    elif bbr_supported; then
      log "Рекомендация: включите BBR — xkit bbr on (пропускная способность и latency под нагрузкой)"
    fi
  fi
  echo -e "${GREEN}============================================================${NC}"

  # v4.5: развилка «что дальше» вместо одного вопроса про автопроброс.
  # Вариант «мастер» = автопроброс + добавление нод (node_add требует
  # живой nginx и панель, поэтому автопроброс всегда идёт первым).
  # XKIT_YES=1 (CI/cloud-init): без вопросов — «сделаю позже сам»
  echo ""
  log "Что дальше?"
  echo "  1) Одиночный сервер — автопроброс инбаундов за nginx (по умолчанию)"
  echo "  2) Главный и дополнительные серверы — настройка nginx, затем подключение серверов"
  echo "  3) Ничего — сделаю позже сам (xkit route / xkit nodes)"
  if [ "${XKIT_YES:-0}" = "1" ]; then
    a="3"
  else
    read -r -p "Выбор [1]: " a || a=""
  fi
  case "${a:-1}" in
    1|"") auto_route ;;
    2) auto_route || warn "Автопроброс не прошёл — ноды можно добавить позже (xkit nodes)"
       echo ""
       log "Добавление нод (мастер-режим)..."
       nodes_menu ;;
    3) : ;;
    *) warn "Нет такого пункта — позже: xkit route (проброс) или xkit nodes (ноды)" ;;
  esac

  if [ "$INSTALL_RESTORE_NODES" = 1 ]; then nodes_restore_reconnect || warn "Часть нод требует ручной проверки: xkit nodes check all --deep"; fi
  case "${INSTALL_BACKUP_STAGE:-}" in /tmp/*) rm -rf -- "$INSTALL_BACKUP_STAGE" ;; esac
  INSTALL_BACKUP_STAGE=""
  echo ""
  xkit_info   # вся сводка в терминал + /root/xkit-info.txt (chmod 600)
  xkit_install_traps_off
  [ -n "${XKIT_LOG:-}" ] && log "Полный лог установки: ${XKIT_LOG}"
  return 0
}

# спрятать УЖЕ установленную панель (без переустановки всего)
hide_existing_panel() {
  require_root
  command -v x-ui >/dev/null 2>&1 || die "3X-UI не установлен (команда x-ui не найдена)"
  read_panel_settings || return 1
  ok "Найдена панель: 127.0.0.1:${PANEL_PORT}${PANEL_WBP}"

  echo ""
  choose_host "Адрес этого сервера (для nginx)"
  XKIT_HOST="$CHOSEN_HOST"
  [ -n "$XKIT_HOST" ] || die "Домен/IP обязателен"
  HOST_KIND="$(host_kind "$XKIT_HOST")"
  choose_certificate "$XKIT_HOST" "$HOST_KIND" || return 1
  XKIT_CRT="$FINAL_CRT"; XKIT_KEY="$FINAL_KEY"; XKIT_CERT_MODE="$CERT_MODE"
  [ -z "${XKIT_SUB_TOKEN:-}" ] && XKIT_SUB_TOKEN="$(rand_str 16)"
  mkdir -p "$XKIT_DIR"; touch "$XKIT_ROUTES"; chmod 600 "$XKIT_ROUTES"   # v7.2.5: mkdir до touch

  if force_panel_localhost "$PANEL_PORT"; then
    ok "Панель прибита к 127.0.0.1"
    read_panel_settings >/dev/null 2>&1 || true
  fi
  save_xkit_env
  regen_conf_and_apply || return 1
  setup_ufw || true
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw deny "${PANEL_PORT}/tcp" >/dev/null 2>&1 && ok "Порт панели закрыт снаружи"
  fi
  save_xkit_env
  if [ -f "$0" ]; then cp -f "$(readlink -f "$0")" "$XKIT_BIN" && chmod 700 "$XKIT_BIN"; fi
  xkit_menu_install || true   # модуль меню (xkit_menu.sh) — v5.0.0
  xkit_extras_install || warn "TUI/модуль протоколов не установлен — выполните xkit update"
  ok "Панель доступна ТОЛЬКО через: https://${XKIT_HOST}${PANEL_WBP}"
  log "Дальше: инбаунды с Listen IP = 127.0.0.1, затем пункт 2 (автопроброс)"
  xkit_summary_save >/dev/null 2>&1 || true
  return 0
}

panel_sub_uri_fix() { # исправляет нативный URL только при расхождении; без лишнего restart
  local want current
  want="https://${XKIT_HOST}${XKIT_PANEL_SUB_PATH}"
  current="$(panel_settings_get | jq -r '.obj.subURI // empty' 2>/dev/null)" || return 1
  [ "$current" = "$want" ] || ensure_panel_sub_settings
}

#=========================== v4.1: API-РАСШИРЕНИЯ =============================
# v7.2.5: ${COOKIE_JAR:-} — вызов без предварительного kit_login больше не
# роняет set -u («COOKIE_JAR: unbound variable», живой баг v7.2.4 в [4/7]).
# + bearer-аргументы (api_auth_args) для пути через API-токен.
api_get_raw() {
  local url; url="$(api_url)$1"
  local -a a=(-s --max-time 10)
  [ "${PANEL_SCHEME:-http}" = "https" ] && a+=(-k)
  [ -n "${COOKIE_JAR:-}" ] && a+=(-b "$COOKIE_JAR")
  api_auth_args
  curl "${a[@]}" "${API_AUTH_ARGS[@]}" "$url"
}

api_post_raw() { # $1 путь, остальные — аргументы curl (--data-urlencode k=v ...)
  local p="$1"; shift
  local url; url="$(api_url)${p#/}"
  local -a a=(-s --max-time 20 -X POST)
  [ "${PANEL_SCHEME:-http}" = "https" ] && a+=(-k)
  [ -n "${COOKIE_JAR:-}" ] && a+=(-b "$COOKIE_JAR")
  [ -n "$CSRF_TOKEN" ] && a+=(-H "X-CSRF-Token: $CSRF_TOKEN")
  api_auth_args
  curl "${a[@]}" "${API_AUTH_ARGS[@]}" "$url" "$@"
}

# v4.9.1: в 3X-UI v3 externalProxy у инбаунда ВЫВЕДЕН — вместо него host-группы
# /panel/api/hosts ( remark "xkit", адрес+порт+security). Апдейт по groupId, если
# группа уже есть — без дублей при повторном запуске.
v3_host_upsert() { # $1 id инбаунда, $2 адрес, $3 порт, $4 security (tls|same|reality)
  local id="$1" addr="$2" eport="$3" sec="$4" resp gid body
  body="$(jq -nc --argjson ids "[${id}]" --arg a "$addr" --argjson p "$eport" --arg s "$sec" \
    '{inboundIds:$ids, remark:"xkit", hosts:[$a], port:$p, security:$s}')"
  resp="$(api_get_raw "panel/api/hosts/list" 2>/dev/null || true)"
  # №18 (аудит №1): нестандартный ответ (строка/массив вместо объекта) —
  # поиск groupId молча не найдёт группу => hosts/add создаст ДУБЛЬ. Честно предупредить
  if [ -n "$resp" ] && ! jq -e 'type=="object"' <<<"$resp" >/dev/null 2>&1; then
    warn "hosts/list: нестандартный ответ панели — возможен дубль host-группы (проверьте панель)"
  fi
  gid="$(jq -r --argjson id "$id" \
    '[.obj[]? | select(((.inboundIds // []) | index($id)) and ((.remark // "") == "xkit"))][0].groupId // empty' \
    <<<"$resp" 2>/dev/null || true)"
  if [ -n "$gid" ]; then
    resp="$(api_post_json "panel/api/hosts/update/${gid}" "$body")"
  else
    resp="$(api_post_json "panel/api/hosts/add" "$body")"
  fi
  jq -e '.success == true' <<<"$resp" >/dev/null 2>&1
}

panel_settings_get() {
  local out
  if [ "$API_V3" = "1" ]; then
    # v3: /panel/api/setting/all только POST (и возвращает browser-safe view:
    # секреты скрыты, но sub*/xray-поля на месте)
    out="$(api_post_json "panel/api/setting/all" "{}")"
  else
    out="$(api_get_raw "panel/setting/all")"
    if ! jq -e '.success == true' <<<"$out" >/dev/null 2>&1; then
      out="$(api_post_raw "panel/setting/all")"
    fi
  fi
  if ! jq -e '.success == true' <<<"$out" >/dev/null 2>&1; then
    err "panel settings: $(api_err_msg "$out" 2>/dev/null | head -c 200)"
    return 1
  fi
  printf '%s' "$out"
}

panel_settings_set() { # пары key=value
  local resp p
  if [ "$API_V3" = "1" ]; then
    p="panel/api/setting/update"
    # v7.4.3: v3-эндпоинт биндит ВСЮ структуру updateSettingForm (entity.AllSetting)
    # и валидирует её целиком: частичная form-форма не проходит — отсутствующие
    # int-поля биндятся нулями и валят validate:"gte=1" (webPort/sessionMaxAge/
    # smtpPort/outboundDownThreshold/nodeDownThreshold) — живой лог 7.4.2:
    # «panel/api/setting/update: request body failed validation» в шаге 4/7.
    # Шлём ПОЛНЫЙ объект из setting/all: секреты в browser-safe view пустые,
    # а «пусто = не менять» (preserveRedactedSecrets панели сохранит прежние).
    # Наши переопределения накладываем сверху с приведением типа ПО ТЕКУЩЕМУ
    # типу поля (bool/number/string), чтобы биндинг не упал на типе.
    local all base pair k v json
    all="$(panel_settings_get)" || { err "${p}: не удалось прочитать settings/all для полной формы"; return 1; }
    base="$(jq -c '.obj // empty' <<<"$all" 2>/dev/null)"
    [ -n "$base" ] || { err "${p}: settings/all вернул пустой obj — update отменён"; return 1; }
    json="$base"
    for pair in "$@"; do
      k="${pair%%=*}"; v="${pair#*=}"
      [ "$k" != "$pair" ] || { err "${p}: аргумент без '=': ${pair:0:40}"; return 1; }
      json="$(jq -c --arg k "$k" --arg v "$v" '
        .[$k] = (if (.[$k]? | type)=="boolean" then ($v=="true" or $v=="1")
                 elif (.[$k]? | type)=="number" then ($v | tonumber)
                 else $v end)' <<<"$json")" \
        || { err "${p}: не удалось применить ключ ${k} к полной форме"; return 1; }
    done
    resp="$(api_post_json "$p" "$json")"
  else
    p="panel/setting/update"
    resp="$(api_post_form "$p" "$@")"
  fi
  if ! jq -e '.success == true' <<<"$resp" >/dev/null 2>&1; then
    err "${p}: $(api_err_msg "$resp" 2>/dev/null | head -c 200)"
    return 1
  fi
  return 0
}

panel_restart() {
  local p out
  # v3: /panel/api/setting/restartPanel; v2: panel/setting/restartPanel, server/restartPanel
  for p in "panel/api/setting/restartPanel" "panel/setting/restartPanel" "server/restartPanel"; do
    out="$(api_post_raw "$p")" || true
    if jq -e '.success == true' <<<"$out" >/dev/null 2>&1; then
      ok "Панель перезапускается..."
      sleep 3
      kit_login >/dev/null 2>&1 || true
      return 0
    fi
  done
  warn "Перезапуск панели через API не удался (можно вручную: x-ui restart panel)"
  return 1
}

xray_restart() {
  local out
  out="$(api_post_raw "panel/api/server/restartXrayService" 2>/dev/null)" || {
    warn "Не удалось перезапустить xray через API"; return 1;
  }
  if jq -e '.success == true' <<<"$out" >/dev/null 2>&1; then
    ok "Xray перезапущен"
    return 0
  fi
  warn "Панель отклонила перезапуск Xray"
  return 1
}

api_add_inbound() { # $1 полный JSON инбаунда
  local ib resp
  ib="$(api_normalize_tgid <<<"$1")" || { err "add inbound: tgId должен быть целым числом или отсутствовать"; return 1; }
  resp="$(api_post add "$ib")" || return 1
  if ! jq -e '.success == true' <<<"$resp" >/dev/null 2>&1; then
    # v7.4.1: api_err_msg — пустой .msg/пустое тело больше не печатаются молчком
    err "add inbound: $(api_err_msg "$resp" | head -c 300)"
    return 1
  fi
  return 0
}

# пара ключей x25519 "private public" (API панели, фолбэк — локальный xray)
api_get_new_x25519() {
  local out priv pub xr pair
  out="$(api_get_raw "panel/api/server/getNewX25519Cert")"
  priv="$(jq -r '.obj.privateKey // .obj.private_key // empty' <<<"$out" 2>/dev/null)"
  pub="$(jq -r '.obj.publicKey // .obj.public_key // empty' <<<"$out" 2>/dev/null)"
  if [ -z "$priv" ] || [ -z "$pub" ]; then
    xr="$(ls -1 /usr/local/x-ui/bin/xray-* 2>/dev/null | head -n1)"
    [ -n "$xr" ] || { err "Не могу сгенерировать x25519 (нет API и нет бинарника xray)"; return 1; }
    pair="$("$xr" x25519 2>/dev/null)" || { err "xray x25519 не сработал"; return 1; }
    priv="$(awk '/Private/{print $NF}' <<<"$pair")"
    pub="$(awk '/Public/{print $NF}' <<<"$pair")"
  fi
  [ -n "$priv" ] && [ -n "$pub" ] || return 1
  printf '%s %s\n' "$priv" "$pub"
}

#=========================== v4.1: ПОДПИСКИ САМОЙ ПАНЕЛИ ======================
# Нативный sub-сервис 3X-UI вешаем на 127.0.0.1:ПОРТ и проксируем через nginx.
# В панели при этом корректный URL: https://ДОМЕН/sub-<token>/<subId>
ensure_panel_sub_settings() {
  # v7.2.5: в fresh-install пути API-сессии ещё нет (kit_login раньше не
  # вызывался) — бутстрап: API-токен, иначе классический логин. Без сессии —
  # честный отказ, а не падение set -u.
  if api_token_ok; then
    API_V3=1   # bearer-путь есть только в 3x-ui v3.11+
  else
    [ -n "${XKIT_XUI_API_TOKEN:-}" ] && warn "API-токен панели не принят — переключаюсь на логин/пароль"
    kit_login || { err "Не удалось залогиниться в панель API — подписки не настроены (повтор: xkit extfix)"; return 1; }
    api_detect_generation
  fi
  local all cur_port cur_path
  all="$(panel_settings_get)" || return 1
  cur_port="$(jq -r '.obj.subPort // ""' <<<"$all")"
  cur_path="$(jq -r '.obj.subPath // ""' <<<"$all")"

  if [ -z "${XKIT_PANEL_SUB_PORT:-}" ] && [ -n "$cur_port" ] && is_port "$cur_port" && [ "$cur_port" != "0" ]; then
    XKIT_PANEL_SUB_PORT="$cur_port"
  fi
  [ -n "${XKIT_PANEL_SUB_PORT:-}" ] || XKIT_PANEL_SUB_PORT="$(rand_free_port 30000 50000)" \
    || { err "Нет свободного порта для подписок"; return 1; }
  if [ -z "${XKIT_PANEL_SUB_PATH:-}" ]; then
    if [ -n "$cur_path" ] && is_nginx_path "$(normalize_panel_path "$cur_path")"; then
      XKIT_PANEL_SUB_PATH="$(normalize_panel_path "$cur_path")"
    else
      [ -n "$cur_path" ] && warn "subPath панели «${cur_path:0:40}» нестандартный — генерирую свой (K-01)"
      XKIT_PANEL_SUB_PATH="/sub-${XKIT_SUB_TOKEN:-$(rand_str 8)}/"
    fi
  fi

  log "Подписки панели: 127.0.0.1:${XKIT_PANEL_SUB_PORT}${XKIT_PANEL_SUB_PATH} -> https://${XKIT_HOST}${XKIT_PANEL_SUB_PATH}"
  panel_settings_set \
    "subEnable=true" \
    "subPort=${XKIT_PANEL_SUB_PORT}" \
    "subPath=${XKIT_PANEL_SUB_PATH}" \
    "subListen=127.0.0.1" \
    "subDomain=${XKIT_HOST}" \
    "subURI=https://${XKIT_HOST}${XKIT_PANEL_SUB_PATH}" || return 1
  ok "Настройки подписок панели применены"
  panel_restart || true
  save_xkit_env
  return 0
}

#=========================== v4.1: КОРРЕКТНЫЕ ССЫЛКИ В ПАНЕЛИ =================
# externalProxy каждому инбаунду: панель генерирует ссылки и QR с
# https://ДОМЕН:443/путь (за nginx) либо ДОМЕН:ПОРТ (direct: Reality и т.п.)
external_proxy_fix() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  [ -n "$XKIT_HOST" ] || die "Не задан XKIT_HOST"
  kit_session || return 1
  routes_load

  echo ""
  log "Шаг 1/2: нативные подписки 3X-UI через nginx..."
  ensure_panel_sub_settings || return 1

  echo ""
  log "Шаг 2/2: externalProxy на инбаундах (панель покажет ДОМЕН, а не 127.0.0.1)..."
  if [ -t 0 ] && [ "${XKIT_YES:-0}" != "1" ]; then
    confirm "Проставить externalProxy ws/grpc/xhttp-инбаундам? (Reality/прямые НЕ трогаем) [Y/n] " y \
      || { log "Отменено"; return 0; }
  fi
  local fixed=0 same=0 ib id port mode eport cur new patched sec
  while IFS= read -r ib; do
    [ -z "$ib" ] && continue
    id="$(jq -r '.id' <<<"$ib")"; port="$(jq -r '.port' <<<"$ib")"
    sec="$(jq -r '.streamSettings|fromjson?|.security // "none"' <<<"$ib")"
    IFS='|' read -r mode _ _ <<<"$(route_info "$id")"
    if [ "$sec" = "reality" ] || [ "$mode" = "direct" ]; then
      same=$((same+1)); continue   # прямым инбаундам (Reality/relay) externalProxy не нужен
    fi
    if [ "$mode" = "local" ]; then eport=443; else eport="$port"; fi
    if [ "$API_V3" = "1" ]; then
      # v3: externalProxy заменён host-группами; апдейт идемпотентен (по groupId)
      if v3_host_upsert "$id" "$XKIT_HOST" "$eport" "tls"; then
        ok "#$id: внешний адрес ${XKIT_HOST}:${eport} (hosts)"
        fixed=$((fixed+1))
      else
        err "#$id: host-группа не применилась"
      fi
      continue
    fi
    cur="$(jq -c '.externalProxy // []' <<<"$ib")"
    new="$(jq -nc --arg d "$XKIT_HOST" --argjson p "$eport" '[{"dest":$d,"port":$p,"remark":"xkit"}]')"
    if [ "$cur" = "$new" ]; then same=$((same+1)); continue; fi
    patched="$(jq -c --argjson ep "$new" '.externalProxy = $ep' <<<"$ib")"
    if api_update_inbound "$id" "$patched"; then
      ok "#$id: внешний адрес ${XKIT_HOST}:${eport}"
      fixed=$((fixed+1))
    else
      err "#$id: externalProxy не применился"
    fi
  done < <(jq -c '.[]' <<<"$INBOUNDS")
  ok "Обновлено: $fixed; уже было корректно: $same"
  xray_restart
  sub_regen_quiet || true
  echo ""
  ok "Теперь ссылки/QR/sub URL в самой панели корректные:"
  ok "  подписка пользователя: https://${XKIT_HOST}${XKIT_PANEL_SUB_PATH}<subId>"
  ok "  файловые подписки xkit: https://${XKIT_HOST}$(sub_path)<subId>"
  return 0
}

#=========================== REALITY / CAMO / XRAY ============================
# CAMO_DIR используется Reality/Hysteria; реализации camo и менеджера версий —
# в src/26_versions_camo.sh (единый fail-closed путь, без старых bypass).
CAMO_DIR="/var/www/camo"

reality_expand_targets() { # CIDR (/24 и меньше) или список -> по IP в строке
  command -v python3 >/dev/null 2>&1 || { err "python3 не найден — выполните: apt-get install -y python3"; echo "ERR:python3 не найден"; return 1; }
  python3 - "$1" <<'PY'
import sys, ipaddress, re
arg = sys.argv[1]
if "/" in arg:
    try:
        net = ipaddress.ip_network(arg, strict=False)
    except ValueError:
        print("ERR:bad-cidr"); sys.exit(0)
    if net.num_addresses > 256:
        print("ERR:too-big"); sys.exit(0)
    for ip in net.hosts():
        print(str(ip))
else:
    for h in arg.split():
        # V-01 (аудит №2): токен уходит в SSH-сессию — валидируем charset,
        # кавычка/;/$ не имеют права доехать до bash ноды
        if not re.fullmatch(r"[A-Za-z0-9._:/-]+", h):
            print("ERR:bad-target"); sys.exit(0)
        print(h)
PY
}

reality_scan_run() { # $1 targets (построчно), $2 out.tsv
  local out="$2"
  local tmp; tmp="$(mktemp /tmp/.xkit-scan.XXXXXX)"
  grep -v '^$' <<<"$1" > "$tmp" || true
  local total open_cnt
  total="$(wc -l < "$tmp")"
  log "Шаг 1/2: TCP-проба :443 на ${total} адресах (50 параллельно)..."
  cat > "${tmp}.probe" <<'EOF'
#!/bin/bash
timeout 2 bash -c 'exec 3<>/dev/tcp/"$1"/443' _ "$1" 2>/dev/null && echo "$1"
EOF
  chmod +x "${tmp}.probe"
  local openf="${tmp}.open"; : > "$openf"
  xargs -a "$tmp" -P 50 -n 1 "${tmp}.probe" >> "$openf" 2>/dev/null || true
  open_cnt="$(grep -c . "$openf" 2>/dev/null || echo 0)"
  log "Шаг 2/2: TLS-детали на ${open_cnt} открытых адресах..."
  : > "$out"
  local ip brief cert cn san issuer end tls13 h2 x25519 selfsig verdict tls_version cipher alpn
  while IFS= read -r ip; do
    [ -z "$ip" ] && continue
    brief="$(echo | timeout 6 openssl s_client -brief -connect "${ip}:443" -servername "${ip}" 2>&1)"
    tls13=no;  grep -q "TLSv1.3" <<<"$brief" && tls13=yes
    h2=no;     grep -qi "ALPN protocol: *h2" <<<"$brief" && h2=yes
    x25519=no; grep -q "X25519" <<<"$brief" && x25519=yes
    tls_version="$(sed -n 's/.*Protocol version: *//p' <<<"$brief" | head -n1)"
    cipher="$(sed -n 's/.*Ciphersuite: *//p' <<<"$brief" | head -n1)"
    alpn="$(sed -n 's/.*ALPN protocol: *//p' <<<"$brief" | head -n1)"
    cert="$(echo | timeout 6 openssl s_client -connect "${ip}:443" -servername "${ip}" 2>/dev/null \
            | openssl x509 -noout -subject -issuer -ext subjectAltName -enddate 2>/dev/null)"
    cn="$(sed -n 's/^subject=.*CN *= *//p' <<<"$cert" | head -n1 | cut -d, -f1 | tr -d ' ')"
    # первый SAN без wildcard (в качестве SNI wildcard не годится), фолбэк — CN
    san="$(awk '/^X509v3 Subject Alternative Name:/{getline; sub(/^ +/,""); print; exit}' <<<"$cert" \
           | sed 's/DNS://g' | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^\*' | head -n1)"
    [ -n "$san" ] || san="$cn"
    issuer="$(sed -n 's/^issuer=.*CN *= *//p' <<<"$cert" | head -n1 | cut -d, -f1 | tr -d ' ')"
    end="$(sed -n 's/^notAfter=//p' <<<"$cert" | head -n1)"
    # self-signed = ЛЮБОЙ провал проверки цепочки (истёк, кривой CN/SAN, unknown CA,
    # incomplete chain). «Verify return code: 0 (ok)» — единственный признак «годен».
    # Раньше отсутствие строки verify трактовалось как успех — плохой dest получал «ДА».
    vrf_out="$(echo | timeout 6 openssl s_client -connect "${ip}:443" -servername "${ip}" 2>&1)"
    selfsig=yes
    if grep -q 'Verify return code: 0 (ok)' <<<"$vrf_out" \
       || grep -qE 'Verify return code: 0[[:space:]]*$' <<<"$vrf_out"; then
      selfsig=no
    fi
    verdict="НЕТ"
    if [ "$tls13" = "yes" ] && [ "$selfsig" = "no" ] && { [ -n "$san" ] || [ -n "$cn" ]; }; then
      verdict="ДА"
      [ "$h2" = "yes" ] && [ "$x25519" = "yes" ] && verdict="ДА+"
    fi
    # Первые 9 полей сохранены для совместимости; v7 добавляет issuer/version/cipher/alpn.
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$ip" "$tls13" "$h2" "$x25519" "$selfsig" "${cn:--}" "${san:--}" "${end:--}" "$verdict" \
      "${issuer:--}" "${tls_version:--}" "${cipher:--}" "${alpn:--}" >> "$out"
  done < "$openf"
  rm -f "$tmp" "${tmp}.probe" "$openf"
  return 0
}

# Единый порядок для отображения и выбора: только подходящие REALITY-кандидаты.
# Полный TSV при этом остаётся на диске для технической диагностики.
# v6.0.0 (по образцу фильтров 3X-UI_KIT): из кандидатов вырезаем имена, которые
# выдают маскировку или выглядят подозрительно для блокировщика:
# брендовые домены (маскироваться под гугл/эппл — дурной тон и риск),
# динамические DNS (сайт «соседа» может завтра переехать) и «плохие» слова.
reality_scan_candidates() { # $1 tsv
  awk -F '\t' '$9 == "ДА" || $9 == "ДА+"' "$1" | awk -F '\t' '
    BEGIN{
      brand="(^|\\.)(google|googleapis|gstatic|youtube|microsoft|windows|apple|icloud|amazon|amazonaws|samsung|yahoo|cloudflare|facebook|instagram|netflix|github|telegram|openai|anthropic)\\.[a-z.]+$"
      dyn="(^|\\.)(sslip\\.io|nip\\.io|xip\\.io|traefik\\.me|work\\.gd|duckdns\\.org|ddns\\.net|hopto\\.org|zapto\\.org|myftp\\.(biz|org)|dynu\\.(net|com)|freeddns\\.org|no-ip\\.(org|biz|info))$"
      bad="(probiv|porn|xxx|sex|adult|casino|bet|vpn|proxy|torrent|crack|hack|warez|drug|weapon|leak|escort|gambl|poker)"
    }
    {
      sni=($7!="-" && $7!="") ? $7 : $6
      if (sni=="" || sni=="-") next
      if (sni ~ brand) next
      if (sni ~ dyn) next
      if (sni ~ bad) next
      print
    }' | sort -t$'\t' -k9,9r -k1,1V
}

reality_scan_candidate_row() { # $1 tsv, $2 номер из нумерованной таблицы
  [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -gt 0 ] || return 1
  reality_scan_candidates "$1" | sed -n "${2}p"
}

reality_scan_print() { # $1 tsv
  local total; total="$(reality_scan_candidates "$1" | wc -l)"
  if [ "$total" -eq 0 ]; then
    echo ""
    warn "Подходящих REALITY-кандидатов не найдено."
    return 1
  fi
  echo ""
  printf '%-5s %-16s %-3s %-7s %-34s %s\n' "№" "IP" "H2" "X25519" "SNI(SAN)" "ГОДЕН"
  echo "--------------------------------------------------------------------------------"
  local n=0 ip t13 h2 x2 ss cn san end v issuer tlsver cipher alpn
  while IFS=$'\t' read -r ip t13 h2 x2 ss cn san end v issuer tlsver cipher alpn; do
    n=$((n+1))
    printf '%-5s %-16s %-3s %-7s %-34s %s\n' "$n" "$ip" "$h2" "$x2" "${san:0:34}" "$v"
  done < <(reality_scan_candidates "$1")
  echo ""
  ok "Показаны только подходящие: TLS1.3 + публичный сертификат. «ДА+» = ещё и H2/X25519."
}

# Общий выбор по номеру для мастера на сервере и сканирования с ноды.
reality_scan_choose() { # $1 tsv; результат в RDEST / RSNI
  local out="$1" n row
  reality_scan_print "$out" || return 1
  ok "Полный технический отчёт сохранён: $out"
  read -r -p "Номер кандидата из таблицы (Enter — отмена): " n || return 1
  [ -n "$n" ] || return 1
  row="$(reality_scan_candidate_row "$out" "$n")"
  [ -n "$row" ] || { err "Нет кандидата с таким номером"; return 1; }
  RDEST="$(awk -F'\t' '{print $1":443"}' <<<"$row")"
  RSNI="$(awk -F'\t' '{print ($7!="-" && $7!="") ? $7 : $6}' <<<"$row")"
  [ -n "$RSNI" ] && [ "$RSNI" != "-" ] || { err "У кандидата нет домена в сертификате — SNI не определить"; return 1; }
  return 0
}

# выбор из готового списка; результат в RDEST / RSNI
reality_known_pick() {
  echo "1) 1.1.1.1:443                SNI: cloudflare-dns.com  (быстрый, надёжный)"
  echo "2) www.tesla.com:443          SNI: www.tesla.com"
  echo "3) www.samsung.com:443        SNI: www.samsung.com"
  echo "4) www.lovelive-anime.jp:443  SNI: www.lovelive-anime.jp"
  echo "5) www.icloud.com:443         SNI: www.icloud.com"
  read -r -p "Выбор [1-5]: " k
  case "$k" in
    1) RDEST="1.1.1.1:443";              RSNI="cloudflare-dns.com" ;;
    2) RDEST="www.tesla.com:443";        RSNI="www.tesla.com" ;;
    3) RDEST="www.samsung.com:443";      RSNI="www.samsung.com" ;;
    4) RDEST="www.lovelive-anime.jp:443"; RSNI="www.lovelive-anime.jp" ;;
    5) RDEST="www.icloud.com:443";       RSNI="www.icloud.com" ;;
    *) return 1 ;;
  esac
  return 0
}

# скан подсети + выбор кандидата; результат в RDEST / RSNI
reality_scan_pick() {
  local myip def t targets
  myip="$(pubip)"
  def=""; [ -n "$myip" ] && def=" (Enter = ${myip%.*}.0/24 — подсеть этого сервера)"
  read -r -p "Что сканируем? CIDR или список IP/доменов через пробел${def} -> " t
  t="${t:-${myip%.*}.0/24}"
  targets="$(reality_expand_targets "$t")"
  case "$targets" in ERR:*) err "$targets"; return 1 ;; esac
  local out="${XKIT_DIR}/reality-scan.tsv"
  mkdir -p "$XKIT_DIR"
  warn "Сканируйте только разрешённые цели. Провайдер VPS может расценить массовое сканирование как abuse; это не DPI-тест."
  reality_scan_run "$targets" "$out" || return 1
  [ -s "$out" ] || { warn "Ни один адрес не ответил на :443"; return 1; }
  reality_scan_choose "$out"
}

# $1 dest (host:port | ip:port | 127.0.0.1:8444), $2 sni
reality_create_inbound() {
  local dest="$1" sni="$2" p
  p="$(rand_free_port 10000 60000)" || { err "Нет свободного порта"; return 1; }
  read -r -p "Публичный порт Reality inbound [${p}]: " pin
  p="${pin:-$p}"
  is_port "$p" || { err "Некорректный порт"; return 1; }
  port_busy "$p" && { err "Порт $p уже занят"; return 1; }

  log "Генерирую ключи x25519 через API панели..."
  local priv pub
  read -r priv pub <<<"$(api_get_new_x25519)"
  [ -n "$priv" ] && [ -n "$pub" ] || { err "Не удалось получить ключи x25519"; return 1; }
  local sid
  sid="$(rand_hex 4)"

  local settings stream ib so
  so='{}'; sockopt_enabled && so="$(sockopt_obj)"   # v7.4.3: TFO+TCP_NODELAY (xkit sockopt off — отключить)
  settings='{"clients":[],"decryption":"none","fallbacks":[]}' 
  stream="$(jq -nc --arg dest "$dest" --arg sni "$sni" --arg priv "$priv" --arg sid "$sid" --arg pub "$pub" --argjson so "$so" '
    {network:"tcp", security:"reality",
     realitySettings:{show:false, xver:0, dest:$dest, serverNames:[$sni],
                      privateKey:$priv, minClient:"", maxClient:"", maxTimeDiff:0,
                      shortIds:[$sid], settings:{publicKey:$pub, fingerprint:"chrome", serverName:""}}}
    + (if (($so|length) > 0) then {sockopt:$so} else {} end)')"
  ib="$(jq -nc --arg port "$p" --arg tag "inbound-${p}" --arg remark "reality-${sni}" \
        --arg s "$settings" --arg st "$stream" '
    {up:0, down:0, total:0, remark:$remark, enable:true, expiryTime:0,
     listen:"", port:($port|tonumber), protocol:"vless",
     settings:$s, streamSettings:$st,
     sniffing:"{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"]}",
     allocate:"{\"strategy\":\"always\",\"refresh\":5,\"concurrency\":-1}",
     tag:$tag}')"

  log "Создаю Reality inbound: порт ${p}, dest ${dest}, SNI ${sni}..."
  api_add_inbound "$ib" || return 1
  if [ "$so" != "{}" ]; then sockopt_tfo_sysctl_apply || true; fi   # v7.4.3: серверный бит TFO

  # id созданного + externalProxy (чтобы панель показывала ДОМЕН:порт)
  local newlist ibid fresh
  newlist="$(api_list)" || true
  ibid="$(jq -r --arg t "inbound-${p}" '[.[]|select(.tag==$t)][0].id // empty' <<<"$newlist")"
  if [ -n "$ibid" ]; then
    fresh="$(api_get_inbound "$ibid")" || true
    if [ "$API_V3" = "1" ]; then
      # v3: externalProxy заменён host-группами; Reality наследует security (same)
      v3_host_upsert "$ibid" "$XKIT_HOST" "$p" "same" \
        && ok "Внешний адрес в панели (hosts): ${XKIT_HOST}:${p}" \
        || warn "Не удалось создать host-группу для Reality-инбаунда (ссылки в панели — вручную)"
    elif [ -n "$fresh" ]; then
      fresh="$(jq -c --arg d "$XKIT_HOST" --argjson p "$p" \
        '.externalProxy = [{"dest":$d,"port":$p,"remark":"xkit"}]' <<<"$fresh")"
      api_update_inbound "$ibid" "$fresh" >/dev/null 2>&1 || true
      fresh="$(api_get_inbound "$ibid")" || true
    fi
  else
    fresh="$ib"
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${p}/tcp" >/dev/null 2>&1 && ok "UFW: открыт ${p}/tcp"
  fi

  echo ""
  ok "Reality inbound создан: порт ${p}, dest ${dest}, SNI ${sni}"
  [ -n "$ibid" ] && ok "Внешний адрес в панели: ${XKIT_HOST}:${p}"
  sub_regen_quiet || true
  ok "Автоматических пользователей нет — добавьте своего через «Пользователи»"
  return 0
}

reality_wizard() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  kit_session || return 1
  echo ""
  echo "Какой dest (сайт-прикрытие) используем для Reality?"
  echo "1) Свой сайт на этом сервере (${XKIT_HOST:-домен} + наш сертификат) — лучший камуфляж"
  echo "2) Скан подсети — найти подходящие сайты рядом"
  echo "3) Готовый список проверенных сайтов"
  echo "4) Ввести адрес сайта и SNI вручную"
  read -r -p "Выбор [1-4]: " c
  local dest="" sni=""
  case "$c" in
    1)
      # v7.2.5: IP-режим с валидным сертификатом (LE shortlived IP) тоже годится.
      # nginx на 127.0.0.1:8444 отдаёт наш серт, посторонние после Reality-фолбэка
      # видят сайт-прикрытие, а SNI=XKIT_HOST (IP) не проверяется по CN — раньше
      # жёсткий фильтр «только домен» делал «свой сайт» недоступным на IP-серверах
      # (живой случай VM-212285: маскировка вообще не создавалась).
      if [ ! -f "${XKIT_CRT:-}" ] || [ ! -f "${XKIT_KEY:-}" ]; then
        err "Нужен валидный сертификат (домен или IP) — сейчас его нет."
        warn "Варианты: пункт «Сертификат: перевыпустить» либо режимы 2/3/4 ниже."
        return 1
      fi
      camo_site_install
      XKIT_REALITY_INTERNAL=1
      save_xkit_env
      regen_conf_and_apply || return 1
      dest="127.0.0.1:8444"; sni="$XKIT_HOST" ;;
    2) reality_scan_pick || return 1; dest="$RDEST"; sni="$RSNI" ;;
    3) reality_known_pick || return 1; dest="$RDEST"; sni="$RSNI" ;;
    4)
      local dh dp
      dh="$(read_host "dest (IP или домен) -> ")"
      read -r -p "Порт dest [443]: " dp; dp="${dp:-443}"; is_port "$dp" || { err "Порт"; return 1; }
      sni="$(read_host "SNI (домен из сертификата dest) -> ")"
      dest="${dh}:${dp}" ;;
    *) err "Нет такого пункта"; return 1 ;;
  esac
  [ -n "$dest" ] && [ -n "$sni" ] || { err "dest/SNI не определены"; return 1; }
  reality_create_inbound "$dest" "$sni"
}

reality_scan_menu() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  mkdir -p "$XKIT_DIR"
  local myip def t targets out="${XKIT_DIR}/reality-scan.tsv"
  myip="$(pubip)"
  def=""; [ -n "$myip" ] && def=" (Enter = ${myip%.*}.0/24)"
  echo ""
  read -r -p "CIDR (например 5.6.7.0/24) или список IP/доменов через пробел${def} -> " t
  t="${t:-${myip%.*}.0/24}"
  targets="$(reality_expand_targets "$t")"
  case "$targets" in ERR:*) err "$targets"; return 1 ;; esac
  reality_scan_run "$targets" "$out" || return 1
  [ -s "$out" ] || { warn "Никто не ответил на :443"; return 0; }
  reality_scan_print "$out" || warn "Полный отчёт сохранён для диагностики: $out"
  return 0
}

reality_show_keys() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  kit_session || return 1
  echo ""
  local found=0 ib sec st tag port dest
  while IFS= read -r ib; do
    [ -z "$ib" ] && continue
    sec="$(jq -r '.streamSettings|fromjson?|.security // "none"' <<<"$ib")"
    [ "$sec" = "reality" ] || continue
    found=$((found+1))
    st="$(jq -r '.streamSettings' <<<"$ib")"
    tag="$(jq -r '.tag' <<<"$ib")"; port="$(jq -r '.port' <<<"$ib")"
    dest="$(jq -r '.realitySettings.dest // ""' <<<"$st")"
    echo -e "${GREEN}── ${tag} (порт ${port})${NC}"
    echo "   dest: ${dest}   SNI: $(reality_sni "$st")"
    echo "   publicKey: $(reality_pbk "$st")"
    echo "   shortId:   $(reality_sid "$st")"
    local cl link
    while IFS= read -r cl; do
      [ -z "$cl" ] && continue
      link="$(link_for_client "$ib" "$cl")"
      [ -n "$link" ] && printf '   %s\n' "$link"
    done < <(jq -c '.settings|fromjson?|.clients[]?' <<<"$ib")
  done < <(jq -c '.[]' <<<"$INBOUNDS")
  [ "$found" -eq 0 ] && warn "Reality-инбаундов нет — создайте (пункт 14)"
  return 0
}

#=========================== v4.1: НОДЫ =======================================
# Схема: клиенты -> мастер (nginx:443, pool-inbound) -> xray balancer -> ноды
# (VLESS+Reality на каждой ноде). Переключение при сбоях — observatory.

node_own_key() {
  local key="${XKIT_DIR}/id_ed25519"
  # приватный ключ: каталог обязан быть 0700 ДО генерации (аудит №7) —
  # save_xkit_env мог ещё не выполняться
  mkdir -p "$XKIT_DIR" 2>/dev/null || true
  chmod 700 "$XKIT_DIR" 2>/dev/null || true
  if [ ! -f "$key" ]; then
    ssh-keygen -t ed25519 -N "" -f "$key" -C "xkit-node" -q >/dev/null 2>&1 || return 1
  fi
  [ -s "$key" ] && [ -s "${key}.pub" ] || return 1
  printf '%s' "$key"
}

# v7.2.9: sshpass ставим САМИ (apt). Раньше node_add просто падал с ошибкой
# «установите: apt-get install -y sshpass» — на чистом сервере добавление ноды
# по паролю обрывалось, пользователь обязан был ставить пакет руками
# (репродукция 7.2.8, нода NDp2g). ВЕСЬ вывод в stderr: node_ssh зовётся
# с захваченным stdout (… | grep -q ok) — диагностика не должна попадать
# в поток данных, иначе ломаются проверки результата.
node_ensure_sshpass() {
  command -v sshpass >/dev/null 2>&1 && return 0
  command -v apt-get >/dev/null 2>&1 \
    || { err "sshpass не найден, а apt-get отсутствует — установите пакет sshpass вручную"; return 1; }
  warn "sshpass не найден — устанавливаю (apt-get install -y sshpass)..."
  apt-get install -y -qq sshpass >/dev/null 2>&1 || {
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq sshpass >/dev/null 2>&1 || true
  }
  if command -v sshpass >/dev/null 2>&1; then
    ok "sshpass установлен" >&2
    return 0
  fi
  err "Не удалось установить sshpass — установите вручную: apt-get install -y sshpass"
  return 1
}

node_ssh() { # $1 rec-json, остальные — команда на ноде
  local rec="$1"; shift
  local host port user auth key
  host="$(jq -r '.host' <<<"$rec")"
  port="$(jq -r '.ssh_port // 22' <<<"$rec")"
  user="$(jq -r '.ssh_user // "root"' <<<"$rec")"
  auth="$(jq -r '.auth // "key"' <<<"$rec")"
  key="$(jq -r '.key_path // ""' <<<"$rec")"
  # постоянный known_hosts: первый коннект TOFU (accept-new), дальше — жёсткая проверка ключа
  local kh="${XKIT_DIR}/known_hosts"
  mkdir -p "$XKIT_DIR" 2>/dev/null || true; touch "$kh" 2>/dev/null || true; chmod 600 "$kh" 2>/dev/null || true
  # V-05 (аудит №2): отпечаток показывается и подтверждается ДО первого
  # коннекта — при парольной аутентификации sshpass отправляет пароль сразу
  node_ssh_host_key "$host" "$port" "$kh" \
    || { err "Ключ хоста ${host}:${port} не подтверждён — подключение отменено (V-05)"; return 1; }
  local -a a=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$kh" -o ConnectTimeout=10 -p "$port")
  if [ "$auth" = "password" ]; then
    node_ensure_sshpass || return 1   # v7.2.9: автоустановка вместо голой ошибки
    SSHPASS="$NODE_SSH_PASS" sshpass -e ssh "${a[@]}" "${user}@${host}" "$@"
  else
    ssh -i "$key" -o BatchMode=yes "${a[@]}" "${user}@${host}" "$@"
  fi
}

# узел-TOFU (V-05): снимаем ключ через keyscan, показываем отпечаток, ждём
# подтверждения ДО того, как что-то (тем более пароль) уедет на ноду
node_ssh_host_key() { # $1 host, $2 port, $3 known_hosts -> 0 = можно подключаться
  local host="$1" port="$2" kh="$3" scan fp a
  ssh-keygen -F "[${host}]:${port}" -f "$kh" >/dev/null 2>&1 && return 0
  ssh-keygen -F "${host}" -f "$kh" >/dev/null 2>&1 && return 0
  # v7.2.6: молчание keyscan (до 15 c) объясняем ЗАРАНЕЕ и в stderr (log() мог бы
  # загрязнить capture); сам TOFU-промпт для node_add теперь виден вне 2>/dev/null
  warn "Первое подключение к ${host}:${port}: снимаю ключ хоста (до 15 сек)…"
  scan="$(timeout 15 ssh-keyscan -T 8 -p "$port" "$host" 2>/dev/null)" || scan=""
  [ -n "$scan" ] || { err "Не удалось снять отпечаток ключа ${host}:${port} (V-05)"; return 1; }
  fp="$(printf '%s\n' "$scan" | ssh-keygen -lf - 2>/dev/null | head -n1 | awk '{print $2, $4}')"
  warn "Первое подключение к ${host}:${port}; отпечаток ключа: ${fp:-?}"
  if [ "${XKIT_YES:-0}" = "1" ] || [ ! -t 0 ]; then
    warn "Принимаю без подтверждения (XKIT_YES/не-интерактив; TOFU — сверьте с консолью провайдера)"
  else
    # TOFU: явное «да» (все варианты confirm); пусто/EOF = отказ
    confirm "Совпадает с консолью провайдера? [y/N] " n || return 1
  fi
  printf '%s\n' "$scan" >> "$kh"
  return 0
}

# Изменённый ключ не принимаем автоматически: это может быть MITM.
node_ssh_host_key_refresh() { # $1 host, $2 port, $3 known_hosts
  local host="$1" port="$2" kh="$3" old old_fp scan new_fp
  old="$( { ssh-keygen -F "[${host}]:${port}" -f "$kh"; ssh-keygen -F "$host" -f "$kh"; } 2>/dev/null)"
  old_fp="$(printf '%s\n' "$old" | ssh-keygen -lf - 2>/dev/null)"
  warn "Ключ хоста ${host}:${port} изменился: возможна переустановка сервера или атака MITM."
  [ -z "$old_fp" ] || { echo "Старые отпечатки:"; echo "$old_fp"; } >&2
  scan="$(timeout 15 ssh-keyscan -T 8 -p "$port" "$host" 2>/dev/null)" || scan=""
  [ -n "$scan" ] || { err "Не удалось получить новый ключ ${host}:${port}; старый сохранён"; return 1; }
  new_fp="$(printf '%s\n' "$scan" | ssh-keygen -lf - 2>/dev/null)"
  [ -n "$new_fp" ] || { err "Не удалось проверить новый ключ ${host}:${port}; старый сохранён"; return 1; }
  { echo "Новые отпечатки:"; echo "$new_fp"; } >&2
  if [ "${XKIT_YES:-0}" = "1" ] || [ ! -t 0 ]; then
    err "Смена ключа требует ручного подтверждения; старый сохранён"; return 1
  fi
  confirm "Сверили новый ключ с консолью провайдера и заменяем старый? [y/N] " n || return 1
  ssh-keygen -f "$kh" -R "[${host}]:${port}" >/dev/null 2>&1 || return 1
  ssh-keygen -f "$kh" -R "$host" >/dev/null 2>&1 || return 1
  printf '%s\n' "$scan" >> "$kh"
}

# отпечаток публичного ключа сертификата (пин, как SSH TOFU): защита panel-API
# ноды от MITM. Снимается при добавлении ноды и проверяется curl при каждом вызове
cert_pin() { # $1 host, $2 port -> base64 sha256 публичного ключа (или пусто)
  echo | timeout 8 openssl s_client -connect "$1:$2" -servername "$1" 2>/dev/null \
    | openssl x509 -pubkey -noout 2>/dev/null \
    | openssl pkey -pubin -outform DER 2>/dev/null \
    | openssl dgst -sha256 -binary 2>/dev/null \
    | base64 -w0 2>/dev/null
}

# v7.2.9: CSRF-токен сессии панели ноды (заполняет node_csrf_fetch). 3X-UI v3+
# бьёт 403 любой POST/PUT/DELETE без X-CSRF-Token — у мастера это давно учтено
# (CSRF_TOKEN + api_post), а ветка нод осталась на JSON-логине эпохи v2.
NODE_CSRF_TOKEN=""

node_csrf_fetch() { # $1 rec, $2 cookie -> NODE_CSRF_TOKEN (v3+: роут csrf-token; v2: 404 -> пусто)
  NODE_CSRF_TOKEN=""
  local out
  out="$(node_api "$1" "csrf-token" GET "" "$2" 2>/dev/null)" || return 0
  if jq -e '.success == true' <<<"$out" >/dev/null 2>&1; then
    NODE_CSRF_TOKEN="$(jq -r '.obj // ""' <<<"$out" 2>/dev/null || true)"
  fi
  return 0
}

node_api() { # $1 rec, $2 path, $3 method, $4 JSON-body, $5 cookie
  local rec="$1" path="$2" method="${3:-GET}" body="${4:-}" ck="$5"
  local base url tls sch="http"
  base="$(normalize_panel_path "$(jq -r '.panel.base // "/"' <<<"$rec")")"
  tls="$(jq -r '.panel.tls // "false"' <<<"$rec")"
  [ "$tls" = "true" ] && sch="https"
  url="${sch}://$(jq -r '.host' <<<"$rec"):$(jq -r '.panel.port' <<<"$rec")${base}"
  local -a a=(-s --max-time 20 -c "$ck" -b "$ck" -X "$method")
  local api_token token_header=""
  api_token="${XKIT_NODE_API_TOKEN:-$(jq -r '.panel.token // ""' <<<"$rec")}"
  if [ -n "$api_token" ]; then
    # Токен не попадает в argv: curl читает header из root-only файла.
    token_header="$(mktemp "${XKIT_DIR}/.node-token.XXXXXX")" || return 1
    chmod 600 "$token_header"; printf 'Authorization: Bearer %s\n' "$api_token" > "$token_header"
    a+=(-H "@${token_header}")
  fi
  if [ "$sch" = "https" ]; then
    local pin; pin="$(jq -r '.panel.pincert // ""' <<<"$rec")"
    if [ -n "$pin" ]; then
      a+=(--pinnedpubkey "sha256//$pin")   # пин снят при добавлении — MITM не пройдёт
    else
      a+=(-k)   # самоподписанный сертификат панели ноды (пина нет)
    fi
  fi
  # v7.2.9: CSRF-заголовок для всех мутирующих запросов (v3+ middleware), как
  # у мастера api_post; токен привязан к сессии в $ck (переполучается node_login)
  local csrf="${NODE_CSRF_TOKEN:-}"
  [ -n "$csrf" ] && a+=(-H "X-CSRF-Token: $csrf")
  if [ -n "$body" ]; then
    if [ "$path" = "login" ]; then
      # v7.2.9: логин 3X-UI (v2 и v3) биндится формой (urlencoded) — JSON-тело
      # эпохи v2 панель v3 не принимает вовсе
      a+=(-H 'Content-Type: application/x-www-form-urlencoded' --data @-)
    else
      a+=(-H 'Content-Type: application/json' --data @-)
    fi
  fi
  # V-03 (аудит №2): тело через stdin — пароль панели ноды не виден в /proc/<pid>/cmdline
  local rc
  if [ -n "${NODE_API_HTTP_CODE:-}" ]; then
    # v7.2.11: режим «HTTP-код вместо тела» (потребность node_token_ok):
    # код пишется в NODE_API_HTTP_CODE, тело в stdout не попадает
    NODE_API_HTTP_CODE="$(curl "${a[@]}" -o /dev/null -w '%{http_code}' "${url}${path}" </dev/null 2>/dev/null)"
    rc=$?
  elif [ -n "$body" ]; then
    printf '%s' "$body" | curl "${a[@]}" "${url}${path}"; rc=$?
  else
    curl "${a[@]}" "${url}${path}"; rc=$?
  fi
  [ -z "$token_header" ] || rm -f "$token_header"
  return "$rc"
}

node_login() { # $1 rec, $2 cookie — v7.2.9: двухфазный CSRF форм-логин, как kit_login
  local rec="$1" ck="$2" out
  # v7.2.11: у ноды есть API-токен — Bearer-путь node_api, логин не нужен
  # (токен не зависит от пароля и CSRF; переполучение токена не требуется)
  [ -z "$(jq -r '.panel.token // ""' <<<"$rec")" ] || return 0
  # 3X-UI v3+ (на ноду ставится ТОТ ЖЕ тег, что и на мастер): POST /login без
  # CSRF-токена = 403 с пустым телом ещё ДО проверки пароля. GET /csrf-token
  # создаёт сессию и возвращает токен; v2: 404 — без заголовка (как у мастера)
  NODE_CSRF_TOKEN=""
  node_csrf_fetch "$rec" "$ck"
  # форм-тело вместо JSON; @uri — как в kit_login; пароль идёт через stdin (V-03)
  out="$(node_api "$rec" "login" POST \
    "$(jq -rn --arg u "$(jq -r '.panel.user' <<<"$rec")" --arg p "$(jq -r '.panel.pass' <<<"$rec")" \
       '"username="+($u|@uri)+"&password="+($p|@uri)')" \
    "$ck")"
  jq -e '.success == true' <<<"$out" >/dev/null 2>&1 || return 1
  # v4.9.1-логика мастера: панель чистит сессию при логине (SetLoginUser ->
  # s.Clear()) — CSRF-токен анонимной сессии аннулирован. Переполучаем от
  # АВТОРИЗОВАННОЙ сессии, иначе все POST node_api вернут 403
  node_csrf_fetch "$rec" "$ck"
  return 0
}

# v7.2.11: API-токен панели ноды (3X-UI v3.11+). Инсталлятор пишет
# XUI_API_TOKEN в /etc/x-ui/install-result.env (mode 600); Bearer-запросы
# node_api CSRF-middleware панели пропускает (как api_authed у мастера) и
# токен не зависит от пароля/2FA — предпочтительный путь. Источники:
# авто-сбор в node_add из install-result.env по SSH (node_token_fetch),
# ручной «xkit nodes token set» (v7.x), обновление «xkit nodes relogin».
node_token_fetch() { # $1 rec -> stdout: XUI_API_TOKEN из install-result.env (пусто = нет токена)
  # парсинг БЕЗ source (файл пишет инсталлятор, аудит №8 у мастера): awk с
  # точным сравнением ключа, снятие \r и парных кавычек
  node_ssh "$1" "cat /etc/x-ui/install-result.env 2>/dev/null" 2>/dev/null \
    | awk -F= -v k="XUI_API_TOKEN" '$1==k { sub(/^[^=]*=/, ""); print; exit }' \
    | tr -d '\r' | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//"
}

node_token_ok() { # $1 rec, $2 cookie -> rc 0 = Bearer принят панелью (openapi.json = 200)
  # как api_token_ok у мастера: 200 = валидный токен (невалидный -> 401,
  # без авторизации -> 404); заодно подтверждает поколение API v3.
  # node_api активирует режим HTTP-кода при НЕ-пустом NODE_API_HTTP_CODE,
  # поэтому маркер "?": он перезапишется реальным кодом curl ("-w").
  local rec="$1" code
  [ -n "$(jq -r '.panel.token // ""' <<<"$rec")" ] || return 1
  NODE_API_HTTP_CODE="?"
  node_api "$rec" "panel/api/openapi.json" GET "" "${2:-}" >/dev/null 2>&1 || true
  code="${NODE_API_HTTP_CODE:-}"
  NODE_API_HTTP_CODE=""
  [ "$code" = "200" ]
}

nodes_load() {
  # битый nodes.json не должен ронять jq у вызывающих и показывать «одиночный
  # сервер» при наличии нод (аудит №11): не массив — считаем нод нет + warn в stderr
  if [ -s "$XKIT_NODES" ] && jq -e 'type=="array"' "$XKIT_NODES" >/dev/null 2>&1; then
    cat "$XKIT_NODES"
  else
    [ -s "$XKIT_NODES" ] && echo -e "${YELLOW}[WARN] nodes.json повреждён (не массив) — считаю, что нод нет; восстановите из бэкапа или переподключите ноды${NC}" >&2
    printf '[]'
  fi
}

nodes_access_export_all() {
  local dir="${XKIT_NODE_ACCESS_DIR:-/root}" rec name tmp expected='' rc=0 old base
  [ -e "$XKIT_NODES" ] || return 0
  jq -e 'type=="array"' "$XKIT_NODES" >/dev/null 2>&1 || { err "Реестр нод повреждён — txt-файлы оставлены без изменений"; return 1; }
  mkdir -p "$dir" && chmod 700 "$dir" || return 1
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    name="$(jq -r '.name // empty' <<<"$rec")"
    [[ "$name" =~ ^[a-zA-Z0-9_-]{1,20}$ ]] || { err "Небезопасное имя ноды в реестре — txt не создан"; rc=1; continue; }
    expected+="${name}"$'\n'
    tmp="$(mktemp "${dir}/.xkit-node-${name}.XXXXXX")" || { rc=1; continue; }
    if ! jq -r '
      "Нода: \(.name)\nАдрес: \(.host)\nSSH: \(.ssh_user // "root")@\(.host):\(.ssh_port // 22)\nSSH-аутентификация: \(.auth // "key")\nSSH-ключ на мастере: \(.key_path // "-")",
      "Панель: \(if .panel.tls == true then "https" else "http" end)://\(.host):\(.panel.port)\(.panel.base // "/")",
      "Логин панели: \(.panel.user // "-")",
      "Пароль панели: \(.panel.pass // "-")",
      "API-токен панели: \(.panel.token // "-")",
      "Туннель: \(.tunnel.proto // "vless")/\(.tunnel.net // "tcp"), порт \(.tunnel.port // "-")",
      "SNI: \(.tunnel.sni // "-")",
      "UUID: \(.tunnel.uuid // "-")",
      "Reality public key: \(.tunnel.pbk // "-")",
      "Reality short ID: \(.tunnel.sid // "-")",
      "Hysteria2 auth: \(.tunnel.auth // "-")",
      "TLS pin: \(.tunnel.tls_pin // "-")"
    ' <<<"$rec" > "$tmp"; then rm -f "$tmp"; rc=1; continue; fi
    chmod 600 "$tmp" && mv -f "$tmp" "${dir}/xkit-node-${name}.txt" || { rm -f "$tmp"; rc=1; }
  done < <(jq -c '.[]' "$XKIT_NODES")
  for old in "$dir"/xkit-node-*.txt; do
    [ -e "$old" ] || continue
    base="$(basename "$old")"; base="${base#xkit-node-}"; base="${base%.txt}"
    grep -Fxq -- "$base" <<<"$expected" || rm -f "$old" || rc=1
  done
  [ "$rc" -eq 0 ] || return "$rc"
  ok "Реквизиты нод обновлены в ${dir}/xkit-node-ИМЯ.txt (0600)"
}

nodes_ensure_pool() {
  if [ -n "${XKIT_POOL_INBOUND:-}" ]; then
    if jq -e --argjson id "${XKIT_POOL_INBOUND:-0}" 'any(.[]; .id==$id)' <<<"$INBOUNDS" >/dev/null 2>&1; then
      XKIT_POOL_TAG="$(jq -r --argjson id "$XKIT_POOL_INBOUND" \
        '[.[]|select(.id==$id)][0].tag // "inbound-pool"' <<<"$INBOUNDS")"
      # early-return ТОЛЬКО если nginx реально знает маршрут pool:
      # после сбоя apply env мог остаться со старым id — тогда пересоздаём,
      # иначе «нода в реестре, но без маршрута» и reapply невозможен
      local pib ppath
      pib="$(jq -c --argjson id "$XKIT_POOL_INBOUND" '[.[]|select(.id==$id)][0]' <<<"$INBOUNDS" 2>/dev/null)"
      ppath="$(jq -r '.streamSettings | (if type=="string" then (fromjson? // {}) else (. // {}) end) | .wsSettings.path // ""' <<<"${pib:-}" 2>/dev/null)"
      if [ -n "$ppath" ] && grep -qF "location ${ppath}" "$XKIT_CONF" 2>/dev/null; then
        return 0
      fi
      warn "Pool-инбаунд #${XKIT_POOL_INBOUND} есть, но маршрута в nginx нет (${ppath:-путь не найден}) — пересоздаю"
    fi
  fi
  local port path uuid subid email settings stream ib
  port="$(rand_free_port 20000 40000)" || { err "Нет свободного порта для pool"; return 1; }
  path="$(auto_path_for ws "$port")"
  uuid="$(new_uuid)"; subid="$(rand_str 16)"; email="pool-$(rand_hex 2)"
  settings="$(jq -nc --arg id "$uuid" --arg email "$email" --arg sub "$subid" '
    {clients:[{id:$id, flow:"", email:$email, limitIp:0, totalGB:0, expiryTime:0,
               enable:true, tgId:"", subId:$sub, reset:0}], decryption:"none", fallbacks:[]}')"
  stream="$(jq -nc --arg p "$path" '{network:"ws", security:"none", wsSettings:{path:$p, headers:{}}}')"
  ib="$(jq -nc --arg port "$port" --arg tag "inbound-${port}" --arg s "$settings" --arg st "$stream" '
    {up:0, down:0, total:0, remark:"xkit-pool", enable:true, expiryTime:0, listen:"127.0.0.1",
     port:($port|tonumber), protocol:"vless", settings:$s, streamSettings:$st,
     sniffing:"{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"]}",
     allocate:"{\"strategy\":\"always\",\"refresh\":5,\"concurrency\":-1}",
     tag:$tag}')"
  api_add_inbound "$ib" || return 1
  local newlist ibid fresh
  newlist="$(api_list)" || return 1
  ibid="$(jq -r --arg t "inbound-${port}" '[.[]|select(.tag==$t)][0].id // empty' <<<"$newlist")"
  [ -n "$ibid" ] || { err "Pool-инбаунд создан, но id не найден"; return 1; }
  fresh="$(api_get_inbound "$ibid")" || true
  if [ "$API_V3" = "1" ]; then
    # v3: externalProxy заменён host-группами; pool за nginx = tls на 443
    v3_host_upsert "$ibid" "$XKIT_HOST" 443 "tls" || \
      warn "host-группа pool не создалась (ссылки в панели покажут 127.0.0.1 — пункт 19 пересоздаст)"
  elif [ -n "$fresh" ]; then
    fresh="$(jq -c --arg d "$XKIT_HOST" '.externalProxy = [{"dest":$d,"port":443,"remark":"xkit"}]' <<<"$fresh")"
    api_update_inbound "$ibid" "$fresh" >/dev/null 2>&1 || true
  fi
  # старый pool мог иметь другой id — осиротевший location /xk-ws-<старый>/ удаляем,
  # иначе nginx продолжает проксировать путь в закрытый порт
  if [ -n "${XKIT_POOL_INBOUND:-}" ] && [ "${XKIT_POOL_INBOUND}" != "$ibid" ]; then
    routes_del "${XKIT_POOL_INBOUND}"
    # сирота в ПАНЕЛИ (аудит №3): раньше чистился только маршрут nginx, а старый
    # pool-инбаунд навсегда оставался в панели — теперь удаляем через API
    if api_del_inbound "${XKIT_POOL_INBOUND}" 2>/dev/null; then
      log "Старый pool-инбаунд #${XKIT_POOL_INBOUND} удалён из панели"
    else
      warn "Старый pool-инбаунд #${XKIT_POOL_INBOUND} НЕ удалён из панели — удалите вручную (Панель -> Inbounds)"
    fi
  fi
  routes_upsert "$ibid" local ws "$path" "127.0.0.1:${port}" "inbound-${port}"
  XKIT_POOL_INBOUND="$ibid"; XKIT_POOL_TAG="inbound-${port}"
  save_xkit_env
  if ! regen_conf_and_apply; then
    err "Конфиг nginx НЕ применился после создания pool — путь ${path} не отвечает."
    err "Полуприменённое состояние: повторите (пункт 2 / xkit route) и проверьте nginx -t."
    err "Pool-инбаунд #${ibid} остаётся в панели: при повторе будет заменён автоматически (старый удалится, если id сменится)."
    return 1
  fi
  ok "Pool-инбаунд #$ibid создан: ws ${path} -> 127.0.0.1:${port} (за nginx)"
  return 0
}

# применяет аутбаунды нод + balancer + observatory к шаблону xray на мастере
# чистая функция (тестируемая): $1 текущий шаблон, $2 путь к nodes.json ИЛИ его
# содержимое (совместимость с тестами; V-03: прод-вызов идёт через tmpfile 600),
# $3 pool_tag, $4 стратегия
nodes_merge_template() {
  command -v python3 >/dev/null 2>&1 || { err "python3 не найден — выполните: apt-get install -y python3"; return 1; }
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys, json, os
tpl = json.loads(sys.argv[1]) if sys.argv[1].strip() else {}
src = sys.argv[2]
# V-03: прод передаёт ПУТЬ к файлу (секреты не в argv); тесты — само содержимое
if os.path.isfile(src):
    # (мелочь №5, аудит v5.2.1): явные with/encoding вместо голого open()
    with open(src, encoding="utf-8") as fh:
        nodes = json.load(fh)
else:
    nodes = json.loads(src)
pool_tag = sys.argv[3]
strategy = sys.argv[4] if sys.argv[4] in ("roundRobin", "random", "leastPing", "leastLoad") else "leastLoad"

outb = tpl.get("outbounds") or []
outb = [o for o in outb if not str(o.get("tag", "")).startswith("node-")]
generated = []
for n in nodes:
    t = n.get("tunnel") or {}
    tag = n.get("outbound_tag") or ("node-" + n.get("name", ""))
    proto = t.get("proto", "vless")
    if proto == "hysteria2":
        if t.get("insecure", False) and not t.get("tls_pin"):
            raise ValueError("Hysteria2: самоподписанный сертификат без tls_pin; повторите profile switch")
        tls = {"serverName": t.get("sni") or n.get("host"), "alpn": ["h3"]}
        if t.get("tls_pin"):
            tls.update({"pinnedPeerCertSha256": t["tls_pin"],
                        "verifyPeerCertByName": t.get("sni") or n.get("host")})
        generated.append({
            "tag": tag, "protocol": "hysteria",
            "settings": {"version": 2, "servers": [{"address": n.get("host"),
                "port": int(t.get("port", 443)), "auth": t.get("auth", "")}]},
            "streamSettings": {"network": "hysteria", "security": "tls", "tlsSettings": tls},
            "mux": {"enabled": False, "concurrency": -1}})
    elif proto == "external" and isinstance(t.get("outbound"), dict):
        # Host-level AWG и другие внешние каналы: только явно сохранённый и
        # проверенный outbound, без выдумывания неподдерживаемого Xray AWG outbound.
        ob = dict(t["outbound"]); ob["tag"] = tag; generated.append(ob)
    else:
        net = t.get("net", "tcp")
        stream = {"network": net, "security": "reality",
                  "realitySettings": {"serverName": t.get("sni", ""),
                                      "fingerprint": "chrome", "publicKey": t.get("pbk", ""),
                                      "shortId": t.get("sid", ""), "spiderX": ""}}
        if net in ("xhttp", "splithttp"):
            stream["xhttpSettings"] = {"path": t.get("path", "/"), "mode": "auto"}
        generated.append({
            "tag": tag, "protocol": "vless",
            "settings": {"vnext": [{"address": n.get("host"), "port": int(t.get("port", 443)),
                                    "users": [{"id": t.get("uuid"), "encryption": "none",
                                               "flow": t.get("flow", "") if net != "tcp" else t.get("flow", "xtls-rprx-vision"),
                                               "level": 0}]}]},
            "streamSettings": stream, "mux": {"enabled": False, "concurrency": -1}})
tpl["outbounds"] = generated + outb

r = tpl.setdefault("routing", {})
rules = r.get("rules") or []
rules = [x for x in rules if x.get("balancerTag") != "XKIT_POOL"]
if pool_tag:
    rules = [x for x in rules if not (x.get("outboundTag") == "direct" and x.get("inboundTag") == [pool_tag]
             and ("geosite:category-ru" in x.get("domain", []) or "geoip:ru" in x.get("ip", [])))]
if pool_tag and nodes:
    rules.insert(0, {"inboundTag": [pool_tag], "domain": ["geosite:category-ru"],
                     "ip": ["geoip:ru"], "outboundTag": "direct"})
    rules.insert(1, {"inboundTag": [pool_tag], "balancerTag": "XKIT_POOL"})
r["rules"] = rules

bal = r.get("balancers") or []
bal = [b for b in bal if b.get("tag") != "XKIT_POOL"]
if nodes:
    bal.append({"tag": "XKIT_POOL", "selector": ["node-"], "strategy": {"type": strategy,
                **({"expected": 1} if strategy == "leastLoad" else {})}})
r["balancers"] = bal

tpl.pop("observatory", None)
tpl.pop("burstObservatory", None)
if nodes and strategy == "leastPing":
    tpl["observatory"] = {"subjectSelector": ["node-"],
                          "probeUrl": "https://www.google.com/generate_204",
                          "probeInterval": "1m", "enableConcurrency": True}
if nodes and strategy == "leastLoad":
    tpl["burstObservatory"] = {"subjectSelector": ["node-"],
                               "pingConfig": {"destination": "https://www.google.com/generate_204",
                                              "connectivity": "http://www.google.com/generate_204",
                                              "interval": "15s", "timeout": "5s", "sampling": 20}}
print(json.dumps(tpl, ensure_ascii=False, separators=(",", ":")))
PY
}

nodes_apply_template() {
  load_xkit_env || return 1
  [ -n "${PANEL_PORT:-}" ] || kit_session || return 1
  local nodes_json; nodes_json="$(nodes_load)"
  local cur merged
  cur="$(master_xray_template_get)" || return 1
  jq -e . <<<"$cur" >/dev/null 2>&1 || cur="{}"
  # V-03 (аудит №2): nodes.json (пароли панелей нод, UUID) — через tmpfile 600,
  # НЕ аргументом в python3 (виден через ps/proc)
  local nodes_file; nodes_file="$(mktemp /tmp/.xkit-nodes.XXXXXX)" || return 1
  chmod 600 "$nodes_file" 2>/dev/null || true
  printf '%s' "$nodes_json" > "$nodes_file"
  local mrc=0
  merged="$(nodes_merge_template "$cur" "$nodes_file" "${XKIT_POOL_TAG:-}" "${XKIT_BAL_STRATEGY:-leastLoad}")" || mrc=$?
  rm -f "$nodes_file"
  [ "$mrc" -eq 0 ] || { err "Не удалось собрать шаблон xray"; return 1; }
  master_xray_template_set "$merged"
}

# скан подсети С САМОЙ НОДЫ (кандидаты видны из её сети/гео); результат в RDEST / RSNI
node_reality_scan_pick() { # $1 rec ноды
  local rec="$1" t tlist
  local out="${XKIT_DIR}/reality-scan-node.tsv"
  mkdir -p "$XKIT_DIR" 2>/dev/null || true
  read -r -p "Что сканируем С НОДЫ? CIDR/список через пробел (Enter = /24 самой ноды) -> " t
  tlist=""
  if [ -n "$t" ]; then
    tlist="$(reality_expand_targets "$t")"
    case "$tlist" in ERR:*) err "$tlist"; return 1 ;; esac
  fi
  log "Сканирую с ноды: TCP :443 (50 потоков) -> TLS-детали..."
  # V-01 (аудит №2): список целей уходит на ноду base64'ом (вне shell-строки);
  # токены уже валидированы в reality_expand_targets — двойной барьер
  local tb64; tb64="$(printf '%s' "$tlist" | base64 -w0)"
  node_ssh "$rec" "TARGETS_B64='${tb64}' bash -s" > "$out" <<'EOS' || true
TARGETS=""
[ -n "${TARGETS_B64:-}" ] && TARGETS="$(printf '%s' "$TARGETS_B64" | base64 -d)"
probe() { timeout 2 bash -c 'exec 3<>/dev/tcp/"$1"/443' _ "$1" 2>/dev/null && echo "$1"; }
export -f probe
TMP="$(mktemp)"; OPEN="$(mktemp)"
trap 'rm -f "$TMP" "$OPEN"' EXIT INT TERM   # чистка даже при обрыве SSH-сессии
if [ -n "${TARGETS:-}" ]; then printf '%s\n' "$TARGETS" | grep -v '^$' > "$TMP"; else
  P="$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null | awk -F. '{print $1"."$2"."$3}')"
  [ -n "$P" ] || { echo "ERR: не удалось определить IP ноды"; exit 1; }
  i=1; while [ "$i" -le 254 ]; do echo "$P.$i"; i=$((i+1)); done > "$TMP"
fi
xargs -a "$TMP" -P 50 -n 1 probe >> "$OPEN" 2>/dev/null || true
while IFS= read -r ip; do
  [ -z "$ip" ] && continue
  brief="$(echo | timeout 6 openssl s_client -brief -connect "${ip}:443" -servername "${ip}" 2>&1)"
  t13=no;  grep -q "TLSv1.3" <<<"$brief" && t13=yes
  h2=no;   grep -qi "ALPN protocol: *h2" <<<"$brief" && h2=yes
  x2=no;   grep -q "X25519" <<<"$brief" && x2=yes
  cert="$(echo | timeout 6 openssl s_client -connect "${ip}:443" -servername "${ip}" 2>/dev/null \
          | openssl x509 -noout -subject -issuer -ext subjectAltName -enddate 2>/dev/null)"
  cn="$(sed -n 's/^subject=.*CN *= *//p' <<<"$cert" | head -n1 | cut -d, -f1 | tr -d ' ')"
  san="$(awk '/^X509v3 Subject Alternative Name:/{getline; sub(/^ +/,""); print; exit}' <<<"$cert" \
         | sed 's/DNS://g' | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^\*' | head -n1)"
  [ -n "$san" ] || san="$cn"
  issuer="$(sed -n 's/^issuer=.*CN *= *//p' <<<"$cert" | head -n1 | cut -d, -f1 | tr -d ' ')"
  end="$(sed -n 's/^notAfter=//p' <<<"$cert" | head -n1)"
  vrf_out="$(echo | timeout 6 openssl s_client -connect "${ip}:443" -servername "${ip}" 2>&1)"
  notvalid=yes
  if grep -q 'Verify return code: 0 (ok)' <<<"$vrf_out" \
     || grep -qE 'Verify return code: 0[[:space:]]*$' <<<"$vrf_out"; then
    notvalid=no
  fi
  verdict="НЕТ"
  if [ "$t13" = "yes" ] && [ "$notvalid" = "no" ] && { [ -n "$san" ] || [ -n "$cn" ]; }; then
    verdict="ДА"; [ "$h2" = "yes" ] && [ "$x2" = "yes" ] && verdict="ДА+"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$ip" "$t13" "$h2" "$x2" "$notvalid" "${cn:--}" "${san:--}" "${end:--}" "$verdict"
done < "$OPEN"
rm -f "$TMP" "$OPEN"
EOS
  [ -s "$out" ] || { warn "Нода: ни один адрес не ответил на :443 (или SSH-сессия оборвалась)"; return 1; }
  grep -q '^ERR:' "$out" && { err "$(head -n1 "$out")"; return 1; }
  reality_scan_choose "$out"
}

# (7.4.0, переустановка): состояние 3X-UI на ноде ДО установки — чтобы не
# оставлять «куски» прежней попытки (отменили установку на полпути, панель
# осталась, инсталлятор падал и т.п.). none — чистый сервер; panel — рабочая
# панель; leftovers — остатки без рабочего бинарника/юнита.
node_xui_detect() { # $1 rec -> stdout: none|panel|leftovers
  local rec="$1" st
  st="$(node_ssh "$rec" 'bash -s' <<'EOS' 2>/dev/null || true
alive=0
if [ -x /usr/local/x-ui/x-ui ] && /usr/local/x-ui/x-ui -v >/dev/null 2>&1; then alive=1; fi
if [ "$alive" = 1 ]; then echo panel; exit 0; fi
if [ -f /etc/systemd/system/x-ui.service ] || [ -d /usr/local/x-ui ] || [ -d /etc/x-ui ] || command -v x-ui >/dev/null 2>&1; then
  echo leftovers
else
  echo none
fi
EOS
)"
  st="$(tail -n1 <<<"$st" 2>/dev/null | tr -d '[:space:]')"
  case "$st" in panel|leftovers) printf '%s' "$st" ;; *) printf 'none' ;; esac
}

# Снос прежней установки 3X-UI на ноде. Прежняя БД (клиенты/настройки) уезжает
# в /root/x-ui-backup-<ts>.tar.gz — переустановка не значит «потерять данные
# молча»; после чистки нода в состоянии none.
node_xui_purge() { # $1 rec -> 0/1
  local rec="$1" ts; ts="$(date +%Y%m%d-%H%M%S)"
  log "Снимаю прежнюю установку 3X-UI с ноды (старая БД -> /root/x-ui-backup-${ts}.tar.gz)..."
  node_ssh "$rec" "bash -s" <<EOS || { err "Не удалось очистить ноду от прежней установки 3X-UI"; return 1; }
systemctl stop x-ui >/dev/null 2>&1 || true
systemctl disable x-ui >/dev/null 2>&1 || true
if [ -d /etc/x-ui ]; then tar -czf /root/x-ui-backup-${ts}.tar.gz -C / etc/x-ui 2>/dev/null || true; chmod 600 /root/x-ui-backup-${ts}.tar.gz 2>/dev/null || true; fi
rm -rf /usr/local/x-ui /etc/x-ui /usr/bin/x-ui /etc/systemd/system/x-ui.service
systemctl daemon-reload >/dev/null 2>&1 || true
echo PURGED
EOS
  ok "Прежняя установка 3X-UI удалена (бэкап старой БД: /root/x-ui-backup-${ts}.tar.gz)"
}

# Проекция ноды в родной раздел «Узлы» мастер-панели. Импорт инбаундов
# всегда выключен явно: selected + пустой список; outbound XKIT не трогаем.
node_panel_sync() { # $1 имя ноды
  load_xkit_env || die "Сначала установка (пункт 1)"
  local n="${1:-}" rec tok scheme pin id path body resp
  [ -n "$n" ] || { err "xkit nodes panel-sync <имя|all>"; return 1; }
  if [ "$n" = all ]; then
    local nn rc=0
    while IFS= read -r nn; do [ -z "$nn" ] || node_panel_sync "$nn" || rc=1; done < <(nodes_load | jq -r '.[].name')
    return "$rc"
  fi
  rec="$(nodes_load | jq -c --arg n "$n" '[.[]|select(.name==$n)][0] // empty')"
  [ -n "$rec" ] || { err "Нода '$n' не найдена"; return 1; }
  tok="$(jq -r '.panel.token // empty' <<<"$rec")"
  [ -n "$tok" ] || { err "${n}: нет API-токена; выполните xkit nodes relogin ${n}"; return 1; }
  scheme="http"; [ "$(jq -r '.panel.tls // false' <<<"$rec")" = "true" ] && scheme="https"
  pin="$(jq -r '.panel.pincert // empty' <<<"$rec")"
  if [ "$scheme" = "https" ] && [ -z "$pin" ]; then
    err "${n}: для HTTPS нужен certificate pin (xkit nodes repin ${n})"; return 1
  fi
  kit_session || { err "Нет сессии мастер-панели"; return 1; }
  id="$(jq -r '.panel_node_id // empty' <<<"$rec")"
  path="panel/api/nodes/add"; [ -n "$id" ] && path="panel/api/nodes/update/${id}"
  body="$(jq -nc --arg name "$n" --arg host "$(jq -r '.host' <<<"$rec")" \
    --argjson port "$(jq -r '.panel.port' <<<"$rec")" --arg base "$(jq -r '.panel.base // "/"' <<<"$rec")" \
    --arg token "$tok" --arg scheme "$scheme" --arg pin "$pin" \
    '{name:$name,remark:"XKIT",scheme:$scheme,address:$host,port:$port,basePath:$base,
      apiToken:$token,enable:true,allowPrivateAddress:true,
      tlsVerifyMode:(if $scheme=="https" then "pin" else "verify" end),pinnedCertSha256:$pin,
      inboundSyncMode:"selected",inboundTags:[],outboundTag:""}')"
  resp="$(api_post_json "$path" "$body")" || { err "${n}: мастер-панель не приняла ноду"; return 1; }
  jq -e '.success == true' <<<"$resp" >/dev/null 2>&1 || {
    err "${n}: $(jq -r '.msg // "ошибка регистрации в разделе Узлы"' <<<"$resp")"; return 1;
  }
  if [ -z "$id" ]; then
    id="$(jq -r '.obj.id // empty' <<<"$resp")"
    [[ "$id" =~ ^[0-9]+$ ]] || { err "${n}: панель не вернула ID ноды"; return 1; }
    nodes_load | jq -c --arg n "$n" --argjson id "$id" \
      'map(if .name==$n then .panel_node_id=$id else . end)' > "${XKIT_NODES}.tmp" \
      && mv "${XKIT_NODES}.tmp" "$XKIT_NODES" && chmod 600 "$XKIT_NODES" || return 1
  fi
  ok "${n}: добавлена/обновлена в «Узлах» 3X-UI; импорт инбаундов отключён"
}

node_reconnect_one() { # $1 record: SSH чинит только доступ нового мастера к панели
  local rec="$1" n myip pp
  n="$(jq -r '.name' <<<"$rec")"
  node_ssh "$rec" true || { err "${n}: SSH недоступен; нода оставлена в реестре без изменений"; return 1; }
  myip="$(pubip)"; pp="$(jq -r '.panel.port' <<<"$rec")"
  is_port "$pp" || { err "${n}: некорректный порт панели в реестре"; return 1; }
  if is_ip "$myip" && node_ssh "$rec" "command -v ufw >/dev/null && ufw status | grep -q '^Status: active'"; then
    node_ssh "$rec" "ufw allow from '${myip}' to any port '${pp}' proto tcp comment 'XKIT:node-panel'" \
      || { err "${n}: не удалось разрешить новый IP мастера в UFW"; return 1; }
  fi
  local ck; ck="$(mktemp /tmp/.xkit-node-ck.XXXXXX)" || return 1
  if ! node_login "$rec" "$ck"; then rm -f "$ck"; err "${n}: API панели недоступен после SSH-проверки"; return 1; fi
  local resp; resp="$(node_api "$rec" panel/api/inbounds/list GET "" "$ck")"
  if ! jq -e '.success == true' <<<"$resp" >/dev/null 2>&1; then
    rm -f "$ck"; err "${n}: API панели не ответил после SSH-проверки"; return 1
  fi
  rm -f "$ck"; ok "${n}: существующая панель и туннель переподключены без переустановки"
}

node_reconnect_existing() {
  local n="$1" rec; rec="$(node_record "$n")"; [ -n "$rec" ] || return 1
  node_reconnect_one "$rec" || return 1
  nodes_repair || return 1
  node_panel_sync "$n" || warn "${n}: повторите xkit nodes panel-sync ${n}"
  nodes_metrics_collect "$n" >/dev/null 2>&1 || true
}

nodes_restore_reconnect() {
  local n rc=0
  while IFS= read -r n; do [ -z "$n" ] || node_reconnect_one "$(node_record "$n")" || rc=1; done < <(nodes_load | jq -r '.[].name')
  nodes_repair || rc=1
  node_panel_sync all || warn "Синхронизацию с «Узлами» 3X-UI можно повторить позже"
  nodes_metrics_collect >/dev/null 2>&1 || true
  return "$rc"
}

node_add() {
  require_root
  command -v ssh >/dev/null 2>&1 || apt-get install -y -qq openssh-client >/dev/null 2>&1
  load_xkit_env || die "Сначала установка (пункт 1)"
  kit_session || return 1

  echo ""
  echo -e "${YELLOW}=== Добавление ноды (зарубежный сервер) ===${NC}"
  local nname nhost nport nuser
  # EOF (Ctrl-D) на любом вводе — отмена, а не молчаливое продолжение
  # (симметрия с v3.2.1, ревью v4.7.0: на порту/юзере EOF давал дефолты
  # 22/root и попытку коннекта к ноде)
  read -r -p "Имя ноды (латиница, например de1): " nname || { echo; return 1; }
  [[ "$nname" =~ ^[a-zA-Z0-9_-]{1,20}$ ]] || { err "Имя: латиница/цифры/-/_ до 20 символов"; return 1; }
  if jq -e --arg n "$nname" 'any(.[]; .name==$n)' <(nodes_load) >/dev/null 2>&1; then
    confirm "Нода '$nname' уже есть. Переподключить без переустановки? [Y/n] " y && node_reconnect_existing "$nname"
    return $?
  fi
  nhost="$(read_host "IP/домен ноды -> ")"
  local existing_name; existing_name="$(nodes_load | jq -r --arg h "$nhost" '[.[]|select(.host==$h)][0].name // empty')"
  if [ -n "$existing_name" ]; then
    confirm "Этот адрес уже записан как '$existing_name'. Переподключить без нового туннеля? [Y/n] " y && node_reconnect_existing "$existing_name"
    return $?
  fi
  read -r -p "SSH порт [22]: " nport || { echo; return 1; }
  nport="${nport:-22}"; is_port "$nport" || { err "Порт"; return 1; }
  read -r -p "SSH пользователь [root]: " nuser || { echo; return 1; }
  nuser="${nuser:-root}"
  # аудит №4: без валидации «a"b» уезжало в ssh/jq-реестр; допускаем то, что
  # легитимно для useradd: латиница/цифры/._-, не с цифры, до 32 символов
  [[ "$nuser" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]{0,31}$ ]] || { err "SSH-пользователь: только латиница/цифры/._- (до 32 симв., не с цифры)"; return 1; }

  echo "Доступ: 1) пароль (один раз — поставим наш SSH-ключ, пароль не сохраняется)  2) путь к ключу"
  read -r -p "Выбор [1]: " am || { echo; return 1; }
  am="${am:-1}"
  local NODE_SSH_PASS="" nkey=""
  local rec_auth="key"
  if [ "$am" = "1" ]; then
    # v7.2.6: sshpass проверяем ДО чтения пароля — иначе «sshpass не найден»
    # глушился 2>/dev/null тихой проверки и выглядел как «пароль не подошёл».
    # v7.2.9: не просто ошибка, а автоустановка (apt) — на чистом сервере
    # пользователь не обязан ставить пакет руками (репродукция 7.2.8:
    # добавление ноды обрывалось здесь, затем падал pause_enter).
    node_ensure_sshpass || return 1
    read -r -s -p "SSH пароль ${nuser}@${nhost}: " NODE_SSH_PASS || { echo; return 1; }
    echo ""
    [ -n "$NODE_SSH_PASS" ] || { err "Пустой пароль"; return 1; }
    rec_auth="password"
    nkey="$(node_own_key)"
  else
    nkey="$(node_own_key)"
    read -r -p "Путь к приватному ключу [${nkey}]: " nkey_in || { echo; return 1; }
    [ -n "$nkey_in" ] && nkey="$nkey_in"
    [ -f "$nkey" ] || { err "Ключ не найден: $nkey"; return 1; }
  fi

  local rec
  rec="$(jq -nc --arg n "$nname" --arg h "$nhost" --argjson p "$nport" --arg u "$nuser" \
         --arg a "$rec_auth" --arg k "$nkey" \
    '{name:$n, host:$h, ssh_port:$p, ssh_user:$u, auth:$a, key_path:$k}')"

  # v7.2.6 (живой баг: «после ввода пароля терминал молчит, потом "пароль не подошёл"»):
  # TOFU-подтверждение отпечатка хоста срабатывало ВНУТРИ первой тихой проверки
  # (node_ssh … 2>/dev/null | grep -q ok): warn/confirm пишут в stderr и были
  # НЕВИДИМЫ — терминал молчал (keyscan до 15 c), пустой Enter на невидимом
  # «[y/N]» = отказ -> ложное «SSH по паролю не прошёл» (пароль не проверялся).
  # Ключ хоста подтверждаем ЯВНО и ВИДИМО до тихих проверок (запись попадает в
  # known_hosts — повторный вызов внутри node_ssh проходит мгновенно).
  # nodes readdress уже делал TOFU видимым — не сломан.
  log "Снимаю отпечаток ключа ${nhost}:${nport} (до 15 сек)..."
  node_ssh_host_key "$nhost" "$nport" "${XKIT_DIR}/known_hosts" \
    || { err "Ключ хоста ${nhost}:${nport} не подтверждён — нода не добавлена"; return 1; }

  log "Проверяю SSH-доступ..."
  if [ "$rec_auth" = "password" ]; then
    local ssh_check ssh_rc
    ssh_check="$(node_ssh "$rec" "echo ok" 2>&1)"; ssh_rc=$?
    if { [ "$ssh_rc" -ne 0 ] || ! grep -q ok <<<"$ssh_check"; } \
      && grep -q 'Host key verification failed' <<<"$ssh_check"; then
      node_ssh_host_key_refresh "$nhost" "$nport" "${XKIT_DIR}/known_hosts" || return 1
      ssh_check="$(node_ssh "$rec" "echo ok" 2>&1)"; ssh_rc=$?
    fi
    if [ "$ssh_rc" -ne 0 ] || ! grep -q ok <<<"$ssh_check"; then
      err "SSH по паролю не прошёл — проверьте реквизиты ${nuser}@${nhost}:${nport}"
      [ -z "$ssh_check" ] || { echo "Ответ SSH:"; tail -n 8 <<<"$ssh_check"; } >&2
      grep -qi 'Permission denied' <<<"$ssh_check" \
        && warn "Сервер отклонил вход: пароль не принят или вход root по паролю запрещён (PermitRootLogin/PasswordAuthentication)"
      return 1
    fi
    local pub; pub="$(cat "${nkey}.pub")"
    node_ssh "$rec" "mkdir -p ~/.ssh && chmod 700 ~/.ssh; grep -qF '$pub' ~/.ssh/authorized_keys 2>/dev/null || echo '$pub' >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys" \
      || { err "Не удалось установить ключ на ноде"; return 1; }
    rec="$(jq -c --arg k "$nkey" '.auth="key" | .key_path=$k' <<<"$rec")"
    ok "Наш ключ установлен на ноде — пароль больше не нужен (и не сохранён)"
  fi
  node_ssh "$rec" "echo ok" 2>/dev/null | grep -q ok || { err "SSH по ключу не прошёл — проверьте ключ и реквизиты ${nuser}@${nhost}:${nport}"; return 1; }
  local kh; kh="${XKIT_DIR}/known_hosts"
  local fp; fp="$(awk -v h="[$nhost]:$nport" -v h2="$nhost" '$3==h || $3==h2 {print}' "$kh" 2>/dev/null \
    | ssh-keygen -lf - 2>/dev/null | head -n1 | awk '{print $2, $4}')"
  [ -n "$fp" ] && ok "Ключ хоста ноды зафиксирован (TOFU; можно сверить с консолью провайдера): ${fp}"

  # (7.4.0, переустановка + минимум вопросов): чистый сервер ставим БЕЗ вопроса
  # (з.6 аудита v5.2.1 о root-установщике закрыт тем, что добавление ноды —
  # это и есть установка; приглашение осталось в XKIT_YES-совместимом виде).
  # Если на ноде уже панель или куски прежней попытки — спрашиваем, что делать.
  local _xui_state _need_install=0 _ra
  _xui_state="$(node_xui_detect "$rec")"
  case "$_xui_state" in
    none) _need_install=1 ;;
    panel)
      warn "На ноде ${nhost} уже установлена рабочая панель 3X-UI."
      echo "  1) Подключить сервер к существующей панели (новые доступы, inbound сохранятся)"
      echo "  2) Переустановить панель (прежние настройки сохранятся в резервной копии)"
      read -r -p "Что делать? [1]: " _ra || { echo; return 1; }
      _ra="${_ra:-1}"
      if [ "$_ra" = "2" ]; then
        node_xui_purge "$rec" || return 1
        _need_install=1
      else
        ok "Использую существующую панель — реквизиты будут заменены на новые (случайные)"
      fi ;;
    leftovers)
      warn "На ноде ${nhost} найдены куски прежней установки 3X-UI (рабочей панели нет)."
      echo "  1) Очистить и поставить заново (рекомендуется)"
      echo "  2) Отменить добавление сервера"
      read -r -p "Что делать? [1]: " _ra || { echo; return 1; }
      _ra="${_ra:-1}"
      [ "$_ra" = "1" ] || { warn "Добавление ноды отменено — куски прежней установки не тронуты"; return 1; }
      node_xui_purge "$rec" || return 1
      _need_install=1 ;;
  esac
  if [ "$_need_install" = "1" ]; then
  log "Устанавливаю 3X-UI на ноду (официальный установщик, от root)..."
  # K-02: тот же тег-релиз, что и на мастере; URL валидирован в xui_install_url
  local xuiu; xuiu="$(xui_install_url)"
  node_ssh "$rec" "XUI_URL='${xuiu}' bash -s" <<'EOS' || { err "Установка 3X-UI на ноде не удалась"; return 1; }
export DEBIAN_FRONTEND=noninteractive
# (баг, найден при проверке установки ноды 7.4.0): sqlite3 ставился ТОЛЬКО вместе
# с curl — если curl уже есть, а sqlite3 CLI нет (типичный Ubuntu 24.04), вставка
# самоподписанного серта в x-ui.db молча пропускалась и панель оставалась на HTTP
miss=""
for b in curl sqlite3; do command -v "$b" >/dev/null 2>&1 || miss="$miss $b"; done
[ -z "$miss" ] || { apt-get update -qq >/dev/null 2>&1 || true; apt-get install -y -qq $miss >/dev/null 2>&1; }
if ! command -v x-ui >/dev/null 2>&1; then
  DL="$(mktemp)"
  curl -fsSL "${XUI_URL:?}" -o "$DL" \
    || { echo "ERR: не удалось скачать установщик 3X-UI"; rm -f "$DL"; exit 1; }
  bash -n "$DL" || { echo "ERR: установщик 3X-UI не проходит bash -n (K-02)"; rm -f "$DL"; exit 1; }
  XUI_NONINTERACTIVE=1 bash "$DL" </dev/null
  rm -f "$DL"
fi
systemctl enable --now x-ui >/dev/null 2>&1 || true
EOS
  fi

  local np_user np_pass np_port
  # (7.4.0): логин панели ноды — случайные 10 символов [a-z0-9]; раньше было
  # «kit»+2 hex (256 вариантов и палевный префикс «kit»)
  np_user="$(rand_str 10 | tr 'A-Z' 'a-z')"
  np_pass="$(rand_str 32)"
  np_port="$(shuf -i 20000-50000 -n 1)"
  log "Настраиваю панель ноды (случайный логин/пароль/порт)..."
  node_ssh "$rec" "/usr/local/x-ui/x-ui setting -username '${np_user}' -password '${np_pass}' -port '${np_port}' >/dev/null 2>&1 || /usr/local/x-ui/x-ui setting -username '${np_user}' -password '${np_pass}' >/dev/null 2>&1" \
    || { err "3X-UI на ноде не принял новые реквизиты — нода не добавлена"; return 1; }
  node_ssh "$rec" "systemctl restart x-ui" \
    || { err "Панель ноды не перезапустилась после смены реквизитов"; return 1; }
  log "Включаю HTTPS (самоподписанный сертификат) для панели ноды — креды не пойдут по HTTP..."
  node_ssh "$rec" 'bash -s' <<'EOS' || warn "HTTPS панели ноды не включился — останется HTTP"
C=/etc/x-ui/panel-cert.pem; K=/etc/x-ui/panel-key.pem
if [ ! -s "$C" ] || [ ! -s "$K" ]; then
  openssl ecparam -name prime256v1 -genkey -noout -out "$K" 2>/dev/null \
    && openssl req -new -x509 -key "$K" -out "$C" -days 3650 \
       -subj "/CN=node-panel" -addext "subjectAltName=IP:127.0.0.1" 2>/dev/null
  chmod 600 "$K" 2>/dev/null; chmod 644 "$C" 2>/dev/null
fi
if [ -s "$C" ] && [ -s "$K" ] && command -v sqlite3 >/dev/null 2>&1; then
  for kv in "webCertFile|$C" "webKeyFile|$K"; do
    key="${kv%%|*}"; val="${kv#*|}"
    sqlite3 /etc/x-ui/x-ui.db \
      "UPDATE settings SET value='$val' WHERE key='$key'; INSERT INTO settings(key,value) SELECT '$key','$val' WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key='$key');"
  done
  systemctl restart x-ui
else
  # (баг 7.4.0): раньше этот пропуск был МОЛЧАЛИВЫМ — WARN про HTTP появлялся
  # только позже, при логине, и выглядел загадочно
  echo "WARN: сертификат панели не применён (нет openssl-файлов или sqlite3) — панель останется на HTTP"
fi
EOS
  # (7.4.1, живой лог 7.4.0): после restart панель поднимается не мгновенно
  # (миграции БД, fail2ban, первый старт) — фиксированного sleep 3 не хватало:
  # API-токен и HTTPS-логин падали «вхолостую» и мастер оставался на HTTP+CSRF.
  # Ждём готовности порта на самой ноде (до 40 сек), с запасом — ретрай логина.
  log "Жду готовности панели ноды (порт ${np_port}, до 40 сек)..."
  node_ssh "$rec" "PORT='${np_port}' bash -s" <<'EOS' || warn "Панель ноды так и не поднялась на порту ${np_port} за 40 сек — продолжаю"
for i in $(seq 1 20); do
  if (exec 3<>/dev/tcp/127.0.0.1/"$PORT") 2>/dev/null; then exit 0; fi
  sleep 2
done
exit 1
EOS
  local nbase
  nbase="$(node_ssh "$rec" "/usr/local/x-ui/x-ui setting -show true 2>/dev/null" \
           | awk -F': ' '/webBasePath/{print $2; exit}' | tr -d '[:space:]')"
  nbase="$(normalize_panel_path "${nbase:-/}")"
  rec="$(jq -c --argjson pp "$np_port" --arg u "$np_user" --arg p "$np_pass" --arg b "$nbase" \
        '.panel = {port:$pp, user:$u, pass:$p, base:$b, tls:true}' <<<"$rec")"
  # v7.2.11: авто-сбор API-токена панели ноды (3X-UI v3.11+ пишет XUI_API_TOKEN
  # в /etc/x-ui/install-result.env): Bearer-путь node_api не зависит от пароля
  # и CSRF — то, что у мастера с v7.2.5, но автоматом. Верифицируем живой
  # панелью (openapi.json = 200); не прошёл — тихий фолбэк на логин+cookie
  # (панели без токена, v2, ротированный токен после переустановки).
  local ntok
  ntok="$(node_token_fetch "$rec")"
  if [ -n "$ntok" ]; then
    local trec tck
    trec="$(jq -c --arg t "$ntok" '.panel.token = $t' <<<"$rec")"
    tck="$(mktemp /tmp/.xkit-node-ck.XXXXXX)"
    # (7.4.1): один ретрай токена через 5 сек — панели v3.11 после restart
    # отвечают openapi.json не сразу
    if ! node_token_ok "$trec" "$tck"; then
      sleep 5; node_token_ok "$trec" "$tck" || trec=""
    fi
    if [ -n "$trec" ]; then
      rec="$trec"
      ok "API-токен панели ноды принят (Bearer) — для API логин по паролю не нужен"
    else
      warn "API-токен панели ноды не прошёл проверку — останусь на логине+CSRF"
    fi
    rm -f "$tck"
  fi
  local ck; ck="$(mktemp /tmp/.xkit-node-ck.XXXXXX)"
  if ! node_login "$rec" "$ck"; then
    # (7.4.1): ретрай HTTPS через 5 сек — рестарт с новым сертом мог не успеть
    sleep 5
    if ! node_login "$rec" "$ck"; then
      warn "Логин по HTTPS не прошёл — пробую HTTP (сертификат панели не применился?)"
      rec="$(jq -c '.panel.tls = false' <<<"$rec")"
      node_login "$rec" "$ck" || { err "Логин в панель ноды (порт ${np_port}${nbase}) не прошёл"; rm -f "$ck"; return 1; }
    fi
  fi
  local psch="http"; jq -e '.panel.tls == true' <<<"$rec" >/dev/null 2>&1 && psch="https"
  ok "Панель ноды: ${psch}://${nhost}:${np_port}${nbase}"
  if [ "$psch" = "https" ]; then
    local npin
    npin="$(cert_pin "$nhost" "$np_port")"
    if [ -n "$npin" ]; then
      rec="$(jq -c --arg p "$npin" '.panel.pincert = $p' <<<"$rec")"
      ok "Сертификат панели ноды запинен (sha256//$(printf '%s' "$npin" | head -c 16)...) — MITM на API не пройдёт"
    else
      warn "Не удалось снять пин сертификата панели — node_api будет без пина (перепинить: xkit nodes repin ${nname})"
    fi
  fi

  # (7.4.0, минимум вопросов): порт туннеля больше не спрашиваем — это
  # внутренняя кухня каскада, туда ходит только мастер. Выбираем автоматически:
  # случайный порт 20000-50000, проверка ss на ноде (до 8 попыток); всё занято —
  # 443, если свободен; иначе отказ. С camo/nginx (порт 80) не конфликтует.
  local tport="" _cand _try
  for _try in 1 2 3 4 5 6 7 8; do
    _cand="$(shuf -i 20000-50000 -n 1)"
    if node_ssh "$rec" "ss -ltn 2>/dev/null | grep -q ':${_cand} '" 2>/dev/null; then
      continue
    fi
    tport="$_cand"; break
  done
  if [ -z "$tport" ]; then
    if node_ssh "$rec" "ss -ltn 2>/dev/null | grep -q ':443 '" 2>/dev/null; then
      err "Не нашёл свободного порта для туннеля на ноде — повторите добавление ноды"
      return 1
    fi
    tport=443
  fi
  ok "Порт туннеля на ноде: ${tport} (выбран автоматически, случайный — туда ходит только мастер)"

  # (7.4.0, минимум вопросов): Dest (прикрытие) Reality на ноде больше не
  # спрашиваем — это внутренняя кухня каскада, а не пользовательский выбор.
  # Автоматически: как на мастере (единая маскировка кластера), иначе 1.1.1.1.
  # Полное ручное меню остаётся для особых случаев: XKIT_NODE_DEST_MENU=1.
  local mdest msni
  mdest="$(jq -r '[.[]|select(.streamSettings|fromjson?|.security? == "reality")][0].streamSettings|fromjson?|.realitySettings.dest // ""' <<<"${INBOUNDS:-[]}" 2>/dev/null)"
  msni="$(jq -r '[.[]|select(.streamSettings|fromjson?|.security? == "reality")][0].streamSettings|fromjson?|.realitySettings.serverNames[0] // ""' <<<"${INBOUNDS:-[]}" 2>/dev/null)"
  local ndest="" nsni="" RDEST="" RSNI="" dc=""
  if [ "${XKIT_NODE_DEST_MENU:-0}" = "1" ]; then
    echo "Dest (прикрытие) для Reality на ноде:"
    echo "  1) 1.1.1.1 (быстро и надёжно)   2) известный список   3) ПОИСК С ДОПОЛНИТЕЛЬНОГО СЕРВЕРА"
    if [ -n "$mdest" ] && [ -n "$msni" ]; then
      echo "  4) как на мастере (${mdest}, SNI ${msni})"
    else
      echo "  4) как на мастере (на мастере Reality-инбаунд не найден — недоступно)"
    fi
    echo "  5) вручную"
    read -r -p "Выбор [1]: " dc; dc="${dc:-1}"
    case "$dc" in
      2) reality_known_pick || return 1; ndest="$RDEST"; nsni="$RSNI" ;;
      3) node_reality_scan_pick "$rec" || return 1; ndest="$RDEST"; nsni="$RSNI" ;;
      4) [ -n "$mdest" ] && [ -n "$msni" ] || { err "На мастере нет Reality — выберите другой вариант"; return 1; }
         ndest="$mdest"; nsni="$msni" ;;
      5)
        local dh dp
        dh="$(read_host "dest -> ")"
        read -r -p "Порт dest [443]: " dp; dp="${dp:-443}"; is_port "$dp" || { err "Порт"; return 1; }
        nsni="$(read_host "SNI -> ")"
        ndest="${dh}:${dp}" ;;
      *) ndest="1.1.1.1:443"; nsni="cloudflare-dns.com" ;;
    esac
  elif [ -n "${XKIT_NODE_DEST:-}" ]; then
    # точечный override окружением: XKIT_NODE_DEST=host:port [XKIT_NODE_SNI=...]
    ndest="$XKIT_NODE_DEST"; nsni="${XKIT_NODE_SNI:-}"
    [[ "$ndest" == *:* ]] || ndest="${ndest}:443"
    [ -n "$nsni" ] || nsni="${ndest%%:*}"
    ok "Dest задан окружением: ${ndest} (SNI ${nsni})"
  elif [ -n "$mdest" ] && [ -n "$msni" ]; then
    ndest="$mdest"; nsni="$msni"
    ok "Dest Reality на ноде: как на мастере — ${ndest} (SNI ${nsni}) — единая маскировка кластера"
  else
    ndest="1.1.1.1:443"; nsni="cloudflare-dns.com"
    ok "Dest Reality на ноде: ${ndest} (SNI ${nsni}) — на мастере Reality-прикрытие не найдено, беру надёжный дефолт"
  fi

  log "Генерирую ключи Reality для ноды..."
  local priv="" pub tuuid tsid existing_resp existing_ib existing_tunnel=0
  existing_resp="$(node_api "$rec" panel/api/inbounds/list GET "" "$ck")" \
    || { err "Не удалось прочитать инбаунды ноды — новый туннель не создаю"; rm -f "$ck"; return 1; }
  jq -e '.success == true and (.obj|type=="array")' <<<"$existing_resp" >/dev/null 2>&1 \
    || { err "Панель ноды не вернула список инбаундов — новый туннель не создаю"; rm -f "$ck"; return 1; }
  existing_ib="$(jq -c --arg remark "xkit-tunnel-${nname}" '[.obj[]|select(.remark==$remark and .protocol=="vless")][0] // empty' <<<"$existing_resp")"
  if [ -n "$existing_ib" ]; then
    existing_tunnel=1; tport="$(jq -r '.port' <<<"$existing_ib")"
    tuuid="$(jq -r '.settings|if type=="string" then (fromjson? // {}) else . end|.clients[0].id // ""' <<<"$existing_ib")"
    pub="$(jq -r '.streamSettings|if type=="string" then (fromjson? // {}) else . end|.realitySettings.settings.publicKey // ""' <<<"$existing_ib")"
    tsid="$(jq -r '.streamSettings|if type=="string" then (fromjson? // {}) else . end|.realitySettings.shortIds[0] // ""' <<<"$existing_ib")"
    ndest="$(jq -r '.streamSettings|if type=="string" then (fromjson? // {}) else . end|.realitySettings.dest // ""' <<<"$existing_ib")"
    nsni="$(jq -r '.streamSettings|if type=="string" then (fromjson? // {}) else . end|.realitySettings.serverNames[0] // ""' <<<"$existing_ib")"
    if ! is_port "$tport" || [ -z "$tuuid" ] || [ -z "$pub" ] || [ -z "$tsid" ] || [ -z "$ndest" ] || [ -z "$nsni" ]; then
      err "Существующий XKIT-туннель повреждён или неполон — дубль не создаю"; rm -f "$ck"; return 1
    fi
    ok "Найден существующий XKIT-туннель :${tport} — использую его, новый inbound не создаю"
  else
    read -r priv pub <<<"$(api_get_new_x25519)"
    [ -n "$priv" ] && [ -n "$pub" ] || { err "Не удалось получить ключи x25519"; rm -f "$ck"; return 1; }
    tuuid="$(new_uuid)"; tsid="$(rand_hex 4)"
  fi

  local nsettings nstream nib
  nsettings="$(jq -nc --arg id "$tuuid" --arg sn "$nname" --arg sub "$(rand_str 16)" '
    {clients:[{id:$id, flow:"xtls-rprx-vision", email:("tunnel-"+$sn), limitIp:0, totalGB:0,
               expiryTime:0, enable:true, tgId:"", subId:$sub, reset:0}],
     decryption:"none", fallbacks:[]}')"
  nstream="$(jq -nc --arg dest "$ndest" --arg sni "$nsni" --arg priv "$priv" --arg sid "$tsid" --arg pub "$pub" '
    {network:"tcp", security:"reality",
     realitySettings:{show:false, xver:0, dest:$dest, serverNames:[$sni], privateKey:$priv,
                      shortIds:[$sid], settings:{publicKey:$pub, fingerprint:"chrome", serverName:""}}}')"
  nib="$(jq -nc --arg port "$tport" --arg tag "inbound-${tport}" --arg remark "xkit-tunnel-${nname}" \
        --arg s "$nsettings" --arg st "$nstream" '
    {up:0, down:0, total:0, remark:$remark, enable:true, expiryTime:0, listen:"",
     port:($port|tonumber), protocol:"vless", settings:$s, streamSettings:$st,
     sniffing:"{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"]}",
     allocate:"{\"strategy\":\"always\",\"refresh\":5,\"concurrency\":-1}",
     tag:$tag}')"
  if [ "$existing_tunnel" = 0 ]; then
    log "Создаю туннельный inbound на ноде (VLESS+Reality, порт ${tport})..."
    local out
    out="$(node_api "$rec" "panel/api/inbounds/add" POST "$nib" "$ck")"
    if ! jq -e '.success == true' <<<"$out" >/dev/null 2>&1; then
      err "Нода: создание inbound не прошло: $(api_err_msg "$out" | head -c 200)"
      rm -f "$ck"; return 1
    fi
    ok "Туннельный inbound на ноде создан"
  fi

  local myip
  myip="$(pubip)"   # только валидный IP; иначе ufw настрою без правила для панели
  is_ip "$myip" || myip=""   # страховка: в env уходит либо валидный IP, либо пусто
  local node_ufw=0
  if node_ssh "$rec" "command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'" >/dev/null 2>&1; then
    log "UFW на ноде уже активен: добавляю SSH ${nport}, туннель ${tport}/tcp и правило панели..."
    # Неактивный UFW никогда не включаем автоматически: это меняет политику всего сервера.
    node_ssh "$rec" "env MYIP='${myip}' NPORT='${nport}' TP='${tport}' NPP='${np_port}' bash -s" <<'EOS' \
      && node_ufw=1 || warn "UFW на ноде НЕ настроен — проверьте firewall вручную"
set -u
: "${NPORT:?нет NPORT}"; : "${TP:?нет TP}"; : "${NPP:?нет NPP}"
ufw allow "${NPORT}/tcp" comment 'XKIT:node-ssh' || { echo "ERR: правило SSH (${NPORT}/tcp) не применилось"; exit 1; }
ufw allow "${TP}/tcp" comment 'XKIT:node-tunnel' || { echo "ERR: правило туннеля (${TP}/tcp) не применилось"; exit 1; }
if [ -n "${MYIP:-}" ]; then
  ufw allow from "${MYIP}" to any port "${NPP}" proto tcp comment 'XKIT:node-panel' || { echo "ERR: правило панели (${NPP})"; exit 1; }
else
  ufw deny "${NPP}/tcp" comment 'XKIT:node-panel' || { echo "ERR: не удалось закрыть панель (${NPP}) в ufw"; exit 1; }
  echo "WARN: IP мастера неизвестен — панель ноды закрыта в ufw (доступ через SSH-туннель)"
fi
echo "UFW на ноде: правила применены, firewall остаётся активен"
EOS
  else
    warn "UFW на ноде неактивен — не включаю его и не меняю правила; ограничьте порты своим firewall"
  fi
  if [ "$node_ufw" = "1" ] && [ -z "$myip" ]; then
    warn "Публичный IP мастера не определён — панель ноды (${np_port}/tcp) ЗАКРЫТА в ufw."
    warn "Доступ к панели ноды — через SSH-туннель: ssh -p ${nport} -L ${np_port}:127.0.0.1:${np_port} ${nuser}@${nhost}"
  fi

  rec="$(jq -c --argjson tport "$tport" --arg uuid "$tuuid" --arg pbk "$pub" --arg sid "$tsid" \
         --arg sni "$nsni" --arg dest "$ndest" --arg tag "node-${nname}" --arg created "$(date -Is)" \
    '.tunnel = {port:$tport, proto:"vless", net:"tcp", sec:"reality", uuid:$uuid, pbk:$pbk,
                sid:$sid, sni:$sni, dest:$dest, flow:"xtls-rprx-vision"}
      | .outbound_tag = $tag | .created = $created' <<<"$rec")"
  nodes_load | jq -c --argjson r "$rec" 'map(select(.name != $r.name)) + [$r]' > "${XKIT_NODES}.tmp" \
    && mv "${XKIT_NODES}.tmp" "$XKIT_NODES"
  chmod 600 "$XKIT_NODES"
  rm -f "$ck"

  local apply_failed=0
  log "Готовлю pool-инбаунд на мастере (вход для клиентов с балансировкой)..."
  nodes_ensure_pool || apply_failed=1
  log "Применяю аутбаунды нод + balancer к xray на мастере..."
  nodes_apply_template || apply_failed=1
  if [ -n "${XKIT_POOL_INBOUND:-}" ]; then
    local pool_ib pool_cl plink
    pool_ib="$(api_get_inbound "$XKIT_POOL_INBOUND")" || true
    # v7.4.2: толерантный разбор settings (защита от v3-wire без нормализации)
    pool_cl="$(jq -c '.settings|if type=="string" then (fromjson? // {}) else (. // {}) end|.clients[0] // empty' <<<"${pool_ib:-}")"
    if [ -n "$pool_cl" ]; then
      plink="$(link_for_client "${pool_ib:-}" "$pool_cl")"
      [ -n "$plink" ] && { echo ""; ok "Ссылка ПОЛА (трафик балансируется по нодам):"; printf '  %s\n' "$plink"; }
    fi
  fi
  read -r -p "Срок аренды ноды '${nname}' (DD.MM.YYYY или YYYY-MM-DD, Enter — пропустить): " dex
  if [ -n "$dex" ]; then
    if expiry_set node "$nname" "$dex" ""; then
      ok "Срок аренды сохранён: ${dex} (виден в веб-дашборде и xkit expiry list)"
    else
      warn "Дата не распознана — задайте позже: xkit expiry set ${nname} DD.MM.YYYY"
    fi
  fi
  echo ""
  if [ "${apply_failed:-0}" = "0" ]; then
    echo -e "${GREEN}=== Нода '${nname}' подключена ===${NC}"
  else
    err "=== Нода '${nname}' в реестре, но конфиг НЕ применён — трафик на неё не пойдёт ==="
    warn "Выполните: xkit (меню) -> пункт 2 (автопроброс), затем НОДЫ -> health"
  fi
  ok "Туннель: мастер -> ${nhost}:${tport} (VLESS+Reality, SNI ${nsni})"
  if [ "$node_ufw" = "1" ]; then
    if [ -n "$myip" ]; then
      ok "Панель ноды: ${psch}://${nhost}:${np_port}${nbase} (UFW: только с IP мастера)"
    else
      ok "Панель ноды: ${psch}://${nhost}:${np_port}${nbase} (UFW: внешний доступ закрыт)"
    fi
  else
    warn "Панель ноды: ${psch}://${nhost}:${np_port}${nbase} (UFW не управляется XKIT)"
  fi
  ok "Стратегия: ${XKIT_BAL_STRATEGY:-leastLoad} (сменить: Ноды -> стратегия)"
  # (7.4.0): реквизиты панели ноды показываем в конце установки — пользователь
  # должен видеть логин/пароль один раз глазами, не выковыривая их из реестра
  echo ""
  echo "Реквизиты панели ноды (сохранены в реестре /etc/xkit/nodes.json, 0600):"
  echo "  URL:    ${psch}://${nhost}:${np_port}${nbase}"
  echo "  Логин:  ${np_user}"
  echo "  Пароль: ${np_pass}"
  warn "Логин/пароль случайные — если развернёте camo-сьют, в браузере будет ФЕЙК-логин сайт-прикрытия, а настоящий — этот."
  xkit_summary_save >/dev/null 2>&1 || true
  # v7.3: сразу предложить серт/camo для панели ноды (пропуск = самоподписанный
  # серт из шага установки; вернуться позже: НОДЫ -> 9/10 или xkit nodes cert|camo)
  # (7.4.0, минимум вопросов): предлагаем ТОЛЬКО релевантные варианты — по типу
  # адреса ноды. IP: самоподписанный (уже стоит) или LE shortlived на IP (~6.5
  # дней, автопродление). Домен: LE на домен, свой сертификат (файлы),
  # subdomain+wildcard (dns-01 Cloudflare) или самоподписанный.
  if [ -t 0 ]; then
    local _cm=""
    echo ""
    if is_ip "$nhost"; then
      read -r -p "Сертификат панели ноды: Enter = самоподписанный (уже стоит) | ip = Let's Encrypt на IP (~6.5 дней, автопродление): " _cm || _cm=""
      case "${_cm,,}" in
        ip|le|letsencrypt) node_cert_one "$nname" ip "" || true ;;
        *) ok "Панель ноды остаётся на самоподписанном серте (xkit nodes cert ${nname} ip — когда понадобится)" ;;
      esac
    else
      echo "Сертификат панели ноды (${nhost}):"
      echo "  1) Let's Encrypt на домен — поддомен с A-записью на ${nhost} (автопродление на ноде) [Enter]"
      echo "  2) свой сертификат — пути к fullchain/privkey на этом сервере"
      echo "  3) Домен и все поддомены через Cloudflare (для сайта-прикрытия)"
      echo "  4) самоподписанный (уже стоит — пропустить)"
      read -r -p "Выбор [1]: " _cm || _cm=""
      case "${_cm:-1}" in
        1|le|domain|letsencrypt) node_cert_one "$nname" domain "" || true ;;
        2|own) node_cert_one "$nname" own "" || true ;;
        3|wildcard|w) node_cert_one "$nname" wildcard "" || true ;;
        4|self) ok "Панель ноды остаётся на самоподписанном серте" ;;
        *) ok "Панель ноды остаётся на самоподписанном серте (xkit nodes cert ${nname} — когда понадобится)" ;;
      esac
    fi
    local _cy=""
    # (стиль v7.1): [y/N]-промпты только через confirm() (typed-guard, EOF = отказ)
    if confirm "Развернуть camo-сьют на ноде (сайт-прикрытие + фейк-логин)? [y/N] " _cy; then
      node_camo_deploy_one "$nname" "" || warn "Camo не развернулся — вернитесь: НОДЫ -> 10 (или xkit nodes camo ${nname})"
    fi
  fi
  node_panel_sync "$nname" || warn "${nname}: нода XKIT сохранена; повторите: xkit nodes panel-sync ${nname}"
  nodes_metrics_collect "$nname" >/dev/null 2>&1 || warn "${nname}: метрики пока недоступны"
  return 0
}

# повторное применение конфигурации после сбоя apply: нода могла остаться
# «в реестре, но без маршрута». Проверяет туннельные инбаунды на нодах,
# pool на мастере и аутбаунды/balancer в шаблоне xray
nodes_repair() {
  require_root
  load_xkit_env || die "Сначала установка (пункт 1)"
  kit_session || return 1
  local bad=0 cnt
  cnt="$(nodes_load 2>/dev/null | jq -r 'length' 2>/dev/null)"
  cnt="${cnt:-0}"
  if [ "$cnt" -eq 0 ]; then
    warn "Нод в реестре нет — repair просто пересоберёт конфиг мастера (pool + маршруты)"
  else
    log "Проверяю туннельные инбаунды на нодах..."
    local rec nm tport ttag inb_id ck
    while IFS= read -r rec; do
      [ -z "$rec" ] && continue
      nm="$(jq -r '.name' <<<"$rec")"
      tport="$(jq -r '.tunnel.port // empty' <<<"$rec")"
      if [ -z "$tport" ]; then
        warn "${nm}: в записи нет tunnel.port — пропускаю"
        continue
      fi
      ttag="inbound-${tport}"
      ck="$(mktemp /tmp/.xkit-node-ck.XXXXXX)"
      if node_login "$rec" "$ck" >/dev/null 2>&1; then
        inb_id="$(node_api "$rec" "panel/api/inbounds/list" GET "" "$ck" \
          | jq -r --arg t "$ttag" '[.obj[]?|select(.tag==$t)][0].id // empty' 2>/dev/null)"
        if [ -n "$inb_id" ]; then
          ok "${nm}: туннельный inbound на месте (#${inb_id})"
        else
          err "${nm}: туннельного inbound (${ttag}) НЕТ на ноде — переподключите ноду (удалить + добавить)"
          bad=1
        fi
      else
        warn "${nm}: панель ноды недоступна — inbound проверить не смог"
        bad=1
      fi
      rm -f "$ck"
    done < <(jq -c '.[]' <(nodes_load))
  fi
  log "Pool-инбаунд на мастере (пересоздам, если маршрута нет)..."
  nodes_ensure_pool || bad=1
  log "Аутбаунды нод + balancer в шаблоне xray..."
  nodes_apply_template || bad=1
  if [ "$bad" -eq 0 ]; then
    ok "Repair завершён: конфигурация применена"
    xkit_summary_save >/dev/null 2>&1 || true
  else
    err "Repair: остались проблемы (см. выше) — проверьте nginx -t и панели нод"
    return 1
  fi
  return 0
}

# перепинить отпечаток сертификата панели ноды (после перевыпуска серта на ноде)
node_repin() { # $1 имя ноды или all
  load_xkit_env || die "Сначала установка (пункт 1)"
  local want="${1:-all}" arr n pin any=0 old_pin yn
  arr="$(nodes_load)"
  [ "$(jq 'length' <<<"$arr" 2>/dev/null || echo 0)" -gt 0 ] || { warn "Нод нет"; return 0; }
  while IFS= read -r rec; do
    [ -z "$rec" ] && continue
    n="$(jq -r '.name' <<<"$rec")"
    [ "$want" = "all" ] || [ "$want" = "$n" ] || continue
    any=1
    if [ "$(jq -r '.panel.tls // "false"' <<<"$rec")" != "true" ]; then
      warn "${n}: панель ноды по HTTP — пиновать нечего"
      continue
    fi
    pin="$(cert_pin "$(jq -r '.host' <<<"$rec")" "$(jq -r '.panel.port' <<<"$rec")")"
    if [ -n "$pin" ]; then
      # TOFU (аудит №4): молча принять ИЗМЕНИВШИЙСЯ пин = легитимизировать
      # возможный MITM. Первый пин (пустой старый) принимается без вопросов
      old_pin="$(jq -r --arg n "$n" 'map(select(.name==$n))[0].panel.pincert // ""' <<<"$arr" 2>/dev/null)"
      if [ -n "$old_pin" ] && [ "$old_pin" != "$pin" ]; then
        warn "${n}: пин ИЗМЕНИЛСЯ (старый: $(printf '%s' "$old_pin" | head -c 16)..., новый: $(printf '%s' "$pin" | head -c 16)...)"
        if [ -t 0 ]; then
          # TOFU: изменённый пин принимается ТОЛЬКО явным «да» (дефолт n);
          # EOF (Ctrl-D) в confirm = отказ — молчаливого принятия нет
          if ! confirm "Принять новый пин? [y/N] " n; then
            warn "${n}: пин не обновлён (если серт не перевыпускали — возможно, MITM'ится)"
            continue
          fi
        else
          warn "${n}: stdin не tty — пин НЕ обновляется (запустите интерактивно)"
          continue
        fi
      fi
      nodes_load | jq -c --arg n "$n" --arg p "$pin" \
        'map(if .name==$n then .panel.pincert=$p else . end)' > "${XKIT_NODES}.tmp" \
        && mv "${XKIT_NODES}.tmp" "$XKIT_NODES" && chmod 600 "$XKIT_NODES"
      ok "${n}: пин обновлён (sha256//$(printf '%s' "$pin" | head -c 16)... )"
    else
      err "${n}: не удалось снять отпечаток сертификата (нода доступна?)"
    fi
  done < <(jq -c '.[]' <<<"$arr")
  [ "$any" = "1" ] || { err "Нода '${want}' не найдена (xkit nodes repin <имя|all>)"; return 1; }
  return 0
}

# v7.2.11: обновить API-токен панели ноды — после переустановки 3X-UI на ноде
# или ротации токена (панель -> Settings -> API Tokens) старый .panel.token
# отбивается 401/403, и Bearer-путь перестаёт работать. Без аргумента — токен
# читается с ноды по SSH из /etc/x-ui/install-result.env (тот же путь, что в
# node_add) и верифицируется живой панелью; не вышел/не принят — токен
# удаляется из реестра и API живёт классическим логином+CSRF. «none» —
# явный сброс токена (ручной путь: «xkit nodes token set» остаётся как был).
node_relogin() { # $1 имя|all, [$2 = none]
  load_xkit_env || die "Сначала установка (пункт 1)"
  local want="${1:-}" mode="${2:-}" arr n any=0 trec tck ntok
  [ -n "$want" ] || { err "xkit nodes relogin <имя|all> [none]"; return 1; }
  arr="$(nodes_load)"
  [ "$(jq 'length' <<<"$arr" 2>/dev/null || echo 0)" -gt 0 ] || { warn "Нод нет"; return 0; }
  while IFS= read -r rec; do
    [ -z "$rec" ] && continue
    n="$(jq -r '.name' <<<"$rec")"
    [ "$want" = "all" ] || [ "$want" = "$n" ] || continue
    any=1
    if [ "$mode" = "none" ]; then
      nodes_load | jq -c --arg n "$n" 'map(if .name==$n then del(.panel.token) else . end)' > "${XKIT_NODES}.tmp" \
        && mv "${XKIT_NODES}.tmp" "$XKIT_NODES" && chmod 600 "$XKIT_NODES"
      ok "${n}: API-токен удалён — API будет по логину+CSRF (xkit nodes token set вернёт Bearer)"
      continue
    fi
    trec="$(jq -c 'del(.panel.token)' <<<"$rec")"
    tck="$(mktemp /tmp/.xkit-node-ck.XXXXXX)"
    ntok="$(node_token_fetch "$rec")"
    if [ -n "$ntok" ] && node_token_ok "$(jq -c --arg t "$ntok" '.panel.token = $t' <<<"$trec")" "$tck"; then
      nodes_load | jq -c --arg n "$n" --arg t "$ntok" \
        'map(if .name==$n then .panel.token=$t else . end)' > "${XKIT_NODES}.tmp" \
        && mv "${XKIT_NODES}.tmp" "$XKIT_NODES" && chmod 600 "$XKIT_NODES"
      ok "${n}: API-токен панели обновлён (Bearer, из install-result.env ноды)"
    else
      nodes_load | jq -c --arg n "$n" 'map(if .name==$n then del(.panel.token) else . end)' > "${XKIT_NODES}.tmp" \
        && mv "${XKIT_NODES}.tmp" "$XKIT_NODES" && chmod 600 "$XKIT_NODES"
      warn "${n}: токен не получен/не принят панелью — API будет по логину+CSRF"
    fi
    rm -f "$tck"
    [ -n "$(jq -r '.panel.token // empty' < <(nodes_load | jq -c --arg n "$n" '.[]|select(.name==$n)'))" ] \
      && { node_panel_sync "$n" || warn "${n}: повторите xkit nodes panel-sync ${n}"; }
  done < <(jq -c '.[]' <<<"$arr")
  [ "$any" = "1" ] || { err "Нода '${want}' не найдена (xkit nodes relogin <имя|all> [none])"; return 1; }
  return 0
}

nodes_list() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  local arr cnt
  arr="$(nodes_load)"; cnt="$(jq 'length' <<<"$arr")"
  [ "$cnt" -eq 0 ] && { warn "Нод нет — добавьте (Ноды -> добавить)"; return 0; }
  echo ""
  printf '%-10s %-22s %-6s %-9s %-24s %-8s\n' "ИМЯ" "ХОСТ" "SSH" "ТУННЕЛЬ" "SNI" "ПАНЕЛЬ"
  echo "-------------------------------------------------------------------------------"
  local n h sp tp sni pp
  while IFS=$'\t' read -r n h sp tp sni pp; do
    printf '%-10s %-22s %-6s %-9s %-24s %-8s\n' "$n" "$h" "$sp" "$tp" "$sni" "$pp"
  done < <(jq -r '.[] | [.name, .host, (.ssh_port|tostring), (.tunnel.port|tostring), .tunnel.sni, (.panel.port|tostring)] | @tsv' <<<"$arr")
  ok "Стратегия: ${XKIT_BAL_STRATEGY:-leastLoad}"
  return 0
}

nodes_health() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  # fails = туннель/панель, ssh_fails = SSH недоступен (аудит №2: раньше SSH-провал
  # не считался, и при живом туннеле печатались [ВНИМ], а финал был «Все ноды живы»)
  local arr cnt fails=0 ssh_fails=0
  arr="$(nodes_load)"; cnt="$(jq 'length' <<<"$arr")"
  [ "$cnt" -eq 0 ] && { warn "Нод нет"; return 0; }
  echo ""
  local rec name host tport ck
  while IFS= read -r rec; do
    [ -z "$rec" ] && continue
    name="$(jq -r '.name' <<<"$rec")"
    host="$(jq -r '.host' <<<"$rec")"
    tport="$(jq -r '.tunnel.port // 443' <<<"$rec")"
    if ! timeout 3 bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$host" "$tport" 2>/dev/null; then
      echo "  [СБОЙ] ${name}: туннель ${host}:${tport} недоступен"
      fails=$((fails+1))
      continue
    fi
    # (баг №3, аудит v5.2.1): systemctl is-active возвращает 3 для inactive — это
    # НЕ провал SSH. Разделяем: «active» / SSH-провал (255, timeout 124) / x-ui не активен
    local svc_out rc
    svc_out="$(node_ssh "$rec" "systemctl is-active x-ui" 2>/dev/null)"; rc=$?
    if [ "$svc_out" = "active" ]; then
      ck="$(mktemp /tmp/.xkit-node-ck.XXXXXX)"
      if node_login "$rec" "$ck"; then
        echo "  [OK]   ${name}: туннель :${tport}, x-ui работает, панель отвечает"
      else
        echo "  [ВНИМ] ${name}: туннель жив, но панель ноды не логинится"
        fails=$((fails+1))
      fi
      rm -f "$ck"
    elif [ "$rc" -eq 255 ] || [ "$rc" -eq 124 ]; then
      echo "  [ВНИМ] ${name}: туннель жив, SSH до ноды не прошёл (x-ui проверьте руками)"
      ssh_fails=$((ssh_fails+1))
    else
      echo "  [ВНИМ] ${name}: туннель жив, x-ui не активен (systemctl: ${svc_out:-код $rc})"
      fails=$((fails+1))
    fi
  done < <(jq -c '.[]' <<<"$arr")
  if [ "$fails" -gt 0 ]; then
    err "Проблемы на ${fails} нодах"
  elif [ "$ssh_fails" -gt 0 ]; then
    warn "Туннели живы, но SSH недоступен на ${ssh_fails} нод(ах) — x-ui/конфиг там проверьте руками"
  else
    ok "Все ноды живы"
  fi
  return 0
}

nodes_strategy() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  echo ""
  echo "Стратегия балансировки (xray balancer):"
  echo "1) По очереди (roundRobin)"
  echo "2) Случайно (random)"
  echo "3) По наименьшей задержке (leastPing): выбирается самый быстрый ответ"
  echo "4) По наименьшей загрузке (leastLoad): проверка каждые 5 минут (по умолчанию)"
  read -r -p "Выбор [1-4, Enter = 4]: " s
  s="${s:-4}"
  case "$s" in
    1) XKIT_BAL_STRATEGY="roundRobin" ;;
    2) XKIT_BAL_STRATEGY="random" ;;
    3) XKIT_BAL_STRATEGY="leastPing" ;;
    4) XKIT_BAL_STRATEGY="leastLoad" ;;
    *) err "Нет такого пункта"; return 1 ;;
  esac
  save_xkit_env
  log "Применяю стратегию ${XKIT_BAL_STRATEGY} к конфигу xray..."
  nodes_apply_template || return 1
  ok "Готово. При leastPing/leastLoad xray сам переключает трафик на живые ноды (observatory)."
  return 0
}

nodes_del() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  local arr cnt
  arr="$(nodes_load)"; cnt="$(jq 'length' <<<"$arr")"
  [ "$cnt" -eq 0 ] && { warn "Нод нет"; return 0; }
  nodes_list
  local n rec
  read -r -p "Имя ноды для удаления (Enter — отмена): " n
  [ -z "$n" ] && return 0
  rec="$(nodes_load | jq -c --arg n "$n" '[.[]|select(.name==$n)][0] // empty')"
  [ -n "$rec" ] || { err "Нода '$n' не найдена"; return 1; }
  confirm "Удалить ноду '$n' из конфигурации? [y/N] " n || return 0
  if confirm "Удалить туннельный inbound на самой ноде (через её API)? [Y/n] " y; then
    local ck; ck="$(mktemp /tmp/.xkit-node-ck.XXXXXX)"
    if node_login "$rec" "$ck" 2>/dev/null; then
      local inb_id
      inb_id="$(node_api "$rec" "panel/api/inbounds/list" GET "" "$ck" \
        | jq -r --arg t "inbound-$(jq -r '.tunnel.port' <<<"$rec")" '[.obj[]?|select(.tag==$t)][0].id // empty')"
      if [ -n "$inb_id" ] && node_api "$rec" "panel/api/inbounds/del/${inb_id}" POST "" "$ck" >/dev/null 2>&1; then
        ok "Инбаунд на ноде удалён"
      else
        warn "Инбаунд ноды не удалён (не критично)"
      fi
    else
      warn "Панель ноды недоступна — inbound не удалял"
    fi
    rm -f "$ck"
  fi
  local panel_id; panel_id="$(jq -r '.panel_node_id // empty' <<<"$rec")"
  if [ -n "$panel_id" ] && confirm "Удалить запись из раздела «Узлы» мастер-панели? [y/N] " n; then
    if kit_session >/dev/null 2>&1 && api_post_json "panel/api/nodes/del/${panel_id}" "" | jq -e '.success == true' >/dev/null 2>&1; then
      ok "Запись удалена из «Узлов» 3X-UI"
    else
      warn "Запись в «Узлах» не удалена (возможны привязанные инбаунды) — проверьте панель"
    fi
  fi
  if confirm "Остановить x-ui на ноде? [y/N] " n; then
    node_ssh "$rec" "systemctl stop x-ui; systemctl disable x-ui" >/dev/null 2>&1 \
      && ok "x-ui на ноде остановлен" || warn "Не удалось остановить (проверьте доступ)"
  fi
  nodes_load | jq -c --arg n "$n" 'map(select(.name != $n))' > "${XKIT_NODES}.tmp" \
    && mv "${XKIT_NODES}.tmp" "$XKIT_NODES"
  kit_session >/dev/null 2>&1 || true
  nodes_apply_template || warn "Шаблон xray не обновился"
  # v4.5: последняя нода удалена — убираем pool-инбаунд целиком. Иначе pool
  # остаётся в панели/маршрутах, а правило balancer уже исчезло (nodes.json
  # пуст): ссылки пула продолжали бы работать, молча меняя выход на IP мастера
  local cnt0; cnt0="$(nodes_load | jq 'length' 2>/dev/null || echo 0)"
  if [ "$cnt0" -eq 0 ] && [ -n "${XKIT_POOL_INBOUND:-}" ]; then
    warn "Это была последняя нода — убираю pool-инбаунд (переход в одиночный режим)"
    pool_remove_force || warn "Pool не убрался полностью: НОДЫ -> пункт 8 (убрать pool)"
  fi
  ok "Нода '$n' удалена; аутбаунд убран, балансировка пересчитана"
  return 0
}

# v4.5: полностью убрать pool-инбаунд — переход мастер -> одиночный.
# ВАЖНО: nodes_merge_template при пустом nodes.json уже убрал правило
# balancer, поэтому трафик pool-инбаунда пошёл бы напрямую с мастера —
# ссылки пула в подписках молча меняли бы exit-IP. Убираем всё: инбаунд
# в панели + маршрут nginx + env, затем ОБЯЗАТЕЛЬНО перегенерация подписок.
pool_remove_force() { # без вопросов — для nodes_del и меню
  local id="${XKIT_POOL_INBOUND:-}"
  [ -n "$id" ] || { warn "Pool не настроен — сервер уже в одиночном режиме"; return 0; }
  # 1) инбаунд в панели (если панель жива)
  if kit_session >/dev/null 2>&1; then
    if api_del_inbound "$id" 2>/dev/null | jq -e '.success == true' >/dev/null 2>&1; then
      ok "Pool-инбаунд #${id} удалён из панели"
    else
      warn "Панель не удалила pool-инбаунд #${id} — проверьте вручную"
    fi
  else
    warn "Панель недоступна: pool-инбаунд #${id} остался в панели (удалите вручную), маршрут уберу"
  fi
  # 2) маршрут nginx + переменные
  routes_del "$id"
  XKIT_POOL_INBOUND=""; XKIT_POOL_TAG=""
  save_xkit_env
  # 3) пересобрать nginx и подписки: ссылки пула исчезают — клиенты должны
  # обновить подписку (она обновится сама при следующем запросе клиента)
  regen_conf_and_apply || { err "Конфиг nginx не применился — выполните: xkit nodes repair"; return 1; }
  sub_regen_quiet || true
  warn "Ссылки пула исчезли из подписок — клиентам нужно обновить подписку (происходит автоматически)"
  ok "Сервер переведён в одиночный режим"
  return 0
}

pool_remove() { # интерактивно (пункт меню НОДЫ -> 8)
  load_xkit_env || die "Сначала установка (пункт 1)"
  local id="${XKIT_POOL_INBOUND:-}"
  if [ -z "$id" ]; then
    warn "Pool не настроен — сервер в одиночном режиме"
    return 0
  fi
  echo ""
  warn "Будет удалён pool-инбаунд #${id}: клиенты перестанут ходить через ноды"
  confirm "Перевести сервер в одиночный режим? [y/N] " n || return 0
  pool_remove_force
}

nodes_menu() {
  while true; do
    echo ""
    echo -e "${YELLOW}=== ДОПОЛНИТЕЛЬНЫЕ СЕРВЕРЫ И РАСПРЕДЕЛЕНИЕ НАГРУЗКИ ===${NC}"
    echo " 1) Добавить сервер по SSH (3X-UI + защищённое соединение)"
    echo " 2) Список дополнительных серверов"
    echo " 3) Проверить состояние серверов"
    echo " 4) Выбрать распределение нагрузки (по очереди/случайно/по задержке/по загрузке)"
    echo " 5) Удалить дополнительный сервер"
    echo " 6) Восстановить настройки серверов после ошибки"
    echo " 7) Проверить и заново доверять сертификат панели сервера"
    echo " 8) Отключить дополнительные серверы и работать только на главном"
    echo " 9) Сертификат панели сервера: домен / IP / самоподписанный"
    echo "10) Сайт-прикрытие сервера: сайт и страница входа"
    echo "11) Проверка серверов: соединение, SSH, панель, память и диск"
    echo "12) Проверка зависания передачи между главным и дополнительным сервером"
    echo "13) Показать отличия настроек / проверить на одном / применить ко всем"
    echo "14) Ограниченный ключ доступа к панели: задать / проверить срок"
    echo "15) Получить новый ключ доступа и обновить список в 3X-UI"
    echo "16) Добавить/обновить сервер в «Узлах» 3X-UI (без импорта)"
    echo " 0) Назад"
    local c
    read -r -p "Выбор: " c || return 0
    case "$c" in
      1) node_add; pause_enter ;;
      2) nodes_list; pause_enter ;;
      3) nodes_health; pause_enter ;;
      4) nodes_strategy; pause_enter ;;
      5) nodes_del; pause_enter ;;
      6) nodes_repair; pause_enter ;;
      7) local _rw; read -r -p "Имя ноды (Enter — все): " _rw; node_repin "${_rw:-all}"; pause_enter ;;
      8) pool_remove; pause_enter ;;
      9) node_cert_menu; pause_enter ;;
      10) node_camo_menu; pause_enter ;;
      11) local _ck; read -r -p "Имя ноды (Enter — все): " _ck; nodes_check "${_ck:-all}"; pause_enter ;;
      12) local _fz; read -r -p "Имя ноды (Enter — все): " _fz; nodes_freeze "${_fz:-all}"; pause_enter ;;
      13) nodes_plan; local _ca; read -r -p "Canary нода (Enter — отмена): " _ca; [ -z "$_ca" ] || { nodes_apply_canary "$_ca" && confirm "Применить остальным? [y/N]" && nodes_apply_remaining; }; pause_enter ;;
      14) local _tn; read -r -p "Нода: " _tn; node_token_set "$_tn"; node_token_expiry_check; pause_enter ;;
      15) local _rl; read -r -p "Нода: " _rl; node_relogin "$_rl"; pause_enter ;;
      16) local _ps; read -r -p "Нода (Enter — все): " _ps; node_panel_sync "${_ps:-all}"; pause_enter ;;
      0) return 0 ;;
      *) warn "Нет такого пункта" ;;
    esac
  done
}

# v7.3: подменю сертификатов нод (вызывается из nodes_menu и CLI-диспетчера)
node_cert_menu() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  local arr; arr="$(nodes_load)"
  [ "$(jq 'length' <<<"$arr" 2>/dev/null || echo 0)" -gt 0 ] || { warn "Нод нет — сначала добавьте ноду"; return 0; }
  node_cert_show all
  local n m d
  read -r -p "Имя ноды (Enter — отмена): " n || return 0
  [ -n "$n" ] || return 0
  echo "Режим: 1) self-signed  2) ip (LE shortlived)  3) domain (http-01)  4) subdomain+wildcard (dns-01, мастер)"
  read -r -p "Режим [1]: " m || return 0
  m="${m:-1}"
  d=""
  if [ "$m" = "3" ] || [ "$m" = "4" ]; then
    read -r -p "Домен$( [ "$m" = "4" ] && echo ' (база, пример n1.example.com)' ): " d || return 0
  fi
  node_cert_one "$n" "$m" "$d"
}

# v7.3: подменю camo-сьюта нод
node_camo_menu() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  node_camo_status
  echo " 1) Установить/обновить сайт-прикрытие   2) Удалить сайт-прикрытие (имя|all)   0) Назад"
  local c n
  read -r -p "Выбор: " c || return 0
  case "$c" in
    1) read -r -p "Имя ноды (Enter — все): " n || return 0
       if [ -n "$n" ]; then node_camo_deploy_one "$n"; else
         local nn; jq -r '.[].name' <(nodes_load) 2>/dev/null | while IFS= read -r nn; do
           node_camo_deploy_one "$nn" || true
         done
       fi ;;
    2) read -r -p "Имя ноды | all: " n || return 0; [ -n "$n" ] && node_camo_off_one "$n" ;;
    0) return 0 ;;
    *) warn "Нет такого пункта" ;;
  esac
}

#=========================== v4.1: ПОЛЬЗОВАТЕЛЬ — СБРОС ТРАФИКА ===============
client_reset() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  kit_session || return 1
  routes_load
  local requested="${1:-}" assume_yes="${2:-}" email n
  [ -z "$assume_yes" ] || [ "$assume_yes" = "--yes" ] || { err "xkit client reset [email] [--yes]"; return 1; }
  if [ -n "$requested" ]; then
    jq -e --arg email "$requested" '[.[].settings|fromjson?|.clients[]?|.email] | index($email) != null' <<<"$INBOUNDS" >/dev/null \
      || { err "Пользователь '$requested' не найден"; return 1; }
    email="$requested"
  else
    list_inbounds_menu || return 1
    local ib="$PICK_IB"
    local -a cls=()
    mapfile -t cls < <(jq -c '.settings|fromjson?|.clients[]?' <<<"$ib")
    [ "${#cls[@]}" -gt 0 ] || { warn "В инбаунде нет клиентов"; return 0; }
    echo ""
    local i=0 cl
    for cl in "${cls[@]}"; do
      i=$((i+1)); printf '%-3s %s\n' "$i" "$(jq -r '.email // "-"' <<<"$cl" | cut -c1-40)"
    done
    read -r -p "Номер пользователя [1-$i] (Enter — отмена): " n
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "$i" ] || { warn "Отменено"; return 0; }
    cl="${cls[$((n-1))]}"
    email="$(jq -r '.email // empty' <<<"$cl" | tr -dc 'A-Za-z0-9._@-')"
    [ -n "$email" ] || { err "У клиента нет email"; return 1; }
  fi
  if [ "$assume_yes" != "--yes" ]; then confirm "Сбросить трафик '$email'? [y/N] " n || return 0; fi
  local resp id reset=0 failed=0
  if [ "$API_V3" = "1" ]; then
    resp="$(api_post_raw "panel/api/clients/resetTraffic/${email}")"
    jq -e '.success == true' <<<"$resp" >/dev/null 2>&1 && reset=1 || failed=1
  else
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      resp="$(api_post_raw "panel/api/inbounds/${id}/resetClientTraffic/${email}")"
      if jq -e '.success == true' <<<"$resp" >/dev/null 2>&1; then reset=$((reset+1)); else failed=$((failed+1)); fi
    done < <(jq -r --arg email "$email" '.[]|select(.settings|fromjson?|.clients[]?|.email==$email)|.id' <<<"$INBOUNDS")
  fi
  [ "$failed" -eq 0 ] || { err "Сброшено: $reset; ошибок: $failed — $(api_err_msg "$resp" 2>/dev/null | head -c 200)"; return 1; }
  ok "Трафик '$email' сброшен во всех протоколах ($reset)"
}

#=========================== v4.1: SSH-ВХОД ===================================
# Авто-меню при входе по SSH: /root/.bashrc вызывает xkit для интерактивных сессий
ssh_hook_toggle() {
  require_root
  if [ -f "$0" ]; then
    cp -f "$(readlink -f "$0")" "$XKIT_BIN" && chmod 700 "$XKIT_BIN" \
      && ok "Команда xkit установлена/обновлена: $XKIT_BIN"
  fi
  xkit_menu_install || true   # модуль меню (xkit_menu.sh) — v5.0.0
  xkit_extras_install || warn "TUI/модуль протоколов не установлен — выполните xkit update"
  if grep -q "# >>> xkit-menu >>>" /root/.bashrc 2>/dev/null; then
    sed -i '/# >>> xkit-menu >>>/,/# <<< xkit-menu <<</d' /root/.bashrc
    ok "Авто-меню при входе по SSH ВЫКЛЮЧЕНО (запускайте xkit вручную)"
  else
    cat >> /root/.bashrc <<'EOF'

# >>> xkit-menu >>>
if [[ $- == *i* && -t 0 && -t 1 && -z "$XKIT_NOMENU" ]] && command -v xkit >/dev/null 2>&1; then
  xkit || true
fi
# <<< xkit-menu <<<
EOF
    ok "Авто-меню при входе по SSH ВКЛЮЧЕНО (выйти в шелл: 0 в меню)"
    warn "Отключить: этот же пункт, либо задать XKIT_NOMENU=1"
  fi
  return 0
}

#=========================== СРОКИ АРЕНДЫ СЕРВЕРОВ (v4.3) =====================
# Отдельный сохраняемый параметр: когда заканчивается аренда мастер-сервера
# и каждой ноды. Файл $XKIT_EXPIRY (tab-separated):
#   scope<TAB>id<TAB>date<TAB>note      scope: master | node; id: "-" или имя ноды
days_left() { # $1 YYYY-MM-DD -> целое число дней (может быть <0); пусто если дата кривая
  [[ "${1:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 0
  local d
  d="$(date -d "$1" +%s 2>/dev/null)" || return 0
  echo $(( (d - $(date +%s)) / 86400 ))
}

expiry_get() { # $1 scope, $2 id -> дата (или пусто)
  [ -r "$XKIT_EXPIRY" ] || return 0
  awk -F'\t' -v s="$1" -v i="$2" '$1==s && $2==i {print $3; exit}' "$XKIT_EXPIRY" 2>/dev/null
}

expiry_note() { # $1 scope, $2 id -> заметка
  [ -r "$XKIT_EXPIRY" ] || return 0
  awk -F'\t' -v s="$1" -v i="$2" '$1==s && $2==i {print $4; exit}' "$XKIT_EXPIRY" 2>/dev/null
}

expiry_set() { # $1 scope, $2 id, $3 date, $4 note
  local scope="$1" id="$2" d="$3" note="${4:-}"
  if [[ "$d" =~ ^([0-9]{2})\.([0-9]{2})\.([0-9]{4})$ ]]; then
    d="${BASH_REMATCH[3]}-${BASH_REMATCH[2]}-${BASH_REMATCH[1]}"
  fi
  [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { err "Дата в формате DD.MM.YYYY или YYYY-MM-DD (например 15.01.2027)"; return 1; }
  date -d "$d" +%s >/dev/null 2>&1 || { err "Некорректная дата: $d"; return 1; }
  # заметка не должна ломать tab-separated формат (4-е поле съедает остаток)
  note="${note//$'\t'/ }"; note="${note//$'\r'/ }"; note="${note//$'\n'/ }"
  mkdir -p "$XKIT_DIR" 2>/dev/null || true
  # flock: параллельные записи (cron dash_gen / CLI) не теряют правки друг друга
  (
    flock -w 5 9 || { err "Файл сроков занят другой операцией — повторите"; exit 1; }
    local tmp; tmp="$(mktemp)"
    [ -f "$XKIT_EXPIRY" ] && awk -F'\t' -v s="$scope" -v i="$id" '!($1==s && $2==i)' "$XKIT_EXPIRY" > "$tmp"
    printf '%s\t%s\t%s\t%s\n' "$scope" "$id" "$d" "$note" >> "$tmp"
    mv -f "$tmp" "$XKIT_EXPIRY"
    chmod 600 "$XKIT_EXPIRY"
    exit 0
  ) 9>"${XKIT_EXPIRY}.lock"
}

expiry_del() { # $1 scope, $2 id
  [ -f "$XKIT_EXPIRY" ] || return 0
  (
    flock -w 5 9 || { err "Файл сроков занят другой операцией — повторите"; exit 1; }
    local tmp; tmp="$(mktemp)"
    awk -F'\t' -v s="$1" -v i="$2" '!($1==s && $2==i)' "$XKIT_EXPIRY" > "$tmp"
    mv -f "$tmp" "$XKIT_EXPIRY"; chmod 600 "$XKIT_EXPIRY"
    exit 0
  ) 9>"${XKIT_EXPIRY}.lock"
}

expiry_list() {
  if [ ! -s "$XKIT_EXPIRY" ]; then
    warn "Записей о сроках аренды нет — задайте: xkit expiry set master ГГГГ-ММ-ДД"
    return 0
  fi
  echo ""
  printf '%-10s %-10s %-12s %-14s %s\n' "ОБЪЕКТ" "ID" "ДО" "ОСТАЛОСЬ" "ЗАМЕТКА"
  echo "--------------------------------------------------------------------"
  local s i d note who dl mark
  while IFS=$'\t' read -r s i d note; do
    [ -z "$s" ] && continue
    who="$i"; [ "$s" = "master" ] && who="мастер"
    dl="$(days_left "$d")"
    if [ -z "$dl" ]; then mark="?"
    elif [ "$dl" -lt 0 ]; then mark="${RED}ПРОСРОЧЕНО${NC}"
    elif [ "$dl" -le 7 ]; then mark="${RED}${dl} дн.${NC}"
    elif [ "$dl" -le 30 ]; then mark="${YELLOW}${dl} дн.${NC}"
    else mark="${GREEN}${dl} дн.${NC}"; fi
    printf '%-10s %-10s %-12s %s %s\n' "$who" "$i" "$d" "$mark" "${note:--}"
  done < "$XKIT_EXPIRY"
  return 0
}

expiry_check() {
  load_xkit_env 2>/dev/null || true
  [ -s "$XKIT_EXPIRY" ] || { ok "Сроки аренды не заданы"; return 0; }
  local s i d note dl bad=0
  while IFS=$'\t' read -r s i d note; do
    [ -z "$s" ] && continue
    dl="$(days_left "$d")"
    [ -z "$dl" ] && continue
    if [ "$dl" -lt 0 ]; then
      err "СРОК АРЕНДЫ ИСТЁК: ${s}/${i} (${d}) — провайдер может отключить сервер в любой момент"
      bad=1
    elif [ "$dl" -le 7 ]; then
      err "Осталось ${dl} дн. аренды: ${s}/${i} (${d})"
      bad=1
    elif [ "$dl" -le 30 ]; then
      warn "Осталось ${dl} дн. аренды: ${s}/${i} (${d})"
    fi
  done < "$XKIT_EXPIRY"
  [ "$bad" -eq 0 ] && ok "Критичных сроков аренды нет"
  return 0
}

expiry_menu_set() {
  echo "Кому задать срок:  1) главный сервер   2) дополнительный сервер"
  read -r -p "Выбор [1]: " w; w="${w:-1}"
  local scope id
  if [ "$w" = "2" ]; then
    nodes_list || true
    read -r -p "Имя ноды: " id
    jq -e --arg n "$id" 'any(.[]; .name==$n)' <(nodes_load) >/dev/null 2>&1 \
      || { err "Нода '$id' не найдена"; return 1; }
    scope="node"
  else
    scope="master"; id="-"
  fi
  local d note
  read -r -p "Дата окончания аренды (DD.MM.YYYY или YYYY-MM-DD): " d
  read -r -p "Заметка (провайдер/тариф, Enter — нет): " note
  expiry_set "$scope" "$id" "$d" "$note" || return 1
  xkit_summary_save >/dev/null 2>&1 || true
  ok "Сохранено. Текущие сроки:"
  expiry_list
  return 0
}

expiry_menu_del() {
  [ -s "$XKIT_EXPIRY" ] || { warn "Записей нет"; return 0; }
  expiry_list
  read -r -p "Удалить запись для (master или имя ноды, Enter — отмена): " id
  [ -z "$id" ] && return 0
  if [ "$id" = "master" ]; then expiry_del master "-"; else expiry_del node "$id"; fi
  ok "Запись удалена (если была)"
  return 0
}

expiry_menu() {
  require_root
  load_xkit_env 2>/dev/null || true
  while true; do
    echo ""
    echo -e "${YELLOW}=== СРОКИ АРЕНДЫ СЕРВЕРОВ (мастер + ноды) ===${NC}"
    expiry_list
    echo " 1) Задать/обновить срок"
    echo " 2) Удалить запись"
    echo " 3) Проверка: что скоро истекает"
    echo " 0) Назад"
    local c
    read -r -p "Выбор: " c || return 0
    case "$c" in
      1) expiry_menu_set; pause_enter ;;
      2) expiry_menu_del; pause_enter ;;
      3) expiry_check; pause_enter ;;
      0) return 0 ;;
      *) warn "Нет такого пункта" ;;
    esac
  done
}

expiry_cli_set() { # expiry set <master|имя ноды> ГГГГ-ММ-ДД [заметка...]
  load_xkit_env 2>/dev/null || true
  [ $# -ge 2 ] || { err "Использование: xkit expiry set <master|имя_ноды> ГГГГ-ММ-ДД [заметка]"; return 1; }
  local scope="$1" d="$2"; shift 2
  local note="$*" s id="-"
  case "$scope" in
    master|main|server) s="master" ;;
    *)
      jq -e --arg n "$scope" 'any(.[]; .name==$n)' <(nodes_load) >/dev/null 2>&1 \
        || { err "Нода '$scope' не найдена (для этого сервера укажите: master)"; return 1; }
      s="node"; id="$scope" ;;
  esac
  expiry_set "$s" "$id" "$d" "$note" || return 1
  ok "Срок аренды ${scope}: ${d}"
  xkit_summary_save >/dev/null 2>&1 || true
}

expiry_cli_del() { # expiry del <master|имя ноды>
  [ $# -ge 1 ] || { err "Использование: xkit expiry del <master|имя_ноды>"; return 1; }
  local scope="$1" s id="-"
  case "$scope" in
    master|main|server) s="master" ;;
    *) s="node"; id="$scope" ;;
  esac
  expiry_del "$s" "$id" && ok "Запись '${scope}' удалена (если была)"
}

#=========================== ВЕБ-ДАШБОРД (v4.3) ===============================
# Скрытая страница рядом с панелью: https://ДОМЕН/d-<токен>/
# Показывает: статусы нод и каналов (туннелей), потреблённый трафик
# (инбаунды мастера, ноды, топ пользователей), сроки аренды серверов.
# Данные строит dash_gen (API панели + nodes.json + expiry.tsv) и кладёт
# data.json + index.html в $XKIT_DASH_DIR; nginx раздаёт по секретному пути
# (noindex/no-referrer/no-store, access_log off, опционально allow IP).
# Обновление: cron каждые 5 минут (xkit dash gen) + автообновление JS 30 сек.

dash_path() { printf '/d-%s/' "${XKIT_DASH_TOKEN:-CHANGE_ME}"; }

# (7.4.0): логин дашборда — полностью случайный, без палевного префикса «dash»
# и без 256-вариантного rand_hex 2: 10 символов [a-z0-9] (~57 бит)
dash_user_gen() { rand_str 10 | tr 'A-Z' 'a-z'; }

# htpasswd для Basic Auth дашборда (apr1-хэш — понимается nginx'ом)
dash_htpasswd_write() { # из XKIT_DASH_USER / XKIT_DASH_PASS
  local u="${XKIT_DASH_USER:-}" p="${XKIT_DASH_PASS:-}" h
  [ -n "$u" ] && [ -n "$p" ] || return 1
  h="$(printf '%s\n' "$p" | openssl passwd -apr1 -stdin 2>/dev/null)" || return 1   # V-03: не в argv
  [ -n "$h" ] || return 1
  printf '%s:%s\n' "$u" "$h" > "${XKIT_DASH_HTPASSWD}"
  chown root:www-data "${XKIT_DASH_HTPASSWD}" 2>/dev/null || true
  chmod 640 "${XKIT_DASH_HTPASSWD}"
  return 0
}

dash_cron_install() {
  cat > "$XKIT_CRON_DASH" <<EOF
# XKIT: обновление веб-дашборда каждые 5 минут
*/5 * * * * root ${XKIT_BIN} dash gen >/dev/null 2>&1
EOF
  chmod 644 "$XKIT_CRON_DASH"
  ok "Cron: дашборд обновляется каждые 5 минут ($XKIT_CRON_DASH)"
}

# состояние мастер-сервера -> JSON-объект
dash_master_json() {
  local nginx_st="inactive" xui_st="inactive" load1="" up_days=""
  local mem_total="" mem_avail="" mem_pct="" disk_pct="" cert_end="" xui_ver="" xray_ver=""
  nginx_st="$(systemctl is-active nginx 2>/dev/null || echo inactive)"
  xui_st="$(systemctl is-active x-ui 2>/dev/null || echo inactive)"
  load1="$(awk '{print $1}' /proc/loadavg 2>/dev/null)"
  up_days="$(awk '{printf "%.1f", $1/86400}' /proc/uptime 2>/dev/null)"
  mem_total="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
  mem_avail="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)"
  if [[ "${mem_total:-}" =~ ^[0-9]+$ ]] && [[ "${mem_avail:-}" =~ ^[0-9]+$ ]] && [ "$mem_total" -gt 0 ]; then
    mem_pct=$(( (mem_total - mem_avail) * 100 / mem_total ))
  fi
  disk_pct="$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')"
  [ -n "${XKIT_CRT:-}" ] && [ -r "$XKIT_CRT" ] \
    && cert_end="$(openssl x509 -enddate -noout -in "$XKIT_CRT" 2>/dev/null | cut -d= -f2-)"
  xui_ver="$(version_xui_current 2>/dev/null || true)"
  xray_ver="$(version_xray_current 2>/dev/null || true)"
  [[ "${disk_pct:-}" =~ ^[0-9]+$ ]] || disk_pct=""
  jq -nc --arg nginx "$nginx_st" --arg xui "$xui_st" --arg load "${load1:-}" \
     --arg mem "$mem_pct" --arg disk "$disk_pct" \
     --arg cert "$cert_end" --arg up "${up_days:-}" \
     --arg uv "$xui_ver" --arg xv "$xray_ver" '
    {nginx:$nginx, xui:$xui, load1:(if $load=="" then null else $load end),
     mem_pct:(if $mem=="" then null else ($mem|tonumber) end),
     disk_pct:(if $disk=="" then null else ($disk|tonumber) end),
     cert_end:(if $cert=="" then null else $cert end),
     xui_version:(if $uv=="" then null else $uv end),
     xray_version:(if $xv=="" then null else $xv end),
     uptime_days:(if $up=="" then null else ($up|tonumber) end)}'
}

# Системные CPU/RAM и версии ноды через существующий защищённый SSH; агент не нужен.
# Значения неизвестны => null, а не фиктивный ноль. Команда на ноде фиксированная.
node_resource_stats() { # $1 rec-ноды
  local out cpu ram load xui xray cert
  out="$(node_ssh "$1" 'bash -s' 2>/dev/null <<'EOS'
cpu_sample() { awk '/^cpu /{t=0; for(i=2;i<=NF;i++)t+=$i; print t,$5+$6; exit}' /proc/stat; }
read -r t0 i0 < <(cpu_sample)
sleep 1
read -r t1 i1 < <(cpu_sample)
cpu="$(awk -v t0="$t0" -v i0="$i0" -v t1="$t1" -v i1="$i1" 'BEGIN{dt=t1-t0; di=i1-i0; if(dt>0)printf "%.1f",100*(dt-di)/dt; else print "0"}')"
mem="$(awk '/^MemTotal:/{t=$2}/^MemAvailable:/{a=$2}END{if(t>0)printf "%.1f",100*(t-a)/t;else print "0"}' /proc/meminfo)"
load="$(awk '{print $1}' /proc/loadavg)"
xui=""; xray=""; cert=""
[ -x /usr/local/x-ui/x-ui ] && xui="$(/usr/local/x-ui/x-ui -v 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
for b in /usr/local/x-ui/bin/xray-linux-*; do
  [ -x "$b" ] || continue
  xray="$("$b" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"; break
done
if [ -r /etc/xkit/xkit.env ]; then
  crt="$(. /etc/xkit/xkit.env 2>/dev/null; printf '%s' "${XKIT_CRT:-}")"
  [ -n "$crt" ] && [ -r "$crt" ] && cert="$(date -d "$(openssl x509 -enddate -noout -in "$crt" 2>/dev/null | cut -d= -f2-)" +%s 2>/dev/null)"
fi
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$cpu" "$mem" "$load" "${xui:--}" "${xray:--}" "${cert:--}"
EOS
)"
  if [[ "$out" =~ ^[0-9]+([.][0-9]+)?[[:space:]]+[0-9]+([.][0-9]+)?[[:space:]]+[0-9]+([.][0-9]+)?([[:space:]].*)?$ ]]; then
    IFS=$'\t' read -r cpu ram load xui xray cert <<<"$out"
    [[ "${cert:-}" =~ ^[0-9]+$ ]] || cert="-"
    jq -nc --argjson c "$cpu" --argjson r "$ram" --argjson l "$load" \
      --arg uv "${xui:--}" --arg xv "${xray:--}" --arg ce "$cert" '
      {resources:"ok",cpu_pct:$c,ram_pct:$r,load1:$l,
       xui_version:(if $uv=="" or $uv=="-" then null else $uv end),
       xray_version:(if $xv=="" or $xv=="-" then null else $xv end),
       cert_expiry:(if ($ce|test("^[0-9]+$")) then ($ce|tonumber) else null end)}'
  else
    jq -nc '{resources:"unavailable",cpu_pct:null,ram_pct:null,load1:null,xui_version:null,xray_version:null,cert_expiry:null}'
  fi
}

# Статистика одной ноды. UDP и реальный клиентский probe не выдумываются:
# для произвольной ноды они не настроены, поэтому явно имеют состояние unknown/not-run.
dash_node_stats() { # $1 rec-ноды, $2 expiry-дата (или пусто), $3 заметка
  local rec="$1" exp="${2:-}" note="${3:-}"
  local name host tport status="down" lat="" panel="n/a" up=0 down=0 total=0 clients=0
  local resources='{"resources":"unavailable","cpu_pct":null,"ram_pct":null,"load1":null,"xui_version":null,"xray_version":null,"cert_expiry":null}'
  local t0 t1 observed
  observed="$(date +%s)"
  name="$(jq -r '.name' <<<"$rec")"
  host="$(jq -r '.host' <<<"$rec")"
  tport="$(jq -r '.tunnel.port // 443' <<<"$rec")"
  t0="$(date +%s%N)"
  if timeout 3 bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$host" "$tport" 2>/dev/null; then
    t1="$(date +%s%N)"
    lat=$(( (t1 - t0) / 1000000 ))
    status="ok"
  fi
  if [ "$status" = "ok" ]; then
    local ck out stats
    ck="$(mktemp /tmp/.xkit-node-ck.XXXXXX)"
    if node_login "$rec" "$ck" >/dev/null 2>&1; then
      panel="ok"
      out="$(node_api "$rec" "panel/api/inbounds/list" GET "" "$ck" 2>/dev/null)"
      if jq -e '.success == true' <<<"${out:-}" >/dev/null 2>&1; then
        stats="$(jq -r '( .obj // [] ) as $a |
          [ ([ $a[] | (.up // 0) ] | add // 0),
            ([ $a[] | (.down // 0) ] | add // 0),
            ([ $a[] | ((.up // 0) + (.down // 0)) ] | add // 0),
            ($a | length) ] | @tsv' <<<"$out" 2>/dev/null)"
        [[ "${stats:-}" =~ ^[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+$ ]] \
          && read -r up down total clients <<<"$stats" || panel="fail"
      else
        panel="fail"
      fi
    else
      panel="fail"
    fi
    rm -f "$ck"
  fi
  [ "$status" = "ok" ] && resources="$(node_resource_stats "$rec")"
  jq -e 'type=="object"' <<<"$resources" >/dev/null 2>&1 \
    || resources='{"resources":"unavailable","cpu_pct":null,"ram_pct":null,"load1":null,"xui_version":null,"xray_version":null,"cert_expiry":null}'
  local dl base err=null
  dl="$(days_left "$exp")"
  [ "$status" = "ok" ] || err='"tcp_unreachable"'
  [ "$status" = "ok" ] && [ "$panel" != "ok" ] && err='"panel_unavailable"'
  base="$(jq -nc --arg n "$name" --arg h "$host" --arg st "$status" \
     --argjson tp "$tport" --argjson lat "${lat:-null}" --arg p "$panel" \
     --argjson up "${up:-0}" --argjson down "${down:-0}" \
     --argjson tot "${total:-0}" --argjson cl "${clients:-0}" \
     --arg exp "$exp" --argjson dl "${dl:-null}" --arg note "$note" \
     --argjson ts "$observed" --argjson error "$err" '
    {name:$n, host:$h, tunnel_port:$tp, status:$st, latency_ms:$lat, panel:$p,
     up:$up, down:$down, total:$tot, clients:$cl,
     expiry:(if $exp=="" then null else $exp end), days_left:$dl,
     note:(if $note=="" then null else $note end), observed_at:$ts,
     last_seen:(if $st=="ok" then $ts else null end), stale:($st!="ok" or $p!="ok"), error:$error,
     probes:{tcp:$st,api:$p,ssh:"unavailable",udp:"unknown",client:"not-run"}}')"
  jq -c --argjson r "$resources" '. + $r | .probes.ssh=$r.resources' <<<"$base"
}

# Внутренний планировщик: не больше XKIT_NODES_PARALLEL workers, у каждого deadline.
# Файлы результатов лежат рядом с основным кэшем; порядок нод сохраняется.
_nodes_metrics_reap() { # $1: 1 = ждать хотя бы одного
  local changed i pid now
  while :; do
    changed=0; now="$(date +%s)"
    for i in "${!_metric_pids[@]}"; do
      [ -n "${_metric_pids[$i]:-}" ] || continue
      pid="${_metric_pids[$i]}"
      if ! kill -0 "$pid" 2>/dev/null; then
        wait "$pid" 2>/dev/null || true
        unset '_metric_pids[$i]'; changed=1; continue
      fi
      if [ $((now-${_metric_starts[$i]})) -ge "$XKIT_NODE_DEADLINE" ]; then
        pkill -TERM -P "$pid" 2>/dev/null || true
        kill -TERM "$pid" 2>/dev/null || true; sleep 0.1
        pkill -KILL -P "$pid" 2>/dev/null || true; kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        : > "${_metric_files[$i]}"
        unset '_metric_pids[$i]'; changed=1
      fi
    done
    [ "$changed" = "1" ] && return 0
    [ "${1:-0}" = "1" ] || return 0
    sleep 0.1
  done
}

# Sanitized history ring buffer: только агрегаты и состояния, никаких реквизитов нод.
nodes_history_update() { # $1 nodes JSON, $2 timestamp
  local nodes="$1" now="$2" old='{"samples":{}}' tmp limit data
  limit="${XKIT_NODES_HISTORY_MAX:-288}"
  [[ "$limit" =~ ^[0-9]+$ ]] && [ "$limit" -ge 48 ] && [ "$limit" -le 288 ] || limit=288
  if [ -r "$XKIT_NODES_HISTORY" ] && jq -e '.samples|type=="object"' "$XKIT_NODES_HISTORY" >/dev/null 2>&1; then
    old="$(cat "$XKIT_NODES_HISTORY")"
  fi
  data="$(jq -nc --argjson old "$old" --argjson ns "$nodes" --argjson now "$now" --argjson lim "$limit" '
    ($old | {samples:(.samples | with_entries(.value=([.value[]? |
      {ts,available,latency_ms,cpu_pct,ram_pct,rate_bps,interval_total}] | .[-$lim:])))}) as $safe |
    reduce $ns[] as $n ($safe;
      .samples[$n.name] = (((.samples[$n.name] // []) + [
        {ts:$now,available:($n.status=="ok"),latency_ms:$n.latency_ms,
         cpu_pct:$n.cpu_pct,ram_pct:$n.ram_pct,rate_bps:$n.rate_bps,
         interval_total:$n.interval_total}
      ]) | .[-$lim:]))
    | {version:1,updated:$now,samples:.samples}')" || return 1
  mkdir -p "$(dirname "$XKIT_NODES_HISTORY")" || return 1
  tmp="$(mktemp "${XKIT_NODES_HISTORY}.tmp.XXXXXX")" || return 1
  if ! printf '%s\n' "$data" >"$tmp" || ! chmod 640 "$tmp" || ! mv -f "$tmp" "$XKIT_NODES_HISTORY"; then
    rm -f "$tmp"; return 1
  fi
  printf '%s\n' "$data"
}

# Общий кэш нод для веб-дашборда и TUI. Сбой одной ноды не обнуляет её прошлые
# показатели и не мешает остальным; сброс счётчиков => rate=null.
nodes_metrics_collect() {
  local arr rec nname cur prev previous='{}' now dt work idx
  local -a input=() results=() _metric_pids=() _metric_starts=() _metric_files=()
  local parallel="${XKIT_NODES_PARALLEL:-4}"
  [[ "$parallel" =~ ^[1-9][0-9]*$ ]] && [ "$parallel" -le 16 ] || parallel=4
  [[ "$XKIT_NODE_DEADLINE" =~ ^[0-9]+$ ]] && [ "$XKIT_NODE_DEADLINE" -ge 5 ] || XKIT_NODE_DEADLINE=45
  now="$(date +%s)"
  if [ -r "$XKIT_NODES_METRICS" ] && jq -e 'type=="object"' "$XKIT_NODES_METRICS" >/dev/null 2>&1; then
    previous="$(cat "$XKIT_NODES_METRICS")"
  fi
  dt=$((now-$(jq -r '.generated // 0' <<<"$previous" 2>/dev/null || echo 0)))
  arr="$(nodes_load)"
  mkdir -p "$(dirname "$XKIT_NODES_METRICS")" || return 1
  work="$(mktemp -d "${XKIT_NODES_METRICS}.work.XXXXXX")" || return 1
  while IFS= read -r rec; do [ -n "$rec" ] && input+=("$rec"); done < <(jq -c '.[]' <<<"$arr")
  for idx in "${!input[@]}"; do
    rec="${input[$idx]}"; nname="$(jq -r '.name' <<<"$rec")"
    _metric_files[$idx]="$work/$idx.json"
    ( dash_node_stats "$rec" "$(expiry_get node "$nname")" "$(expiry_note node "$nname")" > "${_metric_files[$idx]}" ) &
    _metric_pids[$idx]=$!; _metric_starts[$idx]="$(date +%s)"
    [ "$(printf '%s\n' "${!_metric_pids[@]}" | wc -l)" -lt "$parallel" ] || _nodes_metrics_reap 1
  done
  while [ "${#_metric_pids[@]}" -gt 0 ]; do _nodes_metrics_reap 1; done
  for idx in "${!input[@]}"; do
    rec="${input[$idx]}"; nname="$(jq -r '.name' <<<"$rec")"
    cur="$(cat "${_metric_files[$idx]}" 2>/dev/null || true)"
    if ! jq -e 'type=="object" and (.name|type)=="string"' <<<"$cur" >/dev/null 2>&1; then
      cur="$(jq -nc --arg n "$nname" --argjson ts "$now" '{name:$n,status:"down",panel:"n/a",resources:"unavailable",observed_at:$ts,last_seen:null,stale:true,error:"deadline",probes:{tcp:"down",api:"n/a",ssh:"unavailable",udp:"unknown",client:"not-run"}}')"
    fi
    prev="$(jq -c --arg n "$nname" '[.nodes[]?|select(.name==$n)][0] // {}' <<<"$previous")"
    cur="$(jq -c --argjson p "$prev" --argjson dt "$dt" '
      . as $c | ($p.total // null) as $old |
      (if ($c.panel//"ok")=="ok" and ($old|type)=="number" and $dt>0 and $c.total>=$old then
        .interval_total=($c.total-$old) | .interval_up=($c.up-($p.up//0)) |
        .interval_down=($c.down-($p.down//0)) | .rate_bps=(($c.total-$old)/$dt)
      else .interval_total=null | .interval_up=null | .interval_down=null | .rate_bps=null end) |
      (if $c.stale==true and ($p.name//null)==$c.name then
        .up=$p.up | .down=$p.down | .total=$p.total | .clients=$p.clients |
        .cpu_pct=$p.cpu_pct | .ram_pct=$p.ram_pct | .load1=$p.load1 |
        .latency_ms=$p.latency_ms | .last_seen=$p.last_seen |
        .xui_version=$p.xui_version | .xray_version=$p.xray_version | .cert_expiry=$p.cert_expiry
      else . end)' <<<"$cur")"
    results[$idx]="$cur"
  done
  rm -rf "$work"
  local nodes_json='[]' data tmp history='{"version":1,"updated":null,"samples":{}}'
  [ "${#results[@]}" -eq 0 ] || nodes_json="$(printf '%s\n' "${results[@]}" | jq -s '.' 2>/dev/null || echo '[]')"
  data="$(jq -nc --argjson gen "$now" --argjson nodes "$nodes_json" \
    '{generated:$gen,generated_str:($gen|todate),nodes:$nodes}')" || return 1
  tmp="$(mktemp "${XKIT_NODES_METRICS}.tmp.XXXXXX")" || return 1
  if ! printf '%s\n' "$data" >"$tmp" || ! chmod 640 "$tmp" || ! mv -f "$tmp" "$XKIT_NODES_METRICS"; then
    rm -f "$tmp"; return 1
  fi
  history="$(nodes_history_update "$nodes_json" "$now")" || {
    warn "История метрик недоступна: $XKIT_NODES_HISTORY"; history='{"version":1,"updated":null,"samples":{}}';
  }
  jq -c --argjson h "$history" '. + {history:$h.samples,history_updated:$h.updated}' <<<"$data"
}

# санитизированные данные для data.json: БЕЗ privateKey Reality, UUID/subId
# клиентов и прочих внутренностей — только агрегаты, которые ждёт JS
# (поля совпадают с тем, что рендерит index.html: tag/port/proto/enable/...)
dash_sanitize_inbounds() { # $1 = массив инбаундов (JSON) -> stdout
  # ИДЕМПОТЕНТНО: raw из API (.protocol, .settings-строка) -> sanitized;
  # уже sanitized (.proto, .clients-число) проходит без изменений —
  # на этом построены stale-ветка и финальный барьер перед записью.
  # Порядок веток clients КРИТИЧЕН: у raw из API поля .clients НЕТ вообще
  # (клиенты лежат внутри settings-строки), поэтому raw-детект через .settings
  # должен идти ДО прочих веток; .clients-массив (полу-sanitized) считаем длиной,
  # null/битое/пусто -> 0. Всегда возвращаем валидный JSON-массив (даже на
  # пустом входе jq молчит с кодом 0 — потому явная проверка на непустой вывод).
  local out
  out="$(jq -c '[ .[] | {
      tag: (.tag // "inbound"),
      port: .port,
      proto: (.protocol // .proto // ""),
      enable: (if (.enable == null) then true else .enable end),   # // true съел бы явный false
      up: (.up // 0),
      down: (.down // 0),
      total: ((.up // 0) + (.down // 0)),
      clients: (if (.clients|type) == "number" then .clients
                elif (.settings? // null) != null and (.settings? // "") != "" then
                  ([ ((.settings | (if type=="string" then (fromjson? // {}) else (. // {}) end) | (.clients // []))[]) ] | length)
                elif (.clients|type) == "array" then ([ .clients[] ] | length)
                else 0 end)
    } ]' <<<"$1" 2>/dev/null)" || out=""
  [ -n "$out" ] && echo "$out" || echo '[]'
}

# топ-10 пользователей по ПОТРАЧЕННОМУ трафику (up+down из clientStats,
# а не квота .total клиента, как было раньше; clientStats бывает строкой)
dash_sanitize_users() { # $1 = массив инбаундов (JSON) -> stdout
  jq -c '[ .[] | . as $ib |
      ((.settings | (if type=="string" then (fromjson? // {}) else (. // {}) end) | .clients // [])[]) | . as $c |
      (($ib.clientStats // [] | if type=="string" then (fromjson? // []) else . end)
        | map(select(.email == $c.email)) | .[0] // {}) as $s |
      {email:($c.email // "?"), ib:($ib.tag // "?"),
       up:($s.up // 0), down:($s.down // 0),
       total:(($s.up // 0) + ($s.down // 0)),
       enable:(if ($c.enable == null) then true else $c.enable end), expiryTime:($c.expiryTime // 0)} ]
    | sort_by(-(.total // 0)) | .[0:10]' <<<"$1" 2>/dev/null || echo '[]'
}

# whitelist полей пользователя (для users из прошлого data.json): пропускаем
# только safe-поля — дрейф формата или мусор в старом файле не попадёт в запись
dash_users_whitelist() { # $1 = массив users (JSON) -> stdout
  jq -c '[ .[] | {
      email:(.email // "?"), ib:(.ib // "?"),
      up:(.up // 0), down:(.down // 0), total:(.total // 0),
      enable:(if (.enable == null) then true else .enable end), expiryTime:(.expiryTime // 0)} ]' <<<"$1" 2>/dev/null || echo '[]'
}

# права на файлы дашборда: читать должен только nginx, не все локальные юзеры
dash_fix_perms() {
  local ngu="www-data" nguser=""
  if ! getent group www-data >/dev/null 2>&1; then
    # не-Ubuntu (CentOS и т.п.): находим юзера процесса nginx и берём ЕГО
    # ПЕРВИЧНУЮ ГРУППУ (id -gn) — юзер ≠ группа, раньше подставляли юзера в chgrp
    nguser="$(ps -eo user=,comm= 2>/dev/null | awk '$2=="nginx" && $1!="root"{print $1; exit}')"
    [ -n "$nguser" ] && ngu="$(id -gn "$nguser" 2>/dev/null || true)"
  fi
  if [ -z "$ngu" ] || ! getent group "$ngu" >/dev/null 2>&1; then
    warn "dash_fix_perms: группа nginx не найдена — файлы дашборда могут быть world-readable"
    return 0
  fi
  chgrp "$ngu" /var/lib/xkit "$XKIT_DASH_DIR" 2>/dev/null || true
  chmod 750 /var/lib/xkit "$XKIT_DASH_DIR" 2>/dev/null || true
  local f
  for f in "${XKIT_DASH_DIR}/index.html" "${XKIT_DASH_DIR}/data.json" \
    "${XKIT_DASH_DIR}/manifest.webmanifest" "${XKIT_DASH_DIR}/sw.js" \
    "${XKIT_DASH_DIR}/icon-192.png" "${XKIT_DASH_DIR}/icon-512.png"; do
    [ -f "$f" ] || continue
    chown root:"$ngu" "$f" 2>/dev/null || true
    chmod 640 "$f" 2>/dev/null || true
  done
  return 0
}

# построить data.json (+ восстановить index.html, если удалён)
dash_gen() {
  load_xkit_env 2>/dev/null || { err "Сначала установка (пункт 1)"; return 1; }
  [ -n "${XKIT_HOST:-}" ] || { err "Сначала установка (пункт 1)"; return 1; }
  [ "${XKIT_DASH:-0}" = "1" ] || { err "Дашборд не установлен — меню: «Веб-дашборд» (или xkit dash install)"; return 1; }
  mkdir -p -m 750 "$XKIT_DASH_DIR" 2>/dev/null || { err "Не удалось создать $XKIT_DASH_DIR"; return 1; }

  # Блокировка В SUBSHELL: fd 9 живёт только внутри ( ... ) 9>lock и закрывается
  # при его выходе. Раньше `exec 9>` держал lock в интерактивной сессии —
  # cron (xkit dash gen) не мог обновить дашборд, пока админ сидел в меню.
  (
    flock -n 9 || { warn "Предыдущее построение ещё не закончилось — пропускаю"; exit 0; }
    dash_gen_locked
  ) 9>"${XKIT_DASH_DIR}/.lock"
  return $?
}

# вся работа dash_gen под lock (вызывается в subshell из dash_gen)
dash_gen_locked() {
  # 750 СРАЗУ (без окна 755): раньше каждый запуск ставил 755, и между ним
  # и dash_fix_perms каталог был проходим для всех локальных юзеров
  # ВАЖНО: umask действует только в ЭТОМ subshell (dash_gen зовёт нас в ( ... ) 9>lock).
  # НЕ выносить umask в dash_gen вне subshell — иначе он утечёт в интерактивную
  # сессию админа и все последующие файлы кита будут создаваться с маской 640.
  umask 027   # новые файлы (data.json/index.html/.tmp) создаются сразу 640
  chmod 750 /var/lib/xkit "$XKIT_DASH_DIR" 2>/dev/null || true

  # Каркас и PWA перезаписываются при каждой генерации: обновление XKIT
  # не оставляет старый JS/service worker на диске.
  local shell_tmp
  shell_tmp="$(mktemp "${XKIT_DASH_DIR}/.index.html.tmp.XXXXXX")" || return 1
  dash_write_html > "$shell_tmp" && mv -f "$shell_tmp" "${XKIT_DASH_DIR}/index.html" \
    || { rm -f "$shell_tmp"; err "Не удалось записать каркас дашборда"; return 1; }
  dash_write_pwa || { err "Не удалось записать PWA-файлы"; return 1; }

  local panel_st="down" inbounds="[]" users="[]" totals='{"up":0,"down":0,"total":0}'
  local stale=0
  if kit_session >/dev/null 2>&1; then
    panel_st="ok"
    # ВАЖНО: в data.json уходит САНИТИЗИРОВАННЫЙ список (см. dash_sanitize_*)
    inbounds="$(dash_sanitize_inbounds "$INBOUNDS")"
    local sums tu td
    # total = up+down (потрачено): .total инбаунда — квота, а не трафик
    sums="$(jq -r '[( [.[].up // 0] | add // 0 ), ( [.[].down // 0] | add // 0 )] | @tsv' <<<"$INBOUNDS" 2>/dev/null)"
    if [[ "${sums:-}" =~ ^[0-9]+[[:space:]]+[0-9]+$ ]]; then
      read -r tu td <<<"$sums"
      totals="$(jq -nc --argjson u "$tu" --argjson d "$td" '{up:$u,down:$d,total:($u+$d)}')"
    fi
    users="$(dash_sanitize_users "$INBOUNDS")"
    rm -f "${COOKIE_JAR:-}" 2>/dev/null || true
  else
    # Панель недоступна: НЕ затираем прошлый трафик пустотой —
    # берём инбаунды/пользователей из прошлого data.json (stale лучше пустого).
    # ВАЖНО (аудит №4): прошлый data.json мог быть записан v4.3 с СЫРЫМИ
    # инбаундами (privateKey Reality, UUID/subId). Апгрейд + падение панели
    # до первого успешного gen = stale-ветка вернула бы утечку. Поэтому
    # sanitize при ЧТЕНИИ — идемпотентно (sanitized проходит без изменений),
    # сырые данные не доходят до записи ни при каком сценарии.
    if [ -r "${XKIT_DASH_DIR}/data.json" ]; then
      local old old_inb old_users
      old="$(cat "${XKIT_DASH_DIR}/data.json" 2>/dev/null || true)"
      if jq -e '(.inbounds|type) == "array"' <<<"$old" >/dev/null 2>&1; then
        old_inb="$(jq -c '.inbounds // []' <<<"$old")"
        inbounds="$(dash_sanitize_inbounds "$old_inb")"
        if [ "$(jq 'length' <<<"$inbounds" 2>/dev/null || echo 0)" -eq 0 ]; then
          # формат не распознан — пусто безопаснее, чем raw
          inbounds="[]"; users="[]"
        elif jq -e '[ .[] | has("settings") or has("streamSettings") ] | any' <<<"$old_inb" >/dev/null 2>&1; then
          # raw v4.3 ИЛИ смешанный формат (№1, аудит №1): users считаем из СЫРЫХ
          # элементов и ОБЪЕДИНЯЕМ с users sanitized-элементов прошлого data.json
          # (раньше смешанный дамп молча терял клиентов sanitized-инбаундов)
          local raw_inb
          raw_inb="$(jq -c '[ .[] | select(has("settings") or has("streamSettings")) ]' <<<"$old_inb" 2>/dev/null || echo '[]')"
          old_users="$(jq -c '.users // []' <<<"$old" 2>/dev/null || true)"
          jq -e '(.|type) == "array"' <<<"$old_users" >/dev/null 2>&1 || old_users="[]"
          users="$( { dash_sanitize_users "$raw_inb"; printf '%s\n' "$old_users"; } \
            | jq -c -s 'add | unique_by((.email // "?")+"\u0000"+(.ib // "?")) | sort_by(-(.total // 0)) | .[0:10]' 2>/dev/null || echo '[]')"
          users="$(dash_users_whitelist "$users")"
        else
          # уже sanitized (v4.4+): оставляем users, пропустив через whitelist
          old_users="$(jq -c '.users // []' <<<"$old" 2>/dev/null || true)"
          if jq -e '(.|type) == "array"' <<<"$old_users" >/dev/null 2>&1; then
            users="$(dash_users_whitelist "$old_users")"
          else
            users="[]"
          fi
        fi
        # totals пересчитываем из уже sanitized-инбаундов (up+down)
        local s2 tu2 td2
        s2="$(jq -r '[( [.[].up // 0] | add // 0 ), ( [.[].down // 0] | add // 0 )] | @tsv' <<<"$inbounds" 2>/dev/null)"
        if [[ "${s2:-}" =~ ^[0-9]+[[:space:]]+[0-9]+$ ]]; then
          read -r tu2 td2 <<<"$s2"
          totals="$(jq -nc --argjson u "$tu2" --argjson d "$td2" '{up:$u,down:$d,total:($u+$d)}')"
        else
          totals='{"up":0,"down":0,"total":0}'
        fi
        stale=1
      fi
    fi
  fi

  local master_json
  master_json="$(dash_master_json)"

  # --- общий сборщик: туннель/API/трафик/CPU/RAM; тот же кэш читает TUI ---
  local nodes_json="[]" metrics_json history_json='{}'
  metrics_json="$(nodes_metrics_collect)" || return 1
  nodes_json="$(jq -c '.nodes' <<<"$metrics_json")" || return 1
  history_json="$(jq -c '.history // {}' <<<"$metrics_json")" || return 1

  # --- аренда мастер-сервера ---
  local mexp expiry_json="null" mdl
  mexp="$(expiry_get master -)"
  if [ -n "$mexp" ]; then
    mdl="$(days_left "$mexp")"
    expiry_json="$(jq -nc --arg d "$mexp" --argjson dl "${mdl:-null}" \
      --arg n "$(expiry_note master -)" \
      '{date:$d, days_left:$dl, note:(if $n=="" then null else $n end)}')"
  fi

  # Последний барьер (аудит №4): идемпотентная санитизация ПЕРЕД записью —
  # закрывает любые будущие пути попадания сырых данных. users здесь НЕ
  # пересчитываем: у sanitized-инбаундов нет settings/clientStats (стал бы пуст)
  inbounds="$(dash_sanitize_inbounds "$inbounds")"

  # v4.5: явный режим на дашборде — снимает вопрос «почему таблица нод пустая»
  local mode="solo"
  [ "$(jq 'length' <<<"$nodes_json" 2>/dev/null || echo 0)" -gt 0 ] && mode="master"

  local data
  data="$(jq -n \
      --arg v "$XKIT_VERSION" --arg host "$XKIT_HOST" \
      --arg panel "$panel_st" --arg strat "${XKIT_BAL_STRATEGY:-leastLoad}" \
      --arg mode "$mode" \
      --arg gen_str "$(date '+%Y-%m-%d %H:%M:%S %Z')" \
      --argjson gen "$(date +%s)" \
      --argjson master "$master_json" --argjson inb "$inbounds" \
      --argjson users "$users" --argjson nodes "$nodes_json" --argjson history "$history_json" \
      --argjson totals "$totals" --argjson exp "$expiry_json" \
      --argjson stale "$( [ "$stale" = "1" ] && echo true || echo false )" \
      '{version:$v, host:$host, generated:$gen, generated_str:$gen_str, mode:$mode,
        panel:$panel, strategy:$strat, master:$master, totals:$totals,
        inbounds:$inb, users:$users, nodes:$nodes, history:$history, expiry_master:$exp, stale:$stale}')" \
    || { err "Не удалось собрать data.json"; return 1; }

  printf '%s\n' "$data" > "${XKIT_DASH_DIR}/.data.json.tmp" \
    && mv -f "${XKIT_DASH_DIR}/.data.json.tmp" "${XKIT_DASH_DIR}/data.json" \
    || { err "Не удалось записать ${XKIT_DASH_DIR}/data.json"; return 1; }
  dash_fix_perms

  local ncnt ecnt stale_note=""
  ncnt="$(jq 'length' <<<"$nodes_json" 2>/dev/null || echo 0)"
  ecnt="$(jq 'length' <<<"$inbounds" 2>/dev/null || echo 0)"
  [ "$stale" = "1" ] && stale_note=" (панель была недоступна — показаны данные прошлого построения)"
  ok "Дашборд построен: панель=${panel_st}, нод=${ncnt}, инбаундов=${ecnt}${stale_note}"
  log "Файлы: ${XKIT_DASH_DIR}/data.json; URL: https://${XKIT_HOST}$(dash_path)"
  return 0
}

# nginx-локейшн дашборда: секретный путь + security-заголовки + Basic Auth
# + опц. allow IP/CIDR. ВНИМАНИЕ: функция пишет В STDOUT конфига — warn/ok тут
# запрещены (ушли бы в файл конфига), невалидные адреса молча пропускаются
# (deny all; остаётся — fail-closed)
generate_dash_block() {
  local dp; dp="$(dash_path)"
  cat <<BLK

    # --- веб-дашборд xkit (секретный путь; данные: ${XKIT_DASH_DIR}) ---
    location = ${dp%/} {
        return 301 ${dp};
    }
    location ^~ ${dp} {
        alias ${XKIT_DASH_DIR}/;
        index index.html;
        types { text/html html; application/json json; application/manifest+json webmanifest; text/javascript js; image/png png; }
        add_header X-Robots-Tag "noindex, nofollow" always;
        add_header Referrer-Policy "no-referrer" always;
        add_header Cache-Control "no-store" always;
        add_header X-Frame-Options "DENY" always;
        add_header X-Content-Type-Options "nosniff" always;
        access_log off;
BLK
  if [ "${XKIT_DASH_AUTH:-1}" = "1" ] && [ -s "${XKIT_DASH_HTPASSWD}" ]; then
    printf '        auth_basic "xkit-dashboard";\n'
    printf '        auth_basic_user_file %s;\n' "${XKIT_DASH_HTPASSWD}"
  fi
  if [ -n "${XKIT_DASH_ALLOW:-}" ]; then
    local -a _dash_ips=()          # local: не утекает в глобальный scope
    local a
    IFS=',' read -ra _dash_ips <<<"${XKIT_DASH_ALLOW}"
    for a in "${_dash_ips[@]}"; do
      a="${a// /}"; [ -n "$a" ] || continue
      # кривой адрес НЕ печатаем (иначе nginx -t падает и откат блокирует все
      # будущие apply); ручная правка xkit.env больше не ломает nginx
      is_ip "$a" || is_cidr "$a" || continue
      printf '        allow %s;\n' "$a"
    done
    printf '        deny all;\n'
  fi
  printf '    }\n'
}

# PWA: кэшируется только пустой статический каркас. data.json, метрики,
# адреса нод и история никогда не попадают в Cache Storage/localStorage.
dash_write_pwa() {
  cat > "${XKIT_DASH_DIR}/manifest.webmanifest" <<'JSON'
{"name":"XKIT Operations","short_name":"XKIT","start_url":"./","scope":"./","display":"standalone","background_color":"#09110f","theme_color":"#09110f","icons":[{"src":"./icon-192.png","sizes":"192x192","type":"image/png"},{"src":"./icon-512.png","sizes":"512x512","type":"image/png"}]}
JSON
  cat > "${XKIT_DASH_DIR}/sw.js" <<'JS'
"use strict";
const SHELL="xkit-shell-v620";
const ASSETS=["./index.html","./manifest.webmanifest","./icon-192.png","./icon-512.png"];
self.addEventListener("install",e=>e.waitUntil(caches.open(SHELL).then(c=>c.addAll(ASSETS)).then(()=>self.skipWaiting())));
self.addEventListener("activate",e=>e.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k.startsWith("xkit-shell-")&&k!==SHELL).map(k=>caches.delete(k)))).then(()=>self.clients.claim())));
self.addEventListener("fetch",e=>{
  const u=new URL(e.request.url);
  if(e.request.method!=="GET"||u.origin!==self.location.origin)return;
  if(u.pathname.endsWith("/data.json")){e.respondWith(fetch(e.request,{cache:"no-store"}));return;}
  if(e.request.mode==="navigate"){
    e.respondWith(fetch(e.request,{cache:"no-store"}).catch(()=>caches.match("./index.html")));return;
  }
  if(ASSETS.some(a=>u.pathname.endsWith(a.replace("./","/"))))e.respondWith(caches.match(e.request).then(r=>r||fetch(e.request)));
});
JS
  base64 -d > "${XKIT_DASH_DIR}/icon-192.png" <<'PNG'
iVBORw0KGgoAAAANSUhEUgAAAMAAAADACAIAAADdvvtQAAAE1ElEQVR42u3dPW4UQRAG0HHLCREiJENEpKSIs5ByJlLOgkhJiRAZ1yBYybJs2VrP7nTXz/siSw7c2/WmpmZmd33z6s3rTWRvhi0QgAQgAUgAEgFIABKABCARgAQgAUgAEgFIABKABCARgAQgAUgAEoBEABKABCABSAQgAUgAEoBEABKABCCpldt0K3736WPtkvz9+SvRam9SfMVdeTR5MUUH9JjOv99/aqN5++F9IkZBAT1wUx7NmZgCSooI6L6etnSeYhTNUCxA6KRjFAjQnR50zmEUxNCgJ1fu9ifIlWmIDnTaC3R2tKLlfWjQk7oVLe9Dgx6GsgKip4ChQQ9D+QC1fbZVb1fH8kNHUu/kWHWg0FPjRDaW6JEyOzwWHi5SYFe9pVXyADp6+vny41vkvZ6wvPmTUJ0OdCpPWEPBl5cA0KHt535hAhZp5vImN6Hb7EdAxmP6tObvn7/qQEH1hFKVYpEdAT1fgCDlSbHIBICuPgCds/XLy7NqkTPHoHwd6MuPb+dv+kJDL1pk3lY00ulJMWVnWWc7QDWuXCq9tNFhoycf3Dv+XN4Do8uzsGmG6t1rLgho3/E6obT7/kTq83LWDhTQUEM9uU9hBQbqAi9hdCvAQU2o1eBcaoiOYKitnq3tOxKvaKjbZVdBQAsH6p6Dc8EOtMQQPaVOYSkKU+9RTKkZaOZA3XlwNkRfSqH54FwZ0IRhyOhTvAMdaoieFqewUAUrrKfyDHTEQG1w7jVEX9cQPa7C9hty2dUU0FUGaoNz6w50oSF6nMJml7OPnkYz0L6B2uAMkACU58zSrf2060CHFrihno6nsIPK3FNP0xno6sVuq6fvEH3FknfW4ypMAFraOZq3n+4d6MLy0+MUth8BPQAJQBdn5sd6AKKHIYCuWn6GzEAC0NLO4etd6GEIoNXFbmto0MMQQFEK3NCQqzAB6Jje8P3z1/j/lwOgIievtoYGPU+1nwc/MNQR0FU+mMyQGWi/nksMAdRxcN7xq85NaNBzPhGGugAKVbbahgY9L+ouBurigCZ8HxRDrsIuBeGirCagmd8HZaCuBihFeeoZGp31LPlkajFDgx6GdKA1egzUFQBF+CLVzgP1oIehpoAKFKDASxittj7gt7RmNzToYchVWKBrJf/qwOBsoK4LqPD7IpK+tGSAsjw57/OEP98p7EWf91tYlRctMu/klHWIPmfHl1clxSJzAPr789e2bW8/vJ9WniCFWbLI0z6f9lwH2lOeUId1ikXuzm32F3AqQ65LmEr3iorcSLxfkoDlCb68HICOGIMeFylseaYtb+YAtBV7lBH84C75lGMqoKObkExuP5vPhUlKQJpQmV2dDWhmd+2ZyTs8Vr1CTSj79LN+BmKowE6uAeREVmZXx9pXqwnlPXmtP4UxlF3Ptvw+EEOp9WwRbiQylFfPtm03r968jrAd7z59PP3w7/cfOM685opwLRLlUcbdXmhFifQE6kAP+pBW9AydLdJ9kFiAMEpEJy6gB4Y6M3pwQg94AzYooKckdcD0eAqMfOM+OqCnGDVJ/Gc+OQC1wpTrQWE+QBIq3tIqAAlAApAAJAKQACQACUAiAAlAApAAJAKQACQACUAiAAlAApAAJACJACQACUACkAhAApAAJACJACQASbz8BwOpWSUgNQcYAAAAAElFTkSuQmCC
PNG
  base64 -d > "${XKIT_DASH_DIR}/icon-512.png" <<'PNG'
iVBORw0KGgoAAAANSUhEUgAAAgAAAAIACAIAAAB7GkOtAAAMQElEQVR42u3dsVIbTQKFUeRyokilkIwiIiWleBalPJNSnkVFSkpEkfEaziiBQCOjmZ7uvudE/wa7a89o7tcjvOvFcr26ACDPH5cAQAAAEAAABAAAAQBAAAAQAAAEAAABAEAAABAAAAQAAAEAQAAAEAAABAAAAQBAAAAQAAAEAAABAEAAABAAAAQAQAAAEAAABAAAAQBAAAAQAAAEAAABAEAAABAAAAQAAAEAQAAAEAAABAAAAQBAAAAQAAAEAAABAEAAABAAAAQAQAAAEAAABAAAAQBAAAAQAAAEAAABAEAAABAAAAQAAAEAQAAAEAAABAAAAQBAAAAQAAAEAAABAEAAABAAAAQAAAEAEAAABAAAAQBAAAAQAAAEAAABAEAAABAAAAQAAAEAQAAAEAAABAAAAQBAAAAQAAAEAAABAEAAADjur0sQ5eru1kXguLenZxchxGK5XrkKth5UQQAw+iAGAoDRBzEQALrZ/feXV5eO4y5vrpVAAGh79209s1RBCQSAeabf6FNJDGRAACix+0afmmOgBALA+NNv92moBDIgAJh+ZAAB4P/X3+7TQQk0QAAw/cgAAoDpRwYQAOtv+knLgAYIgOk3/cgAM/D3AVh/KOfbT7j/PytvAOnrb/oJfxXwHiAADv6Q2wAZEAAHf/AqQAl+BmD9YU6HT4EfCQiA9QcNYFq+Apph/U0/fOvL10G+CxIAB3/IbYAMTMpXQNYfKuLrIAGw/qABGiAA1h80QAMEoKdPM+CpEYD+j/8+xzBKA7wECID1Bw1AAKw/aAACYP1BAxAA6w8agADU8UkFPFkCkHL8Bzx3ApD4KXRIgWIvARogANYfNAABqOlzCXjWBCDl+A94EgUg8TPnSAIzvgRogAB4IQXPHQLglRM8lQiAYwh4+hCA8Q8aPn9QTwO8BAiA10zwhCIAXj/Bk4gAOFyA5xQBcOgAzyMC4FgBnlYBwHEDPJUCALRns9u6CAjA5G+UgQcN49LEDXKb/G8CBADjkpvnzW7rTiEAUx3/05bly7j4MHhj8+QKgHdMI0LVtyn29vlRsABgVkTazWLYYrleuQonvkWGHC4Gh+Px/sEHo6FXtMD7dXlz/fHPb0/PPi3eADhpU06ZFUfLhtbf/UIAsCmhd8r9QgB+Kef7H5siGz3xPwgQAEyDm/X13+teIwCMswjWpMVUu2sIANYk90XNXUMABvT9AwBrEnu/Qu6aHwMIANbE/Tr2H+vGCQBZUzLdmri86oIA4FGnpbvmgyEAfNLfDwDsiLuWdu/8GEAAsCPu2qn/dW6fANDbiJTfEZe93cvo9gkARsSI+NggAHiMybt3PjwCgAWxILmXzo8EBIAm56OeBXE7Wr9obqIAxGn3z4CaD+s/rtb/NjF/ElQAglT4uGqA9UcA0ABAAADHfwQALwFYfwQADbD+PjwIABpg/X1sEAA0wPpbfwQADQAEABz/Hf8RALwEWH/rjwCgAdbf+iMAaID1t/4IABrgN2v9EQA0ABAAcPx3/BcAl8BLgHG0/ggAGmAirT8CgAYYSuuPAKABGgACADj+IwB4CfASYP0RADRAA6w/AoAGaID1RwDQgMgGWH8EAA1Ifw8AAYAgjv8IAF4CEl8CrD8CgAYkNsD6IwBoQGIDrD8CgAYkNsD6IwBoQPp7AAgABHH8RwDwEpA4uNYfAUADEmfX+iMAaEDi+Fp/BAANMMFuEAKAiYmhPQgAJA6xL38QALwEJDbA+iMAaEBiA6w/AoAGJDbA+iMAkP4eAAIAQRz/EQBIfAmw/ggAJDbA+iMAkNgA648AQGIDrD8CAOnvASAAEMTxHwGAxJcA648AQGIDrD8CAIkNsP4IAKS/B7iYCAAEzZY/OIQAQIcGx92XPwgAdDteRybe+iMAkNgA648AQGIDrD8CAOnvASAAEMTxHwSAxJcA6w8CgGlziRAAMHAuDgIAZs5lQQDA2IEAAIqIAIDJcykQADB8LgICAObPbx8BACPoN44AgCkEAQDN0zwEAAIH0fojAJA4i9YfAYDEcbT+CACYSBAA0DYQAOh4KK0/AgCJc2n9EQBIHE3rjwBA4nRafwQADCgIAKgXCAB0PKPWHwGAxDG1/ggAJE6q9UcAIHFYrT8CAOYVBAD0CQQAOh5Z648AACAAMIHNbusXBgIAGgACgIUFBADr7xcJAoD190sFAcD6+wWDAGBM/bJBAEADQACwoSAAYP39FhAAMJ1+IwgAGE2/HQQAzKXfFAIAaAACAFYSBACsv7whAGAcNQABALOoAQgACJ6LgACANQQBwPr7jYMAYAT99kEAMH8uAggAhs+lAAEADQABwN4BAoD1d1lAADBzLg4IAAbOJQIBwLTtebx/eLx/cKFAAAilASAAxB3/3RcQANLX30sAAgC5Z38NQAAgcf01AAGAzg1OvAYgAJC7XH44jABAb+vf7rJ7CUAAMFiF1t8XQQgA5J79NQABgMT11wAEANJpAAIAccd/EABIX38vAQgA5J79NQABgMT11wAEAHLXXwMQAEinAQgAxB3/QQAgff29BCAAWP/cs78GIABY/8T11wAEAHLXXwMQABz/hccPnBEArL8VdoMQAIxL1Pr7IggBwPrnjq8GIABY/9zZ1QAEAHJpAAKA43/o2oIAYP1z199LAAKA9c89+2sAAoD1T1x/DUAAsP65668BCACk0wAEAMf/uOM/CADWP339vQQgAFj/3LO/BiAAWP/E9dcABADrn7v+GoAAQDoNQABw/I87/oMAYP3T199LAAKACcg9+2sAAoCHP3H9NQABgHQagADgmY87/oMAYP3T199LAAKARz337K8BCAAe8txvfjQAAcD659IABAA0QAMQABz/AQHA+nsJ8IFBALD+GuBjgwBg/TVAAxAArL8GaAACABqgAQgAjv+AAFh/6+8lwEsAAmBE/HrcPg3gR4vleuUqHLq6u/345/eXV68C1j9zc1u/iZc31x///Pb07NPlDcBZ0nC4dyf9MtxEAcCOoN8IAHbEfPjYIAA09DAXfp7Nh3gjACSuiflo92L60l8AsCbWX7kRgGz7f2Js/0+SWROUuxX+DKgAUOg1X10EBgEg8Zk3Ii1utC/9EQCbYv01GwHgsy5/DDD6BNgRza6THwAIANN+CWD9NRsBwKzQwM3ypT8CwDizYkpkHgHoWfc/Bvj1QFgTta6ZHwAIAFN9RWD91RoBIHFcrElDDfClPwJwlqhvgQbHxZpIdf18/yMAlDhgItUIQOjhImFc9nfEpoi3J7Qz/lL4k7T+d8SfabPbWv/Kb5DpPwyA73+8AeBEmXKD3Ca8AXgJAMd/x39vAAAIwHQHDcBTKQCd80YJnlYBwHEDPI8C4FgBeE4FwKED8CQKgMMF4AkVgN4/YY4eUM/x3/oLgNdP8PQhAF4zwVOJADiGgOcOAZjkuOGzCDOuv+O/AHjlBE8iAuCFFDxrCEDJo4fPJRRef8d/AdAAsP4IQAUNADx3AuCQAniyBCDsMOKTCpOuv+O/AGgAWH8EQAPA+iMAGgDWHwHQALD+CEBNn2PAUyMAKS8BPs1w5vo7/guABoD1RwA0AKw/51ks1ytXYWpXd7f7//L95dU1gcH1N/0C0GcDZAAc/GfnK6BCfB0E1l8ANEADwPpXwVdApR1+F3Th6yBMv/UXgOQMaAAO/i6LAHgVAAd/SvAzgNl8+4n3UwGsP94AvAp4FcD0IwCpDZABOp5+6y8AyACmHwFABjD9CAA/NUAJaHT3rb8AIAOYfgSAkTKgBNS8+6ZfAChUAjGgktG3+wLAbBkQA2YZfdMvAFRXAlVgoq23+wJAkyWAUdh9AUAMMPoIAGKA0UcAUAVsPQIAQHX8fQAAAgCAAAAgAAAIAAACAIAAACAAAAgAAAIAgAAAIAAACAAAAgCAAAAgAAAIAAACAIAAACAAAAgAAAIAgAAAIAAAAgCAAAAgAAAIAAACAIAAACAAAAgAAAIAgAAAIAAACAAAAgCAAAAgAAAIAAACAIAAACAAAAgAAAIAgAAAIAAAAuASAAgAAAIAgAAAIAAACAAAAgCAAAAgAAAIAAACAIAAACAAAAgAAAIAgAAAIAAACAAAAgCAAAAgAAAIAAACAIAAAAgAAAIAgAAAIAAACAAAAgCAAAAgAAAIAAACAIAAACAAAAgAAAIAgAAAIAAACAAAAgCAAABwun96qUoFCI2xfQAAAABJRU5ErkJggg==
PNG
}

# HTML-каркас дашборда (статичный; данные подтягивает JS из ./data.json)
dash_write_html() { # stdout: index.html
  cat <<'HTML'
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="robots" content="noindex,nofollow">
<meta name="theme-color" content="#09110f">
<link rel="manifest" href="./manifest.webmanifest">
<link rel="icon" href="./icon-192.png">
<link rel="apple-touch-icon" href="./icon-192.png">
<title>XKIT · Operations</title>
<style>
:root{color-scheme:dark;--bg:#09110f;--panel:#101b18;--line:#243a33;--tx:#e1ebe6;--mut:#82988f;--ok:#6ee7b7;--warn:#f4bf75;--bad:#fb7185;--acc:#93c5fd}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--tx);font:14px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}.wrap{max-width:1440px;margin:auto;padding:24px}.top{display:flex;justify-content:space-between;gap:20px;align-items:flex-start;margin-bottom:22px}.brand{font-size:22px;font-weight:650;letter-spacing:-.02em}.brand span{color:var(--ok)}.sub,.mut{color:var(--mut)}.sub{font-size:12px;margin-top:4px}.live{font:12px ui-monospace,SFMono-Regular,Consolas,monospace;color:var(--mut);text-align:right}.grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px;margin-bottom:22px}.panel{border-top:1px solid var(--line);background:var(--panel);padding:16px}.panel h2,.section-title{font-size:11px;text-transform:uppercase;letter-spacing:.11em;color:var(--mut);margin:0 0 12px}.kv{display:flex;justify-content:space-between;gap:12px;padding:4px 0}.kv b,.num{font-variant-numeric:tabular-nums;font-family:ui-monospace,SFMono-Regular,Consolas,monospace;font-weight:550}.badge,.pill{display:inline-block;padding:2px 7px;border:1px solid var(--line);font-size:11px;font-weight:600}.ok{color:var(--ok)}.warn{color:var(--warn)}.bad{color:var(--bad)}.badge.ok{border-color:#285f4c;background:#102a22}.badge.warn{border-color:#664c2c;background:#2a2115}.badge.bad{border-color:#6b303c;background:#2b171c}.err{padding:12px 16px;border-left:3px solid var(--bad);background:#25171a;margin-bottom:18px}.notice{padding:12px 16px;border-left:3px solid var(--line);color:var(--mut);margin-bottom:18px}.section{margin:24px 0}.section-head{display:flex;justify-content:space-between;align-items:baseline;border-bottom:1px solid var(--line);padding-bottom:8px}.nodes{display:grid;gap:10px}.node{background:var(--panel);padding:16px;border-left:2px solid var(--line)}.node.fresh{border-left-color:var(--ok)}.node.stale{border-left-color:var(--warn)}.node-head{display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap}.node-name{font-size:16px;font-weight:650}.host{color:var(--mut);font:12px ui-monospace,SFMono-Regular,Consolas,monospace}.node-grid{display:grid;grid-template-columns:1.2fr 1fr 1fr 1fr;gap:16px;margin-top:14px}.metric-label{font-size:10px;color:var(--mut);text-transform:uppercase;letter-spacing:.08em}.metric-value{font:16px ui-monospace,SFMono-Regular,Consolas,monospace;margin:3px 0}.metric-detail{font-size:11px;color:var(--mut)}.spark{display:block;width:100%;height:34px;margin-top:6px}.spark polyline{fill:none;stroke:var(--ok);stroke-width:1.5;vector-effect:non-scaling-stroke}.probes{display:flex;gap:6px;flex-wrap:wrap;margin-top:12px}.probe{font:10px ui-monospace,SFMono-Regular,Consolas,monospace;color:var(--mut);border:1px solid var(--line);padding:2px 5px}.probe.good{color:var(--ok);border-color:#285f4c}.probe.bad{color:var(--bad);border-color:#6b303c}.tablewrap{overflow:auto}table{width:100%;border-collapse:collapse}th{text-align:left;color:var(--mut);font-size:10px;text-transform:uppercase;letter-spacing:.07em;padding:8px;border-bottom:1px solid var(--line)}td{padding:8px;border-bottom:1px solid #1a2a25;white-space:nowrap}tr:last-child td{border:0}footer{border-top:1px solid var(--line);padding-top:14px;color:var(--mut);font-size:11px}.offline{display:none}@media(max-width:980px){.grid{grid-template-columns:1fr}.node-grid{grid-template-columns:repeat(2,1fr)}}@media(max-width:600px){.wrap{padding:16px}.node-grid{grid-template-columns:1fr 1fr;gap:12px}.top{display:block}.live{text-align:left;margin-top:10px}}@media(prefers-reduced-motion:no-preference){.node{animation:enter .2s ease-out}@keyframes enter{from{opacity:.6}to{opacity:1}}}
</style>
</head>
<body><main class="wrap">
<header class="top"><div><div class="brand"><span>XKIT</span> / Operations</div><div class="sub" id="hdr">Ожидание первого ответа сервера…</div></div><div class="live" id="freshness">ДАННЫЕ НЕ ПОЛУЧЕНЫ</div></header>
<div class="err" id="err" style="display:none"></div><div class="notice offline" id="offline">Офлайн-каркас: метрики не сохраняются в браузере. Подключитесь к серверу для актуальных данных.</div>
<div class="notice" id="solo" style="display:none"></div>
<section class="grid" id="cards"></section>
<section class="section"><div class="section-head"><h2 class="section-title">Ноды / ресурсы и активность</h2><span class="mut">TCP ≠ API ≠ SSH ≠ UDP ≠ клиентский probe</span></div><div class="nodes" id="nodes"></div></section>
<section class="section"><h2 class="section-title">Инбаунды мастера</h2><div class="tablewrap"><table id="inbounds"></table></div></section>
<section class="section"><h2 class="section-title">Топ пользователей по потреблённому трафику</h2><div class="tablewrap"><table id="users"></table></div></section>
<footer>XKIT v<span id="ver">?</span> · сбор каждые 5 минут · опрос страницы каждые 30 секунд · PWA не кэширует метрики</footer>
</main>
<script>
"use strict";
var D=null;
function $(id){return document.getElementById(id)}
function esc(s){return String(s==null?"":s).replace(/[&<>"']/g,function(c){return {"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]})}
function fmtB(b){if(b==null||!isFinite(Number(b)))return "—";b=Number(b);var u=["Б","КиБ","МиБ","ГиБ","ТиБ"],i=0;while(Math.abs(b)>=1024&&i<4){b/=1024;i++}return (i?b.toFixed(1):String(Math.round(b)))+" "+u[i]}
function fmtRate(b){return b==null?"—":fmtB(b)+"/с"}
function pct(v){return v==null?"—":Number(v).toFixed(1)+"%"}
function age(ts){if(!ts)return "неизвестно";var s=Math.max(0,Math.floor(Date.now()/1000-ts));if(s<60)return s+" сек назад";if(s<3600)return Math.floor(s/60)+" мин назад";return Math.floor(s/3600)+" ч назад"}
function svcB(s){var c=s==="active"?"ok":(s==="inactive"||s==="failed"?"bad":"warn");return '<span class="badge '+c+'">'+esc(s||"n/a")+'</span>'}
function panB(s){return '<span class="badge '+(s==="ok"?"ok":(s==="fail"||s==="down"?"bad":"warn"))+'">'+esc(s||"n/a")+'</span>'}
function stB(s){return '<span class="badge '+(s==="ok"?"ok":"bad")+'">'+(s==="ok"?"TCP доступен":"TCP недоступен")+'</span>'}
function expChip(d,dl){if(!d)return '<span class="mut">—</span>';var c=dl==null||dl<=30?"warn":"ok";if(dl!=null&&dl<0)c="bad";return '<span class="pill '+c+'">'+esc(d)+(dl==null?"":" · "+dl+" дн.")+'</span>'}
function certChip(ts){if(!ts)return '<span class="mut">сертификат: —</span>';var d=new Date(ts*1000),dl=Math.ceil((ts-Date.now()/1000)/86400);return expChip(d.toISOString().slice(0,10),dl)}
function keyExp(ms){if(!ms||ms<=0)return '<span class="mut">∞</span>';return expChip(new Date(ms).toISOString().slice(0,10),Math.ceil((ms-Date.now())/86400000))}
function spark(a,key){var v=(a||[]).map(function(x){return x[key]}).filter(function(x){return typeof x==="number"&&isFinite(x)});if(v.length<2)return '<div class="metric-detail">история накапливается</div>';var min=Math.min.apply(null,v),max=Math.max.apply(null,v),range=max-min||1,pts=v.map(function(x,i){return (i*100/(v.length-1)).toFixed(1)+","+(30-(x-min)*26/range).toFixed(1)}).join(" ");return '<svg class="spark" viewBox="0 0 100 34" preserveAspectRatio="none" aria-hidden="true"><polyline points="'+pts+'"/></svg>'}
function probe(label,s){var good=s==="ok"||s==="active",bad=s==="down"||s==="fail"||s==="unavailable";return '<span class="probe '+(good?"good":bad?"bad":"")+'">'+esc(label)+' '+esc(s||"unknown")+'</span>'}
function render(){if(!D)return;$("ver").textContent=D.version||"?";$("hdr").textContent=(D.host||"?")+" · снимок "+(D.generated_str||"?")+(D.stale?" · данные панели устарели":"");$("freshness").textContent="СНИМОК: "+age(D.generated).toUpperCase();var solo=$("solo");solo.style.display=D.mode==="solo"?"block":"none";solo.textContent="Одиночный режим: ноды не подключены. Добавление: xkit nodes.";
 var m=D.master||{},t=D.totals||{},em=D.expiry_master,c="";
 c+='<div class="panel"><h2>'+(D.mode==="solo"?"Этот сервер":"Этот сервер (мастер)")+'</h2><div class="kv"><span>nginx / 3X-UI</span><b>'+svcB(m.nginx)+' '+svcB(m.xui)+'</b></div><div class="kv"><span>CPU load / RAM</span><b>'+esc(m.load1==null?"—":m.load1)+' / '+pct(m.mem_pct)+'</b></div><div class="kv"><span>Диск / Uptime</span><b>'+pct(m.disk_pct)+' / '+(m.uptime_days==null?"—":m.uptime_days.toFixed(1)+" дн.")+'</b></div><div class="kv"><span>3X-UI / Xray</span><b>'+esc(m.xui_version||"—")+' / '+esc(m.xray_version||"—")+'</b></div><div class="kv"><span>Сертификат</span><b>'+esc(m.cert_end||"—")+'</b></div></div>';
 c+='<div class="panel"><h2>Трафик мастера</h2><div class="kv"><span>Отдано</span><b>'+fmtB(t.up)+'</b></div><div class="kv"><span>Принято</span><b>'+fmtB(t.down)+'</b></div><div class="kv"><span>Всего</span><b>'+fmtB(t.total)+'</b></div><div class="kv"><span>Балансировка</span><b>'+esc(D.strategy||"—")+'</b></div></div>';
 c+='<div class="panel"><h2>Аренда мастера</h2>'+(em&&em.date?'<div class="kv"><span>Действует до</span>'+expChip(em.date,em.days_left)+'</div>'+(em.note?'<div class="kv"><span>Заметка</span><b>'+esc(em.note)+'</b></div>':''):'<div class="mut">Срок не задан.<br>xkit expiry set master ГГГГ-ММ-ДД</div>')+'</div>';$("cards").innerHTML=c;
 var ns=D.nodes||[],h="";if(!ns.length)h='<div class="notice">Нод нет</div>';for(var i=0;i<ns.length;i++){var n=ns[i],hist=(D.history||{})[n.name]||[],pr=n.probes||{};
 h+='<article class="node '+(n.stale?"stale":"fresh")+'"><div class="node-head"><div><span class="node-name">'+esc(n.name)+'</span> <span class="host">'+esc(n.host)+':'+esc(n.tunnel_port)+'</span>'+(n.note?'<div class="mut">'+esc(n.note)+'</div>':'')+'</div><div>'+stB(n.status)+' '+panB(n.panel)+(n.stale?' <span class="badge warn">stale</span>':'')+'</div></div>';
 h+='<div class="node-grid"><div><div class="metric-label">Скорость / интервал</div><div class="metric-value">'+fmtRate(n.rate_bps)+'</div><div class="metric-detail">'+fmtB(n.interval_total)+' за интервал · ↑ '+fmtB(n.interval_up)+' ↓ '+fmtB(n.interval_down)+'</div>'+spark(hist,"rate_bps")+'</div>';
 h+='<div><div class="metric-label">CPU / RAM / load</div><div class="metric-value">'+pct(n.cpu_pct)+' / '+pct(n.ram_pct)+'</div><div class="metric-detail">load '+(n.load1==null?"—":esc(n.load1))+' · SSH '+esc(n.resources||"unknown")+'</div>'+spark(hist,"cpu_pct")+'</div>';
 h+='<div><div class="metric-label">Накопленный трафик</div><div class="metric-value">'+fmtB(n.total)+'</div><div class="metric-detail">↑ '+fmtB(n.up)+' · ↓ '+fmtB(n.down)+'<br>Отклик '+(n.latency_ms==null?"—":n.latency_ms+" мс")+' · inbound '+esc(n.clients==null?"—":n.clients)+'</div></div>';
 h+='<div><div class="metric-label">Версии / сроки</div><div class="metric-value">'+esc(n.xui_version||"—")+' / '+esc(n.xray_version||"—")+'</div><div class="metric-detail">3X-UI / Xray · '+certChip(n.cert_expiry)+'<br>Аренда '+expChip(n.expiry,n.days_left)+'</div></div></div>';
 h+='<div class="probes">'+probe("TCP",pr.tcp)+probe("API",pr.api)+probe("SSH",pr.ssh)+probe("UDP",pr.udp)+probe("CLIENT",pr.client)+'</div><div class="metric-detail" style="margin-top:8px">Опрос: '+age(n.observed_at)+' · последний TCP-ответ: '+age(n.last_seen)+(n.error?' · '+esc(n.error):'')+'</div></article>'}
 $("nodes").innerHTML=h;
 var ib=D.inbounds||[],h2='<tr><th>Инбаунд</th><th>Порт</th><th>Протокол</th><th>Статус</th><th>Клиентов</th><th>↑</th><th>↓</th><th>Σ</th></tr>';for(var j=0;j<ib.length;j++){var b=ib[j];h2+='<tr><td>'+esc(b.tag)+'</td><td class="num">'+esc(b.port)+'</td><td>'+esc(b.proto)+'</td><td>'+(b.enable?'<span class="ok">вкл</span>':'<span class="warn">выкл</span>')+'</td><td class="num">'+esc(b.clients)+'</td><td class="num">'+fmtB(b.up)+'</td><td class="num">'+fmtB(b.down)+'</td><td class="num">'+fmtB(b.total)+'</td></tr>'}if(!ib.length)h2+='<tr><td colspan="8" class="mut">Нет данных</td></tr>';$("inbounds").innerHTML=h2;
 var us=D.users||[],h3='<tr><th>Пользователь</th><th>Инбаунд</th><th>↑</th><th>↓</th><th>Σ</th><th>Срок ключа</th></tr>';for(var k=0;k<us.length;k++){var u=us[k];h3+='<tr><td>'+esc(u.email)+'</td><td class="mut">'+esc(u.ib)+'</td><td class="num">'+fmtB(u.up)+'</td><td class="num">'+fmtB(u.down)+'</td><td class="num">'+fmtB(u.total)+'</td><td>'+keyExp(u.expiryTime)+'</td></tr>'}if(!us.length)h3+='<tr><td colspan="6" class="mut">Нет данных</td></tr>';$("users").innerHTML=h3}
function load(){fetch("./data.json?ts="+Date.now(),{cache:"no-store",credentials:"same-origin"}).then(function(r){if(!r.ok)throw new Error("HTTP "+r.status);return r.json()}).then(function(j){D=j;$("err").style.display="none";$("offline").style.display="none";render()}).catch(function(e){$("err").textContent="Актуальные метрики недоступны: "+e.message+". Выполните xkit dash gen или дождитесь cron.";$("err").style.display="block";if(!D)$("offline").style.display="block"})}
load();setInterval(load,30000);setInterval(function(){if(D)render()},60000);
if("serviceWorker" in navigator)window.addEventListener("load",function(){navigator.serviceWorker.register("./sw.js").catch(function(){})});
</script></body></html>
HTML
}

dash_install() {
  require_root
  load_xkit_env || die "Сначала установка (пункт 1)"
  [ -n "${XKIT_HOST:-}" ] || die "Сначала установка (пункт 1)"

  echo ""
  echo -e "${YELLOW}=== ВЕБ-ДАШБОРД: статусы нод, каналы, трафик, сроки аренды ===${NC}"
  echo "Секретная страница рядом с панелью: https://${XKIT_HOST}/d-<токен>/"
  echo "(без токена — обычный 404, как у панели; сверх токена — Basic Auth; access_log выключен)"

  if [ -z "${XKIT_DASH_TOKEN:-}" ]; then
    XKIT_DASH_TOKEN="$(rand_str 24)"
  fi
  # Basic Auth — как у панели: случайные логин/пароль (хранятся в xkit.env, 600)
  XKIT_DASH_AUTH="1"
  if [ -z "${XKIT_DASH_USER:-}" ] || [ -z "${XKIT_DASH_PASS:-}" ]; then
    XKIT_DASH_USER="$(dash_user_gen)"
    XKIT_DASH_PASS="$(rand_str 20)"
  fi
  dash_htpasswd_write || { err "Не удалось создать htpasswd для дашборда"; return 1; }
  local allow a ok_all _al _ka
  if [ -n "${XKIT_DASH_ALLOW:-}" ]; then
    log "Текущее ограничение IP: ${XKIT_DASH_ALLOW}"
    confirm "Оставить ограничение IP как есть? [Y/n] " y || XKIT_DASH_ALLOW=""
  fi
  if [ -z "${XKIT_DASH_ALLOW:-}" ]; then
    read -r -p "Ограничить доступ по IP/CIDR (несколько — через запятую; Enter — доступ с любого): " allow
    if [ -n "$allow" ]; then
      ok_all=1
      IFS=',' read -ra _al <<<"$allow"
      for a in "${_al[@]}"; do
        a="${a// /}"; [ -n "$a" ] || continue
        is_ip "$a" || is_cidr "$a" || { err "Не похоже на IP/CIDR: $a"; ok_all=0; }
      done
      [ "$ok_all" = "1" ] || return 1
      XKIT_DASH_ALLOW="$allow"
    else
      XKIT_DASH_ALLOW=""
    fi
  fi
  XKIT_DASH="1"
  save_xkit_env

  local mexp mexd
  mexp="$(expiry_get master -)"
  if [ -z "$mexp" ]; then
    read -r -p "Срок аренды ЭТОГО сервера (DD.MM.YYYY или YYYY-MM-DD, Enter — пропустить): " mexd
    [ -n "$mexd" ] && expiry_set master "-" "$mexd" ""
  fi

  log "Пересобираю конфиг nginx (секретный location дашборда)..."
  regen_conf_and_apply || { err "Не удалось применить конфиг nginx — дашборд НЕ установлен"; XKIT_DASH="0"; save_xkit_env; return 1; }
  dash_cron_install
  log "Первое построение данных..."
  dash_gen || warn "Первое построение не удалось — cron повторит через 5 минут"

  echo ""
  ok "Дашборд установлен: https://${XKIT_HOST}$(dash_path)"
  ok "Логин: ${XKIT_DASH_USER}   Пароль: ${XKIT_DASH_PASS}   (Basic Auth; ротация: xkit dash rotate)"
  [ -n "${XKIT_DASH_ALLOW:-}" ] && ok "Доступ ограничен IP/CIDR: ${XKIT_DASH_ALLOW}"
  ok "Данные: cron каждые 5 минут; на странице автообновление каждые 30 сек"
  ok "Реквизиты также в ${XKIT_INFO_FILE} и ${XKIT_ENV} (chmod 600)"
  warn "Ссылку потеряли: xkit dash url. Выключить: xkit dash uninstall"
  xkit_summary_save >/dev/null 2>&1 || true
  return 0
}

dash_uninstall() {
  require_root
  load_xkit_env 2>/dev/null || true
  XKIT_DASH="0"
  save_xkit_env >/dev/null 2>&1 || true
  rm -f "$XKIT_CRON_DASH"
  if [ -f "$XKIT_CONF" ]; then
    log "Убираю location дашборда из nginx..."
    regen_conf_and_apply >/dev/null 2>&1 || warn "Не удалось пересобрать конфиг nginx — проверьте вручную"
  fi
  ok "Дашборд выключен (nginx + cron); файлы в ${XKIT_DASH_DIR} сохранены"
  ok "Логин/пароль дашборда сохранены в ${XKIT_ENV} — повторный install их не меняет (сменить: xkit dash rotate)"
  ok "Сроки аренды (expiry) не тронуты — вернуть дашборд: xkit dash install"
  return 0
}

# ротация секрета дашборда: новый токен URL + новый логин/пароль Basic Auth
# (если токен/пароль засветились — не надо переустанавливать дашборд целиком)
dash_rotate() {
  require_root
  load_xkit_env || die "Сначала установка (пункт 1)"
  [ "${XKIT_DASH:-0}" = "1" ] && [ -n "${XKIT_DASH_TOKEN:-}" ] \
    || die "Дашборд не установлен (xkit dash install)"
  local old_token="${XKIT_DASH_TOKEN}" old_user="${XKIT_DASH_USER}" old_pass="${XKIT_DASH_PASS}"
  log "Старый URL (перестанет работать): https://${XKIT_HOST}$(dash_path)"
  # бэкап htpasswd: откат — КОПИРОВАНИЕМ, а не пересчётом openssl (аудит №6:
  # пересчёт мог упасть и оставить новый пароль в htpasswd при старом env)
  local htbk; htbk="$(mktemp /tmp/.xkit-htbk.XXXXXX 2>/dev/null)" || htbk=""
  if [ -n "$htbk" ]; then
    # (мелочь №4, аудит v5.2.1): cp не удался — подчищаем созданный mktemp-файл
    if cp -f "$XKIT_DASH_HTPASSWD" "$htbk" 2>/dev/null; then :; else rm -f "$htbk"; htbk=""; fi
  fi
  if [ -z "$htbk" ]; then
    # №4 (аудит №1): без бэкапа откат невозможен — рассинхрон «nginx требует
    # новый пароль, env — старый». Честно отменяем ДО генерации новых значений
    err "Не удалось создать бэкап htpasswd — ротация отменена, ничего не изменено"
    return 1
  fi
  XKIT_DASH_TOKEN="$(rand_str 24)"
  XKIT_DASH_USER="$(dash_user_gen)"
  XKIT_DASH_PASS="$(rand_str 20)"
  # htpasswd перезаписывается НОВЫМ паролем — при сбое apply откатим и его
  if ! dash_htpasswd_write; then
    err "Не удалось записать htpasswd"
    XKIT_DASH_TOKEN="$old_token"; XKIT_DASH_USER="$old_user"; XKIT_DASH_PASS="$old_pass"
    [ -n "$htbk" ] && rm -f "$htbk"
    return 1
  fi
  # ВАЖНО (аудит №4): env на диск — только ПОСЛЕ успешного apply. Иначе при
  # падении regen_conf_and_apply nginx откатится на старый путь, а в xkit.env
  # остался бы новый токен: «ротация прошла», а URL отдаёт 404 (рассинхрон)
  if ! regen_conf_and_apply; then
    XKIT_DASH_TOKEN="$old_token"; XKIT_DASH_USER="$old_user"; XKIT_DASH_PASS="$old_pass"
    if [ -n "$htbk" ] && [ -f "$htbk" ]; then
      if cp -f "$htbk" "$XKIT_DASH_HTPASSWD"; then
        chown root:www-data "$XKIT_DASH_HTPASSWD" 2>/dev/null || true
        chmod 640 "$XKIT_DASH_HTPASSWD" 2>/dev/null || true
      else
        err "ВНИМАНИЕ: старый htpasswd не восстановлен — выполните xkit dash rotate повторно"
      fi
      rm -f "$htbk"
    else
      dash_htpasswd_write 2>/dev/null || err "ВНИМАНИЕ: вернуть старый htpasswd не удалось — выполните xkit dash rotate повторно"
    fi
    err "Не удалось применить конфиг nginx — ротация ОТМЕНЕНА (старые реквизиты действуют)"
    return 1
  fi
  [ -n "$htbk" ] && rm -f "$htbk" 2>/dev/null
  # аудит №13: apply уже прошёл — при сбое записи env новые реквизиты остались
  # бы только в этом выводе; кричим об этом явно
  save_xkit_env || err "Не удалось сохранить xkit.env — НОВЫЕ реквизиты напечатаны выше, запишите их вручную"
  echo ""
  ok "Дашборд ротирован: https://${XKIT_HOST}$(dash_path)"
  ok "Новый логин: ${XKIT_DASH_USER}   Пароль: ${XKIT_DASH_PASS}"
  warn "Старая ссылка и старый пароль больше не работают"
  xkit_summary_save >/dev/null 2>&1 || true
  return 0
}

dash_url() {
  load_xkit_env 2>/dev/null || return 1
  [ "${XKIT_DASH:-0}" = "1" ] && [ -n "${XKIT_DASH_TOKEN:-}" ] \
    || { err "Дашборд не установлен (xkit dash install)"; return 1; }
  printf 'https://%s%s\n' "${XKIT_HOST}" "$(dash_path)"
  [ -n "${XKIT_DASH_USER:-}" ] \
    && printf 'Логин: %s   Пароль: %s\n' "${XKIT_DASH_USER}" "${XKIT_DASH_PASS}"
  return 0
}

dash_menu() {
  require_root
  load_xkit_env 2>/dev/null || true
  while true; do
    echo ""
    echo -e "${YELLOW}=== СТРАНИЦА СОСТОЯНИЯ (серверы / соединения / трафик / аренда) ===${NC}"
    if [ "${XKIT_DASH:-0}" = "1" ] && [ -n "${XKIT_DASH_TOKEN:-}" ]; then
      ok "Установлен: https://${XKIT_HOST:-?}$(dash_path)"
      [ -n "${XKIT_DASH_ALLOW:-}" ] && log "Доступ ограничен IP: ${XKIT_DASH_ALLOW}"
    else
      warn "Не установлен"
    fi
    echo " 1) Установить / переустановить (адрес, автообновление и первые данные)"
    echo " 2) Обновить данные сейчас"
    echo " 3) Показать адрес страницы"
    echo " 4) Сменить адрес страницы и логин/пароль"
    echo " 5) Выключить страницу (данные и сроки аренды сохранятся)"
    echo " 0) Назад"
    local c
    read -r -p "Выбор: " c || return 0
    case "$c" in
      1) dash_install; pause_enter ;;
      2) dash_gen; pause_enter ;;
      3) dash_url; pause_enter ;;
      4) dash_rotate; pause_enter ;;
      5) dash_uninstall; pause_enter ;;
      0) return 0 ;;
      *) warn "Нет такого пункта" ;;
    esac
  done
}

#=========================== v4.5: TELEGRAM-АЛЕРТЫ =============================
# Принцип: шлём ТОЛЬКО то, чего 3X-UI не знает (ноды/аренда/сертификат/
# дашборд). Бот-команды и уведомления о клиентах НЕ дублируем — это умеет
# сам 3X-UI (один бот, один чат, сообщения xkit помечены [XKIT]).
#
# Доставка: (1) напрямую с мастера; (2) если api.telegram.org недоступен
# (типично для РФ) — через ноды по SSH: curl крутится НА ноде, выход с её
# зарубежного IP. Живой выбор балансировщика здесь не нужен: сообщение
# одно и то же, идём по реестру до первой успешной доставки. Токен не
# попадает в argv (ps на ноде чист): curl читает URL из stdin-конфига -K -.
xkit_tg_send() { # $1 текст; 0 = доставлено или TG не настроен
  local msg="$1" token="${XKIT_TG_TOKEN:-}" chat="${XKIT_TG_CHAT:-}"
  [ -n "$token" ] && [ -n "$chat" ] || return 0   # TG не настроен — тихо
  # №9 (аудит №1): токен из env уходит в curl-конфиг — убеждаемся в формате,
  # иначе мусор/инъекция из xkit.env доедет до curl
  [[ "$token" =~ ^[0-9]{6,12}:[A-Za-z0-9_-]{30,46}$ ]] \
    || { warn "TG-токен в env невалиден — уведомление пропущено (xkit 6 → 2 — перенастройте)"; return 1; }
  [ -n "$msg" ] || return 0
  # urlencoded POST-body (chat_id и text кодируются @uri: переводы строк -> %0A,
  # кавычек/бэкслэшей не остаётся — строка безопасна для curl-конфига)
  local data
  data="$(jq -rn --arg c "$chat" --arg t "$msg" '"chat_id=\($c|@uri)&text=\($t|@uri)"' 2>/dev/null)" || return 1
  local -a px=()
  [ -n "${XKIT_TG_PROXY:-}" ] && px=(--proxy "$XKIT_TG_PROXY")
  # (1) напрямую с мастера
  { printf 'request = "POST"\nurl = "https://api.telegram.org/bot%s/sendMessage"\ndata = "%s"\n' "$token" "$data"; } \
    | curl -sf --max-time 8 ${px[@]+"${px[@]}"} -K - -o /dev/null 2>/dev/null && return 0
  # (2) через ноды по SSH: curl на ноде, выход с её IP
  local rec
  while IFS= read -r rec; do
    [ -z "$rec" ] && continue
    { printf 'request = "POST"\nurl = "https://api.telegram.org/bot%s/sendMessage"\ndata = "%s"\n' "$token" "$data"; } \
      | node_ssh "$rec" 'curl -sf --max-time 10 -K - -o /dev/null' >/dev/null 2>&1 && return 0
  done < <(nodes_load | jq -c '.[]' 2>/dev/null)
  return 1
}

# --- состояние алертов (гистерезис/дедуп): key=val построчно, chmod 600 ---
notify_state_get() { # $1 key -> value (пусто если нет)
  [ -r "$XKIT_NOTIFY_STATE" ] || return 0
  awk -F= -v k="$1" '$1==k{print substr($0, length(k)+2); exit}' "$XKIT_NOTIFY_STATE" 2>/dev/null
}

notify_state_set() { # $1 key, $2 value (пустое значение = удалить ключ)
  mkdir -p "$XKIT_DIR" 2>/dev/null || true
  # запись целиком в subshell (симметрично dash_gen_locked): umask 077 не
  # утекает в вызывающую оболочку, даже если mktemp/awk/mv провалятся
  # посередине (ревью v4.6.0 — раньше umask 022 ставился в конце основной
  # оболочки и не выполнялся при любом сбое выше)
  (
    umask 077
    tmp="$(mktemp)" || exit 0
    # удаление ключа — awk с точным сравнением $1==k (аудит №14): grep -v
    # трактовал «.» в ключе как regex и мог зацепить чужие ключи; симметрично get
    { [ -r "$XKIT_NOTIFY_STATE" ] && awk -F= -v k="$1" '$1!=k' "$XKIT_NOTIFY_STATE" 2>/dev/null
      [ -n "$2" ] && printf '%s=%s\n' "$1" "$2"; } > "$tmp"
    mv -f "$tmp" "$XKIT_NOTIFY_STATE" 2>/dev/null
  )
  chmod 600 "$XKIT_NOTIFY_STATE" 2>/dev/null
  return 0
}

# чистая функция гистерезиса ноды (тестируемая):
#   $1 прошлое состояние (up|fail1|down|пусто), $2 текущая проба (ok|fail)
#   stdout: "новое_состояние<TAB>текст_алерта" (пустой текст = не алертить).
# Логика: алерт о падении — только со 2-й проверки подряд (одиночный таймаут
# не алертим), о восстановлении — всегда один раз.
notify_node_trans() {
  local st="${1:-}" probe="$2"
  if [ "$probe" = "ok" ]; then
    case "$st" in
      down) printf 'up\tнедоступна была — восстановлена\n' ;;
      *)    printf 'up\t' ;;
    esac
  else
    case "$st" in
      down)  printf 'down\t' ;;
      fail1) printf 'down\tнедоступна (2 проверки подряд)\n' ;;
      *)     printf 'fail1\t' ;;
    esac
  fi
}

# периодическая проверка (cron каждые 10 мин): ноды (TCP-проба туннеля),
# аренда, сертификат мастера, свежесть дашборда. Алерты — только при
# ИЗМЕНЕНИИ состояния (дедуп: аренда/серт — при смене числа дней, т.е.
# максимум раз в сутки). Один прогон = максимум одно сообщение со всеми
# событиями (не поток сообщений).
# --- чистые функции алертов (тестируемые, как notify_node_trans) ---

# А1 диск: $1 = занято % -> уровень "95"|"85"|"" (пусто = всё ок)
notify_disk_verdict() {
  local p="$1"
  case "$p" in ''|*[!0-9]*) return 0 ;; esac   # не число — не алертим
  [ "$p" -ge 95 ] && { printf '95'; return 0; }
  [ "$p" -ge 85 ] && printf '85'
  return 0
}

# А2 сервис мастера: переходы. $1 old(""|up|down), $2 new(up|down) -> "state\tmsg"
# (msg пуст — ничего не слать; стиль notify_node_trans)
notify_svc_trans() {
  local old="$1" new="$2"
  if [ "$new" = "down" ]; then
    [ "$old" = "down" ] && { printf 'down\t'; return 0; }   # уже алертили — молчим
    printf 'down\tНЕ работает — проверьте systemctl status'
    return 0
  fi
  [ "$old" = "down" ] && printf 'up\tснова работает' || printf 'up\t'
  return 0
}

notify_check() {
  load_xkit_env 2>/dev/null || return 0
  [ -n "${XKIT_TG_TOKEN:-}" ] && [ -n "${XKIT_TG_CHAT:-}" ] || return 0   # не настроено
  local -a L=()

  # --- А2 сервисы мастера: nginx/x-ui молча умереть не должны (раньше мастер
  #     сообщал только о нодах, а о себе — через stale-дашборд, и то через 25 мин) ---
  local sv svc_st sold snew snst snmsg
  for sv in nginx x-ui; do
    svc_st="$(systemctl is-active "$sv" 2>/dev/null || true)"
    [ "$svc_st" = "active" ] && svc_st="up" || svc_st="down"
    sold="$(notify_state_get "svc:${sv}")"
    snew="$(notify_svc_trans "${sold:-}" "$svc_st")"
    snst="${snew%%$'\t'*}"; snmsg="${snew#*$'\t'}"
    [ "${sold:-}" != "$snst" ] && notify_state_set "svc:${sv}" "$snst"
    [ -n "$snmsg" ] && L+=("Сервис ${sv}: ${snmsg}")
  done

  # --- А1 диск: переполнение молча валит sqlite панели/certbot/бэкапы ---
  local dpct dlv dold
  dpct="$(df -P / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')"
  dlv="$(notify_disk_verdict "$dpct")"
  dold="$(notify_state_get "disk")"
  if [ -n "$dpct" ]; then
    if [ -n "$dlv" ] && [ "$dlv" != "$dold" ]; then
      if [ "$dlv" = "95" ]; then
        L+=("ДИСК: занято ${dpct}% — панель/сертификаты/бэкапы скоро начнут падать")
      else
        L+=("Диск: занято ${dpct}% (порог 85%) — почистите место")
      fi
      notify_state_set "disk" "$dlv"
    elif [ -z "$dlv" ] && [ -n "$dold" ]; then
      L+=("Диск: место освободилось (занято ${dpct}%)")
      notify_state_set "disk" ""
    fi
  fi

  # --- ноды: TCP-проба туннеля (быстро, без SSH) ---
  local rec name host tport old new nst nmsg probe
  while IFS= read -r rec; do
    [ -z "$rec" ] && continue
    name="$(jq -r '.name' <<<"$rec")"
    host="$(jq -r '.host' <<<"$rec")"
    tport="$(jq -r '.tunnel.port // 443' <<<"$rec")"
    if timeout 3 bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$host" "$tport" 2>/dev/null; then probe="ok"; else probe="fail"; fi
    old="$(notify_state_get "node:${name}")"
    new="$(notify_node_trans "${old:-}" "$probe")"
    nst="${new%%$'\t'*}"; nmsg="${new#*$'\t'}"
    [ "${old:-}" != "$nst" ] && notify_state_set "node:${name}" "$nst"
    [ -n "$nmsg" ] && L+=("Нода ${name}: ${nmsg}")
  done < <(nodes_load | jq -c '.[]' 2>/dev/null)

  # --- аренда: алерт при <=7 дн. и при истечении; дедуп по числу дней ---
  local s i d note dl last
  if [ -s "$XKIT_EXPIRY" ]; then
    while IFS=$'\t' read -r s i d note; do
      [ -z "$s" ] && continue
      dl="$(days_left "$d")"
      [ -n "$dl" ] || continue
      if [ "$dl" -le 7 ]; then
        last="$(notify_state_get "exp:${s}/${i}")"
        if [ "${last:-x}" != "$dl" ]; then
          if [ "$dl" -lt 0 ]; then
            L+=("Аренда ИСТЕКЛА: ${s}/${i} (${d})${note:+ — ${note}}")
          else
            L+=("Осталось ${dl} дн. аренды: ${s}/${i} (${d})${note:+ — ${note}}")
          fi
          notify_state_set "exp:${s}/${i}" "$dl"
        fi
      fi
    done < "$XKIT_EXPIRY"
  fi

  # --- сертификат мастера: <=14 дн., дедуп по числу дней ---
  if [ -n "${XKIT_CRT:-}" ] && [ -f "$XKIT_CRT" ]; then
    local cend cdl
    cend="$(openssl x509 -enddate -noout -in "$XKIT_CRT" 2>/dev/null | cut -d= -f2-)"
    if [ -n "$cend" ]; then
      cdl=$(( ( $(date -d "$cend" +%s) - $(date +%s) ) / 86400 ))
      if [ "$cdl" -le 14 ]; then
        last="$(notify_state_get "cert:master")"
        if [ "${last:-x}" != "$cdl" ]; then
          L+=("Сертификат ${XKIT_HOST} истекает через ${cdl} дн. (${cend})")
          notify_state_set "cert:master" "$cdl"
        fi
      fi
    fi
  fi

  # --- дашборд: data.json не обновлялся >25 мин (5 пропусков cron) ---
  if [ "${XKIT_DASH:-0}" = "1" ] && [ -r "${XKIT_DASH_DIR}/data.json" ]; then
    local gen age
    gen="$(jq -r '.generated // 0' "${XKIT_DASH_DIR}/data.json" 2>/dev/null || echo 0)"
    case "$gen" in ''|*[!0-9]*) gen=0 ;; esac
    if [ "$gen" -gt 0 ]; then
      age=$(( $(date +%s) - gen ))
      if [ "$age" -gt 1500 ]; then
        if [ "$(notify_state_get "dash")" != "stale" ]; then
          L+=("Дашборд не обновляется: данные от $(date -d "@$gen" '+%d.%m %H:%M' 2>/dev/null || echo '?')")
          notify_state_set "dash" "stale"
        fi
      else
        if [ "$(notify_state_get "dash")" = "stale" ]; then
          notify_state_set "dash" ""
          L+=("Дашборд снова обновляется")
        fi
      fi
    fi
  fi

  [ "${#L[@]}" -eq 0 ] && return 0
  local msg="[XKIT] ${XKIT_HOST:-сервер}" ln
  for ln in "${L[@]}"; do msg+=$'\n'"${ln}"; done
  if xkit_tg_send "$msg"; then
    ok "Telegram: отправлено (событий: ${#L[@]})"
    return 0
  fi
  warn "Telegram: доставить не удалось (${#L[@]} событий) — ни напрямую, ни через ноды"
  return 1
}

notify_cron_install() {
  cat > "$XKIT_CRON_NOTIFY" <<EOF
# XKIT: Telegram-алерты (ноды/аренда/сертификат/дашборд) каждые 10 минут
*/10 * * * * root ${XKIT_BIN} telegram check >/dev/null 2>&1
EOF
  chmod 644 "$XKIT_CRON_NOTIFY"
  ok "Cron: алерты проверяются каждые 10 минут ($XKIT_CRON_NOTIFY)"
}

notify_cron_remove() { rm -f "$XKIT_CRON_NOTIFY" 2>/dev/null; return 0; }

telegram_setup() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  echo ""
  echo -e "${YELLOW}=== Telegram-уведомления ===${NC}"
  if [ -n "${XKIT_TG_TOKEN:-}" ]; then
    ok "Уже настроено (чат ${XKIT_TG_CHAT}) — повторный запуск заменит реквизиты"
  fi
  echo "Приходит только то, чего 3X-UI НЕ знает: нода упала/восстановилась,"
  echo "аренда <=7 дн. или истекла, сертификат <=14 дн., дашборд stale."
  echo "Бот-команды и уведомления о клиентах остаются у 3X-UI (не дублируем)."
  echo "Доставка: с мастера напрямую; если не проходит — через ноды (их IP)."
  local tok chat px admins
  read -r -p "Bot token (от @BotFather, вид 123456:ABC-...): " tok
  [[ "$tok" =~ ^[0-9]{6,12}:[A-Za-z0-9_-]{30,46}$ ]] || { err "Токен не похож на валидный"; return 1; }
  read -r -p "Chat ID (число от @userinfobot, или @имя_канала): " chat
  [[ "$chat" =~ ^-?[0-9]+$|^@[A-Za-z0-9_]{4,64}$ ]] || { err "Chat ID: число (личка/группа) или @имя_канала"; return 1; }
  read -r -p "Прокси для api.telegram.org (http://... или socks5://...; Enter — без прокси): " px
  admins="$chat"; [[ "$admins" =~ ^-?[0-9]+$ ]] || admins=""
  XKIT_TG_TOKEN="$tok"; XKIT_TG_CHAT="$chat"; XKIT_TG_PROXY="$px"; XKIT_TG_ADMINS="$admins"
  save_xkit_env
  notify_cron_install
  log "Отправляю тестовое сообщение..."
  if xkit_tg_send "[XKIT] ${XKIT_HOST:-сервер}: Telegram настроен. Алерты: ноды, аренда, сертификат, дашборд."; then
    ok "Тестовое сообщение доставлено"
  else
    warn "Прямая отправка не прошла. Если api.telegram.org недоступен с этого"
    warn "сервера — сообщения пойдут через ноды (после их добавления)."
    warn "Проверка вручную: xkit telegram check"
  fi
  xkit_summary_save >/dev/null 2>&1 || true
  return 0
}

telegram_off() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  [ -n "${XKIT_TG_TOKEN:-}" ] || { warn "Telegram не настроен"; return 0; }
  confirm "Выключить Telegram-уведомления (токен удалится)? [y/N] " n || return 0
  XKIT_TG_TOKEN=""; XKIT_TG_CHAT=""; XKIT_TG_PROXY=""
  save_xkit_env
  notify_cron_remove
  ok "Telegram-уведомления выключены (история состояний: ${XKIT_NOTIFY_STATE})"
  xkit_summary_save >/dev/null 2>&1 || true
  return 0
}

telegram_menu() {
  load_xkit_env 2>/dev/null || true
  while true; do
    echo ""
    echo -e "${YELLOW}=== УВЕДОМЛЕНИЯ В TELEGRAM (серверы/аренда/сертификаты) ===${NC}"
    if [ -n "${XKIT_TG_TOKEN:-}" ] && [ -n "${XKIT_TG_CHAT:-}" ]; then
      ok "Настроено: чат ${XKIT_TG_CHAT}${XKIT_TG_PROXY:+, прокси ${XKIT_TG_PROXY}}"
    else
      warn "Не настроено (xkit telegram setup)"
    fi
    echo " 1) Настроить / заменить (ключ бота + чат + тестовое сообщение)"
    echo " 2) Проверить сейчас (те же проверки, что автоматически каждые 10 минут)"
    echo " 3) Отправить тестовое сообщение"
    echo " 4) Выключить (ключ удаляется, автоматические проверки отключаются)"
    echo " 0) Назад"
    local c
    read -r -p "Выбор: " c || return 0
    case "$c" in
      1) telegram_setup; pause_enter ;;
      2) load_xkit_env >/dev/null 2>&1 || true; notify_check; pause_enter ;;
      3) load_xkit_env >/dev/null 2>&1 || true
         if xkit_tg_send "[XKIT] тест: канал доставки работает"; then ok "Доставлено"; else err "Не доставлено (напрямую и через ноды)"; fi
         pause_enter ;;
      4) telegram_off; pause_enter ;;
      0) return 0 ;;
      *) warn "Нет такого пункта" ;;
    esac
  done
}

#=========================== СВОДКА (реквизиты) ================================
# После установки/операций — всё важное в /root/xkit-info.txt (chmod 600).
# ПАРОЛИ по умолчанию МАСКИРОВАНЫ в stdout (аудит №4): терминальный scrollback,
# tee/script/CI-логи не должны собирать секреты. Полные — только в файл 600
# (xkit_summary_save/xkit_info пишут его через --show-secrets).
xkit_summary_text() { # stdout: plain-текст без цветов
  local show_secrets=0
  [ "${1:-}" = "--show-secrets" ] && show_secrets=1
  load_xkit_env 2>/dev/null || true
  read_panel_settings >/dev/null 2>&1 || true
  local -a L=()
  L+=("XKIT v${XKIT_VERSION} — сводка сервера")
  L+=("Обновлено: $(date '+%Y-%m-%d %H:%M:%S %Z')")
  L+=("================================================================")
  if [ -n "${XKIT_HOST:-}" ]; then
    L+=("Сервер:            ${XKIT_HOST}")
    # v4.5: явный режим сервера
    local nc; nc="$(jq 'length' <<<"$(nodes_load 2>/dev/null || printf '[]')" 2>/dev/null || echo 0)"
    if [ "$nc" -gt 0 ]; then
      L+=("Режим:             мастер (${nc} нод; балансировка ${XKIT_BAL_STRATEGY:-leastLoad})")
    else
      L+=("Режим:             одиночный сервер (ноды не подключены)")
    fi
    [ -n "${PANEL_PORT:-}" ] && [ -n "${PANEL_WBP:-}" ] \
      && L+=("Панель 3X-UI:      https://${XKIT_HOST}${PANEL_WBP}")
    [ -n "${PANEL_USER:-}" ] && L+=("Логин панели:      ${PANEL_USER}")
    if [ -n "${PANEL_PASS:-}" ]; then
      if [ "$show_secrets" = "1" ]; then
        L+=("Пароль панели:     ${PANEL_PASS}")
      else
        L+=("Пароль панели:     ********  (полные реквизиты: cat ${XKIT_INFO_FILE})")
      fi
    fi
    [ -n "${XKIT_SUB_TOKEN:-}" ] && L+=("Подписки xkit:     https://${XKIT_HOST}$(sub_path)")
    # v7.4.2: живой вопрос пользователя «где теперь логин/пароль панели» —
    # показываем хранилище-источник явно (сводка с паролем: cat ${XKIT_INFO_FILE})
    [ -n "${PANEL_USER:-}" ] && L+=("Источник пароля:   /etc/x-ui/install-result.env (обновляет установщик 3X-UI)")
    if [ "${XKIT_DASH:-0}" = "1" ] && [ -n "${XKIT_DASH_TOKEN:-}" ]; then
      L+=("Веб-дашборд:       https://${XKIT_HOST}$(dash_path)")
      [ -n "${XKIT_DASH_USER:-}" ] && L+=("Логин дашборда:    ${XKIT_DASH_USER}")
      if [ -n "${XKIT_DASH_PASS:-}" ]; then
        if [ "$show_secrets" = "1" ]; then
          L+=("Пароль дашборда:   ${XKIT_DASH_PASS}")
        else
          L+=("Пароль дашборда:   ********  (полные реквизиты: cat ${XKIT_INFO_FILE})")
        fi
      fi
      [ -n "${XKIT_DASH_ALLOW:-}" ] && L+=("Дашборд: allow IP: ${XKIT_DASH_ALLOW}")
    fi
    # v4.5: состояние Telegram-алертов (токен не показываем)
    if [ -n "${XKIT_TG_TOKEN:-}" ] && [ -n "${XKIT_TG_CHAT:-}" ]; then
      L+=("Telegram алерты:   включены (чат ${XKIT_TG_CHAT})")
    else
      L+=("Telegram алерты:   не настроены (xkit telegram setup)")
    fi
  else
    L+=("(xkit ещё не установлен — запустите: xkit install)")
  fi
  # ноды
  local arr; arr="$(nodes_load 2>/dev/null || printf '[]')"
  if [ "$(jq 'length' <<<"${arr:-[]}" 2>/dev/null || echo 0)" -gt 0 ]; then
    L+=("")
    L+=("Ноды:")
    local nr
    while IFS= read -r nr; do
      [ -z "$nr" ] && continue
      L+=("  - $(jq -r '.name' <<<"$nr"): $(jq -r '.host' <<<"$nr"), туннель :$(jq -r '.tunnel.port // 443' <<<"$nr"), панель :$(jq -r '.panel.port // "?"' <<<"$nr")")
    done < <(jq -c '.[]' <<<"$arr")
  fi
  # сроки аренды
  if [ -s "$XKIT_EXPIRY" ]; then
    L+=("")
    L+=("Сроки аренды:")
    local es ei ed enote edl
    while IFS=$'\t' read -r es ei ed enote; do
      [ -z "$es" ] && continue
      edl="$(days_left "$ed")"
      L+=("  - ${es}/${ei}: до ${ed}${edl:+, осталось ${edl} дн.}${enote:+ (${enote})}")
    done < "$XKIT_EXPIRY"
  fi
  L+=("")
  L+=("Файлы: ${XKIT_ENV} | ${XKIT_CONF}")
  L+=("Меню: команда xkit | Эта сводка: xkit info")
  printf '%s\n' "${L[@]}"
}

xkit_info() { # в терминал (пароли маскируются) И в /root/xkit-info.txt (полные)
  local txt tfull
  txt="$(xkit_summary_text)" || return 1
  tfull="$(xkit_summary_text --show-secrets)" || return 1
  printf '%s\n' "$txt"
  log "Пароли не печатаются в терминал (scrollback/логи) — полные реквизиты: cat ${XKIT_INFO_FILE}"
  if printf '%s\n' "$tfull" > "$XKIT_INFO_FILE" 2>/dev/null && chmod 600 "$XKIT_INFO_FILE" 2>/dev/null; then
    ok "Сводка сохранена: ${XKIT_INFO_FILE} (chmod 600)"
  else
    warn "Не удалось записать ${XKIT_INFO_FILE}"
  fi
  return 0
}

xkit_summary_save() { # тихо: только файл (вызывается после операций)
  local txt
  txt="$(xkit_summary_text --show-secrets)" || return 1
  if printf '%s\n' "$txt" > "$XKIT_INFO_FILE" 2>/dev/null && chmod 600 "$XKIT_INFO_FILE" 2>/dev/null; then
    ok "Сводка обновлена: ${XKIT_INFO_FILE}"
  else
    warn "Не удалось обновить ${XKIT_INFO_FILE}"
  fi
  return 0
}

#=========================== ОБНОВЛЕНИЕ =======================================
# Фоновая проверка для TUI: только версия из удалённого ядра, никакой установки.
xkit_update_check() { # [--force] [--quiet]
  require_root
  load_xkit_env 2>/dev/null || true
  local force=0 quiet=0 base tmp nv cache now mtime latest=""
  [ "${1:-}" = "--force" ] && { force=1; shift; }
  [ "${1:-}" = "--quiet" ] && quiet=1
  base="${XKIT_REPO_URL:-}"; case "$base" in */xkit.sh) base="${base%/*}" ;; esac
  [ -n "$base" ] || { [ "$quiet" = 1 ] || err "Не задан XKIT_REPO_URL"; return 1; }
  case "$base" in
    http://127.0.0.1*|http://localhost*|http://\[::1\]*) ;;
    http://*) [ "$quiet" = 1 ] || err "Проверка по http:// запрещена"; return 1 ;;
  esac
  cache="${XKIT_DIR}/update-check.json"; now="$(date +%s)"
  if [ "$force" = 0 ] && [ -r "$cache" ]; then
    mtime="$(stat -c %Y "$cache" 2>/dev/null || echo 0)"
    if [ $((now-mtime)) -lt 21600 ]; then latest="$(jq -r '.latest // empty' "$cache" 2>/dev/null)"; fi
  fi
  if [ -z "$latest" ]; then
    tmp="$(mktemp /tmp/.xkit-version.XXXXXX)" || return 1
    curl -fsSL --connect-timeout 4 --max-time 10 "${base}/xkit.sh" -o "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    nv="$(grep -m1 '^XKIT_VERSION=' "$tmp" | cut -d'"' -f2)"; rm -f "$tmp"
    [[ "$nv" =~ ^[0-9]+(\.[0-9]+)+$ ]] || return 1
    latest="$nv"
    jq -nc --arg latest "$latest" --argjson checked "$now" '{latest:$latest,checked_at:$checked}' \
      | _xkit_atomic_write "$cache" || return 1
    chmod 600 "$cache" 2>/dev/null || true
  fi
  if [ "$latest" != "$XKIT_VERSION" ] && [ "$(printf '%s\n%s\n' "$XKIT_VERSION" "$latest" | sort -V | tail -1)" = "$latest" ]; then
    [ "$quiet" = 1 ] || ok "Доступно обновление XKIT: v${XKIT_VERSION} -> v${latest}"
  else
    latest=""
    [ "$quiet" = 1 ] || ok "Установлена актуальная версия XKIT v${XKIT_VERSION}"
  fi
  [ -n "$latest" ] && printf '%s\n' "$latest"
  return 0
}

# v5.0.0: обновляются ОБА файла — xkit.sh (ядро) и xkit_menu.sh (модуль меню).
# Пломба xkit.sh.sha256 — формат sha256sum, 2 строки; строка 1 = xkit.sh,
# строка 2 = xkit_menu.sh (старые версии читают строку 1 — совместимость)
xkit_self_update() { # $1 base-url (необязательно; иначе XKIT_REPO_URL из xkit.env)
  require_root
  load_xkit_env 2>/dev/null || true   # свежая SSH-сессия: XKIT_REPO_URL живёт в xkit.env
  local base="${1:-${XKIT_REPO_URL:-}}"
  if [ -z "$base" ]; then
    err "Не знаю, откуда обновляться. Укажите URL репозитория:"
    err "  xkit update https://raw.githubusercontent.com/НИК/xkit/main"
    err "  (или переустановите через install.sh — он запомнит источник)"
    return 1
  fi
  case "$base" in */xkit.sh) base="${base%/*}" ;; esac
  # K-02: http:// наружу запрещён (локальные зеркала для тестов — можно)
  case "$base" in
    http://127.0.0.1*|http://localhost*|http://\[::1\]*) ;;
    http://*) err "K-02: обновление по http:// запрещено — укажите https://-источник"; return 1 ;;
  esac
  local tmp tmpm sumf
  tmp="$(mktemp /tmp/.xkit-update.XXXXXX)" || return 1
  log "Скачиваю ${base}/xkit.sh ..."
  curl -fsSL "${base}/xkit.sh" -o "$tmp" || { err "Скачать не удалось: ${base}/xkit.sh"; rm -f "$tmp"; return 1; }
  # модуль меню — обязателен с v5.0.0 (UI-слой вынесен в отдельный файл)
  tmpm="$(mktemp /tmp/.xkit-menu.XXXXXX)" || { rm -f "$tmp"; return 1; }
  if ! curl -fsSL "${base}/xkit_menu.sh" -o "$tmpm"; then
    if [ -r "${XKIT_MENU_DIR}/xkit_menu.sh" ]; then
      warn "xkit_menu.sh в репо не найден — оставляю установленный (${XKIT_MENU_DIR})"
      tmpm=""
    else
      err "Скачать не удалось: ${base}/xkit_menu.sh (файл меню)"
      err "Залейте xkit_menu.sh в репозиторий (см. GITHUB_SETUP.md) или обновите снова позже"
      rm -f "$tmp" "$tmpm"; return 1
    fi
  fi
  local sumf="${tmp}.sha256" want got
  if curl -fsSL "${base}/xkit.sh.sha256" -o "$sumf" 2>/dev/null; then
    want="$(awk 'NR==1{print $1}' "$sumf")"; got="$(sha256sum "$tmp" | awk '{print $1}')"
    if [ -n "$want" ] && [ "$want" = "$got" ]; then
      ok "SHA-256 проверен: xkit.sh $got"
    else
      err "SHA-256 НЕ совпал — обновление отменено (файл битый или изменён)"
      rm -f "$tmp" "$sumf"; [ -n "$tmpm" ] && rm -f "$tmpm"
      return 1
    fi
    if [ -n "$tmpm" ]; then
      want="$(awk '$2=="xkit_menu.sh"{print $1; exit}' "$sumf")"
      got="$(sha256sum "$tmpm" | awk '{print $1}')"
      if [ -z "$want" ]; then
        # K-02: меню без суммы не ставим — оставляем установленное
        warn "В пломбе нет строки xkit_menu.sh — меню НЕ обновляю (оставляю установленное)"
        rm -f "$tmpm"; tmpm=""
      elif [ "$want" != "$got" ]; then
        err "SHA-256 xkit_menu.sh НЕ совпал — обновление отменено"
        rm -f "$tmp" "$sumf" "$tmpm"; return 1
      else
        ok "SHA-256 проверен: xkit_menu.sh $got"
      fi
    fi
  else
    if [ "${XKIT_ALLOW_UNVERIFIED:-0}" != "1" ]; then
      # K-02: fail-closed — без пломбы код не ставится
      err "xkit.sh.sha256 недоступен — обновление ОТМЕНЕНО (K-02: без суммы код не ставится)"
      err "Осознанный обход: XKIT_ALLOW_UNVERIFIED=1 xkit update"
      rm -f "$tmp" "$sumf"; [ -n "$tmpm" ] && rm -f "$tmpm"
      return 1
    fi
    warn "xkit.sh.sha256 недоступен, но задан XKIT_ALLOW_UNVERIFIED=1 — ставлю без проверки"
  fi
  bash -n "$tmp" || { err "Новый файл не проходит bash -n — обновление отменено"; rm -f "$tmp" "$sumf"; [ -n "$tmpm" ] && rm -f "$tmpm"; return 1; }
  if [ -n "$tmpm" ]; then
    bash -n "$tmpm" || { err "Новый xkit_menu.sh не проходит bash -n — обновление отменено"; rm -f "$tmp" "$sumf" "$tmpm"; return 1; }
  fi
  local nv; nv="$(grep -m1 '^XKIT_VERSION=' "$tmp" | cut -d'"' -f2)"; nv="${nv:-?}"
  if [ "$nv" = "$XKIT_VERSION" ] && [ "${XKIT_FORCE:-0}" != "1" ]; then
    ok "Уже установлена версия $nv (принудительно: XKIT_FORCE=1 xkit update)"
    rm -f "$tmp" "$sumf"; [ -n "$tmpm" ] && rm -f "$tmpm"
    return 0
  fi
  [ -f "$XKIT_BIN" ] && cp -f "$XKIT_BIN" "${XKIT_BIN}.bak"
  if ! install -m 700 "$tmp" "${XKIT_BIN}.new" || ! mv -f "${XKIT_BIN}.new" "$XKIT_BIN"; then
    err "Не удалось заменить $XKIT_BIN"; rm -f "$tmp" "$sumf"; [ -n "$tmpm" ] && rm -f "$tmpm"; return 1
  fi
  if [ -n "$tmpm" ]; then
    mkdir -p "$XKIT_MENU_DIR" 2>/dev/null || true
    [ -f "${XKIT_MENU_DIR}/xkit_menu.sh" ] && cp -f "${XKIT_MENU_DIR}/xkit_menu.sh" "${XKIT_MENU_DIR}/xkit_menu.sh.bak"
    if install -m 700 "$tmpm" "${XKIT_MENU_DIR}/xkit_menu.sh.new" \
       && mv -f "${XKIT_MENU_DIR}/xkit_menu.sh.new" "${XKIT_MENU_DIR}/xkit_menu.sh"; then
      ok "Модуль меню обновлён: ${XKIT_MENU_DIR}/xkit_menu.sh"
    else
      err "Не удалось обновить ${XKIT_MENU_DIR}/xkit_menu.sh — меню докачается при первом запуске xkit"
    fi
  fi
  rm -f "$tmp" "$sumf"; [ -n "$tmpm" ] && rm -f "$tmpm"
  # v5.2: после ядра/меню атомарно обновляем модуль протоколов и TUI.
  xkit_extras_install || warn "Дополнительные компоненты обновятся при следующем запуске"
  rm -f "${XKIT_DIR}/update-check.json"
  ok "Обновлено: v${XKIT_VERSION} -> v${nv} ($XKIT_BIN); резервная копия: ${XKIT_BIN}.bak"
  ok "Конфиг nginx, состояние и подписки не тронуты"
  return 0
}

#=========================== МЕНЮ: МОДУЛЬНЫЙ UI (v5.0.0) ======================
# Меню живёт в отдельном файле xkit_menu.sh (UI-слой), чтобы xkit.sh не
# раздувался: правки меню не трогают ядро. Порядок поиска:
#   1) рядом с самим xkit.sh   2) $XKIT_MENU_DIR (/usr/local/lib/xkit)
#   3) каталог команды xkit    4) /etc/xkit
# Не нашли — докачиваем с XKIT_REPO_URL со сверкой SHA-256 (строка 2 пломбы).

# V-02 (аудит №2): код под root грузится ТОЛЬКО из доверенных мест — владелец
# root, без group/world-write, каталоги /tmp, /var/tmp, /dev/shm запрещены
xkit_dir_trusted() { # $1 каталог, $2 файл -> 0 = доверенный
  local d="$1" f="$2" st myuid
  case "$d" in /tmp|/tmp/*|/var/tmp|/var/tmp/*|/dev/shm|/dev/shm/*|/run/shm*) return 1 ;; esac
  myuid="$(id -u 2>/dev/null || echo 0)"
  st="$(stat -Lc '%u %a' "$d" 2>/dev/null)" || return 1
  # владелец = root ИЛИ текущий пользователь (dev-каталог в своей домашке —
  # доверенно; ЧУЖОЙ владелец при запуске под root — нет)
  { [ "${st%% *}" = "0" ] || [ "${st%% *}" = "$myuid" ]; } || return 1
  [ $(( 8#${st#* } & 8#022 )) -eq 0 ] || return 1
  st="$(stat -Lc '%u %a' "$f" 2>/dev/null)" || return 1
  { [ "${st%% *}" = "0" ] || [ "${st%% *}" = "$myuid" ]; } || return 1
  [ $(( 8#${st#* } & 8#022 )) -eq 0 ] || return 1
  return 0
}

xkit_menu_src() { # -> печатает путь к найденному xkit_menu.sh; 1 = не нашли
  local d f self
  self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
  # №19 (аудит №1): dirname вместо ${XKIT_BIN%/*} (без слэша давал мусорный путь)
  for d in "$(dirname "$self")" "${XKIT_MENU_DIR}" "$(dirname -- "${XKIT_BIN:-/usr/local/bin/xkit}" 2>/dev/null)" "/etc/xkit"; do
    [ -n "$d" ] || continue
    f="$d/xkit_menu.sh"
    [ -r "$f" ] || continue
    # V-02: подозрительное расположение (например, /tmp) — пропускаем кандидата
    if ! xkit_dir_trusted "$d" "$f"; then
      warn "Пропускаю $f: каталог/файл не доверенные (owner/mode, V-02)"
      continue
    fi
    printf '%s\n' "$f"; return 0
  done
  return 1
}

xkit_menu_fetch() { # авто-докачка меню (потеря файла / обновление со старой версии)
  local base="${XKIT_REPO_URL:-}"
  [ -n "$base" ] || return 1
  case "$base" in */xkit.sh) base="${base%/*}" ;; esac
  mkdir -p "$XKIT_MENU_DIR" 2>/dev/null || return 1
  local tmp sumf want got
  tmp="$(mktemp /tmp/.xkit-menu.XXXXXX)" || return 1
  curl -fsSL "${base}/xkit_menu.sh" -o "$tmp" || { rm -f "$tmp"; return 1; }
  sumf="$(mktemp /tmp/.xkit-menu-sum.XXXXXX)" || { rm -f "$tmp"; return 1; }
  if curl -fsSL "${base}/xkit.sh.sha256" -o "$sumf" 2>/dev/null; then
    want="$(awk '$2=="xkit_menu.sh"{print $1; exit}' "$sumf")"
    got="$(sha256sum "$tmp" | awk '{print $1}')"
    if [ -n "$want" ] && [ "$want" != "$got" ]; then
      err "SHA-256 xkit_menu.sh НЕ совпал — докачка отменена"
      rm -f "$tmp" "$sumf"; return 1
    fi
    if [ -z "$want" ]; then
      # K-02: без суммы докачка fail-open'ом больше не проходит
      err "В пломбе нет строки xkit_menu.sh — докачка отменена (K-02)"
      rm -f "$tmp" "$sumf"; return 1
    fi
  else
    err "Сумма xkit_menu.sh недоступна — докачка отменена (K-02; осознанный обход: XKIT_ALLOW_UNVERIFIED=1)"
    if [ "${XKIT_ALLOW_UNVERIFIED:-0}" != "1" ]; then
      rm -f "$tmp"; return 1
    fi
    warn "XKIT_ALLOW_UNVERIFIED=1 — ставлю меню без проверки"
  fi
  bash -n "$tmp" 2>/dev/null || { err "xkit_menu.sh не проходит bash -n — докачка отменена"; rm -f "$tmp" "$sumf"; return 1; }
  local rc=0
  # F-1 (аудит №2): раньше local rc=$? стоял после if и всегда был 0 —
  # неудачная установка меню маскировалась «ок»
  if install -m 700 "$tmp" "${XKIT_MENU_DIR}/xkit_menu.sh.new" \
     && mv -f "${XKIT_MENU_DIR}/xkit_menu.sh.new" "${XKIT_MENU_DIR}/xkit_menu.sh"; then
    ok "Модуль меню докачан: ${XKIT_MENU_DIR}/xkit_menu.sh"
  else
    err "Не удалось установить xkit_menu.sh в ${XKIT_MENU_DIR}"
    rc=1
  fi
  rm -f "$tmp" "$sumf"
  return $rc
}

xkit_menu_install() { # положить модуль меню в $XKIT_MENU_DIR (вызывается установщиком)
  local self src
  self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
  src="$(dirname "$self")/xkit_menu.sh"
  if [ -r "$src" ] && xkit_dir_trusted "$(dirname "$src")" "$src"; then
    mkdir -p "$XKIT_MENU_DIR" 2>/dev/null || return 1
    # F-2 (аудит №2): раньше cp без ветки неудачи — функция возвращала 0 даже при сбое
    if cp -f "$src" "${XKIT_MENU_DIR}/xkit_menu.sh" && chmod 700 "${XKIT_MENU_DIR}/xkit_menu.sh"; then
      ok "Модуль меню: ${XKIT_MENU_DIR}/xkit_menu.sh"
    else
      err "Не удалось скопировать модуль меню в ${XKIT_MENU_DIR}"
      return 1
    fi
    return 0
  fi
  [ -r "$src" ] && warn "Локальный $src не доверенный (V-02) — меню будет докачано из репо"
  # рядом со скриптом нет (установка из пайпа) — докачаем с репо
  xkit_menu_fetch \
    || warn "xkit_menu.sh не найден рядом и не докачан — меню скачается при первом запуске xkit"
  return 0
}

xkit_load_menu() { # подключить модуль меню (source); 1 = не нашли (ошибка уже напечатана)
  local f
  if f="$(xkit_menu_src)" && . "$f"; then return 0; fi
  # load_xkit_env при ОТСУТСТВИИ env-файла (свежая машина) затирает
  # XKIT_REPO_URL и выходит раньше восстановления — репо-адрес из внешнего
  # env (install.sh пробрасывает его явно) терялся, авто-докачка молчала
  local _repo="${XKIT_REPO_URL:-}"
  load_xkit_env >/dev/null 2>&1 || true
  [ -n "${XKIT_REPO_URL:-}" ] || XKIT_REPO_URL="$_repo"
  if xkit_menu_fetch && f="$(xkit_menu_src)" && . "$f"; then return 0; fi
  err "Не найден файл меню xkit_menu.sh (ищу рядом со скриптом, в ${XKIT_MENU_DIR} и /etc/xkit)"
  err "Обновите установку:  sudo xkit update   либо переустановите через install.sh"
  return 1
}

#=========================== V5.2: TUI И ПРОТОКОЛЫ ============================
xkit_component_fetch() { # $1 имя в репо, $2 конечный файл; SHA-256 обязателен
  local base="${XKIT_REPO_URL:-}" name="$1" dst="$2" tmp sumf want got
  [ -n "$base" ] || return 1
  case "$base" in */xkit.sh) base="${base%/*}" ;; esac
  case "$base" in http://127.0.0.1*|http://localhost*|http://\[::1\]*) ;; http://*) return 1 ;; esac
  tmp="$(mktemp /tmp/.xkit-component.XXXXXX)" || return 1
  sumf="$(mktemp /tmp/.xkit-component-sum.XXXXXX)" || { rm -f "$tmp"; return 1; }
  curl -fsSL "${base}/${name}" -o "$tmp" && curl -fsSL "${base}/xkit.sh.sha256" -o "$sumf" || { rm -f "$tmp" "$sumf"; return 1; }
  want="$(awk -v n="$name" '$2==n{print $1;exit}' "$sumf")"
  got="$(sha256sum "$tmp" | awk '{print $1}')"
  [ -n "$want" ] && [ "$want" = "$got" ] || { err "SHA-256 ${name} не совпал или отсутствует"; rm -f "$tmp" "$sumf"; return 1; }
  case "$name" in *.sh) bash -n "$tmp" || { rm -f "$tmp" "$sumf"; return 1; } ;; esac
  mkdir -p "$(dirname "$dst")" && install -m 700 "$tmp" "${dst}.new" && mv -f "${dst}.new" "$dst" || { rm -f "$tmp" "$sumf"; return 1; }
  rm -f "$tmp" "$sumf"
  ok "Компонент установлен: $dst"
}

xkit_extras_install() { # протоколы + TUI текущей архитектуры
  local self src arch name rc=0
  self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
  src="$(dirname "$self")"
  mkdir -p "$XKIT_MENU_DIR" || return 1
  if [ -r "$src/xkit_protocols.sh" ] && xkit_dir_trusted "$src" "$src/xkit_protocols.sh"; then
    [ ! -f "$XKIT_PROTOCOLS_FILE" ] || cp -f "$XKIT_PROTOCOLS_FILE" "${XKIT_PROTOCOLS_FILE}.bak"
    install -m 700 "$src/xkit_protocols.sh" "$XKIT_PROTOCOLS_FILE" || rc=1
  else
    xkit_component_fetch xkit_protocols.sh "$XKIT_PROTOCOLS_FILE" || rc=1
  fi
  case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) warn "TUI: архитектура $(uname -m) не поддерживается"; return "$rc" ;; esac
  name="xkit-tui-linux-${arch}"
  if [ -r "$src/$name" ] && xkit_dir_trusted "$src" "$src/$name"; then
    [ ! -f "$XKIT_TUI_FILE" ] || cp -f "$XKIT_TUI_FILE" "${XKIT_TUI_FILE}.bak"
    install -m 700 "$src/$name" "$XKIT_TUI_FILE" || rc=1
  else
    xkit_component_fetch "$name" "$XKIT_TUI_FILE" || rc=1
  fi
  return "$rc"
}

xkit_protocols_load() {
  local f="$XKIT_PROTOCOLS_FILE" self
  if [ ! -r "$f" ]; then
    self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
    [ -r "$(dirname "$self")/xkit_protocols.sh" ] && f="$(dirname "$self")/xkit_protocols.sh"
  fi
  if [ -r "$f" ] && xkit_dir_trusted "$(dirname "$f")" "$f"; then
    XKIT_PROTOCOLS_FILE="$f"; . "$f"; return 0
  fi
  err "Модуль протоколов не найден или не доверен: $f (выполните xkit update)"
  return 1
}

xkit_tui_run() {
  [ "${XKIT_TUI:-1}" = 1 ] && [ "${FORCE_CLASSIC:-0}" != 1 ] || return 1
  [ -t 0 ] && [ -t 1 ] || return 1
  if [ ! -x "$XKIT_TUI_FILE" ]; then
    local self0 arch0
    self0="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
    case "$(uname -m)" in x86_64) arch0=amd64 ;; aarch64|arm64) arch0=arm64 ;; *) arch0=unknown ;; esac
    [ -r "$(dirname "$self0")/xkit-tui-linux-${arch0}" ] && XKIT_TUI_FILE="$(dirname "$self0")/xkit-tui-linux-${arch0}"
  fi
  if [ ! -x "$XKIT_TUI_FILE" ] && [ "$(id -u)" = 0 ]; then
    load_xkit_env >/dev/null 2>&1 || true
    xkit_extras_install >/dev/null 2>&1 || true
  fi
  [ -x "$XKIT_TUI_FILE" ] && xkit_dir_trusted "$(dirname "$XKIT_TUI_FILE")" "$XKIT_TUI_FILE" || return 1
  local self; self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
  "$XKIT_TUI_FILE" --xkit "$self"
}

xkit_snapshot() { # только агрегаты; без UUID, privateKey, паролей и токенов
  load_xkit_env >/dev/null 2>&1 || true
  local host="${XKIT_HOST:-}" mode=solo nodes=0 nodes_ok=0 clients=0 cert_days=-1 backup_hours=-1
  local nginx=false xui=false xray=false protocols='[]' inbounds='' nodes_metrics='[]' metrics_generated=0 client_names='[]'
  systemctl is-active --quiet nginx 2>/dev/null && nginx=true
  systemctl is-active --quiet x-ui 2>/dev/null && xui=true
  pgrep -x xray >/dev/null 2>&1 && xray=true
  if [ -r "$XKIT_NODES" ]; then nodes="$(jq 'length' "$XKIT_NODES" 2>/dev/null || echo 0)"; fi
  [[ "$nodes" =~ ^[0-9]+$ ]] || nodes=0
  [ "$nodes" -gt 0 ] && mode=master
  if [ -r "$XKIT_NODES_METRICS" ]; then
    # Явный whitelist: host, заметки, реквизиты панели и любые новые поля кэша
    # автоматически в snapshot не попадают.
    # (з.8, аудит v5.2.1): interval_up/interval_down в whitelist — иначе TUI не может
    # показать «↑/↓ за интервал» отдельно от общего
    nodes_metrics="$(jq -c '[.nodes[]?|{name,status,panel,latency_ms,cpu_pct,ram_pct,load1,total,clients,resources,rate_bps,interval_total,interval_up,interval_down}]' "$XKIT_NODES_METRICS" 2>/dev/null || echo '[]')"
    metrics_generated="$(jq -r '.generated // 0' "$XKIT_NODES_METRICS" 2>/dev/null || echo 0)"
    nodes_ok="$(jq '[.nodes[]?|select(.status=="ok")]|length' "$XKIT_NODES_METRICS" 2>/dev/null || echo 0)"
  elif [ -r "${XKIT_DASH_DIR}/data.json" ]; then
    nodes_ok="$(jq '[.nodes[]?|select(.status=="ok")]|length' "${XKIT_DASH_DIR}/data.json" 2>/dev/null || echo 0)"
  fi
  [[ "$nodes_ok" =~ ^[0-9]+$ ]] || nodes_ok=0
  [[ "$metrics_generated" =~ ^[0-9]+$ ]] || metrics_generated=0
  if [ -r "${XKIT_CRT:-}" ]; then
    local end_epoch now_epoch
    end_epoch="$(date -d "$(openssl x509 -in "$XKIT_CRT" -noout -enddate 2>/dev/null | cut -d= -f2-)" +%s 2>/dev/null || echo 0)"
    now_epoch="$(date +%s)"; [ "$end_epoch" -gt 0 ] && cert_days=$(( (end_epoch-now_epoch)/86400 ))
  fi
  local latest; latest="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'xkit-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
  if [ -n "$latest" ]; then backup_hours=$(( ($(date +%s)-$(stat -c %Y "$latest" 2>/dev/null || date +%s))/3600 )); fi
  if kit_session >/dev/null 2>&1; then
    inbounds="$(api_list 2>/dev/null || true)"
    client_names="$(jq -c '[.[]?|(.settings|fromjson?|.clients[]?)|.email // empty]|unique' <<<"$inbounds" 2>/dev/null || echo '[]')"
    clients="$(jq 'length' <<<"$client_names" 2>/dev/null || echo 0)"
  fi
  [[ "$clients" =~ ^[0-9]+$ ]] || clients=0
  if xkit_protocols_load >/dev/null 2>&1; then
    protocols="$(protocols_snapshot_json 2>/dev/null || echo '[]')"
  fi
  # freeze-вердикты (7.3): кэш nodes-freeze.json не содержит секретов — только
  # вердикт/байты/время; в snapshot добавляем verdict+at, чтобы TUI показывал
  # «заморозку» рядом со статусом ноды без отдельного вызова CLI
  local fz_state="${XKIT_FREEZE_STATE:-${XKIT_DIR}/nodes-freeze.json}"
  if [ -r "$fz_state" ] && [ "$nodes" -gt 0 ]; then
    nodes_metrics="$(jq -c --slurpfile fz "$fz_state" '
      map(. as $n | ($fz[0].nodes[$n.name] // null) as $r
          | if ($r|type)=="object" and ($r.verdict|type)=="string"
            then . + {freeze:{verdict:$r.verdict, at:($r.at // 0)}}
            else . end)' <<<"$nodes_metrics" 2>/dev/null || echo "$nodes_metrics")"
  fi
  jq -nc --arg host "$host" --arg mode "$mode" --arg generated "$(date -Iseconds)" \
    --argjson nodes "$nodes" --argjson nodes_ok "$nodes_ok" --argjson clients "$clients" \
    --argjson nginx "$nginx" --argjson xui "$xui" --argjson xray "$xray" \
    --argjson cert_days "$cert_days" --argjson backup_hours "$backup_hours" --argjson protocols "$protocols" \
    --argjson nodes_metrics "$nodes_metrics" --argjson metrics_generated "$metrics_generated" --argjson client_names "$client_names" \
    '{host:$host,mode:$mode,nodes:$nodes,nodes_ok:$nodes_ok,clients:$clients,client_names:$client_names,nginx:$nginx,xui:$xui,xray:$xray,cert_days:$cert_days,backup_hours:$backup_hours,protocols:$protocols,nodes_metrics:$nodes_metrics,metrics_generated:$metrics_generated,generated:$generated}'
}

#=========================== ФАЙЛ ОТВЕТОВ (v7.2.0) ============================
# Неинтерактивная установка: `xkit install --answers файл` (или XKIT_ANSWERS=...).
# Формат — KEY=VALUE, только ключи XKIT_ANSWER_* (см. справку ниже).
xkit_answers_load() {
  local f="${1:-${XKIT_ANSWERS:-}}" line k v
  [ -n "$f" ] || { err "файл ответов не указан (--answers FILE)"; return 1; }
  [ -r "$f" ] || { err "файл ответов не найден/не читается: $f"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    k="${line%%=*}"; v="${line#*=}"
    [ "$k" != "$line" ] || { err "файл ответов: строка без '=': ${line:0:40}"; return 1; }
    [[ "$k" =~ ^XKIT_ANSWER_[A-Z0-9_]+$ ]] || { err "файл ответов: недопустимый ключ: $k"; return 1; }
    printf -v "$k" '%s' "$v"
  done < "$f"
  log "Файл ответов применён: $f"
  return 0
}

usage() {
  cat <<EOF
XKIT v${XKIT_VERSION} — nginx(TLS 443) + 3X-UI одним шагом, меню как у родного x-ui

Использование:
  xkit                 — полноэкранный TUI (при наличии; иначе классическое меню)
  xkit --classic       — классическое Bash-меню (6 групп с подменю)
  xkit protocols       — REALITY/XHTTP/AmneziaWG/Hysteria 2
  xkit protocols list [--json] — санитизированная сводка профилей
  xkit protocols remove — удалить выбранный inbound и обновить nginx/подписки
  xkit snapshot        — JSON состояния для TUI (без секретов)
  xkit install         — установка одним шагом (при уже установленном — меню:
                         обновить / переустановить чисто / починить поверх)
  xkit install --answers FILE — неинтерактивная установка по файлу ответов
                         (ключи XKIT_ANSWER_*: HOST, CERT_MODE (0 = серт из
                         бэкапа без перевыпуска), LE_EMAIL, BACKUP_ENABLED,
                         BACKUP_INTERVAL_H, BACKUP_KEEP_DAYS, BACKUP_KEEP_MIN)
  xkit reinstall       — ЧИСТАЯ переустановка: бэкап -> полное удаление -> установка
  xkit uninstall [--full|--purge] — удалить xkit (бэкап делается ОБЯЗАТЕЛЬНО;
                         --full = вместе с 3X-UI и /etc/nginx/ssl; --purge = БЕЗ
                         СОХРАНЕНИЙ: бэкапы, /etc/letsencrypt, venv certbot, логи,
                         пакеты nginx/certbot если чужих сайтов нет; бэкап не создаётся)
  xkit route [--yes]   — автопроброс всех инбаундов за nginx (без вопросов: --yes)
  xkit sub [-q]        — base64 + Clash + sing-box подписки и metadata
  xkit sub qr <subId> [svg|png|awg] — QR подписки или animated QR для AmneziaVPN
  xkit client add|del|list|reset — управление пользователями
  xkit client show <email> — ссылки и локальный QR конкретного пользователя
  xkit client del|reset <email> [--yes] — действие без выбора по номеру
  xkit client all      — пользователь во ВСЕ протоколы сразу (одна подписка)
  xkit reality          — Reality: создать inbound (wizard)
  xkit sockopt [on|off|status] — TCP Fast Open + TCP_NODELAY на TCP-инбаундах
                         (on — sysctl net.ipv4.tcp_fastopen=3 + sockopt всем
                         vless/vmess/trojan; off — снять наш sockopt)
  xkit nodes            — меню нод (добавить/список/health/стратегия/удалить)
  xkit nodes repair     — переприменить конфигурацию нод (после сбоя apply)
  xkit nodes repin [имя|all] — перепинить сертификат панели ноды (MITM-защита)
  xkit nodes metrics    — обновить трафик, скорость, ping и системные CPU/RAM нод
  xkit nodes check [имя|all] [--json] [--deep] — проверка нод: TCP, SSH, API, служба x-ui;
                         --deep добавляет CPU/RAM/диск/версии/срок серта панели
  xkit nodes freeze [имя|all] — замер «заморозки» ТСПУ на леге мастер→нода
                         (идея и логика замера: freeze-check, MIT); без имени —
                         показать сохранённые вердикты (файл nodes-freeze.json)
  xkit nodes plan [--json] — sanitized drift diff без изменений
  xkit nodes apply --canary <имя> | --remaining — поэтапное применение
  xkit nodes token set|remove <имя> — scoped API token (0600, не argv)
  xkit nodes relogin <имя|all> [none] — обновить API-токен ноды из install-result.env (Bearer вместо пароля)
  xkit nodes panel-sync <имя|all> — добавить/обновить «Узлы» 3X-UI без импорта инбаундов
  xkit nodes cert <имя|all> [self|ip|domain|wildcard] [домен] — сертификат панели ноды (wildcard выпускает мастер по dns-01)
  xkit nodes cert show — таблица сертификатов/камо нод
  xkit nodes cert-renew [имя|--cron] — продление wildcard-линейджей мастера + пере-раздача нодам
  xkit nodes camo <имя|all> [домен] — camo-сьют ноды: свой сайт + фейк-логин /login + vhost api./dev./login.
  xkit nodes camo-off <имя|all> — снять camo с ноды
  xkit nodes readdress <имя> <новый-IP> [--dry-run] — смена IP без переустановки
  xkit nodes profile list|survey|switch|benchmark <имя> [профиль] — канал мастер→нода
  xkit nodes tune <имя> show|safe|balanced — откатываемая сетевая настройка
  xkit nodes credentials — обновить /root/xkit-node-ИМЯ.txt (0600)
  xkit telegram-proxy ... — только MTProto FakeTLS и Telegram Web Proxy
  xkit reality scan-csv [tsv] [csv] — TLS/ALPN/issuer отчёт
  xkit extfix           — externalProxy + подписки панели (корректные ссылки в UI)
  xkit health          — проверка жизнеспособности
  xkit health deep     — глубокая проверка: реальный клиент по нашим ссылкам
                         (REALITY/XHTTP/Hysteria2) открывает страницу через туннель
  xkit backup [create|verify|export] — бэкап, проверка или age-экспорт
  xkit backup auto     — плановый бэкап (гейт интервала; вызывает cron)
  xkit backup settings [enabled interval_h [days min]] — политика бэкапов:
                         вкл/выкл, интервал 24/48/168/свой, срок хранения и
                         минимум копий (по умолчанию 14 дн и 3 копии)
  xkit restore [--dry-run] [файл] — проверить восстановление или восстановить
  xkit doctor export [--output файл.tar.gz] — sanitized support bundle
  xkit maintenance install|run — logrotate и ежедневный systemd timer
  xkit restart defer <service>|apply|status — отложенные перезапуски
  xkit ledger collect|show|quota-check <bytes> — read-only монотонный учёт
  xkit geodata update <tag> <sha256 geoip> <sha256 geosite> — pinned update
  xkit status          — сервисы, порты, что светится наружу
  xkit dash [install|gen|url|rotate|uninstall] — веб-дашборд (статусы/трафик/аренда;
                         rotate — новый токен URL + новый логин/пароль)
  xkit expiry set <master|имя_ноды> ГГГГ-ММ-ДД [заметка]
  xkit expiry list|check|del <master|имя_ноды> — сроки аренды серверов
  xkit telegram [setup|check|test|off] — Telegram-алерты: настроить,
                         проверить сейчас (как cron), тест, выключить.
                         Доставка напрямую, при неудаче — через ноды (их IP)
  xkit info            — сводка в терминал (пароли маскируются) + полная в ${XKIT_INFO_FILE}
  xkit core-pin [версия] — закрепить ядро Xray панели (SHA-256 по .dgst, с откатом);
                         без аргумента — версия XKIT_CORE_PIN (${XKIT_CORE_PIN:-26.6.27})
  xkit bbr status|on|off — BBR + fq (TCP congestion control): рекомендация
                         после установки; on пишет /etc/sysctl.d/99-xkit-bbr.conf
  xkit versions list|status — связки и установленные версии
  xkit versions install <3xui> <xray> — SHA-256 + snapshot + probes + rollback
  xkit versions rollback [snapshot] — восстановить прежнюю связку и БД
  xkit camo status|files — состояние и файлы, которые можно заменить вручную
  xkit camo regenerate [seed] — новый случайный сайт; seed = воспроизводимый вариант
  xkit update [URL]    — обновить xkit из репозитория (SHA-256 + бэкап; URL = .../main)
  xkit update --check [--force] — проверить новую версию (кэш 6 часов)
  xkit help            — эта справка

Неинтерактивный режим (CI/cloud-init): XKIT_YES=1 (согласие на вопросы) и
  XKIT_FORCE=1 (установка поверх существующей без меню). Полная автоматизация —
  `xkit install --answers FILE` (или XKIT_ANSWERS=FILE). install.sh пробрасывает:
  bash install.sh -y | --yes | --force

Файлы:
  $XKIT_ENV    — состояние (адрес, серты, токен подписок)
  $XKIT_ROUTES — таблица маршрутов (id/mode/net/path/target)
  $XKIT_NODES  — реестр нод (туннели, панель ноды, стратегия)
  $XKIT_CONF   — конфиг nginx (генерируется xkit, не правьте руками)
  $SUBS_DIR    — файлы подписок (base64, раздаются nginx по /s-<token>/)
  $XKIT_EXPIRY — сроки аренды серверов (мастер + ноды)
  $XKIT_DASH_DIR — веб-дашборд (index.html + data.json)
  $XKIT_INFO_FILE — сводка-реквизиты (обновляется после установки и операций)
EOF
}

xkit_main_impl() {
  case "${1:-menu}" in
    menu|"") if xkit_tui_run; then exit 0; fi; xkit_load_menu || exit 1; menu_loop ;;
    --classic|classic) xkit_load_menu || exit 1; menu_loop ;;
    protocols|proto) shift; require_root; xkit_protocols_load || exit 1; protocols_main "$@" ;;
    snapshot) xkit_snapshot ;;
    install) shift; require_root
             if [ "${1:-}" = "--answers" ]; then xkit_answers_load "${2:-}" || exit 1; shift 2; fi
             one_step_install ;;
    reinstall) require_root; xkit_reinstall ;;
    uninstall) shift; require_root; xkit_uninstall "$@" ;;
    route)   shift; [ "${1:-}" = "--yes" ] && export XKIT_YES=1; require_root; auto_route ;;
    sub)     shift
             if [ "${1:-}" = qr ]; then require_root; sub_qr "${2:-}" "${3:-svg}"
             else [ "${1:-}" = "-q" ] && export SUB_QUIET=1; require_root; sub_regen; fi ;;
    client)  shift; require_root
             case "${1:-list}" in
               add) client_add_all ;; del) shift; client_del "$@" ;; list) client_list ;;
               reset) shift; client_reset "$@" ;; show) shift; client_show "$@" ;;
               all) client_add_all ;;
               *) err "xkit client add|all|del|list|reset|show"; exit 1 ;;
             esac ;;
    reality) shift; require_root; load_xkit_env || true
             if [ "${1:-}" = scan-csv ]; then reality_scan_csv "${2:-${XKIT_DIR}/reality-scan.tsv}" "${3:-${XKIT_DIR}/reality-scan.csv}"; else reality_wizard; fi ;;
    sockopt) shift; sockopt_cmd "${1:-status}" ;;
    nodes)   shift; require_root
             case "${1:-menu}" in
               repair) nodes_repair ;;
               repin)  shift; node_repin "${1:-all}" ;;
               metrics) nodes_metrics_collect >/dev/null && ok "Метрики нод обновлены: $XKIT_NODES_METRICS" ;;
               check) shift; nodes_check "$@" ;;
               freeze) shift; nodes_freeze "$@" ;;
               plan) shift; nodes_plan "${1:-}" ;;
               apply) shift
                      case "${1:-}" in
                        --canary) nodes_apply_canary "${2:-}" ;;
                        --remaining) nodes_apply_remaining ;;
                        *) err "nodes apply --canary <имя> | --remaining"; exit 1 ;;
                      esac ;;
               token) shift
                      case "${1:-}" in set) node_token_set "${2:-}" ;; remove) node_token_revoke_local "${2:-}" ;; *) err "nodes token set|remove <имя>"; exit 1 ;; esac ;;
               relogin) shift; node_relogin "${1:-all}" "${2:-}" ;;
               panel-sync) shift; node_panel_sync "${1:-}" ;;
               cert) shift; node_cert_dispatch "$@" ;;
               cert-renew) shift; node_cert_dispatch renew "$@" ;;
               camo) shift; node_camo_dispatch "$@" ;;
               camo-off) shift; node_camo_dispatch off "$@" ;;
               readdress) shift; node_readdress "$@" ;;
               profile) shift
                      case "${1:-list}" in list) node_profile_list "${2:-all}" ;; survey) node_profile_survey "${2:-}" ;; switch) node_profile_switch "${2:-}" "${3:-}" ;; benchmark) node_profile_benchmark "${2:-}" ;; *) err "nodes profile list|survey <имя>|switch <имя> <профиль>|benchmark <имя>"; exit 1 ;; esac ;;
               tune) shift; node_tune "$@" ;;
               credentials) nodes_access_export_all; return $? ;;
               *) nodes_menu ;;
             esac
             local nodes_rc=$?
             nodes_access_export_all || warn "Не удалось обновить txt-реквизиты нод"
             return "$nodes_rc" ;;
    extfix)  require_root; external_proxy_fix ;;
    health)  shift
             if [ "${1:-}" = "deep" ]; then require_root; health_deep; else health_check; fi ;;
    core-pin) shift; require_root; core_pin_install "${1:-}" ;;
    versions)
      case "${1:-status}" in
        list) versions_list ;;
        status) versions_status ;;
        install) shift; require_root; versions_install "$@" ;;
        rollback) shift; require_root; versions_rollback "${1:-}" ;;
        *) die "versions: list | status | install <3xui> <xray> | rollback [snapshot]" ;;
      esac ;;
    camo)
      case "${1:-status}" in
        status) camo_status ;;
        files) camo_files ;;
        regenerate) require_root; camo_regenerate "${2:-}" ;;
        *) die "camo: status | files | regenerate [64-hex seed]" ;;
      esac ;;
    backup)  shift; require_root
             case "${1:-create}" in
               create|now) backup_now ;;
               auto) backup_auto ;;
               settings) shift
                         if [ $# -ge 2 ]; then backup_settings_set "$@"; else backup_settings_show; fi ;;
               verify) backup_verify "${2:-}" ;;
               export) backup_export "${2:-}" ;;
               *) err "backup [create|auto|settings|verify [файл]|export [файл]]"; exit 1 ;;
             esac ;;
    restore) shift; require_root
             if [ "${1:-}" = --dry-run ]; then backup_restore_dry_run "${2:-}"; else backup_restore "${1:-}"; fi ;;
    status)  show_status ;;
    bbr)     shift; require_root
             case "${1:-status}" in
               status) bbr_status ;;
               on) bbr_on ;;
               off) bbr_off ;;
               *) die "bbr: status | on | off" ;;
             esac ;;
    dash)    shift; require_root
             case "${1:-menu}" in
               install|on) dash_install ;;
               uninstall|off) dash_uninstall ;;
               gen|build) dash_gen ;;
               url) dash_url ;;
               rotate|rekey) dash_rotate ;;
               *) dash_menu ;;
             esac ;;
    expiry)  shift; require_root
             case "${1:-menu}" in
               set) shift; expiry_cli_set "$@" ;;
               del|rm) shift; expiry_cli_del "$@" ;;
               list) expiry_list ;;
               check) expiry_check ;;
               *) expiry_menu ;;
             esac ;;
    telegram) shift; require_root
             case "${1:-menu}" in
               setup) telegram_setup ;;
               bot) shift
                    case "${1:-status}" in once) telegram_bot_once ;; run) telegram_bot_run ;; on|off|status) telegram_bot_service "${1:-status}" ;; *) err "telegram bot once|run|on|off|status"; exit 1 ;; esac ;;
               check) load_xkit_env >/dev/null 2>&1 || true; notify_check ;;
               test)  load_xkit_env >/dev/null 2>&1 || true
                      if xkit_tg_send "[XKIT] тест: канал доставки работает"; then ok "Доставлено"; else err "Не доставлено (напрямую и через ноды)"; exit 1; fi ;;
               off)   telegram_off ;;
               *)     telegram_menu ;;
             esac ;;
    telegram-proxy|tg-proxy) shift; require_root
             case "${1:-menu}" in
               mtproto) shift; tgproxy_mtproto_install "$@" ;;
               web) shift; tgproxy_web_install "$@" ;;
               list) tgproxy_list ;;
               link) tgproxy_link "${2:-mtproto}" ;;
               menu) tgproxy_menu ;;
               *) err "telegram-proxy mtproto|web|list|link"; exit 1 ;;
             esac ;;
    doctor) shift; require_root
            case "${1:-export}" in export) doctor_export "${3:-${2:-}}" ;; *) err "doctor export [--output файл.tar.gz]"; exit 1 ;; esac ;;
    audit) shift; require_root; audit_show "${2:-${1:-50}}" ;;
    restart) shift; require_root
             case "${1:-status}" in defer) restart_request "${2:-}" ;; apply) restart_apply ;; status) restart_status ;; *) err "restart defer <service>|apply|status"; exit 1 ;; esac ;;
    maintenance) shift; require_root
             case "${1:-run}" in install) ops_hygiene_install ;; run) maintenance_run ;; *) err "maintenance install|run"; exit 1 ;; esac ;;
    ledger) shift; require_root
            case "${1:-show}" in collect) traffic_ledger_collect && ok "Ledger обновлён" ;; show) traffic_ledger_show ;; quota-check) traffic_ledger_quota_check "${2:-}" ;; *) err "ledger collect|show|quota-check <bytes>"; exit 1 ;; esac ;;
    geodata) shift; require_root
             case "${1:-}" in update) shift; geodata_update "$@" ;; *) err "geodata update <tag> <geoip-sha256> <geosite-sha256>"; exit 1 ;; esac ;;
    update)  shift; if [ "${1:-}" = "--check" ]; then shift; xkit_update_check "$@"; else xkit_self_update "${1:-}"; fi ;;
    info)    require_root; xkit_info ;;
    help|-h|--help) usage ;;
    *) err "Неизвестная команда: $1 (xkit help)"; exit 1 ;;
  esac
}

# Точка входа перенесена в последний src-модуль: сначала определяются v7-функции.

#=========================== v6.0.0: CLASH/MIHOMO-ПОДПИСКИ ====================
# Статический Clash-YAML рядом с base64: $SUBS_DIR/<subId>.yaml, nginx отдаёт
# его с content-type application/yaml (см. generate_subs_block в 05).
# Зачем: единую ссылку удобнее двух — приложения на ядре Mihomo (Clash Verge,
# FlClash, Mihomo Party) не читают base64-список vless-ссылок.
#
# Схема полей — по маппингам Mihomo, проверенным в тест-матрице
# «протокол × клиент» проекта 3X-UI_KIT (itsnotkubrick):
#   * vless xhttp  -> network: xhttp + xhttp-opts (НЕ ws-opts);
#   * hysteria2    -> type: hysteria2, password, obfs/obfs-password;
#   * AmneziaWG    -> type: wireguard + amnezia-wg-option, h1..h4 СТРОКАМИ,
#                     при header-protection-key обязателен version: 3.
# В YAML попадают: панельные клиенты этого subId (все протоколы), плюс
# Hysteria 2 отдельной службы (пароль сервера общий — как и его ссылка).
# Отдельный (standalone) AWG НЕ попадает: его конфиги раздаются файлами
# per-client, привязать их к subId без панели нельзя.
#================================================================================

clash_q() { # JSON-строка является и безопасным YAML-скаляром
  jq -nc --arg s "${1-}" '$s'
}

clash_cert_pin() { # sha256 сертификата xkit (fingerprint для self-signed)
  [ -r "${XKIT_CRT:-}" ] || { printf ''; return; }
  openssl x509 -in "$XKIT_CRT" -noout -fingerprint -sha256 2>/dev/null \
    | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f'
}

# параметры amnezia-wg-option из settings.server инбаунда: TSV key<TAB>value
clash_awg_opts_tsv() { # $1 inbound JSON
  jq -r '.settings|if type=="string" then (fromjson? // {}) else . end
         | .server // {} | del(.privateKey,.publicKey,.subnetIp,.subnetCidr,.primaryDns,.secondaryDns)
         | to_entries[] | select(.value != null) | [.key, (.value|tostring)] | @tsv' <<<"$1" 2>/dev/null
}

clash_tls_tail() { # хвост TLS-полей для обычного TLS при self-signed серте
  [ "${XKIT_CERT_MODE:-}" = "4" ] && printf '    skip-cert-verify: true\n' || true
}

clash_hy2_tls_tail() { # fingerprint (pin) или skip-cert-verify для hysteria2
  if [ "${XKIT_CERT_MODE:-}" = "4" ]; then
    local pin; pin="$(clash_cert_pin)"
    if [ -n "$pin" ]; then printf '    fingerprint: %s\n' "$(clash_q "$pin")"
    else printf '    skip-cert-verify: true\n'; fi
  fi
}

# прокси из пары (inbound JSON, client JSON); печать YAML-блока или пусто
clash_proxy_entry() { # $1 inbound JSON, $2 client JSON, $3 email
  local ib="$1" cl="$2" email="$3"
  local proto port mode rnet rpath stream sec net
  proto="$(jq -r '.protocol' <<<"$ib")"
  port="$(jq -r '.port' <<<"$ib")"
  IFS='|' read -r mode rnet rpath <<<"$(route_info "$(jq -r '.id' <<<"$ib")")"
  stream="$(jq -r '.streamSettings // "{}"' <<<"$ib")"
  stream="$(jq -r 'if type=="string" then (fromjson? // "{}") else . end' <<<"$stream" 2>/dev/null)"
  sec="$(jq -r '.security // "none"' <<<"$stream" 2>/dev/null)"
  net="$(jq -r '.network // "tcp"' <<<"$stream" 2>/dev/null)"

  local name="" body=""
  case "$proto" in
    vless)
      local uuid flow sni pbk sid path svc tls_sec tls_port label
      uuid="$(jq -r '.id // ""' <<<"$cl")"; [ -n "$uuid" ] || return 0
      flow="$(jq -r '.flow // ""' <<<"$cl")"
      tls_port="$port"; path=""; svc=""
      if [ "$mode" = "local" ]; then
        tls_sec="tls"; tls_port=443; net="$rnet"
        case "$rnet" in
          grpc) svc="$(inbound_path "$ib" grpc)"; [ -n "$svc" ] || svc="xk-gr-${port}" ;;
          *)    path="$(inbound_path "$ib" "$rnet")"; [ -n "$path" ] || path="$rpath" ;;
        esac
        sni="${XKIT_HOST}"
      else
        tls_sec="$sec"
        if [ "$sec" = "reality" ]; then
          pbk="$(reality_pbk "$stream")"; sid="$(reality_sid "$stream")"
          sni="$(reality_sni "$stream")"; [ -n "$sni" ] || sni="${XKIT_HOST}"
        elif [ "$sec" = "tls" ]; then
          sni="${XKIT_HOST}"
        fi
        case "$net" in
          ws|xhttp|splithttp|httpupgrade) path="$(inbound_path "$ib" "$net")" ;;
          grpc) svc="$(inbound_path "$ib" grpc)" ;;
        esac
      fi
      case "$net" in xhttp|splithttp) net="xhttp" ;; httpupgrade) net="ws" ;; esac
      label="VLESS"; [ "$tls_sec" = "reality" ] && label="REALITY"
      [ "$net" = "xhttp" ] && label="XHTTP"
      name="${email} (${label} ${tls_port})"
      body="  - name: $(clash_q "$name")
    type: vless
    server: $(clash_q "$XKIT_HOST")
    port: ${tls_port}
    udp: true
    uuid: $(clash_q "$uuid")
"
      [ -n "$flow" ] && body+="    flow: $(clash_q "$flow")"$'\n'
      [ "$tls_sec" != "none" ] && body+="    tls: true"$'\n'
      [ -n "$sni" ] && body+="    servername: $(clash_q "$sni")"$'\n'
      body+="    client-fingerprint: chrome"$'\n'
      case "$net" in
        ws)    body+="    network: ws"$'\n'
               [ -n "$path" ] && body+="    ws-opts:"$'\n'"      path: $(clash_q "$path")"$'\n' ;;
        xhttp) body+="    network: xhttp"$'\n'"    xhttp-opts:"$'\n'"      path: $(clash_q "$path")"$'\n'"      mode: auto"$'\n' ;;
        grpc)  body+="    network: grpc"$'\n'"    grpc-opts:"$'\n'"      grpc-service-name: $(clash_q "$svc")"$'\n' ;;
      esac
      if [ "$tls_sec" = "reality" ]; then
        body+="    reality-opts:"$'\n'"      public-key: $(clash_q "$pbk")"$'\n'
        [ -n "$sid" ] && body+="      short-id: $(clash_q "$sid")"$'\n'
      elif [ "$tls_sec" = "tls" ]; then
        body+="$(clash_tls_tail)"
      fi
      printf '%s' "$body" ;;

    vmess)
      local uuid2 vpath
      uuid2="$(jq -r '.id // ""' <<<"$cl")"; [ -n "$uuid2" ] || return 0
      name="${email} (VMess ${port})"
      body="  - name: $(clash_q "$name")
    type: vmess
    server: $(clash_q "$XKIT_HOST")
    port: ${port}
    udp: true
    uuid: $(clash_q "$uuid2")
    alterId: 0
    cipher: auto
"
      [ "$sec" = "tls" ] && body+="    tls: true"$'\n'"    servername: $(clash_q "$XKIT_HOST")"$'\n'
      [ "$net" = "ws" ] && { vpath="$(inbound_path "$ib" ws)"; \
        body+="    network: ws"$'\n'"    ws-opts:"$'\n'"      path: $(clash_q "$vpath")"$'\n'; }
      printf '%s' "$body" ;;

    trojan)
      local pass2 tnet tpath tsvc
      pass2="$(jq -r '.password // .id // ""' <<<"$cl")"; [ -n "$pass2" ] || return 0
      name="${email} (Trojan ${port})"
      body="  - name: $(clash_q "$name")
    type: trojan
    server: $(clash_q "$XKIT_HOST")
    port: ${port}
    udp: true
    password: $(clash_q "$pass2")
    sni: $(clash_q "$XKIT_HOST")
"
      body+="$(clash_tls_tail)"
      tnet="$(jq -r '.network // "tcp"' <<<"$stream" 2>/dev/null)"
      case "$tnet" in
        ws)   tpath="$(inbound_path "$ib" ws)"; \
              body+="    network: ws"$'\n'"    ws-opts:"$'\n'"      path: $(clash_q "$tpath")"$'\n' ;;
        grpc) tsvc="$(inbound_path "$ib" grpc)"; \
              body+="    network: grpc"$'\n'"    grpc-opts:"$'\n'"      grpc-service-name: $(clash_q "$tsvc")"$'\n' ;;
      esac
      printf '%s' "$body" ;;

    shadowsocks)
      local spass smethod
      spass="$(jq -r '.password // ""' <<<"$cl")"
      [ -n "$spass" ] || spass="$(jq -r '.settings|if type=="string" then (fromjson? // {}) else . end | .password // ""' <<<"$ib")"
      [ -n "$spass" ] || return 0
      smethod="$(jq -r '.settings|if type=="string" then (fromjson? // {}) else . end | .method // "aes-256-gcm"' <<<"$ib")"
      name="${email} (SS ${port})"
      printf '  - name: %s\n    type: ss\n    server: %s\n    port: %s\n    cipher: %s\n    password: %s\n    udp: true\n' \
        "$(clash_q "$name")" "$(clash_q "$XKIT_HOST")" "$port" "$(clash_q "$smethod")" "$(clash_q "$spass")" ;;

    hysteria)
      # панельный inbound (Xray-core с протоколом hysteria): пароль клиента в .auth
      local hauth
      hauth="$(jq -r '.auth // ""' <<<"$cl")"; [ -n "$hauth" ] || return 0
      name="${email} (Hysteria2 ${port})"
      body="  - name: $(clash_q "$name")
    type: hysteria2
    server: $(clash_q "$XKIT_HOST")
    port: ${port}
    password: $(clash_q "$hauth")
"
      [ "${XKIT_CERT_MODE:-}" != "4" ] && body+="    sni: $(clash_q "$XKIT_HOST")"$'\n'
      body+="    alpn:"$'\n'"      - h3"$'\n'
      body+="$(clash_hy2_tls_tail)"
      printf '%s' "$body" ;;

    amneziawg|wireguard)
      # панельный inbound: ключи клиента в его записи, сервер — в settings.server
      local wpriv wpub wip k v has_hp=0
      wpriv="$(jq -r '.privateKey // ""' <<<"$cl")"
      wpub="$(jq -r '.publicKey // ""' <<<"$cl")"
      [ -n "$wpriv" ] && [ -n "$wpub" ] || return 0
      wip="$(jq -r '.allowedIPs[0] // ""' <<<"$cl" 2>/dev/null | cut -d/ -f1)"
      [ -n "$wip" ] || return 0
      local spub
      spub="$(jq -r '.settings|if type=="string" then (fromjson? // {}) else . end | .server.publicKey // ""' <<<"$ib")"
      [ -n "$spub" ] || return 0
      name="${email} (AmneziaWG ${port})"
      body="  - name: $(clash_q "$name")
    type: wireguard
    server: $(clash_q "$XKIT_HOST")
    port: ${port}
    ip: $(clash_q "$wip")
    private-key: $(clash_q "$wpriv")
    public-key: $(clash_q "$spub")
    udp: true
    amnezia-wg-option:
"
      while IFS=$'\t' read -r k v; do
        [ -n "$k" ] || continue
        case "$k" in
          h1|h2|h3|h4) v="'${v}'" ;;
          headerProtectionKey) has_hp=1; v="$(clash_q "$v")" ;;
          jc|jmin|jmax|s1|s2|s3|s4) : ;;
          i1|i2|i3|i4|i5) v="$(clash_q "$v")" ;;
          *) continue ;;
        esac
        body+="      ${k}: ${v}"$'\n'
      done < <(clash_awg_opts_tsv "$ib")
      [ "$has_hp" = "1" ] && body+="      version: 3"$'\n'
      printf '%s' "$body" ;;

    *) return 0 ;;
  esac
}

clash_standalone_hy2() { # блок hysteria2 из службы xkit-hysteria2 (если стоит)
  # состояние протоколов читаем напрямую: xkit sub работает без загрузки
  # xkit_protocols.sh, где живёт proto_state_load (файл пишет наш же установщик).
  # XKIT_HOST НЕ перечитываем (load_xkit_env при отсутствии env-файла
  # обнулил бы его) — вызывающий sub_regen уже загрузил состояние.
  [ -r "${XKIT_PROTOCOLS_ENV:-/etc/xkit/protocols.env}" ] || return 0
  # shellcheck disable=SC1090
  . "${XKIT_PROTOCOLS_ENV:-/etc/xkit/protocols.env}"
  [ -n "${HY2_PORT:-}" ] && [ -n "${HY2_AUTH:-}" ] || return 0
  [ -n "${XKIT_HOST:-}" ] || return 0
  local body
  body="  - name: $(clash_q "XKIT Hysteria2 ${HY2_PORT}")
    type: hysteria2
    server: $(clash_q "$XKIT_HOST")
    port: ${HY2_PORT}
    password: $(clash_q "$HY2_AUTH")
"
  if [ "${XKIT_CERT_MODE:-}" = "4" ]; then
    body+="    skip-cert-verify: true"$'\n'
  else
    body+="    sni: $(clash_q "$XKIT_HOST")"$'\n'
  fi
  [ -n "${HY2_OBFS:-}" ] && body+="    obfs: salamander"$'\n'"    obfs-password: $(clash_q "$HY2_OBFS")"$'\n'
  printf '%s' "$body"
}

clash_yaml_gen() { # $1 subId, $2 файл-аккумулятор «id<TAB>clientJSON» -> пишет $SUBS_DIR/<subId>.yaml
  local subid="$1" acc="$2"
  case "$subid" in ''|*[!A-Za-z0-9_-]*) err "Некорректный subId — YAML не создан"; return 1 ;; esac
  local out="${SUBS_DIR}/${subid}.yaml"
  local -a names=() wg_names=()
  local proxies="" nm ib cl block email
  while IFS=$'\t' read -r ibid cl; do
    [ -n "$ibid" ] || continue
    ib="$(jq -c --argjson i "$ibid" '[.[]|select(.id==$i)][0]' <<<"${INBOUNDS:-[]}" 2>/dev/null)"
    [ -n "$ib" ] && [ "$ib" != "null" ] || continue
    # клиент именно этого subId (в инбаунде их может быть несколько)
    cl="$(jq -c --arg s "$subid" '.settings|if type=="string" then (fromjson? // {clients:[]}) else . end
           | .clients[]? | select(.subId==$s)' <<<"$ib" 2>/dev/null | head -n1)"
    [ -n "$cl" ] || continue
    email="$(jq -r '.email // "user"' <<<"$cl")"
    block="$(clash_proxy_entry "$ib" "$cl" "$email")" || true
    [ -n "$block" ] || continue
    nm="$(sed -n 's/^  - name: //p' <<<"$block" | head -n1)"; nm="${nm%\"}"; nm="${nm#\"}"
    case "$block" in *"type: wireguard"*) wg_names+=("$nm") ;; *) names+=("$nm") ;; esac
    proxies+="$block"
  done < "$acc"

  # Hysteria 2 отдельной службой: пароль общий для сервера — как и его ссылка
  block="$(clash_standalone_hy2)"
  if [ -n "$block" ]; then
    nm="$(sed -n 's/^  - name: //p' <<<"$block" | head -n1)"; nm="${nm%\"}"; nm="${nm#\"}"
    names+=("$nm"); proxies+="$block"
  fi

  [ -n "$proxies" ] || { rm -f "$acc"; return 1; }

  # группы: «Авто» без WireGuard/AWG (имена они резолвят на клиенте — вставать
  # в автовыбор с ними нельзя), «Прокси» — всё
  local group_auto="" group_all="" n
  for n in "${names[@]}"; do group_auto+="      - $(clash_q "$n")"$'\n'; done
  for n in "${names[@]}" "${wg_names[@]:-}"; do
    [ -n "$n" ] && group_all+="      - $(clash_q "$n")"$'\n'
  done
  {
    printf '# XKIT v%s — Clash/Mihomo-профиль подписки (генерируется автоматически)\n' "$XKIT_VERSION"
    printf 'mixed-port: 7890\nallow-lan: false\nmode: rule\nlog-level: warning\nipv6: true\n\n'
    printf 'dns:\n  enable: true\n  enhanced-mode: fake-ip\n  fake-ip-range: 198.18.0.1/16\n  nameserver:\n    - "https://1.1.1.1/dns-query"\n    - "https://8.8.8.8/dns-query"\n\n'
    printf 'proxies:\n%s\n' "$proxies"
    printf '\nproxy-groups:\n'
    printf '  - name: "Авто"\n    type: url-test\n    url: "http://www.gstatic.com/generate_204"\n    interval: 300\n    proxies:\n%s' "$group_auto"
    printf '  - name: "Прокси"\n    type: select\n    proxies:\n      - "Авто"\n%s' "$group_all"
    printf '\nrules:\n  - GEOSITE,category-ru,DIRECT\n  - GEOIP,RU,DIRECT,no-resolve\n  - MATCH,Прокси\n'
  } > "$out"
  chmod 644 "$out"
  rm -f "$acc"
  return 0
}

#=========================== v6.0.0: ПАНЕЛЬНЫЙ РЕЖИМ ПРОТОКОЛОВ ===============
# Решение по образцу 3X-UI_KIT: Hysteria2 и AmneziaWG — не отдельные службы,
# а инбаунды самой панели (ядро Xray 26.x умеет протоколы hysteria/amneziawg).
# Что это даёт: единые пользователи (один subId во всех протоколах), единая
# подписка (панель рендерит и hysteria2://, и vpn://), общий учёт трафика.
#
# СТАБИЛЬНОСТЬ — двойной режим с эмпирической пробой: xkit сам проверяет,
# что ядро панели принимает протокол (создаёт пробный инбаунд на 127.0.0.1,
# ждёт слушателя на UDP-порту, удаляет пробу). Не умеет — фолбэк на
# standalone-службы (ветка v5.x, ни одна установка не ломается).
#
# v7.2.7: AmneziaWG 3.1 — общий генератор параметров awg31_gen_params (ниже),
# инбаунд с полной wire-схемой 3x-ui (internal/amneziawg/types.go) в двух
# профилях: «31» (Header Protection, гейт версии панели >= 3.7 + проба +
# контрольная сверка сохранённого headerProtectionKey) и «classic».
#================================================================================

# пара ключей WireGuard через бинарник xray панели ("Private key: x / Public key: y")
xray_wg_pair() { # -> "priv pub"
  local xr out
  xr="$(ls -1 /usr/local/x-ui/bin/xray-* 2>/dev/null | head -n1)"
  [ -n "$xr" ] || { err "Не найден бинарник xray панели"; return 1; }
  out="$("$xr" wg 2>/dev/null)" || { err "xray wg не сработал"; return 1; }
  local priv pub
  priv="$(awk '/Private/{print $NF}' <<<"$out")"
  pub="$(awk '/Public|Password/{print $NF; exit}' <<<"$out")"
  [ -n "$priv" ] && [ -n "$pub" ] || { err "Не удалось разобрать вывод xray wg"; return 1; }
  printf '%s %s\n' "$priv" "$pub"
}

#--- v7.2.7: AmneziaWG 3.1 — общий генератор параметров обфускации --------------
# Источники: docs.amnezia.org/Documentation/Amnezia-WG (спецификация 3.0/3.1),
# генератор 3x-ui internal/amneziawg/params.go (GenerateObfuscation31),
# bivlked/amneziawg-installer ADVANCED.md (живые измерения). Единый генератор
# для панельного инбаунда и отдельной службы: xkit_protocols.sh подгружается
# ПОСЛЕ xkit.sh, поэтому функция доступна в обоих путях (и в тестах).
# Инварианты (проверяются test_v728):
#  * Jc 3-6 — далеко ниже потолка 122 у amneziawg-клиентов (партия 128 пакетов:
#    Jc + I-пакеты + handshake; amneziawg-go#111);
#  * S1-S4 >= 12 — nonce шифра защиты заголовков берётся из первых 12 байт
#    S-паддинга; S4 <= 27 (запас MTU, у 3x-ui потолок 32);
#  * S1+56 != S2 — иначе init/response совпадут размером после паддинга;
#  * H1-H4 = 1/2/3/4 — ДОКУМЕНТИРОВАННЫЙ режим совместимости с Header
#    Protection: механизм кастомных заголовков выключен, тип сообщения прячет
#    HP-ключ. Диапазонные H не генерируем: вместе с RandomTrailers это баг
#    классификатора (amnezia-vpn/amneziawg-go#186,
#    amnezia-vpn/amneziawg-linux-kernel-module#226) — молча теряются
#    транспортные пакеты (замерено до 75% потерь);
#  * тайминги — диапазоны вокруг констант WireGuard (rekey 120 c, reject 180 c):
#    каждый reject строго больше каждого rekey минимум на 30 c; keepalive
#    <= 20 c — под 25 c PersistentKeepalive и NAT-таймауты UDP;
#  * ContentPaddingAddition: суммарный паддинг <= 64 (едет в полноразмерных
#    транспортных пакетах в том же MTU-запасе, что ограничивает S4);
#  * RandomTrailers/DisableCookies ВЫКЛЮЧЕНЫ: RandomTrailers двусторонний и
#    (до апстрим-фикса классификатора) режет пропускную способность в десятки
#    раз; DisableCookies ломает cookie-защиту от флуда рукопожатиями.
#    Отсутствие строки = «выключено», и парсер до 3.1 не спотыкается.
awg31_ri() { local lo="$1" hi="$2"; [ "$hi" -gt "$lo" ] 2>/dev/null || { printf '%s' "$lo"; return; }; printf '%s' "$((RANDOM % (hi - lo + 1) + lo))"; }
awg31_hpk() { # 32 байта base64 — формат HeaderProtectionKey (как awg genkey)
  if command -v openssl >/dev/null 2>&1; then openssl rand -base64 32; else head -c 32 /dev/urandom | base64; fi
}
awg31_gen_params() { # заполняет AWG31_* (JC JMIN JMAX S1-S4 H1-H4 I1 HPK CPA RKAT RT RJT KAT MHA MTU)
  local lo hi
  AWG31_JC="$(awg31_ri 3 6)"
  AWG31_JMIN="$(awg31_ri 40 89)"; AWG31_JMAX=$((AWG31_JMIN + $(awg31_ri 50 250)))
  AWG31_S1="$(awg31_ri 15 150)"; AWG31_S2="$(awg31_ri 15 150)"
  # S1+56 == S2 делает init/response одинаковыми по размеру — сдвигаем с
  # контролем границы (S2=150 не должен выталкиваться в 151)
  [ $((AWG31_S1 + 56)) -ne "$AWG31_S2" ] || { AWG31_S2=$((AWG31_S2 + 1)); [ "$AWG31_S2" -le 150 ] || AWG31_S2=$((AWG31_S2 - 2)); }
  AWG31_S3="$(awg31_ri 12 55)"; AWG31_S4="$(awg31_ri 12 27)"
  AWG31_H1=1; AWG31_H2=2; AWG31_H3=3; AWG31_H4=4
  AWG31_I1="<r $(awg31_ri 32 128)>"
  AWG31_HPK="$(awg31_hpk)"
  lo="$(awg31_ri 8 24)";  AWG31_CPA="${lo}-$((lo + $(awg31_ri 8 40)))"
  lo="$(awg31_ri 100 120)"; hi=$((lo + $(awg31_ri 10 40))); AWG31_RKAT="${lo}-${hi}"
  lo=$((hi + $(awg31_ri 30 60))); AWG31_RJT="${lo}-$((lo + $(awg31_ri 30 90)))"
  lo="$(awg31_ri 3 6)";  AWG31_RT="${lo}-$((lo + $(awg31_ri 1 4)))"
  lo="$(awg31_ri 8 12)"; AWG31_KAT="${lo}-$((lo + $(awg31_ri 2 8)))"
  lo="$(awg31_ri 15 25)"; AWG31_MHA="${lo}-$((lo + $(awg31_ri 5 25)))"
  AWG31_MTU=1280 # рекомендация Amnezia для self-hosted 3.1 (было 1376)
}

# Кэшированная проба «ядро панели умеет ПОЛНЫЙ набор 3.1». Гейт версии панели
# (>= 3.7) обязателен: старая панель МОЛЧА отбрасывает неизвестные ей поля —
# эмпирическая проба (inbound поднялся, UDP слушается) этого не отличает от
# честного применения 3.1. Проба дорогая (inbound + слушатель + удаление) —
# результат кэшируется в XKIT_AWG31_OK на время запуска.
proto_awg31_supported() {
  [ "${XKIT_AWG31_OK:-}" = "1" ] && return 0
  [ "${XKIT_AWG31_OK:-}" = "0" ] && return 1
  XKIT_AWG31_OK=0
  [ -n "${XKIT_XUI_VERSION:-}" ] && ! ver_ge "$XKIT_XUI_VERSION" 3.7 && return 1
  proto_core_supports amneziawg31 && XKIT_AWG31_OK=1
  [ "$XKIT_AWG31_OK" = "1" ]
}

proto_udp_free() { # $1 порт -> 0 = свободен
  ! ss -lunH "sport = :$1" 2>/dev/null | grep -q .
}

# ЭМПИРИЧЕСКАЯ ПРОБА: умеет ли ядро панели протокол.
# Создаём минимальный инбаунд на 127.0.0.1:случайный-UDP, ждём слушателя,
# удаляем. Только реальный запуск ядра — источник истины, не версия.
proto_core_supports() { # $1 hysteria|amneziawg, $2 file = проверить file-masquerade
  local proto="$1" port resp ib listening camo_mode="${2:-}" probe="xkit-probe-$(rand_hex 4)"
  if [ -z "${PANEL_PORT:-}" ]; then
    warn "проба '$proto': порт панели не определён (PANEL_PORT пуст) — проба невозможна"; return 1
  fi
  port="$(rand_free_port 23000 59000)" || { warn "проба '$proto': нет свободного TCP-порта для пробы"; return 1; }
  proto_udp_free "$port" || { warn "проба '$proto': UDP ${port} занят — проба отменена"; return 1; }
  local settings stream
  case "$proto" in
    hysteria)
      settings='{"version":2,"clients":[]}'
      if [ "$camo_mode" = "file" ]; then
        stream="$(jq -nc --arg d "${CAMO_DIR:-/var/www/camo}" '{network:"hysteria",security:"tls",tlsSettings:{alpn:["h3"]},hysteriaSettings:{version:2,masquerade:{type:"file",file:{dir:$d}}}}')"
      else
        stream='{"network":"hysteria","security":"tls","tlsSettings":{"alpn":["h3"]},"hysteriaSettings":{"version":2}}'
      fi ;;
    amneziawg)
      local priv pub
      read -r priv pub <<<"$(xray_wg_pair)" || return 1
      # v7.4.3: У ПРОБЫ ДОЛЖЕН БЫТЬ PEER. Сайдкар AWG (internal/amneziawgnet)
      # стартует только когда у инбаунда есть хотя бы один включённый клиент
      # с publicKey и allowedIPs (amneziawg.InstanceFromInbound: «no enabled
      # peer to serve — skips the sidecar entirely»). Проба с clients:[]
      # никогда не поднимала UDP-слушатель — вердикт «ядро НЕ умеет» был
      # ложным при живой поддержке AWG (живой лог 7.4.2).
      settings="$(jq -nc --arg probe "$probe" --arg pk "$priv" --arg pub "$pub" \
        '{server:{privateKey:$pk,publicKey:$pub,subnetIp:"10.8.9.0",subnetCidr:24,primaryDns:"1.1.1.1",secondaryDns:"8.8.8.8"},
          clients:[{email:$probe,enable:true,publicKey:$pub,allowedIPs:["10.8.9.2/32"]}]}')"
      stream='{}' ;;
    amneziawg31) # v7.4.2: ПОЛНОЕ ИМЯ ПРОТОКОЛА — «amneziawg» (набор 3.1 отличается
      # только ПОЛЯМИ настроек, отдельного протокола amneziawg31 в 3x-ui нет:
      # живой лог 7.4.1 — «панель отклонила протокол — request body failed
      # validation» при живой поддержке AWG в ядре 26.10.21). Проба «поняло ли
      # ядро поля 3.x» — по сохранённому headerProtectionKey судит установщик.
      local priv pub
      read -r priv pub <<<"$(xray_wg_pair)" || return 1
      awg31_gen_params
      settings="$(jq -nc --arg probe "$probe" --arg pk "$priv" --arg pub "$pub" \
        --argjson jc "$AWG31_JC" --argjson jmin "$AWG31_JMIN" --argjson jmax "$AWG31_JMAX" \
        --argjson s1 "$AWG31_S1" --argjson s2 "$AWG31_S2" --argjson s3 "$AWG31_S3" --argjson s4 "$AWG31_S4" \
        --arg h1 "$AWG31_H1" --arg h2 "$AWG31_H2" --arg h3 "$AWG31_H3" --arg h4 "$AWG31_H4" \
        --arg i1 "$AWG31_I1" --arg hpk "$AWG31_HPK" --arg cpa "$AWG31_CPA" \
        --arg rkat "$AWG31_RKAT" --arg rt "$AWG31_RT" --arg rjt "$AWG31_RJT" \
        --arg kat "$AWG31_KAT" --arg mha "$AWG31_MHA" --argjson mtu "$AWG31_MTU" \
        '{server:{privateKey:$pk,publicKey:$pub,subnetIp:"10.8.9.0",subnetCidr:24,mtu:$mtu,
          primaryDns:"1.1.1.1",secondaryDns:"8.8.8.8",jc:$jc,jmin:$jmin,jmax:$jmax,
          s1:$s1,s2:$s2,s3:$s3,s4:$s4,h1:$h1,h2:$h2,h3:$h3,h4:$h4,i1:$i1,
          headerProtectionKey:$hpk,contentPaddingAddition:$cpa,
          rekeyAfterTime:$rkat,rekeyTimeout:$rt,rejectAfterTime:$rjt,
          keepaliveTimeout:$kat,maxHandshakeAttempts:$mha,
          randomTrailers:false,disableCookies:false},
          clients:[{email:$probe,enable:true,publicKey:$pub,allowedIPs:["10.8.9.2/32"]}]}')"
      stream='{}' ;;
    *) return 1 ;;
  esac
  # v7.4.2: имя протокола в API всегда базовое (amneziawg/hysteria);
  # суффикс «31» — только наш внутренний маркер профиля настроек
  local pname="$proto"
  case "$proto" in amneziawg31) pname="amneziawg" ;; esac
  ib="$(jq -nc --arg probe "$probe" --argjson port "$port" --arg s "$settings" --arg st "$stream" '
    {up:0,down:0,total:0,remark:$probe,enable:true,expiryTime:0,listen:"127.0.0.1",
     port:$port,protocol:"'"$pname"'",settings:$s,streamSettings:$st,
     sniffing:"{\"enabled\":false}",allocate:"{\"strategy\":\"always\",\"refresh\":5,\"concurrency\":-1}",tag:$probe}')"
  # v7.4.1: отказ ПРИМЕНЕНИЯ пробы (пустой/не-JSON ответ = 401 bearer / 403 CSRF)
  # ≠ «ядро не умеет протокол». api_post уже повторил запрос с восстановленной
  # аутентификацией; если всё равно не JSON — честно говорим, что вердикт о
  # поддержке протокола недействителен (живой лог 7.4.0: «ядро НЕ умеет
  # amneziawg» при живом POST-канале панели).
  if ! resp="$(api_post add "$ib" 2>/dev/null)" || [ -z "$resp" ]; then
    warn "проба '$proto': панель не ответила на создание пробного инбаунда (401/403 middleware?) — вердикт о поддержке протокола не выносится"
    _proto_probe_cleanup; return 1
  fi
  if ! jq -e 'type=="object"' <<<"$resp" >/dev/null 2>&1; then
    warn "проба '$proto': не-JSON ответ панели — вердикт о поддержке протокола не выносится"
    _proto_probe_cleanup; return 1
  fi
  if ! jq -e '.success == true' <<<"$resp" >/dev/null 2>&1; then
    warn "проба '$proto': панель отклонила протокол — $(api_err_msg "$resp" | head -c 140)"
    _proto_probe_cleanup; return 1
  fi
  # v7.4.3: опрос слушателя вместо одного sleep 2. У AmneziaWG слушатель
  # поднимает САЙДКАР панели, а он реконсиличится job-ом с тактом 10 секунд
  # (3x-ui internal/web/job/amneziawg_job.go) — двух секунд всегда не хватало.
  local wait_max=6 step=3 tries=0
  case "$proto" in amneziawg|amneziawg31) wait_max=27 ;; esac
  listening=0
  while [ "$tries" -lt "$wait_max" ]; do
    sleep "$step"; tries=$((tries + step))
    listening="$(ss -lunpH "sport = :$port" 2>/dev/null | grep -c . || true)"
    [ "${listening:-0}" -gt 0 ] && break
  done
  _proto_probe_cleanup
  if [ "${listening:-0}" -eq 0 ]; then
    warn "проба '$proto': inbound принят панелью, но UDP-слушатель на ${port} не появился за ${wait_max}с —"
    warn "  сайдкар/ядро не поднял протокол (лог панели: journalctl -u x-ui | grep -iE 'amnez|awg|hysteria')"
    return 1
  fi
  return 0
}

_proto_probe_cleanup() { # удалить только текущую пробу, молча
  local pid
  pid="$(jq -r --arg t "${probe:-xkit-probe}" '[.[]|select(.tag==$t)][0].id // empty' <<<"$(api_list 2>/dev/null)" 2>/dev/null)"
  [ -n "$pid" ] && api_del_inbound "$pid" >/dev/null 2>&1 || true
  return 0
}

# String-fallback: визуально тот же camo, но CSS/SVG встроены, потому что
# string-masquerade не отдаёт /assets/*. Внутренние страницы в fallback отключены.
proto_panel_camo_content() {
  local d="${CAMO_DIR:-/var/www/camo}" html css svg
  [ -r "$d/index.html" ] || { camo_site_install 2>/dev/null || true; }
  [ -r "$d/index.html" ] || return 1
  # Совместимость с ручным одностраничным camo: если assets удалены, отдаём HTML.
  if [ ! -r "$d/assets/style.css" ] || [ ! -r "$d/assets/mark.svg" ]; then cat "$d/index.html"; return 0; fi
  html="$(cat "$d/index.html")"; css="$(cat "$d/assets/style.css")"; svg="$(cat "$d/assets/mark.svg")"
  html="${html/<link rel=\"stylesheet\" href=\"\/assets\/style.css\">/<style>${css}<\/style>}"
  html="${html/<link rel=\"icon\" href=\"\/assets\/mark.svg\">/}"
  html="${html/<img class=\"mark\" src=\"\/assets\/mark.svg\" alt=\"\">/${svg}}"
  html="${html//href=\"\/about.html\"/href=\"#\"}"
  html="${html//href=\"\/contact.html\"/href=\"#\"}"
  printf '%s' "$html"
}

#--- инбаунды ------------------------------------------------------------------
# Hysteria2: protocol=hysteria, settings {version:2, clients:[{... auth}]},
# stream {network:hysteria, security:tls, hysteriaSettings:{version:2, masquerade}}
proto_panel_hysteria_ib() { # $1 порт, $2 auth, $3 clientJSON -> полный JSON инбаунда
  local port="$1" auth="$2" cl="$3" page="" stream
  if [ "${PANEL_HY2_CAMO_MODE:-string}" = "file" ]; then
    stream="$(jq -nc --arg d "${CAMO_DIR:-/var/www/camo}" '{network:"hysteria",security:"tls",tlsSettings:{alpn:["h3"]},hysteriaSettings:{version:2,masquerade:{type:"file",file:{dir:$d}}}}')"
  else
    page="$(proto_panel_camo_content)" || return 1
    stream="$(jq -nc --argjson t '{"alpn":["h3"]}' --argjson h '{"content-type":"text/html; charset=utf-8"}' --arg page "$page" '
      {network:"hysteria",security:"tls",tlsSettings:$t,
       hysteriaSettings:{version:2,masquerade:{type:"string",content:$page,statusCode:200,headers:$h}}}')"
  fi
  local settings
  settings="$(jq -nc --arg a "$auth" --argjson c "$cl" '{version:2, clients:(if $c == {} then [] else [$c + {auth:$a}] end)}')"
  jq -nc --argjson port "$port" --arg remark "hysteria2-${port}" --arg s "$settings" --arg st "$stream" '
    {up:0,down:0,total:0,remark:$remark,enable:true,expiryTime:0,listen:"",
     port:$port,protocol:"hysteria",settings:$s,streamSettings:$st,
     sniffing:"{\"enabled\":false}",allocate:"{\"strategy\":\"always\",\"refresh\":5,\"concurrency\":-1}",tag:"inbound-'$port'"}'
}

# AmneziaWG-инбаунд, два профиля (v7.2.7):
#  * «31» — полный набор AWG 3.1: HeaderProtectionKey + S1-S4 (>= 12) +
#    H1-H4 = 1/2/3/4 (режим совместимости HP) + I1 + паддинг/тайминг-диапазоны.
#    Клиенты: AmneziaVPN >= 5.0.1.5, AmneziaWG >= 3.1, WG Tunnel >= 5.6,
#    свежий Mihomo (amnezia-wg-option version: 3).
#  * «classic» — Jc/Jmin/Jmax/S1/S2/H1-H4 без 3.x-полей: старые клиенты,
#    роутеры Keenetic, Mihomo без amnezia-wg-option. Схема дополнена
#    обязательными полями wire-JSON 3x-ui (s3/s4/mtu/флаги) — раньше их не
#    было, панель показывала нули, а клиентский конфиг выходил «маленький».
# Поля — internal/amneziawg/types.go (ServerSettings): h1-h4 СТРОКАМИ,
# s3/s4/mtu числами, randomTrailers/disableCookies обязательно bool.
proto_panel_awg_ib() { # $1 порт, $2 clientJSON, $3 профиль: 31|classic
  local port="$1" cl="$2" profile="${3:-31}" priv pub settings
  read -r priv pub <<<"$(xray_wg_pair)" || return 1
  if [ "$profile" = "31" ]; then
    awg31_gen_params
    settings="$(jq -nc --arg pk "$priv" --arg pub "$pub" \
      --argjson jc "$AWG31_JC" --argjson jmin "$AWG31_JMIN" --argjson jmax "$AWG31_JMAX" \
      --argjson s1 "$AWG31_S1" --argjson s2 "$AWG31_S2" --argjson s3 "$AWG31_S3" --argjson s4 "$AWG31_S4" \
      --arg h1 "$AWG31_H1" --arg h2 "$AWG31_H2" --arg h3 "$AWG31_H3" --arg h4 "$AWG31_H4" \
      --arg i1 "$AWG31_I1" --arg hpk "$AWG31_HPK" --arg cpa "$AWG31_CPA" \
      --arg rkat "$AWG31_RKAT" --arg rt "$AWG31_RT" --arg rjt "$AWG31_RJT" \
      --arg kat "$AWG31_KAT" --arg mha "$AWG31_MHA" --argjson mtu "$AWG31_MTU" \
      --argjson c "$cl" '{
      server:{privateKey:$pk, publicKey:$pub, subnetIp:"10.8.1.0", subnetCidr:24,
              mtu:$mtu, primaryDns:"1.1.1.1", secondaryDns:"8.8.8.8",
              jc:$jc, jmin:$jmin, jmax:$jmax, s1:$s1, s2:$s2, s3:$s3, s4:$s4,
              h1:$h1, h2:$h2, h3:$h3, h4:$h4, i1:$i1,
              headerProtectionKey:$hpk, contentPaddingAddition:$cpa,
              rekeyAfterTime:$rkat, rekeyTimeout:$rt, rejectAfterTime:$rjt,
              keepaliveTimeout:$kat, maxHandshakeAttempts:$mha,
              randomTrailers:false, disableCookies:false},
      clients:(if $c == {} then [] else [$c] end)}')"
  else
    local jc jmin jmax s1 s2 h1 h2 h3 h4
    jc=$((RANDOM % 4 + 3)); jmin=$((RANDOM % 50 + 40)); jmax=$((jmin + RANDOM % 200 + 50))
    s1=$((RANDOM % 136 + 15)); s2=$((RANDOM % 136 + 15))
    [ $((s1 + 56)) -ne "$s2" ] || { s2=$((s2 + 1)); [ "$s2" -le 150 ] || s2=$((s2 - 2)); }
    h1=$((RANDOM * 32768 + RANDOM)); h2=$((RANDOM * 32768 + RANDOM))
    h3=$((RANDOM * 32768 + RANDOM)); h4=$((RANDOM * 32768 + RANDOM))
    while [ "$h2" = "$h1" ]; do h2=$((RANDOM * 32768 + RANDOM)); done
    while [ "$h3" = "$h1" ] || [ "$h3" = "$h2" ]; do h3=$((RANDOM * 32768 + RANDOM)); done
    while [ "$h4" = "$h1" ] || [ "$h4" = "$h2" ] || [ "$h4" = "$h3" ]; do h4=$((RANDOM * 32768 + RANDOM)); done
    settings="$(jq -nc --arg pk "$priv" --arg pub "$pub" \
      --argjson jc "$jc" --argjson jmin "$jmin" --argjson jmax "$jmax" \
      --argjson s1 "$s1" --argjson s2 "$s2" --argjson h1 "$h1" --argjson h2 "$h2" \
      --argjson h3 "$h3" --argjson h4 "$h4" --argjson c "$cl" '{
      server:{privateKey:$pk, publicKey:$pub, subnetIp:"10.8.1.0", subnetCidr:24,
              mtu:1280, primaryDns:"1.1.1.1", secondaryDns:"8.8.8.8",
              jc:$jc, jmin:$jmin, jmax:$jmax, s1:$s1, s2:$s2, s3:0, s4:0,
              h1:($h1|tostring), h2:($h2|tostring), h3:($h3|tostring), h4:($h4|tostring),
              randomTrailers:false, disableCookies:false},
      clients:(if $c == {} then [] else [$c] end)}')"
  fi
  jq -nc --argjson port "$port" --arg remark "amneziawg-${port}" --arg s "$settings" '
    {up:0,down:0,total:0,remark:$remark,enable:true,expiryTime:0,listen:"",
     port:$port,protocol:"amneziawg",settings:$s,streamSettings:"{}",
     sniffing:"{\"enabled\":false}",allocate:"{\"strategy\":\"always\",\"refresh\":5,\"concurrency\":-1}",tag:"inbound-'$port'"}'
}

#--- клиенты (payload по протоколу; fresh-секрет на каждый инбаунд) ------------
# Результат — в глобальной PAYLOAD (JSON клиента); EXTRA_LINK/EXTRA_NOTE —
# подсказки. Возвращать payload через stdout нельзя: вызов в $(...) — субшелл,
# и установленные им глобальные EXTRA_* терялись бы (нашёл test_v600).
client_payload_for() { # $1 ib, $2 email, $3 subid, $4 totalGB, $5 expiry
  local ib="$1" email="$2" subid="$3" gb="${4:-0}" exp="${5:-0}" cj=""
  local proto uuid auth priv pub ipn used ips
  proto="$(jq -r '.protocol' <<<"$ib")"
  EXTRA_LINK=""; EXTRA_NOTE=""; PAYLOAD=""
  case "$proto" in
    vless)
      uuid="$(new_uuid)"
      local flow="" sec
      sec="$(jq -r '.streamSettings|if type=="string" then (fromjson? // {}) else . end | .security // "none"' <<<"$ib")"
      local vnet
      vnet="$(jq -r '.streamSettings|if type=="string" then (fromjson? // {}) else . end | .network // "tcp"' <<<"$ib")"
      # Vision предназначен для RAW/TCP; XHTTP работает без flow.
      { [ "$vnet" = "tcp" ] || [ "$vnet" = "raw" ]; } && [ "$sec" = "reality" ] && flow="xtls-rprx-vision"
      cj="$(jq -nc --arg id "$uuid" --arg email "$email" --arg sub "$subid" \
        --argjson total "$gb" --argjson exp "$exp" --arg flow "$flow" '
        {id:$id, flow:$flow, email:$email, limitIp:0, totalGB:$total,
         expiryTime:$exp, enable:true, tgId:"", subId:$sub, reset:0}')"
      PAYLOAD="$cj" ;;
    vmess)
      uuid="$(new_uuid)"
      cj="$(jq -nc --arg id "$uuid" --arg email "$email" --arg sub "$subid" \
        --argjson total "$gb" --argjson exp "$exp" '
        {id:$id, email:$email, limitIp:0, totalGB:$total, security:"auto", alterId:0,
         expiryTime:$exp, enable:true, tgId:"", subId:$sub, reset:0}')"
      PAYLOAD="$cj" ;;
    trojan)
      uuid="$(new_uuid)"
      cj="$(jq -nc --arg id "$uuid" --arg pass "$uuid" --arg email "$email" --arg sub "$subid" \
        --argjson total "$gb" --argjson exp "$exp" '
        {id:$id, password:$pass, flow:"", email:$email, limitIp:0, totalGB:$total,
         expiryTime:$exp, enable:true, tgId:"", subId:$sub, reset:0}')"
      PAYLOAD="$cj" ;;
    shadowsocks)
      uuid="$(new_uuid)"
      cj="$(jq -nc --arg id "$uuid" --arg pass "$uuid" --arg email "$email" --arg sub "$subid" \
        --argjson total "$gb" --argjson exp "$exp" '
        {id:$id, method:"", password:$pass, email:$email, limitIp:0, totalGB:$total,
         expiryTime:$exp, enable:true, tgId:"", subId:$sub, reset:0}')"
      PAYLOAD="$cj" ;;
    hysteria)
      auth="$(rand_str 24)"
      cj="$(jq -nc --arg a "$auth" --arg email "$email" --arg sub "$subid" \
        --argjson total "$gb" --argjson exp "$exp" '
        {email:$email, limitIp:0, totalGB:$total, expiryTime:$exp, enable:true,
         tgId:"", subId:$sub, comment:"", reset:0, auth:$a}')"
      local hport hsni q
      hport="$(jq -r '.port' <<<"$ib")"
      if [ "${XKIT_CERT_MODE:-}" = "4" ]; then
        local pin; pin="$(clash_cert_pin)"
        q="insecure=1"; [ -n "$pin" ] && q="pinSHA256=$(enc_uri "$pin")"
      else
        q="sni=$(enc_uri "${XKIT_HOST:-}")"
      fi
      EXTRA_LINK="$(printf 'hysteria2://%s@%s:%s?%s&alpn=h3#%s' "$(enc_uri "$auth")" "${XKIT_HOST:-}" "$hport" "$q" "$(enc_uri "$email")")"
      PAYLOAD="$cj" ;;
    amneziawg)
      read -r priv pub <<<"$(xray_wg_pair)" || return 1
      ipn="$(proto_panel_awg_next_ip "$ib")" || return 1
      cj="$(jq -nc --arg pk "$priv" --arg pub "$pub" --arg ip "10.8.1.${ipn}/32" \
        --arg email "$email" --arg sub "$subid" --argjson total "$gb" --argjson exp "$exp" '
        {email:$email, limitIp:0, totalGB:$total, expiryTime:$exp, enable:true,
         tgId:"", subId:$sub, comment:"", reset:0, privateKey:$pk, publicKey:$pub, allowedIPs:[$ip]}')"
      # v7.2.7: подсказка зависит от профиля инбаунда (3.1 требует свежих клиентов)
      if jq -e '(.settings|if type=="string" then fromjson else . end|.server.headerProtectionKey // "")|length>0' <<<"$ib" >/dev/null 2>&1; then
        EXTRA_NOTE="AmneziaWG 3.1 (Header Protection): конфиг в подписке (vpn:// рендерит панель); нужны клиенты AmneziaVPN >= 5.0.1.5 / AmneziaWG >= 3.1 / WG Tunnel >= 5.6 / свежий Mihomo (amnezia-wg-option version: 3) — старые конфиг отвергнут"
      else
        EXTRA_NOTE="AmneziaWG: конфиг клиента появится в подписке (vpn:// рендерит панель) — приложения AmneziaVPN/Mihomo"
      fi
      PAYLOAD="$cj" ;;
    *) return 1 ;;
  esac
}

proto_panel_awg_next_ip() { # $1 inbound amneziawg -> свободный хост-номер (>=2)
  local used n=2
  used="$(jq -r '.settings|if type=="string" then (fromjson? // {}) else . end
          | .clients[]? | .allowedIPs[]? | split("/")[0] | split(".")[-1]' <<<"$1" 2>/dev/null)"
  while grep -qx "$n" <<<"$used"; do n=$((n+1)); [ "$n" -le 254 ] || { err "Пул 10.8.1.0/24 заполнен"; return 1; }; done
  printf '%s' "$n"
}

#--- установка/удаление панельного режима --------------------------------------
_proto_panel_rollback_created() { # $1 hp (или пусто), $2 ap (или пусто)
  local proto port list id
  for proto in hysteria amneziawg; do
    if [ "$proto" = "hysteria" ]; then port="${1:-}"; else port="${2:-}"; fi
    [ -n "$port" ] || continue
    list="$(api_list 2>/dev/null)" || continue
    id="$(jq -r --arg p "$proto" --arg r "${proto/hysteria/hysteria2}-${port}" \
      '[.[]|select(.protocol==$p and .remark==$r)][0].id // empty' <<<"$list")"
    [ -z "$id" ] || api_del_inbound "$id" >/dev/null 2>&1 || true
    if [ "$proto" = "hysteria" ]; then xkit_fw_remove hysteria2 "$port" udp >/dev/null 2>&1 || true
    else xkit_fw_remove awg "$port" udp >/dev/null 2>&1 || true; fi
  done
}

proto_panel_install() { # $1 режим: all (по умолчанию) | awg | hy2 — v7.2.7: панельный AWG включается и отдельно
  local mode="${1:-all}"
  require_root; load_xkit_env || die "Сначала установка XKIT"; kit_session || return 1
  local have_hy have_awg
  have_hy="$(jq -r '[.[]|select(.protocol=="hysteria")]|length' <<<"$INBOUNDS")"
  have_awg="$(jq -r '[.[]|select(.protocol=="amneziawg")]|length' <<<"$INBOUNDS")"
  case "$mode" in
    awg) [ "${have_awg:-0}" -gt 0 ] && { warn "Панельный AmneziaWG уже включён (${have_awg})"; return 0; } ;;
    hy2) [ "${have_hy:-0}" -gt 0 ] && { warn "Панельный Hysteria 2 уже включён (${have_hy})"; return 0; } ;;
    all) if [ "${have_hy:-0}" -gt 0 ] || [ "${have_awg:-0}" -gt 0 ]; then
           warn "Панельный режим уже включён (hysteria: ${have_hy:-0}, amneziawg: ${have_awg:-0})"
           return 0
         fi ;;
    *) err "Режим панельного режима: all|awg|hy2 (получено: $mode)"; return 1 ;;
  esac
  echo ""
  log "Проба ядра панели (эмпирически, через API):"
  local ok_hy=1 ok_awg=1 awg31=0
  if [ "$mode" != "awg" ]; then
    if proto_core_supports hysteria; then
      ok "ядро умеет hysteria2"; PANEL_HY2_CAMO_MODE="string"
      camo_site_install || { err 'Не удалось подготовить локальный camo'; return 1; }
      if proto_core_supports hysteria file; then PANEL_HY2_CAMO_MODE="file"; ok 'file-masquerade поддержан: общий /var/www/camo';
      else warn 'file-masquerade не поддержан: использую самодостаточный string-camo'; fi
    else ok_hy=0; warn "ядро НЕ умеет hysteria2 — панельный режим Hysteria 2 недоступен"; fi
  else ok_hy=0; fi
  if [ "$mode" != "hy2" ]; then
    if proto_awg31_supported; then
      ok "ядро умеет amneziawg с полным набором 3.1 (Header Protection)"; awg31=1
    elif proto_core_supports amneziawg; then
      ok "ядро умеет amneziawg (классический набор параметров)"
    else ok_awg=0; warn "ядро НЕ умеет amneziawg — панельный режим AmneziaWG недоступен"; fi
  else ok_awg=0; fi
  if [ "$ok_hy" != "1" ] && [ "$ok_awg" != "1" ]; then
    err "Ни один запрошенный протокол ядром не поддерживается — оставайтесь на отдельных службах"; return 1
  fi

  # Сначала создаём и проверяем панельные inbound, и только потом удаляем standalone.
  local migrate_hy=0 migrate_awg=0
  if [ "$mode" != "awg" ] && [ -f "$XKIT_HY2_CONF" ] && [ "$ok_hy" = "1" ]; then
    warn "Hysteria 2 стоит отдельной службой — после успешного создания панельного inbound она будет удалена."
    if confirm "Перейти на панельный Hysteria2? [y/N]"; then migrate_hy=1
    else log "Панельный Hysteria2 не создаю"; ok_hy=0; fi
  fi
  if [ "$mode" != "hy2" ] && [ -f "$XKIT_AWG_CONF" ] && [ "$ok_awg" = "1" ]; then
    warn "AmneziaWG стоит отдельной службой. Клиентские конфиги после переноса надо будет раздать заново."
    if confirm "Перейти на панельный AmneziaWG? [y/N]"; then migrate_awg=1
    else log "Панельный AmneziaWG не создаю"; ok_awg=0; fi
  fi
  [ "$ok_hy" = "1" ] || [ "$ok_awg" = "1" ] || { err "Панельный inbound не создаётся: оба протокола отклонены"; return 1; }

  # v7.2.7: профиль обфускации AmneziaWG — «31» (Header Protection) или «classic»
  local awg_profile="classic"
  if [ "$ok_awg" = "1" ]; then
    if [ "$awg31" = "1" ]; then
      echo ""
      echo "Профиль обфускации AmneziaWG:"
      echo " 1) AWG 3.1 — Header Protection + паддинги S1-S4 + тайминг-джиттер (рекомендуется;"
      echo "    клиенты: AmneziaVPN >= 5.0.1.5, AmneziaWG >= 3.1, WG Tunnel >= 5.6, свежий Mihomo)"
      echo " 2) Классический — Jc/Jmin/Jmax/S1/S2/H1-H4 (старые клиенты, роутеры Keenetic,"
      echo "    Mihomo без amnezia-wg-option)"
      local pc; read -r -p 'Профиль [1]: ' pc || return 1
      case "${pc:-1}" in
        1) awg_profile="31" ;;
        2) awg_profile="classic" ;;
        *) err 'Нет такого профиля'; return 1 ;;
      esac
    else
      warn "Ядро не приняло набор 3.1 — инбаунд будет с классическим профилем"
    fi
  fi

  proto_port_profile_pick || return 1
  local created=0 hp="" ap=""
  if [ "$ok_hy" = "1" ]; then
    local hp; hp="$PROTO_HY2_PORT_DEFAULT"
    read -r -p "UDP-порт Hysteria 2 (панельный) [${hp}]: " a; hp="${a:-$hp}"
    is_port "$hp" && proto_udp_free "$hp" || { err "Порт $hp занят/некорректен"; return 1; }
    local auth cl ib
    auth="$(rand_str 24)"
    cl='{}' 
    ib="$(proto_panel_hysteria_ib "$hp" "$auth" "$cl")" || return 1
    api_add_inbound "$ib" || return 1
    xkit_fw_add hysteria2 "$hp" udp || { _proto_panel_rollback_created "$hp" ""; err 'Firewall Hysteria 2 не настроен — inbound откачен'; return 1; }
    PANEL_HY2_PORT="$hp"
    created=$((created+1))
    ok "Hysteria2 инбаунд панели создан: UDP ${hp}"
  fi
  if [ "$ok_awg" = "1" ]; then
    local ap; ap="$PROTO_AWG_PORT_DEFAULT"
    read -r -p "UDP-порт AmneziaWG (панельный) [${ap}]: " a; ap="${a:-$ap}"
    is_port "$ap" && proto_udp_free "$ap" || { err "Порт $ap занят/некорректен"; _proto_panel_rollback_created "$hp" ""; return 1; }
    local wpriv wpub cl2 ib2
    read -r wpriv wpub <<<"$(xray_wg_pair)"
    [ -n "$wpriv" ] && [ -n "$wpub" ] || { _proto_panel_rollback_created "$hp" ""; return 1; }
    cl2='{}' 
    ib2="$(proto_panel_awg_ib "$ap" "$cl2" "$awg_profile")" || { _proto_panel_rollback_created "$hp" ""; return 1; }
    api_add_inbound "$ib2" || { _proto_panel_rollback_created "$hp" ""; return 1; }
    # (v7.2.7) контрольная сверка: панель СОХРАНИЛА параметры 3.1 — старая
    # панель могла молча отбросить неизвестные поля, версия-гейт не панацея.
    # Не сохранила — пересоздаём инбаунд классическим профилем.
    if [ "$awg_profile" = "31" ]; then
      local rb bad_id
      rb="$(jq -r --arg t "inbound-${ap}" '[.[]|select(.tag==$t)][0].settings // empty' <<<"$(api_list 2>/dev/null)" 2>/dev/null)"
      if ! jq -e '(.|if type=="string" then fromjson else . end|.server.headerProtectionKey // "")|length>0' <<<"${rb:-}" >/dev/null 2>&1; then
        warn "Панель не сохранила HeaderProtectionKey — пересоздаю инбаунд классическим профилем"
        bad_id="$(jq -r --arg t "inbound-${ap}" '[.[]|select(.tag==$t)][0].id // empty' <<<"$(api_list 2>/dev/null)" 2>/dev/null)"
        [ -z "$bad_id" ] || api_del_inbound "$bad_id" >/dev/null 2>&1 || true
        xkit_fw_remove awg "$ap" udp >/dev/null 2>&1 || true
        awg_profile="classic"
        ib2="$(proto_panel_awg_ib "$ap" "$cl2" "classic")" || { _proto_panel_rollback_created "$hp" ""; return 1; }
        api_add_inbound "$ib2" || { _proto_panel_rollback_created "$hp" ""; return 1; }
      else
        ok "Header Protection подтверждён в сохранённых настройках инбаунда"
      fi
    fi
    xkit_fw_add awg "$ap" udp || { _proto_panel_rollback_created "$hp" "$ap"; err 'Firewall AmneziaWG не настроен — созданные inbound откачены'; return 1; }
    PANEL_AWG_PORT="$ap"; PANEL_AWG_PROFILE="$awg_profile"
    created=$((created+1))
    if [ "$awg_profile" = "31" ]; then
      ok "AmneziaWG инбаунд панели создан: UDP ${ap}, профиль 3.1 (Header Protection)"
    else
      ok "AmneziaWG инбаунд панели создан: UDP ${ap}, классический профиль"
    fi
  fi
  [ "$created" -gt 0 ] || { warn "Ничего не создано"; return 1; }
  [ -z "$hp" ] || proto_hy2_camo_check "$hp" || warn 'Masquerade требует ручной проверки; локальный probe не гарантирует обход DPI'
  # Точка невозврата для миграции — только после успешного создания новых inbound.
  if [ "$migrate_hy" = "1" ]; then
    systemctl disable --now xkit-hysteria2 >/dev/null 2>&1 || true
    rm -f "$XKIT_HY2_UNIT" "$XKIT_HY2_CONF"; systemctl daemon-reload >/dev/null 2>&1 || true
    [ -z "${HY2_PORT:-}" ] || xkit_fw_remove hysteria2 "$HY2_PORT" udp >/dev/null 2>&1 || true
    HY2_PORT=""; HY2_AUTH=""; HY2_OBFS=""
    ok "Отдельная служба Hysteria 2 удалена после создания панельного inbound"
  fi
  if [ "$migrate_awg" = "1" ]; then
    systemctl disable --now awg-quick@awg0 >/dev/null 2>&1 || true
    xkit_awg_route_remove "${AWG_DEV:-}" >/dev/null 2>&1 || true
    [ -z "${AWG_PORT:-}" ] || xkit_fw_remove awg "$AWG_PORT" udp >/dev/null 2>&1 || true
    rm -f "$XKIT_AWG_CONF" "$XKIT_AWG_SYSCTL"
    AWG_PORT=""; AWG_SERVER_PUB=""; AWG_DEV=""
    ok "Отдельная служба AmneziaWG удалена после создания панельного inbound"
  fi
  PROTO_MODE="panel"; proto_state_save || warn "Состояние панельного режима не сохранено в ${XKIT_PROTOCOLS_ENV}"
  echo ""
  ok "Панельный режим включён. Пользователь на ВСЕ протоколы сразу:  xkit client all"
  sub_regen_quiet || true
  return 0
}

proto_panel_uninstall() {
  require_root; load_xkit_env || die "Сначала установка XKIT"; kit_session || return 1
  local ids id ports="" port
  confirm "Удалить панельные инбаунды Hysteria2/AmneziaWG? (пользователи в них будут удалены)" || return 0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    port="$(jq -r --argjson i "$id" '[.[]|select(.id==$i)][0].port // empty' <<<"$INBOUNDS")"
    proto="$(jq -r --argjson i "$id" '[.[]|select(.id==$i)][0].protocol // empty' <<<"$INBOUNDS")"
    if api_del_inbound "$id"; then
      ok "Инбаунд #$id (${proto:-?}) удалён"
      # (v7.2.7) fw-правило снимается по ПРОТОКОЛУ инбаунда: раньше с каждого
      # удаляемого инбаунда снимали и hysteria2-, и awg-правило одного порта
      case "${proto:-}" in
        hysteria)  [ -n "$port" ] && xkit_fw_remove "hysteria2" "$port" udp >/dev/null 2>&1 ;;
        amneziawg) [ -n "$port" ] && xkit_fw_remove "awg" "$port" udp >/dev/null 2>&1 ;;
      esac
    else
      warn "Инбаунд #$id не удалён — проверьте панель"
    fi
  done < <(jq -r '.[]|select((.protocol=="hysteria" and ((.remark//"")|test("^hysteria2-[0-9]+$"))) or (.protocol=="amneziawg" and ((.remark//"")|test("^amneziawg-[0-9]+$"))))|.id' <<<"$INBOUNDS")
  PROTO_MODE=""; PANEL_HY2_PORT=""; PANEL_AWG_PORT=""; PANEL_AWG_PROFILE=""; proto_state_save >/dev/null 2>&1 || true
  sub_regen_quiet || true
  return 0
}

protocol_remove() {
  load_xkit_env || die "Сначала установка XKIT"; kit_session || return 1
  routes_load; list_inbounds_menu || return 1
  local ib="$PICK_IB" id proto port remark clients
  id="$(jq -r '.id' <<<"$ib")"; proto="$(jq -r '.protocol' <<<"$ib")"
  port="$(jq -r '.port' <<<"$ib")"; remark="$(jq -r '.remark // ""' <<<"$ib")"
  clients="$(jq -r '[.settings|if type=="string" then fromjson else . end|.clients[]?]|length' <<<"$ib")"
  confirm "Удалить inbound #$id ($proto, порт $port) и его пользователей ($clients)? Остальные протоколы не изменятся. [y/N] " n || { warn "Отменено"; return 0; }
  api_del_inbound "$id" || return 1
  routes_del "$id"
  case "$proto:$remark" in
    hysteria:hysteria2-[0-9]*) xkit_fw_remove hysteria2 "$port" udp || warn "Проверьте UDP-правило $port" ;;
    amneziawg:amneziawg-[0-9]*) xkit_fw_remove awg "$port" udp || warn "Проверьте UDP-правило $port" ;;
  esac
  regen_conf_and_apply || { err "Inbound удалён, но nginx не обновлён — выполните xkit route --yes"; return 1; }
  sub_regen_quiet || { warn "Inbound удалён; подписки обновите командой xkit sub"; return 1; }
  ok "Протокол #$id удалён; остальные inbound, пользователи и маршруты не затронуты"
}

proto_panel_status() {
  load_xkit_env 2>/dev/null || true
  proto_state_load 2>/dev/null || true
  echo "Режим протоколов: ${PROTO_MODE:-standalone}"
  [ -n "${PANEL_HY2_PORT:-}" ] && echo "  Hysteria2 (панель): UDP ${PANEL_HY2_PORT}, camo=${PANEL_HY2_CAMO_MODE:-string}"
  [ -n "${PANEL_AWG_PORT:-}" ] && echo "  AmneziaWG (панель): UDP ${PANEL_AWG_PORT}, профиль: $([ "${PANEL_AWG_PROFILE:-}" = "31" ] && echo '3.1 (Header Protection)' || echo 'классический')"
  [ -f "$XKIT_HY2_CONF" ] && echo "  Hysteria2 (служба): UDP ${HY2_PORT:-?}"
  [ -f "$XKIT_AWG_CONF" ] && echo "  AmneziaWG (служба): UDP ${AWG_PORT:-?}"
  return 0
}

proto_panel_menu() {
  while :; do
    echo ""
    proto_panel_status
    echo '1) Включить панельный режим (Hysteria2 + AmneziaWG как инбаунды панели)'
    echo '2) Выключить панельный режим (удалить панельные инбаунды)'
    echo '3) Пользователь во ВСЕ протоколы (xkit client all)'
    echo '0) Назад'
    read -r -p 'Панельный режим: ' c || return
    case "$c" in
      1) proto_panel_install ;;
      2) proto_panel_uninstall ;;
      3) client_add_all ;;
      0) return ;; *) warn 'Нет такого пункта' ;;
    esac
  done
}

#================= v6.1.0: ВЕРСИИ 3X-UI/XRAY И САЙТ-ПРИКРЫТИЕ ================
# Манифест — фильтр известных связок, а НЕ доказательство совместимости.
# Окончательное решение принимают локальные binary/config/service/API probes.
XKIT_VERSION_STATE="${XKIT_DIR}/versions.env"
XKIT_VERSION_BACKUPS="${BACKUP_DIR}/versions"
XKIT_CAMO_STATE="${XKIT_DIR}/camo.env"
# v7.2.1: + связка 3.11.0 + 26.10.21 — именно её бандлит установщик 3x-ui
# v3.11.0, т.е. это ДЕФОЛТНЫЙ результат стандартной установки; раньше она
# честно показывалась как unlisted сразу после чистой установки.
XKIT_VERSION_MANIFEST='
[
 {"xui":"3.11.0","xray":"26.10.31","status":"candidate"},
 {"xui":"3.11.0","xray":"26.10.21","status":"candidate"},
 {"xui":"3.11.0","xray":"26.6.27","status":"candidate"}
]'

versions_manifest() {
  local f="${XKIT_VERSION_MANIFEST_FILE:-}"
  if [ -n "$f" ]; then
    [ -f "$f" ] || { err "Манифест не найден: $f"; return 1; }
    local owner; owner="$(stat -Lc '%u' "$f" 2>/dev/null)"
    { [ "$owner" = 0 ] || [ "$owner" = "$(id -u)" ]; } || { err "Владелец манифеста не доверен"; return 1; }
    [ "$(stat -Lc '%a' "$f" 2>/dev/null)" = "600" ] || [ "$(stat -Lc '%a' "$f" 2>/dev/null)" = "400" ] || {
      err "Манифест должен быть доступен на запись только владельцу (0600/0400)"; return 1;
    }
    jq -e 'type=="array" and all(.[]; (.xui|test("^[0-9]+(\\.[0-9]+)+$")) and (.xray|test("^[0-9]+(\\.[0-9]+)+$")))' "$f" >/dev/null || {
      err "Некорректный манифест версий"; return 1;
    }
    cat "$f"
  else
    jq -e . <<<"$XKIT_VERSION_MANIFEST" >/dev/null || return 1
    printf '%s\n' "$XKIT_VERSION_MANIFEST"
  fi
}

version_norm() { local v="${1#v}"; [[ "$v" =~ ^[0-9]+(\.[0-9]+)+$ ]] || return 1; printf '%s' "$v"; }
version_arch() {
  case "$(uname -m)" in
    x86_64) V_XUI=amd64; V_XRAY=64 ;;
    aarch64|arm64) V_XUI=arm64; V_XRAY=arm64-v8a ;;
    *) err "Архитектура $(uname -m) не поддерживается"; return 1 ;;
  esac
}
version_xray_bin() {
  local b
  for b in /usr/local/x-ui/bin/xray-linux-*; do [ -x "$b" ] && { printf '%s' "$b"; return 0; }; done
  return 1
}
version_xui_current() {
  local s=""
  if [ -x /usr/local/x-ui/x-ui ]; then s="$(/usr/local/x-ui/x-ui -v 2>/dev/null || true)"; fi
  [ -n "$s" ] || s="$(x-ui version 2>/dev/null || true)"
  grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$s" | head -n1
}
version_xray_current() {
  local b; b="$(version_xray_bin)" || return 1
  "$b" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}
version_pair_status() { # xui xray -> candidate|unlisted
  local m; m="$(versions_manifest)" || return 1
  jq -r --arg x "$1" --arg y "$2" 'if any(.[]; .xui==$x and .xray==$y) then (.[]|select(.xui==$x and .xray==$y)|.status//"candidate") else "unlisted" end' <<<"$m" | head -n1
}
versions_state_load() { [ -r "$XKIT_VERSION_STATE" ] && . "$XKIT_VERSION_STATE" || true; }
versions_state_save() { # xui xray snapshot
  (
    umask 077
    local t; t="$(mktemp "${XKIT_VERSION_STATE}.new.XXXXXX")" || exit 1
    { printf 'XKIT_XUI_VERSION=%q\n' "$1"; printf 'XKIT_XRAY_VERSION=%q\n' "$2"; printf 'XKIT_VERSION_SNAPSHOT=%q\n' "$3"; } >"$t"
    mv "$t" "$XKIT_VERSION_STATE"
  )
}

version_snapshot() { # -> путь; останавливает панель только на короткое копирование БД
  require_root
  local d ts; ts="$(date +%Y%m%d-%H%M%S)"; d="${XKIT_VERSION_BACKUPS}/${ts}"
  mkdir -p "$d" || return 1; chmod 700 "$XKIT_VERSION_BACKUPS" "$d"
  systemctl stop x-ui 2>/dev/null || true
  local rc=0
  if [ -d /usr/local/x-ui ]; then cp -a /usr/local/x-ui "$d/x-ui" || rc=1; fi
  if [ -d /etc/x-ui ]; then cp -a /etc/x-ui "$d/etc-x-ui" || rc=1; fi
  systemctl start x-ui 2>/dev/null || true
  [ "$rc" -eq 0 ] || return 1
  [ -f /etc/systemd/system/x-ui.service ] && cp -a /etc/systemd/system/x-ui.service "$d/" || true
  [ -f /usr/bin/x-ui ] && cp -a /usr/bin/x-ui "$d/x-ui-cli" || true
  [ -f "$XUI_RESULT" ] && cp -a "$XUI_RESULT" "$d/install-result.env" || true
  printf '%s' "$d"
}
version_snapshot_restore() {
  local d="$1"
  [ -d "$d" ] || { err "Snapshot не найден: $d"; return 1; }
  systemctl stop x-ui 2>/dev/null || true
  if [ -d "$d/x-ui" ]; then mkdir -p /usr/local/x-ui; cp -a "$d/x-ui/." /usr/local/x-ui/ || return 1; fi
  if [ -d "$d/etc-x-ui" ]; then mkdir -p /etc/x-ui; cp -a "$d/etc-x-ui/." /etc/x-ui/ || return 1; fi
  [ -f "$d/x-ui.service" ] && cp -a "$d/x-ui.service" /etc/systemd/system/x-ui.service
  [ -f "$d/x-ui-cli" ] && cp -a "$d/x-ui-cli" /usr/bin/x-ui
  [ -f "$d/install-result.env" ] && cp -a "$d/install-result.env" "$XUI_RESULT"
  systemctl daemon-reload 2>/dev/null || true
  systemctl restart x-ui 2>/dev/null || true
}

version_download_verified() { # url sha-url output; SHA обязателен, без интерактивного bypass
  local url="$1" sumurl="$2" out="$3" sum got want
  sum="${out}.sha256"
  curl -fsSL --max-time 120 -o "$out" "$url" || { err "Не удалось скачать $url"; return 1; }
  curl -fsSL --max-time 30 -o "$sum" "$sumurl" || { err "Нет официальной SHA-256: $sumurl — установка запрещена"; return 1; }
  want="$(grep -oE '[0-9a-fA-F]{64}' "$sum" | head -n1 | tr 'A-F' 'a-f')"
  got="$(sha256sum "$out" | awk '{print $1}')"
  [ -n "$want" ] && [ "$want" = "$got" ] || { err "SHA-256 не совпал — установка запрещена"; return 1; }
  ok "SHA-256 проверен: $(basename "$url")"
}

version_extract_xui() { # archive destdir; без абсолютных путей, .. и ссылок
  python3 - "$1" "$2" <<'PY'
import sys,tarfile
p,d=sys.argv[1:]
with tarfile.open(p,'r:gz') as t:
    for m in t.getmembers():
        n=m.name
        if n.startswith('/') or '..' in n.split('/') or m.issym() or m.islnk() or m.isdev():
            raise SystemExit('unsafe tar member: '+n)
    t.extractall(d,filter='data')
PY
}

version_probes() { # expected-xray expected-xui
  local xb cfg; xb="$(version_xray_bin)" || { err "Xray binary не найден"; return 1; }
  "$xb" version >/dev/null 2>&1 || { err "Xray не запускается"; return 1; }
  local xv; xv="$(version_xray_current)"
  [ "$xv" = "$1" ] || { err "Xray version mismatch: ожидали $1, получили ${xv:-unknown}"; return 1; }
  cfg="/usr/local/x-ui/bin/config.json"
  if [ -s "$cfg" ]; then "$xb" run -test -config "$cfg" >/dev/null 2>&1 || { err "Xray отклонил config.json"; return 1; }; fi
  systemctl is-active --quiet x-ui || { err "Служба x-ui не активна"; return 1; }
  load_xkit_env >/dev/null 2>&1 || true
  if [ -n "${PANEL_PORT:-}" ]; then
    local code; code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${PANEL_PORT}${PANEL_WBP:-/}" || true)"
    case "$code" in 200|301|302|400|401|403|404) ;; *) err "Локальный API панели не отвечает"; return 1 ;; esac
  fi
  if [ -n "$2" ]; then
    local uv; uv="$(version_xui_current)"
    [ "$uv" = "$2" ] || { err "3X-UI version mismatch: ожидали $2, получили ${uv:-unknown}"; return 1; }
  fi
  return 0
}

# (7.4.0) Список релизов официального репозитория 3x-ui (GitHub API без токена;
# лимит 60 запросов/час на IP — при отказе остаётся ручной ввод тега).
xui_releases_list() { # [$1 = сколько тегов, по умолчанию 10] -> stdout: теги
  local n="${1:-10}"
  curl -fsSL --max-time 15 "https://api.github.com/repos/MHSanaei/3x-ui/releases?per_page=${n}" 2>/dev/null \
    | jq -r '.[].tag_name' 2>/dev/null | grep -E '^v[0-9]+(\.[0-9]+)+$' | head -n "$n"
}

versions_installer_select() {
  # Неинтерактивно: XKIT_3XUI_TAG=vX.Y.Z и XKIT_XRAY_VERSION=A.B.C.
  # Для выбранной вручную версии 3X-UI обязателен SHA-256 её install.sh.
  if [ -n "${XKIT_3XUI_TAG:-}" ] || [ -n "${XKIT_XRAY_VERSION:-}" ]; then
    log "Выбор версий задан окружением: 3X-UI ${XKIT_3XUI_TAG:-default}, Xray ${XKIT_XRAY_VERSION:-default}"
    return 0
  fi
  [ -t 0 ] || return 0
  local a u x rel
  echo "Версии 3X-UI/Xray:"
  echo "  1) Последняя официальная версия 3X-UI и входящий в неё Xray [Enter]"
  echo "  2) Выбрать версию из официального списка GitHub"
  echo "  3) Выбрать проверенное сочетание версий 3X-UI + Xray"
  read -r -p "Ваш выбор: " a || return 0
  a="${a:-1}"
  case "$a" in
    1) return 0 ;;
    2)
      # (7.4.0): «странный вариант v из манифеста» заменён явным выбором релиза
      # из официального репозитория: теги берутся LIVE у MHSanaei/3x-ui, SHA-256
      # install.sh выбранного тега на шаге установки показывается и требует
      # подтверждения (v7.2.2) — пин XKIT_XUI_SHA256 по-прежнему можно задать сразу.
      log "Запрашиваю релизы официального репозитория MHSanaei/3x-ui..."
      rel="$(xui_releases_list 10)"
      if [ -n "$rel" ]; then
        echo "Официальные релизы (новые сверху):"
        local i=1 t
        while IFS= read -r t; do printf '  %2d) %s\n' "$i" "$t"; i=$((i+1)); done <<<"$rel"
        read -r -p "Номер из списка или тег (Enter = последний): " u || return 1
        u="${u:-$(head -n1 <<<"$rel")}"
      else
        warn "Список релизов недоступен (GitHub API лимит/сеть) — введите тег вручную"
        read -r -p "Тег релиза (например v2.4.0): " u || return 1
      fi
      if [[ "$u" =~ ^[0-9]+$ ]]; then
        u="$(sed -n "${u}p" <<<"$rel" | tr -d '[:space:]')"
        [ -n "$u" ] || { err "Нет такого номера в списке"; return 1; }
      fi
      u="${u#v}"
      u="$(version_norm "$u")" || { err "'$u' не похож на тег релиза (пример: v2.4.0)"; return 1; }
      XKIT_3XUI_TAG="v$u"
      ok "Выбран релиз официального репозитория: ${XKIT_3XUI_TAG} (Xray — тот, что бандлит его install.sh)"
      [ -n "${XKIT_XUI_SHA256:-}" ] || \
        log "SHA-256 install.sh ${XKIT_3XUI_TAG} не закреплён — на шаге установки будет показан и потребует подтверждения"
      ;;
    3)
      versions_list || return 1
      read -r -p "Версия 3X-UI: " u || return 1
      read -r -p "Версия Xray (Enter = не менять): " x || return 1
      u="$(version_norm "$u")" || return 1
      XKIT_3XUI_TAG="v$u"
      if [ -n "$x" ]; then
        XKIT_XRAY_VERSION="$(version_norm "$x")" || return 1; XKIT_CORE_PIN="$XKIT_XRAY_VERSION"
        [ "$(version_pair_status "$u" "$XKIT_XRAY_VERSION")" != unlisted ] || { err "Связка отсутствует в манифесте — используйте её после тестирования через versions install --allow-unlisted"; return 1; }
      fi
      # v7.2.2 (UX): пин SHA-256 больше не тупик для интерактивного выбора —
      # на шаге установки он будет вычислен, показан и потребует подтверждения.
      # Закрепить сразу: XKIT_XUI_SHA256=<64 hex> (актуальное значение — check-upstream.sh).
      [ -n "${XKIT_XUI_SHA256:-}" ] || \
        log "SHA-256 install.sh ${XKIT_3XUI_TAG} не закреплён — на шаге установки будет показан и потребует подтверждения"
      ;;
    *) return 0 ;;
  esac
}
versions_list() {
  local m; m="$(versions_manifest)" || return 1
  printf '%-12s %-12s %s\n' '3X-UI' 'XRAY' 'СТАТУС'
  jq -r '.[]|[.xui,.xray,(.status//"candidate")]|@tsv' <<<"$m" | while IFS=$'\t' read -r x y s; do printf '%-12s %-12s %s\n' "$x" "$y" "$s"; done
  echo "candidate = допущен к локальным probes, а не гарантия совместимости"
}
versions_status() {
  local x u; x="$(version_xray_current || true)"; u="$(version_xui_current || true)"
  echo "3X-UI: ${u:-не установлен / версия неизвестна}"
  echo "Xray:  ${x:-не установлен / версия неизвестна}"
  if [ -n "$u" ] && [ -n "$x" ]; then echo "Связка: $(version_pair_status "$u" "$x")"; fi
  [ -r "$XKIT_VERSION_STATE" ] && { versions_state_load; echo "Последний snapshot: ${XKIT_VERSION_SNAPSHOT:-неизвестен}"; }
  return 0
}

versions_install() { # xui xray [--allow-unlisted] [--allow-downgrade]
  require_root
  local u x allow=0 down=0 snap work stage xb uv
  u="$(version_norm "${1:-}")" || { err "Использование: xkit versions install <3xui> <xray>"; return 1; }
  x="$(version_norm "${2:-}")" || { err "Некорректная версия Xray"; return 1; }
  shift 2 || true
  while [ $# -gt 0 ]; do case "$1" in --allow-unlisted) allow=1;; --allow-downgrade) down=1;; *) err "Неизвестный флаг: $1"; return 1;; esac; shift; done
  command -v x-ui >/dev/null 2>&1 || [ -x /usr/local/x-ui/x-ui ] || die "3X-UI не установлен: выбор связки доступен при установке"
  [ "$(version_pair_status "$u" "$x")" != "unlisted" ] || [ "$allow" = 1 ] || {
    err "Связки нет в манифесте. Сначала проверьте её; для осознанного эксперимента: --allow-unlisted"; return 1;
  }
  uv="$(version_xui_current || true)"
  if [ -n "$uv" ] && dpkg --compare-versions "$u" lt "$uv" && [ "$down" != 1 ]; then
    err "Downgrade 3X-UI $uv -> $u запрещён: схема БД может быть несовместима. --allow-downgrade только после внешнего бэкапа"; return 1
  fi
  if [ -f "$XUI_RESULT" ] && grep -q 'XUI_DB_TYPE=postgres' "$XUI_RESULT" 2>/dev/null && [ "${XKIT_ALLOW_POSTGRES_VERSION_CHANGE:-0}" != 1 ]; then
    err "PostgreSQL не входит в файловый snapshot. Сделайте Backup в панели и явно задайте XKIT_ALLOW_POSTGRES_VERSION_CHANGE=1"; return 1
  fi
  [ -f /etc/x-ui/x-ui.db ] || [ -n "$uv" ] || warn "Установленная БД не найдена; проверьте тип БД панели"
  confirm "Установить связку 3X-UI $u + Xray $x с backup и автоматическим rollback? [y/N]" || return 1
  version_arch || return 1
  work="$(mktemp -d)" || return 1; stage="$work/stage"; mkdir -p "$stage"
  local base="https://github.com/MHSanaei/3x-ui/releases/download/v${u}/x-ui-linux-${V_XUI}.tar.gz"
  local xurl="https://github.com/XTLS/Xray-core/releases/download/v${x}/Xray-linux-${V_XRAY}.zip"
  version_download_verified "$base" "${base}.sha256" "$work/xui.tar.gz" || { rm -rf "$work"; return 1; }
  version_download_verified "$xurl" "${xurl}.dgst" "$work/xray.zip" || { rm -rf "$work"; return 1; }
  version_extract_xui "$work/xui.tar.gz" "$stage" || { rm -rf "$work"; err "Небезопасный/битый архив 3X-UI"; return 1; }
  [ -x "$stage/x-ui/x-ui" ] || chmod +x "$stage/x-ui/x-ui" 2>/dev/null || true
  [ -x "$stage/x-ui/x-ui" ] || { rm -rf "$work"; err "В архиве нет x-ui"; return 1; }
  python3 - "$work/xray.zip" "$work" <<'PY' || { rm -rf "$work"; return 1; }
import sys,zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    n=next((n for n in z.namelist() if n.rstrip('/')=='xray'),None)
    if n is None: raise SystemExit('xray missing')
    z.extract(n,sys.argv[2])
PY
  chmod 755 "$work/xray" || { rm -rf "$work"; return 1; }
  "$work/xray" version >/dev/null 2>&1 || { rm -rf "$work"; err "Скачанный Xray не запускается"; return 1; }
  snap="$(version_snapshot)" || { rm -rf "$work"; err "Snapshot не создан — отмена"; return 1; }
  systemctl stop x-ui 2>/dev/null || true
  mkdir -p /usr/local/x-ui
  cp -a "$stage/x-ui/." /usr/local/x-ui/ || { version_snapshot_restore "$snap"; rm -rf "$work"; return 1; }
  xb="$(version_xray_bin)" || { version_snapshot_restore "$snap"; rm -rf "$work"; return 1; }
  install -m 755 "$work/xray" "$xb" || { version_snapshot_restore "$snap"; rm -rf "$work"; return 1; }
  rm -rf "$work"
  systemctl daemon-reload 2>/dev/null || true
  systemctl restart x-ui 2>/dev/null || true
  sleep 3
  if version_probes "$x" "$u"; then
    versions_state_save "$u" "$x" "$snap" || return 1
    ok "Связка установлена и прошла локальные probes: 3X-UI $u + Xray $x"
    log "Snapshot прежней связки: $snap"
  else
    err "Проверки не прошли — откат прежней связки"
    version_snapshot_restore "$snap" || return 1
    sleep 2
    systemctl is-active --quiet x-ui || { err "Rollback не поднял x-ui; snapshot: $snap"; return 1; }
    ok "Прежняя связка восстановлена"
    return 1
  fi
}

versions_rollback() {
  require_root
  versions_state_load
  local d="${1:-${XKIT_VERSION_SNAPSHOT:-}}"
  [ -n "$d" ] && [ -d "$d" ] || { err "Нет snapshot для отката"; return 1; }
  confirm "Восстановить прежние 3X-UI/Xray и БД из $d? [y/N]" || return 1
  version_snapshot_restore "$d" || return 1
  sleep 3
  systemctl is-active --quiet x-ui || { err "x-ui не активен после rollback"; return 1; }
  versions_status
}

# Старая команда остаётся совместимой, но больше не имеет bypass SHA-256.
core_pin_install() {
  local v u; v="$(version_norm "${1:-${XKIT_CORE_PIN:-}}")" || { err "Некорректная версия Xray"; return 1; }
  u="$(version_xui_current || true)"
  [ -n "$u" ] || { err "Версия 3X-UI неизвестна; используйте versions install <3xui> <xray>"; return 1; }
  versions_install "$u" "$v" --allow-unlisted
}

# Детерминированный camo: seed сохраняется, restart/повторная установка сайт не меняют.
camo_seed_load() {
  if [ -r "$XKIT_CAMO_STATE" ]; then . "$XKIT_CAMO_STATE"; fi
  if [[ "${XKIT_CAMO_SEED:-}" =~ ^[0-9a-f]{64}$ ]]; then printf '%s' "$XKIT_CAMO_SEED"; return 0; fi
  return 1
}
camo_seed_save() {
  [[ "$1" =~ ^[0-9a-f]{64}$ ]] || return 1
  mkdir -p "$XKIT_DIR"; chmod 700 "$XKIT_DIR"
  ( umask 077; local t; t="$(mktemp "${XKIT_CAMO_STATE}.new.XXXXXX")" || exit 1; printf 'XKIT_CAMO_SEED=%q\n' "$1" >"$t"; mv "$t" "$XKIT_CAMO_STATE" )
}
camo_generate_tree() { # seed destination
  python3 - "$1" "$2" <<'PY'
import sys,hashlib,pathlib
seed,dest=sys.argv[1:]
p=pathlib.Path(dest); (p/'assets').mkdir(parents=True,exist_ok=True)
def pick(seq,n):
    h=hashlib.sha256((seed+':'+n).encode()).digest()
    return seq[int.from_bytes(h[:8],'big')%len(seq)]
themes=[
 ('atelier','Morrow & Field','Small editions, careful printing and paper goods made in our workshop.'),
 ('studio','Stillroom Studio','Independent product and portrait photography, arranged by appointment.'),
 ('workshop','Northbank Cycles','Bicycle maintenance, wheel building and practical repairs.'),
 ('bakery','Daybreak Oven','Slow-fermented bread and a short seasonal menu, baked each morning.'),
 ('florist','Fern & Hollow','Seasonal stems, quiet arrangements and local weekend delivery.'),
 ('cafe','Juniper Counter','Coffee, simple lunches and a few seats by the window.'),
]
layouts=['split','stack','journal']
palettes=[('#f4f1ea','#26312c','#596f62'),('#f6f7f9','#202830','#526f91'),('#faf5ef','#382b27','#9a6245'),('#f2f5f7','#25333b','#427783')]
kind,title,tagline=pick(themes,'theme'); layout=pick(layouts,'layout'); bg,fg,accent=pick(palettes,'palette')
font=pick(['system-ui,sans-serif','Georgia,serif','Arial,sans-serif'],'font')
radius=pick(['0','6px','14px'],'radius')
owner=pick(['A. Mercer','R. Bennett','L. Hart','M. Ellis','S. Nolan'],'owner')
addr=pick(['18 Mill Lane','42 Station Road','7 Cedar Court','26 Market Square'],'address')
nav='<nav><a href="/">Home</a><a href="/about.html">About</a><a href="/contact.html">Contact</a></nav>'
css=f'''body{{margin:0;background:{bg};color:{fg};font-family:{font};line-height:1.65}}main{{max-width:880px;margin:auto;padding:9vh 7vw}}nav{{display:flex;gap:22px;margin-bottom:70px}}a{{color:{fg};text-decoration:none}}a:hover{{color:{accent}}}.mark{{width:42px;height:42px;border:1px solid {accent};border-radius:{radius};margin-bottom:25px}}h1{{font-size:clamp(30px,5vw,54px);line-height:1.1;font-weight:500}}.lead{{max-width:560px;color:{accent}}}.meta{{margin-top:55px;padding-top:20px;border-top:1px solid {accent};font-size:14px}}body.split main{{display:grid;grid-template-columns:2fr 1fr;gap:60px}}body.split nav{{grid-column:1/-1}}body.journal h1{{max-width:620px}}@media(max-width:650px){{body.split main{{display:block}}nav{{margin-bottom:40px}}}}'''
(p/'assets/style.css').write_text(css)
(p/'assets/mark.svg').write_text(f'<svg xmlns="http://www.w3.org/2000/svg" width="42" height="42"><rect x="1" y="1" width="40" height="40" rx="4" fill="none" stroke="{accent}"/><path d="M11 29V13l10 10 10-10v16" fill="none" stroke="{accent}"/></svg>')
def page(heading,text,extra=''):
    return f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{heading} — {title}</title><link rel="stylesheet" href="/assets/style.css"><link rel="icon" href="/assets/mark.svg"></head><body class="{layout}"><main>{nav}<section><img class="mark" src="/assets/mark.svg" alt=""><h1>{heading}</h1><p class="lead">{text}</p>{extra}</section><aside class="meta">{owner}<br>{addr}<br>Mon–Fri 09:00–17:00</aside></main></body></html>'''
(p/'index.html').write_text(page(title,tagline))
(p/'about.html').write_text(page('A small, independent practice',f'{title} is a fictional local {kind}. We keep our work deliberate and our opening hours simple.'))
(p/'contact.html').write_text(page('Visit or write',f'Appointments can be arranged in person at {addr}. General correspondence is handled during opening hours.'))
(p/'privacy.html').write_text(page('Privacy','This static website does not use analytics, external fonts, tracking pixels or data-collection forms.'))
(p/'404.html').write_text(page('Page not found','The requested page is not available. Use the navigation above to continue.'))
PY
}
camo_site_install() { # [hex-seed], без аргумента использует сохранённый
  require_root
  local seed="${1:-}" stage oldbak
  if [ -z "$seed" ]; then seed="$(camo_seed_load || true)"; fi
  if [ -z "$seed" ]; then seed="$(rand_hex 32)"; fi
  [[ "$seed" =~ ^[0-9a-f]{64}$ ]] || { err "Seed: ровно 64 hex-символа"; return 1; }
  if [ -z "${1:-}" ] && [ -f "$CAMO_DIR/index.html" ] && [ -f "$CAMO_DIR/assets/style.css" ]; then
    ok "Сайт-прикрытие сохранён без изменений (seed зафиксирован)"; return 0
  fi
  stage="$(mktemp -d "$(dirname "$CAMO_DIR")/.camo.new.XXXXXX")" || return 1
  camo_generate_tree "$seed" "$stage" || { rm -rf "$stage"; return 1; }
  # Внешние ресурсы и формы запрещены; генератор не должен молча их пропустить.
  if grep -R -E 'https?://|src="//|<form|@import' "$stage" --include='*.html' --include='*.css' | grep -v 'http://www.w3.org/2000/svg'; then
    rm -rf "$stage"; err "Camo содержит внешний ресурс или форму"; return 1
  fi
  camo_seed_save "$seed" || { rm -rf "$stage"; return 1; }
  oldbak="$(mktemp -d "$(dirname "$CAMO_DIR")/.camo.old.XXXXXX")" || { rm -rf "$stage"; return 1; }
  if [ -d "$CAMO_DIR" ]; then mv "$CAMO_DIR" "$oldbak/site" || { rm -rf "$stage" "$oldbak"; return 1; }; fi
  if mv "$stage" "$CAMO_DIR"; then
    find "$CAMO_DIR" -type d -exec chmod 755 {} +; find "$CAMO_DIR" -type f -exec chmod 644 {} +
    rm -rf "$oldbak"
    ok "Сайт-прикрытие сгенерирован детерминированно: $CAMO_DIR (seed сохранён отдельно)"
  else
    [ -d "$oldbak/site" ] && mv "$oldbak/site" "$CAMO_DIR"; rm -rf "$stage" "$oldbak"; return 1
  fi
}
camo_status() {
  local seed; seed="$(camo_seed_load || true)"
  echo "Каталог: $CAMO_DIR"
  echo "Seed: ${seed:+сохранён}${seed:-отсутствует}"
  [ -f "$CAMO_DIR/index.html" ] && echo "Сайт: установлен" || echo "Сайт: не установлен"
  echo "Seed — не секрет подключения, но публично не выводится"
}
camo_files() {
  cat <<EOF
Файлы сайта, которые можно заменить вручную:
  $CAMO_DIR/index.html       — главная страница
  $CAMO_DIR/about.html       — о проекте
  $CAMO_DIR/contact.html     — контакты
  $CAMO_DIR/privacy.html     — privacy
  $CAMO_DIR/404.html         — страница ошибки
  $CAMO_DIR/assets/style.css — оформление
  $CAMO_DIR/assets/mark.svg  — локальная графика
Используйте только локальные ресурсы. Ручные правки будут перезаписаны при camo regenerate.
EOF
}
camo_regenerate() {
  local seed="${1:-}"
  # Явная регенерация без seed = новый случайный вариант. С seed = воспроизводимый.
  [ -n "$seed" ] || seed="$(rand_hex 32)" || return 1
  camo_site_install "$seed"
}

#=========================== XKIT 7: ЭКСПЛУАТАЦИЯ И ДИАГНОСТИКА ===============
# Все состояния пишутся атомарно в своём каталоге. В журнал/дашборд/общий
# snapshot секреты не передаются. Отложенный restart — явная операция.

XKIT_AUDIT_LOG="${XKIT_AUDIT_LOG:-/var/log/xkit/audit.jsonl}"
XKIT_RESTART_QUEUE="${XKIT_RESTART_QUEUE:-${XKIT_DIR}/restart.queue}"
XKIT_LEDGER="${XKIT_LEDGER:-/var/lib/xkit/traffic-ledger.json}"
XKIT_PLAN_STATE="${XKIT_PLAN_STATE:-${XKIT_DIR}/nodes-plan.json}"
XKIT_MAINT_SERVICE="${XKIT_MAINT_SERVICE:-/etc/systemd/system/xkit-maintenance.service}"
XKIT_MAINT_TIMER="${XKIT_MAINT_TIMER:-/etc/systemd/system/xkit-maintenance.timer}"
XKIT_LOGROTATE="${XKIT_LOGROTATE:-/etc/logrotate.d/xkit}"
XKIT_GEODATA_DIR="${XKIT_GEODATA_DIR:-/usr/local/share/xray}"

_xkit_atomic_write() { # $1 destination; stdin -> same-dir temp -> chmod 600 -> mv
  local dst="$1" dir tmp
  dir="$(dirname "$dst")"; mkdir -p "$dir" || return 1
  tmp="$(mktemp "${dir}/.xkit-write.XXXXXX")" || return 1
  if ! cat > "$tmp"; then rm -f "$tmp"; return 1; fi
  chmod 600 "$tmp" 2>/dev/null || true
  if ! mv -f "$tmp" "$dst"; then rm -f "$tmp"; return 1; fi
}

audit_event() { # action target result [detail]; detail только технический, без значений
  local action="${1:-unknown}" target="${2:-master}" result="${3:-ok}" detail="${4:-}" ts row
  case "$action$target$result$detail" in *[$'\r\n\t']*) detail="invalid-text" ;; esac
  action="${action//[^A-Za-z0-9_.:-]/_}"; target="${target//[^A-Za-z0-9_.:-]/_}"
  result="${result//[^A-Za-z0-9_.:-]/_}"; detail="${detail//[^A-Za-z0-9_.: -]/_}"
  detail="${detail:0:160}"; ts="$(date -Is)"
  row="$(jq -nc --arg ts "$ts" --arg action "$action" --arg target "$target" \
    --arg result "$result" --arg detail "$detail" \
    '{ts:$ts,action:$action,target:$target,result:$result}+(if $detail!="" then {detail:$detail} else {} end)')" || return 0
  mkdir -p "$(dirname "$XKIT_AUDIT_LOG")" 2>/dev/null || return 0
  ( flock -w 3 9 || exit 0; printf '%s\n' "$row" >> "$XKIT_AUDIT_LOG"; chmod 600 "$XKIT_AUDIT_LOG" 2>/dev/null || true ) 9>"${XKIT_AUDIT_LOG}.lock" 2>/dev/null || true
  return 0
}

audit_show() {
  [ -r "$XKIT_AUDIT_LOG" ] || { warn "Audit journal пока пуст"; return 0; }
  tail -n "${1:-50}" "$XKIT_AUDIT_LOG" | jq -r '[.ts,.action,.target,.result,(.detail//"")]|@tsv' 2>/dev/null
}

restart_request() {
  local svc="${1:-}" cur
  case "$svc" in nginx|x-ui|xkit-hysteria2|awg-quick@awg0) ;; *) err "Разрешены: nginx, x-ui, xkit-hysteria2, awg-quick@awg0"; return 1 ;; esac
  cur="$( { [ -r "$XKIT_RESTART_QUEUE" ] && cat "$XKIT_RESTART_QUEUE"; printf '%s\n' "$svc"; } | awk 'NF&&!a[$0]++')"
  printf '%s\n' "$cur" | _xkit_atomic_write "$XKIT_RESTART_QUEUE" || return 1
  audit_event restart.defer "$svc" ok
  ok "Перезапуск отложен: $svc. Применить: xkit restart apply"
}

restart_status() {
  [ -s "$XKIT_RESTART_QUEUE" ] || { ok "Очередь перезапусков пуста"; return 0; }
  cat "$XKIT_RESTART_QUEUE"
}

restart_apply() {
  require_root
  [ -s "$XKIT_RESTART_QUEUE" ] || { ok "Очередь перезапусков пуста"; return 0; }
  local svc failed=0
  if grep -qx nginx "$XKIT_RESTART_QUEUE" && ! nginx -t; then err "nginx -t не прошёл — очередь сохранена"; return 1; fi
  while IFS= read -r svc; do
    case "$svc" in nginx|x-ui|xkit-hysteria2|awg-quick@awg0) ;; *) failed=1; continue ;; esac
    if [ "$svc" = nginx ]; then systemctl reload nginx || systemctl restart nginx; else systemctl restart "$svc"; fi \
      && audit_event restart.apply "$svc" ok || { failed=1; audit_event restart.apply "$svc" error; err "Не перезапущен: $svc"; }
  done < "$XKIT_RESTART_QUEUE"
  [ "$failed" -eq 0 ] || return 1
  rm -f "$XKIT_RESTART_QUEUE"; ok "Все отложенные перезапуски применены"
}

ops_hygiene_install() {
  require_root
  mkdir -p "$(dirname "$XKIT_AUDIT_LOG")" /var/log/xkit; chmod 700 /var/log/xkit
  cat > "$XKIT_LOGROTATE" <<'EOF'
/var/log/xkit-*.log /var/log/xkit/*.log /var/log/xkit/*.jsonl {
    daily
    rotate 14
    size 10M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    create 0600 root root
}
EOF
  chmod 644 "$XKIT_LOGROTATE"
  cat > "$XKIT_MAINT_SERVICE" <<EOF
[Unit]
Description=XKIT maintenance (logs, traffic ledger, backup verification)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${XKIT_BIN} maintenance run
NoNewPrivileges=true
PrivateTmp=true
EOF
  cat > "$XKIT_MAINT_TIMER" <<'EOF'
[Unit]
Description=Daily XKIT maintenance

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=10m

[Install]
WantedBy=timers.target
EOF
  chmod 644 "$XKIT_MAINT_SERVICE" "$XKIT_MAINT_TIMER"
  systemctl daemon-reload; systemctl enable --now xkit-maintenance.timer
  audit_event maintenance.install master ok
  ok "Logrotate и ежедневный maintenance timer установлены"
}

maintenance_run() {
  logrotate -s /var/lib/xkit/logrotate.status "$XKIT_LOGROTATE" >/dev/null 2>&1 || warn "logrotate завершился с ошибкой"
  traffic_ledger_collect >/dev/null 2>&1 || warn "Traffic ledger: панель недоступна"
  local latest; latest="$(ls -1t "$BACKUP_DIR"/xkit-*.tar.gz 2>/dev/null | head -n1)"
  [ -n "$latest" ] && backup_verify "$latest" >/dev/null 2>&1 || true
}

# Безопасная проверка backup: пути, symlink и командные подстановки в env.
backup_archive_check() { # $1 archive, $2 optional extraction directory
  local file="$1" dest="${2:-}" own=0 bad link target
  [ -f "$file" ] || { err "Архив не найден"; return 1; }
  tar -tzf "$file" >/dev/null 2>&1 || { err "Архив битый"; return 1; }
  if tar -tzf "$file" | grep -qE '(^/|(^|/)\.\.(/|$))'; then err "Небезопасные пути в архиве"; return 1; fi
  if [ -z "$dest" ]; then dest="$(mktemp -d)" || return 1; own=1; fi
  mkdir -p "$dest"; tar xzf "$file" -C "$dest" || { [ "$own" = 1 ] && rm -rf "$dest"; return 1; }
  bad="$(find "$dest" -type l -print0 2>/dev/null | while IFS= read -r -d '' link; do
    target="$(readlink -f "$link" 2>/dev/null || true)"; case "$target" in "$dest"|"$dest"/*) ;; *) printf '%s\n' "$link"; break ;; esac
  done)"
  if [ -n "$bad" ]; then err "Symlink ведёт наружу архива"; [ "$own" = 1 ] && rm -rf "$dest"; return 1; fi
  if [ -f "$dest${XKIT_ENV}" ] && grep -qE '`|\$\(|\$\{' "$dest${XKIT_ENV}" 2>/dev/null; then
    err "xkit.env содержит командную подстановку"; [ "$own" = 1 ] && rm -rf "$dest"; return 1
  fi
  [ "$own" = 1 ] && rm -rf "$dest"
  return 0
}

backup_verify() {
  local file="${1:-}" tmp
  [ -n "$file" ] || file="$(ls -1t "$BACKUP_DIR"/xkit-*.tar.gz 2>/dev/null | head -n1)"
  [ -n "$file" ] || { warn "Бэкапы не найдены"; return 1; }
  tmp="$(mktemp -d)" || return 1
  if backup_archive_check "$file" "$tmp"; then
    local count; count="$(find "$tmp" -type f | wc -l)"
    rm -rf "$tmp"; audit_event backup.verify master ok
    ok "Архив пригоден для распаковки: $file (файлов: $count)"
  else rm -rf "$tmp"; audit_event backup.verify master error; return 1; fi
}

backup_restore_dry_run() {
  local file="${1:-}" tmp db nginx_state
  [ -n "$file" ] || file="$(ls -1t "$BACKUP_DIR"/xkit-*.tar.gz 2>/dev/null | head -n1)"
  [ -n "$file" ] || { warn "Бэкапы не найдены"; return 1; }
  tmp="$(mktemp -d)" || return 1
  backup_archive_check "$file" "$tmp" || { rm -rf "$tmp"; return 1; }
  db=missing; [ -f "$tmp${XUI_DB}" ] && db=present
  nginx_state=missing; [ -f "$tmp${XKIT_CONF}" ] && nginx_state=present
  jq -nc --arg file "$(basename "$file")" --arg db "$db" --arg nginx "$nginx_state" \
    --argjson files "$(find "$tmp" -type f | wc -l)" '{dry_run:true,file:$file,database:$db,nginx:$nginx,files:$files}'
  rm -rf "$tmp"; ok "Dry-run завершён: система не изменялась"
}

backup_export() {
  local src="${1:-}" recipient="${XKIT_AGE_RECIPIENT:-}" out
  command -v age >/dev/null 2>&1 || { err "Нужен age (apt install age). Автоустановку не выполняю"; return 1; }
  [ -n "$src" ] || src="$(ls -1t "$BACKUP_DIR"/xkit-*.tar.gz 2>/dev/null | head -n1)"
  [ -f "$src" ] || { err "Бэкап не найден"; return 1; }
  backup_archive_check "$src" || return 1
  if [ -z "$recipient" ]; then read -r -p "Публичный age recipient: " recipient || return 1; fi
  [[ "$recipient" =~ ^age1[023456789acdefghjklmnpqrstuvwxyz]{20,100}$ ]] || { err "Неверный age recipient"; return 1; }
  out="${src%.tar.gz}-$(date +%Y%m%d-%H%M%S).tar.gz.age"
  age -r "$recipient" -o "$out" "$src" || { rm -f "$out"; return 1; }
  chmod 600 "$out"; age -d -i /dev/null "$out" >/dev/null 2>&1 || true # расшифровка требует вашего ключа
  sha256sum "$out" > "${out}.sha256"; chmod 600 "${out}.sha256"
  audit_event backup.export master ok age
  ok "Зашифрованный экспорт: $out"
}

# Санитизация support bundle: секреты, UUID, subscription tokens и адреса нод.
doctor_sanitize_stream() {
  python3 -c 'import re,sys
s=sys.stdin.read()
s=re.sub(r"-----BEGIN [^-]+-----.*?-----END [^-]+-----", "[REDACTED-KEY]", s, flags=re.S)
patterns=[
 (r"(?i)(password|passwd|token|secret|privatekey|private_key|authorization|cookie)([\" ]*[:=][\" ]*)[^\s,;\"}]+", r"\1\2[REDACTED]"),
 (r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}", "[REDACTED-UUID]"),
 (r"/s-[A-Za-z0-9_-]{6,}/[A-Za-z0-9_-]+", "/[REDACTED-SUBSCRIPTION]"),
 (r"\b[0-9]{6,12}:[A-Za-z0-9_-]{30,46}\b", "[REDACTED-BOT-TOKEN]"),
 (r"\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b", "[REDACTED-IP]")]
for p,r in patterns: s=re.sub(p,r,s)
sys.stdout.write(s)'
}

doctor_export() {
  require_root
  load_xkit_env >/dev/null 2>&1 || true
  local out="${1:-}" stamp tmp report
  command -v python3 >/dev/null 2>&1 || { err "Нужен python3"; return 1; }
  stamp="$(date +%Y%m%d-%H%M%S)"; out="${out:-/root/xkit-doctor-${stamp}.tar.gz}"
  case "$out" in /*.tar.gz) ;; *) err "Укажите абсолютный путь .tar.gz"; return 1 ;; esac
  tmp="$(mktemp -d)" || return 1; chmod 700 "$tmp"
  {
    printf 'XKIT %s\n' "$XKIT_VERSION"; printf 'collected=%s\n' "$(date -Is)"
    printf 'os='; . /etc/os-release 2>/dev/null && printf '%s %s\n' "$ID" "$VERSION_ID" || printf 'unknown\n'
    printf 'kernel='; uname -r
    for svc in nginx x-ui xkit-hysteria2 awg-quick@awg0 xkit-maintenance.timer; do printf 'service.%s=%s\n' "$svc" "$(systemctl is-active "$svc" 2>/dev/null || true)"; done
    printf 'disk='; df -P / | awk 'NR==2{print $5}'
    printf 'nginx_test='; nginx -t 2>&1 | tail -n 3
    printf 'xray_test='; local xr; xr="$(ls -1 /usr/local/x-ui/bin/xray-linux-* 2>/dev/null | head -n1)"; [ -n "$xr" ] && "$xr" run -test -confdir /usr/local/x-ui/bin 2>&1 | tail -n 5 || printf 'unavailable\n'
    printf 'nodes='; nodes_load 2>/dev/null | jq -c '[.[]?|{name,ssh_port,auth,panel:{port:.panel.port,tls:.panel.tls,token:(if (.panel.token//"")!="" then "configured" else "not-configured" end)},tunnel:{port:.tunnel.port,proto:.tunnel.proto,net:.tunnel.net,sec:.tunnel.sec}}]' 2>/dev/null || printf '[]\n'
  } > "$tmp/report.txt" 2>&1
  doctor_sanitize_stream < "$tmp/report.txt" > "$tmp/report.sanitized"; mv "$tmp/report.sanitized" "$tmp/report.txt"
  for svc in nginx x-ui; do journalctl -u "$svc" -n 100 --no-pager 2>/dev/null | doctor_sanitize_stream > "$tmp/journal-${svc}.txt"; done
  [ -r "$XKIT_AUDIT_LOG" ] && tail -n 200 "$XKIT_AUDIT_LOG" | doctor_sanitize_stream > "$tmp/audit.jsonl"
  (cd "$tmp" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$tmp/SHA256SUMS"
  tar czf "$out" -C "$tmp" . || { rm -rf "$tmp"; return 1; }; chmod 600 "$out"; rm -rf "$tmp"
  audit_event doctor.export master ok
  ok "Sanitized support bundle: $out"
}

# Read-only ledger из clientStats. Ноль после reset/restart не вычитает трафик.
traffic_ledger_update() { # $1 previous JSON, $2 inbounds JSON, $3 epoch
  jq -nc --argjson old "${1:-null}" --argjson ibs "${2:-[]}" --argjson now "${3:-0}" '
    def stats($ib): ($ib.clientStats//[]|if type=="string" then (fromjson? // []) else . end);
    def clients($ib): ($ib.settings|if type=="string" then (fromjson? // {}) else (.//{}) end|.clients//[]);
    [$ibs[]? as $ib | stats($ib)[]? | select((.email//"")!="") |
      {key:(($ib.id|tostring)+":"+.email),email:.email,up:(.up//0|tonumber? // 0),down:(.down//0|tonumber? // 0)}] as $cur |
    {version:1,updated:$now,users:{}} as $base |
    reduce $cur[] as $c ($base;
      .users[$c.key] as $o |
      (($old.users[$c.key]//null)) as $p |
      (if $p==null then {up:0,down:0,resets:0}
       elif $c.up>=($p.raw_up//0) and $c.down>=($p.raw_down//0) then {up:($c.up-$p.raw_up),down:($c.down-$p.raw_down),resets:0}
       else {up:0,down:0,resets:1} end) as $d |
      .users[$c.key]={email:$c.email,raw_up:$c.up,raw_down:$c.down,
        total_up:(($p.total_up//0)+$d.up),total_down:(($p.total_down//0)+$d.down),
        resets:(($p.resets//0)+$d.resets),last_seen:$now})'
}

traffic_ledger_collect() {
  load_xkit_env >/dev/null 2>&1 || return 1
  kit_session >/dev/null 2>&1 || return 1
  local old='{"version":1,"users":{}}' new now
  [ -r "$XKIT_LEDGER" ] && jq -e . "$XKIT_LEDGER" >/dev/null 2>&1 && old="$(cat "$XKIT_LEDGER")"
  now="$(date +%s)"; new="$(traffic_ledger_update "$old" "$INBOUNDS" "$now")" || return 1
  printf '%s\n' "$new" | _xkit_atomic_write "$XKIT_LEDGER"
}

traffic_ledger_show() {
  [ -r "$XKIT_LEDGER" ] || { warn "Ledger пуст: xkit ledger collect"; return 0; }
  jq -r '.users|to_entries[]|[.value.email,.value.total_up,.value.total_down,((.value.total_up+.value.total_down)|tostring),(.value.resets|tostring)]|@tsv' "$XKIT_LEDGER" \
    | { printf 'EMAIL\tUP\tDOWN\tTOTAL\tRESETS\n'; cat; }
}

traffic_ledger_quota_check() { # только отчёт; никакого disable/reset
  local limit="${1:-0}"; [[ "$limit" =~ ^[0-9]+$ ]] && [ "$limit" -gt 0 ] || { err "Лимит в байтах, >0"; return 1; }
  [ -r "$XKIT_LEDGER" ] || { err "Сначала xkit ledger collect"; return 1; }
  jq -c --argjson limit "$limit" '{dry_run:true,limit_bytes:$limit,over:[.users[]|select(.total_up+.total_down>$limit)|{email,total:(.total_up+.total_down)}]}' "$XKIT_LEDGER"
}

geodata_update() { # pinned tag + обе SHA-256; latest запрещён
  local tag="${1:-}" hip="${2:-}" hsite="${3:-}" tmp gd ip site xr
  [[ "$tag" =~ ^[0-9A-Za-z._-]+$ ]] && [ "$tag" != latest ] || { err "Нужен pinned tag релиза, не latest"; return 1; }
  [[ "$hip$hsite" =~ ^[0-9a-f]{128}$ ]] || { err "Нужны SHA-256 geoip.dat и geosite.dat"; return 1; }
  tmp="$(mktemp -d)" || return 1; gd="$XKIT_GEODATA_DIR"
  curl -fsSL --max-time 60 "https://github.com/XTLS/Xray-rules-dat/releases/download/${tag}/geoip.dat" -o "$tmp/geoip.dat" \
    && curl -fsSL --max-time 60 "https://github.com/XTLS/Xray-rules-dat/releases/download/${tag}/geosite.dat" -o "$tmp/geosite.dat" || { rm -rf "$tmp"; return 1; }
  printf '%s  %s\n%s  %s\n' "$hip" "$tmp/geoip.dat" "$hsite" "$tmp/geosite.dat" | sha256sum -c - || { rm -rf "$tmp"; return 1; }
  mkdir -p "$gd"; for ip in geoip.dat geosite.dat; do [ ! -f "$gd/$ip" ] || cp -a "$gd/$ip" "$tmp/$ip.old"; done
  install -m 644 "$tmp/geoip.dat" "$gd/geoip.dat"; install -m 644 "$tmp/geosite.dat" "$gd/geosite.dat"
  xr="$(ls -1 /usr/local/x-ui/bin/xray-linux-* 2>/dev/null | head -n1)"
  if [ -n "$xr" ] && ! "$xr" run -test -confdir /usr/local/x-ui/bin >/dev/null 2>&1; then
    for ip in geoip.dat geosite.dat; do [ ! -f "$tmp/$ip.old" ] || cp -a "$tmp/$ip.old" "$gd/$ip"; done
    rm -rf "$tmp"; err "Config test не прошёл — старые geodata восстановлены"; return 1
  fi
  rm -rf "$tmp"; restart_request x-ui; audit_event geodata.update master ok "$tag"
  ok "Geodata $tag установлены; restart x-ui отложен"
}

#=========================== XKIT 7: SING-BOX И SUBSCRIPTION UX ===============

singbox_json_gen() { # $1 base64 links file, $2 output JSON; unsupported links skipped
  python3 - "$1" "$2" <<'PY'
import base64,json,sys
from urllib.parse import urlparse,parse_qs,unquote
src,dst=sys.argv[1:3]
raw=open(src,'rb').read()
try: text=base64.b64decode(raw,validate=True).decode()
except Exception: text=raw.decode()
out=[]; skipped=[]
def query(u): return {k:v[-1] for k,v in parse_qs(u.query).items()}
for line in text.splitlines():
    line=line.strip()
    if not line: continue
    try:
        u=urlparse(line); q=query(u); name=unquote(u.fragment) or u.scheme
        if u.scheme=='vless':
            user={'uuid':u.username,'encryption':'none'}
            if q.get('flow'): user['flow']=q['flow']
            o={'type':'vless','tag':name,'server':u.hostname,'server_port':u.port,
               'uuid':u.username,'encryption':'none'}
            if q.get('flow'): o['flow']=q['flow']
            sec=q.get('security','none'); typ=q.get('type','tcp')
            if typ=='splithttp': typ='xhttp'
            tls={'enabled':sec in ('tls','reality'),'server_name':q.get('sni',u.hostname),
                 'utls':{'enabled':True,'fingerprint':q.get('fp','chrome')}}
            if q.get('insecure')=='1' or q.get('allowInsecure')=='1': tls['insecure']=True
            if sec=='reality': tls['reality']={'enabled':True,'public_key':q.get('pbk',''),'short_id':q.get('sid','')}
            if tls['enabled']: o['tls']=tls
            if typ=='xhttp': o['transport']={'type':'http','path':q.get('path','/'),'host':q.get('host','')}
            elif typ=='ws': o['transport']={'type':'ws','path':q.get('path','/'),'headers':{'Host':q.get('host','')} }
            elif typ=='grpc': o['transport']={'type':'grpc','service_name':q.get('serviceName','')}
            elif typ not in ('tcp','raw',''): skipped.append(name+':transport'); continue
        elif u.scheme in ('hysteria2','hy2'):
            o={'type':'hysteria2','tag':name,'server':u.hostname,'server_port':u.port,'password':unquote(u.username or '')}
            tls={'enabled':True,'server_name':q.get('sni',u.hostname),'alpn':['h3']}
            if q.get('insecure')=='1': tls['insecure']=True
            o['tls']=tls
            if q.get('obfs')=='salamander': o['obfs']={'type':'salamander','password':q.get('obfs-password','')}
        elif u.scheme=='trojan':
            o={'type':'trojan','tag':name,'server':u.hostname,'server_port':u.port,'password':unquote(u.username or ''),
               'tls':{'enabled':True,'server_name':q.get('sni',u.hostname),'utls':{'enabled':True,'fingerprint':'chrome'}}}
        elif u.scheme=='ss':
            # ss://base64(method:password)@host:port и ss://method:password@host:port
            userinfo=unquote(u.username or '')
            if ':' not in userinfo:
                try: userinfo=base64.urlsafe_b64decode(userinfo+'===').decode()
                except Exception: raise ValueError('ss userinfo')
            if ':' not in userinfo: raise ValueError('ss cipher')
            method,password=userinfo.split(':',1)
            o={'type':'shadowsocks','tag':name,'server':u.hostname,'server_port':u.port,'method':method,'password':password}
        else:
            skipped.append(name+':scheme'); continue
        out.append(o)
    except Exception:
        skipped.append(name if 'name' in locals() else line[:16])
conf={'log':{'level':'warn','timestamp':True},'outbounds':[],'route':{
    'rule_set':[
        {'type':'remote','tag':'geosite-category-ru','format':'binary','url':'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ru.srs','update_interval':'24h'},
        {'type':'remote','tag':'geoip-ru','format':'binary','url':'https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs','update_interval':'24h'}],
    'rules':[{'rule_set':['geosite-category-ru','geoip-ru'],'outbound':'direct'}],
    'final':'auto'}}
if out:
    conf['outbounds']=[{'type':'selector','tag':'auto','outbounds':[o['tag'] for o in out]+['direct'],'default':out[0]['tag']}]+out+[{'type':'direct','tag':'direct'}]
else: conf['outbounds']=[{'type':'direct','tag':'direct'}]
tmp=dst+'.tmp'
with open(tmp,'w',encoding='utf-8') as f: json.dump(conf,f,ensure_ascii=False,indent=2); f.write('\n')
import os
os.replace(tmp,dst)
print(json.dumps({'generated':len(out),'skipped':skipped},ensure_ascii=False))
PY
}

subscription_nginx_headers() { # $1 subId, $2 metadata file; только числовые values
  local sub="$1" meta="$2" up down total expire value
  local sub_path; sub_path="$(sub_path)"
  [[ "$sub" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  up="$(jq -r '.up//0|tonumber? // 0|floor' "$meta" 2>/dev/null)"; down="$(jq -r '.down//0|tonumber? // 0|floor' "$meta" 2>/dev/null)"
  total="$(jq -r '.total//0|tonumber? // 0|floor' "$meta" 2>/dev/null)"; expire="$(jq -r '.expire//0|tonumber? // 0|floor' "$meta" 2>/dev/null)"
  value="upload=${up:-0}; download=${down:-0}; total=${total:-0}; expire=${expire:-0}"
  cat <<EOF
    location = ${sub_path}${sub} {
        alias ${SUBS_DIR}/${sub};
        default_type text/plain;
        add_header subscription-userinfo "${value}" always;
        add_header profile-title "XKIT" always;
        add_header profile-update-interval "6" always;
        add_header Referrer-Policy "no-referrer" always;
        add_header Cache-Control "no-store" always;
        add_header X-Robots-Tag "noindex, nofollow" always;
        access_log off;
    }
    location = ${sub_path}${sub}/amnezia {
        alias ${SUBS_DIR}/${sub}.amnezia.html;
        default_type text/html;
        add_header Referrer-Policy "no-referrer" always;
        add_header Cache-Control "no-store" always;
        add_header X-Robots-Tag "noindex, nofollow" always;
        access_log off;
    }
EOF
}

subscription_metadata_update() { # subId + inbounds; aggregate stats/quota/expiry
  local sub="$1" ibs="$2"
  jq -nc --arg sub "$sub" --argjson ibs "$ibs" '
    def arr($x): ($x|if type=="string" then (fromjson? // []) else (.//[]) end);
    def clients($ib): ($ib.settings|if type=="string" then (fromjson? // {}) else (.//{}) end|.clients//[]);
    [$ibs[] as $ib | clients($ib)[] | select(.subId==$sub)] as $cl |
    [$ibs[] as $ib | arr($ib.clientStats)[] as $s | select(($cl|map(.email)|index($s.email))!=null) | $s] as $st |
    {up:($st|map(.up//0)|add//0),down:($st|map(.down//0)|add//0),
     total:($cl|map(.totalGB//0)|add//0),
     expire:([$cl[]|.expiryTime//0|select(.>0)|./1000|floor]|min//0)}'
}

amnezia_qr_html() { # $1 vpn:// с plain-base64 .conf, $2 HTML с родными QR-фрагментами Amnezia
  AWG_QR_LINK="$1" AWG_QR_OUT="$2" python3 - <<'PY'
import base64,configparser,html as html_escape,io,json,os,shutil,struct,subprocess,zlib
from pathlib import Path

link=os.environ['AWG_QR_LINK']; out=Path(os.environ['AWG_QR_OUT'])
if not link.startswith('vpn://'): raise SystemExit('Нужна vpn:// ссылка AmneziaWG')
try: conf=base64.b64decode(link[6:],validate=True).decode()
except Exception as e: raise SystemExit(f'Некорректный AWG vpn://: {e}')
p=configparser.ConfigParser(interpolation=None); p.optionxform=str; p.read_string(conf)
if not p.has_section('Interface') or not p.has_section('Peer'): raise SystemExit('AWG конфиг без Interface/Peer')
i=p['Interface']; peer=p['Peer']; endpoint=peer.get('Endpoint','')
try: host,port=endpoint.rsplit(':',1); port=int(port)
except ValueError: raise SystemExit('AWG Endpoint должен быть host:port')
if not host or not 1<=port<=65535: raise SystemExit('Некорректный AWG Endpoint')
host=host.strip('[]'); dns=[x.strip() for x in i.get('DNS','').split(',') if x.strip()]
fields={
 'Jc':'junkPacketCount','Jmin':'junkPacketMinSize','Jmax':'junkPacketMaxSize',
 'S1':'initPacketJunkSize','S2':'responsePacketJunkSize','S3':'cookieReplyPacketJunkSize',
 'S4':'transportPacketJunkSize','H1':'initPacketMagicHeader','H2':'responsePacketMagicHeader',
 'H3':'underloadPacketMagicHeader','H4':'transportPacketMagicHeader',
 'I1':'specialJunk1','I2':'specialJunk2','I3':'specialJunk3','I4':'specialJunk4','I5':'specialJunk5',
 'HeaderProtectionKey':'headerProtectionKey','ContentPaddingAddition':'contentPaddingAddition',
 'RekeyAfterTime':'rekeyAfterTime','RekeyTimeout':'rekeyTimeout','RejectAfterTime':'rejectAfterTime',
 'KeepaliveTimeout':'keepaliveTimeout','MaxHandshakeAttempts':'maxHandshakeAttempts',
 'RandomTrailers':'randomTrailers','DisableCookies':'disableCookies'}
extra={dst:i[src] for src,dst in fields.items() if i.get(src,'')!=''}
last={'config':conf,'hostName':host,'port':port,'client_ip':i.get('Address',''),
 'client_priv_key':i.get('PrivateKey',''),'client_pub_key':'0',
 'server_pub_key':peer.get('PublicKey',''),'psk_key':peer.get('PresharedKey',''),
 'allowedIps':[x.strip() for x in peer.get('AllowedIPs','').split(',') if x.strip()],
 'persistentKeepAlive':i.get('PersistentKeepalive',peer.get('PersistentKeepalive','')),
 'mtu':i.get('MTU',''),**extra}
server={'isThirdPartyConfig':True,'transport_proto':'udp','port':str(port),
 'last_config':json.dumps(last,ensure_ascii=False,separators=(',',':')),**extra}
data={'containers':[{'container':'amnezia-awg','awg':server}],
 'defaultContainer':'amnezia-awg','description':'XKIT AmneziaWG','hostName':host,
 'dns1':dns[0] if dns else '','dns2':dns[1] if len(dns)>1 else ''}
plain=json.dumps(data,ensure_ascii=False,separators=(',',':')).encode()
packed=struct.pack('>I',len(plain))+zlib.compress(plain,8)  # Qt qCompress
chunks=[packed[n:n+850] for n in range(0,len(packed),850)]
payloads=[base64.urlsafe_b64encode(struct.pack('>hBBI',1984,len(chunks),n,len(c))+c).rstrip(b'=').decode()
          for n,c in enumerate(chunks)]
def svg(payload):
 if shutil.which('qrencode'):
  return subprocess.run(['qrencode','-t','SVG','-l','L','-o','-',payload],check=True,capture_output=True).stdout
 import qrcode,qrcode.image.svg
 im=qrcode.make(payload,error_correction=qrcode.constants.ERROR_CORRECT_L,
                image_factory=qrcode.image.svg.SvgPathImage)
 buf=io.BytesIO(); im.save(buf); return buf.getvalue()
try: frames=['data:image/svg+xml;base64,'+base64.b64encode(svg(x)).decode() for x in payloads]
except ImportError: raise SystemExit('Для QR установите qrencode или python3-qrcode')
html='''<!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>XKIT — AmneziaWG</title><style>body{margin:0;background:#111;color:#eee;font:16px sans-serif;text-align:center}img{width:min(92vw,720px);image-rendering:pixelated;background:white}p{margin:16px}pre{margin:20px auto;padding:16px;max-width:900px;overflow:auto;text-align:left;background:#222;white-space:pre-wrap;overflow-wrap:anywhere}button{padding:12px 20px;font-size:16px;cursor:pointer}</style>
<h2>AmneziaWG</h2><img id="qr" alt="QR для AmneziaVPN"><p id="status"></p><p>Сканируйте через AmneziaVPN до завершения импорта.</p>
<h2>Или скопируйте конфиг</h2><button id="copy">Скопировать конфиг</button><span id="copied"></span><pre id="config">CONFIG</pre>
<script>const f=FRAMES;let n=0;const img=document.getElementById('qr');function show(){img.src=f[n];document.getElementById('status').textContent=`Фрагмент ${n+1} из ${f.length}`;n=(n+1)%f.length}show();setInterval(show,700);document.getElementById('copy').onclick=async()=>{await navigator.clipboard.writeText(document.getElementById('config').textContent);document.getElementById('copied').textContent=' Скопировано'};</script></html>'''.replace('FRAMES',json.dumps(frames,separators=(',',':'))).replace('CONFIG',html_escape.escape(conf))
tmp=out.with_suffix(out.suffix+'.tmp'); tmp.write_text(html,encoding='utf-8'); os.chmod(tmp,0o600); os.replace(tmp,out)
print(f'Amnezia QR: {len(frames)} фрагмент(а)')
PY
}

sub_qr() { # локальный SVG/PNG или родной animated HTML для AmneziaVPN
  local sub="${1:-}" fmt="${2:-svg}" url out
  [[ "$sub" =~ ^[A-Za-z0-9_-]+$ ]] || { err "xkit sub qr <subId> [svg|png|awg]"; return 1; }
  load_xkit_env >/dev/null 2>&1 || return 1
  if [ "$fmt" = awg ]; then
    kit_session || return 1
    local pair ib cl link
    pair="$(api_list | jq -c --arg sub "$sub" '[.[] as $ib | select($ib.protocol=="amneziawg") | ($ib.settings|if type=="string" then fromjson else . end|.clients//[])[] | select(.subId==$sub) | {ib:$ib,cl:.}][0] // empty')"
    [ -n "$pair" ] || { err "Пользователь с subId ${sub} не найден"; return 1; }
    ib="$(jq -c '.ib' <<<"$pair")"; cl="$(jq -c '.cl' <<<"$pair")"
    [ "$(jq -r '.protocol' <<<"$ib")" = amneziawg ] || { err "У пользователя нет AmneziaWG"; return 1; }
    link="$(link_for_client "$ib" "$cl")"; [ -n "$link" ] || { err "Не удалось собрать AWG конфиг"; return 1; }
    out="${XKIT_DIR}/qr-${sub}-amnezia.html"
    amnezia_qr_html "$link" "$out" || return 1
    ok "QR AmneziaVPN сохранён локально: $out (откройте в браузере)"
    return 0
  fi
  url="https://${XKIT_HOST}$(sub_path)${sub}"
  out="${XKIT_DIR}/qr-${sub}.${fmt}"
  if command -v qrencode >/dev/null 2>&1; then
    case "$fmt" in svg) qrencode -t SVG -o "$out" "$url" ;; png) qrencode -t PNG -s 8 -o "$out" "$url" ;; *) return 1 ;; esac
  elif python3 -c 'import qrcode' >/dev/null 2>&1; then
    QR_URL="$url" QR_OUT="$out" QR_FMT="$fmt" python3 - <<'PY'
import os,qrcode
im=qrcode.make(os.environ['QR_URL'])
if os.environ['QR_FMT']=='png': im.save(os.environ['QR_OUT'])
else:
 import qrcode.image.svg
 im=qrcode.make(os.environ['QR_URL'],image_factory=qrcode.image.svg.SvgPathImage); im.save(os.environ['QR_OUT'])
PY
  else
    err "Для локального QR установите qrencode или python3-qrcode. Внешний QR-сервис не используется"; return 1
  fi
  chmod 600 "$out"; ok "QR сохранён локально: $out"
}

#=========================== XKIT 7: NODE PLAN / CANARY / TOKENS ==============

node_canary_probe() { # rec -> 0 только при TCP+SSH+API; client probe отдельно
  local rec="$1" ck rc=0
  timeout 4 bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$(jq -r '.host' <<<"$rec")" "$(jq -r '.tunnel.port//443' <<<"$rec")" 2>/dev/null || rc=1
  node_ssh "$rec" 'true' >/dev/null 2>&1 || rc=1
  ck="$(mktemp /tmp/.xkit-node-ck.XXXXXX)" || return 1
  if node_login "$rec" "$ck" >/dev/null 2>&1; then
    node_api "$rec" panel/api/inbounds/list GET "" "$ck" 2>/dev/null | jq -e '.success==true' >/dev/null 2>&1 || rc=1
  else rc=1; fi
  rm -f "$ck"; return "$rc"
}

nodes_plan_collect() { # stdout sanitized JSON; сохраняет hash, но не credentials
  load_xkit_env >/dev/null 2>&1 || return 1
  local arr hash ck rec name host port actual state
  arr="$(nodes_load)"; hash="$(printf '%s' "$arr" | sha256sum | awk '{print $1}')"
  printf '[]\n' | _xkit_atomic_write "${XKIT_PLAN_STATE}.empty" || return 1
  rm -f "${XKIT_PLAN_STATE}.empty"
  local rows='[]'
  while IFS= read -r rec; do
    [ -z "$rec" ] && continue
    name="$(jq -r '.name' <<<"$rec")"; host="$(jq -r '.host' <<<"$rec")"; port="$(jq -r '.tunnel.port//443' <<<"$rec")"
    state=unknown; actual='null'; ck="$(mktemp /tmp/.xkit-node-ck.XXXXXX)" || continue
    if node_login "$rec" "$ck" >/dev/null 2>&1; then
      actual="$(node_api "$rec" panel/api/inbounds/list GET "" "$ck" 2>/dev/null | jq -c --argjson p "$port" '[.obj[]?|select(.port==$p and .protocol=="vless")][0]|if .==null then null else {port,protocol,enable:(.enable//true),remark} end' 2>/dev/null)"
      if [ "$(jq -r 'type' <<<"${actual:-null}" 2>/dev/null)" = object ]; then
        if [ "$(jq -r '.enable' <<<"$actual")" = true ]; then state=in-sync; else state=disabled; fi
      else state=missing; fi
    else state=api-unavailable; fi
    rm -f "$ck"
    rows="$(jq -c --arg name "$name" --arg host "$host" --argjson port "$port" --arg state "$state" --argjson actual "${actual:-null}" '. + [{name:$name,host:$host,port:$port,state:$state,actual:$actual}]' <<<"$rows")"
  done < <(jq -c '.[]' <<<"$arr")
  jq -nc --argjson ts "$(date +%s)" --arg hash "$hash" --argjson nodes "$rows" '{version:1,created:$ts,hash:$hash,status:"planned",canary:null,nodes:$nodes}' | _xkit_atomic_write "$XKIT_PLAN_STATE"
  printf '%s\n' "$rows"
}

nodes_plan() {
  local rows rc=0; rows="$(nodes_plan_collect)" || return 1
  if [ "${1:-}" = --json ]; then printf '%s\n' "$rows" | jq .; return 0; fi
  printf 'NODE\tHOST\tPORT\tSTATE\n'
  jq -r '.[]|[.name,.host,(.port|tostring),.state]|@tsv' <<<"$rows"
  jq -e 'all(.[];.state=="in-sync")' <<<"$rows" >/dev/null 2>&1 || rc=2
  audit_event nodes.plan master ok
  return "$rc"
}

nodes_apply_canary() {
  local want="${1:-}" rec rows hash state
  [ -n "$want" ] || { err "xkit nodes apply --canary <имя>"; return 1; }
  [ -r "$XKIT_PLAN_STATE" ] || { err "Сначала xkit nodes plan"; return 1; }
  rec="$(nodes_load | jq -c --arg n "$want" '[.[]|select(.name==$n)][0]//empty')"
  [ -n "$rec" ] || { err "Нода не найдена"; return 1; }
  hash="$(printf '%s' "$(nodes_load)" | sha256sum | awk '{print $1}')"
  [ "$hash" = "$(jq -r '.hash' "$XKIT_PLAN_STATE")" ] || { err "Реестр изменился после plan — повторите plan"; return 1; }
  log "Canary $want: TCP + SSH + API (без имитации client/DPI probe)"
  node_canary_probe "$rec" || { audit_event nodes.canary "$want" error; err "Canary не прошёл — apply не выполнен"; return 1; }
  jq -c '.status="canary-ok"|.canary=$n|.canary_at=$t' --arg n "$want" --argjson t "$(date +%s)" "$XKIT_PLAN_STATE" | _xkit_atomic_write "$XKIT_PLAN_STATE" || return 1
  audit_event nodes.canary "$want" ok
  ok "Canary $want прошёл. Продолжить: xkit nodes apply --remaining"
}

nodes_apply_remaining() {
  local hash
  [ -r "$XKIT_PLAN_STATE" ] || { err "Сначала plan и canary"; return 1; }
  [ "$(jq -r '.status' "$XKIT_PLAN_STATE")" = canary-ok ] || { err "Canary ещё не пройден"; return 1; }
  hash="$(printf '%s' "$(nodes_load)" | sha256sum | awk '{print $1}')"
  [ "$hash" = "$(jq -r '.hash' "$XKIT_PLAN_STATE")" ] || { err "Реестр изменился — повторите plan/canary"; return 1; }
  nodes_repair || { audit_event nodes.apply master error; return 1; }
  jq -c '.status="applied"|.applied_at=$t' --argjson t "$(date +%s)" "$XKIT_PLAN_STATE" | _xkit_atomic_write "$XKIT_PLAN_STATE"
  audit_event nodes.apply master ok canary
  ok "Каскадная конфигурация применена после canary"
}

node_token_set() {
  local want="${1:-}" token expires rec arr ck out
  [ -n "$want" ] || { err "xkit nodes token set <имя>"; return 1; }
  arr="$(nodes_load)"; rec="$(jq -c --arg n "$want" '[.[]|select(.name==$n)][0]//empty' <<<"$arr")"
  [ -n "$rec" ] || { err "Нода не найдена"; return 1; }
  read -r -s -p "Scoped API token для $want: " token || { echo; return 1; }; echo
  [[ "$token" =~ ^[A-Za-z0-9._~-]{20,512}$ ]] || { err "Токен пуст или имеет неподдерживаемый формат"; return 1; }
  read -r -p "Истекает DD.MM.YYYY или YYYY-MM-DD (Enter — не задан): " expires || return 1
  if [ -n "$expires" ] && ! [[ "$expires" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then err "Формат даты"; return 1; fi
  ck="$(mktemp /tmp/.xkit-node-ck.XXXXXX)" || return 1
  out="$(XKIT_NODE_API_TOKEN="$token" node_api "$rec" panel/api/inbounds/list GET "" "$ck" 2>/dev/null)"; rm -f "$ck"
  jq -e '.success==true' <<<"$out" >/dev/null 2>&1 || { err "Токен не принят панелью — реестр не изменён"; return 1; }
  rec="$(XKIT_NODE_TOKEN="$token" jq -c --arg e "$expires" '.panel.token=env.XKIT_NODE_TOKEN|.panel.token_expiry=(if $e=="" then null else $e end)' <<<"$rec")"
  local rec_file; rec_file="$(mktemp "${XKIT_DIR}/.node-record.XXXXXX")" || return 1
  chmod 600 "$rec_file"; printf '%s' "$rec" > "$rec_file"
  jq -c --arg n "$want" --slurpfile r "$rec_file" 'map(if .name==$n then $r[0] else . end)' <<<"$arr" | _xkit_atomic_write "$XKIT_NODES"
  local rc=$?; rm -f "$rec_file"; [ "$rc" -eq 0 ] || return 1
  audit_event nodes.token.set "$want" ok
  ok "Scoped token проверен и сохранён с mode 0600; старый пароль оставлен как fallback"
  [ -z "$(jq -r '.panel_node_id // empty' <<<"$rec")" ] || node_panel_sync "$want" || warn "Токен в «Узлах» 3X-UI не обновлён: xkit nodes panel-sync ${want}"
}

node_token_revoke_local() {
  local want="${1:-}" arr
  [ -n "$want" ] || return 1; arr="$(nodes_load)"
  jq -e --arg n "$want" 'any(.[];.name==$n)' <<<"$arr" >/dev/null || return 1
  jq -c --arg n "$want" 'map(if .name==$n then del(.panel.token,.panel.token_expiry) else . end)' <<<"$arr" | _xkit_atomic_write "$XKIT_NODES" || return 1
  audit_event nodes.token.remove "$want" ok
  warn "Токен удалён локально. Отзовите его в панели ноды отдельно — XKIT не считает локальное удаление отзывом"
}

#=========================== XKIT 7: SCANNER CSV / READ-ONLY BOT ==============

reality_scan_csv() {
  local in="${1:-${XKIT_DIR}/reality-scan.tsv}" out="${2:-${XKIT_DIR}/reality-scan.csv}"
  [ -r "$in" ] || { err "TSV не найден: $in"; return 1; }
  python3 - "$in" "$out" <<'PY'
import csv,sys
src,dst=sys.argv[1:3]
fields=['ip','tls13','h2','x25519','self_signed','cn','san','expires','verdict','issuer','tls_version','cipher','alpn']
with open(src,encoding='utf-8',errors='replace') as fi, open(dst+'.tmp','w',encoding='utf-8',newline='') as fo:
 w=csv.writer(fo); w.writerow(fields)
 for line in fi:
  row=line.rstrip('\n').split('\t'); row=(row+['']*len(fields))[:len(fields)]; w.writerow(row)
import os
os.replace(dst+'.tmp',dst)
PY
  chmod 600 "$out"; audit_event reality.scan.csv master ok
  ok "CSV сохранён: $out"
}

_tg_api_read() { # $1 method, $2 urlencoded data; token только в curl config stdin
  local method="$1" data="${2:-}" token="${XKIT_TG_TOKEN:-}"
  [[ "$token" =~ ^[0-9]{6,12}:[A-Za-z0-9_-]{30,46}$ ]] || return 1
  { printf 'request = "POST"\nurl = "https://api.telegram.org/bot%s/%s"\ndata = "%s"\n' "$token" "$method" "$data"; } \
    | curl -sf --max-time 15 -K - 2>/dev/null
}

telegram_bot_allowed() { # $1 numeric sender/chat id
  local id="$1" list="${XKIT_TG_ADMINS:-${XKIT_TG_CHAT:-}}" x
  [[ "$id" =~ ^-?[0-9]+$ ]] || return 1
  IFS=',' read -ra _tg_ids <<< "$list"
  for x in "${_tg_ids[@]}"; do [ "$id" = "$x" ] && return 0; done
  return 1
}

telegram_bot_status_text() {
  local nginx xui nodes_ok nodes_all
  nginx="$(systemctl is-active nginx 2>/dev/null || true)"; xui="$(systemctl is-active x-ui 2>/dev/null || true)"
  nodes_all="$(nodes_load 2>/dev/null | jq 'length' 2>/dev/null || echo 0)"
  nodes_ok=0
  if [ -r "$XKIT_NODES_METRICS" ]; then nodes_ok="$(jq '[.nodes[]?|select(.status=="ok")]|length' "$XKIT_NODES_METRICS" 2>/dev/null || echo 0)"; fi
  printf '[XKIT] Read-only status\nnginx: %s\n3X-UI: %s\nnodes: %s/%s ok\nversion: %s\n' "$nginx" "$xui" "$nodes_ok" "$nodes_all" "$XKIT_VERSION"
}

telegram_bot_once() {
  load_xkit_env >/dev/null 2>&1 || return 1
  [ -n "${XKIT_TG_TOKEN:-}" ] || { err "Сначала xkit telegram setup"; return 1; }
  local offset_file="${XKIT_DIR}/telegram-bot.offset" offset=0 updates row uid cid text msg key last now
  [ -r "$offset_file" ] && offset="$(cat "$offset_file")"
  [[ "$offset" =~ ^[0-9]+$ ]] || offset=0
  updates="$(_tg_api_read getUpdates "offset=${offset}&timeout=1&allowed_updates=%5B%22message%22%5D")" || return 1
  jq -e '.ok==true' <<<"$updates" >/dev/null 2>&1 || return 1
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    offset=$(( $(jq -r '.update_id' <<<"$row") + 1 ))
    uid="$(jq -r '.message.from.id//0' <<<"$row")"; cid="$(jq -r '.message.chat.id//0' <<<"$row")"
    text="$(jq -r '.message.text//""' <<<"$row")"
    if ! telegram_bot_allowed "$uid" || ! telegram_bot_allowed "$cid"; then continue; fi
    now="$(date +%s)"; key="bot:${uid}"; last="$(notify_state_get "$key")"
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    [ $((now-last)) -ge 5 ] || continue
    notify_state_set "$key" "$now"
    case "$text" in
      /status|/report) msg="$(telegram_bot_status_text)" ;;
      /start|/help) msg='[XKIT] Read-only bot. Команды: /status, /report. Управление и резервные копии отключены.' ;;
      *) msg='[XKIT] Только /status или /report.' ;;
    esac
    xkit_tg_send "$msg" >/dev/null 2>&1 || warn "Telegram bot: ответ не доставлен"
  done < <(jq -c '.result[]?|select(.message.text!=null)' <<<"$updates")
  printf '%s\n' "$offset" | _xkit_atomic_write "$offset_file"
}

telegram_bot_run() {
  log "Read-only Telegram bot запущен; Ctrl-C — остановить"
  while true; do telegram_bot_once || sleep 5; done
}

telegram_bot_service() {
  local action="${1:-status}" unit="${XKIT_TG_BOT_UNIT:-/etc/systemd/system/xkit-telegram-bot.service}"
  case "$action" in
    on)
      require_root; load_xkit_env >/dev/null 2>&1 || return 1
      [ -n "${XKIT_TG_TOKEN:-}" ] && [ -n "${XKIT_TG_CHAT:-}" ] || { err "Сначала telegram setup"; return 1; }
      cat > "$unit" <<EOF
[Unit]
Description=XKIT read-only Telegram bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${XKIT_BIN} telegram bot run
Restart=on-failure
RestartSec=10
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
      chmod 644 "$unit"; systemctl daemon-reload; systemctl enable --now xkit-telegram-bot.service
      audit_event telegram.bot.on master ok; ok "Read-only bot включён" ;;
    off)
      require_root; systemctl disable --now xkit-telegram-bot.service >/dev/null 2>&1 || true; rm -f "$unit"; systemctl daemon-reload
      audit_event telegram.bot.off master ok; ok "Read-only bot выключен" ;;
    status) systemctl status xkit-telegram-bot.service --no-pager 2>/dev/null || true ;;
    *) err "on|off|status"; return 1 ;;
  esac
}

# Обёртка CLI: только имя команды и код, никогда аргументы/секреты.
main() {
  local cmd="${1:-menu}" rc=0
  xkit_main_impl "$@" || rc=$?
  case "$cmd" in menu|""|snapshot|help|-h|--help) ;; *) audit_event "cli.${cmd}" master "$([ "$rc" -eq 0 ] && printf ok || printf error)" ;; esac
  return "$rc"
}

# Direct entry находится в последнем src-модуле после загрузки всех функций.

#=========================== XKIT 7.1: READDRESS / TRANSPORT PROFILES =========

XKIT_PROFILE_STATE="${XKIT_PROFILE_STATE:-${XKIT_DIR}/node-profile-state.json}"

node_record() { nodes_load | jq -c --arg n "$1" '[.[]|select(.name==$n)][0]//empty'; }
node_profile_name() { jq -r '.tunnel.profile // (.tunnel.proto // "vless-reality-vision")' <<<"$1"; }
node_profile_valid() { [[ "$1" =~ ^(vless-reality-vision|vless-xhttp-reality|hysteria2|amneziawg-external)$ ]]; }

node_readdress_host_key() { # старый record, новый IP; никаких новых TOFU при readdress
  local rec="$1" new="$2" old port kh oldkeys scan common
  old="$(jq -r '.host' <<<"$rec")"; port="$(jq -r '.ssh_port//22' <<<"$rec")"; kh="${XKIT_DIR}/known_hosts"
  oldkeys="$({ ssh-keygen -F "[$old]:$port" -f "$kh"; ssh-keygen -F "$old" -f "$kh"; } 2>/dev/null | awk '!/^#/ {print $2" "$3}' | sort -u)"
  [ -n "$oldkeys" ] || { err "Старый SSH host key не найден в known_hosts"; return 1; }
  scan="$(timeout 15 ssh-keyscan -T 8 -p "$port" "$new" 2>/dev/null | awk '!/^#/ {print $2" "$3}' | sort -u)"
  common="$(comm -12 <(printf '%s\n' "$oldkeys") <(printf '%s\n' "$scan"))"
  [ -n "$common" ]
}

node_readdress() { # name new-ip [--dry-run]
  local want="${1:-}" new="${2:-}" dry="${3:-}" arr rec testrec ck pin backup rc=0
  [ -n "$want" ] && [ -n "$new" ] || { err "xkit nodes readdress <имя> <новый-IP> [--dry-run]"; return 1; }
  is_ip "$new" || { err "Нужен числовой новый IP; смену домена выполняйте отдельно после DNS"; return 1; }
  arr="$(nodes_load)"; rec="$(jq -c --arg n "$want" '[.[]|select(.name==$n)][0]//empty' <<<"$arr")"
  [ -n "$rec" ] || { err "Нода не найдена"; return 1; }
  [ "$new" != "$(jq -r '.host' <<<"$rec")" ] || { ok "Адрес уже совпадает — изменений нет"; return 0; }
  if [ "$dry" = --dry-run ]; then
    jq -nc --arg n "$want" --arg old "$(jq -r '.host' <<<"$rec")" --arg new "$new" \
      '{node:$n,old_host:$old,new_host:$new,changes:["node registry","SSH/API endpoint","master outbound","certificate pin"],reinstall:false,certificate:"only if SAN/host requires",client_subscription:"unchanged for master-only cascade"}'
    return 0
  fi
  load_xkit_env || return 1
  testrec="$(jq -c --arg h "$new" '.host=$h|del(.panel.pincert)' <<<"$rec")"
  log "Preflight ${new}: SSH host key должен совпасть с прежним сервером; панельный сертификат проверяется заново"
  node_readdress_host_key "$rec" "$new" || { err "SSH host key нового IP не совпадает с уже доверенным ключом ноды"; return 1; }
  node_ssh "$testrec" 'true' || { err "SSH preflight не прошёл — реестр не изменён"; return 1; }
  ck="$(mktemp /tmp/.xkit-node-ck.XXXXXX)" || return 1
  node_login "$testrec" "$ck" >/dev/null 2>&1 || { rm -f "$ck"; err "API на новом адресе недоступен"; return 1; }
  node_api "$testrec" panel/api/inbounds/list GET "" "$ck" 2>/dev/null | jq -e '.success==true' >/dev/null || { rm -f "$ck"; err "API preflight не прошёл"; return 1; }
  rm -f "$ck"
  if [ "$(jq -r '.panel.tls//false' <<<"$rec")" = true ]; then
    pin="$(cert_pin "$new" "$(jq -r '.panel.port' <<<"$rec")")"
    [ -n "$pin" ] || { err "Не удалось проверить новый TLS pin — реестр не изменён"; return 1; }
    testrec="$(jq -c --arg p "$pin" '.panel.pincert=$p' <<<"$testrec")"
  fi
  backup="${XKIT_DIR}/readdress-${want}-$(date +%s).json"
  printf '%s\n' "$arr" | _xkit_atomic_write "$backup" || return 1
  local rf; rf="$(mktemp "${XKIT_DIR}/.readdress.XXXXXX")" || return 1; chmod 600 "$rf"; printf '%s' "$testrec" >"$rf"
  jq -c --arg n "$want" --slurpfile r "$rf" 'map(if .name==$n then $r[0] else . end)' <<<"$arr" | _xkit_atomic_write "$XKIT_NODES" || rc=$?
  rm -f "$rf"; [ "$rc" -eq 0 ] || return 1
  if ! nodes_apply_template; then
    warn "Master apply не прошёл — возвращаю прежний адрес"
    cp "$backup" "${XKIT_NODES}.rollback" && chmod 600 "${XKIT_NODES}.rollback" && mv "${XKIT_NODES}.rollback" "$XKIT_NODES"
    nodes_apply_template >/dev/null 2>&1 || true
    audit_event nodes.readdress "$want" error rollback
    return 1
  fi
  audit_event nodes.readdress "$want" ok
  ok "Адрес ноды изменён без переустановки. Snapshot: $backup"
  [ -z "$(jq -r '.panel_node_id // empty' <<<"$testrec")" ] || node_panel_sync "$want" || warn "Адрес в «Узлах» 3X-UI не обновлён: xkit nodes panel-sync ${want}"
  warn "REALITY не требует перевыпуска собственного сертификата; TLS/Hysteria сертификат обновляется только если старый IP входил в SAN"
}

node_profile_inbound_vless() { # rec profile port private-key -> JSON
  local rec="$1" profile="$2" port="$3" priv="$4" net=tcp flow="" path="" settings stream
  [ "$profile" = vless-xhttp-reality ] && { net=xhttp; path="/xkn-$(rand_hex 6)"; }
  [ "$profile" = vless-reality-vision ] && flow=xtls-rprx-vision
  settings="$(jq -nc --arg id "$(jq -r '.tunnel.uuid' <<<"$rec")" --arg n "$(jq -r '.name' <<<"$rec")" --arg f "$flow" --arg s "$(rand_hex 3)" \
    '{clients:[{id:$id,flow:$f,email:("tunnel-"+$n+"-"+$s),enable:true,limitIp:0,totalGB:0,expiryTime:0,reset:0}],decryption:"none",fallbacks:[]}')"
  stream="$(jq -nc --arg net "$net" --arg dest "$(jq -r '.tunnel.dest' <<<"$rec")" --arg sni "$(jq -r '.tunnel.sni' <<<"$rec")" \
    --arg priv "$priv" --arg sid "$(jq -r '.tunnel.sid' <<<"$rec")" --arg pub "$(jq -r '.tunnel.pbk' <<<"$rec")" --arg path "$path" \
    '{network:$net,security:"reality",realitySettings:{show:false,xver:0,dest:$dest,serverNames:[$sni],privateKey:$priv,shortIds:[$sid],settings:{publicKey:$pub,fingerprint:"chrome",serverName:""}}} + (if $net=="xhttp" then {xhttpSettings:{path:$path,mode:"auto"}} else {} end)')"
  jq -nc --argjson port "$port" --arg remark "xkit-tunnel-$(jq -r '.name' <<<"$rec")" --arg s "$settings" --arg st "$stream" \
    '{up:0,down:0,total:0,remark:$remark,enable:true,expiryTime:0,listen:"",port:$port,protocol:"vless",settings:$s,streamSettings:$st,sniffing:"{\"enabled\":false}",allocate:"{\"strategy\":\"always\",\"refresh\":5,\"concurrency\":-1}",tag:("inbound-"+($port|tostring))}'
}

node_profile_tunnel_vless() { # rec profile port private-key path-from-inbound
  local rec="$1" profile="$2" port="$3" priv="$4" ib="$5" net=tcp flow=xtls-rprx-vision path=""
  # v7.4.2: панели нод v3 отдают streamSettings объектом — толерантный разбор
  if [ "$profile" = vless-xhttp-reality ]; then net=xhttp; flow=""; path="$(jq -r '.streamSettings|if type=="string" then (fromjson? // {}) else (. // {}) end|.xhttpSettings.path // ""' <<<"$ib")"; fi
  jq -c --argjson port "$port" --arg net "$net" --arg flow "$flow" --arg path "$path" --arg priv "$priv" --arg profile "$profile" \
    '.tunnel={port:$port,proto:"vless",profile:$profile,net:$net,sec:"reality",uuid:.tunnel.uuid,pbk:.tunnel.pbk,sid:.tunnel.sid,sni:.tunnel.sni,dest:.tunnel.dest,flow:$flow,path:$path,reality_private:$priv}' <<<"$rec"
}

node_profile_hysteria_ib() { # rec port auth cert key -> inbound
  local rec="$1" port="$2" auth="$3" crt="$4" key="$5" settings stream
  settings="$(jq -nc --arg a "$auth" --arg n "$(jq -r '.name' <<<"$rec")" --arg s "$(rand_hex 3)" '{version:2,clients:[{email:("tunnel-"+$n+"-"+$s),auth:$a,enable:true,limitIp:0,totalGB:0,expiryTime:0,reset:0}]}')"
  stream="$(jq -nc --arg c "$crt" --arg k "$key" '{network:"hysteria",security:"tls",tlsSettings:{alpn:["h3"],certificates:[{certificateFile:$c,keyFile:$k}]},hysteriaSettings:{version:2}}')"
  jq -nc --argjson port "$port" --arg remark "xkit-tunnel-$(jq -r '.name' <<<"$rec")" --arg s "$settings" --arg st "$stream" \
    '{up:0,down:0,total:0,remark:$remark,enable:true,expiryTime:0,listen:"",port:$port,protocol:"hysteria",settings:$s,streamSettings:$st,sniffing:"{\"enabled\":false}",allocate:"{\"strategy\":\"always\",\"refresh\":5,\"concurrency\":-1}",tag:("inbound-"+($port|tostring))}'
}

node_profile_list() {
  local want="${1:-all}" arr; arr="$(nodes_load)"
  jq -r --arg n "$want" '.[]|select($n=="all" or .name==$n)|[.name,(.tunnel.profile//.tunnel.proto//"vless-reality-vision"),(.host),(.tunnel.port|tostring)]|@tsv' <<<"$arr"
  printf '%s\n' 'Доступно: vless-reality-vision, vless-xhttp-reality, hysteria2'
  printf '%s\n' 'amneziawg-external: только host-level туннель + явно проверенный outbound; Xray AWG outbound не существует'
}

node_profile_remote_port() { # rec tcp|udp [preferred] -> свободный preferred или случайный порт
  node_ssh "$1" python3 - _ "$2" "${3:-}" <<'PY'
import socket,sys
s=socket.socket(socket.AF_INET,socket.SOCK_STREAM if sys.argv[2]=="tcp" else socket.SOCK_DGRAM)
preferred=int(sys.argv[3]) if len(sys.argv)>3 and sys.argv[3] else 0
try: s.bind(("",preferred))
except OSError:
    if not preferred: raise
    s.bind(("",0))
print(s.getsockname()[1]); s.close()
PY
}

node_profile_fw() { # rec add|del port tcp|udp; только owned XKIT rule, UFW не включаем
  local rec="$1" op="$2" port="$3" proto="$4"
  if [ "$op" = add ]; then
    node_ssh "$rec" "if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then ufw allow ${port}/${proto} comment 'XKIT:node-profile' >/dev/null; fi"
  else
    node_ssh "$rec" "if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then ufw delete allow ${port}/${proto} >/dev/null 2>&1 || true; fi"
  fi
}

node_profile_switch() {
  local want="${1:-}" profile="${2:-}" probe="${3:-}" arr rec oldrec ck list oldib oldport priv port ib out newrec rf oldid newid rc=0 proto=tcp certpin="" certmade=0
  node_profile_valid "$profile" || { err "Неизвестный профиль"; return 1; }
  [ -z "$probe" ] || [ "$probe" = --probe ] || { err "Неизвестный режим profile switch"; return 1; }
  [ "$profile" != amneziawg-external ] || { err "AWG не является Xray outbound. Сначала нужен host-level туннель; автоматическое переключение отклонено, чтобы не создать нерабочий канал"; return 2; }
  arr="$(nodes_load)"; rec="$(jq -c --arg n "$want" '[.[]|select(.name==$n)][0]//empty' <<<"$arr")"; [ -n "$rec" ] || return 1
  [ "$(node_profile_name "$rec")" != "$profile" ] || { ok "Профиль уже активен"; return 0; }
  oldrec="$rec"; ck="$(mktemp /tmp/.xkit-node-ck.XXXXXX)" || return 1
  node_login "$rec" "$ck" || { rm -f "$ck"; return 1; }
  list="$(node_api "$rec" panel/api/inbounds/list GET "" "$ck")"; oldport="$(jq -r '.tunnel.port' <<<"$rec")"
  oldib="$(jq -c --argjson p "$oldport" '[.obj[]|select(.port==$p)][0]//empty' <<<"$list")"; [ -n "$oldib" ] || { rm -f "$ck"; err "Старый inbound не найден — switch отменён"; return 1; }
  [ "$profile" = hysteria2 ] && proto=udp
  port="$(node_profile_remote_port "$rec" "$proto" 443)" || { rm -f "$ck"; return 1; }
  is_port "$port" || { rm -f "$ck"; err "Не удалось выделить candidate port"; return 1; }
  case "$profile" in
    vless-*)
      priv="$(jq -r '.tunnel.reality_private//""' <<<"$rec")"
      [ -n "$priv" ] || priv="$(jq -r '.streamSettings|if type=="string" then (fromjson? // {}) else (. // {}) end|.realitySettings.privateKey//""' <<<"$oldib")"
      [ -n "$priv" ] || { rm -f "$ck"; err "REALITY private key не найден"; return 1; }
      ib="$(node_profile_inbound_vless "$rec" "$profile" "$port" "$priv")" ;;
    hysteria2)
      local auth crt key
      auth="$(rand_str 32)"; crt="/etc/xkit/node-hysteria-${want}.crt"; key="/etc/xkit/node-hysteria-${want}.key"
      local san; san="$(jq -r '.host' <<<"$rec")"; is_ip "$san" && san="IP:$san" || san="DNS:$san"
      node_ssh "$rec" "mkdir -p /etc/xkit && chmod 700 /etc/xkit && openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 -subj /CN=xkit-node -addext subjectAltName=$san -keyout '$key' -out '$crt' >/dev/null 2>&1 && chmod 600 '$key'" || { rm -f "$ck"; err "Не удалось создать сертификат Hysteria2 на ноде ($san)"; return 1; }
      certmade=1; certpin="$(node_ssh "$rec" "openssl x509 -in '$crt' -outform DER | openssl dgst -sha256 -binary | base64 -w0")"
      [ -n "$certpin" ] || { rm -f "$ck"; err "Не удалось рассчитать certificate pin Hysteria"; return 1; }
      ib="$(node_profile_hysteria_ib "$rec" "$port" "$auth" "$crt" "$key")"
      rec="$(jq -c --arg a "$auth" --arg c "$crt" --arg k "$key" --arg p "$certpin" '.tunnel.auth=$a|.tunnel.cert=$c|.tunnel.key=$k|.tunnel.tls_pin=$p' <<<"$rec")" ;;
  esac
  out="$(node_api "$rec" panel/api/inbounds/add POST "$ib" "$ck")"
  jq -e '.success==true' <<<"$out" >/dev/null || { rm -f "$ck"; err "Candidate inbound не создан"; return 1; }
  node_profile_fw "$rec" add "$port" "$proto" || { newid="$(node_api "$rec" panel/api/inbounds/list GET "" "$ck" | jq -r --argjson p "$port" '[.obj[]|select(.port==$p)][0].id//empty')"; [ -z "$newid" ] || node_api "$rec" "panel/api/inbounds/del/$newid" POST "" "$ck" >/dev/null 2>&1 || true; rm -f "$ck"; return 1; }
  if [ "$profile" = hysteria2 ]; then
    newrec="$(jq -c --argjson p "$port" --arg profile "$profile" '.tunnel.port=$p|.tunnel.proto="hysteria2"|.tunnel.profile=$profile|.tunnel.net="hysteria"|.tunnel.sec="tls"|.tunnel.sni=.host|.tunnel.insecure=true' <<<"$rec")"
  else newrec="$(node_profile_tunnel_vless "$rec" "$profile" "$port" "$priv" "$ib")"; fi
  rf="$(mktemp "${XKIT_DIR}/.profile.XXXXXX")"; chmod 600 "$rf"; printf '%s' "$newrec" >"$rf"
  jq -c --arg n "$want" --slurpfile r "$rf" 'map(if .name==$n then $r[0] else . end)' <<<"$arr" | _xkit_atomic_write "$XKIT_NODES" || rc=$?
  rm -f "$rf"
  if [ "$rc" -ne 0 ]; then
    newid="$(node_api "$rec" panel/api/inbounds/list GET "" "$ck" | jq -r --argjson p "$port" '[.obj[]|select(.port==$p)][0].id//empty')"
    [ -z "$newid" ] || node_api "$rec" "panel/api/inbounds/del/$newid" POST "" "$ck" >/dev/null 2>&1 || true
    node_profile_fw "$rec" del "$port" "$proto" >/dev/null 2>&1 || true; rm -f "$ck"; return 1
  fi
  if ! nodes_apply_template || ! node_profile_benchmark "$want" --quiet; then
    warn "Новый профиль не прошёл apply/benchmark — восстанавливаю реестр и старый канал"
    printf '%s' "$arr" | _xkit_atomic_write "$XKIT_NODES"; nodes_apply_template >/dev/null 2>&1 || true
    newid="$(node_api "$rec" panel/api/inbounds/list GET "" "$ck" | jq -r --argjson p "$port" '[.obj[]|select(.port==$p)][0].id//empty')"
    [ -z "$newid" ] || node_api "$rec" "panel/api/inbounds/del/$newid" POST "" "$ck" >/dev/null 2>&1 || true
    node_profile_fw "$rec" del "$port" "$proto" >/dev/null 2>&1 || true
    if [ "$certmade" = 1 ]; then node_ssh "$oldrec" "rm -f $(jq -r '.tunnel.cert' <<<"$rec") $(jq -r '.tunnel.key' <<<"$rec")" >/dev/null 2>&1 || true; fi
    rm -f "$ck"; audit_event nodes.profile.switch "$want" error rollback; return 1
  fi
  if [ "$probe" = --probe ]; then
    printf '%s' "$arr" | _xkit_atomic_write "$XKIT_NODES" && nodes_apply_template >/dev/null 2>&1 || { rm -f "$ck"; err "Probe завершён, но исходный канал не восстановлен"; return 1; }
    newid="$(node_api "$rec" panel/api/inbounds/list GET "" "$ck" | jq -r --argjson p "$port" '[.obj[]|select(.port==$p)][0].id//empty')"
    [ -z "$newid" ] || node_api "$rec" "panel/api/inbounds/del/$newid" POST "" "$ck" >/dev/null 2>&1 || true
    node_profile_fw "$rec" del "$port" "$proto" >/dev/null 2>&1 || true
    if [ "$certmade" = 1 ]; then node_ssh "$oldrec" "rm -f $(jq -r '.tunnel.cert' <<<"$rec") $(jq -r '.tunnel.key' <<<"$rec")" >/dev/null 2>&1 || true; fi
    rm -f "$ck"; audit_event nodes.profile.probe "$want" ok "$profile"; return 0
  fi
  oldid="$(jq -r '.id' <<<"$oldib")"; node_api "$rec" "panel/api/inbounds/del/$oldid" POST "" "$ck" >/dev/null || warn "Старый inbound #${oldid} не удалён — удалите после проверки"
  node_profile_fw "$oldrec" del "$oldport" "$([ "$(jq -r '.tunnel.proto' <<<"$oldrec")" = hysteria2 ] && printf udp || printf tcp)" >/dev/null 2>&1 || true
  rm -f "$ck"; audit_event nodes.profile.switch "$want" ok "$profile"
  ok "Активный профиль $want: $profile; постоянных candidate-инбаундов не осталось"
}

# Полный active-path benchmark: master loopback -> Xray node outbound -> node loopback HTTP.
node_profile_benchmark() {
  local want="${1:-}" quiet="${2:-}" rec rp lp metrics elapsed ms rtt bytes speed rc=0 orig="" merged applied=0 result
  load_xkit_env || return 1
  [ -n "${PANEL_PORT:-}" ] || kit_session || return 1
  rec="$(node_record "$want")"; [ -n "$rec" ] || return 1
  command -v python3 >/dev/null && command -v curl >/dev/null || return 1
  lp="$(rand_free_port 31000 59000)" || return 1
  rp="$(node_ssh "$rec" python3 - <<'PY'
import socket
s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()
PY
)" || return 1
  [[ "$rp" =~ ^[0-9]+$ ]] || return 1
  node_ssh "$rec" "set -e; rm -rf /run/xkit-node-bench; mkdir -p /run/xkit-node-bench; dd if=/dev/zero of=/run/xkit-node-bench/payload bs=1M count=8 status=none; nohup python3 -m http.server $rp --bind 127.0.0.1 --directory /run/xkit-node-bench </dev/null >/run/xkit-node-bench/server.log 2>&1 & p=\$!; printf '%s\n' \"\$p\" >/run/xkit-node-bench.pid" || return 1
  orig="$(master_xray_template_get)" || { node_profile_bench_cleanup "$rec"; return 1; }
  # Любой выход/сигнал восстанавливает исходный master template и убирает HTTP server.
  trap 'if [ "${applied:-0}" = 1 ]; then master_xray_template_set "$orig" >/dev/null 2>&1 || true; fi; node_profile_bench_cleanup "$rec"' RETURN INT TERM
  merged="$(printf '%s' "$orig" | node_probe_merge "$lp" "$rp" "$(jq -r '.outbound_tag//("node-"+.name)' <<<"$rec")")" || rc=1
  if [ "$rc" -eq 0 ]; then master_xray_template_set "$merged" && applied=1 || rc=1; fi
  if [ "$rc" -eq 0 ]; then
    sleep 2
    metrics="$(curl -fsS --max-time 25 -o /dev/null -w '%{time_starttransfer} %{time_total}' "http://127.0.0.1:${lp}/payload")" || rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    rtt="$(awk '{printf "%d",$1*1000}' <<<"$metrics")"
    elapsed="$(awk '{printf "%d",$2*1000}' <<<"$metrics")"
    [ "$elapsed" -gt 0 ] || elapsed=1; bytes=8388608; speed=$((bytes*8*1000/elapsed/1000000)); ms="$elapsed"
  fi
  if [ "$applied" = 1 ]; then master_xray_template_set "$orig" >/dev/null 2>&1 || { err "Не удалось восстановить master template после benchmark"; rc=1; }; applied=0; fi
  node_profile_bench_cleanup "$rec"; trap - RETURN INT TERM
  [ "$rc" -eq 0 ] || { [ "$quiet" = --quiet ] || err "Full-path benchmark не прошёл"; return 1; }
  result="$(jq -nc --arg n "$want" --arg profile "$(node_profile_name "$rec")" --argjson rtt "$rtt" --argjson ms "$ms" --argjson mbps "$speed" '{node:$n,profile:$profile,rtt_ms:$rtt,total_ms:$ms,download_mbps:$mbps,bytes:8388608,scope:"master->node full active path",dpi_test:false}')"
  printf '%s\n' "$result" | _xkit_atomic_write "${XKIT_DIR}/benchmark-${want}.json" || return 1
  [ "$quiet" = --quiet ] || { ok "Полный каскад: RTT ${rtt} ms, 8 MiB за ${ms} ms, ~${speed} Mbps (не DPI test)"; printf '%s\n' "$result"; }
}

node_profile_survey() {
  local want="${1:-}" rec current p row results='[]' report choice rc
  rec="$(node_record "$want")"; [ -n "$rec" ] || { err "Нода не найдена"; return 1; }
  current="$(node_profile_name "$rec")"
  warn "Проверка временно применяет candidate и возвращает исходный канал после каждого замера"
  for p in vless-reality-vision vless-xhttp-reality hysteria2; do
    log "Проверка $p"
    if [ "$p" = "$current" ]; then node_profile_benchmark "$want" --quiet; else node_profile_switch "$want" "$p" --probe; fi
    rc=$?
    if [ "$rc" -eq 0 ] && row="$(jq -c '. + {ok:true}' "${XKIT_DIR}/benchmark-${want}.json" 2>/dev/null)"; then
      results="$(jq -c --argjson r "$row" '. + [$r]' <<<"$results")"
    else
      row="$(jq -nc --arg p "$p" '{profile:$p,ok:false}')"; results="$(jq -c --argjson r "$row" '. + [$r]' <<<"$results")"
    fi
  done
  report="$(jq -nc --arg n "$want" --argjson r "$results" '{node:$n,results:$r,scope:"master->node full path; 8 MiB",dpi_test:false}')"
  printf '%s\n' "$report" | _xkit_atomic_write "${XKIT_DIR}/profile-survey-${want}.json" || return 1
  printf '\n%-4s %-25s %-10s %-10s %-12s\n' '№' 'ПРОФИЛЬ' 'СТАТУС' 'RTT, ms' 'СКОРОСТЬ'
  jq -r '.results[]|[.profile,(if .ok then "РАБОТАЕТ" else "НЕ РАБОТАЕТ" end),(.rtt_ms//"-"|tostring),(if .ok then ((.download_mbps|tostring)+" Mbps") else "-" end)]|@tsv' <<<"$report" | \
    while IFS=$'\t' read -r p st rtt speed; do printf '%-4s %-25s %-10s %-10s %-12s\n' '-' "$p" "$st" "$rtt" "$speed"; done
  mapfile -t choices < <(jq -r '.results[]|select(.ok)|.profile' <<<"$report")
  [ "${#choices[@]}" -gt 0 ] || { err "Ни один профиль не прошёл полную передачу данных; исходный канал сохранён"; return 1; }
  [ -t 0 ] || { ok "Отчёт сохранён; для переключения: xkit nodes profile switch $want <профиль>"; return 0; }
  echo ""; echo ' 0) Не переключать'
  local i; for i in "${!choices[@]}"; do printf ' %d) %s\n' "$((i+1))" "${choices[$i]}"; done
  read -r -p 'Профиль для переключения: ' choice || return 0
  [ "$choice" != 0 ] || return 0
  [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -le "${#choices[@]}" ] || { err "Неверный выбор — ничего не изменено"; return 1; }
  node_profile_switch "$want" "${choices[$((choice-1))]}"
}

node_profile_bench_cleanup() { node_ssh "$1" "p=\$(cat /run/xkit-node-bench.pid 2>/dev/null || true); case \"\$p\" in ''|*[!0-9]*) ;; *) kill \"\$p\" 2>/dev/null || true ;; esac; rm -rf /run/xkit-node-bench /run/xkit-node-bench.pid" >/dev/null 2>&1 || true; }

node_probe_merge() { # stdin=template; local-port remote-port active-tag
  # FIX (аудит): было `python3 - "$@" <<'PY'` — heredoc занимал stdin, из-за чего
  # шаблон из пайпа не доходил до json.load(sys.stdin) (EOF -> JSONDecodeError).
  # Программа перенесена в -c: stdin теперь остаётся входным шаблоном.
  python3 -c '
import json,sys
c=json.load(sys.stdin); lp=int(sys.argv[1]); rp=int(sys.argv[2]); tag=sys.argv[3]
c.setdefault("inbounds",[]).append({"listen":"127.0.0.1","port":lp,"protocol":"dokodemo-door","tag":"xkit-profile-probe","settings":{"address":"127.0.0.1","port":rp,"network":"tcp"}})
r=c.setdefault("routing",{}).setdefault("rules",[])
r.insert(0,{"type":"field","inboundTag":["xkit-profile-probe"],"outboundTag":tag})
print(json.dumps(c,separators=(",",":")))
' "$@"
}

master_xray_template_get() {
  local resp
  if [ "$API_V3" = 1 ]; then resp="$(api_post_json panel/api/xray/ '{}')"; jq -c '.obj|if type=="string" then fromjson else . end|.xraySetting//{}|if type=="string" then fromjson else . end' <<<"$resp"
  else resp="$(panel_settings_get)"; jq -c '.obj.xrayTemplateConfig//{}|if type=="string" then fromjson else . end' <<<"$resp"; fi
}
master_xray_template_set() {
  local body="$1" resp
  if [ "$API_V3" = 1 ]; then resp="$(api_post_form panel/api/xray/update "xraySetting=${body}")"; jq -e '.success==true' <<<"$resp" >/dev/null
  else panel_settings_set "xrayTemplateConfig=${body}"; fi || return 1
  xray_restart
}

node_tune() {
  local want="$1" mode="${2:-show}" rec
  rec="$(node_record "$want")"; [ -n "$rec" ] || return 1
  case "$mode" in
    show) node_ssh "$rec" 'sysctl net.core.default_qdisc net.ipv4.tcp_congestion_control net.core.rmem_max net.core.wmem_max 2>/dev/null' ;;
    safe) node_ssh "$rec" 'rm -f /etc/sysctl.d/90-xkit-node.conf; systemctl restart systemd-sysctl >/dev/null 2>&1 || true' ;;
    balanced)
      node_ssh "$rec" 'set -e; grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; printf "%s\n" "net.core.default_qdisc=fq" "net.ipv4.tcp_congestion_control=bbr" "net.core.rmem_max=16777216" "net.core.wmem_max=16777216" "net.core.netdev_max_backlog=4096" > /etc/sysctl.d/90-xkit-node.conf; chmod 644 /etc/sysctl.d/90-xkit-node.conf; sysctl --system >/dev/null' ;;
    *) err "nodes tune <имя> show|safe|balanced"; return 1 ;;
  esac
  audit_event nodes.tune "$want" ok "$mode"
}

#=========================== XKIT 7.1: TELEGRAM MTPROTO / WEB PROXY ===========
# SOCKS5/HTTP proxy намеренно отсутствуют. MTProto — только FakeTLS (ee...).

XKIT_TGPROXIES="${XKIT_TGPROXIES:-${XKIT_DIR}/telegram-proxies.json}"

tgproxy_load() { if [ -s "$XKIT_TGPROXIES" ] && jq -e 'type=="array"' "$XKIT_TGPROXIES" >/dev/null 2>&1; then cat "$XKIT_TGPROXIES"; else printf '[]'; fi; }
tgproxy_save() { _xkit_atomic_write "$XKIT_TGPROXIES"; }
tgproxy_faketls_secret() { local d="$1"; printf 'ee%s%s' "$(rand_hex 16)" "$(printf '%s' "$d" | od -An -tx1 | tr -d ' \n')"; }
tgproxy_valid_domain() { is_domain "$1" && [[ "$1" =~ ^[a-z0-9.-]+$ ]]; }
tgproxy_target_rec() { [ "$1" = master ] || node_record "$1"; }

tgproxy_mtproto_ib() { # target port listen domain secret
  local target="$1" port="$2" listen="$3" domain="$4" secret="$5" settings
  settings="$(jq -nc --arg d "$domain" --arg s "$secret" --arg e "xkit-tg-${target}" \
    '{fakeTlsDomain:$d,clients:[{email:$e,secret:$s,enable:true,limitIp:0,totalGB:0,expiryTime:0,reset:0}]}')"
  jq -nc --argjson p "$port" --arg l "$listen" --arg r "xkit-tg-mtproto-${target}" --arg s "$settings" \
    '{up:0,down:0,total:0,remark:$r,enable:true,expiryTime:0,listen:$l,port:$p,protocol:"mtproto",settings:$s,streamSettings:"{}",sniffing:"{\"enabled\":false}",allocate:"{\"strategy\":\"always\",\"refresh\":5,\"concurrency\":-1}",tag:$r}'
}

tgproxy_mtproto_install() {
  local target="${1:-}" mode="${2:-direct}" port="${3:-}" domain="${4:-}" public="${5:-}" rec ib secret listen out arr ck="" host link pubhost ibid="" orig="" fwport="" created=0
  [ -n "$target" ] && is_port "${port:-0}" && tgproxy_valid_domain "${domain:-}" || { err "tg-proxy mtproto <master|нода> direct|cascade <port> <fake-domain> [public-port]"; return 1; }
  [[ "$mode" =~ ^(direct|cascade)$ ]] || return 1
  [ "$mode" = direct ] || [ "$target" != master ] || { err "Cascade требует exit-ноду"; return 1; }
  [ "$mode" != cascade ] || is_port "${public:-0}" || { err "Для cascade заранее укажите public-port мастера"; return 1; }
  tgproxy_load | jq -e --arg t "$target" 'all(.[];.type!="mtproto" or .target!=$t)' >/dev/null || { err "MTProto для цели уже управляется XKIT"; return 1; }
  load_xkit_env || return 1; rec="$(tgproxy_target_rec "$target")"; [ "$target" = master ] || [ -n "$rec" ] || return 1
  [ "$mode" != cascade ] || orig="$(master_xray_template_get)" || return 1
  secret="$(tgproxy_faketls_secret "$domain")"; listen=""; [ "$mode" = cascade ] && listen=127.0.0.1
  ib="$(tgproxy_mtproto_ib "$target" "$port" "$listen" "$domain" "$secret")"
  if [ "$target" = master ]; then
    kit_session || return 1; out="$(api_post add "$ib")"
  else
    ck="$(mktemp /tmp/.xkit-node-ck.XXXXXX)" || return 1; node_login "$rec" "$ck" || { rm -f "$ck"; return 1; }
    out="$(node_api "$rec" panel/api/inbounds/add POST "$ib" "$ck")"
  fi
  jq -e '.success==true' <<<"$out" >/dev/null || { [ -z "$ck" ] || rm -f "$ck"; err "3X-UI не приняла MTProto FakeTLS — проверьте pinned capability"; return 1; }
  created=1
  if [ "$mode" = direct ]; then
    public="$port"; pubhost="$([ "$target" = master ] && printf '%s' "$XKIT_HOST" || jq -r '.host' <<<"$rec")"
    if [ "$target" = master ]; then xkit_fw_add tg-mtproto "$port" tcp && fwport="$port" || true; else node_ssh "$rec" "if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then ufw allow $port/tcp comment 'XKIT:tg-mtproto'; fi" && fwport="$port" || true; fi
  else
    pubhost="$XKIT_HOST"
    tgproxy_cascade_add "$public" "$port" "$(jq -r '.outbound_tag//("node-"+.name)' <<<"$rec")" && xkit_fw_add tg-mtproto "$public" tcp && fwport="$public" || true
  fi
  if [ "$mode" = cascade ] && [ -z "$fwport" ] || [ "$mode" = direct ] && [ -z "$fwport" ]; then
    warn "Не удалось завершить firewall/relay — откатываю MTProto inbound"
    [ -z "$orig" ] || master_xray_template_set "$orig" >/dev/null 2>&1 || true
    tgproxy_mtproto_delete_ib "$target" "$rec" "$port" "$ck" >/dev/null 2>&1 || true
    [ -z "$ck" ] || rm -f "$ck"; return 1
  fi
  host="$pubhost"; link="tg://proxy?server=${host}&port=${public}&secret=${secret}"
  arr="$(tgproxy_load | jq -c --arg t mtproto --arg target "$target" --arg mode "$mode" --argjson port "$port" --argjson public "$public" --arg host "$host" --arg secret "$secret" --arg domain "$domain" --arg link "$link" '. + [{type:$t,target:$target,mode:$mode,port:$port,public_port:$public,host:$host,secret:$secret,fake_domain:$domain,link:$link,created:(now|floor)}]')"
  if ! printf '%s' "$arr" | tgproxy_save; then
    [ -z "$orig" ] || master_xray_template_set "$orig" >/dev/null 2>&1 || true
    tgproxy_mtproto_delete_ib "$target" "$rec" "$port" "$ck" >/dev/null 2>&1 || true
    [ -z "$fwport" ] || { [ "$target" = master ] || [ "$mode" = cascade ]; } && xkit_fw_remove tg-mtproto "$fwport" tcp >/dev/null 2>&1 || true
    [ -z "$ck" ] || rm -f "$ck"; return 1
  fi
  [ -z "$ck" ] || rm -f "$ck"
  audit_event telegram.mtproto.install "$target" ok "$mode"
  ok "MTProto FakeTLS установлен; статус процесса не является Telegram client/DPI test"
  printf '%s\n' "$link"
}

tgproxy_mtproto_delete_ib() { # target rec port cookie — только XKIT-owned inbound
  local target="$1" rec="$2" port="$3" ck="$4" list id
  if [ "$target" = master ]; then
    list="$(api_list)"; id="$(jq -r --argjson p "$port" '[.[]|select(.port==$p and .remark==("xkit-tg-mtproto-master"))][0].id//empty' <<<"$list")"
    [ -z "$id" ] || api_del_inbound "$id"
  else
    list="$(node_api "$rec" panel/api/inbounds/list GET "" "$ck")"; id="$(jq -r --argjson p "$port" '[.obj[]|select(.port==$p and .remark==("xkit-tg-mtproto-"+$target))][0].id//empty' --arg target "$target" <<<"$list")"
    [ -z "$id" ] || node_api "$rec" "panel/api/inbounds/del/$id" POST "" "$ck"
  fi
}

tgproxy_cascade_add() { # public local target-port outbound-tag
  local pub="$1" remote="$2" tag="$3" cur merged
  cur="$(master_xray_template_get)" || return 1
  merged="$(printf '%s' "$cur" | python3 -c 'import json,sys; c=json.load(sys.stdin); p=int(sys.argv[1]); r=int(sys.argv[2]); tag=sys.argv[3]; c.setdefault("inbounds",[]).append({"listen":"0.0.0.0","port":p,"protocol":"dokodemo-door","tag":"xkit-tg-mtproto-relay","settings":{"address":"127.0.0.1","port":r,"network":"tcp"}}); c.setdefault("routing",{}).setdefault("rules",[]).insert(0,{"type":"field","inboundTag":["xkit-tg-mtproto-relay"],"outboundTag":tag}); print(json.dumps(c,separators=(",",":")))' "$pub" "$remote" "$tag")" || return 1
  master_xray_template_set "$merged"
}

tgproxy_list() {
  tgproxy_load | jq -r '.[]|[.type,.target,.mode,.host,(.public_port|tostring),(.fake_domain//.base_path//"")]|@tsv'
}
tgproxy_link() { tgproxy_load | jq -r --arg t "$1" '.[]|select(.type==$t)|.link//empty'; }

tgproxy_web_link() { # stdin secret, host path -> stdout link
  python3 - "$1" "$2" <<'PY'
import sys,base64,urllib.parse
secret=sys.stdin.read().strip(); address=sys.argv[1]+'/'+sys.argv[2]
marked=base64.urlsafe_b64encode(b'\x70'+bytes.fromhex(secret)).decode().rstrip('=')
print('tg://webproxy?server='+urllib.parse.quote(address,safe='')+'&secret='+marked)
PY
}

tgproxy_web_install() {
  local target="${1:-}" mode="${2:-}" hostname="${3:-}" carrier="${4:-websocket-lanes}" commit="${5:-}" sha="${6:-}" rec secret slug link lp cur merged arr
  [ -n "$target" ] && [[ "$mode" =~ ^(direct|cascade)$ ]] && tgproxy_valid_domain "${hostname:-}" || { err "tg-proxy web <нода> direct|cascade <hostname> [carrier] <pinned-commit> <archive-sha256>"; return 1; }
  [[ "$carrier" =~ ^(https|https-lanes|websocket|websocket-lanes)$ ]] || return 1
  [[ "$commit" =~ ^[0-9a-f]{40}$ && "$sha" =~ ^[0-9a-f]{64}$ ]] || { err "Web Proxy требует pinned commit и SHA-256 архива; latest запрещён"; return 1; }
  [ "$mode" = cascade ] && [ "$target" != master ] || [ "$mode" = direct ] || { err "Cascade Web Proxy устанавливается на exit-ноду"; return 1; }
  tgproxy_load | jq -e --arg t "$target" 'all(.[];.type!="web" or .target!=$t)' >/dev/null || { err "Web Proxy для цели уже управляется XKIT"; return 1; }
  load_xkit_env || return 1; rec="$(tgproxy_target_rec "$target")"; [ "$target" = master ] || [ -n "$rec" ] || return 1
  secret="$(rand_hex 16)"; slug="$(head -c 10 /dev/urandom | base32 | tr 'A-Z' 'a-z')"
  if [ "$mode" = direct ]; then
    [ "$target" != master ] || { err "Direct Web Proxy на master используйте как cascade только с exit-нодой; не перехватываем существующий nginx"; return 1; }
    node_ssh "$rec" 'test "$(uname -m)" = x86_64 && ! ss -ltn | grep -Eq ":(80|443) " && ! systemctl is-active --quiet caddy && ! test -e /etc/caddy/Caddyfile' || { err "Direct Web Proxy требует выделенную x86_64 ноду без Caddy/сайтов и со свободными 80/443"; return 1; }
    [ -f /var/www/camo/index.html ] || { err "Direct: сначала создайте camo-сайт на master (/var/www/camo/index.html)"; return 1; }
    tar -C /var/www/camo -cf - . | node_ssh "$rec" 'install -d -m 755 /var/lib/xkit-tproxy-site && tar -C /var/lib/xkit-tproxy-site -xf -' || { err "Не удалось передать camo-сайт на direct-ноду"; return 1; }
    tgproxy_web_remote_direct "$rec" "$hostname" "$secret" "$slug" "$carrier" "$commit" "$sha" || return 1
  else
    tgproxy_web_remote_cascade "$rec" "$hostname" "$secret" "$slug" "$carrier" "$commit" "$sha" || return 1
    lp="$(rand_free_port 31000 59000)" || { tgproxy_web_remote_uninstall "$rec"; return 1; }
    cur="$(master_xray_template_get)" || { tgproxy_web_remote_uninstall "$rec"; return 1; }
    merged="$(printf '%s' "$cur" | python3 -c 'import json,sys; c=json.load(sys.stdin); p=int(sys.argv[1]); tag=sys.argv[2]; c.setdefault("inbounds",[]).append({"listen":"127.0.0.1","port":p,"protocol":"dokodemo-door","tag":"xkit-tg-web-relay","settings":{"address":"127.0.0.1","port":8080,"network":"tcp"}}); c.setdefault("routing",{}).setdefault("rules",[]).insert(0,{"type":"field","inboundTag":["xkit-tg-web-relay"],"outboundTag":tag}); print(json.dumps(c,separators=(",",":")))' "$lp" "$(jq -r '.outbound_tag//("node-"+.name)' <<<"$rec")")" || { tgproxy_web_remote_uninstall "$rec"; return 1; }
    if ! master_xray_template_set "$merged"; then tgproxy_web_remote_uninstall "$rec"; return 1; fi
    routes_upsert "tg-web-${target}" relay tgweb "/${slug}/" "127.0.0.1:${lp}" "xkit-tg-web"
    if ! regen_conf_and_apply; then
      master_xray_template_set "$cur" >/dev/null 2>&1 || true; routes_del "tg-web-${target}"; regen_conf_and_apply >/dev/null 2>&1 || true
      tgproxy_web_remote_uninstall "$rec"; return 1
    fi
  fi
  link="$(printf '%s' "$secret" | tgproxy_web_link "$hostname" "$slug")"
  arr="$(tgproxy_load | jq -c --arg t web --arg target "$target" --arg mode "$mode" --arg host "$hostname" --arg secret "$secret" --arg path "$slug" --arg carrier "$carrier" --arg link "$link" --arg commit "$commit" '. + [{type:$t,target:$target,mode:$mode,host:$host,public_port:443,secret:$secret,base_path:$path,carrier:$carrier,link:$link,commit:$commit,created:(now|floor)}]')"
  if ! printf '%s' "$arr" | tgproxy_save; then
    if [ "$mode" = cascade ]; then [ -z "${cur:-}" ] || master_xray_template_set "$cur" >/dev/null 2>&1 || true; routes_del "tg-web-${target}"; regen_conf_and_apply >/dev/null 2>&1 || true; tgproxy_web_remote_uninstall "$rec"; fi
    return 1
  fi
  audit_event telegram.web.install "$target" ok "$mode"
  ok "Telegram Web Proxy установлен из pinned source. Health/ready проверены; реальный WEB client test остаётся обязательным"
  printf '%s\n' "$link"
}

tgproxy_web_remote_uninstall() { # только rollback новой cascade-установки XKIT
  node_ssh "$1" 'systemctl disable --now tproxy-server mtproxy mtproxy-config-refresh.timer refresh-mtproxy-config.timer tproxy-firewall >/dev/null 2>&1 || true; rm -rf /etc/tproxy-server /etc/mtproxy; rm -f /etc/systemd/system/tproxy-server.service /etc/systemd/system/tproxy-firewall.service /etc/systemd/system/mtproxy.service /etc/systemd/system/mtproxy-config-refresh.service /etc/systemd/system/mtproxy-config-refresh.timer /usr/local/bin/tproxy-server; systemctl daemon-reload' >/dev/null 2>&1 || true
}

tgproxy_web_remote_direct() { # rec host secret slug carrier commit sha; секреты только stdin remote bash
  local rec="$1" h="$2" s="$3" slug="$4" carrier="$5" commit="$6" sha="$7"
  node_ssh "$rec" 'bash -s' <<EOS
set -euo pipefail
umask 077
W=/var/tmp/xkit-tproxy-install; rm -rf "\$W"; mkdir -p "\$W"; chmod 700 "\$W"
curl -fsSL --proto '=https' --proto-redir '=https' 'https://github.com/telegramdesktop/tproxy-server/archive/${commit}.tar.gz' -o "\$W/src.tgz"
printf '%s  %s\n' '${sha}' "\$W/src.tgz" | sha256sum -c -
tar -xzf "\$W/src.tgz" -C "\$W" --strip-components=1
cd "\$W"
printf '%s\n' '${s}' | bash deploy/install.sh --hostname '${h}' --email 'admin@${h}' --base-path '${slug}' --site-dir /var/lib/xkit-tproxy-site
systemctl is-active --quiet caddy tproxy-server mtproxy tproxy-firewall
printf '%s' '{"profiles":[{"name":"default","secret":"${s}","backend":"127.0.0.1:2398","carrier_mode":"${carrier}"}]}' >/etc/tproxy-server/profiles.json; chmod 400 /etc/tproxy-server/profiles.json
/usr/local/bin/tproxy-server -check -config /etc/tproxy-server/config.json
systemctl restart tproxy-server
curl -fsS http://127.0.0.1:8081/readyz >/dev/null
cd /; rm -rf "\$W"
EOS
}

tgproxy_web_remote_cascade() {
  local rec="$1" h="$2" s="$3" slug="$4" carrier="$5" commit="$6" sha="$7"
  node_ssh "$rec" 'bash -s' <<EOS
set -euo pipefail
umask 077
test "\$(uname -m)" = x86_64
test -d /var/www/camo
! systemctl list-unit-files | grep -Eq '^(tproxy-server|mtproxy|tproxy-firewall)\.service'
! ss -ltn | grep -Eq ':(8080|8081|2398|8888) '
W=/var/tmp/xkit-tproxy-install; rm -rf "\$W"; mkdir -p "\$W"; chmod 700 "\$W"
trap 'systemctl disable --now tproxy-server mtproxy mtproxy-config-refresh.timer refresh-mtproxy-config.timer tproxy-firewall >/dev/null 2>&1 || true; rm -rf /etc/tproxy-server /etc/mtproxy "\$W"' ERR
export DEBIAN_FRONTEND=noninteractive; apt-get update -qq; apt-get install -y -qq golang-go git nftables >/dev/null
curl -fsSL --proto '=https' --proto-redir '=https' 'https://github.com/telegramdesktop/tproxy-server/archive/${commit}.tar.gz' -o "\$W/src.tgz"
printf '%s  %s\n' '${sha}' "\$W/src.tgz" | sha256sum -c -
tar -xzf "\$W/src.tgz" -C "\$W" --strip-components=1
cd "\$W"; go test ./...; go build -trimpath -o /usr/local/bin/tproxy-server.new ./cmd/tproxy-server; chmod 755 /usr/local/bin/tproxy-server.new; mv /usr/local/bin/tproxy-server.new /usr/local/bin/tproxy-server
bash deploy/install-mtproxy.sh
id tproxy >/dev/null 2>&1 || useradd --system --home /nonexistent --shell /usr/sbin/nologin tproxy
install -d -m 700 /etc/tproxy-server
install -m 644 deploy/tproxy-server.service /etc/systemd/system/tproxy-server.service
install -m 644 deploy/tproxy-firewall.service /etc/systemd/system/tproxy-firewall.service
install -m 644 deploy/mtproxy.service /etc/systemd/system/mtproxy.service
if test -f deploy/refresh-mtproxy-config.service; then R=refresh-mtproxy-config; else R=mtproxy-config-refresh; fi
test -f "deploy/\$R.service"; test -f "deploy/\$R.timer"; test -x "deploy/\$R.sh" || test -f "deploy/\$R.sh"
install -m 644 "deploy/\$R.service" "/etc/systemd/system/\$R.service"
install -m 644 "deploy/\$R.timer" "/etc/systemd/system/\$R.timer"
install -m 644 deploy/firewall.nft /etc/tproxy-server/firewall.nft
LOCAL_IP="\$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if(\$i=="src"){print \$(i+1);exit}}')"
PUBLIC_IP="\$(curl -4 -fsS --max-time 10 https://api.ipify.org)"
test -n "\$LOCAL_IP"; test -n "\$PUBLIC_IP"
NAT_ARGS=""
if test -n "\$LOCAL_IP" && test -n "\$PUBLIC_IP" && test "\$LOCAL_IP" != "\$PUBLIC_IP"; then NAT_ARGS="--nat-info \$LOCAL_IP:\$PUBLIC_IP"; fi
printf 'MTPROXY_SECRET=%s\nMTPROXY_WORKERS=1\nMTPROXY_MAX_CONNECTIONS=4096\nMTPROXY_NAT_ARGS=%s\n' '${s}' "\$NAT_ARGS" >/etc/mtproxy/mtproxy.env; chmod 600 /etc/mtproxy/mtproxy.env
bash deploy/ensure-token-key.sh
printf '%s' '{"profiles":[{"name":"default","secret":"${s}","backend":"127.0.0.1:2398","carrier_mode":"${carrier}"}]}' >/etc/tproxy-server/profiles.json; chmod 400 /etc/tproxy-server/profiles.json
printf '%s' '{"public_hostname":"${h}","base_path":"${slug}","listen":"127.0.0.1:8080","admin_listen":"127.0.0.1:8081","public_dir":"/var/www/camo","token_key_file":"/etc/tproxy-server/token.key","static_routes":"exact","profiles_file":"/run/credentials/tproxy-server.service/profiles.json","enable_pprof":false}' >/etc/tproxy-server/config.json; chmod 600 /etc/tproxy-server/config.json
systemctl daemon-reload; systemctl enable --now tproxy-firewall mtproxy "$R.timer" tproxy-server
sleep 3; systemctl is-active --quiet tproxy-firewall mtproxy tproxy-server; systemctl is-enabled --quiet "\$R.timer"; curl -fsS http://127.0.0.1:8081/readyz >/dev/null
trap - ERR; cd /; rm -rf "\$W"
EOS
}

generate_tgweb_block() { # path target
  cat <<EOF

    # Telegram Web Proxy: no URI/header/body logging, long-poll + WSS
    location ^~ $1 {
        client_max_body_size 4m;
        access_log off;
        proxy_pass http://$2;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_read_timeout 90s;
        proxy_send_timeout 90s;
        proxy_buffering off;
        proxy_request_buffering off;
    }
EOF
}

tgproxy_menu() {
  printf '%s\n' 'Telegram proxy: 1) MTProto FakeTLS  2) Web Proxy  3) Список  0) Назад'
  local a; read -r -p '> ' a || return 1
  case "$a" in
    1) local t m p d pp; read -r -p 'Нода/master: ' t; read -r -p 'direct/cascade [direct]: ' m; read -r -p 'Порт: ' p; read -r -p 'FakeTLS domain: ' d; [ "$m" = cascade ] && read -r -p 'Public port мастера: ' pp; tgproxy_mtproto_install "$t" "${m:-direct}" "$p" "$d" "$pp" ;;
    2) printf '%s\n' 'Нужны pinned commit и SHA-256 исходного архива telegramdesktop/tproxy-server.'; local t m h c co sh; read -r -p 'Нода: ' t; read -r -p 'direct/cascade: ' m; read -r -p 'Hostname: ' h; read -r -p 'Carrier [websocket-lanes]: ' c; read -r -p 'Commit: ' co; read -r -p 'SHA-256: ' sh; tgproxy_web_install "$t" "$m" "$h" "${c:-websocket-lanes}" "$co" "$sh" ;;
    3) tgproxy_list ;; 0) return 0 ;; *) return 1 ;;
  esac
}

# v7.2.5: диспетчер `main "$@"` переездал в src/99_dispatch.sh — ПОСЛЕДНИЙ
# модуль сборки. Здесь он выполнялся ДО определения функций модулей, которые
# склеиваются позже (33_bbr_v72.sh): bbr_active/bbr_supported в сводке
# установки падали «command not found», «xkit bbr …» не работал из CLI.
#=========================== BBR (v7.2.0) =====================================
# BBR (TCP congestion control) + qdisc fq: заметно лучше пропускная способность
# и стабильнее latency под нагрузкой (прокси-трафик как раз такой). Требуется
# ядро >= 4.9 и собранный модуль tcp_bbr. Включение — sysctl drop-in, который
# переживает ребут. Рекомендация показывается после установки (12_install.sh).
bbr_supported() {
  command -v sysctl >/dev/null 2>&1 || return 1
  grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null && return 0
  # модуль может быть не загружен — попробуем подгрузить (нужен root; без
  # root просто честно скажем «нет»)
  modprobe tcp_bbr 2>/dev/null || true
  grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null
}

bbr_active() {
  command -v sysctl >/dev/null 2>&1 || return 1
  [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ]
}

bbr_status() {
  local cc qdisc conf="/etc/sysctl.d/99-xkit-bbr.conf"
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
  qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
  echo "Ядро: $(uname -r 2>/dev/null || echo '?')"
  echo "Контроль перегрузок: ${cc} (qdisc: ${qdisc})"
  echo "BBR доступен: $(bbr_supported && echo да || echo 'нет (ядро < 4.9 или модуль не собран)')"
  echo "Конфиг: ${conf} $( [ -f "$conf" ] && echo '(есть)' || echo '(нет)' )"
  if bbr_active; then
    ok "BBR активен"
  else
    warn "BBR не активен"
  fi
  return 0
}

bbr_on() {
  if ! bbr_supported; then
    err "BBR недоступен (ядро $(uname -r 2>/dev/null || echo '?') < 4.9 или модуль tcp_bbr не собран) — ничего не меняю"
    return 1
  fi
  if bbr_active && [ -f /etc/sysctl.d/99-xkit-bbr.conf ]; then
    ok "BBR уже активен (конфиг /etc/sysctl.d/99-xkit-bbr.conf на месте)"
    return 0
  fi
  cat > /etc/sysctl.d/99-xkit-bbr.conf <<'EOF'
# XKIT v7.2.0: BBR + fq — пропускная способность и стабильный latency
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  chmod 644 /etc/sysctl.d/99-xkit-bbr.conf
  if sysctl -p /etc/sysctl.d/99-xkit-bbr.conf >/dev/null 2>&1 && bbr_active; then
    ok "BBR включён (конфиг /etc/sysctl.d/99-xkit-bbr.conf — переживёт ребут)"
    return 0
  fi
  err "Не удалось применить BBR через sysctl — проверьте вручную: sysctl net.ipv4.tcp_congestion_control"
  return 1
}

bbr_off() {
  local conf="/etc/sysctl.d/99-xkit-bbr.conf"
  [ -f "$conf" ] || { log "Конфиг BBR отсутствует — выключать нечего"; return 0; }
  rm -f "$conf"
  sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
  ok "BBR выключен (вернули cubic; после ребута — системный дефолт)"
  return 0
}

#=========================== XKIT 7.3: СЕРТИФИКАТЫ ПАНЕЛИ НОД ==========================
# Проблема: панель ноды живёт на самоподписанном EC-серте (node_add, ветка «Включаю
# HTTPS»), curl дергается с -k, пин снимается с самоподписи. Для Reality-туннеля этого
# хватает, но: 1) серт «node-panel» палит родство всех нод кластера (одинаковый CN,
# одинаковый ключ у нод, поставленных одним шаблоном); 2) пин приходится перепинять
# вручную после каждого пересоздания серта.
#
# `xkit nodes cert` — выпуск НАСТОЯЩЕГО сертификата для панели ноды, 4 режима:
#
#   ip        — Let's Encrypt shortlived на IP ноды (--ip-address, ~6.5 дней,
#               автопродление на самой ноде; нужен certbot >= 3.9 c профилем
#               shortlived — ставится venv на ноду, как на мастере с v7.2.4).
#   domain    — отдельный домен/поддомен, A-запись -> IP ноды; http-01 standalone
#               на порту 80 ноды; продление на ноде (дважды в сутки).
#   wildcard  — продвинутый: база вида n1.example.com + *.n1.example.com. Выпускает
#               МАСТЕР по dns-01 (Cloudflare), токен лежит ТОЛЬКО на мастере
#               ($XKIT_DIR/cf-dns.ini, 0600) и на ноды не передаётся; зона
#               верифицируется через API ДО выпуска; доставка на ноду — tar+base64
#               через stdin node_ssh c проверкой sha256 с обеих сторон; продление —
#               таймер мастера 03:30 ежедневно (renew + пере-раздача нодам).
#               Ограничения wildcard: только dns-01; * не матчит точку (ровно один
#               уровень поддоменов: api.n1.example.com — да, x.api.n1.example.com —
#               нет); на IP выпустить нельзя (поэтому для IP-нод — режим ip).
#   self      — самоподписанный (текущее поведение, CN = имя ноды — ключ уникален).
#
# После применения сертификата пин панели ноды перепинывается автоматически
# (node_repin), реестр хранит .panel.cert = {mode, domain, lineage, renew}.
#
# Безопасность: токен Cloudflare — только на мастере (0600, umask 077); приватный
# ключ ноды передаётся по уже доверенному SSH-каналу с пином и TOFU (V-05), тело
# через stdin (пароли/ключи не видны в /proc/<pid>/cmdline, V-03); sha256 сверяется
# на мастере и на ноде до применения.

node_cert_cf_ini() { printf '%s' "${XKIT_DIR}/cf-dns.ini"; }

# A-запись домена: dig -> getent -> python3 (резолвер зависит от окружения мастера).
node_cert_a_record() { # $1 domain -> stdout: первый A-адрес (пусто = не нашлась)
  local d="$1" out=""
  if command -v dig >/dev/null 2>&1; then
    out="$(dig +short A "$d" 2>/dev/null | head -n1)"
  elif getent ahostsv4 "$d" >/dev/null 2>&1; then
    out="$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1; exit}')"
  fi
  [[ "$out" =~ ^[0-9.]+$ ]] || out="$(python3 -c 'import socket,sys;
try: print(socket.gethostbyname(sys.argv[1]))
except Exception: print("")' "$d" 2>/dev/null)"
  is_ipv4 "$out" 2>/dev/null || { [[ "$out" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || out=""; }
  printf '%s' "$out"
}

# Токен Cloudflare: ввод без эха, файл 0600 (umask 077), верификация токена ДО
# выпуска (client/v4/user/tokens/verify). Токен никогда не попадает в argv.
node_cert_cf_token_set() { # -> 0/1; создаёт/освежает cf-dns.ini
  local ini; ini="$(node_cert_cf_ini)"
  local tok
  read -r -p "Cloudflare API-токен (Zone:DNS:Edit на зону базы; ввод скроется): " tok || return 1
  [ -n "$tok" ] || { err "Пустой токен"; return 1; }
  log "Проверяю токен через Cloudflare API (verify)..."
  local v
  v="$(curl -fsS --max-time 15 -H "Authorization: Bearer $tok" \
        -H 'Content-Type: application/json' \
        'https://api.cloudflare.com/client/v4/user/tokens/verify' 2>/dev/null)" || v=""
  jq -e '.success == true and .result.status == "active"' <<<"$v" >/dev/null 2>&1 \
    || { err "Cloudflare токен не принят (verify != active) — выпуск wildcard отменён"; return 1; }
  mkdir -p "$XKIT_DIR" 2>/dev/null || true
  ( umask 077; local t; t="$(mktemp "$ini.new.XXXXXX")" || return 1
    printf 'dns_cloudflare_api_token = %s\n' "$tok" > "$t"
    mv "$t" "$ini" )
  chmod 600 "$ini" 2>/dev/null || true
  ok "Токен принят и сохранён: $ini (0600, только на мастере — на ноды не передаётся)"
  return 0
}

# Верификация зоны через API до выпуска: зона должна существовать и быть active.
node_cert_cf_zone_id() { # $1 base-domain -> id зоны (пусто = зоны нет/не active)
  local d="$1" ini tok out
  ini="$(node_cert_cf_ini)"
  tok="$(sed -n 's/^dns_cloudflare_api_token = //p' "$ini" 2>/dev/null | tail -n1)"
  [ -n "$tok" ] || return 0
  out="$(curl -fsS --max-time 15 -G -H "Authorization: Bearer $tok" \
        'https://api.cloudflare.com/client/v4/zones' \
        --data-urlencode "name=$d" 2>/dev/null)" || out=""
  local id st
  id="$(jq -r '.result[0].id // ""' <<<"$out" 2>/dev/null || true)"
  st="$(jq -r '.result[0].status // ""' <<<"$out" 2>/dev/null || true)"
  [ "$st" = "active" ] || id=""
  printf '%s' "$id"
}

# certbot + dns-cloudflare плагин на МАСТЕРЕ (тот же venv, что certbot_upgrade).
node_cert_master_plugin() { # -> 0/1
  local venv="${XKIT_CERTBOT_VENV:-/opt/certbot-venv}"
  command -v certbot >/dev/null 2>&1 || certbot_upgrade || { err "certbot на мастере недоступен"; return 1; }
  if "$venv/bin/certbot" plugins 2>/dev/null | grep -q 'dns-cloudflare'; then return 0; fi
  log "Ставлю плагин certbot-dns-cloudflare в venv мастера..."
  "$venv/bin/pip" install -q certbot-dns-cloudflare >/dev/null 2>&1 || { err "Плагин dns-cloudflare не поставился"; return 1; }
  hash -r
  return 0
}

# Выпуск wildcard НА МАСТЕРЕ: порядок -d важен — первым идёт база, тогда lineage
# (и каталог /etc/letsencrypt/live/<имя>) получает имя базы, а не *.базы.
node_cert_issue_wildcard() { # $1 base, [$2 email] -> 0 = live/$base готов
  local base="$1" email="${2:-}" extra=() rc=0 venv
  require_root
  node_cert_master_plugin || return 1
  mapfile -t extra < <(le_email_args "$email")
  log "Выпускаю сертификат $base + *.$base (dns-01, зона через API)..."
  certbot certonly --dns-cloudflare \
    --dns-cloudflare-credentials "$(node_cert_cf_ini)" \
    --dns-cloudflare-propagation-seconds "${NODE_CERT_DNS_WAIT:-30}" \
    -d "$base" -d "*.$base" \
    --non-interactive --agree-tos "${extra[@]}" || rc=$?
  [ $rc -eq 0 ] && [ -s "/etc/letsencrypt/live/$base/fullchain.pem" ] \
    || { err "Wildcard-выпуск не удался (порядок -d: '$base' -d '*.$base')"; return 1; }
  ok "Сертификат на мастере: /etc/letsencrypt/live/$base/ (base + *.base)"
  return 0
}

# Доставка серта на ноду: tar -h (разыменовать симлинки live->archive) | base64 |
# stdin node_ssh (V-03: тело не в argv) + sha256 с обеих сторон до применения.
node_cert_push_to_node() { # $1 rec, $2 lineage -> 0 = нода перезапустила панель с новым сертом
  local rec="$1" lineage="$2" payload h_chain h_key
  [ -s "/etc/letsencrypt/live/$lineage/fullchain.pem" ] || { err "На мастере нет live/$lineage"; return 1; }
  payload="$(tar -C /etc/letsencrypt/live -czf - -h "$lineage" 2>/dev/null | base64 -w0)" || return 1
  h_chain="$(sha256sum "/etc/letsencrypt/live/$lineage/fullchain.pem" | awk '{print $1}')"
  h_key="$(sha256sum "/etc/letsencrypt/live/$lineage/privkey.pem" | awk '{print $1}')"
  log "Доставка сертификата на ноду (stdin, sha256-сверка)..."
  node_ssh "$rec" 'bash -s' <<EOF || { err "Нода не применила сертификат"; return 1; }
set -e
d="\$(mktemp -d /tmp/.xkit-cert.XXXXXX)"
printf '%s' '$payload' | base64 -d | tar -xzf - -C "\$d"
[ "\$(sha256sum "\$d/$lineage/fullchain.pem" | awk '{print \$1}')" = '$h_chain' ] || { echo 'ERR: fullchain sha256 не сошёлся'; rm -rf "\$d"; exit 1; }
[ "\$(sha256sum "\$d/$lineage/privkey.pem" | awk '{print \$1}')" = '$h_key' ] || { echo 'ERR: privkey sha256 не сошёлся'; rm -rf "\$d"; exit 1; }
install -m 644 "\$d/$lineage/fullchain.pem" /etc/x-ui/panel-cert.pem
install -m 600 "\$d/$lineage/privkey.pem" /etc/x-ui/panel-key.pem
rm -rf "\$d"
command -v sqlite3 >/dev/null 2>&1 || { echo 'ERR: sqlite3 не установлен — сертификат панели не применён'; exit 1; }
for kv in "webCertFile|/etc/x-ui/panel-cert.pem" "webKeyFile|/etc/x-ui/panel-key.pem"; do
  key="\${kv%%|*}"; val="\${kv#*|}"
  sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value='\$val' WHERE key='\$key'; INSERT INTO settings(key,value) SELECT '\$key','\$val' WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key='\$key');"
done
systemctl restart x-ui
EOF
  return 0
}

# (7.4.0, режим own): доставка СВОЕГО сертификата (купленного/выпущенного
# вне xkit) с мастера на ноду: base64 каждого файла через stdin node_ssh
# (V-03) + sha256-сверка с обеих сторон до применения; продолжение пути
# node_cert_push_to_node — sqlite webCertFile/webKeyFile + restart x-ui.
node_cert_push_files() { # $1 rec, $2 fullchain.pem, $3 privkey.pem -> 0/1
  local rec="$1" cf="$2" kf="$3" b64c b64k h_chain h_key
  [ -s "$cf" ] && [ -s "$kf" ] || { err "Нет файлов: $cf / $kf"; return 1; }
  b64c="$(base64 -w0 "$cf")" || return 1
  b64k="$(base64 -w0 "$kf")" || return 1
  h_chain="$(sha256sum "$cf" | awk '{print $1}')"
  h_key="$(sha256sum "$kf" | awk '{print $1}')"
  log "Доставка своего сертификата на ноду (stdin, sha256-сверка)..."
  node_ssh "$rec" 'bash -s' <<EOF || { err "Нода не применила сертификат"; return 1; }
set -e
d="\$(mktemp -d /tmp/.xkit-cert.XXXXXX)"
printf '%s' '$b64c' | base64 -d > "\$d/fullchain.pem"
printf '%s' '$b64k' | base64 -d > "\$d/privkey.pem"
[ "\$(sha256sum "\$d/fullchain.pem" | awk '{print \$1}')" = '$h_chain' ] || { echo 'ERR: fullchain sha256 не сошёлся'; rm -rf "\$d"; exit 1; }
[ "\$(sha256sum "\$d/privkey.pem" | awk '{print \$1}')" = '$h_key' ] || { echo 'ERR: privkey sha256 не сошёлся'; rm -rf "\$d"; exit 1; }
install -m 644 "\$d/fullchain.pem" /etc/x-ui/panel-cert.pem
install -m 600 "\$d/privkey.pem" /etc/x-ui/panel-key.pem
rm -rf "\$d"
command -v sqlite3 >/dev/null 2>&1 || { echo 'ERR: sqlite3 не установлен — сертификат панели не применён'; exit 1; }
for kv in "webCertFile|/etc/x-ui/panel-cert.pem" "webKeyFile|/etc/x-ui/panel-key.pem"; do
  key="\${kv%%|*}"; val="\${kv#*|}"
  sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value='\$val' WHERE key='\$key'; INSERT INTO settings(key,value) SELECT '\$key','\$val' WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key='\$key');"
done
systemctl restart x-ui
echo OK-OWN-CERT
EOF
  return 0
}

# Выпуск НА НОДЕ (режимы ip/domain/self): сертификат рождается на ноде и остаётся
# там; webCertFile панели смотрит прямо в live/ или /etc/x-ui/. Продление — таймер
# certbot на самой ноде (venv, дважды в сутки — для shortlived IP это обязательно).
node_cert_apply_remote() { # $1 rec, $2 mode(ip|domain|self), $3 name(IP/домен/CN)
  local rec="$1" mode="$2" name="$3" ipwait=""
  [ "$mode" = "ip" ] && ipwait="короткоживущий (~6.5 дней), продление автоматом"
  log "Выпускаю сертификат на ноде: режим $mode, $name ($ipwait)"
  node_ssh "$rec" 'bash -s' <<EOF || { err "Выпуск сертификата на ноде не удался"; return 1; }
set -e
MODE='$mode'; NAME='$name'
C=/etc/x-ui/panel-cert.pem; K=/etc/x-ui/panel-key.pem
case "\$MODE" in
  self)
    openssl ecparam -name prime256v1 -genkey -noout -out "\$K" 2>/dev/null
    openssl req -new -x509 -key "\$K" -out "\$C" -days 825 \
      -subj "/CN=\$NAME" -addext "subjectAltName=IP:\$NAME" 2>/dev/null \
      || openssl req -new -x509 -key "\$K" -out "\$C" -days 825 -subj "/CN=\$NAME" 2>/dev/null
    chmod 600 "\$K"; chmod 644 "\$C"
    ;;
  ip|domain)
    # Camo уже занимает :80 — освобождаем его на время standalone-выпуска.
    systemctl stop nginx >/dev/null 2>&1 || true
    if ss -ltn 2>/dev/null | grep -q ':80 '; then
      echo 'ERR: порт 80 на ноде занят не nginx — standalone-выпуск невозможен'; exit 1
    fi
    if ! command -v certbot >/dev/null 2>&1 || ! certbot --version 2>/dev/null | grep -qE '(3\.[9-9]|[4-9]|[1-9][0-9])'; then
      echo '[INFO] Ставлю certbot (venv) на ноду...'
      apt-get install -y -qq python3-venv python3-pip >/dev/null 2>&1 || true
      python3 -m venv /opt/certbot-venv
      /opt/certbot-venv/bin/pip install -q --upgrade pip >/dev/null 2>&1 || true
      /opt/certbot-venv/bin/pip install -q certbot >/dev/null 2>&1
      ln -sf /opt/certbot-venv/bin/certbot /usr/local/bin/certbot
    fi
    if [ "\$MODE" = "ip" ]; then
      certbot certonly --standalone --ip-address "\$NAME" --preferred-profile shortlived \
        --register-unsafely-without-email --non-interactive --agree-tos || { systemctl start nginx >/dev/null 2>&1 || true; exit 1; }
    else
      certbot certonly --standalone -d "\$NAME" \
        --register-unsafely-without-email --non-interactive --agree-tos || { systemctl start nginx >/dev/null 2>&1 || true; exit 1; }
    fi
    systemctl start nginx >/dev/null 2>&1 || true
    L=/etc/letsencrypt/live/\$NAME
    [ -s "\$L/fullchain.pem" ] || { echo 'ERR: live не появился'; exit 1; }
    install -m 644 "\$L/fullchain.pem" "\$C"
    install -m 600 "\$L/privkey.pem" "\$K"
    # таймер продления на ноде (клон xkit-certbot с мастера): без него 6-дневные
    # IP-серты протухнут; дважды в сутки, как у пакетного certbot.timer
    sd=/etc/systemd/system
    printf '[Unit]\nDescription=XKIT node certbot renew\n[Service]\nType=oneshot\nExecStart=/opt/certbot-venv/bin/certbot -q renew\n' > \$sd/xkit-node-certbot.service
    printf '[Unit]\nDescription=XKIT node certbot renew (twice daily)\n[Timer]\nOnCalendar=*-*-* 00,12:00:00\nRandomizedDelaySec=43200\nPersistent=true\n[Install]\nWantedBy=timers.target\n' > \$sd/xkit-node-certbot.timer
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable --now xkit-node-certbot.timer >/dev/null 2>&1 || true
    ;;
esac
command -v sqlite3 >/dev/null 2>&1 || { echo 'ERR: sqlite3 не установлен — сертификат панели не применён'; exit 1; }
[ -s "\$C" ] && [ -s "\$K" ] || { echo 'ERR: файлы сертификата панели пусты'; exit 1; }
for kv in "webCertFile|\$C" "webKeyFile|\$K"; do
  key="\${kv%%|*}"; val="\${kv#*|}"
  sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value='\$val' WHERE key='\$key'; INSERT INTO settings(key,value) SELECT '\$key','\$val' WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key='\$key');"
done
systemctl restart x-ui
echo OK-CERT-\$MODE
EOF
  return 0
}

# Таймер мастера: продление wildcard-линейджей (dns-01 через cf-dns.ini) и
# пере-раздача сертов нодам с renew=master. Один путь продления — как у
# certbot_renewal_unit: ровно ОДИН источник renew на линейдж.
node_cert_timer_install() { # -> 0
  require_root
  local sd="${XKIT_SYSTEMD_DIR:-/etc/systemd/system}"
  local bin="${XKIT_BIN:-$(readlink -f "$0" 2>/dev/null || echo /usr/local/bin/xkit)}"
  [ -d "$sd" ] || { warn "systemd недоступен — продление wildcard запустите вручную (xkit nodes cert-renew)"; return 1; }
  cat > "$sd/xkit-nodes-cert.service" <<EOF
[Unit]
Description=XKIT nodes cert renew (wildcard dns-01 + redeploy)
[Service]
Type=oneshot
ExecStart=$bin nodes cert-renew --cron
EOF
  cat > "$sd/xkit-nodes-cert.timer" <<'EOF'
[Unit]
Description=XKIT nodes cert renew (daily 03:30)
[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now xkit-nodes-cert.timer >/dev/null 2>&1 || true
  ok "Таймер мастера: xkit-nodes-cert.timer (ежедневно 03:30, renew + раздача нодам)"
  return 0
}

# cron-путь: тихий, без die/confirm, ошибки — в stderr; exit-код агрегированный.
node_cert_renew_cron() { # -> 0 = всё продлено/раздаётся
  load_xkit_env || { echo "xkit-nodes-cert: нет состояния xkit" >&2; return 1; }
  local rc=0 arr n rec lineage
  certbot renew -q >/dev/null 2>&1 || { echo "xkit-nodes-cert: certbot renew упал" >&2; rc=1; }
  arr="$(nodes_load 2>/dev/null || echo '[]')"
  while IFS= read -r rec; do
    [ -z "$rec" ] && continue
    n="$(jq -r '.name' <<<"$rec")"
    lineage="$(jq -r '.panel.cert.lineage // ""' <<<"$rec")"
    [ "$(jq -r '.panel.cert.renew // ""' <<<"$rec")" = "master" ] || continue
    [ -n "$lineage" ] && [ -s "/etc/letsencrypt/live/$lineage/fullchain.pem" ] || { echo "xkit-nodes-cert: $n — нет live/$lineage" >&2; rc=1; continue; }
    if node_cert_push_to_node "$rec" "$lineage" >/dev/null 2>&1; then
      node_repin "$n" >/dev/null 2>&1 || true
    else
      echo "xkit-nodes-cert: $n — раздача серта не прошла" >&2; rc=1
    fi
  done < <(jq -c '.[]' <<<"$arr" 2>/dev/null)
  return $rc
}

# Обновление реестра: тот же контур, что node_relogin (tmp + 600).
node_cert_reg_set() { # $1 имя, $2 jq-фильтр над элементом (пример: '.panel.cert=$c')
  local n="$1" filt="$2"; shift 2
  nodes_load | jq -c --arg n "$n" "$filt" "${@}" > "${XKIT_NODES}.tmp" \
    && mv "${XKIT_NODES}.tmp" "$XKIT_NODES" && chmod 600 "$XKIT_NODES"
}

node_cert_one() { # $1 имя, $2 режим(пусто = меню), $3 домен/база(для domain/wildcard)
  load_xkit_env || die "Сначала установка (пункт 1)"
  local nname="${1:-}" mode="${2:-}" d="${3:-}"
  local rec; rec="$(nodes_load | jq -c --arg n "$nname" '[.[]|select(.name==$n)][0] // empty')"
  [ -n "$rec" ] || die "Нода '$nname' не найдена"
  local nhost; nhost="$(jq -r '.host' <<<"$rec")"
  echo ""
  echo -e "${YELLOW}=== Сертификат панели ноды $nname ($nhost) ===${NC}"
  echo " Текущий режим: $(jq -r '.panel.cert.mode // "self-signed (по умолчанию)"' <<<"$rec")"
  if [ -z "$mode" ]; then
    echo "  1) Самоподписанный — быстро, отдельный ключ для сервера"
    echo "  2) Для IP — короткий сертификат с автопродлением"
    echo "  3) Для отдельного домена — с автопродлением на сервере"
    echo "  4) subdomain+wildcard — база + *.база, выпускает мастер по dns-01 (Cloudflare),"
    echo "                        раздаётся ноде; открывает vhost api./dev./login. (camo-сьют)"
    echo "  5) own              — свой сертификат: пути к fullchain/privkey на этом сервере"
    read -r -p "Режим [1]: " mode || return 1
    mode="${mode:-1}"
    case "$mode" in
      1|self) mode="self" ;;
      2|ip) mode="ip" ;;
      3|domain) mode="domain" ;;
      4|wildcard|w) mode="wildcard" ;;
      5|own) mode="own" ;;
      *) err "Нет такого режима"; return 1 ;;
    esac
  fi
  local lineage="" renew="node" certdomain=""
  case "$mode" in
    self)
      node_cert_apply_remote "$rec" self "$nname" || return 1
      ok "Самоподписанный серт ноды обновлён (CN=$nname) — панель перезапущена"
      ;;
    ip)
      is_ip "$nhost" || { err "Хост ноды не IP ('$nhost') — режим ip только для IP-нод"; return 1; }
      certdomain="$nhost"
      node_cert_apply_remote "$rec" ip "$nhost" || return 1
      lineage="$nhost"
      ok "LE shortlived-сертификат выпущен на ноде ($nhost); продление — таймер certbot на ноде"
      ;;
    domain)
      [ -n "$d" ] || { read -r -p "Домен панели ноды (A -> $nhost): " d || return 1; }
      is_domain "$d" || { err "'$d' не похож на домен"; return 1; }
      local aip; aip="$(node_cert_a_record "$d")"
      [ -n "$aip" ] || { err "A-запись $d не нашлась — выпуск отменён (пропишите и повторите)"; return 1; }
      [ "$aip" = "$nhost" ] || [ "$d" = "$nhost" ] || warn "A-запись $d -> $aip, а нода $nhost — продолжаю, но LE будет биться в $aip"
      certdomain="$d"
      node_cert_apply_remote "$rec" domain "$d" || return 1
      lineage="$d"
      ok "Сертификат для $d выпущен на ноде; продление — таймер certbot на ноде"
      ;;
    wildcard)
      [ -n "$d" ] || { read -r -p "База wildcard (пример: n1.example.com — сама база + *.база): " d || return 1; }
      is_domain "$d" || { err "'$d' не похож на домен"; return 1; }
      [[ "$d" == *"*"* ]] && { err "Пишите БЕЗ '*.' — выпуск покроет $d и *.$d"; return 1; }
      if [ ! -s "$(node_cert_cf_ini)" ]; then
        node_cert_cf_token_set || return 1
      fi
      local zid; zid="$(node_cert_cf_zone_id "${d#*.}")"
      [ -n "$zid" ] || { err "Зона ${d#*.} не найдена/не active через Cloudflare API — проверьте токен и зону"; return 1; }
      ok "Зона ${d#*.} подтверждена (id ${zid:0:8}...)"
      node_cert_issue_wildcard "$d" "${XKIT_LE_EMAIL:-}" || return 1
      node_cert_push_to_node "$rec" "$d" || return 1
      lineage="$d"; certdomain="$d"; renew="master"
      node_cert_timer_install || true
      warn "Wildcard: только dns-01; * покрывает ровно один уровень (api.$d — да, x.api.$d — нет)"
      ;;
    own)
      # (7.4.0): свой сертификат — купленный/выпущенный вне xkit. Файлы лежат
      # на МАСТЕРЕ (куда пользователь их и положил); проверяем соответствие
      # пары (pubkey серта == pubkey ключа), доставляем на ноду с sha256-сверкой.
      local cf kf
      read -r -p "Путь к сертификату (fullchain.pem) на этом сервере: " cf || return 1
      [ -s "$cf" ] || { err "Файл не найден или пуст: $cf"; return 1; }
      read -r -p "Путь к приватному ключу (privkey.pem): " kf || return 1
      [ -s "$kf" ] || { err "Файл не найден или пуст: $kf"; return 1; }
      openssl x509 -in "$cf" -noout >/dev/null 2>&1 || { err "$cf — это не сертификат X.509"; return 1; }
      local cm km
      cm="$(openssl x509 -in "$cf" -noout -pubkey 2>/dev/null | sha256sum | awk '{print $1}')"
      km="$(openssl pkey -in "$kf" -pubout 2>/dev/null | sha256sum | awk '{print $1}')"
      [ -n "$cm" ] && [ -n "$km" ] && [ "$cm" = "$km" ] || { err "Сертификат и ключ не подходят друг другу (pubkey не совпал)"; return 1; }
      local kfperm; kfperm="$(stat -Lc '%a' "$kf" 2>/dev/null)"
      [ "$kfperm" = "600" ] || [ "$kfperm" = "400" ] || warn "Ключ $kf доступен не только владельцу (${kfperm}) — рекомендую chmod 600"
      certdomain="$(openssl x509 -in "$cf" -noout -subject -nameopt multiline 2>/dev/null | sed -n 's/.*commonName *= *//p' | head -n1 | tr -d ' ')"
      node_cert_push_files "$rec" "$cf" "$kf" || return 1
      lineage="-"; renew="none"
      ok "Свой сертификат доставлен и применён панелью ноды; продление — на вашей стороне (обновить: xkit nodes cert $nname own)"
      ;;
    *) err "Режим '$mode' не знаю (self|ip|domain|wildcard|own)"; return 1 ;;
  esac
  local tls_probe='' tls_try
  for tls_try in 1 2 3 4 5; do
    tls_probe="$(cert_pin "$nhost" "$(jq -r '.panel.port' <<<"$rec")")"
    [ -n "$tls_probe" ] && break
    sleep 2
  done
  [ -n "$tls_probe" ] || { err "Панель $nname не прошла TLS-handshake после перезапуска — реестр оставлен на прежней схеме"; return 1; }
  node_cert_reg_set "$nname" --argjson c "$(jq -nc --arg m "$mode" --arg d "$certdomain" --arg l "$lineage" --arg r "$renew" \
      '{mode:$m, domain:$d, lineage:$l, renew:$r}')" \
      'map(if .name==$n then .panel.cert=$c | .panel.tls=true else . end)' \
    || { err "Не записал HTTPS и сертификат панели в реестр"; return 1; }
  log "Перепин сертификата панели ноды..."
  node_repin "$nname" || warn "Перепин не прошёл — выполните: xkit nodes repin $nname"
  [ -z "$(jq -r '.panel_node_id // empty' <<<"$rec")" ] || node_panel_sync "$nname" || warn "Схему в «Узлах» 3X-UI обновите: xkit nodes panel-sync $nname"
  ok "Готово: панель ноды $nname на сертификате '$mode' (${certdomain:-CN=$nname})"
}

node_cert_show() { # $1 имя|all|пусто
  load_xkit_env || die "Сначала установка (пункт 1)"
  local arr; arr="$(nodes_load)"
  [ "$(jq 'length' <<<"$arr" 2>/dev/null || echo 0)" -gt 0 ] || { warn "Нод нет"; return 0; }
  jq -r '.[] | [.name, .host,
      (.panel.cert.mode // "self"),
      (.panel.cert.domain // "-"),
      (.panel.cert.lineage // "-"),
      (.panel.cert.renew // "-"),
      (.camo.domain // "-")] | @tsv' <<<"$arr" \
    | while IFS=$'\t' read -r nm hst m d l r cd; do
        printf '%-14s %-16s cert=%-9s %s (renew:%s) camo=%s\n' "$nm" "$hst" "$m" "$d" "$r" "$cd"
      done
}

node_cert_dispatch() { # $1 sub, $2...
  load_xkit_env || die "Сначала установка (пункт 1)"
  local sub="${1:-}"
  case "$sub" in
    "") die "nodes cert: <имя|all> [self|ip|domain|wildcard|own] [домен]" ;;
    show) node_cert_show "${2:-all}" ;;
    renew)
      if [ "${2:-}" = "--cron" ]; then node_cert_renew_cron; return $?; fi
      # без --cron: разовый проход (renew + раздача), а при указании имени —
      # точечная пере-раздача именно этой ноде
      local rc=0
      if [ -n "${2:-}" ]; then
        local rec; rec="$(nodes_load | jq -c --arg n "$2" '[.[]|select(.name==$n)][0] // empty')"
        [ -n "$rec" ] || die "Нода '$2' не найдена"
        local lineage; lineage="$(jq -r '.panel.cert.lineage // ""' <<<"$rec")"
        [ "$(jq -r '.panel.cert.renew // ""' <<<"$rec")" = "master" ] \
          || { err "$2: серт не в режиме renew=master (nodes cert show)"; return 1; }
        [ -n "$lineage" ] || { err "$2: нет lineage в реестре"; return 1; }
        node_cert_push_to_node "$rec" "$lineage" || rc=1
        node_repin "$2" || true
        return $rc
      fi
      node_cert_renew_cron || rc=1
      return $rc ;;
    -h|--help|help) die "nodes cert <имя|all> [self|ip|domain|wildcard|own] [домен] | nodes cert show | nodes cert-renew" ;;
    all)
      local arr; arr="$(nodes_load)"
      [ "$(jq 'length' <<<"$arr")" -gt 0 ] || { warn "Нод нет"; return 0; }
      local n; jq -r '.[].name' <<<"$arr" | while IFS= read -r n; do
        node_cert_one "$n" "${2:-}" "${3:-}" || true
      done ;;
    *) node_cert_one "$sub" "${2:-}" "${3:-}" ;;
  esac
}
#=========================== XKIT 7.3: CAMO-СЬЮТ НОД ===================================
# Проблема: у всех нод кластера один и тот же вид снаружи — панель 3X-UI на высоком
# порту (одинаковый интерфейс), пустой 80-й порт, один и тот же самоподписанный серт
# «node-panel». Кластер палится как кластер (анти-паттерн «одна матрёшка на все ноды»).
#
# `xkit nodes camo <имя|all>` — ставит на ноду nginx + сайт-прикрытие:
#   - контент ДЕТЕРМИНИРОВАН от per-node seed: seed ноды = sha256(master_seed:имя) —
#     у каждой ноды свой дизайн (тема/палитра/шрифт), у нод нет общего контента,
#     и при повторном деплое сайт не меняется (тот же seed — то же дерево);
#   - фейк-логин /login: форма «Employee sign-in», POST -> nginx 303 /login?e=1
#     БЕЗ бэкенда (пароль некуда вводить — некому и сливать);
#   - <meta name="referrer" content="no-referrer"> — переходы наружу не тащат
#     referer (по нему связали бы ноду с мастером);
#   - единственная внешняя ссылка «Portal» — на прикрытие МАСТЕРА (https://$XKIT_HOST/):
#     клик уводит на дом мастера, а не на третьи ресурсы;
#   - с wildcard-сертификатом (nodes cert wildcard) поднимаются vhost'ы
#     api.<база> / dev.<база> / login.<база> — нода выглядит как обычная компания
#     (API-статус, dev-портал, SSO-логин). Без домена — catch-all по IP с тем же
#     сайтом и /login.
#   - когда nginx занимает порт 80, ставим renewal-hooks (stop/start nginx вокруг
#     certbot renew) — иначе renew IP/domain-сертификатов на ноде бьётся о nginx.
#
# Реестр: .camo = {seed, domain, deployed}. Файлы: /var/www/camo-node/,
# /etc/nginx/sites-available/xkit-camo.conf. Удаление: nodes camo-off <имя|all>.

node_camo_seed_for() { # $1 имя ноды -> hex64 (детерминирован от seed мастера)
  local ms; ms="$(camo_seed_load || true)"
  if [ -z "$ms" ]; then
    ms="$(rand_hex 32)"
    camo_seed_save "$ms" || { err "Не сохраняю seed мастера"; return 1; }
    warn "Seed мастера не был задан — создан новый (camo regenerate мастера поменяет сайт)"
  fi
  printf '%s' "$(printf 'xkit-node-camo:v1:%s:%s' "$ms" "$1" | sha256sum | awk '{print $1}')"
}

node_camo_portal() { printf 'https://%s/' "${XKIT_HOST:-}"; }

# Пост-обработка дерева camo_generate_tree: referrer-политика, Portal, фейк-логин,
# dev/api-страницы для vhost'ов. Всё в том же стиле (css/mark от seed).
node_camo_postprocess() { # $1 seed, $2 portal-url, $3 dest
  python3 - "$1" "$2" "$3" <<'PY'
import hashlib,pathlib,sys
seed,portal,dest=sys.argv[1:]
p=pathlib.Path(dest)
css=(p/'assets/style.css').read_text()
def digest(s):
    return hashlib.sha256((seed+':'+s).encode()).hexdigest()
brand={'font':None}
import re
m=re.search(r'font-family:([^;]+);',css)
font=m.group(1) if m else 'system-ui,sans-serif'
m=re.search(r'background:([^;]+);',css)
bg=m.group(1) if m else '#f4f1ea'
m=re.search(r'\.lead\{max-width:560px;color:([^}]+)\}',css)
accent=m.group(1) if m else '#555'
def page(title,heading,text,form=False):
    form_html=''
    if form:
        form_html=('<section><form method="post" action="/login" class="login">'
                   '<h1>Employee sign-in</h1>'
                   '<p><label>User<br><input type="text" name="user" autocomplete="off"></label></p>'
                   '<p><label>Password<br><input type="password" name="pass"></label></p>'
                   '<p><button type="submit">Sign in</button></p>'
                   '</form></section>')
    return (f'<!doctype html><html lang="en"><head><meta charset="utf-8">'
            f'<meta name="viewport" content="width=device-width,initial-scale=1">'
            f'<meta name="referrer" content="no-referrer">'
            f'<title>{title}</title><link rel="stylesheet" href="/assets/style.css">'
            f'<link rel="icon" href="/assets/mark.svg"></head><body class="stack"><main>'
            f'<nav><a href="/">Home</a><a href="/about.html">About</a>'
            f'<a href="/contact.html">Contact</a><a href="{portal}" rel="noopener">Portal</a></nav>'
            f'{form_html}<section><img class="mark" src="/assets/mark.svg" alt="">'
            f'<h1>{heading}</h1><p class="lead">{text}</p></section>'
            f'<aside class="meta">Internal use only<br>Mon-Fri 09:00-17:00</aside>'
            f'</main></body></html>')
(p/'login.html').write_text(page('Sign in','', '', form=True))
(p/'dev.html').write_text(page('Dev portal','Internal tools',
    'Build and deployment dashboards are available to staff from the office network.'))
api_h=int(digest('api')[:8],16)%4+2
(p/'api.html').write_text(page('API status','All systems operational',
    f'Uptime {99+int(digest("u")[:2],16)%98//100}.{int(digest("n")[:4],16)%100}% over the last 30 days. '
    f'Region eu-central, {api_h} services monitored.'))
for f in p.glob('*.html'):
    t=f.read_text()
    if '<meta name="referrer"' not in t:
        t=t.replace('<meta charset="utf-8">','<meta charset="utf-8"><meta name="referrer" content="no-referrer">',1)
    if 'href="'+portal+'" rel="noopener">Portal</a>' not in t:
        t=t.replace('</nav>',f'<a href="{portal}" rel="noopener">Portal</a></nav>',1)
    f.write_text(t)
css+=('form.login{max-width:360px;margin:40px 0;padding:28px;border:1px solid '+accent+';border-radius:12px}'
      'form.login input{width:100%;box-sizing:border-box;margin-top:4px;padding:9px;border:1px solid '+accent+';background:'+bg+';color:inherit}'
      'form.login button{margin-top:14px;padding:9px 18px;background:'+accent+';color:'+bg+';border:0;cursor:pointer;font-family:'+font+'}')
(p/'assets/style.css').write_text(css)
PY
}

node_camo_nginx_conf() { # $1 домен|пусто, $2 portal -> конфиг в stdout
  local d="$1" portal="$2"
  cat <<EOF
# XKIT camo-suite (v7.3): сайт-прикрытие ноды. Сгенерировано xkit nodes camo.
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root /var/www/camo-node;
    index index.html;
    error_page 404 /404.html;
    location = /login {
        if (\$request_method = POST) { return 303 /login?e=1; }
        try_files /login.html =404;
    }
    location /assets/ { try_files \$uri =404; }
    location / { try_files \$uri \$uri/ =404; }
    add_header Referrer-Policy "no-referrer" always;
    add_header X-Content-Type-Options "nosniff" always;
}
EOF
  if [ -n "$d" ]; then
    cat <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name api.$d;
    root /var/www/camo-node;
    location = / { try_files /api.html =404; }
    location /assets/ { try_files \$uri =404; }
    location / { try_files \$uri =404; }
    add_header Referrer-Policy "no-referrer" always;
}
server {
    listen 80;
    listen [::]:80;
    server_name dev.$d;
    root /var/www/camo-node;
    location = / { try_files /dev.html =404; }
    location /assets/ { try_files \$uri =404; }
    location / { try_files \$uri =404; }
    add_header Referrer-Policy "no-referrer" always;
}
server {
    listen 80;
    listen [::]:80;
    server_name login.$d;
    root /var/www/camo-node;
    location = /login { if (\$request_method = POST) { return 303 /login?e=1; } try_files /login.html =404; }
    location = / { try_files /login.html =404; }
    location /assets/ { try_files \$uri =404; }
    location / { try_files \$uri =404; }
    add_header Referrer-Policy "no-referrer" always;
}
EOF
  fi
}

# Проверка: единственная внешняя ссылка — Portal на мастера (+ xmlns w3.org у SVG).
node_camo_check_tree() { # $1 dest, $2 portal -> 0 = чисто
  local dest="$1" portal="$2" bad
  bad="$(grep -R -E 'https?://' "$dest" --include='*.html' --include='*.css' 2>/dev/null \
        | grep -v 'http://www.w3.org/2000/svg' \
        | grep -v -- "${portal}" || true)"
  [ -z "$bad" ] || { err "Camo содержит внешние ресурсы помимо Portal: $bad"; return 1; }
  grep -q 'name="referrer" content="no-referrer"' "$dest/index.html" || { err "Нет referrer-политики"; return 1; }
  [ -f "$dest/login.html" ] || { err "Нет login.html"; return 1; }
  return 0
}

node_camo_deploy_one() { # $1 имя, [$2 домен|""], [$3 force]
  local nname="$1" d="${2:-}" force="${3:-}"
  local rec; rec="$(nodes_load | jq -c --arg n "$nname" '[.[]|select(.name==$n)][0] // empty')"
  [ -n "$rec" ] || die "Нода '$nname' не найдена"
  local seed portal stage
  seed="$(node_camo_seed_for "$nname")" || return 1
  portal="$(node_camo_portal)"
  if [ -z "$d" ]; then
    d="$(jq -r '.panel.cert.domain // ""' <<<"$rec")"
    jq -e '.panel.cert.mode == "wildcard"' <<<"$rec" >/dev/null 2>&1 || d=""
    if [ -n "$d" ]; then
      ok "Найден wildcard-сертификат ($d) — поднимаю vhost api./dev./login.$d"
    else
      warn "Wildcard-сертификата нет — камо будет catch-all по IP (+/login); для vhost'ов: xkit nodes cert $nname wildcard"
    fi
  fi
  stage="$(mktemp -d "${TMPDIR:-/tmp}/.xkit-camo.XXXXXX")" || return 1
  camo_generate_tree "$seed" "$stage" || { rm -rf "$stage"; return 1; }
  node_camo_postprocess "$seed" "$portal" "$stage" || { rm -rf "$stage"; return 1; }
  node_camo_check_tree "$stage" "$portal" || { rm -rf "$stage"; return 1; }
  local payload htar
  payload="$(tar -C "$stage" -czf - . | base64 -w0)"
  htar="$(printf '%s' "$payload" | base64 -d | sha256sum | awk '{print $1}')"
  rm -rf "$stage"
  log "Доставка camo на ноду $nname (nginx + сайт, stdin, sha256-сверка)..."
  node_ssh "$rec" 'bash -s' <<EOF || { err "Нода не развернула camo"; return 1; }
set -e
command -v nginx >/dev/null 2>&1 || { apt-get update -qq >/dev/null 2>&1 || true; apt-get install -y -qq nginx >/dev/null 2>&1; }
printf '%s' '$payload' | base64 -d | sha256sum | awk '{print \$1}' | grep -qx '$htar' || { echo 'ERR: camo payload sha256 не сошёлся'; exit 1; }
s="\$(mktemp -d /tmp/.xkit-camo-node.XXXXXX)"
printf '%s' '$payload' | base64 -d | tar -xzf - -C "\$s"
[ -s "\$s/index.html" ] || { echo 'ERR: index.html в payload нет'; rm -rf "\$s"; exit 1; }
[ -d /var/www/camo-node ] && rm -rf /var/www/camo-node.old && mv /var/www/camo-node /var/www/camo-node.old
install -d -m 755 /var/www/camo-node
cp -a "\$s/." /var/www/camo-node/
rm -rf "\$s" /var/www/camo-node.old
find /var/www/camo-node -type d -exec chmod 755 {} +
find /var/www/camo-node -type f -exec chmod 644 {} +
cat > /etc/nginx/sites-available/xkit-camo.conf <<'NGINXEOF'
$(node_camo_nginx_conf "$d" "$portal")
NGINXEOF
ln -sf /etc/nginx/sites-available/xkit-camo.conf /etc/nginx/sites-enabled/xkit-camo.conf
rm -f /etc/nginx/sites-enabled/default
# renewal-hooks: nginx занял 80 — certbot renew (standalone) должен уметь его освободить
if [ -d /etc/letsencrypt/renewal-hooks ] || mkdir -p /etc/letsencrypt/renewal-hooks/pre /etc/letsencrypt/renewal-hooks/post; then
  printf '#!/bin/sh\nsystemctl stop nginx >/dev/null 2>&1 || true\n' > /etc/letsencrypt/renewal-hooks/pre/xkit-camo-nginx.sh
  printf '#!/bin/sh\nsystemctl start nginx >/dev/null 2>&1 || true\n' > /etc/letsencrypt/renewal-hooks/post/xkit-camo-nginx.sh
  chmod +x /etc/letsencrypt/renewal-hooks/pre/xkit-camo-nginx.sh /etc/letsencrypt/renewal-hooks/post/xkit-camo-nginx.sh
fi
nginx -t 2>/dev/null || { echo 'ERR: nginx -t не прошёл'; exit 1; }
systemctl enable --now nginx >/dev/null 2>&1 || true
systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true
echo OK-CAMO
EOF
  local cjson
  cjson="$(jq -nc --arg s "$seed" --arg d "$d" --arg t "$(date -u +%Y-%m-%dT%H:%MZ)" '{seed:$s, domain:$d, deployed:$t}')"
  node_cert_reg_set "$nname" --argjson c "$cjson" \
      'map(if .name==$n then .camo=$c else . end)' \
    || warn "Не записал .camo в реестр"
  ok "Camo ноды $nname развернут: nginx :80, сайт /var/www/camo-node${d:+, vhost api./dev./login.$d}"
  return 0
}

node_camo_off_one() { # $1 имя|all
  local want="${1:-}"
  [ -n "$want" ] || die "nodes camo-off: <имя|all>"
  local arr rec n
  arr="$(nodes_load)"
  if [ "$want" = "all" ]; then
    while IFS= read -r n; do
      [ -z "$n" ] && continue
      node_camo_off_one "$n" || true
    done < <(jq -r '.[].name' <<<"$arr")
    return 0
  fi
  rec="$(jq -c --arg n "$want" '[.[]|select(.name==$n)][0] // empty' <<<"$arr")"
  [ -n "$rec" ] || die "Нода '$want' не найдена"
  log "Снимаю camo с ноды $want (nginx остаётся, хуки certbot остаются)..."
  node_ssh "$rec" 'bash -s' <<'EOS' || { err "Нода не сняла camo"; return 1; }
set -e
rm -f /etc/nginx/sites-enabled/xkit-camo.conf /etc/nginx/sites-available/xkit-camo.conf
ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default 2>/dev/null || true
nginx -t 2>/dev/null && systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true
rm -rf /var/www/camo-node
echo OK-CAMO-OFF
EOS
  node_cert_reg_set "$want" 'map(if .name==$n then del(.camo) else . end)' \
    || warn "Не убрал .camo из реестра"
  ok "Camo снят: $want"
}

node_camo_status() {
  load_xkit_env || die "Сначала установка (пункт 1)"
  local arr; arr="$(nodes_load)"
  [ "$(jq 'length' <<<"$arr" 2>/dev/null || echo 0)" -gt 0 ] || { warn "Нод нет"; return 0; }
  jq -r '.[] | [.name, (.camo.domain // "-"), (.camo.deployed // "-"),
      (if .camo.seed then "да" else "нет" end), (.panel.cert.mode // "self")] | @tsv' <<<"$arr" \
    | while IFS=$'\t' read -r nm d t s m; do
        printf '%-14s camo=%-3s домен=%-22s деплой=%s cert=%s\n' "$nm" "$s" "$d" "$t" "$m"
      done
}

node_camo_dispatch() { # $1 sub...
  load_xkit_env || die "Сначала установка (пункт 1)"
  local sub="${1:-}"
  case "$sub" in
    "") die "nodes camo: <имя|all> [домен] | nodes camo-off <имя|all> | nodes camo status" ;;
    status) node_camo_status ;;
    off) shift; node_camo_off_one "${1:-}" ;;
    -h|--help|help) die "nodes camo <имя|all> [домен] | nodes camo-off <имя|all> | nodes camo status" ;;
    all)
      local arr; arr="$(nodes_load)"
      [ "$(jq 'length' <<<"$arr")" -gt 0 ] || { warn "Нод нет"; return 0; }
      local n; jq -r '.[].name' <<<"$arr" | while IFS= read -r n; do
        node_camo_deploy_one "$n" "${2:-}" || true
      done ;;
    *) node_camo_deploy_one "$sub" "${2:-}" ;;
  esac
}
# shellcheck shell=bash
#=========================== XKIT 7.3: ПРОВЕРКА НОД + FREEZE-CHECK =============
# Два сценария поверх существующего nodes_health («все ноды разом», меню):
#
#   xkit nodes check [имя|all] [--json] [--deep] — детальная проверка одной ноды
#     или всех: TCP туннеля (с RTT), SSH, API панели, служба x-ui; --deep добавляет
#     CPU/RAM/диск, версии 3X-UI/Xray и срок серта панели (через node_resource_stats).
#
#   xkit nodes freeze [имя|all] — замер «заморозки» ТСПУ на леге мастер->нода.
#     Идея и логика замера заимствованы из freeze-check
#     (https://github.com/MarkSinD/freeze-check, MIT License, Copyright (c) 2026
#     MarkSinD): на ноде на 2-3 минуты поднимается временный HTTP-сервер со
#     случайным 2 МБ файлом по случайному порту (systemd-run + ufw-дыра, всё чистится
#     автоматически); мастер скачивает 256 КБ N раз и выдаёт вердикт. Замер ведётся
#     С МАСТЕРА, поэтому вердикт валиден для провайдера/региона МАСТЕРА (для каскада
#     «мастер в РФ» это и есть измеряемый RF->foreign участок). Это НЕ client/DPI-тест
#     (см. README). Вердикты хранятся в $XKIT_FREEZE_STATE (0600) и читаются
#     nodes check --json.

XKIT_FREEZE_STATE="${XKIT_FREEZE_STATE:-${XKIT_DIR}/nodes-freeze.json}"
# пороги freeze-check (upstream: LIMIT=256 KiB, SLOW_MIN=64 KiB, 40 с на пробу)
XKIT_FREEZE_LIMIT="${XKIT_FREEZE_LIMIT:-262144}"
XKIT_FREEZE_SLOW_MIN="${XKIT_FREEZE_SLOW_MIN:-65536}"
XKIT_FREEZE_MAXT="${XKIT_FREEZE_MAXT:-40}"
XKIT_FREEZE_TRIES="${XKIT_FREEZE_TRIES:-3}"

_freeze_record() { # $1 имя -> JSON-запись вердикта или null
  [ -r "$XKIT_FREEZE_STATE" ] || { printf 'null'; return 0; }
  jq -c --arg n "$1" '.nodes[$n] // null' "$XKIT_FREEZE_STATE" 2>/dev/null || printf 'null'
}

_freeze_registry_merge() { # $1 имя, $2 JSON-запись; монотонно перезаписывает узел $1
  local name="$1" rec="$2" old
  old='{"version":1,"updated":0,"nodes":{}}'
  [ -r "$XKIT_FREEZE_STATE" ] && old="$(cat "$XKIT_FREEZE_STATE" 2>/dev/null)"
  jq -e 'type=="object"' <<<"$old" >/dev/null 2>&1 || old='{"version":1,"updated":0,"nodes":{}}'
  jq -nc --argjson old "$old" --arg n "$name" --argjson r "$rec" --argjson ts "$(date +%s)" \
    '$old | .version=1 | .updated=$ts | .nodes[$n]=$r' | _xkit_atomic_write "$XKIT_FREEZE_STATE"
}

#---------------------------- nodes check --------------------------------------

node_check_one() { # $1 rec-ноды, $2 deep(0|1) -> stdout: одна JSON-строка
  local rec="$1" deep="${2:-0}"
  local name host tport observed status="down" lat="null" ssh="n/a" api="n/a" svc="unknown"
  local disk_used="null" disk_pct="null" res_json="null" fz_json="null"
  local t0 t1 ssh_out ssh_rc=0
  observed="$(date +%s)"
  name="$(jq -r '.name' <<<"$rec")"
  host="$(jq -r '.host' <<<"$rec")"
  tport="$(jq -r '.tunnel.port // 443' <<<"$rec")"
  fz_json="$(_freeze_record "$name")"
  t0="$(date +%s%N)"
  if timeout 3 bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$host" "$tport" 2>/dev/null; then
    t1="$(date +%s%N)"; lat="$(( (t1 - t0) / 1000000 ))"; status="ok"
  fi
  if [ "$status" = "ok" ]; then
    # один SSH-вызов: SSH-проба + служба x-ui + диск (deep включён всегда — дёшево)
    ssh_out="$(node_ssh "$rec" 'bash -s' 2>/dev/null <<'EOS'
printf 'svc\t%s\n' "$(systemctl is-active x-ui 2>/dev/null || echo unknown)"
df -Pm / 2>/dev/null | awk 'NR==2{printf "disk\t%s\t%s\n",$3,$5}'
EOS
)" || ssh_rc=$?
    if [ "$ssh_rc" -eq 0 ] && [ -n "$ssh_out" ]; then
      ssh="ok"
      svc="$(awk -F'\t' '$1=="svc"{print $2; exit}' <<<"$ssh_out")"
      [ -n "$svc" ] || svc="unknown"
      local dline dused dpct
      dline="$(awk -F'\t' '$1=="disk"{print $2"|"$3; exit}' <<<"$ssh_out")"
      if [ -n "$dline" ]; then
        dused="${dline%%|*}"; dpct="${dline##*|}"; dpct="${dpct%\%}"
        [[ "$dused" =~ ^[0-9]+$ ]] && disk_used="$dused"
        [[ "$dpct" =~ ^[0-9]+$ ]] && disk_pct="$dpct"
      fi
    else
      [ "$ssh_rc" -eq 124 ] && ssh="timeout" || ssh="unavailable"
    fi
    if [ "$ssh" = "ok" ]; then
      local ck
      ck="$(mktemp /tmp/.xkit-node-ck.XXXXXX)" || return 1
      if node_login "$rec" "$ck" >/dev/null 2>&1 \
         && node_api "$rec" panel/api/inbounds/list GET "" "$ck" 2>/dev/null | jq -e '.success==true' >/dev/null 2>&1; then
        api="ok"
      else
        api="fail"
      fi
      rm -f "$ck"
      if [ "$api" = "ok" ] && [ "$svc" = "active" ]; then status="ok"; else status="degraded"; fi
    else
      status="degraded"
    fi
    if [ "$deep" = "1" ] && [ "$ssh" = "ok" ]; then
      res_json="$(node_resource_stats "$rec" 2>/dev/null)" || res_json="null"
      jq -e 'type=="object"' <<<"$res_json" >/dev/null 2>&1 || res_json="null"
    fi
  fi
  jq -nc --arg n "$name" --arg h "$host" --argjson tp "$tport" --arg st "$status" \
    --argjson lat "$lat" --arg ssh "$ssh" --arg api "$api" --arg svc "$svc" \
    --argjson du "$disk_used" --argjson dp "$disk_pct" --argjson ts "$observed" \
    --argjson deep "$deep" --argjson res "$res_json" --argjson fz "$fz_json" '
    {name:$n, host:$h, tunnel_port:$tp, status:$st, latency_ms:$lat,
     probes:{tcp:(if $st=="down" then "down" else "ok" end), ssh:$ssh, api:$api, service:$svc},
     disk_used_mb:$du, disk_pct:$dp, observed_at:$ts,
     deep:(if $deep==1 and ($res|type)=="object" then $res else null end),
     freeze:(if ($fz|type)=="object" then {verdict:$fz.verdict, at:$fz.at} else null end)}'
}

_check_verdict_ru() { # человекочитаемый вердикт nodes check
  case "$1" in
    ok) printf 'OK' ;;
    degraded) printf 'ПРОБЛЕМА' ;;
    down) printf 'НЕДОСТУПНА' ;;
    *) printf '?' ;;
  esac
}

nodes_check() { # xkit nodes check [имя|all] [--json] [--deep]
  load_xkit_env || die "Сначала установка (пункт 1)"
  local want="all" json=0 deep=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1 ;;
      --deep) deep=1 ;;
      -h|--help) err "xkit nodes check [имя|all] [--json] [--deep]"; return 0 ;;
      *) want="$1" ;;
    esac
    shift
  done
  local arr; arr="$(nodes_load)"
  [ "$(jq 'length' <<<"$arr" 2>/dev/null || echo 0)" -gt 0 ] \
    || { warn "Нод нет — добавьте (Ноды -> добавить)"; return 0; }
  if [ "$want" != "all" ]; then
    jq -e --arg n "$want" 'any(.[]; .name==$n)' <<<"$arr" >/dev/null 2>&1 \
      || { err "Нода '${want}' не найдена (xkit nodes list)"; return 1; }
    arr="$(jq -c --arg n "$want" '[.[]|select(.name==$n)]' <<<"$arr")"
  fi
  local rows='[]' rec out
  while IFS= read -r rec; do
    [ -z "$rec" ] && continue
    out="$(node_check_one "$rec" "$deep")"
    jq -e 'type=="object"' <<<"$out" >/dev/null 2>&1 \
      || out="$(jq -nc --arg n "$(jq -r '.name' <<<"$rec")" --argjson ts "$(date +%s)" \
           '{name:$n,status:"down",latency_ms:null,probes:{tcp:"down",ssh:"n/a",api:"n/a",service:"unknown"},
            disk_used_mb:null,disk_pct:null,observed_at:$ts,deep:null,freeze:null}')"
    rows="$(jq -c --argjson r "$out" '. + [$r]' <<<"$rows")"
  done < <(jq -c '.[]' <<<"$arr")
  audit_event nodes.check "$want" ok
  if [ "$json" = "1" ]; then printf '%s\n' "$rows" | jq .; return 0; fi
  echo ""
  if [ "$deep" = "1" ]; then
    log "Проверка нод (deep): TCP, SSH, API, x-ui + CPU/RAM/диск/версии/серт"
  else
    log "Проверка нод: TCP, SSH, API, x-ui (--deep — добавить CPU/RAM/диск/серт)"
  fi
  local now certd
  now="$(date +%s)"
  printf '%-11s %-8s %-11s %-5s %-9s %-10s %-6s %-6s %-7s %-8s\n' \
    "ИМЯ" "TCP/мс" "SSH" "API" "X-UI" "ВЕРДИКТ" "CPU%" "RAM%" "ДИСК%" "СЕРТ/дн"
  echo "-----------------------------------------------------------------------------------------"
  local line n latv sshv apiv svcv stv duv deepv
  while IFS=$'\t' read -r line; do
    n="$(jq -r '.name' <<<"$line")"
    latv="$(jq -r 'if .latency_ms then (.latency_ms|tostring) else "-" end' <<<"$line")"
    sshv="$(jq -r '.probes.ssh' <<<"$line")"
    apiv="$(jq -r '.probes.api' <<<"$line")"
    svcv="$(jq -r '.probes.service' <<<"$line")"
    stv="$(_check_verdict_ru "$(jq -r '.status' <<<"$line")")"
    duv="$(jq -r 'if .disk_used_mb then "\(.disk_used_mb)M/\(.disk_pct)%" else "-" end' <<<"$line")"
    deepv="$(jq -c '.deep // empty' <<<"$line")"
    local cpu="-" ram="-" certd="-"
    if [ -n "${deepv:-}" ]; then
      cpu="$(jq -r '(.cpu_pct // "-")|tostring' <<<"$deepv")"
      ram="$(jq -r '(.ram_pct // "-")|tostring' <<<"$deepv")"
      certd="$(jq -r --argjson now "$now" 'if (.cert_expiry // 0) > 0 then (((.cert_expiry-$now)/86400)|floor|tostring) else "-" end' <<<"$deepv")"
    fi
    printf '%-11s %-8s %-11s %-5s %-9s %-10s %-6s %-6s %-7s %-8s\n' \
      "$n" "$latv" "$sshv" "$apiv" "$svcv" "$stv" "$cpu" "$ram" "$duv" "$certd"
  done < <(jq -c '.[]' <<<"$rows")
  if jq -e 'all(.[]; .status=="ok")' <<<"$rows" >/dev/null 2>&1; then
    ok "Все проверенные ноды в норме"
    return 0
  fi
  warn "Есть ноды с проблемами — подробности выше; freeze-вердикты: xkit nodes freeze"
  return 2
}

#---------------------------- freeze-check: замер с мастера --------------------

# Одна проба. Логика 1:1 из freeze-check probe() (MIT): curl range 0..256K,
# connect 8 с, стоп при <1 Б/с в течение 6 с, максимум XKIT_FREEZE_MAXT с.
# PASS — пришли все 256 КБ (или весь файл целиком), SLOW — обрыв выше 64 КБ
# (медленный канал, не заморозка), FROZEN — обрыв на 1 Б..64 КБ (заморозка ТСПУ:
# соединение открылось, несколько пакетов прошло, дальше тишина без RST),
# NONE — не пришло ни байта. -> stdout: "VERDICT<TAB>bytes"
_freeze_probe_once() {
  local url="$1" rcf got rc v
  rcf="$(mktemp /tmp/.xkit-fz.XXXXXX)" || { printf 'NONE\t0'; return 0; }
  got="$( { curl -sk -r 0-$((XKIT_FREEZE_LIMIT - 1)) --connect-timeout 8 --speed-time 6 \
              --speed-limit 1 -m "$XKIT_FREEZE_MAXT" "$url" 2>/dev/null; echo $? >"$rcf"; } \
          | head -c "$XKIT_FREEZE_LIMIT" | wc -c | tr -d ' ')"
  rc="$(cat "$rcf" 2>/dev/null || echo 1)"; rm -f "$rcf"
  [[ "$got" =~ ^[0-9]+$ ]] || got=0
  if [ "$got" -ge "$XKIT_FREEZE_LIMIT" ] || { [ "${rc:-1}" = "0" ] && [ "$got" -gt 0 ]; }; then v="PASS"
  elif [ "$got" -ge "$XKIT_FREEZE_SLOW_MIN" ]; then v="SLOW"
  elif [ "$got" -gt 0 ]; then v="FROZEN"
  else v="NONE"; fi
  printf '%s\t%s' "$v" "$got"
}

# Агрегация N проб одного нода — как в url-режиме freeze-check:
# все PASS/SLOW -> ok; только FROZEN/NONE и есть FROZEN -> frozen;
# только NONE -> nothing; иначе unstable.
_freeze_aggregate() { # $1 pass, $2 frozen, $3 none
  local p="$1" f="$2" z="$3" n=$(( $1 + $2 + $3 ))
  [ "$n" -gt 0 ] || { printf 'unstable'; return 0; }
  if [ "$p" -eq "$n" ]; then printf 'ok'
  elif [ $((f + z)) -eq "$n" ] && [ "$f" -gt 0 ]; then printf 'frozen'
  elif [ $((f + z)) -eq "$n" ]; then printf 'nothing'
  else printf 'unstable'; fi
}

_freeze_verdict_ru() {
  case "$1" in
    ok) printf 'OK' ;;
    frozen) printf 'ЗАМОРОЗКА' ;;
    nothing) printf 'НЕТ-ОТВЕТА' ;;
    unstable) printf 'НЕСТАБИЛЬНО' ;;
    *) printf 'ОШИБКА' ;;
  esac
}

_freeze_country() { curl -s -m 8 https://ipinfo.io/country 2>/dev/null | tr -d '\r\n '; }

# Страховочная очередь: rec+реквизиты временного сервера; чистится после каждого
# нода, при ошибке/Ctrl+C/exit — trap'ом (см. nodes_freeze).
FREEZE_PENDING=()

_freeze_cleanup_pending() {
  [ "${#FREEZE_PENDING[@]}" -gt 0 ] || { trap - EXIT RETURN INT TERM 2>/dev/null || true; return 0; }
  local e rec dir unit clean port ufw
  for e in "${FREEZE_PENDING[@]}"; do
    IFS=$'\t' read -r rec dir unit clean port ufw <<<"$e"
    timeout 20 node_ssh "$rec" 'bash -s' >/dev/null 2>&1 <<CLEAN || true
systemctl stop '$unit' 2>/dev/null
systemctl stop '$clean.timer' '$clean.service' 2>/dev/null
rm -rf '$dir' 2>/dev/null
[ '$ufw' = 1 ] && { ufw delete allow '$port/tcp' comment 'XKIT:freeze-check' >/dev/null 2>&1 || ufw delete allow '$port/tcp' >/dev/null 2>&1 || true; }
exit 0
CLEAN
  done
  FREEZE_PENDING=()
  trap - EXIT RETURN INT TERM 2>/dev/null || true
}

# Подготовка на НОДЕ одним SSH-вызовом (bash -s через stdin, V-03: без argv-секретов):
# случайный свободный порт, tmp-каталог, 2 МБ файл по случайному токен-пути,
# ufw-дыра (только если ufw активен), systemd-run сервер с RuntimeMaxSec и
# страховочный таймер самоочистки через 30 мин (переживает гибель мастера),
# self-test с самой ноды. stdout: OK<TAB>port<TAB>tok<TAB>dir<TAB>unit<TAB>clean<TAB>ufw
_freeze_node_setup() { # $1 rec
  local rec="$1" out rc
  out="$(node_ssh "$rec" 'bash -s' <<'EOS'
command -v python3 >/dev/null 2>&1 || { echo "ERR nopys"; exit 3; }
command -v systemd-run >/dev/null 2>&1 || { echo "ERR nosystemd"; exit 3; }
PORT=""
if command -v shuf >/dev/null 2>&1; then CAND="$(shuf -i 20000-45000 -n 12 2>/dev/null || true)"; else CAND="$(seq 21000 21012)"; fi
for p in $CAND; do
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -qE ":${p}[[:space:]]" || { PORT="$p"; break; }
  else PORT="$p"; break; fi
done
[ -n "$PORT" ] || { echo "ERR noport"; exit 3; }
DIR="$(mktemp -d /tmp/xkit-freeze.XXXXXX)" || { echo "ERR tmp"; exit 3; }
TOK="$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
mkdir -p "$DIR/$TOK" && head -c 2097152 /dev/urandom > "$DIR/$TOK/freeze-test.bin" \
  || { rm -rf "$DIR"; echo "ERR file"; exit 3; }
UFW=0
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow "$PORT/tcp" comment 'XKIT:freeze-check' >/dev/null 2>&1 && UFW=1
fi
SFX="$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
UNIT="xkit-freeze-$SFX"; CLEAN="xkit-freeze-cln-$SFX"
if ! systemd-run --unit="$UNIT" --property=RuntimeMaxSec=1500 \
     bash -c "exec python3 -m http.server $PORT --bind 0.0.0.0 --directory '$DIR'" >/dev/null 2>&1; then
  rm -rf "$DIR"
  [ "$UFW" = 1 ] && ufw delete allow "$PORT/tcp" comment 'XKIT:freeze-check' >/dev/null 2>&1
  echo "ERR systemd"; exit 3
fi
systemd-run --on-active=1800 --unit="$CLEAN" \
  bash -c "systemctl stop $UNIT 2>/dev/null; systemctl stop $CLEAN.timer 2>/dev/null; rm -rf '$DIR'; ufw delete allow $PORT/tcp comment 'XKIT:freeze-check' >/dev/null 2>&1; ufw delete allow $PORT/tcp >/dev/null 2>&1" >/dev/null 2>&1
OK=0
for i in 1 2 3 4 5 6 7 8 9 10; do
  curl -s -o /dev/null -m 2 "http://127.0.0.1:$PORT/$TOK/freeze-test.bin" && { OK=1; break; }
  sleep 0.5
done
if [ "$OK" != 1 ]; then
  systemctl stop "$UNIT" >/dev/null 2>&1
  systemctl stop "$CLEAN.timer" "$CLEAN.service" >/dev/null 2>&1
  rm -rf "$DIR"
  [ "$UFW" = 1 ] && ufw delete allow "$PORT/tcp" comment 'XKIT:freeze-check' >/dev/null 2>&1
  echo "ERR selftest"; exit 3
fi
printf 'OK\t%s\t%s\t%s\t%s\t%s\t%s\n' "$PORT" "$TOK" "$DIR" "$UNIT" "$CLEAN" "$UFW"
EOS
)" || rc=$?
  [ "${rc:-0}" -eq 0 ] || { case "${rc:-0}" in
      255) err "  SSH до ноды не прошёл" ;;
      124) err "  SSH таймаут" ;;
      *)   err "  Подготовка на ноде не удалась ($(head -n1 <<<"${out:-}")): python3? порт? ufw?" ;;
    esac; return 1; }
  local flag port tok dir unit clean ufw
  IFS=$'\t' read -r flag port tok dir unit clean ufw <<<"$out"
  if [ "$flag" != "OK" ] \
     || ! [[ "$port" =~ ^[0-9]{4,5}$ && "$tok" =~ ^[0-9a-f]{24}$ \
             && "$dir" =~ ^/tmp/xkit-freeze\.[A-Za-z0-9]{6}$ \
             && "$unit" =~ ^[A-Za-z0-9._-]+$ && "$clean" =~ ^[A-Za-z0-9._-]+$ && "$ufw" =~ ^[01]$ ]]; then
    err "  Некорректный ответ ноды — замер отменён (fail-closed)"
    return 1
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$port" "$tok" "$dir" "$unit" "$clean" "$ufw"
}

_freeze_measure_node() { # $1 rec, $2 tries -> stdout: JSON-вердикт; rc!=0 при ошибке подготовки
  local rec="$1" tries="$2"
  local name host url setup port tok dir unit clean ufw
  name="$(jq -r '.name' <<<"$rec")"
  host="$(jq -r '.host' <<<"$rec")"
  setup="$(_freeze_node_setup "$rec")" || return 1
  IFS=$'\t' read -r port tok dir unit clean ufw <<<"$setup"
  FREEZE_PENDING+=("$rec"$'\t'"$dir"$'\t'"$unit"$'\t'"$clean"$'\t'"$port"$'\t'"$ufw")
  url="http://${host}:${port}/${tok}/freeze-test.bin"
  local p=0 f=0 z=0 i pv vver vbytes vmin="$XKIT_FREEZE_LIMIT" bjson='[]'
  for i in $(seq 1 "$tries"); do
    pv="$(_freeze_probe_once "$url")"
    vver="${pv%%$'\t'*}"
    vbytes="${pv##*$'\t'}"
    [[ "$vbytes" =~ ^[0-9]+$ ]] || vbytes=0
    [ "$vbytes" -lt "$vmin" ] && vmin="$vbytes"
    case "$vver" in
      PASS|SLOW) p=$((p + 1)) ;;
      FROZEN) f=$((f + 1)) ;;
      NONE) z=$((z + 1)) ;;
    esac
    printf '  проба %d/%d: %s (%d байт)\n' "$i" "$tries" "$vver" "$vbytes" >&2
    bjson="$(jq -nc --argjson a "$bjson" --argjson b "$vbytes" '$a + [$b]')"
  done
  _freeze_cleanup_pending   # текущий нод чистится сразу; trap страхует аварийные пути
  local verdict at cc
  verdict="$(_freeze_aggregate "$p" "$f" "$z")"
  at="$(date +%s)"; cc="$(_freeze_country)"
  jq -nc --arg v "$verdict" --argjson b "$bjson" --argjson mb "$vmin" \
    --argjson t "$tries" --argjson at "$at" --arg c "${cc:-?}" \
    '{verdict:$v, bytes:$b, min_bytes:$mb, tries:$t, at:$at, country:$c}'
}

nodes_freeze() { # xkit nodes freeze [имя|all] [--tries N] [--any-country] [--json]
  load_xkit_env || die "Сначала установка (пункт 1)"
  command -v curl >/dev/null 2>&1 || { err "curl не найден — freeze-замер невозможен"; return 1; }
  local want="" anyc=0 json=0 tries="$XKIT_FREEZE_TRIES"
  while [ $# -gt 0 ]; do
    case "$1" in
      --tries) tries="${2:-$XKIT_FREEZE_TRIES}"; shift ;;
      --any-country) anyc=1 ;;
      --json) json=1 ;;
      -h|--help) err "xkit nodes freeze [имя|all] [--tries N] [--any-country] [--json]"; return 0 ;;
      *) want="$1" ;;
    esac
    shift
  done
  [[ "$tries" =~ ^[1-9]$ ]] && [ "$tries" -le 5 ] || tries=3
  if [ -z "$want" ]; then  # без цели — только показать сохранённые вердикты
    [ -r "$XKIT_FREEZE_STATE" ] \
      && { [ "$json" = "1" ] && jq . "$XKIT_FREEZE_STATE" || nodes_freeze_show; return 0; } \
      || { warn "Замеров ещё не было. Запустите: xkit nodes freeze <имя|all>"; return 0; }
  fi
  local arr; arr="$(nodes_load)"
  [ "$(jq 'length' <<<"$arr" 2>/dev/null || echo 0)" -gt 0 ] \
    || { warn "Нод нет — freeze-замер относится к каскаду (Ноды -> добавить)"; return 0; }
  if [ "$want" != "all" ]; then
    jq -e --arg n "$want" 'any(.[]; .name==$n)' <<<"$arr" >/dev/null 2>&1 \
      || { err "Нода '${want}' не найдена (xkit nodes list)"; return 1; }
    arr="$(jq -c --arg n "$want" '[.[]|select(.name==$n)]' <<<"$arr")"
  fi
  echo ""
  log "Freeze-замер С МАСТЕРА: «заморозка» ТСПУ на леге мастер->нода (256 КБ-пробы, идея freeze-check)"
  warn "На ноде на 2-3 минуты поднимается временный HTTP-сервер: случайный порт, ufw-дыра закрывается автоматически"
  local cc
  cc="$(_freeze_country)"
  if [ -z "$cc" ]; then
    warn "Страна выхода мастера не определена (ipinfo.io недоступен) — валидность вердикта не гарантирована"
  elif [ "$cc" = "RU" ]; then
    log "Замер из России — вердикты применимы к российскому провайдеру мастера"
  else
    warn "Мастер выходит в мир через '${cc}', не через RU — вердикт будет валиден только для этой страны"
    [ "$anyc" = 1 ] || { confirm "Продолжить замер из '${cc}'? [y/N] " || { warn "Отменено"; return 0; }; }
  fi
  trap 'rc=$?; _freeze_cleanup_pending; exit $rc' EXIT
  trap '_freeze_cleanup_pending; exit 130' INT TERM
  trap '_freeze_cleanup_pending' RETURN
  echo ""
  local rec name out verdict rows_failed=0 frozen=0 measured=0
  while IFS= read -r rec; do
    [ -z "$rec" ] && continue
    name="$(jq -r '.name' <<<"$rec")"
    if ! timeout 3 bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$(jq -r '.host' <<<"$rec")" "$(jq -r '.tunnel.port // 443' <<<"$rec")" 2>/dev/null; then
      err "${name}: туннель недоступен — замер бессмыслен, нода пропущена"
      _freeze_registry_merge "$name" '{"verdict":"error","detail":"tcp_unreachable","bytes":[],"min_bytes":0,"tries":0,"at":'"$(date +%s)"',"country":"?"}'
      audit_event nodes.freeze "$name" error
      rows_failed=$((rows_failed + 1))
      continue
    fi
    log "${name}: поднимаю временный HTTP-сервер и замеряю лег мастер->${name}"
    out="$(_freeze_measure_node "$rec" "$tries")"
    if jq -e 'type=="object" and (.verdict|type)=="string"' <<<"${out:-}" >/dev/null 2>&1; then
      verdict="$(jq -r '.verdict' <<<"$out")"
      _freeze_registry_merge "$name" "$out"
      audit_event nodes.freeze "$name" ok "$verdict"
      measured=$((measured + 1))
      case "$verdict" in
        ok) ok "${name}: ${verdict} — лег живой, заморозки не видно" ;;
        frozen) err "${name}: ${verdict} — обрыв после первых килобайт: фирменная заморозка ТСПУ"
                frozen=$((frozen + 1)) ;;
        nothing) warn "${name}: ${verdict} — HTTP не отвечал: порт могла закрыть security-group провайдера или связь умерла до TLS; повторите" ;;
        unstable) warn "${name}: ${verdict} — пробы неоднозначные, повторите замер" ;;
      esac
    else
      err "${name}: замер не выполнен"
      _freeze_registry_merge "$name" '{"verdict":"error","detail":"setup_failed","bytes":[],"min_bytes":0,"tries":0,"at":'"$(date +%s)"',"country":"?"}'
      audit_event nodes.freeze "$name" error
      rows_failed=$((rows_failed + 1))
    fi
  done < <(jq -c '.[]' <<<"$arr")
  _freeze_cleanup_pending
  echo ""
  if [ "$frozen" -gt 0 ]; then
    err "ЗАМОРОЗКА на ${frozen} нод(ах). Лег мастер->нода режется ТСПУ: варианты лечения —
  1) xkit protocols (AmneziaWG / Hysteria 2 — UDP-протоколы не страдают от TCP-заморозки);
  2) xkit nodes readdress <имя> <новый-IP> — сменить сеть (сеть кандидата проверьте заранее, например freeze-check'ом: owner <IP>)."
  elif [ "$measured" -gt 0 ]; then
    ok "Заморозка на проверенных легах не обнаружена (${measured} нод(ы))"
  fi
  [ "$rows_failed" -eq 0 ] || warn "Не удалось измерить: ${rows_failed} нод(ы) — вердикт error записан в реестр"
  nodes_freeze_show
  return 0
}

nodes_freeze_show() {
  load_xkit_env >/dev/null 2>&1 || true
  [ -r "$XKIT_FREEZE_STATE" ] || { warn "Замеров ещё не было. Запустите: xkit nodes freeze <имя|all>"; return 0; }
  echo ""
  printf '%-11s %-11s %-10s %-8s %-17s\n' "ИМЯ" "ВЕРДИКТ" "МИН.БАЙТ" "ПОПЫТКИ" "КОГДА"
  echo "---------------------------------------------------------------"
  jq -r '.nodes | to_entries[] | [.key, .value.verdict, (.value.min_bytes // 0), (.value.tries // 0), (.value.at // 0)] | @tsv' \
    "$XKIT_FREEZE_STATE" 2>/dev/null \
  | while IFS=$'\t' read -r n v mb tr at; do
      printf '%-11s %-11s %-10s %-8s %-17s\n' \
        "$n" "$(_freeze_verdict_ru "$v")" "$mb" "$tr" "$(date -d "@${at}" '+%F %R' 2>/dev/null || echo '-')"
    done
  ok "Файл вердиктов: $XKIT_FREEZE_STATE (замер валиден для провайдера/региона мастера)"
}
#=========================== ДИСПЕТЧЕР (v7.2.5) ================================
# `main "$@"` — ПОСЛЕДНИЙ модуль сборки (build.sh склеивает src/[0-9][0-9]_*.sh
# по именам). Раньше вызов стоял в конце 32_tgproxy_v71.sh, и всё, что
# склеивалось после него (33_bbr_v72.sh), определялось УЖЕ ПОСЛЕ старта main:
# bbr_active/bbr_supported в сводке установки падали «command not found», а
# «xkit bbr …» не работал из CLI. Теперь к моменту запуска main определены все
# функции всех модулей.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
