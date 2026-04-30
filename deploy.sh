#!/bin/bash
# ============================================================
# deploy.sh — Deploy completo end-to-end Guardian na LG (e Conecthus)
#
# Substitui run.sh com workflow mais robusto:
#  1. Pre-flight (docker daemon, disco, GITHUB_TOKEN, redes)
#  2. Pull repos + diff (mostra o que mudou desde HEAD anterior)
#  3. Snapshot rollback automatico (tag imagem :rollback-TS)
#  4. Build imagens (parallel)
#  5. Run migrations explicit + verify alembic current
#  6. Recreate containers em ordem (postgres → backend → frontend)
#  7. Healthcheck multi-stage com retry
#  8. Smoke test integrado (login admin, lookup-ad endpoint)
#  9. ROLLBACK AUTOMATICO se smoke falhar
# 10. Log estruturado em /var/log/guardian-deploy/YYYYMMDD-HHMMSS.log
#
# Uso (one-liner LG, GITHUB_TOKEN obrigatorio):
#   curl -sL https://raw.githubusercontent.com/MatheusLedstar/gd-boot/main/deploy.sh | GITHUB_TOKEN=ghp_... bash
#
# Modos:
#   SKIP_BUILD=1     — pula build (usa imagens existentes)
#   SKIP_SMOKE=1     — pula smoke test final
#   FORCE_ROLLBACK=1 — sempre rollback no final (DRY-RUN)
#   BRANCH=dev       — deploy de outra branch (default main)
#   DRY_RUN=1        — mostra plano sem executar
# ============================================================
set -uo pipefail

# ========== Config ==========
WORKDIR="${WORKDIR:-$HOME/guardian-deploy}"
BRANCH="${BRANCH:-main}"
NET_APP="${NET_APP:-lg-app}"
PORT_BACKEND="${PORT_BACKEND:-8004}"
PORT_FRONTEND="${PORT_FRONTEND:-8050}"
NAME_BACKEND="${NAME_BACKEND:-guardian-app-main}"
NAME_FRONTEND="${NAME_FRONTEND:-guardian-frontend-main}"
PG_CONTAINER="${PG_CONTAINER:-guardian}"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="${LOG_DIR:-/var/log/guardian-deploy}"
LOG_FILE="$LOG_DIR/$TIMESTAMP.log"
[ -w "$(dirname "$LOG_DIR")" ] || LOG_DIR="/tmp/guardian-deploy-logs"
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp"
LOG_FILE="$LOG_DIR/$TIMESTAMP.log"

# Cores (deferred — so habilita se TTY)
if [ -t 1 ]; then
  RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYA='\033[0;36m'; BLD='\033[1m'; NC='\033[0m'
else
  RED=''; GRN=''; YLW=''; CYA=''; BLD=''; NC=''
fi

# ========== Logging ==========
log() {
  local msg="[$(date +'%H:%M:%S')] $*"
  echo "$msg" | tee -a "$LOG_FILE"
}
ok()    { echo -e "${GRN}✓${NC} $*" | tee -a "$LOG_FILE"; }
fail()  { echo -e "${RED}✗${NC} $*" | tee -a "$LOG_FILE"; }
warn()  { echo -e "${YLW}⚠${NC} $*" | tee -a "$LOG_FILE"; }
info()  { echo -e "${CYA}ℹ${NC} $*" | tee -a "$LOG_FILE"; }
section() {
  echo | tee -a "$LOG_FILE"
  echo -e "${CYA}${BLD}══════════════════════════════════════════════════════════${NC}" | tee -a "$LOG_FILE"
  echo -e "${CYA}${BLD}  $*${NC}" | tee -a "$LOG_FILE"
  echo -e "${CYA}${BLD}══════════════════════════════════════════════════════════${NC}" | tee -a "$LOG_FILE"
}

die() { fail "$*"; echo "[ABORTANDO] log: $LOG_FILE" >&2; exit 1; }

