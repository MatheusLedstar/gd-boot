#!/bin/bash
# ============================================================
# auth-test-suite.sh — Smoke + Stress test do fluxo de autenticacao
# Roda na LG (150.150.251.213) ou Conecthus (172.100.11.125).
#
# MODOS (env var MODE):
#   smoke   — 8 cenarios estruturados (default rapido, ~10s)
#   stress  — N reqs paralelas em /local-login, mede latencia
#   full    — smoke + stress (default)
#
# Uso simples (smoke + stress, joao.nunes admin):
#   AD_PASS='@manaus2026' bash <(curl -sL https://raw.githubusercontent.com/MatheusLedstar/gd-boot/main/auth-test-suite.sh)
#
# Com user AD comum (testa pending gate):
#   AD_PASS='@manaus2026' TARGET_USER=usuario.normal TARGET_PASS='senha' bash <(curl -sL ...)
#
# So smoke (rapido):
#   MODE=smoke AD_PASS='@manaus2026' bash <(curl -sL ...)
#
# Stress alto (200 reqs / 10 paralelos):
#   MODE=stress STRESS_REQS=200 STRESS_PARALLEL=10 AD_PASS='@manaus2026' bash <(curl -sL ...)
# ============================================================
set -uo pipefail

MODE="${MODE:-full}"
ADMIN_USER="${ADMIN_USER:-admin.guardian}"
ADMIN_PASS="${ADMIN_PASS:-Guardian2026!}"
AD_USER="${AD_USER:-joao.nunes}"
AD_PASS="${AD_PASS:?AD_PASS env var requerido (ex: AD_PASS='@manaus2026')}"
TARGET_USER="${TARGET_USER:-}"
TARGET_PASS="${TARGET_PASS:-}"
BACKEND="${BACKEND:-http://localhost:8004}"
FRONTEND="${FRONTEND:-http://localhost:8050}"
STRESS_REQS="${STRESS_REQS:-50}"
STRESS_PARALLEL="${STRESS_PARALLEL:-5}"

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYA='\033[0;36m'; NC='\033[0m'
PASS=0; FAIL=0; WARN=0
ok()   { echo -e "  ${GRN}OK${NC}    $*"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}FAIL${NC}  $*"; FAIL=$((FAIL+1)); }
warn() { echo -e "  ${YLW}WARN${NC}  $*"; WARN=$((WARN+1)); }
info() { echo -e "  ${CYA}info${NC}  $*"; }
section() {
  echo
  echo -e "${CYA}===========================================================${NC}"
  echo -e "${CYA}  $*${NC}"
  echo -e "${CYA}===========================================================${NC}"
}

login_full() {
  local user="$1" pass="$2"
  curl -sS -m 8 -X POST "$BACKEND/api/v1/auth/local-login" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"$user\",\"password\":\"$pass\"}" \
    -w "___HTTP___%{http_code}___TIME___%{time_total}" 2>/dev/null
}

extract_status() { echo "$1" | grep -oE '___HTTP___[0-9]+' | sed 's/___HTTP___//'; }
extract_body()   { echo "$1" | sed 's/___HTTP___[0-9]*___TIME___[0-9.]*$//'; }
extract_token()  {
  echo "$1" | python3 -c 'import sys,re; m=re.search(r"\"access_token\":\"([^\"]+)\"", sys.stdin.read()); print(m.group(1) if m else "")' 2>/dev/null
}

