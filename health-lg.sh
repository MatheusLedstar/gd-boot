#!/bin/bash
# ============================================================
# health-lg.sh — Diagnostico de saude COMPLETO do ambiente LG
#
# Roda dentro da LG (150.150.251.213). Captura tudo que precisa
# pra um analista remoto debugar:
#  - Containers UP/DOWN, restarts, idade
#  - Aliases criticos em lg-app
#  - Healthcheck backend/frontend (HTTP)
#  - Smoke login admin local + AD (se AD_PASS setado)
#  - PG state (cameras, employees, alembic_version)
#  - mediamtx state (paths, ready)
#  - Conectividade AD/HR (150.150.251.243:3000)
#  - Logs ultimos 60s do guardian-app-main filtrados (errors/auth/login)
#  - Versao deployada (git HEAD nas imagens)
#
# Uso:
#   curl -sL https://raw.githubusercontent.com/MatheusLedstar/gd-boot/main/health-lg.sh | bash
#
# Com user AD pra smoke E2E completo:
#   curl -sL .../health-lg.sh | AD_USER=joao.nunes AD_PASS='@manaus2026.' bash
#
# Saida: tudo em /tmp/lg-health-YYYYMMDD-HHMMSS.log + tela
# ============================================================
set -uo pipefail

NAME_BACKEND="${NAME_BACKEND:-guardian-app-main}"
NAME_FRONTEND="${NAME_FRONTEND:-guardian-frontend-main}"
PG_CONTAINER="${PG_CONTAINER:-guardian}"
PG_USER="${PG_USER:-guardian_admin}"
PG_PASS="${PG_PASS:-LgGuardian_2026}"
PG_DB="${PG_DB:-guardian}"
BACKEND_HOST="${BACKEND_HOST:-localhost}"
BACKEND_PORT="${BACKEND_PORT:-8004}"
FRONTEND_HOST="${FRONTEND_HOST:-localhost}"
FRONTEND_PORT="${FRONTEND_PORT:-8050}"
AD_API_BASE="${AD_API_BASE_URL:-http://150.150.251.243:3000}"
ADMIN_USER="${ADMIN_USER:-admin.guardian}"
ADMIN_PASS="${ADMIN_PASS:-Guardian2026!}"
AD_USER="${AD_USER:-}"
AD_PASS="${AD_PASS:-}"
LOG_FILE="/tmp/lg-health-$(date +%Y%m%d-%H%M%S).log"

# Cores se TTY
if [ -t 1 ]; then
  R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
else
  R=''; G=''; Y=''; C=''; B=''; N=''
fi

PASS=0; FAIL=0; WARN=0
ok()    { echo -e "  ${G}OK${N}    $*"   | tee -a "$LOG_FILE"; PASS=$((PASS+1)); }
fail()  { echo -e "  ${R}FAIL${N}  $*"   | tee -a "$LOG_FILE"; FAIL=$((FAIL+1)); }
warn()  { echo -e "  ${Y}WARN${N}  $*"   | tee -a "$LOG_FILE"; WARN=$((WARN+1)); }
info()  { echo -e "  ${C}info${N}  $*"   | tee -a "$LOG_FILE"; }
section() {
  echo                                                | tee -a "$LOG_FILE"
  echo -e "${C}${B}=========================================${N}"  | tee -a "$LOG_FILE"
  echo -e "${C}${B}  $*${N}"                          | tee -a "$LOG_FILE"
  echo -e "${C}${B}=========================================${N}"  | tee -a "$LOG_FILE"
}

log_block() { echo "$@" >> "$LOG_FILE"; }

echo "Salvando log em: $LOG_FILE" | tee "$LOG_FILE"

# ====== 1. CONTAINERS ======
section "1. Containers Guardian + lg-* (status, idade, restarts)"
docker ps --format '{{.Names}}|{{.Status}}|{{.Image}}|{{.Networks}}' \
  | grep -iE 'guardian|^lg-|streamer|nginx|laravel|mariadb|postgres' | sort | tee -a "$LOG_FILE"

for c in "$NAME_BACKEND" "$NAME_FRONTEND" "$PG_CONTAINER"; do
  if docker inspect "$c" >/dev/null 2>&1; then
    STATUS=$(docker inspect "$c" --format '{{.State.Status}}')
    RESTARTS=$(docker inspect "$c" --format '{{.RestartCount}}')
    AGE=$(docker inspect "$c" --format '{{.State.StartedAt}}')
    [ "$STATUS" = "running" ] && ok "$c running (restarts=$RESTARTS started=$AGE)" || fail "$c status=$STATUS"
  else
    fail "$c NAO existe"
  fi
done

