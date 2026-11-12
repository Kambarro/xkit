#!/bin/bash
#==============================================================================
#  XKIT — КЛАССИЧЕСКОЕ МЕНЮ (fallback для TUI), v7.4.7
#
#  Меню вынесено из xkit.sh в отдельный файл: ядро (API, установка, nginx,
#  подписки, ноды, дашборд) не раздувается, а правки меню не трогают xkit.sh.
#  Подгружается через `source` из xkit.sh (xkit_load_menu). Сам по себе не
#  запускается — только в составе xkit.
#
#  Где xkit.sh его ищет (первый найденный):
#    1) рядом с самим xkit.sh        (разработка / тесты)
#    2) $XKIT_MENU_DIR               (/usr/local/lib/xkit — установка)
#    3) каталог команды xkit         (/usr/local/bin)
#    4) /etc/xkit
#==============================================================================

# прямой запуск запрещён: работаем только внутри xkit.sh
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "Это модуль меню xkit — запускайте команду xkit (xkit_menu.sh подключается сам)." >&2
  exit 1
fi

pause_enter() { echo ""; read -r -p "Нажмите Enter для возврата в меню..." _; }

#=========================== ГЛАВНОЕ МЕНЮ =====================================
# v5.0.0: плоский список из 26 пунктов (в v5.1.0 — фрагмент без изменений) собран в 6 групп-подменю — управление
# пользователями (было 4/5/6/20) теперь в одном месте, главное меню помещается
# в один экран
show_menu() {
  load_xkit_env 2>/dev/null || true
  local _nc; _nc="$(nodes_load 2>/dev/null | jq 'length' 2>/dev/null || echo 0)"
  echo ""
  echo -e "${GREEN}============================================================${NC}"
  echo -e "${GREEN}   XKIT v${XKIT_VERSION} — nginx + 3X-UI${XKIT_HOST:+   |   ${XKIT_HOST}}${NC}"
  echo -e "${GREEN}   Режим: $([ "$_nc" -gt 0 ] && echo "мастер (${_nc} нод)" || echo "одиночный сервер")${NC}"
  echo -e "${GREEN}============================================================${NC}"
  echo -e "${YELLOW} 1)${NC} Установка и настройка (3X-UI, автопроброс, relay)"
  echo -e "${YELLOW} 2)${NC} ПОЛЬЗОВАТЕЛИ: создать / удалить / список / трафик / подписки"
  echo -e "${YELLOW} 3)${NC} Протоколы: REALITY / XHTTP / AmneziaWG / Hysteria 2"
  echo -e "${YELLOW} 4)${NC} НОДЫ: пул серверов, туннели, балансировка"
  echo -e "${YELLOW} 5)${NC} Обслуживание: сертификат, health, статус, бэкап, обновление"
  echo -e "${YELLOW} 6)${NC} Мониторинг: дашборд, Telegram, аренда, SSH-хук, реквизиты"
  echo -e "${YELLOW} 7)${NC} Магистральные каналы: профиль, benchmark, смена IP, tuning"
  echo -e "${YELLOW} 0)${NC} Выход"
  echo ""
}

menu_loop() {
  while true; do
    show_menu
    read -r -p "Выбор: " choice || { echo; exit 0; }   # EOF (cron/pipe) — выходим, не зацикливаемся
    case "$choice" in
      1) menu_install ;;
      2) menu_users ;;
      3) menu_reality ;;
      4) nodes_menu ;;
      5) menu_service ;;
      6) menu_extra ;;
      7) menu_channels_v71 ;;
      0) exit 0 ;;
      *) warn "Нет такого пункта" ;;
    esac
  done
}