# ============ SMOKE ============
if [ "$MODE" = "smoke" ] || [ "$MODE" = "full" ]; then
  section "SMOKE TEST — 8 cenarios"

  # 1) admin local
  R=$(login_full "$ADMIN_USER" "$ADMIN_PASS")
  S=$(extract_status "$R")
  B=$(extract_body "$R")
  if [ "$S" = "200" ] && echo "$B" | grep -q '"auth_source":[ ]*"local"'; then
    ok "1) admin LOCAL ($ADMIN_USER) -> 200 auth_source=local"
  else
    fail "1) admin LOCAL -> HTTP $S body=$(echo "$B" | head -c 100)"
  fi

  # 2) admin AD (joao.nunes em ADMIN_USERNAMES = auto-aprovado)
  R=$(login_full "$AD_USER" "$AD_PASS")
  S=$(extract_status "$R")
  B=$(extract_body "$R")
  if [ "$S" = "200" ]; then
    SRC=$(echo "$B" | grep -oE '"auth_source":[ ]*"[^"]+"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    ok "2) admin AD ($AD_USER) -> 200 auth_source=$SRC"
  elif [ "$S" = "401" ]; then
    fail "2) admin AD -> 401 senha rejeitada"
  elif [ "$S" = "403" ]; then
    fail "2) admin AD -> 403 (NAO devia virar pending — esta em ADMIN_USERNAMES?)"
  else
    fail "2) admin AD -> HTTP $S"
  fi

  # 3) User AD comum primeiro acesso (pending gate)
  if [ -n "$TARGET_USER" ] && [ -n "$TARGET_PASS" ]; then
    R=$(login_full "$TARGET_USER" "$TARGET_PASS")
    S=$(extract_status "$R")
    B=$(extract_body "$R")
    case "$S" in
      403)
        if echo "$B" | grep -q 'pending_approval'; then
          ok "3) user AD comum ($TARGET_USER) -> 403 pending_approval (gate ATIVO)"
        else
          fail "3) user AD comum 403 mas sem 'pending_approval' no body"
        fi
        ;;
      200)
        ok "3) user AD comum -> 200 (ja aprovado em sessao anterior)"
        ;;
      *)
        fail "3) user AD comum -> HTTP $S"
        ;;
    esac
  else
    info "3) user AD comum: PULADO (setar TARGET_USER/TARGET_PASS pra testar pending gate)"
  fi

  # 4) Senha errada
  R=$(login_full "$ADMIN_USER" "senha-totalmente-errada-9999")
  S=$(extract_status "$R")
  if [ "$S" = "401" ]; then
    ok "4) senha errada -> 401 rejeicao"
  else
    fail "4) senha errada -> HTTP $S (esperado 401)"
  fi

  # 5) User inexistente
  R=$(login_full "usuario.que.nao.existe.999" "qualquer")
  S=$(extract_status "$R")
  case "$S" in
    401|404) ok "5) user inexistente -> $S (rejeicao OK)" ;;
    *)       fail "5) user inexistente -> $S" ;;
  esac

  # 6) Frontend proxy
  R=$(curl -sS -m 5 -X POST "$FRONTEND/api/v1/auth/local-login" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\"}" \
    -w "\n___HTTP___%{http_code}" 2>/dev/null)
  S=$(extract_status "$R")
  [ "$S" = "200" ] && ok "6) frontend proxy ($FRONTEND/api/v1) -> 200" || fail "6) frontend proxy -> $S"

  # 7) JWT em /user-details + lookup-ad
  R=$(login_full "$ADMIN_USER" "$ADMIN_PASS")
  T=$(extract_token "$R")
  if [ -n "$T" ]; then
    S=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $T" "$BACKEND/api/v1/auth/user-details")
    [ "$S" = "200" ] && ok "7a) JWT /user-details -> 200" || fail "7a) JWT /user-details -> $S"

    S=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $T" "$BACKEND/api/v1/guardian/management/users/lookup-ad?username=$AD_USER")
    [ "$S" = "200" ] && ok "7b) lookup-ad ($AD_USER) -> 200" || fail "7b) lookup-ad -> $S"

    # 8) listar pendentes (admin only)
    S=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $T" "$BACKEND/api/v1/guardian/management/users?status=pending")
    [ "$S" = "200" ] && ok "8) listar pendentes (admin) -> 200" || warn "8) listar pendentes -> $S (deploy Fase B?)"
  else
    fail "7) sem JWT — login admin nao retornou access_token"
  fi
fi