# ====== 2. NETWORKS DOS CONTAINERS ======
# Verifica do LADO DO CONTAINER (mais robusto que .Containers do network).
# Em lg-app os containers podem ter aliases vazios — o NOME do container ja
# eh o hostname resolvivel na rede. Aliases adicionais so existem quando
# nome != esperado pelo nginx (ex: Conecthus usa lg-runner-nginx + alias lg-nginx).
section "2. Networks dos containers (lg-app + aliases adicionais)"
for c in "$NAME_BACKEND" "$NAME_FRONTEND" "$PG_CONTAINER" lg-nginx lg-streamer; do
  if docker inspect "$c" >/dev/null 2>&1; then
    NETS=$(docker inspect "$c" --format '{{range $n,$cfg := .NetworkSettings.Networks}}{{$n}}={{$cfg.Aliases}};{{end}}' 2>/dev/null)
    if echo "$NETS" | grep -q 'lg-app='; then
      ALIASES_LG=$(echo "$NETS" | grep -oE 'lg-app=\[[^]]*\]' | head -1)
      ok "$c em lg-app (${ALIASES_LG:-nome real serve como hostname})"
    else
      warn "$c NAO esta em lg-app (networks atuais: $NETS)"
    fi
  else
    info "$c nao existe nesse ambiente"
  fi
done

# ====== 3. HEALTHCHECK HTTP ======
section "3. Healthcheck HTTP (backend + frontend)"
S=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "http://${BACKEND_HOST}:${BACKEND_PORT}/docs")
[ "$S" = "200" ] && ok "backend /docs -> 200" || fail "backend /docs -> $S"

S=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "http://${FRONTEND_HOST}:${FRONTEND_PORT}/")
[ "$S" = "200" ] && ok "frontend / -> 200" || fail "frontend / -> $S"

S=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "http://${FRONTEND_HOST}:${FRONTEND_PORT}/api/v1/auth/local-login" -X POST -H 'Content-Type: application/json' -d '{}')
case "$S" in
  422|400) ok "frontend proxy /api/v1/auth/local-login -> $S (rota viva)" ;;
  502)     fail "frontend proxy 502 — alias guardian-app-main faltando" ;;
  *)       warn "frontend proxy /local-login -> $S" ;;
esac

