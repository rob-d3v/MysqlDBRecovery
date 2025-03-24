#!/bin/bash

# Configurações
DB_HOST="db"  # Nome do serviço no docker-compose
DB_USER="root"
DB_PASS="12545121"
DB_NAME="batatinha123"
IBD_SOURCE_DIR="/app/IBD_FILES"
BACKUP_DIR="/app/backup"
LOGS_DIR="/app/logs"
CURRENT_DATE=$(date +%Y%m%d_%H%M%S)

# Log function
log() {
    local message="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "${LOGS_DIR}/recovery_${CURRENT_DATE}.log"
}

# Error handling
handle_error() {
    log "ERROR: $1"
    exit 1
}

# Função para executar comandos MySQL
execute_mysql_command() {
    mysql -h$DB_HOST -u$DB_USER -p$DB_PASS -e "$1"
    if [ $? -ne 0 ]; then
        log "Erro ao executar o comando MySQL: $1"
        return 1
    fi
    return 0
}

# Função para executar scripts SQL
execute_mysql_file() {
    cat <(echo "USE $DB_NAME;") "$1" | mysql -h$DB_HOST -u$DB_USER -p$DB_PASS || handle_error "Failed to execute SQL file: $1"
}

# Criar diretório de logs se não existir
mkdir -p "$LOGS_DIR"

# Força remover diretório do banco e recriar
execute_mysql_command "DROP DATABASE IF EXISTS $DB_NAME;"
execute_mysql_command "CREATE DATABASE $DB_NAME;"
execute_mysql_file "./drop.sql"
execute_mysql_file "./create.sql"

# Verificar criação do banco
log "Verificando criação do banco..."
execute_mysql_command "SHOW DATABASES LIKE '$DB_NAME';" || handle_error "Database creation failed"

# Verificar tamanho do banco
log "Verificando tamanho do banco..."
execute_mysql_command "SELECT table_schema, 
   ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS 'Size (MB)'
   FROM information_schema.tables 
   WHERE table_schema='$DB_NAME'
   GROUP BY table_schema;" > "${LOGS_DIR}/size_before_import.log"

# Desabilitar checagem de chaves estrangeiras
log "Desabilitando checagem de chaves estrangeiras..."
execute_mysql_command "SET GLOBAL foreign_key_checks=0;"

# Obter lista de tabelas
TABLES=$(mysql -h$DB_HOST -u$DB_USER -p$DB_PASS -N -e "SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA='$DB_NAME' AND ENGINE='InnoDB';")

# Remover chaves estrangeiras
log "Removendo chaves estrangeiras..."
for TABLE in $TABLES; do
    FK_CONSTRAINTS=$(mysql -h$DB_HOST -u$DB_USER -p$DB_PASS -N -e "
      SELECT CONSTRAINT_NAME 
      FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE 
      WHERE TABLE_NAME = '$TABLE' AND TABLE_SCHEMA = '$DB_NAME' AND REFERENCED_TABLE_NAME IS NOT NULL;")

    for FK in $FK_CONSTRAINTS; do
        log "Removendo chave estrangeira $FK da tabela $TABLE..."
        execute_mysql_command "ALTER TABLE $DB_NAME.$TABLE DROP FOREIGN KEY $FK;"
    done
done

# Preparar para discard tablespace
log "Preparando para discard tablespace..."
for TABLE in $TABLES; do
    log "Executando discard tablespace para $TABLE..."
    execute_mysql_command "ALTER TABLE $DB_NAME.$TABLE DISCARD TABLESPACE;"
done

# Função para remover índices secundários
remove_secondary_indexes() {
    local SUCCESS=1
    for TABLE in $TABLES; do
        INDEXES=$(mysql -h$DB_HOST -u$DB_USER -p$DB_PASS -N -e "
            SELECT DISTINCT INDEX_NAME 
            FROM INFORMATION_SCHEMA.STATISTICS 
            WHERE TABLE_SCHEMA='$DB_NAME' 
              AND TABLE_NAME='$TABLE' 
              AND INDEX_NAME != 'PRIMARY';")

        for INDEX in $INDEXES; do
            log "Removendo índice $INDEX da tabela $TABLE..."
            if ! execute_mysql_command "ALTER TABLE $DB_NAME.$TABLE DROP INDEX $INDEX;"; then
                log "Falha ao remover índice $INDEX da tabela $TABLE."
                SUCCESS=0
                break
            fi
        done

        [ $SUCCESS -eq 0 ] && break
    done

    return $SUCCESS
}

remove_secondary_indexes

# Copiar arquivos .ibd
log "Copiando arquivos .ibd..."
for IBD_FILE in $IBD_SOURCE_DIR/*.ibd; do
    FILENAME=$(basename "$IBD_FILE")
    log "Copiando $FILENAME..."
    
    # Copiar arquivo com permissões de leitura/escrita para todos
    cp "$IBD_FILE" "/var/lib/mysql/$DB_NAME/" || handle_error "Failed to copy $FILENAME"
    chmod 666 "/var/lib/mysql/$DB_NAME/$FILENAME" || log "Warning: Could not set permissions for $FILENAME, but continuing..."
done

# Array para tabelas removidas
DROPPED_TABLES=()

# Importar tablespaces
for TABLE in $TABLES; do
    log "Importando tablespace para $TABLE..."
    
    if ! execute_mysql_command "ALTER TABLE $DB_NAME.$TABLE IMPORT TABLESPACE;"; then
        log "Erro ao importar tablespace para $TABLE. Tentando reparar..."
        
        if ! execute_mysql_command "REPAIR TABLE $DB_NAME.$TABLE;"; then
            log "Erro ao reparar $TABLE. Removendo tabela..."
            execute_mysql_command "DROP TABLE $DB_NAME.$TABLE;"
            DROPPED_TABLES+=("$TABLE")
            continue
        fi
        
        if ! execute_mysql_command "ALTER TABLE $DB_NAME.$TABLE IMPORT TABLESPACE;"; then
            log "Falha na reimportação após reparo. Removendo $TABLE..."
            execute_mysql_command "DROP TABLE $DB_NAME.$TABLE;"
            DROPPED_TABLES+=("$TABLE")
        fi
    fi
done

# Recriar índices
log "Recriando índices secundários..."
execute_mysql_file "./recreate_indexes.sql"

# Criar dump
log "Criando dump..."
BACKUP_FILE="${BACKUP_DIR}/backup_${CURRENT_DATE}.sql"
mysqldump -h$DB_HOST -u$DB_USER -p$DB_PASS $DB_NAME > "$BACKUP_FILE" || handle_error "Dump creation failed"
chmod 644 "$BACKUP_FILE" || log "Warning: Could not set permissions for backup file"

# Criar um arquivo de status para a aplicação web
echo "$BACKUP_FILE" > "${BACKUP_DIR}/latest_backup.txt"

# Verificar tamanho final
execute_mysql_command "SELECT table_schema, 
   ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS 'Size (MB)'
   FROM information_schema.tables 
   WHERE table_schema='$DB_NAME'
   GROUP BY table_schema;" > "${LOGS_DIR}/size_after_import.log"

# Mostrar tabelas removidas
if [ ${#DROPPED_TABLES[@]} -gt 0 ]; then
    log "Tabelas removidas durante o processo:"
    for TABLE in "${DROPPED_TABLES[@]}"; do
        log "- $TABLE"
    done
fi

log "Processo de recovery concluído!"
log "Verifique os logs em ${LOGS_DIR}"
