#!/bin/sh
set -eu

MYSQL_HOST=${MYSQL_HOST:-mysql}
MYSQL_PORT=${MYSQL_PORT:-3306}
GAME_SCHEMA=neural_doom_local_game_20261024
TEST_SCHEMA=neural_doom_local_sql_test_20261024
INSTALLATION_ID=neural-doom-lab-portable-v1
REPOSITORY_ROOT=/opt/neural/repo

if [ -z "${MYSQL_ROOT_PASSWORD:-}" ] || [ -z "${NN_DB_USER:-}" ] || [ -z "${NN_DB_PASSWORD:-}" ]; then
  echo "Configuração privada incompleta; execute scripts/setup.ps1 -Mode Docker." >&2
  exit 2
fi
case "$NN_DB_USER" in
  neural_doom_app_[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *) echo "Nome de usuário local fora do formato esperado." >&2; exit 2 ;;
esac
case "$NN_DB_PASSWORD" in
  *[!0-9a-f]*|'') echo "Senha local fora do formato gerado pelo setup." >&2; exit 2 ;;
esac

umask 077
CLIENT_CONFIG=$(mktemp)
printf '[client]\nuser=root\npassword=%s\nhost=%s\nport=%s\nprotocol=tcp\n' \
  "$MYSQL_ROOT_PASSWORD" "$MYSQL_HOST" "$MYSQL_PORT" > "$CLIENT_CONFIG"
unset MYSQL_ROOT_PASSWORD
trap 'rm -f "$CLIENT_CONFIG"; unset MYSQL_PWD NN_DB_PASSWORD' EXIT HUP INT TERM

mysql_root() {
  mysql --defaults-extra-file="$CLIENT_CONFIG" --connect-timeout=3 --batch --raw --skip-column-names "$@"
}

mysql_scalar() {
  mysql_root --execute="$1"
}

attempt=0
until mysqladmin --defaults-extra-file="$CLIENT_CONFIG" ping --silent >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 60 ]; then
    echo "MySQL não ficou pronto dentro do prazo." >&2
    exit 3
  fi
  sleep 2
done

server_version=$(mysql_scalar 'SELECT VERSION()')
case "$server_version" in
  8.0.46*) ;;
  *) echo "Versão MySQL não validada: esta instalação foi fixada em MySQL 8.0.46." >&2; exit 4 ;;
esac
if [ "$(mysql_scalar 'SELECT @@GLOBAL.general_log')" != "0" ]; then
  echo "O general_log global está ativo; a instalação parou antes de criar schemas/contas para evitar registrar SQL sensível." >&2
  exit 12
fi

schema_exists() {
  [ "$(mysql_scalar "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='$1'")" -eq 1 ]
}

schema_is_owned() {
  [ "$(mysql_scalar "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$1' AND table_name='neural_doom_lab_installation'")" -eq 1 ] || return 1
  [ "$(mysql_scalar "SELECT COUNT(*) FROM $1.neural_doom_lab_installation WHERE installation_id='$INSTALLATION_ID' AND singleton=1")" -eq 1 ]
}

for schema in "$GAME_SCHEMA" "$TEST_SCHEMA"; do
  if schema_exists "$schema" && ! schema_is_owned "$schema"; then
    echo "O schema $schema já existe e não pertence a esta instalação; nenhum conteúdo foi alterado." >&2
    exit 5
  fi
done

create_owned_schema() {
  schema=$1
  if ! schema_exists "$schema"; then
    mysql_root --execute="CREATE DATABASE $schema CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
    mysql_root --database="$schema" --execute="CREATE TABLE neural_doom_lab_installation (singleton TINYINT NOT NULL PRIMARY KEY, installation_id VARCHAR(64) NOT NULL, installed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP) ENGINE=InnoDB; INSERT INTO neural_doom_lab_installation (singleton, installation_id) VALUES (1, '$INSTALLATION_ID'); CREATE TABLE neural_doom_lab_setup_steps (step_key VARCHAR(100) NOT NULL PRIMARY KEY, state ENUM('running','complete') NOT NULL, checksum CHAR(64) NOT NULL, applied_at TIMESTAMP NULL, updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP) ENGINE=InnoDB"
  fi
}

create_owned_schema "$GAME_SCHEMA"
create_owned_schema "$TEST_SCHEMA"

for schema in "$GAME_SCHEMA" "$TEST_SCHEMA"; do
  if ! schema_is_owned "$schema"; then
    echo "A marca de propriedade do schema $schema não pôde ser confirmada." >&2
    exit 6
  fi
done

while IFS='|' read -r target step relative_path; do
  case "$target" in ''|'#'*) continue ;; esac
  case "$target" in
    game) schema=$GAME_SCHEMA ;;
    test) schema=$TEST_SCHEMA ;;
    *) echo "Destino inválido no plano de instalação." >&2; exit 7 ;;
  esac
  case "$step" in *[!a-zA-Z0-9_-]*|'') echo "Etapa inválida no plano de instalação." >&2; exit 7 ;; esac
  file="$REPOSITORY_ROOT/$relative_path"
  if [ ! -f "$file" ]; then
    echo "Arquivo SQL ausente no clone: $relative_path" >&2
    exit 8
  fi
  checksum=$(sha256sum "$file" | awk '{print $1}')
  row=$(mysql_scalar "SELECT CONCAT(state,'|',checksum) FROM $schema.neural_doom_lab_setup_steps WHERE step_key='$step'")
  case "$row" in
    "complete|$checksum") echo "Já instalado: $target/$step"; continue ;;
    complete\|*) echo "O arquivo da etapa $target/$step mudou depois de aplicado; instalação interrompida." >&2; exit 9 ;;
    running\|*) echo "A etapa $target/$step teve execução incompleta; nenhuma recuperação destrutiva será tentada." >&2; exit 10 ;;
    '') mysql_root --execute="INSERT INTO $schema.neural_doom_lab_setup_steps (step_key,state,checksum) VALUES ('$step','running','$checksum')" ;;
    *) echo "Estado inesperado na etapa $target/$step." >&2; exit 11 ;;
  esac
  mysql_root --database="$schema" < "$file"
  mysql_root --execute="UPDATE $schema.neural_doom_lab_setup_steps SET state='complete', applied_at=CURRENT_TIMESTAMP WHERE step_key='$step' AND state='running' AND checksum='$checksum'"
  echo "Instalado: $target/$step"
done < /opt/neural/plan.tsv

user_exists=$(mysql_scalar "SELECT COUNT(*) FROM mysql.user WHERE user='$NN_DB_USER' AND host='%'" )
if [ "$user_exists" -eq 0 ]; then
  printf "CREATE USER '%s'@'%%' IDENTIFIED BY '%s';\nGRANT EXECUTE ON %s.* TO '%s'@'%%';\n" \
    "$NN_DB_USER" "$NN_DB_PASSWORD" "$GAME_SCHEMA" "$NN_DB_USER" | mysql_root
else
  mysql_root --execute="GRANT EXECUTE ON $GAME_SCHEMA.* TO '$NN_DB_USER'@'%'"
fi

echo "Instalação SQL verificada em MySQL $server_version; conta da aplicação limitada a EXECUTE no schema do jogo."
