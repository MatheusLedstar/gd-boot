#!/bin/bash
# Diagnostico do guardian-app-main quando healthcheck falha pos-deploy.
# Uso na LG: curl -sL https://raw.githubusercontent.com/MatheusLedstar/gd-boot/main/diag.sh | bash
set -uo pipefail
C="${1:-guardian-app-main}"

hr() { printf '\n=== %s ===\n' "$1"; }

hr "1. Status do container $C"
docker inspect "$C" --format 'status={{.State.Status}} exitCode={{.State.ExitCode}} restarts={{.RestartCount}} startedAt={{.State.StartedAt}}' 2>&1

hr "2. Networks do container $C"
docker inspect "$C" --format '{{range $net, $cfg := .NetworkSettings.Networks}}{{$net}}: aliases={{$cfg.Aliases}} ip={{$cfg.IPAddress}}
{{end}}' 2>&1

hr "3. Logs --tail 60 (procurar Traceback / Error / Failed)"
docker logs "$C" --tail 60 2>&1 | tail -60

hr "4. Curl interno /docs (de dentro do container)"
docker exec "$C" sh -c "curl -sS -m 3 -o /dev/null -w 'HTTP %{http_code}\n' http://localhost:8000/docs" 2>&1

hr "5. Curl externo /docs (do host)"
curl -sS -m 3 -o /dev/null -w 'HTTP %{http_code}\n' "http://localhost:$(docker port "$C" 8000/tcp 2>/dev/null | awk -F: '{print $NF}' | head -1)/docs" 2>&1

hr "6. Postgres reachability (de dentro do backend)"
docker exec "$C" sh -c "getent hosts postgres 2>&1; getent hosts guardian-postgres 2>&1; python3 -c 'import os,psycopg2; psycopg2.connect(host=os.environ[\"DB_HOST\"], port=os.environ[\"DB_PORT\"], user=os.environ[\"DB_USER\"], password=os.environ[\"DB_PASSWORD\"], dbname=os.environ[\"DB_NAME\"]).close(); print(\"PG OK\")' 2>&1" 2>&1 | tail -5

hr "7. Env vars criticas"
docker exec "$C" sh -c 'env | grep -E "^(DB_|JWT_|LOCAL_AUTH|ADMIN_GUARDIAN_|LG_ANALYTICS_PASSWORD|YOLO_API_|AD_)" | sort' 2>&1

hr "8. Containers postgres no host"
docker ps --filter name=postgres --format '{{.Names}} | {{.Status}} | {{.Networks}}'
docker ps --filter name=guardian-postgres --format '{{.Names}} | {{.Status}} | {{.Networks}}'

hr "9. Dica de causa raiz"
LOGS="$(docker logs "$C" --tail 100 2>&1)"
case "$LOGS" in
  *"FATAL: password authentication failed"*) echo ">> POSTGRES auth FAIL — DB_PASSWORD do container nao bate com o do PG. Conferir env vs senha real do PG." ;;
  *"could not translate host name"*|*"Name or service not known"*) echo ">> DNS FAIL — DB_HOST nao resolve. Postgres provavelmente sem alias na rede lg-app." ;;
  *"alembic.util.exc.CommandError"*|*"Can't locate revision"*) echo ">> ALEMBIC FAIL — versao na tabela alembic_version nao existe no codigo. Rodar 'docker exec $C alembic stamp head' ou ajustar." ;;
  *"ADMIN_GUARDIAN_PASSWORD"*|*"LG_ANALYTICS_PASSWORD"*) echo ">> Senha LOCAL_AUTH faltando no env. Conferir Dockerfile defaults." ;;
  *"Address already in use"*) echo ">> Porta 8000 ocupada dentro do container — algum processo zumbi." ;;
  *) echo ">> Sem padrao conhecido. Ler logs acima manualmente." ;;
esac
