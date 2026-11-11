#!/usr/bin/env bash
# Слежение за закреплёнными версиями XKIT (по образцу tools/check-upstream.sh
# проекта 3X-UI_KIT): сравнивает пины ядра/панели с последними релизами и
# подсказывает актуальный SHA-256 установщика 3X-UI для XKIT_XUI_SHA256.
# Ничего не меняет — только печатает. Запуск: bash check-upstream.sh
set -uo pipefail
cd "$(cd "$(dirname "$0")" && pwd)" || exit 1

SRC01="src/01_header.sh"
[ -f "$SRC01" ] || SRC01="xkit.sh"   # в установке src/ может не быть

pinned_const() { # $1 имя константы
  awk -v k="$1" '$1==k {gsub(/"/,"",$3); print $3; exit}' "$SRC01" 2>/dev/null
}
latest_tag() { # $1 repo, $2 regex
  git ls-remote --tags --refs "https://github.com/$1" 2>/dev/null \
    | awk '{print $2}' | sed 's#refs/tags/##' | grep -E "$2" | sort -V | tail -1
}
row() { # имя закреплено последняя
  local mark="  "
  [ -n "${3:-}" ] && [ "$2" != "$3" ] && mark="⬆ "
  printf '%s%-12s закреплено %-12s последняя %s\n' "$mark" "$1" "$2" "${3:-?}"
}

CORE_PIN="$(pinned_const XKIT_CORE_PIN)"
echo "Закреплённые версии и последние релизы (⬆ — есть новее; сначала прочитайте"
echo "список изменений и прогоните тест-матрицу, потом xkit core-pin <версия>):"
row "Xray-core" "${CORE_PIN:-?}" "$(latest_tag XTLS/Xray-core '^v[0-9]+\.[0-9]+\.[0-9]+$')"
row "3X-UI" "(последний)" "$(latest_tag MHSanaei/3x-ui '^v[0-9]+\.[0-9]+\.[0-9]+$')"
echo ""
echo "SHA-256 установщика 3X-UI (для строгой сверки задайте XKIT_XUI_SHA256):"
tag="$(latest_tag MHSanaei/3x-ui '^v[0-9]+\.[0-9]+\.[0-9]+$')"
if [ -n "$tag" ]; then
  h="$(curl -fsSL --max-time 20 "https://raw.githubusercontent.com/MHSanaei/3x-ui/$tag/install.sh" 2>/dev/null | sha256sum | awk '{print $1}')"
  if [ -n "$h" ]; then
    printf '  %s  (тег %s)\n' "$h" "$tag"
    printf '  использование:  XKIT_XUI_SHA256=%s bash install.sh ...\n' "$h"
  else
    echo "  не удалось скачать установщик (сеть?)"
  fi
fi
echo ""
echo "Hysteria (для standalone-службы ставится по releases/latest c проверкой hashes.txt — пин не требуется)."
