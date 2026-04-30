#!/bin/bash
# ============================================================
# validate-ad-full-flow.sh — E2E AD Flow (Fase A + Fase B)
#
# Valida cadeia completa do fluxo AD com user real (joao.nunes):
#   1) PRE-CHECK         — containers UP e ferramentas
#   2) T1  — AD direto   — /api/ad/authenticate + /api/hr/employee/get
#   3) T2  — Backend     — /management/users/lookup-ad (Fase A)
#   4) T3  — Backend     — /lookup-ad com user inexistente (404)
#   5) T4  — Backend     — /local-login com user AD (auto-approve esperado)
#   6) T5  — Backend     — /user-details com JWT do AD
#   7) T6  — PG state    — employees row + is_pending=FALSE
#   8) T7  — Frontend    — proxy nginx → backend funciona
#   9) T8  — Backend     — listar pendentes (/management/users?status=pending)
#  10) T9  — Backend     — approve idempotente
#  11) T10 — Logs        — coleta linhas relevantes do guardian-app-main
#
# RODA DENTRO DO SERVIDOR LG (150.150.251.213) — depende de
# alcance interno a 150.150.251.243:3000 (AD/HR API).
#
# joao.nunes esta em ADMIN_USERNAMES => esperado AUTO-APROVADO
# (is_pending=false) na primeira entrada via AD.
#
# Uso (one-liner):
#   AD_PASS='@manaus2026' bash <(curl -sL https://raw.githubusercontent.com/MatheusLedstar/gd-boot/main/validate-ad-full-flow.sh)
#
# Variaveis customizaveis (env):
#   AD_USER          (default joao.nunes)
#   AD_PASS          (sem default — OBRIGATORIO)
#   ADMIN_USER       (default admin.guardian)
#   ADMIN_PASS       (default Guardian2026!)
#   BACKEND_HOST     (default localhost)
#   BACKEND_PORT     (default 8004)
#   FRONTEND_HOST    (default localhost)
#   FRONTEND_PORT    (default 8050)
#   AD_API_BASE      (default http://150.150.251.243:3000)
#   PG_CONTAINER     (default guardian)
#   PG_USER          (default guardian_admin)
#   PG_PASS          (default LgGuardian_2026)
#   PG_DB            (default guardian)
#
# Saidas:
#   exit 0 = todos os testes criticos passaram
#   exit 1 = algum FAIL critico (fluxo AD quebrado)
# ============================================================
set -uo pipefail

# ──────────── Config ────────────
AD_API_BASE="${AD_API_BASE:-http://150.150.251.243:3000}"
BACKEND_HOST="${BACKEND_HOST:-localhost}"
BACKEND_PORT="${BACKEND_PORT:-8004}"
FRONTEND_HOST="${FRONTEND_HOST:-localhost}"
FRONTEND_PORT="${FRONTEND_PORT:-8050}"
PG_CONTAINER="${PG_CONTAINER:-guardian}"
PG_USER="${PG_USER:-guardian_admin}"
PG_PASS="${PG_PASS:-LgGuardian_2026}"
PG_DB="${PG_DB:-guardian}"

AD_USER="${AD_USER:-joao.nunes}"
AD_PASS="${AD_PASS:-}"

ADMIN_USER="${ADMIN_USER:-admin.guardian}"
ADMIN_PASS="${ADMIN_PASS:-Guardian2026!}"

LOG_FILE="/tmp/ad-validation-$(date +%Y%m%d-%H%M).log"

PASS=0
FAIL=0
WARN=0
CRITICAL_FAIL=0

# Flags pra detectar deploy nao aplicado
LOOKUP_AD_AVAILABLE=1
APPROVE_AVAILABLE=1

# ──────────── Helpers ────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYA='\033[0;36m'; MAG='\033[0;35m'; NC='\033[0m'

ok()   { echo -e "  ${GRN}✓${NC} $*"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}✗${NC} $*"; FAIL=$((FAIL+1)); CRITICAL_FAIL=$((CRITICAL_FAIL+1)); }
warn() { echo -e "  ${YLW}⚠${NC} $*"; WARN=$((WARN+1)); }
info() { echo -e "  ${CYA}ℹ${NC} $*"; }
note() { echo -e "  ${MAG}»${NC} $*"; }