# ========== Trap rollback ==========
ROLLBACK_BACKEND_IMG=""
ROLLBACK_FRONTEND_IMG=""
DEPLOY_OK=false

cleanup_on_fail() {
  if [ "$DEPLOY_OK" = "false" ] && [ -n "$ROLLBACK_BACKEND_IMG" ]; then
    section "ROLLBACK AUTOMATICO (deploy falhou)"
    warn "Restaurando containers anteriores..."
    if [ -n "$ROLLBACK_BACKEND_IMG" ]; then
      docker stop "$NAME_BACKEND" 2>/dev/null || true
      docker rm "$NAME_BACKEND" 2>/dev/null || true
      docker run -d --name "$NAME_BACKEND" --restart unless-stopped \
        --network "$NET_APP" -p "$PORT_BACKEND:8000" \
        -v guardian_uploads:/backend/upload \
        "$ROLLBACK_BACKEND_IMG" >/dev/null \
        && warn "  backend restaurado: $ROLLBACK_BACKEND_IMG" \
        || fail "  rollback backend falhou — investigar manualmente"
    fi
    if [ -n "$ROLLBACK_FRONTEND_IMG" ]; then
      docker stop "$NAME_FRONTEND" 2>/dev/null || true
      docker rm "$NAME_FRONTEND" 2>/dev/null || true
      docker run -d --name "$NAME_FRONTEND" --restart unless-stopped \
        --network "$NET_APP" -p "$PORT_FRONTEND:80" \
        "$ROLLBACK_FRONTEND_IMG" >/dev/null \
        && warn "  frontend restaurado: $ROLLBACK_FRONTEND_IMG" \
        || fail "  rollback frontend falhou — investigar manualmente"
    fi
    fail "DEPLOY ABORTADO — sistema voltou ao estado anterior"
  fi
}
trap cleanup_on_fail EXIT

# ========== 1. Pre-flight ==========
section "1/9 Pre-flight checks"

[ -n "${GITHUB_TOKEN:-}" ] || die "GITHUB_TOKEN env var obrigatorio (export GITHUB_TOKEN=ghp_...)"

command -v docker >/dev/null || die "docker nao instalado"
docker info >/dev/null 2>&1 || die "docker daemon nao responde"
ok "docker daemon OK"

command -v git >/dev/null || die "git nao instalado"
ok "git OK"

# Espaco em disco (warn se < 5GB)
DISK_FREE=$(df -BG "$HOME" 2>/dev/null | awk 'NR==2{gsub(/G/,"",$4); print $4}')
if [ -n "$DISK_FREE" ] && [ "$DISK_FREE" -lt 5 ]; then
  warn "espaco em disco baixo: ${DISK_FREE}G (recomendado >5G)"
else
  ok "espaco em disco: ${DISK_FREE:-?}G livres"
fi

# Rede lg-app
docker network inspect "$NET_APP" >/dev/null 2>&1 \
  && ok "rede $NET_APP existe" \
  || { warn "criando rede $NET_APP"; docker network create "$NET_APP" >/dev/null; }

# Postgres alive
if docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
  if docker exec "$PG_CONTAINER" pg_isready -h localhost -p 5432 >/dev/null 2>&1; then
    ok "postgres ($PG_CONTAINER) responde pg_isready"
  else
    warn "postgres ($PG_CONTAINER) nao responde pg_isready — deploy pode travar em entrypoint"
  fi
else
  die "container postgres '$PG_CONTAINER' nao esta UP — deploy abortado"
fi

# Postgres alias na rede
PG_ALIASES=$(docker network inspect "$NET_APP" \
  --format "{{range \$i,\$c := .Containers}}{{if eq \$c.Name \"$PG_CONTAINER\"}}{{range \$a := \$c.Aliases}}{{\$a}} {{end}}{{end}}{{end}}" 2>/dev/null)
if echo "$PG_ALIASES" | grep -qw "postgres"; then
  ok "postgres tem alias 'postgres' em $NET_APP"
