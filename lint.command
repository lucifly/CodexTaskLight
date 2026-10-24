#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"

ruff_path="${CODEXTASKLIGHT_RUFF:-}"
if [[ -z "$ruff_path" ]]; then
  if [[ -x .venv/bin/ruff ]]; then
    ruff_path="$PWD/.venv/bin/ruff"
  elif (( $+commands[ruff] )); then
    ruff_path="${commands[ruff]}"
  else
    print -u2 '缺少 Ruff。请按 docs/BUILD.md 的“代码风格检查”安装开发工具。'
    exit 1
  fi
fi

xcrun swift-format lint --strict --recursive --configuration .swift-format Sources Tools
"$ruff_path" check --no-cache .
"$ruff_path" format --check --no-cache .
for script in ./*.command; do
  zsh -n "$script"
done
print 'PASS: Swift lint, Python lint/format and Zsh syntax'