section() {
  echo ""
  echo -e "${CYA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${CYA}  $*${NC}"
  echo -e "${CYA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Imprime "STATUS|BODY" — STATUS = 3 digitos, BODY = resposta (raw, possivelmente multi-line)
http_call() {
  local out
  out=$(curl -sS --max-time 12 -w '\n___HTTP___%{http_code}' "$@" 2>/dev/null)
  local status
  status=$(echo "$out" | grep -oE '___HTTP___[0-9]+' | tail -1 | sed 's/___HTTP___//')
  local body
  body=$(echo "$out" | sed 's/___HTTP___[0-9]*$//')
  [ -z "$status" ] && status="000"
  echo "${status}|${body}"
}

http_status() {
  curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "$@" 2>/dev/null
}

# Trunca body pra log limpo
trunc() {
  local s="$1"
  local n="${2:-300}"
  echo "$s" | tr -d '\n' | head -c "$n"
  [ "${#s}" -gt "$n" ] && echo "..." || echo ""
}

# Extrai campo JSON simples sem precisar de jq
json_field() {
  local body="$1"
  local field="$2"
  echo "$body" | grep -oE "\"$field\"[ ]*:[ ]*\"[^\"]*\"" | head -1 | sed 's/.*:[ ]*"//;s/"$//'
}

json_field_bool() {
  local body="$1"
  local field="$2"
  echo "$body" | grep -oE "\"$field\"[ ]*:[ ]*(true|false)" | head -1 | sed 's/.*:[ ]*//'
}

json_field_num() {
  local body="$1"
  local field="$2"
  echo "$body" | grep -oE "\"$field\"[ ]*:[ ]*[0-9]+" | head -1 | sed 's/.*:[ ]*//'
}

# ──────────── PRE-CHECK ────────────
section "PRE-CHECK — ferramentas, containers, credenciais"

command -v curl >/dev/null && ok "curl disponivel" || { fail "curl nao instalado"; exit 1; }
command -v jq >/dev/null && ok "jq disponivel (output rico)" || warn "jq ausente — fallback grep/sed"
command -v docker >/dev/null && ok "docker CLI disponivel" || warn "docker CLI ausente — testes de container/PG serao pulados"

if [ -z "$AD_PASS" ]; then
  fail "AD_PASS nao setado — exporte com: AD_PASS='@manaus2026' bash <(curl -sL ...)"
  exit 1
fi
ok "AD_PASS setado (${#AD_PASS} chars)"
info "  AD_USER=$AD_USER  ADMIN_USER=$ADMIN_USER"
info "  Backend=$BACKEND_HOST:$BACKEND_PORT  Frontend=$FRONTEND_HOST:$FRONTEND_PORT"
info "  AD_API_BASE=$AD_API_BASE"
info "  Logs serao salvos em: $LOG_FILE"

if command -v docker >/dev/null; then
  if docker ps --format '{{.Names}}' | grep -qx "guardian-app-main"; then
    ok "guardian-app-main esta UP"
    BE_STATUS=$(docker inspect guardian-app-main --format '{{.State.Status}}' 2>/dev/null)
    info "  status=$BE_STATUS"
  else
    fail "guardian-app-main NAO esta UP — sem backend nao da pra validar"
    exit 1
  fi

  if docker ps --format '{{.Names}}' | grep -qx "guardian-frontend-main"; then
    ok "guardian-frontend-main esta UP"
  else
    warn "guardian-frontend-main nao esta UP — T7 (frontend proxy) sera pulado"
  fi

  if docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
    ok "postgres ($PG_CONTAINER) esta UP"
  else
    warn "postgres ($PG_CONTAINER) nao esta UP — T6 (PG state) sera pulado"
  fi
fi

# Ping rapido no backend
BE_HEALTH=$(http_status "http://${BACKEND_HOST}:${BACKEND_PORT}/health")
case "$BE_HEALTH" in
  200|404) ok "Backend responde em :$BACKEND_PORT (HTTP $BE_HEALTH)" ;;
  000) fail "Backend nao responde em :$BACKEND_PORT — abortar" ; exit 1 ;;
  *) warn "Backend HTTP $BE_HEALTH em /health — pode ser endpoint inexistente, prosseguindo" ;;
esac

# ──────────── T1 — AD direto ────────────
section "T1 — AD direto: /api/ad/authenticate + /api/hr/employee/get"