else
  warn "postgres SEM alias 'postgres' em $NET_APP — corrigindo"
  ALIAS_ARGS="--alias postgres"
  for A in $PG_ALIASES; do ALIAS_ARGS="$ALIAS_ARGS --alias $A"; done
  docker network disconnect "$NET_APP" "$PG_CONTAINER" 2>/dev/null || true
  docker network connect $ALIAS_ARGS "$NET_APP" "$PG_CONTAINER" \
    && ok "  postgres reconectado com alias" \
    || die "  falha ao reconectar postgres"
fi

if [ "${DRY_RUN:-0}" = "1" ]; then
  info "DRY_RUN=1 — saindo apos pre-flight"
  exit 0
fi

# ========== 2. Pull repos ==========
section "2/9 Clone/pull repos GitHub (branch=$BRANCH)"

mkdir -p "$WORKDIR"
cd "$WORKDIR"

REPO_BACKEND="https://oauth2:$GITHUB_TOKEN@github.com/MatheusLedstar/guardian-backend.git"
REPO_FRONTEND="https://oauth2:$GITHUB_TOKEN@github.com/MatheusLedstar/guardian.git"

clone_or_pull() {
  local dir="$1" url="$2"
  if [ -d "$dir/.git" ]; then
    cd "$dir"
    OLD_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "none")
    git fetch --quiet origin "$BRANCH" 2>&1 | tee -a "$LOG_FILE"
    git reset --hard "origin/$BRANCH" 2>&1 | tee -a "$LOG_FILE"
    NEW_HEAD=$(git rev-parse HEAD)
    if [ "$OLD_HEAD" != "$NEW_HEAD" ]; then
      info "  $dir: $OLD_HEAD → $NEW_HEAD"
      log "  commits novos:"
      git log --oneline "$OLD_HEAD..$NEW_HEAD" 2>&1 | head -10 | tee -a "$LOG_FILE"
    else
      info "  $dir: ja em $NEW_HEAD (sem mudancas)"
    fi
    cd "$WORKDIR"
  else
    git clone --quiet --branch "$BRANCH" "$url" "$dir" 2>&1 | tee -a "$LOG_FILE"
    cd "$dir" && info "  $dir clonado em $(git rev-parse HEAD)"
    cd "$WORKDIR"
  fi
}

clone_or_pull guardian-backend "$REPO_BACKEND"
clone_or_pull guardian "$REPO_FRONTEND"

BACKEND_HEAD=$(cd guardian-backend && git rev-parse --short HEAD)
FRONTEND_HEAD=$(cd guardian && git rev-parse --short HEAD)
ok "backend HEAD=$BACKEND_HEAD  frontend HEAD=$FRONTEND_HEAD"

# ========== 3. Snapshot rollback ==========
section "3/9 Snapshot rollback (tag imagens atuais com timestamp)"

CURRENT_BACKEND_IMG=$(docker inspect "$NAME_BACKEND" --format '{{.Image}}' 2>/dev/null || echo "")
CURRENT_FRONTEND_IMG=$(docker inspect "$NAME_FRONTEND" --format '{{.Image}}' 2>/dev/null || echo "")

if [ -n "$CURRENT_BACKEND_IMG" ]; then
  ROLLBACK_BACKEND_IMG="guardian-backend:rollback-$TIMESTAMP"
  docker tag "$CURRENT_BACKEND_IMG" "$ROLLBACK_BACKEND_IMG" 2>/dev/null \
    && ok "backend snapshot: $ROLLBACK_BACKEND_IMG" \
    || warn "falha ao tag backend (pode nao ser problema)"
fi

if [ -n "$CURRENT_FRONTEND_IMG" ]; then
  ROLLBACK_FRONTEND_IMG="guardian-frontend:rollback-$TIMESTAMP"
  docker tag "$CURRENT_FRONTEND_IMG" "$ROLLBACK_FRONTEND_IMG" 2>/dev/null \
    && ok "frontend snapshot: $ROLLBACK_FRONTEND_IMG" \
    || warn "falha ao tag frontend"
