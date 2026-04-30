#!/bin/bash
# ============================================================
# validate-ad-auth.sh — valida cadeia AD → Backend → Frontend
# pra garantir que login do Guardian funciona junto ao AD da LG.
#
# RODA DENTRO DO SERVIDOR LG (150.150.251.213) — depende de
# alcance interno a 150.150.251.243:3000 (AD/HR API) e
# 150.150.251.132:8033 (AD legado).
#
# Uso (one-liner):
#   curl -sL https://raw.githubusercontent.com/MatheusLedstar/gd-boot/main/validate-ad-auth.sh | bash
#
# Com user/senha custom (env vars):
#   AD_USER=joao.nunes AD_PASS='senha-real' bash <(curl -sL ...)
#
# Saidas:
#   exit 0 = todos os testes passaram
#   exit 1 = pelo menos 1 teste critico falhou (login UI quebra)
#   exit 2 = teste opcional falhou (login funciona, mas algo
#            secundario tem issue)
# ============================================================
set -uo pipefail

# ──────────── Config ────────────
AD_API_BASE="${AD_API_BASE_URL:-http://150.150.251.243:3000}"
AD_LEGACY_BASE="${AD_LEGACY_BASE:-http://150.150.251.132:8033}"
BACKEND_HOST="${BACKEND_HOST:-localhost}"
BACKEND_PORT="${BACKEND_PORT:-8004}"
FRONTEND_HOST="${FRONTEND_HOST:-localhost}"
FRONTEND_PORT="${FRONTEND_PORT:-8050}"
PG_CONTAINER="${PG_CONTAINER:-guardian}"
PG_USER="${PG_USER:-guardian_admin}"
PG_PASS="${PG_PASS:-LgGuardian_2026}"
PG_DB="${PG_DB:-guardian}"

# User AD pra testar autenticacao real (precisa setar via env)
AD_USER="${AD_USER:-}"
AD_PASS="${AD_PASS:-}"

# Senhas locais conhecidas (default da Dockerfile)
LOCAL_USER="${LOCAL_USER:-admin.guardian}"
LOCAL_PASS="${LOCAL_PASS:-Guardian2026!}"

PASS=0
FAIL=0
WARN=0

# ──────────── Helpers ────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYA='\033[0;36m'; NC='\033[0m'

ok()   { echo -e "  ${GRN}✓${NC} $*"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}✗${NC} $*"; FAIL=$((FAIL+1)); }
warn() { echo -e "  ${YLW}⚠${NC} $*"; WARN=$((WARN+1)); }
info() { echo -e "  ${CYA}ℹ${NC} $*"; }

section() {
  echo ""
  echo -e "${CYA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${CYA}  $*${NC}"
  echo -e "${CYA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

http_status() {
  curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "$@" 2>/dev/null
}

http_body_status() {
  # imprime "STATUS|BODY" — STATUS = 3 digitos, BODY = resposta (1-line escaped)
  local out
  out=$(curl -sS --max-time 8 -w '___HTTP___%{http_code}' "$@" 2>/dev/null)
  local body="${out%___HTTP___*}"
  local status="${out##*___HTTP___}"
  echo "$status|$body"
}

# ──────────── PRE-CHECK ────────────
section "PRE-CHECK — ferramentas e containers"

command -v curl >/dev/null && ok "curl disponivel" || { fail "curl nao instalado"; exit 1; }
command -v jq >/dev/null && ok "jq disponivel" || warn "jq ausente — output JSON sera bruto"
command -v docker >/dev/null && ok "docker CLI disponivel" || warn "docker CLI ausente — pulo testes de container"

if command -v docker >/dev/null && docker ps --format '{{.Names}}' | grep -qx "guardian-app-main"; then
  ok "guardian-app-main esta UP"
  BE_STATUS=$(docker inspect guardian-app-main --format '{{.State.Status}}' 2>/dev/null)
  info "  status=$BE_STATUS"
else
  warn "guardian-app-main nao esta UP — testes de backend podem falhar"
fi

if command -v docker >/dev/null && docker ps --format '{{.Names}}' | grep -qx "guardian-frontend-main"; then
  ok "guardian-frontend-main esta UP"
else
  warn "guardian-frontend-main nao esta UP — testes de frontend serao pulados"
fi

# ──────────── T1 — AD API alcancavel ────────────
section "T1 — AD API base ($AD_API_BASE)"

# Endpoint root pode 404, mas o /swagger/docs/v1 deveria responder 200
S=$(http_status "$AD_API_BASE/swagger/docs/v1")
case "$S" in
  200|301|302) ok "AD API responde no Swagger ($AD_API_BASE/swagger/docs/v1) — HTTP $S" ;;
  000) fail "AD API NAO ALCANCAVEL ($AD_API_BASE) — sem rota/firewall ou servico down. Login AD vai quebrar." ;;
  404) warn "Swagger 404 mas servico responde — testa autenticacao direto (T2)" ;;
  *)   warn "AD API respondeu $S no /swagger — comportamento inesperado" ;;