# ============ STRESS ============
if [ "$MODE" = "stress" ] || [ "$MODE" = "full" ]; then
  section "STRESS TEST — $STRESS_REQS reqs em $STRESS_PARALLEL paralelos"
  info "warm-up..."

  # Warm-up
  for i in 1 2 3; do
    curl -sS -m 5 -o /dev/null "$BACKEND/api/v1/auth/local-login" -X POST \
      -H 'Content-Type: application/json' \
      -d "{\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\"}" 2>/dev/null
  done

  TMPDIR=$(mktemp -d)
  START=$(date +%s.%N)

  for i in $(seq 1 $STRESS_REQS); do
    (
      T_START=$(date +%s.%N)
      S=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' -X POST "$BACKEND/api/v1/auth/local-login" \
        -H 'Content-Type: application/json' \
        -d "{\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\"}" 2>/dev/null)
      T_END=$(date +%s.%N)
      DUR=$(awk "BEGIN{print $T_END - $T_START}")
      echo "$S $DUR" > "$TMPDIR/r-$i.txt"
    ) &
    [ $((i % STRESS_PARALLEL)) = 0 ] && wait
  done
  wait
  END=$(date +%s.%N)
  TOTAL=$(awk "BEGIN{print $END - $START}")

  # Aggregate
  declare -A COUNTS
  TIMES_FILE="$TMPDIR/all-times.txt"
  : > "$TIMES_FILE"
  for f in "$TMPDIR"/r-*.txt; do
    read SS TT < "$f"
    COUNTS[$SS]=$((${COUNTS[$SS]:-0} + 1))
    echo "$TT" >> "$TIMES_FILE"
  done

  RPS=$(awk "BEGIN{printf \"%.2f\", $STRESS_REQS / $TOTAL}")
  echo "  Total: $STRESS_REQS reqs em ${TOTAL}s ($RPS req/s)"
  echo "  Distribuicao por status code:"
  for code in "${!COUNTS[@]}"; do
    PCT=$(awk "BEGIN{printf \"%.1f\", ${COUNTS[$code]} / $STRESS_REQS * 100}")
    case "$code" in
      200) echo -e "    HTTP ${GRN}$code${NC}: ${COUNTS[$code]} ($PCT%)" ;;
      401|403|404) echo -e "    HTTP ${YLW}$code${NC}: ${COUNTS[$code]} ($PCT%)" ;;
      429) echo -e "    HTTP ${YLW}$code${NC}: ${COUNTS[$code]} ($PCT%) — rate limit" ;;
      000|5*) echo -e "    HTTP ${RED}$code${NC}: ${COUNTS[$code]} ($PCT%) — erro/timeout" ;;
      *) echo "    HTTP $code: ${COUNTS[$code]} ($PCT%)" ;;
    esac
  done

  # Percentis (sort + pick)
  if [ -s "$TIMES_FILE" ]; then
    sort -n "$TIMES_FILE" -o "$TIMES_FILE"
    N=$(wc -l < "$TIMES_FILE")
    P50_LINE=$(((N * 50 / 100) + 1))
    P95_LINE=$(((N * 95 / 100) + 1))
    P99_LINE=$(((N * 99 / 100) + 1))
    P50=$(sed -n "${P50_LINE}p" "$TIMES_FILE")
    P95=$(sed -n "${P95_LINE}p" "$TIMES_FILE")
    P99=$(sed -n "${P99_LINE}p" "$TIMES_FILE")
    echo "  Latencia: p50=${P50}s p95=${P95}s p99=${P99}s"
  fi

  rm -rf "$TMPDIR"

  # Veredito
  S200="${COUNTS[200]:-0}"
  S5XX_TOTAL=0
  for c in "${!COUNTS[@]}"; do
    case "$c" in
      000|5*) S5XX_TOTAL=$((S5XX_TOTAL + COUNTS[$c])) ;;
    esac
  done
  if [ "$S200" -gt $((STRESS_REQS * 8 / 10)) ]; then
    ok "stress: maioria 200 ($S200/$STRESS_REQS) — backend estavel sob carga"
  elif [ "${COUNTS[429]:-0}" -gt 0 ]; then
    info "stress: rate limit ativado em ${COUNTS[429]} reqs (esperado se /local-login tem @limiter)"
  else
    warn "stress: poucos 200 ($S200/$STRESS_REQS) — investigar logs"
  fi
  [ $S5XX_TOTAL -gt 0 ] && fail "stress: $S5XX_TOTAL reqs com erro 5xx/timeout — backend instavel" || true
fi

# ============ SUMMARY ============
section "RESUMO"
echo -e "  ${GRN}PASS: $PASS${NC}"
[ $WARN -gt 0 ] && echo -e "  ${YLW}WARN: $WARN${NC}"
[ $FAIL -gt 0 ] && echo -e "  ${RED}FAIL: $FAIL${NC}"

section "PRA MONITORAR LOGS DURANTE TESTE MANUAL (outra janela SSH)"
echo "  docker logs -f guardian-app-main 2>&1 | grep -iE 'login|auth|ad_authenticate|is_pending|approve|employee_lookup|429' --color=auto"

[ $FAIL -eq 0 ] && exit 0 || exit 1