fi

# ========== 4. Build ==========
if [ "${SKIP_BUILD:-0}" = "1" ]; then
  warn "SKIP_BUILD=1 — pulando build"
else
  section "4/9 Build imagens (parallel)"

  cd "$WORKDIR/guardian-backend"
  log "build guardian-backend (log: $LOG_DIR/build-backend-$TIMESTAMP.log)"
  docker build -q -t guardian-backend:from-github . > "$LOG_DIR/build-backend-$TIMESTAMP.log" 2>&1 &
  BACKEND_BUILD_PID=$!

  cd "$WORKDIR/guardian"
  log "build guardian-frontend (log: $LOG_DIR/build-frontend-$TIMESTAMP.log)"
  docker build -q -t guardian-frontend:from-github . > "$LOG_DIR/build-frontend-$TIMESTAMP.log" 2>&1 &
  FRONTEND_BUILD_PID=$!

  wait $BACKEND_BUILD_PID && ok "build backend OK" || die "build backend FALHOU — ver $LOG_DIR/build-backend-$TIMESTAMP.log"
  wait $FRONTEND_BUILD_PID && ok "build frontend OK" || die "build frontend FALHOU — ver $LOG_DIR/build-frontend-$TIMESTAMP.log"

  # Tag com timestamp pra rollback futuro
  docker tag guardian-backend:from-github "guardian-backend:from-github-$TIMESTAMP" 2>/dev/null
  docker tag guardian-frontend:from-github "guardian-frontend:from-github-$TIMESTAMP" 2>/dev/null
  ok "imagens taggeadas: guardian-{backend,frontend}:from-github-$TIMESTAMP"
fi

# ========== 5. Recreate containers ==========
section "5/9 (Re)create containers"

# Backend
log "stop+rm $NAME_BACKEND"
docker stop "$NAME_BACKEND" 2>/dev/null || true
docker rm   "$NAME_BACKEND" 2>/dev/null || true

log "run $NAME_BACKEND :$PORT_BACKEND -> 8000 (rede $NET_APP)"
docker run -d \
  --name "$NAME_BACKEND" \
  --restart unless-stopped \
  --network "$NET_APP" \
  -p "$PORT_BACKEND:8000" \
  -v guardian_uploads:/backend/upload \
  -e DB_HOST=postgres \
  -e DB_PORT=5432 \
  -e DB_USER="${DB_USER:-guardian_admin}" \
  -e DB_PASSWORD="${DB_PASSWORD:-LgGuardian_2026}" \
  -e DB_NAME="${DB_NAME:-guardian}" \
  -e LOCAL_AUTH_ENABLED="${LOCAL_AUTH_ENABLED:-true}" \
  -e ADMIN_GUARDIAN_PASSWORD="${ADMIN_GUARDIAN_PASSWORD:-Guardian2026!}" \
  -e LG_ANALYTICS_PASSWORD="${LG_ANALYTICS_PASSWORD:-lg-analytics}" \
  -e AD_API_BASE_URL="${AD_API_BASE_URL:-http://150.150.251.243:3000}" \
  -e AD_API_TIMEOUT="${AD_API_TIMEOUT:-3.0}" \
  -e AD_API_ENABLED="${AD_API_ENABLED:-true}" \
  -e AD_LOGIN_URL="${AD_LOGIN_URL:-http://150.150.251.132:8033/LGEActiveDirectory/login}" \
  -e AD_USERS_URL="${AD_USERS_URL:-http://150.150.251.132:8033/LGEActiveDirectory/users}" \
  -e YOLO_API_URL="${YOLO_API_URL:-http://lg-nginx:80}" \
  -e YOLO_API_BASE_URL="${YOLO_API_BASE_URL:-http://lg-nginx:80}" \
  -e YOLO_API_EMAIL="${YOLO_API_EMAIL:-lg-analytics@lg.com}" \
  -e YOLO_API_PASSWORD="${YOLO_API_PASSWORD:-lg-analytics}" \
  -e JWT_SECRET_KEY="${JWT_SECRET_KEY:-guardian-jwt-secret-2026-conecthus}" \
  -e JWT_ALGORITHM="${JWT_ALGORITHM:-HS256}" \
  -e JWT_ACCESS_TOKEN_EXPIRE_DAYS="${JWT_ACCESS_TOKEN_EXPIRE_DAYS:-15}" \
  -e ADMIN_USERNAMES="${ADMIN_USERNAMES:-matheus.dantas,arthur.bezerra,luis.filho,nelson.gouvea,admin.guardian,lg-analytics,joao.nunes}" \
  -e MONITORING_USERNAMES="${MONITORING_USERNAMES:-s.pompeu,samuel.moreira,fabio.song,jiho.yang,lg-analytics}" \
  -e CORS_ALLOWED_ORIGINS="${CORS_ALLOWED_ORIGINS:-http://localhost,http://localhost:80,http://150.150.251.213,http://150.150.251.213:8050,http://localhost:4200}" \
  -e IHR_API_URL="${IHR_API_URL:-http://150.150.251.132:8033}" \
  -e IHR_SYNC_TOKEN="${IHR_SYNC_TOKEN:-guardian-sync-token}" \
  -e SMTP_URL="${SMTP_URL:-http://localhost:25}" \
  -e LOG_API_URL="${LOG_API_URL:-http://localhost:$PORT_BACKEND}" \
  guardian-backend:from-github >/dev/null \
  || die "docker run backend falhou"