esac

# ──────────── T2 — POST /api/ad/authenticate (user invalido) ────────────
section "T2 — AD authenticate REJEITA user invalido (controle negativo)"

INVALID_USER="usuario.que.nao.existe.999"
INVALID_PASS="senha-totalmente-invalida"
RESP=$(curl -sS --max-time 8 -X POST \
  "$AD_API_BASE/api/ad/authenticate?userId=${INVALID_USER}&password=${INVALID_PASS}" \
  -H 'Accept: application/json' \
  -H 'Content-Length: 0' \
  --data '' \
  -w '\n___HTTP___%{http_code}' 2>/dev/null)
S=$(echo "$RESP" | grep -oE '___HTTP___[0-9]+' | sed 's/___HTTP___//')
B=$(echo "$RESP" | grep -v '___HTTP___')

if [ "$S" = "200" ]; then
  if echo "$B" | grep -q '"IsAuthenticated":[ ]*false'; then
    ok "AD rejeita user invalido (IsAuthenticated=false) — controle OK"
  elif echo "$B" | grep -q '"IsAuthenticated":[ ]*true'; then
    fail "AD aceitou user FAKE como autenticado — bypass critico de seguranca!"
  else
    warn "Resposta inesperada (sem IsAuthenticated): $(echo "$B" | head -c 200)"
  fi
elif [ "$S" = "401" ] || [ "$S" = "403" ]; then
  ok "AD rejeita user invalido (HTTP $S)"
elif [ "$S" = "000" ]; then
  fail "AD authenticate nao alcancavel ($AD_API_BASE/api/ad/authenticate)"
elif [ "$S" = "411" ]; then
  fail "HTTP 411 Length Required — falta Content-Length: 0 no POST. ad_client.py ja faz isso, mas se falhar aqui, replicar fix em outras chamadas."
else
  warn "AD authenticate retornou HTTP $S inesperado: $(echo "$B" | head -c 100)"
fi

# ──────────── T3 — POST /api/ad/authenticate (user valido — opcional) ────────────
if [ -n "$AD_USER" ] && [ -n "$AD_PASS" ]; then
  section "T3 — AD authenticate ACEITA user valido ($AD_USER)"

  RESP=$(curl -sS --max-time 8 -X POST \
    "$AD_API_BASE/api/ad/authenticate?userId=${AD_USER}&password=${AD_PASS}" \
    -H 'Accept: application/json' \
    -H 'Content-Length: 0' \
    --data '' \
    -w '\n___HTTP___%{http_code}' 2>/dev/null)
  S=$(echo "$RESP" | grep -oE '___HTTP___[0-9]+' | sed 's/___HTTP___//')
  B=$(echo "$RESP" | grep -v '___HTTP___')

  if [ "$S" = "200" ] && echo "$B" | grep -q '"IsAuthenticated":[ ]*true'; then
    ok "AD aceita user $AD_USER (IsAuthenticated=true)"
    if command -v jq >/dev/null; then
      DOMAIN=$(echo "$B" | jq -r .UserDomain 2>/dev/null)
      info "  domain=$DOMAIN"
    fi
  elif [ "$S" = "200" ] && echo "$B" | grep -q '"IsAuthenticated":[ ]*false'; then
    fail "AD rejeitou $AD_USER (IsAuthenticated=false). Senha invalida OU user nao existe no LDAP://LGE.NET:636."
  elif [ "$S" = "000" ]; then
    fail "AD authenticate nao respondeu — erro de rede"
  else
    fail "AD authenticate HTTP $S: $(echo "$B" | head -c 200)"
  fi