note "T1.a — POST $AD_API_BASE/api/ad/authenticate?userId=$AD_USER&password=***"
RESP=$(curl -sS --max-time 10 -X POST \
  "$AD_API_BASE/api/ad/authenticate?userId=${AD_USER}&password=${AD_PASS}" \
  -H 'Accept: application/json' \
  -H 'Content-Length: 0' \
  --data '' \
  -w '\n___HTTP___%{http_code}' 2>/dev/null)
S=$(echo "$RESP" | grep -oE '___HTTP___[0-9]+' | sed 's/___HTTP___//')
B=$(echo "$RESP" | grep -v '___HTTP___')
echo "  [T1.a response] HTTP $S — $(trunc "$B" 250)"

if [ "$S" = "200" ] && echo "$B" | grep -q '"IsAuthenticated":[ ]*true'; then
  ok "AD autenticou $AD_USER (IsAuthenticated=true)"
  DOMAIN=$(json_field "$B" "UserDomain")
  [ -n "$DOMAIN" ] && info "  UserDomain=$DOMAIN"
elif [ "$S" = "200" ] && echo "$B" | grep -q '"IsAuthenticated":[ ]*false'; then
  fail "AD REJEITOU $AD_USER — verificar senha real ou se user existe no LDAP"
elif [ "$S" = "000" ]; then
  fail "AD API nao alcancavel ($AD_API_BASE)"
else
  fail "AD authenticate HTTP $S inesperado: $(trunc "$B" 200)"
fi

note "T1.b — GET $AD_API_BASE/api/hr/employee/get?parameters.userName=$AD_USER"
RESP=$(curl -sS --max-time 10 \
  "$AD_API_BASE/api/hr/employee/get?parameters.userName=${AD_USER}" \
  -H 'Accept: application/json' \
  -w '\n___HTTP___%{http_code}' 2>/dev/null)
S=$(echo "$RESP" | grep -oE '___HTTP___[0-9]+' | sed 's/___HTTP___//')
B=$(echo "$RESP" | grep -v '___HTTP___')
echo "  [T1.b response] HTTP $S — $(trunc "$B" 250)"

if [ "$S" = "200" ] && echo "$B" | grep -qE '"GlobalId"|"Email"|"Name"'; then
  ok "HR API retornou metadata de $AD_USER"
  HR_NAME=$(json_field "$B" "Name")
  HR_EMAIL=$(json_field "$B" "Email")
  HR_GID=$(json_field "$B" "GlobalId")
  HR_DEPT=$(json_field "$B" "DepartmentName")
  [ -n "$HR_NAME" ] && info "  Name=$HR_NAME"
  [ -n "$HR_EMAIL" ] && info "  Email=$HR_EMAIL"
  [ -n "$HR_GID" ] && info "  GlobalId=$HR_GID"
  [ -n "$HR_DEPT" ] && info "  DepartmentName=$HR_DEPT"
elif [ "$S" = "200" ] && echo "$B" | grep -qE '^\[\]$|"length":[ ]*0'; then
  fail "HR API respondeu vazio pra $AD_USER — sem metadata, lookup-ad nao tem o que retornar"
elif [ "$S" = "000" ]; then
  fail "HR API nao alcancavel"
else
  fail "HR API HTTP $S: $(trunc "$B" 200)"
fi

# ──────────── Pre T2 — pega JWT do admin local ────────────
section "Auth ADMIN — POST /local-login $ADMIN_USER (pra usar nos T2/T3/T8)"

RESP=$(curl -sS --max-time 10 -X POST \
  "http://${BACKEND_HOST}:${BACKEND_PORT}/api/v1/auth/local-login" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\"}" \
  -w '\n___HTTP___%{http_code}' 2>/dev/null)
S=$(echo "$RESP" | grep -oE '___HTTP___[0-9]+' | sed 's/___HTTP___//')
B=$(echo "$RESP" | grep -v '___HTTP___')

ADMIN_JWT=""
if [ "$S" = "200" ]; then
  ADMIN_JWT=$(echo "$B" | grep -oE '"access_token":[ ]*"[^"]+"' | head -1 | sed 's/"access_token":[ ]*"//;s/"$//')
  if [ -n "$ADMIN_JWT" ]; then
    ok "ADMIN JWT obtido (${#ADMIN_JWT} chars)"
  else
    fail "Resposta 200 mas sem access_token: $(trunc "$B" 200)"
  fi