#=========================== 1. УСТАНОВКА И НАСТРОЙКА =========================
menu_install() {
  while true; do
    echo ""
    echo -e "${YELLOW}=== УСТАНОВКА И НАСТРОЙКА: nginx(TLS 443) + 3X-UI ===${NC}"
    echo " 1) Установка одним шагом (3X-UI + nginx + SSL + панель за nginx)"
    echo " 2) АВТОПРОБРОС: все инбаунды → 127.0.0.1 за nginx + подписки"
    echo " 3) Спрятать УЖЕ установленную панель 3X-UI за nginx"
    echo " 4) Ручной relay-маршрут (проброс пути на другой сервер)"
    echo " 5) Панель: корректные ссылки и подписки (externalProxy)"
    echo " 0) Назад"
    local c
    read -r -p "Выбор: " c || return 0
    case "$c" in
      1) one_step_install; pause_enter ;;
      2) auto_route; pause_enter ;;
      3) hide_existing_panel; pause_enter ;;
      4) add_relay_route; pause_enter ;;
      5) external_proxy_fix; pause_enter ;;
      0) return 0 ;;
      *) warn "Нет такого пункта" ;;
    esac
  done
}

#=========================== 2. ПОЛЬЗОВАТЕЛИ ==================================
menu_users() {
  while true; do
    echo ""
    echo -e "${YELLOW}=== ПОЛЬЗОВАТЕЛИ: клиенты инбаундов панели ===${NC}"
    echo " 1) Создать пользователя"
    echo " 2) Удалить пользователя"
    echo " 3) Сбросить трафик пользователю"
    echo " 4) Список пользователей + ссылки"
    echo " 5) Подписки: перегенерировать и показать URL"
    echo " 6) Пользователь во ВСЕ протоколы (одна подписка, v6)"
    echo " 7) QR подписки (локально, SVG/PNG)"
    echo " 0) Назад"
    local c
    read -r -p "Выбор: " c || return 0
    case "$c" in
      1) client_add; pause_enter ;;
      2) client_del; pause_enter ;;
      3) client_reset; pause_enter ;;
      4) client_list; pause_enter ;;
      5) sub_regen; pause_enter ;;
      6) client_add_all; pause_enter ;;
      7) local sid fmt; read -r -p "subId: " sid; read -r -p "Формат [svg]: " fmt; sub_qr "$sid" "${fmt:-svg}"; pause_enter ;;
      0) return 0 ;;
      *) warn "Нет такого пункта" ;;
    esac
  done
}

#=========================== 3. ПРОТОКОЛЫ =====================================
menu_reality() {
  while true; do
    echo ""
    echo -e "${YELLOW}=== ПРОТОКОЛЫ И ПОДКЛЮЧЕНИЯ ===${NC}"
    echo " 1) VLESS + REALITY + Vision: создать inbound"
    echo " 2) VLESS + XHTTP + REALITY: создать inbound"
    echo " 3) REALITY: скан подсети"
    echo " 4) REALITY: показать ключи и ссылки"
    echo " 5) AmneziaWG: панель (рекомендуется) или служба — обе с AWG 3.1"
    echo " 6) Hysteria 2: служба и ссылка"
    echo " 7) Сводка всех профилей"
    echo " 8) Панельный режим: AWG + Hy2 как инбаунды панели (v6)"
    echo " 0) Назад"
    local c
    read -r -p "Выбор: " c || return 0
    case "$c" in
      1) reality_wizard; pause_enter ;;
      2) xkit_protocols_load && proto_xhttp_create; pause_enter ;;
      3) reality_scan_menu; pause_enter ;;
      4) reality_show_keys; pause_enter ;;
      5) xkit_protocols_load && proto_awg_menu; pause_enter ;;
      6) xkit_protocols_load && proto_hy2_menu; pause_enter ;;
      7) xkit_protocols_load && protocols_list; pause_enter ;;
      8) xkit_protocols_load && proto_panel_menu; pause_enter ;;
      0) return 0 ;;
      *) warn "Нет такого пункта" ;;
    esac
  done
}

#=========================== 5. ОБСЛУЖИВАНИЕ ==================================
menu_service_cert() { # бывший пункт 10 главного меню: перевыпуск сертификата
  [ -n "${XKIT_HOST:-}" ] || die "Сначала установка"
  choose_certificate "$XKIT_HOST" "$(host_kind "$XKIT_HOST")" || return 1
  XKIT_CRT="$FINAL_CRT"; XKIT_KEY="$FINAL_KEY"; XKIT_CERT_MODE="$CERT_MODE"
  save_xkit_env
  # (мелочь №10, аудит v5.2.1): сбой применения не должен прятаться за общим сообщением
  regen_conf_and_apply || { err "Конфиг nginx не применён — проверьте: nginx -t"; return 1; }
  warn "Клиентам могут понадобиться новые файлы серта (для IP-сертов — обновите подписку)"
}