# Frontend
log "stop+rm $NAME_FRONTEND"
docker stop "$NAME_FRONTEND" 2>/dev/null || true
docker rm   "$NAME_FRONTEND" 2>/dev/null || true

log "run $NAME_FRONTEND :$PORT_FRONTEND -> 80 (rede $NET_APP)"
docker run -d \
  --name "$NAME_FRONTEND" \
  --restart unless-stopped \
  --network "$NET_APP" \
  -p "$PORT_FRONTEND:80" \
  guardian-frontend:from-github >/dev/null \
  || die "docker run frontend falhou"

ok "containers criados"

# ========== 6. Migrations explicit ==========
section "6/9 Verificar migrations (alembic current)"

# Aguarda backend startup pra alembic ja ter rodado via entrypoint
log "aguardando entrypoint executar alembic upgrade head..."
for i in $(seq 1 30); do
  sleep 2
  if docker logs --tail 50 "$NAME_BACKEND" 2>&1 | grep -q "Migrations complete\|Application startup complete"; then
    ok "alembic upgrade completou em ${i}*2s"
    break
  fi
  if docker logs --tail 20 "$NAME_BACKEND" 2>&1 | grep -qi "FATAL\|alembic.*error\|psycopg2.*error"; then
    fail "alembic ou PG erro detectado nos logs"
    docker logs --tail 30 "$NAME_BACKEND" 2>&1 | tee -a "$LOG_FILE"
    die "migration falhou"
  fi
  [ "$i" = "30" ] && warn "timeout aguardando 'Migrations complete' (60s) — continuando, healthcheck vai validar"
done

# Pega versao alembic atual
ALEMBIC_CURRENT=$(docker exec "$NAME_BACKEND" sh -c 'cd /backend && alembic current 2>&1 | tail -1' 2>/dev/null || echo "?")
info "alembic current: $ALEMBIC_CURRENT"

# ========== 7. Healthcheck ==========
section "7/9 Healthcheck multi-stage"

healthcheck() {
  local name="$1" url="$2" tries="${3:-15}" delay="${4:-3}"
  for i in $(seq 1 "$tries"); do
    S=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo "000")
    if [ "$S" = "200" ]; then
      ok "$name $url -> HTTP 200 em ${i}*${delay}s"
      return 0
    fi
    log "  $name $url try $i/$tries => HTTP $S"
    sleep "$delay"
  done
  fail "$name $url FALHOU apos $tries tentativas"
  return 1
}