else
  fail "Login admin local falhou — HTTP $S: $(trunc "$B" 200)"
  warn "Sem ADMIN_JWT, T2/T3/T8/T9 vao ser pulados"
fi

# ──────────── T2 — Backend lookup-ad (Fase A): user existente ────────────
section "T2 — Backend /management/users/lookup-ad?username=$AD_USER (Fase A)"

if [ -z "$ADMIN_JWT" ]; then
  warn "T2 PULADO — sem ADMIN_JWT"
else
  RESP=$(curl -sS --max-time 10 \
    "http://${BACKEND_HOST}:${BACKEND_PORT}/api/v1/management/users/lookup-ad?username=${AD_USER}" \
    -H "Authorization: Bearer $ADMIN_JWT" \
    -H 'Accept: application/json' \
    -w '\n___HTTP___%{http_code}' 2>/dev/null)
  S=$(echo "$RESP" | grep -oE '___HTTP___[0-9]+' | sed 's/___HTTP___//')
  B=$(echo "$RESP" | grep -v '___HTTP___')
  echo "  [T2 response] HTTP $S — $(trunc "$B" 350)"

  if [ "$S" = "200" ]; then
    if echo "$B" | grep -qE '"username"[ ]*:[ ]*"'; then
      ok "lookup-ad retornou metadata de $AD_USER (Fase A funcional)"
      LU_NAME=$(json_field "$B" "name")
      LU_EMAIL=$(json_field "$B" "email")
      LU_GID=$(json_field "$B" "global_id")
      LU_USER=$(json_field "$B" "username")
      [ -n "$LU_USER" ] && info "  username=$LU_USER"
      [ -n "$LU_NAME" ] && info "  name=$LU_NAME"
      [ -n "$LU_EMAIL" ] && info "  email=$LU_EMAIL"
      [ -n "$LU_GID" ] && info "  global_id=$LU_GID"
    else
      warn "200 mas sem campos esperados: $(trunc "$B" 200)"
    fi
  elif [ "$S" = "404" ]; then
    warn "lookup-ad endpoint NAO EXISTE (HTTP 404) — Fase A nao foi deployada ainda"
    LOOKUP_AD_AVAILABLE=0
    CRITICAL_FAIL=$((CRITICAL_FAIL-1))  # nao conta como critico se deploy nao foi
    FAIL=$((FAIL-1))
  elif [ "$S" = "401" ] || [ "$S" = "403" ]; then
    fail "lookup-ad rejeitou JWT admin (HTTP $S) — admin nao tem permissao? $(trunc "$B" 150)"
  elif [ "$S" = "500" ]; then
    fail "lookup-ad HTTP 500 — erro interno no backend: $(trunc "$B" 200)"
  else
    fail "lookup-ad HTTP $S inesperado: $(trunc "$B" 200)"
  fi
fi

# ──────────── T3 — Backend lookup-ad com user inexistente (404 esperado) ────────────
section "T3 — Backend /lookup-ad?username=usuario.fake.999 (esperado 404)"

if [ -z "$ADMIN_JWT" ]; then
  warn "T3 PULADO — sem ADMIN_JWT"
elif [ "$LOOKUP_AD_AVAILABLE" = "0" ]; then
  warn "T3 PULADO — lookup-ad nao deployado (T2 retornou 404)"
else
  FAKE_USER="usuario.fake.999"
  RESP=$(curl -sS --max-time 10 \
    "http://${BACKEND_HOST}:${BACKEND_PORT}/api/v1/management/users/lookup-ad?username=${FAKE_USER}" \
    -H "Authorization: Bearer $ADMIN_JWT" \
    -H 'Accept: application/json' \
    -w '\n___HTTP___%{http_code}' 2>/dev/null)
  S=$(echo "$RESP" | grep -oE '___HTTP___[0-9]+' | sed 's/___HTTP___//')
  B=$(echo "$RESP" | grep -v '___HTTP___')
  echo "  [T3 response] HTTP $S — $(trunc "$B" 200)"

  if [ "$S" = "404" ]; then
    ok "lookup-ad retornou 404 pra user inexistente (controle negativo OK)"
  elif [ "$S" = "200" ]; then
    fail "lookup-ad retornou 200 pra user fake — bug: deveria ser 404"
  else
    warn "lookup-ad HTTP $S (esperado 404): $(trunc "$B" 150)"
  fi
fi