menu_service() {
  while true; do
    echo ""
    echo -e "${YELLOW}=== ОБСЛУЖИВАНИЕ: серты, диагностика, бэкапы, обновление ===${NC}"
    echo " 1) Сертификат: перевыпустить (домен / IP / self-signed)"
    echo " 2) Проверка жизнеспособности (и «что светится наружу»)"
    echo " 3) Глубокая проверка: реальный клиент по нашим ссылкам (v6)"
    echo " 4) Статус: сервисы, порты, маршруты"
    echo " 5) Бэкап: сделать сейчас"
    echo " 6) Бэкап: восстановить из последнего"
    echo " 7) Обновить xkit из репозитория (SHA-256, бэкап)"
    echo " 8) Версии 3X-UI/Xray: список, проверка, установка, rollback"
    echo " 9) Сайт-заглушка: статус или ручная регенерация по seed"
    echo "10) Doctor: sanitized support bundle"
    echo "11) Бэкап: verify / restore dry-run / age export"
    echo "12) Maintenance: logrotate + systemd timer"
    echo "13) Отложенные restart: статус / применить"
    echo "14) Traffic ledger: собрать / показать / quota dry-run"
    echo "15) Audit journal: последние 50 действий"
    echo "16) Бэкапы: расписание и хранение (интервал 24/48/168/свой)"
    echo "17) BBR: статус / включить (рекомендация для пропускной способности)"
    echo "18) Socket options: TFO / TCP_NODELAY"
    echo "19) Проверить обновление XKIT"
    echo " 0) Назад"
    local c
    read -r -p "Выбор: " c || return 0
    case "$c" in
      1) menu_service_cert; pause_enter ;;
      2) health_check; pause_enter ;;
      3) health_deep; pause_enter ;;
      4) show_status; pause_enter ;;
      5) backup_now; pause_enter ;;
      6) backup_restore; pause_enter ;;
      7) xkit_self_update; pause_enter ;;
      8) menu_versions; pause_enter ;;
      9) menu_camo; pause_enter ;;
      10) doctor_export; pause_enter ;;
      11) menu_backup_v7; pause_enter ;;
      12) ops_hygiene_install; pause_enter ;;
      13) restart_status; confirm "Применить очередь сейчас? [y/N]" && restart_apply; pause_enter ;;
      14) traffic_ledger_collect >/dev/null 2>&1 || true; traffic_ledger_show; pause_enter ;;
      15) audit_show 50; pause_enter ;;
      16) backup_settings_menu; pause_enter ;;
      17) menu_bbr; pause_enter ;;
      18) sockopt_cmd; pause_enter ;;
      19) xkit_update_check --force; pause_enter ;;
      0) return 0 ;;
      *) warn "Нет такого пункта" ;;
    esac
  done
}

menu_versions() {
  while true; do
    echo ""; echo "=== ВЕРСИИ 3X-UI/XRAY ==="
    versions_status
    echo " 1) Показать манифест связок"
    echo " 2) Установить связку (SHA-256 + backup + probes + rollback)"
    echo " 3) Откатить последнюю смену связки"
    echo " 0) Назад"
    local c u x; read -r -p "Выбор: " c || return 0
    case "$c" in
      1) versions_list ;;
      2) read -r -p "Версия 3X-UI: " u; read -r -p "Версия Xray: " x; versions_install "$u" "$x" ;;
      3) versions_rollback ;;
      0) return 0 ;;
    esac
  done
}
menu_camo() {
  echo ""; camo_status; echo ""; camo_files
  echo "Регенерация меняет публичный сайт. TLS/nginx/REALITY-фингерпринт она не меняет."
  echo "Enter = новый случайный вариант; 64 hex-символов seed = воспроизводимый сайт:"
  echo "тот же seed при переустановке даёт тот же сайт (seed хранится в $XKIT_DIR/camo.env)."
  local seed
  read -r -p "Seed (Enter — случайный): " seed || return 0
  confirm "Сгенерировать сайт-прикрытие сейчас? [y/N]" || return 0
  camo_regenerate "${seed:-}"
}