# ====== 4. SMOKE LOGIN ======
section "4. Smoke login admin.guardian local"
RESP=$(curl -sS -m 8 -X POST "http://${BACKEND_HOST}:${BACKEND_PORT}/api/v1/auth/local-login" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\"}" 2>/dev/null)
JWT=$(echo "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
if [ -n "$JWT" ]; then
  ok "login local $ADMIN_USER -> JWT (${#JWT} chars)"
  S=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $JWT" "http://${BACKEND_HOST}:${BACKEND_PORT}/api/v1/auth/user-details")
  [ "$S" = "200" ] && ok "JWT em /user-details -> 200" || fail "JWT em /user-details -> $S"
else
  fail "login local $ADMIN_USER FALHOU: $(echo "$RESP" | head -c 200)"
fi

# ====== 5. SMOKE AD (opcional) ======
if [ -n "$AD_USER" ] && [ -n "$AD_PASS" ]; then
  section "5. Smoke login AD ($AD_USER)"
  RESP=$(curl -sS -m 12 -X POST "http://${BACKEND_HOST}:${BACKEND_PORT}/api/v1/auth/local-login" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"$AD_USER\",\"password\":\"$AD_PASS\"}" 2>/dev/null)
  S_HTTP=$(echo "$RESP" | grep -oE '"access_token"' >/dev/null && echo 200 || echo "?")
  if [ "$S_HTTP" = "200" ]; then
    SRC=$(echo "$RESP" | grep -oE '"auth_source":"[^"]+"' | head -1 | cut -d'"' -f4)
    ok "login AD $AD_USER -> 200 auth_source=${SRC:-?}"
  else
    DETAIL=$(echo "$RESP" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("detail","?"))' 2>/dev/null || echo "$RESP" | head -c 100)
    fail "login AD $AD_USER FALHOU detail=$DETAIL"
  fi
else
  section "5. Smoke login AD (PULADO — setar AD_USER/AD_PASS)"
  info "ex: AD_USER=joao.nunes AD_PASS='@manaus2026.' bash <(curl -sL .../health-lg.sh)"
fi

# ====== 6. PG STATE ======
section "6. PostgreSQL state (employees, cameras, alembic)"
PG_OUT=$(docker exec -e PGPASSWORD="$PG_PASS" "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -t -A -c "
  SELECT 'alembic=' || version_num FROM alembic_version
  UNION ALL SELECT 'employees=' || count(*) FROM employees
  UNION ALL SELECT 'pending_employees=' || count(*) FROM employees WHERE is_pending=TRUE
  UNION ALL SELECT 'cameras_local=' || count(*) FROM gua_cameras
  UNION ALL SELECT 'analytics=' || count(*) FROM gua_analytic_aliases;" 2>&1 | grep -v "^$" | head -10)
echo "$PG_OUT" | tee -a "$LOG_FILE"
echo "$PG_OUT" | grep -q "alembic=" && ok "PG responde + queries OK" || fail "PG nao respondeu"

# ====== 7. MEDIAMTX ======
section "7. mediamtx state (paths)"
STREAMER=""
for cand in lg-streamer lg-runner-streamer; do
  if docker inspect "$cand" >/dev/null 2>&1; then STREAMER="$cand"; break; fi
done
if [ -n "$STREAMER" ]; then
  RAW=$(docker exec "$STREAMER" curl -sS http://localhost:9997/v3/paths/list 2>/dev/null)
  TOTAL=$(echo "$RAW" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('items',[])))" 2>/dev/null || echo "?")
  echo "  streamer: $STREAMER" | tee -a "$LOG_FILE"
  echo "  total paths: $TOTAL" | tee -a "$LOG_FILE"
  if [ "${TOTAL:-0}" != "0" ] && [ "$TOTAL" != "?" ]; then
    echo "$RAW" | python3 -c "
import sys,json
items = json.load(sys.stdin).get('items',[])
for it in items[:10]:
    n = it.get('name','?')
    r = it.get('ready', False)
    b = it.get('bytesReceived', 0)
    print(f'  {n}: ready={r} bytes={b}')
" 2>&1 | tee -a "$LOG_FILE"
    ok "$TOTAL paths configurados no mediamtx"
  else
    info "mediamtx 0 paths — esperado se ninguem pediu HLS nos ultimos 45s (lazy runOnDemand)"
  fi
else
  info "container streamer nao encontrado nesse ambiente"
fi

# ====== 8. AD/HR conectividade ======
section "8. Conectividade AD/HR ($AD_API_BASE)"
S=$(docker exec "$NAME_BACKEND" curl -sS -m 5 -o /dev/null -w '%{http_code}' "$AD_API_BASE/swagger/docs/v1" 2>/dev/null)
case "$S" in
  200|301|302) ok "backend alcanca AD API ($AD_API_BASE) -> $S" ;;
  000)         fail "backend NAO alcanca $AD_API_BASE — login AD vai dar timeout" ;;
  *)           warn "AD API -> HTTP $S" ;;
esac

# ====== 9. ENV vars criticas ======
section "9. Env vars do backend"
docker exec "$NAME_BACKEND" env 2>/dev/null \
  | grep -E '^(DB_|JWT_|LOCAL_AUTH|ADMIN_GUARDIAN|LG_ANALYTICS_PASSWORD|YOLO_API_|AD_|ADMIN_USERNAMES|MONITORING_USERNAMES)' \
  | grep -v 'PASSWORD=' | sort | tee -a "$LOG_FILE"
PG_OK=$(docker exec "$NAME_BACKEND" env | grep -c '^DB_USER=guardian_admin')
[ "$PG_OK" = "1" ] && ok "DB_USER=guardian_admin (esperado)" || warn "DB_USER nao bate com esperado"

# ====== 10. LOGS ======
section "10. Logs guardian-app-main (ultimos 90s, filtrados)"
docker logs "$NAME_BACKEND" --since 90s 2>&1 \
  | grep -iE 'login|auth|ad_|employee|is_pending|approve|HTTPException|FATAL|Traceback|psycopg2.*error|429|500' \
  | tail -25 | tee -a "$LOG_FILE"

# ====== 11. VERSAO ======
section "11. Versao deployada"
docker inspect "$NAME_BACKEND" --format 'image={{.Config.Image}} created={{.Created}}' | tee -a "$LOG_FILE"
docker inspect "$NAME_FRONTEND" --format 'image={{.Config.Image}} created={{.Created}}' | tee -a "$LOG_FILE"

# ====== RESUMO ======
section "RESUMO"
echo -e "  ${G}PASS:${N} $PASS" | tee -a "$LOG_FILE"
[ $WARN -gt 0 ] && echo -e "  ${Y}WARN:${N} $WARN" | tee -a "$LOG_FILE"
[ $FAIL -gt 0 ] && echo -e "  ${R}FAIL:${N} $FAIL" | tee -a "$LOG_FILE"
echo
echo "Log completo salvo em: $LOG_FILE"
echo "Cole esse arquivo (ou tail -100) pro analista:"
echo "  cat $LOG_FILE | head -200"

[ $FAIL -eq 0 ] && exit 0 || exit 1