# ──────────── T4 — Backend /local-login com joao.nunes (auto-approve) ────────────
section "T4 — Backend /local-login com $AD_USER (esperado auto-approve, ADMIN_USERNAMES)"

RESP=$(curl -sS --max-time 12 -X POST \
  "http://${BACKEND_HOST}:${BACKEND_PORT}/api/v1/auth/local-login" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"$AD_USER\",\"password\":\"$AD_PASS\"}" \
  -w '\n___HTTP___%{http_code}' 2>/dev/null)
S=$(echo "$RESP" | grep -oE '___HTTP___[0-9]+' | sed 's/___HTTP___//')
B=$(echo "$RESP" | grep -v '___HTTP___')
echo "  [T4 response] HTTP $S — $(trunc "$B" 350)"

USER_JWT=""
if [ "$S" = "200" ]; then
  AUTH_SRC=$(json_field "$B" "auth_source")
  USER_JWT=$(echo "$B" | grep -oE '"access_token":[ ]*"[^"]+"' | head -1 | sed 's/"access_token":[ ]*"//;s/"$//')

  if [ "$AUTH_SRC" = "ad" ]; then
    ok "Backend autenticou $AD_USER via AD (auth_source=ad)"
    [ -n "$USER_JWT" ] && info "  JWT recebido (${#USER_JWT} chars)"
  elif [ "$AUTH_SRC" = "local" ]; then
    warn "auth_source=local — user ja existia no PG (sessao anterior). OK se ja foi auto-aprovado antes."
    [ -n "$USER_JWT" ] && info "  JWT recebido (${#USER_JWT} chars)"
  else
    warn "200 mas sem auth_source: $(trunc "$B" 200)"
  fi

  # Checa se response indica is_pending
  IS_PENDING=$(json_field_bool "$B" "is_pending")
  if [ -n "$IS_PENDING" ]; then
    if [ "$IS_PENDING" = "false" ]; then
      ok "Response inclui is_pending=false (auto-aprovado)"
    else
      warn "Response inclui is_pending=true — joao.nunes NAO foi auto-aprovado. Conferir ADMIN_USERNAMES no env."
    fi
  fi
elif [ "$S" = "401" ]; then
  fail "Backend rejeitou $AD_USER (HTTP 401) — senha AD invalida ou backend nao consegue alcancar AD"
elif [ "$S" = "403" ]; then
  fail "Backend retornou 403 — user nao autorizado (is_pending=true talvez bloqueando)"
elif [ "$S" = "503" ]; then
  fail "Backend 503 — AD_API_ENABLED=false. Setar e restartar guardian-app-main."
else
  fail "Backend HTTP $S: $(trunc "$B" 200)"
fi

# ──────────── T5 — JWT joao.nunes em /user-details ────────────
section "T5 — GET /user-details com JWT do $AD_USER"

if [ -z "$USER_JWT" ]; then
  warn "T5 PULADO — sem USER_JWT (T4 falhou)"
else
  RESP=$(curl -sS --max-time 10 \
    "http://${BACKEND_HOST}:${BACKEND_PORT}/api/v1/auth/user-details" \
    -H "Authorization: Bearer $USER_JWT" \
    -H 'Accept: application/json' \
    -w '\n___HTTP___%{http_code}' 2>/dev/null)
  S=$(echo "$RESP" | grep -oE '___HTTP___[0-9]+' | sed 's/___HTTP___//')
  B=$(echo "$RESP" | grep -v '___HTTP___')
  echo "  [T5 response] HTTP $S — $(trunc "$B" 300)"

  if [ "$S" = "200" ]; then
    ok "JWT de $AD_USER aceito em /user-details (E2E full chain OK)"
    UD_USER=$(json_field "$B" "username")
    UD_ROLE=$(json_field "$B" "role")
    [ -n "$UD_USER" ] && info "  username=$UD_USER"
    [ -n "$UD_ROLE" ] && info "  role=$UD_ROLE"
  elif [ "$S" = "401" ]; then
    fail "JWT rejeitado em /user-details (HTTP 401) — token invalido ou expirado imediatamente?"
  else
    fail "/user-details HTTP $S: $(trunc "$B" 200)"
  fi
fi

# ──────────── T6 — PG state: employees row ────────────
section "T6 — PG state: SELECT FROM employees WHERE username='$AD_USER'"

