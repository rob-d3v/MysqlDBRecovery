#!/bin/bash

# Configurações
DB_HOST="db"
DB_USER="root"
DB_PASS="12545121"
DB_NAME="Firebee2_0"
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
    log "Interrompendo execução devido ao erro."
    exit 1
}

# Função para executar comandos MySQL com diagnóstico
execute_mysql_command() {
    local command="$1"
    local result
    
    result=$(mysql -h$DB_HOST -u$DB_USER -p$DB_PASS -e "$command" 2>&1)
    local exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        log "ERRO ao executar comando MySQL: $command"
        log "Saída do erro: $result"
        return 1
    fi
    
    # Se há resultado, mostrar
    if [ -n "$result" ]; then
        echo "$result"
    fi
    
    return 0
}

# Função para verificar e diagnosticar create.sql
check_create_sql() {
    log "Verificando arquivo create.sql..."
    
    if [ ! -f "./create.sql" ]; then
        handle_error "Arquivo create.sql não encontrado no diretório atual!"
    fi
    
    file_size=$(stat -c%s "./create.sql" 2>/dev/null || echo "0")
    log "Tamanho do arquivo create.sql: ${file_size} bytes"
    
    if [ "$file_size" -eq 0 ]; then
        handle_error "Arquivo create.sql está vazio!"
    fi
    
    # Verificar se contém comandos CREATE TABLE
    table_count=$(grep -i "CREATE TABLE" "./create.sql" | wc -l)
    log "Comandos CREATE TABLE encontrados: $table_count"
    
    if [ "$table_count" -eq 0 ]; then
        log "AVISO: Nenhum comando CREATE TABLE encontrado em create.sql"
        log "Primeiras 10 linhas do arquivo:"
        head -10 "./create.sql" | while read line; do
            log "  $line"
        done
    fi
    
    # Verificar se contém ENGINE=InnoDB
    innodb_count=$(grep -i "ENGINE=InnoDB" "./create.sql" | wc -l)
    log "Tabelas com ENGINE=InnoDB: $innodb_count"
    
    return 0
}

