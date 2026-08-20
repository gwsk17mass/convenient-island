#!/bin/zsh

set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"

failed=0

while IFS= read -r candidate_file; do
    [[ -z "$candidate_file" ]] && continue
    echo "Слишком большой файл для GitHub: $candidate_file" >&2
    failed=1
done < <(find . -type f -not -path './.git/*' -not -path './.build/*' -not -path './build/*' -size +90M -print)

if rg -n --hidden \
    --glob '!.git/**' \
    --glob '!.build/**' \
    --glob '!build/**' \
    --glob '!scripts/preflight-github.sh' \
    '/Users/[^/]+/' .; then
    echo "Найдены абсолютные пути к личной папке." >&2
    failed=1
fi

if rg -n --hidden \
    --glob '!.git/**' \
    --glob '!.build/**' \
    --glob '!build/**' \
    --glob '!scripts/preflight-github.sh' \
    '(AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|-----BEGIN ([A-Z ]+ )?PRIVATE KEY-----)' .; then
    echo "Найден возможный секрет или приватный ключ." >&2
    failed=1
fi

if (( failed != 0 )); then
    exit 1
fi

echo "GitHub preflight: OK"