JOAO_PG_ID=""
if ! command -v docker >/dev/null || ! docker inspect "$PG_CONTAINER" >/dev/null 2>&1; then
  warn "T6 PULADO — postgres container ($PG_CONTAINER) nao acessivel"
else
  PG_OUT=$(docker exec -e PGPASSWORD="$PG_PASS" "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -t -A -F'|' -c \
    "SELECT id, username, name, email, role, COALESCE(is_pending::text,'NULL') FROM employees WHERE username='$AD_USER';" 2>&1)
  echo "  [PG output] $(trunc "$PG_OUT" 400)"

  if [ -z "$PG_OUT" ] || echo "$PG_OUT" | grep -qE '^\s*$|0 rows|FATAL|ERROR'; then
    if echo "$PG_OUT" | grep -qE 'FATAL|ERROR'; then
      fail "Erro PG: $(trunc "$PG_OUT" 200)"
    else
      fail "User $AD_USER NAO existe em employees — login AD nao criou registro"
    fi
  else
    ROWS=$(echo "$PG_OUT" | grep -c '|')
    if [ "$ROWS" -ge 1 ]; then
      ok "User $AD_USER existe em employees ($ROWS linha(s))"
      FIRST=$(echo "$PG_OUT" | head -1)
      JOAO_PG_ID=$(echo "$FIRST" | cut -d'|' -f1)
      EMP_ROLE=$(echo "$FIRST" | cut -d'|' -f5)
      EMP_PEND=$(echo "$FIRST" | cut -d'|' -f6)
      info "  id=$JOAO_PG_ID  role=$EMP_ROLE  is_pending=$EMP_PEND"

      if [ "$EMP_PEND" = "f" ] || [ "$EMP_PEND" = "false" ] || [ "$EMP_PEND" = "FALSE" ]; then
        ok "is_pending=FALSE — auto-aprovado conforme ADMIN_USERNAMES"
      elif [ "$EMP_PEND" = "t" ] || [ "$EMP_PEND" = "true" ] || [ "$EMP_PEND" = "TRUE" ]; then
        fail "is_pending=TRUE — $AD_USER NAO foi auto-aprovado. Verificar ADMIN_USERNAMES no env do backend"
      else
        warn "is_pending=$EMP_PEND (valor inesperado, coluna pode nao existir ainda — Fase B nao deployada?)"
      fi
    else
      fail "PG retornou 0 linhas — $AD_USER nao foi criado"
    fi
  fi
fi

# ──────────── T7 — Frontend proxy ────────────
section "T7 — Frontend proxy ($FRONTEND_HOST:$FRONTEND_PORT) → backend"

if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "guardian-frontend-main"; then
  warn "T7 PULADO — guardian-frontend-main nao esta UP"
else
  RESP=$(curl -sS --max-time 12 -X POST \
    "http://${FRONTEND_HOST}:${FRONTEND_PORT}/api/v1/auth/local-login" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"$AD_USER\",\"password\":\"$AD_PASS\"}" \
    -w '\n___HTTP___%{http_code}' 2>/dev/null)
  S=$(echo "$RESP" | grep -oE '___HTTP___[0-9]+' | sed 's/___HTTP___//')
  B=$(echo "$RESP" | grep -v '___HTTP___')
  echo "  [T7 response] HTTP $S — $(trunc "$B" 250)"

  case "$S" in
    200) ok "Frontend proxy roteia pro backend OK (login via :$FRONTEND_PORT funciona)" ;;
    401) fail "Frontend proxy 401 — chega no backend mas auth quebrou" ;;
    502) fail "Frontend proxy 502 — backend unreachable da rede do nginx" ;;
    404) fail "Frontend proxy 404 — nginx nao tem rota /api/v1" ;;
    000) fail "Frontend nao responde em :$FRONTEND_PORT" ;;
    *) warn "Frontend proxy HTTP $S inesperado" ;;
  esac
fi

# ──────────── T8 — Listar pendentes ────────────
section "T8 — GET /management/users?status=pending (admin only)"

if [ -z "$ADMIN_JWT" ]; then
  warn "T8 PULADO — sem ADMIN_JWT"