#=========================== 6. МОНИТОРИНГ И РЕКВИЗИТЫ ========================
menu_channels_v71() {
  while true; do
    echo ""
    echo " 1) Профили нод: список"
    echo " 2) Переключить профиль (candidate + benchmark + rollback)"
    echo " 3) Benchmark: RTT и скорость полного канала"
    echo " 4) Сменить IP ноды без переустановки (dry-run)"
    echo " 5) Сменить IP ноды без переустановки (apply)"
    echo " 6) Conservative tuning: show / safe / balanced"
    echo " 0) Назад"
    local c n p ip m; read -r -p "Выбор: " c || return 0
    case "$c" in
      1) node_profile_list all; pause_enter ;;
      2) read -r -p 'Нода: ' n; read -r -p 'Профиль: ' p; node_profile_switch "$n" "$p"; pause_enter ;;
      3) read -r -p 'Нода: ' n; node_profile_benchmark "$n"; pause_enter ;;
      4) read -r -p 'Нода: ' n; read -r -p 'Новый IP: ' ip; node_readdress "$n" "$ip" --dry-run; pause_enter ;;
      5) read -r -p 'Нода: ' n; read -r -p 'Новый IP: ' ip; node_readdress "$n" "$ip"; pause_enter ;;
      6) read -r -p 'Нода: ' n; read -r -p 'show/safe/balanced: ' m; node_tune "$n" "$m"; pause_enter ;;
      0) return 0 ;; *) warn "Нет такого пункта" ;;
    esac
  done
}

menu_extra() {
  while true; do
    echo ""
    echo -e "${YELLOW}=== МОНИТОРИНГ И РЕКВИЗИТЫ ===${NC}"
    echo " 1) ВЕБ-ДАШБОРД: статусы нод, каналы, трафик (секретный URL)"
    echo " 2) Telegram: алерты (ноды/аренда/сертификат/дашборд)"
    echo " 3) СРОКИ АРЕНДЫ серверов: мастер + ноды (expiry)"
    echo " 4) SSH: авто-меню при входе вкл/выкл (+ обновить команду xkit)"
    echo " 5) Реквизиты: сводка в терминал (пароли — только в /root/xkit-info.txt)"
    echo " 6) Telegram Proxy: MTProto FakeTLS / Web Proxy (без SOCKS5)"
    echo " 0) Назад"
    local c
    read -r -p "Выбор: " c || return 0
    case "$c" in
      1) dash_menu ;;
      2) telegram_menu ;;
      3) expiry_menu ;;
      4) ssh_hook_toggle; pause_enter ;;
      5) xkit_info; pause_enter ;;
      6) tgproxy_menu; pause_enter ;;
      0) return 0 ;;
      *) warn "Нет такого пункта" ;;
    esac
  done
}

menu_backup_v7() {
  echo "1) verify  2) restore dry-run  3) age export  0) отмена"
  local c; read -r -p "Выбор: " c || return 0
  case "$c" in 1) backup_verify ;; 2) backup_restore_dry_run ;; 3) backup_export ;; 0) : ;; *) warn "Нет такого пункта" ;; esac
}

# v7.2.0: рекомендация/управление BBR — ТС-перегрузки, ядро >= 4.9
menu_bbr() {
  echo ""; echo "=== BBR (TCP congestion control) ==="
  echo "Рекомендуется для прокси-нагрузки: выше пропускная способность, стабильнее latency."
  bbr_status
  echo " 1) Включить BBR (sysctl drop-in, переживёт ребут)"
  echo " 2) Выключить BBR"
  echo " 0) Назад"
  local c; read -r -p "Выбор: " c || return 0
  case "$c" in
    1) bbr_on ;;
    2) bbr_off ;;
    0) : ;;
    *) warn "Нет такого пункта" ;;
  esac
}