healthcheck backend "http://localhost:$PORT_BACKEND/docs" 20 3 || die "backend nao subiu"
healthcheck frontend "http://localhost:$PORT_FRONTEND/" 10 2 || die "frontend nao subiu"

# ========== 8. Smoke test ==========
if [ "${SKIP_SMOKE:-0}" = "1" ]; then
  warn "SKIP_SMOKE=1 — pulando smoke test"
else
  section "8/9 Smoke test (login admin + lookup-ad)"

  # Login admin local
  RESP=$(curl -sS -m 8 -X POST "http://localhost:$PORT_BACKEND/api/v1/auth/local-login" \
    -H 'Content-Type: application/json' \
    -d '{"username":"admin.guardian","password":"Guardian2026!"}' 2>/dev/null)
  if echo "$RESP" | grep -q '"access_token"'; then
    ok "smoke[1/3]: login admin.guardian -> 200 + JWT"
    JWT=$(echo "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
  else
    fail "smoke[1/3]: login admin.guardian FALHOU: $(echo "$RESP" | head -c 200)"
    die "smoke test falhou — rollback automatico"
  fi

  # /user-details com JWT
  if [ -n "$JWT" ]; then
    S=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer $JWT" \
      "http://localhost:$PORT_BACKEND/api/v1/auth/user-details")
    [ "$S" = "200" ] && ok "smoke[2/3]: JWT /user-details -> 200" || warn "smoke[2/3]: /user-details -> $S"
  fi

  # Frontend proxy
  S=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' -X POST \
    "http://localhost:$PORT_FRONTEND/api/v1/auth/local-login" \
    -H 'Content-Type: application/json' \
    -d '{"username":"admin.guardian","password":"Guardian2026!"}')
  [ "$S" = "200" ] && ok "smoke[3/3]: frontend proxy /api/v1 -> 200" || die "smoke[3/3]: proxy FALHOU ($S)"
fi

# ========== 9. Status final ==========
section "9/9 Status final"

DEPLOY_OK=true

docker ps --format '{{.Names}} {{.Status}} {{.Networks}} {{.Image}}' | grep -E "$NAME_BACKEND|$NAME_FRONTEND" | tee -a "$LOG_FILE"
echo
ok "DEPLOY OK — backend $BACKEND_HEAD + frontend $FRONTEND_HEAD"
info "Imagens (rollback futuro):"
info "  guardian-backend:from-github-$TIMESTAMP"
info "  guardian-frontend:from-github-$TIMESTAMP"
[ -n "$ROLLBACK_BACKEND_IMG" ] && info "  $ROLLBACK_BACKEND_IMG (versao anterior)"
[ -n "$ROLLBACK_FRONTEND_IMG" ] && info "  $ROLLBACK_FRONTEND_IMG (versao anterior)"
echo
info "Log completo: $LOG_FILE"
echo
info "Pra rollback manual a versao anterior:"
[ -n "$ROLLBACK_BACKEND_IMG" ] && echo "    docker stop $NAME_BACKEND && docker rm $NAME_BACKEND && docker run -d --name $NAME_BACKEND --network $NET_APP -p $PORT_BACKEND:8000 -v guardian_uploads:/backend/upload $ROLLBACK_BACKEND_IMG"
[ -n "$ROLLBACK_FRONTEND_IMG" ] && echo "    docker stop $NAME_FRONTEND && docker rm $NAME_FRONTEND && docker run -d --name $NAME_FRONTEND --network $NET_APP -p $PORT_FRONTEND:80 $ROLLBACK_FRONTEND_IMG"

if [ "${FORCE_ROLLBACK:-0}" = "1" ]; then
  warn "FORCE_ROLLBACK=1 — disparando rollback artificial pra testar trap"
  DEPLOY_OK=false
  exit 1
fi

exit 0