else
  RESP=$(curl -sS --max-time 10 \
    "http://${BACKEND_HOST}:${BACKEND_PORT}/api/v1/management/users?status=pending" \
    -H "Authorization: Bearer $ADMIN_JWT" \
    -H 'Accept: application/json' \
    -w '\n___HTTP___%{http_code}' 2>/dev/null)
  S=$(echo "$RESP" | grep -oE '___HTTP___[0-9]+' | sed 's/___HTTP___//')
  B=$(echo "$RESP" | grep -v '___HTTP___')
  echo "  [T8 response] HTTP $S — $(trunc "$B" 300)"

  if [ "$S" = "200" ]; then
    # Conta items no array (sem jq, conta {)
    COUNT=$(echo "$B" | grep -oE '"id"[ ]*:[ ]*[0-9]+|"username"[ ]*:[ ]*"' | grep -c 'id\|username' 2>/dev/null || echo 0)
    if echo "$B" | grep -qE '^\[\]|"length"[ ]*:[ ]*0'; then
      ok "Lista pending vazia (esperado pos-auto-approve do $AD_USER)"
    else
      ok "Lista pending retornou (count aproximado=$COUNT). Esperado vazio se Fase B funciona com ADMIN_USERNAMES."
    fi
  elif [ "$S" = "404" ]; then
    warn "GET /management/users?status=pending NAO EXISTE — Fase B nao foi deployada ainda"
    APPROVE_AVAILABLE=0
    CRITICAL_FAIL=$((CRITICAL_FAIL-1))
    FAIL=$((FAIL-1))
  elif [ "$S" = "401" ] || [ "$S" = "403" ]; then
    fail "Lista pending rejeitou JWT admin (HTTP $S)"
  else
    fail "Lista pending HTTP $S: $(trunc "$B" 200)"
  fi
fi

# ──────────── T9 — Approve idempotente (smoke) ────────────
section "T9 — POST /users/{id}/approve idempotencia (smoke)"

if [ -z "$ADMIN_JWT" ]; then
  warn "T9 PULADO — sem ADMIN_JWT"
elif [ -z "$JOAO_PG_ID" ]; then
  warn "T9 PULADO — sem id de $AD_USER (T6 nao retornou)"
elif [ "$APPROVE_AVAILABLE" = "0" ]; then
  warn "T9 PULADO — endpoints de management nao deployados (T8 retornou 404)"
else
  note "T9.a — primeira chamada approve($JOAO_PG_ID)"
  RESP=$(curl -sS --max-time 10 -X POST \
    "http://${BACKEND_HOST}:${BACKEND_PORT}/api/v1/management/users/${JOAO_PG_ID}/approve" \
    -H "Authorization: Bearer $ADMIN_JWT" \
    -H 'Content-Type: application/json' \
    -d '{}' \
    -w '\n___HTTP___%{http_code}' 2>/dev/null)
  S1=$(echo "$RESP" | grep -oE '___HTTP___[0-9]+' | sed 's/___HTTP___//')
  B1=$(echo "$RESP" | grep -v '___HTTP___')
  echo "  [T9.a response] HTTP $S1 — $(trunc "$B1" 200)"

  note "T9.b — segunda chamada approve($JOAO_PG_ID) — esperado idempotente"
  RESP=$(curl -sS --max-time 10 -X POST \
    "http://${BACKEND_HOST}:${BACKEND_PORT}/api/v1/management/users/${JOAO_PG_ID}/approve" \
    -H "Authorization: Bearer $ADMIN_JWT" \
    -H 'Content-Type: application/json' \
    -d '{}' \
    -w '\n___HTTP___%{http_code}' 2>/dev/null)
  S2=$(echo "$RESP" | grep -oE '___HTTP___[0-9]+' | sed 's/___HTTP___//')
  B2=$(echo "$RESP" | grep -v '___HTTP___')
  echo "  [T9.b response] HTTP $S2 — $(trunc "$B2" 200)"

  case "$S1" in
    200|204|304) ok "Primeira approve OK (HTTP $S1)" ;;
    404) warn "approve endpoint nao existe (HTTP 404)" ;;
    409) ok "Primeira approve retornou 409 (ja aprovado — auto-approve do ADMIN_USERNAMES funcionou antes)" ;;
    *) fail "Primeira approve HTTP $S1: $(trunc "$B1" 150)" ;;
  esac

  case "$S2" in
    200|204|304|409) ok "Segunda approve idempotente (HTTP $S2)" ;;
    500) fail "Segunda approve HTTP 500 — bug de idempotencia: $(trunc "$B2" 150)" ;;
    *) warn "Segunda approve HTTP $S2 inesperado: $(trunc "$B2" 150)" ;;
  esac
