#!/bin/bash
# ============================================================
# tail-auth-logs.sh — segue logs do guardian-app-main filtrando
# eventos de login/AD/aprovacao em tempo real.
#
# Uso na LG (em janela SSH separada enquanto outro testa login UI):
#   curl -sL https://raw.githubusercontent.com/MatheusLedstar/gd-boot/main/tail-auth-logs.sh | bash
#
# Modo capture (salva tudo em arquivo + mostra em tela):
#   MODE=capture bash <(curl -sL .../tail-auth-logs.sh)
#
# Modo since (logs dos ultimos N segundos pos-tentativa):
#   MODE=since SINCE=2m bash <(curl -sL .../tail-auth-logs.sh)
#
# Modo verbose (TODOS os logs, sem filtro):
#   MODE=verbose bash <(curl -sL .../tail-auth-logs.sh)
# ============================================================
set -uo pipefail

CONTAINER="${CONTAINER:-guardian-app-main}"
MODE="${MODE:-tail}"
SINCE="${SINCE:-5m}"
LOG_FILE="${LOG_FILE:-/tmp/auth-logs-$(date +%Y%m%d-%H%M%S).log}"

# Padrao de filtro — eventos relevantes pro fluxo de auth/AD
FILTER='login|auth|ad_authenticate|ad_user_data|employee_lookup|employee_created|employee_approved|is_pending|pending_approval|local-login|lookup-ad|approve|HTTPException|Unauthorized|Credenciais|429|Traceback|FATAL'

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYA='\033[0;36m'; NC='\033[0m'

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo -e "${RED}[ERRO]${NC} container '$CONTAINER' nao existe (setar CONTAINER=guardian-app-dev se Conecthus)"
  exit 1
fi

case "$MODE" in
  tail)
    echo -e "${CYA}=== TAIL EM TEMPO REAL — '$CONTAINER' ===${NC}"
    echo -e "${YLW}Filtro:${NC} $FILTER"
    echo -e "${YLW}Pra parar:${NC} Ctrl+C"
    echo
    docker logs -f "$CONTAINER" 2>&1 | grep --line-buffered -iE "$FILTER" --color=auto
    ;;

  capture)
    echo -e "${CYA}=== CAPTURE — salvando em $LOG_FILE ===${NC}"
    echo -e "${YLW}Filtro:${NC} $FILTER"
    echo -e "${YLW}Pra parar:${NC} Ctrl+C (arquivo permanece)"
    echo
    docker logs -f "$CONTAINER" 2>&1 \
      | grep --line-buffered -iE "$FILTER" --color=auto \
      | tee "$LOG_FILE"
    ;;

  since)
    echo -e "${CYA}=== LOGS DOS ULTIMOS $SINCE — '$CONTAINER' ===${NC}"
    echo -e "${YLW}Filtro:${NC} $FILTER"
    echo
    docker logs "$CONTAINER" --since "$SINCE" 2>&1 \
      | grep -iE "$FILTER" --color=auto \
      | tail -200
    echo
    echo -e "${CYA}=== fim ===${NC}"
    ;;

  verbose)
    echo -e "${CYA}=== VERBOSE — todos os logs em tempo real (sem filtro) ===${NC}"
    docker logs -f "$CONTAINER" 2>&1
    ;;

  json)
    echo -e "${CYA}=== JSON STRUCTLOG — eventos estruturados dos ultimos $SINCE ===${NC}"
    docker logs "$CONTAINER" --since "$SINCE" 2>&1 \
      | grep -iE '"event":"[a-z_]*(login|auth|ad_|employee|approve|pending)' \
      | python3 -c '
import sys, json, re
for line in sys.stdin:
    # logs structlog vem como linha "key=val key=val..." ou JSON
    m = re.search(r"\"event\":\s*\"([^\"]+)\"", line)
    if m:
        print(f"  {m.group(1):40s}  {line.strip()[:200]}")
' 2>/dev/null
    ;;

  *)
    echo "MODE invalido: $MODE"
    echo "Validos: tail | capture | since | verbose | json"
    exit 1
    ;;
esac
