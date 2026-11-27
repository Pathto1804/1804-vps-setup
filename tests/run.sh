#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0

for t in "${ROOT}"/tests/test_*.sh; do
  [[ -f "${t}" ]] || continue
  if ! bash "${t}"; then
    fail=$((fail + 1))
  fi
done

if (( fail > 0 )); then
  printf '=== 测试失败：%d 个套件未通过 ===\n' "${fail}" >&2
  exit 1
fi
printf '=== 全部打桩测试通过 ===\n'
