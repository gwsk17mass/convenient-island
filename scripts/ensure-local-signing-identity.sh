#!/bin/zsh

set -euo pipefail

project_dir="${0:A:h:h}"
identity_file="$project_dir/.local-signing-identity"
configured_identity="${CONVENIENCE_ISLAND_SIGNING_IDENTITY:-}"

if [[ -z "$configured_identity" && -f "$identity_file" ]]; then
    configured_identity="$(sed -n '1p' "$identity_file" | tr -d '\r\n')"
fi

# Public and contributor builds are ad-hoc by default. Creating a persistent
# trust root or private key is never an implicit build side effect.
if [[ -z "$configured_identity" || "$configured_identity" == "-" ]]; then
    print -r -- "-"
    exit 0
fi

keychain_path="$HOME/Library/Keychains/login.keychain-db"
resolved_identity="$({
    security find-identity -v -p codesigning "$keychain_path" 2>/dev/null || true
} | awk -v requested="$configured_identity" '
    index($0, requested) { print $2; exit }
')"

if [[ -z "$resolved_identity" ]]; then
    print -u2 -- "Не найдена явно выбранная подпись: $configured_identity"
    print -u2 -- "Укажите действующий Developer ID или удалите настройку для безопасной ad-hoc подписи."
    exit 1
fi

print -r -- "$resolved_identity"