else
  section "T3 — AD authenticate ACEITA user valido (PULADO)"
  info "Setar AD_USER e AD_PASS pra rodar este teste"
  info "Exemplo: AD_USER=joao.nunes AD_PASS='SuaSenhaAD' bash <(curl -sL ...)"
fi

# ──────────── T4 — GET /api/hr/employee/get (HR metadata) ────────────
section "T4 — HR /api/hr/employee/get (metadata do funcionario)"

# Usa AD_USER se disponivel, senao tenta admin generico
PROBE_USER="${AD_USER:-admin.guardian}"
RESP=$(curl -sS --max-time 8 \
  "$AD_API_BASE/api/hr/employee/get?parameters.userName=${PROBE_USER}" \
  -H 'Accept: application/json' \
  -w '\n___HTTP___%{http_code}' 2>/dev/null)
S=$(echo "$RESP" | grep -oE '___HTTP___[0-9]+' | sed 's/___HTTP___//')
B=$(echo "$RESP" | grep -v '___HTTP___')

if [ "$S" = "200" ]; then
  if echo "$B" | grep -qE '"GlobalId"|"UserName"|"Email"'; then
    ok "HR API retornou metadata do user $PROBE_USER"
    if command -v jq >/dev/null; then
      NAME=$(echo "$B" | jq -r '.[0].Name // "?"' 2>/dev/null)
      DEP=$(echo "$B" | jq -r '.[0].DepartmentName // "?"' 2>/dev/null)
      EMAIL=$(echo "$B" | jq -r '.[0].Email // "?"' 2>/dev/null)
      info "  Name=$NAME  Dept=$DEP  Email=$EMAIL"
    fi
  elif echo "$B" | grep -qE '^\[\]$|"length":[ ]*0'; then
    warn "HR API respondeu vazio — user $PROBE_USER nao tem registro RH (esperado pra usuarios system tipo admin.guardian)"
  else
    warn "HR API resposta sem campos esperados: $(echo "$B" | head -c 200)"
  fi
elif [ "$S" = "000" ]; then
  fail "HR API nao alcancavel ($AD_API_BASE/api/hr/employee/get) — primeira auth de user novo vai falhar (sem dados pra criar registro local)"
else
  fail "HR API HTTP $S: $(echo "$B" | head -c 200)"
fi

# ──────────── T5 — AD legado ($AD_LEGACY_BASE) ────────────
section "T5 — AD legado ($AD_LEGACY_BASE) — fallback de /login antigo"

S=$(http_status "$AD_LEGACY_BASE/LGEActiveDirectory/login")
case "$S" in
  200|400|405) ok "AD legado responde (HTTP $S)" ;;
  000) warn "AD legado nao alcancavel — OK se nao usar /login (so /local-login)" ;;
  *)   info "AD legado HTTP $S — verificar manualmente" ;;
esac

# ──────────── T6 — Backend Guardian /api/v1/auth/local-login ────────────
section "T6 — Backend $BACKEND_HOST:$BACKEND_PORT/api/v1/auth/local-login"

# 6a: login local (admin.guardian) — nao depende de AD
S_LOCAL=$(http_status -X POST \
  "http://${BACKEND_HOST}:${BACKEND_PORT}/api/v1/auth/local-login" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"$LOCAL_USER\",\"password\":\"$LOCAL_PASS\"}")
if [ "$S_LOCAL" = "200" ]; then
  ok "Backend aceita LOCAL ($LOCAL_USER) — auth_source=local funciona"
elif [ "$S_LOCAL" = "401" ]; then
  fail "Backend rejeitou $LOCAL_USER (HTTP 401) — senha local nao bate. Conferir env ADMIN_GUARDIAN_PASSWORD do container"