# Função para executar create.sql com diagnósticos detalhados
execute_create_sql() {
    log "Executando create.sql com diagnósticos..."
    
    # Primeiro, teste de conexão
    if ! execute_mysql_command "SELECT 1;" > /dev/null; then
        handle_error "Falha na conexão com MySQL"
    fi
    
    # Verificar se o banco existe e selecioná-lo
    if ! execute_mysql_command "USE $DB_NAME;" > /dev/null; then
        handle_error "Não foi possível acessar o banco $DB_NAME"
    fi
    
    # Executar create.sql
    log "Executando create.sql..."
    
    if mysql -h$DB_HOST -u$DB_USER -p$DB_PASS $DB_NAME < "./create.sql" 2> "${LOGS_DIR}/create_sql_errors.log"; then
        log "create.sql executado com sucesso"
    else
        log "Erro ao executar create.sql. Verificando detalhes..."
        
        if [ -s "${LOGS_DIR}/create_sql_errors.log" ]; then
            log "Erros encontrados:"
            cat "${LOGS_DIR}/create_sql_errors.log" | while read line; do
                log "  ERRO: $line"
            done
        fi
        
        # Tentar executar com --force
        log "Tentando executar com --force..."
        if mysql -h$DB_HOST -u$DB_USER -p$DB_PASS --force $DB_NAME < "./create.sql" 2> "${LOGS_DIR}/create_sql_force_errors.log"; then
            log "create.sql executado com --force"
        else
            handle_error "Falha crítica ao executar create.sql mesmo com --force"
        fi
    fi
    
    # Verificar o que foi criado
    log "Verificando tabelas criadas..."
    created_tables=$(mysql -h$DB_HOST -u$DB_USER -p$DB_PASS $DB_NAME -e "SHOW TABLES;" 2>/dev/null | tail -n +2)
    
    if [ -z "$created_tables" ]; then
        log "NENHUMA tabela foi criada!"
        
        # Diagnósticos adicionais
        log "Diagnósticos adicionais:"
        log "1. Verificando se o banco foi selecionado corretamente..."
        mysql -h$DB_HOST -u$DB_USER -p$DB_PASS $DB_NAME -e "SELECT DATABASE();"
        
        log "2. Verificando se há tabelas em outros bancos..."
        mysql -h$DB_HOST -u$DB_USER -p$DB_PASS -e "SELECT TABLE_SCHEMA, TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA NOT IN ('information_schema', 'performance_schema', 'mysql', 'sys');" 2>/dev/null
        
        log "3. Verificando syntax do create.sql..."
        head -50 "./create.sql" > "${LOGS_DIR}/create_sql_preview.txt"
        log "Preview salvo em: ${LOGS_DIR}/create_sql_preview.txt"
        
        handle_error "Nenhuma tabela foi criada após executar create.sql"
    else
        log "Tabelas criadas com sucesso:"
        echo "$created_tables" | while read table; do
            if [ -n "$table" ]; then
                log "  - $table"
            fi
        done
        
        # Verificar engines das tabelas
        log "Verificando engines das tabelas..."
        mysql -h$DB_HOST -u$DB_USER -p$DB_PASS $DB_NAME -e "
        SELECT TABLE_NAME, ENGINE, TABLE_ROWS, 
               ROUND((DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2) AS 'Size_MB'
        FROM INFORMATION_SCHEMA.TABLES 
        WHERE TABLE_SCHEMA = '$DB_NAME' 
        ORDER BY TABLE_NAME;" 2>/dev/null | while read line; do
            if [ -n "$line" ]; then
                log "  $line"
            fi
        done
    fi
}

# Função para backup da estrutura de índices
backup_original_indexes() {
    log "Verificando se existe banco para backup de índices..."
    
    db_exists=$(mysql -h$DB_HOST -u$DB_USER -p$DB_PASS -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='$DB_NAME';" 2>/dev/null | grep -v "SCHEMA_NAME" | head -1)
    
    if [ -z "$db_exists" ]; then
        log "Nenhum banco existente encontrado. Pulando backup de índices."
        create_empty_recreate_indexes
        return 0
    fi
    
    log "Fazendo backup da estrutura de índices do banco existente..."
    
    mkdir -p "$BACKUP_DIR"
    backup_file="${BACKUP_DIR}/original_indexes_backup_${CURRENT_DATE}.sql"
    
    # Criar cabeçalho
    cat > "$backup_file" << EOF
-- Backup da estrutura original de índices
-- Banco: $DB_NAME
-- Data: $(date)

SET foreign_key_checks = 0;
USE $DB_NAME;

EOF
    
    # Backup dos índices secundários
    indexes_sql=$(mysql -h$DB_HOST -u$DB_USER -p$DB_PASS -e "
    SELECT CONCAT(
        'CREATE ',
        IF(NON_UNIQUE = 0, 'UNIQUE ', ''),
        'INDEX \`', INDEX_NAME, '\` ON \`', TABLE_SCHEMA, '\`.\`', TABLE_NAME, '\` (',
        GROUP_CONCAT(
            CONCAT('\`', COLUMN_NAME, '\`', 
                   IF(SUB_PART IS NOT NULL, CONCAT('(', SUB_PART, ')'), ''))
            ORDER BY SEQ_IN_INDEX
            SEPARATOR ', '
        ), ');'
    ) AS create_index_statement
    FROM INFORMATION_SCHEMA.STATISTICS
    WHERE TABLE_SCHEMA = '$DB_NAME'
      AND INDEX_NAME != 'PRIMARY'
    GROUP BY TABLE_NAME, INDEX_NAME
    ORDER BY TABLE_NAME, INDEX_NAME;" 2>/dev/null | grep -v "create_index_statement")
    
    if [ -n "$indexes_sql" ]; then
        echo "$indexes_sql" >> "$backup_file"
        log "Índices secundários salvos no backup"
    else
        echo "-- Nenhum índice secundário encontrado" >> "$backup_file"
        log "Nenhum índice secundário encontrado para backup"
    fi
    
    # Backup das chaves estrangeiras
    echo "" >> "$backup_file"
    echo "-- Chaves estrangeiras:" >> "$backup_file"
    
    fks_sql=$(mysql -h$DB_HOST -u$DB_USER -p$DB_PASS -e "
    SELECT CONCAT(
        'ALTER TABLE \`$DB_NAME\`.\`', kcu.TABLE_NAME, '\` ',
        'ADD CONSTRAINT \`', kcu.CONSTRAINT_NAME, '\` ',
        'FOREIGN KEY (\`', kcu.COLUMN_NAME, '\`) ',
        'REFERENCES \`', kcu.REFERENCED_TABLE_SCHEMA, '\`.\`', kcu.REFERENCED_TABLE_NAME, '\` (\`', kcu.REFERENCED_COLUMN_NAME, '\`)',
        CASE 
            WHEN rc.UPDATE_RULE != 'RESTRICT' THEN CONCAT(' ON UPDATE ', rc.UPDATE_RULE)
            ELSE ''
        END,
        CASE 
            WHEN rc.DELETE_RULE != 'RESTRICT' THEN CONCAT(' ON DELETE ', rc.DELETE_RULE)
            ELSE ''
        END,
        ';'
    ) AS fk_statement
    FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu
    JOIN INFORMATION_SCHEMA.REFERENTIAL_CONSTRAINTS rc 
        ON kcu.CONSTRAINT_NAME = rc.CONSTRAINT_NAME 
        AND kcu.TABLE_SCHEMA = rc.CONSTRAINT_SCHEMA
    WHERE kcu.TABLE_SCHEMA = '$DB_NAME'
      AND kcu.REFERENCED_TABLE_NAME IS NOT NULL
    ORDER BY kcu.TABLE_NAME, kcu.CONSTRAINT_NAME;" 2>/dev/null | grep -v "fk_statement")
    
    if [ -n "$fks_sql" ]; then
        echo "$fks_sql" >> "$backup_file"
        log "Chaves estrangeiras salvas no backup"
    else
        echo "-- Nenhuma chave estrangeira encontrada" >> "$backup_file"
        log "Nenhuma chave estrangeira encontrada para backup"
    fi
    
    echo "" >> "$backup_file"
    echo "SET foreign_key_checks = 1;" >> "$backup_file"
    
    log "Backup de índices originais salvo em: $backup_file"
    
    # Copiar para recreate_indexes.sql
    cp "$backup_file" "./recreate_indexes.sql"
    log "Arquivo recreate_indexes.sql gerado com base no backup"
}

# Função para criar recreate_indexes.sql vazio
create_empty_recreate_indexes() {
    log "Criando recreate_indexes.sql vazio..."
    
    cat > "./recreate_indexes.sql" << EOF
-- recreate_indexes.sql
-- Gerado automaticamente - nenhum banco original encontrado
-- Data: $(date)

SET foreign_key_checks = 0;
USE $DB_NAME;

-- Nenhum índice para recriar (banco novo)
-- Os índices primários serão criados automaticamente com as tabelas

SET foreign_key_checks = 1;
EOF
    
    log "Arquivo recreate_indexes.sql vazio criado"
}

# Criar diretório de logs se não existir
mkdir -p "$LOGS_DIR" "$BACKUP_DIR"

# Verificar pré-requisitos
log "=========================================="
log "INICIANDO VERIFICAÇÕES PRÉ-RECOVERY"
log "=========================================="

# Verificar conexão com MySQL
log "Testando conexão com MySQL..."
if ! execute_mysql_command "SELECT VERSION();" > /dev/null; then
    handle_error "Falha na conexão com MySQL. Verifique se o serviço está rodando."
fi
log "Conexão com MySQL OK"

# Verificar diretório de arquivos .ibd
log "Verificando diretório de arquivos .ibd..."
if [ ! -d "$IBD_SOURCE_DIR" ]; then
    handle_error "Diretório $IBD_SOURCE_DIR não encontrado"
fi

ibd_count=$(find "$IBD_SOURCE_DIR" -name "*.ibd" 2>/dev/null | wc -l)
log "Arquivos .ibd encontrados: $ibd_count"

if [ "$ibd_count" -eq 0 ]; then
    handle_error "Nenhum arquivo .ibd encontrado em $IBD_SOURCE_DIR"
fi

# Verificar arquivo create.sql
check_create_sql

log "=========================================="
log "INICIANDO PROCESSO DE RECOVERY"
log "=========================================="

# ETAPA 1: Backup da estrutura original
backup_original_indexes

# ETAPA 2: Recriar o banco
log "Recriando banco do zero..."
execute_mysql_command "DROP DATABASE IF EXISTS $DB_NAME;"
execute_mysql_command "CREATE DATABASE IF NOT EXISTS $DB_NAME;"

# ETAPA 3: Executar create.sql com diagnósticos
execute_create_sql

# ETAPA 4: Verificar se temos tabelas InnoDB
log "Verificando tabelas InnoDB criadas..."
innodb_tables=$(mysql -h$DB_HOST -u$DB_USER -p$DB_PASS $DB_NAME -e "
SELECT TABLE_NAME 
FROM INFORMATION_SCHEMA.TABLES 
WHERE TABLE_SCHEMA='$DB_NAME' AND ENGINE='InnoDB';" 2>/dev/null | grep -v "TABLE_NAME")

if [ -z "$innodb_tables" ]; then
    log "DIAGNÓSTICO: Nenhuma tabela InnoDB encontrada!"
    
    # Verificar todas as tabelas
    all_tables=$(mysql -h$DB_HOST -u$DB_USER -p$DB_PASS $DB_NAME -e "
    SELECT TABLE_NAME, ENGINE 
    FROM INFORMATION_SCHEMA.TABLES 
    WHERE TABLE_SCHEMA='$DB_NAME';" 2>/dev/null | grep -v "TABLE_NAME")
    
    if [ -n "$all_tables" ]; then
        log "Tabelas encontradas (com engines):"
        echo "$all_tables" | while read line; do
            if [ -n "$line" ]; then
                log "  $line"
            fi
        done
        
        log "Tentando converter tabelas para InnoDB..."
        echo "$all_tables" | while read table_info; do
            table_name=$(echo "$table_info" | awk '{print $1}')
            if [ -n "$table_name" ]; then
                log "Convertendo $table_name para InnoDB..."
                mysql -h$DB_HOST -u$DB_USER -p$DB_PASS $DB_NAME -e "ALTER TABLE $table_name ENGINE=InnoDB;" 2>/dev/null
            fi
        done
        
        # Verificar novamente
        innodb_tables=$(mysql -h$DB_HOST -u$DB_USER -p$DB_PASS $DB_NAME -e "
        SELECT TABLE_NAME 
        FROM INFORMATION_SCHEMA.TABLES 
        WHERE TABLE_SCHEMA='$DB_NAME' AND ENGINE='InnoDB';" 2>/dev/null | grep -v "TABLE_NAME")
    fi
    
    if [ -z "$innodb_tables" ]; then
        handle_error "Impossível continuar sem tabelas InnoDB"
    fi
fi

# Converter string para array
TABLES=()
while IFS= read -r line; do
    if [ -n "$line" ]; then
        TABLES+=("$line")
    fi
done <<< "$innodb_tables"

log "Encontradas ${#TABLES[@]} tabelas InnoDB para processar:"
for table in "${TABLES[@]}"; do
    log "  - $table"
done

log "=========================================="
log "CONTINUANDO COM O PROCESSO DE RECOVERY"
log "=========================================="

# Verificar tamanho do banco
log "Verificando tamanho do banco..."
mysql -h$DB_HOST -u$DB_USER -p$DB_PASS $DB_NAME -e "
SELECT table_schema, 
   ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS 'Size (MB)'
FROM information_schema.tables 
WHERE table_schema='$DB_NAME'
GROUP BY table_schema;" > "${LOGS_DIR}/size_before_import.log" 2>/dev/null

# Desabilitar checagem de chaves estrangeiras
log "Desabilitando checagem de chaves estrangeiras..."
execute_mysql_command "SET GLOBAL foreign_key_checks=0;"

# Remover chaves estrangeiras
log "Removendo chaves estrangeiras..."
for TABLE in "${TABLES[@]}"; do
    fk_constraints=$(mysql -h$DB_HOST -u$DB_USER -p$DB_PASS $DB_NAME -e "
      SELECT CONSTRAINT_NAME 
      FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE 
      WHERE TABLE_NAME = '$TABLE' AND TABLE_SCHEMA = '$DB_NAME' AND REFERENCED_TABLE_NAME IS NOT NULL;" 2>/dev/null | grep -v "CONSTRAINT_NAME")

    if [ -n "$fk_constraints" ]; then
        echo "$fk_constraints" | while read fk; do
            if [ -n "$fk" ]; then
                log "Removendo chave estrangeira $fk da tabela $TABLE..."
                mysql -h$DB_HOST -u$DB_USER -p$DB_PASS $DB_NAME -e "ALTER TABLE $TABLE DROP FOREIGN KEY $fk;" 2>/dev/null
            fi
        done
    fi
done

# Preparar para discard tablespace
log "Preparando para discard tablespace..."
for TABLE in "${TABLES[@]}"; do
    log "Executando discard tablespace para $TABLE..."
    mysql -h$DB_HOST -u$DB_USER -p$DB_PASS $DB_NAME -e "ALTER TABLE $TABLE DISCARD TABLESPACE;" 2>/dev/null
done

# Remover índices secundários
log "Removendo índices secundários..."
for TABLE in "${TABLES[@]}"; do
    indexes=$(mysql -h$DB_HOST -u$DB_USER -p$DB_PASS $DB_NAME -e "
        SELECT DISTINCT INDEX_NAME 
        FROM INFORMATION_SCHEMA.STATISTICS 
        WHERE TABLE_SCHEMA='$DB_NAME' 
          AND TABLE_NAME='$TABLE' 
          AND INDEX_NAME != 'PRIMARY';" 2>/dev/null | grep -v "INDEX_NAME")

    if [ -n "$indexes" ]; then
        echo "$indexes" | while read index; do
            if [ -n "$index" ]; then
                log "Removendo índice $index da tabela $TABLE..."
                mysql -h$DB_HOST -u$DB_USER -p$DB_PASS $DB_NAME -e "ALTER TABLE $TABLE DROP INDEX $index;" 2>/dev/null
            fi
        done
    fi
done

# Copiar arquivos .ibd
log "Copiando arquivos .ibd..."
ibd_copied=0
for ibd_file in "$IBD_SOURCE_DIR"/*.ibd; do
    if [ -f "$ibd_file" ]; then
        filename=$(basename "$ibd_file")
        log "Copiando $filename..."
        
        cp "$ibd_file" "/var/lib/mysql/$DB_NAME/" || handle_error "Failed to copy $filename"
        chmod 666 "/var/lib/mysql/$DB_NAME/$filename" || log "Warning: Could not set permissions for $filename"
        ibd_copied=$((ibd_copied + 1))
    fi
done

log "Total de arquivos .ibd copiados: $ibd_copied"

# Arrays para rastreamento
DROPPED_TABLES=()
IMPORTED_TABLES=()

# Importar tablespaces
log "Importando tablespaces..."
for TABLE in "${TABLES[@]}"; do
    log "Importando tablespace para $TABLE..."
    
    if mysql -h$DB_HOST -u$DB_USER -p$DB_PASS $DB_NAME -e "ALTER TABLE $TABLE IMPORT TABLESPACE;" 2>/dev/null; then
        IMPORTED_TABLES+=("$TABLE")
        log "Tablespace para $TABLE importado com sucesso"
    else
        log "Erro ao importar tablespace para $TABLE. Tentando reparar..."
        
        if mysql -h$DB_HOST -u$DB_USER -p$DB_PASS $DB_NAME -e "REPAIR TABLE $TABLE;" 2>/dev/null; then
            if mysql -h$DB_HOST -u$DB_USER -p$DB_PASS $DB_NAME -e "ALTER TABLE $TABLE IMPORT TABLESPACE;" 2>/dev/null; then
                IMPORTED_TABLES+=("$TABLE")
                log "Tablespace para $TABLE importado após reparo"
            else
                log "Falha na reimportação após reparo. Removendo $TABLE..."
                mysql -h$DB_HOST -u$DB_USER -p$DB_PASS $DB_NAME -e "DROP TABLE $TABLE;" 2>/dev/null
                DROPPED_TABLES+=("$TABLE")
            fi
        else
            log "Erro ao reparar $TABLE. Removendo tabela..."
            mysql -h$DB_HOST -u$DB_USER -p$DB_PASS $DB_NAME -e "DROP TABLE $TABLE;" 2>/dev/null
            DROPPED_TABLES+=("$TABLE")
        fi
    fi
done

# Recriar índices
log "Recriando índices secundários..."
if [ -f "./recreate_indexes.sql" ]; then
    useful_lines=$(grep -E "^(CREATE|ALTER)" "./recreate_indexes.sql" | wc -l)
    
    if [ "$useful_lines" -gt 0 ]; then
        log "Executando recreate_indexes.sql ($useful_lines comandos)..."
        if mysql -h$DB_HOST -u$DB_USER -p$DB_PASS $DB_NAME < "./recreate_indexes.sql" 2> "${LOGS_DIR}/recreate_indexes_errors.log"; then
            log "Índices recriados com sucesso"
        else
            log "Erros ao recriar índices:"
            if [ -s "${LOGS_DIR}/recreate_indexes_errors.log" ]; then
                cat "${LOGS_DIR}/recreate_indexes_errors.log" | while read line; do
                    log "  ERRO: $line"
                done
            fi
        fi
    else
        log "recreate_indexes.sql não contém comandos úteis"
    fi
else
    log "recreate_indexes.sql não encontrado"
fi

# Reabilitar checagem de chaves estrangeiras
log "Reabilitando checagem de chaves estrangeiras..."
execute_mysql_command "SET GLOBAL foreign_key_checks=1;"

# Criar dump
log "Criando dump..."
backup_file="${BACKUP_DIR}/backup_${CURRENT_DATE}.sql"
if mysqldump -h$DB_HOST -u$DB_USER -p$DB_PASS $DB_NAME > "$backup_file" 2> "${LOGS_DIR}/dump_errors.log"; then
    chmod 644 "$backup_file"
    echo "$backup_file" > "${BACKUP_DIR}/latest_backup.txt"
    log "Dump criado com sucesso: $backup_file"
else
    log "Erro ao criar dump:"
    if [ -s "${LOGS_DIR}/dump_errors.log" ]; then
        cat "${LOGS_DIR}/dump_errors.log" | while read line; do
            log "  ERRO: $line"
        done
    fi
fi

# Verificar tamanho final
mysql -h$DB_HOST -u$DB_USER -p$DB_PASS $DB_NAME -e "
SELECT table_schema, 
   ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS 'Size (MB)'
FROM information_schema.tables 
WHERE table_schema='$DB_NAME'
GROUP BY table_schema;" > "${LOGS_DIR}/size_after_import.log" 2>/dev/null

# Relatório final
log "=========================================="
log "RELATÓRIO FINAL DO RECOVERY"
log "=========================================="
log "Tabelas processadas: ${#TABLES[@]}"
log "Tabelas importadas com sucesso: ${#IMPORTED_TABLES[@]}"
log "Tabelas removidas (falha): ${#DROPPED_TABLES[@]}"
log "Arquivos .ibd processados: $ibd_copied"

if [ ${#DROPPED_TABLES[@]} -gt 0 ]; then
    log "Tabelas removidas:"
    for table in "${DROPPED_TABLES[@]}"; do
        log "  - $table"
    done
fi

if [ ${#IMPORTED_TABLES[@]} -gt 0 ]; then
    log "Tabelas importadas:"
    for table in "${IMPORTED_TABLES[@]}"; do
        log "  - $table"
    done
fi

# Status final
if [ ${#IMPORTED_TABLES[@]} -gt 0 ]; then
    log "=========================================="
    log "✅ RECOVERY CONCLUÍDO COM SUCESSO!"
    log "=========================================="
else
    log "=========================================="
    log "❌ RECOVERY FALHOU - NENHUMA TABELA IMPORTADA"
    log "=========================================="
    exit 1
fi

log "Logs detalhados salvos em: ${LOGS_DIR}/"
log "Backup criado em: $backup_file"