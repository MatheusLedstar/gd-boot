#!/bin/bash
# Wrapper publico — guardian-backend e privado, entao pega o deploy script
# via GitHub API authenticated (header) e executa passando o token adiante.
# Uso: curl -sL <este-gist-raw> | GITHUB_TOKEN=ghp_xxx bash
set -euo pipefail
T="${GITHUB_TOKEN:?GITHUB_TOKEN env var obrigatorio}"
B="${BRANCH:-main}"
echo "[wrapper] baixando deploy-from-github.sh do branch=$B ..."
curl -fsSL \
  -H "Authorization: token $T" \
  -H "Accept: application/vnd.github.raw" \
  "https://api.github.com/repos/MatheusLedstar/guardian-backend/contents/scripts/deploy-from-github.sh?ref=$B" \
  -o /tmp/guardian-deploy.sh
chmod +x /tmp/guardian-deploy.sh
echo "[wrapper] executando deploy ..."
exec env GITHUB_TOKEN="$T" BRANCH="$B" bash /tmp/guardian-deploy.sh "$@"
