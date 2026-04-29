#!/bin/bash
# ============================================================
# quick-fix-pg.sh — recria guardian-app-main SEM rebuild
# preservando todas as env vars atuais e SO trocando DB_PASSWORD
# pelo valor correto LgGuardian_2026.
#
# Uso na LG (one-liner):
#   curl -sL https://raw.githubusercontent.com/MatheusLedstar/gd-boot/main/quick-fix-pg.sh | bash
# ============================================================
set -uo pipefail

C="${C:-guardian-app-main}"
PG_PASS="${PG_PASS:-LgGuardian_2026}"
TMPENV="/tmp/guardian-app-env.$$"

cleanup() { rm -f "$TMPENV"; }
trap cleanup EXIT

if ! docker inspect "$C" >/dev/null 2>&1; then
  echo "[ERRO] container $C nao existe — rode o deploy primeiro" >&2
  exit 1
fi

echo "[1/5] extraindo config atual de $C ..."
IMG=$(docker inspect "$C" --format '{{.Image}}')
NET=$(docker inspect "$C" --format '{{range $n,$_ := .NetworkSettings.Networks}}{{$n}}{{println}}{{end}}' | head -1)
PORT=$(docker port "$C" 8000/tcp 2>/dev/null | awk -F: '{print $NF}' | head -1)
RESTART=$(docker inspect "$C" --format '{{.HostConfig.RestartPolicy.Name}}')
[ -z "$PORT" ] && PORT=8004

echo "  image=$IMG"
echo "  network=$NET"
echo "  port=$PORT"
echo "  restart=$RESTART"

echo "[2/5] dump env vars (sem mostrar senhas)..."
docker inspect "$C" --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | grep -v '^$' > "$TMPENV"

OLD_PASS=$(grep -E '^DB_PASSWORD=' "$TMPENV" | sed 's/^DB_PASSWORD=//')
echo "  DB_PASSWORD atual termina em: ...${OLD_PASS: -3}"
echo "  total de env vars: $(wc -l < "$TMPENV")"

echo "[3/5] substituindo DB_PASSWORD por LgGuardian_2026 (no env-file temporario)..."
sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=${PG_PASS}/" "$TMPENV"
NEW_PASS=$(grep -E '^DB_PASSWORD=' "$TMPENV" | sed 's/^DB_PASSWORD=//')
echo "  DB_PASSWORD novo termina em: ...${NEW_PASS: -3}"

echo "[4/5] stop+rm $C ..."
docker stop "$C" >/dev/null 2>&1 || true
docker rm   "$C" >/dev/null 2>&1 || true

echo "[5/5] run $C com mesma imagem + envs (senha corrigida)..."
docker run -d \
  --name "$C" \
  --restart "${RESTART:-unless-stopped}" \
  --network "$NET" \
  -p "${PORT}:8000" \
  --env-file "$TMPENV" \
  "$IMG" >/dev/null

echo ""
echo "=== aguardando 12s pra startup ==="
sleep 12

echo ""
echo "=== logs --tail 30 ==="
docker logs "$C" --tail 30 2>&1 | tail -25

echo ""
echo "=== status final ==="
docker inspect "$C" --format 'Status: {{.State.Status}}  Restarts: {{.RestartCount}}'
echo ""
echo "=== healthcheck /docs ==="
curl -sS -m 4 -o /dev/null -w 'HTTP %{http_code}\n' "http://localhost:${PORT}/docs"
echo ""
echo "=== healthcheck /api/v1/auth/local-login ==="
curl -sS -m 4 -X POST "http://localhost:${PORT}/api/v1/auth/local-login" \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin.guardian","password":"Guardian2026!"}' \
  -w '\nHTTP %{http_code}\n' | tail -3
