FROM python:3.9-slim

WORKDIR /app

# Instalar cliente MySQL e outras dependências
RUN apt-get update && \
    apt-get install -y \
    default-mysql-client \
    mariadb-client \
    && rm -rf /var/lib/apt/lists/*

# Criar diretórios necessários e configurar permissões
RUN mkdir -p /var/lib/mysql /app/IBD_FILES /app/logs /app/backup && \
    chmod -R 777 /var/lib/mysql /app/IBD_FILES /app/logs /app/backup

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY . .
RUN chmod +x recovery.sh

CMD ["python", "app.py"]