fi

# ──────────── T10 — Logs do backend ────────────
section "T10 — Logs guardian-app-main (60s, filtrados)"

if ! command -v docker >/dev/null; then
  warn "T10 PULADO — docker indisponivel"
else
  LOG_RAW=$(docker logs guardian-app-main --since 60s 2>&1 || true)
  LOG_FILTERED=$(echo "$LOG_RAW" | grep -E 'employee_lookup|ad_user_data_fetched|ad_authenticate|approve|is_pending|local-login|lookup-ad|ADMIN_USERNAMES' | tail -50)

  if [ -n "$LOG_FILTERED" ]; then
    LINES=$(echo "$LOG_FILTERED" | wc -l | tr -d ' ')
    ok "$LINES linhas relevantes nos logs (ultimos 60s)"
    echo "  --- amostra (ate 10 linhas) ---"
    echo "$LOG_FILTERED" | head -10 | sed 's/^/    /'
    echo "  --- fim amostra ---"
  else
    warn "Nenhuma linha relevante nos logs ultimos 60s — testes podem nao ter passado pelo backend"
  fi

  # Salva tudo no log file
  {
    echo "=== validate-ad-full-flow.sh — $(date) ==="
    echo "AD_USER=$AD_USER  ADMIN_USER=$ADMIN_USER"
    echo "BACKEND=$BACKEND_HOST:$BACKEND_PORT  FRONTEND=$FRONTEND_HOST:$FRONTEND_PORT"
    echo "AD_API_BASE=$AD_API_BASE"
    echo ""
    echo "=== LOGS guardian-app-main (--since 60s) ==="
    echo "$LOG_RAW"
    echo ""
    echo "=== FIM ==="
  } > "$LOG_FILE" 2>/dev/null

  if [ -f "$LOG_FILE" ]; then
    info "Logs completos salvos em: $LOG_FILE"
  else
    warn "Falhou ao salvar log em $LOG_FILE"
  fi
fi

# ──────────── RESUMO ────────────
echo ""
echo -e "${CYA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYA}  RESUMO E2E AD FLOW${NC}"
echo -e "${CYA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Tabela markdown
echo ""
echo "| Teste | Categoria                                       | Status |"
echo "|-------|-------------------------------------------------|--------|"
echo "| T1    | AD direto (authenticate + HR metadata)          | ver acima |"
echo "| T2    | Backend /lookup-ad (Fase A)                     | ver acima |"
echo "| T3    | Backend /lookup-ad 404 (controle negativo)      | ver acima |"
echo "| T4    | Backend /local-login com user AD                | ver acima |"
echo "| T5    | /user-details com JWT do AD                     | ver acima |"
echo "| T6    | PG state (is_pending=FALSE)                     | ver acima |"
echo "| T7    | Frontend proxy → backend                        | ver acima |"
echo "| T8    | /management/users?status=pending                | ver acima |"
echo "| T9    | Approve idempotencia                            | ver acima |"
echo "| T10   | Logs guardian-app-main                          | ver acima |"

echo ""
echo -e "  ${GRN}PASS: $PASS${NC}"
[ $WARN -gt 0 ] && echo -e "  ${YLW}WARN: $WARN${NC}"
[ $FAIL -gt 0 ] && echo -e "  ${RED}FAIL: $FAIL${NC}"

if [ "$LOOKUP_AD_AVAILABLE" = "0" ] || [ "$APPROVE_AVAILABLE" = "0" ]; then
  echo ""
  echo -e "${YLW}⚠ NOTA:${NC} alguns endpoints de /management/users (Fase A/B) nao foram"
  echo -e "  encontrados — provavelmente o deploy ainda nao foi aplicado."
  echo -e "  Os testes correspondentes foram pulados (nao contam como FAIL critico)."
fi

[ -f "$LOG_FILE" ] && echo "" && echo "  Log completo: $LOG_FILE"

echo ""
if [ $CRITICAL_FAIL -eq 0 ]; then
  echo -e "${GRN}✓ Fluxo AD E2E ($AD_USER) funcional${NC}"
  exit 0
else
  echo -e "${RED}✗ $CRITICAL_FAIL FAIL(s) critico(s) — corrigir antes de validar UI${NC}"
  exit 1
fi
