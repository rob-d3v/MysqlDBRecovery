FROM mariadb:10.3.34

# Argumentos do build
ARG MYSQL_ROOT_PASSWORD=12545121
ARG TZ=America/Sao_Paulo

# Variáveis de ambiente
ENV MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD} \
    TZ=${TZ}

# Instalação de dependências e configuração de timezone
RUN apt-get update && apt-get install -y \
    tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime \
    && echo $TZ > /etc/timezone

# Criar diretórios necessários
RUN mkdir -p /backup /var/lib/mysql-files /IBD_FILES \
    && chown -R mysql:mysql /backup /var/lib/mysql-files /IBD_FILES

# Copiar arquivo de configuração personalizado
COPY custom.cnf /etc/mysql/conf.d/
RUN chmod 644 /etc/mysql/conf.d/custom.cnf

# Expor porta
EXPOSE 3306

# Volume para dados persistentes
VOLUME ["/var/lib/mysql", "/backup", "/IBD_FILES"]

# Healthcheck
HEALTHCHECK --interval=30s --timeout=30s --start-period=60s --retries=5 \
    CMD mysqladmin ping -h localhost -u root -p${MYSQL_ROOT_PASSWORD} || exit 1