elif [ "$S_LOCAL" = "404" ]; then
  fail "Backend HTTP 404 — endpoint nao existe. Frontend pode estar chamando URL errada (/auth/login vs /auth/local-login)"
elif [ "$S_LOCAL" = "000" ]; then
  fail "Backend nao responde em $BACKEND_HOST:$BACKEND_PORT — container down ou crash startup"
else
  fail "Backend HTTP $S_LOCAL inesperado"
fi

# 6b: login AD via backend (so se AD_USER setado)
if [ -n "$AD_USER" ] && [ -n "$AD_PASS" ]; then
  RESP=$(curl -sS --max-time 12 -X POST \
    "http://${BACKEND_HOST}:${BACKEND_PORT}/api/v1/auth/local-login" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"$AD_USER\",\"password\":\"$AD_PASS\"}" \
    -w '\n___HTTP___%{http_code}' 2>/dev/null)
  S=$(echo "$RESP" | grep -oE '___HTTP___[0-9]+' | sed 's/___HTTP___//')
  B=$(echo "$RESP" | grep -v '___HTTP___')

  if [ "$S" = "200" ]; then
    if echo "$B" | grep -q '"auth_source":[ ]*"ad"'; then
      ok "Backend aceitou $AD_USER via AD (auth_source=ad)"
      JWT=$(echo "$B" | grep -oE '"access_token":[ ]*"[^"]+"' | sed 's/"access_token":[ ]*"//;s/"$//')
      [ -n "$JWT" ] && info "  JWT recebido (${#JWT} chars)"

      # T7: validar JWT em /user-details
      U_S=$(http_status -H "Authorization: Bearer $JWT" \
        "http://${BACKEND_HOST}:${BACKEND_PORT}/api/v1/auth/user-details")
      [ "$U_S" = "200" ] \
        && ok "JWT do AD aceito em /user-details (E2E full chain OK)" \
        || fail "JWT do AD rejeitado em /user-details (HTTP $U_S)"
    elif echo "$B" | grep -q '"auth_source":[ ]*"local"'; then
      warn "Backend autenticou via LOCAL em vez de AD — usuario ja existia no PG. OK se foi criado em sessao anterior."
    else
      warn "Backend 200 mas sem auth_source: $(echo "$B" | head -c 200)"
    fi
  elif [ "$S" = "401" ]; then
    fail "Backend rejeitou $AD_USER via AD — verificar (a) senha AD, (b) AD_API_ENABLED=true no container, (c) AD_API_BASE_URL aponta pra 150.150.251.243:3000"
  elif [ "$S" = "503" ]; then
    fail "Backend retornou 503 — AD_API_ENABLED=false no container. Setar AD_API_ENABLED=true e restartar."
  else
    fail "Backend HTTP $S em login AD: $(echo "$B" | head -c 200)"
  fi
else
  warn "Login AD via backend PULADO — setar AD_USER/AD_PASS pra testar E2E"
fi

# ──────────── T7 — Env vars AD no backend ────────────
section "T7 — Env vars AD no container guardian-app-main"

if command -v docker >/dev/null && docker inspect guardian-app-main >/dev/null 2>&1; then
  ENV_DUMP=$(docker exec guardian-app-main env 2>/dev/null | grep -E '^(AD_|YOLO_API_|DB_|LOCAL_AUTH)' | sort)
  echo "$ENV_DUMP" | grep -E '^AD_' | while read line; do echo "  $line"; done

  echo "$ENV_DUMP" | grep -q 'AD_API_BASE_URL=' && ok "AD_API_BASE_URL setado" || warn "AD_API_BASE_URL ausente (usando default $AD_API_BASE)"
  echo "$ENV_DUMP" | grep -q 'AD_API_ENABLED=true' && ok "AD_API_ENABLED=true" || warn "AD_API_ENABLED nao=true (login AD vai retornar 503)"
  echo "$ENV_DUMP" | grep -q 'AD_LOGIN_URL=' && ok "AD_LOGIN_URL setado (legado)" || info "AD_LOGIN_URL ausente — OK se usar so /local-login"

  # DNS de 150.150.251.243 desde o container
  if docker exec guardian-app-main getent hosts 150.150.251.243 >/dev/null 2>&1; then
    ok "container resolve 150.150.251.243 (AD/HR API)"
  else
    info "  (IP literal nao precisa DNS, so testando rotinas)"
  fi
  C_S=$(docker exec guardian-app-main curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
    "$AD_API_BASE/swagger/docs/v1" 2>/dev/null)
  case "$C_S" in
    200|301|302) ok "container alcanca AD API ($AD_API_BASE) — HTTP $C_S" ;;
    000) fail "container NAO alcanca $AD_API_BASE — firewall/route ausente. Login AD vai timeout 3s e falhar." ;;
    *)   info "container -> AD API HTTP $C_S" ;;
  esac
else
  warn "guardian-app-main nao acessivel — pulando inspecao de envs"
fi

# ──────────── T8 — Frontend proxy → backend ────────────
section "T8 — Frontend nginx ($FRONTEND_HOST:$FRONTEND_PORT) proxy"

S_FE=$(http_status "http://${FRONTEND_HOST}:${FRONTEND_PORT}/")
[ "$S_FE" = "200" ] && ok "Frontend serve / (HTTP 200)" || warn "Frontend HTTP $S_FE em /"

# Login via frontend proxy (deveria roteer pro backend)
S_FE_LOGIN=$(http_status -X POST \
  "http://${FRONTEND_HOST}:${FRONTEND_PORT}/api/v1/auth/local-login" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"$LOCAL_USER\",\"password\":\"$LOCAL_PASS\"}")
case "$S_FE_LOGIN" in
  200) ok "Frontend proxy -> backend funciona (login local via :$FRONTEND_PORT)" ;;
  502) fail "Frontend proxy 502 — backend unreachable. Conferir alias 'guardian-app-main' na rede lg-app." ;;
  404) fail "Frontend proxy 404 — nginx.conf do frontend pode estar com upstream errado ou rota /api/v1 nao mapeada." ;;
  401) warn "Frontend proxy chega no backend mas auth falhou (HTTP 401). Senha local errada?" ;;
  000) fail "Frontend nao responde em :$FRONTEND_PORT" ;;
  *)   warn "Frontend proxy HTTP $S_FE_LOGIN — investigar manualmente" ;;
esac

# ──────────── T9 — User criado no PG apos login AD ────────────
if command -v docker >/dev/null && docker inspect "$PG_CONTAINER" >/dev/null 2>&1 && [ -n "$AD_USER" ]; then
  section "T9 — User AD existe na tabela employees (PG)"

  PG_OUT=$(docker exec -e PGPASSWORD="$PG_PASS" "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -t -A -c \
    "SELECT username, name, email, role, auth_source FROM employees WHERE username='$AD_USER';" 2>&1)
  if echo "$PG_OUT" | grep -q "$AD_USER"; then
    ok "User $AD_USER existe na tabela employees:"
    echo "  $PG_OUT" | head -3
  else
    warn "User $AD_USER NAO encontrado em employees (sera criado no proximo login bem-sucedido)"
  fi
fi

# ──────────── RESUMO ────────────
echo ""
echo -e "${CYA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYA}  RESUMO${NC}"
echo -e "${CYA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${GRN}PASS: $PASS${NC}"
[ $WARN -gt 0 ] && echo -e "  ${YLW}WARN: $WARN${NC}"
[ $FAIL -gt 0 ] && echo -e "  ${RED}FAIL: $FAIL${NC}"

echo ""
if [ $FAIL -eq 0 ]; then
  echo -e "${GRN}✓ Login AD funcional — frontend pode autenticar via /api/v1/auth/local-login${NC}"
  exit 0
else
  echo -e "${RED}✗ Cadeia AD quebrada — corrigir os FAIL acima antes de validar UI${NC}"
  echo ""
  echo "Para fix mais comum (AD_API_ENABLED ou alcance):"
  echo "  docker exec guardian-app-main env | grep ^AD_"
  echo "  docker exec guardian-app-main curl -m 5 $AD_API_BASE/swagger/docs/v1 -o /dev/null -w '%{http_code}\\n'"
  exit 1
fi
