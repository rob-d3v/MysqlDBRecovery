# MySQL Database Recovery Tool

![MySQL Recovery](https://img.shields.io/badge/MySQL-Recovery-blue)
![Docker](https://img.shields.io/badge/Docker-Powered-blue)
![MariaDB](https://img.shields.io/badge/MariaDB-10.3.34-green)
![Flask](https://img.shields.io/badge/Flask-Web_App-red)

Uma solução containerizada para recuperação de bancos de dados MySQL a partir de arquivos `.ibd` isolados, ideal para situações de recuperação de desastres quando você tem apenas os arquivos de tablespace e precisa restaurar suas tabelas.

## 📋 Sumário

- [Visão Geral](#visão-geral)
- [Características](#características)
- [Estrutura do Projeto](#estrutura-do-projeto)
- [Requisitos](#requisitos)
- [Instalação e Configuração](#instalação-e-configuração)
- [Como Usar](#como-usar)
- [Como Funciona](#como-funciona)
- [Solução de Problemas](#solução-de-problemas)
- [Implementações Futuras](#implementações-futuras)
- [Contribuições](#contribuições)
- [Licença](#licença)

## 🔍 Visão Geral

Esta ferramenta foi desenvolvida para permitir a recuperação de tabelas MySQL/MariaDB a partir de arquivos `.ibd` (tablespace InnoDB), mesmo quando os arquivos de metadados `.frm` não estão disponíveis. O projeto utiliza Docker para criar um ambiente isolado que facilita a recuperação de dados, oferecendo uma interface web amigável para gerenciar todo o processo.

## ✨ Características

- **Interface Web Intuitiva**: Interface Flask para gerenciar operações de recuperação
- **Ambiente Containerizado**: Isolamento completo via Docker
- **Recuperação de Tablespace**: Suporte à recuperação de tabelas a partir de arquivos `.ibd`
- **Logs Detalhados**: Registro de todas as operações realizadas
- **Sistema de Backup**: Backup automático antes de operações críticas
- **Compatibilidade**: Suporte para diversas versões do MySQL/MariaDB

## 🏗️ Estrutura do Projeto

```
docker-recovery-mysql/
├── docker-compose.yml         # Definição dos serviços
├── IBD_FILES/                 # Diretório para arquivos .ibd
├── db/                        # Configuração do banco de dados
│   ├── Dockerfile             # Imagem do banco MariaDB
│   └── custom.cnf             # Configurações do MySQL
└── webapp/                    # Aplicação web
    ├── Dockerfile             # Imagem da aplicação Flask
    ├── app.py                 # Aplicação principal
    ├── recovery.sh            # Script de recuperação
    ├── requirements.txt       # Dependências Python
    └── templates/             # Templates HTML
        └── index.html         # Interface de usuário
```

## 📋 Requisitos

- Docker (versão 20.10.0+)
- Docker Compose (versão 2.0.0+)
- 4GB de RAM disponível
- 10GB de espaço em disco
- Sistema operacional compatível (Linux, macOS, Windows com WSL2)

## 🚀 Instalação e Configuração

### 1. Clone o repositório

```bash
git clone https://github.com/seu-usuario/docker-recovery-mysql.git
cd docker-recovery-mysql
```

### 2. Prepare os diretórios

```bash
mkdir -p IBD_FILES
```

### 3. Construa e inicie os contêineres

```bash
docker-compose build
docker-compose up -d
```

### 4. Verifique se os serviços estão rodando

```bash
docker-compose ps
```

Você deverá ver dois serviços em execução: `webapp` e `db`.

### 5. Acesse a interface web

Abra seu navegador e acesse:

```
http://localhost:5000
```

## 🔧 Como Usar

### Recuperando uma tabela a partir de um arquivo .ibd

1. **Prepare o arquivo .ibd**:
   - Copie seu arquivo `.ibd` para o diretório `IBD_FILES` do projeto

2. **Acesse a interface web**:
   - Abra `http://localhost:5000` em seu navegador

3. **Configure a recuperação**:
   - Preencha o nome desejado para a tabela
   - Selecione ou crie um banco de dados
   - Selecione o arquivo `.ibd` a ser recuperado

4. **Inicie a recuperação**:
   - Clique no botão "Recuperar"
   - Acompanhe o processo pelo log na interface

5. **Verifique os resultados**:
   - Use qualquer cliente MySQL para conectar ao banco de dados na porta 3306
   - Credenciais padrão: root / 12545121

## ⚙️ Como Funciona

O processo de recuperação segue estas etapas:

1. **Ambiente preparado**: O contêiner MariaDB é configurado com parâmetros especiais que facilitam a recuperação de tablespaces

2. **Criação do esqueleto**: O sistema cria uma tabela vazia com o mesmo nome no banco de dados especificado

3. **Descarte do tablespace**: A estrutura inicial do tablespace é descartada

4. **Importação do arquivo .ibd**: O arquivo é copiado para o local apropriado dentro do contêiner

5. **Importação do tablespace**: O comando `IMPORT TABLESPACE` é executado para restaurar os dados

6. **Validação**: O sistema verifica se a tabela foi recuperada com sucesso

Internamente, o processo usa os recursos do InnoDB para reconstruir metadados e restabelecer a estrutura da tabela a partir dos dados armazenados no arquivo `.ibd`.

## ❓ Solução de Problemas

### Os contêineres não iniciam

Verifique as portas:
```bash
sudo lsof -i :3306
sudo lsof -i :5000
```

Se as portas estiverem em uso, modifique o `docker-compose.yml` para usar portas diferentes.

### Erro de permissão nos arquivos .ibd

Ajuste as permissões:
```bash
chmod -R 777 IBD_FILES
```

### Problemas de conexão com o banco

Verifique os logs:
```bash
docker-compose logs db
```

### Erro na recuperação da tabela

Verifique os logs da aplicação:
```bash
docker-compose logs webapp
```

## 🔮 Implementações Futuras

- **Interface de Administração Avançada**: Painel completo para gerenciamento de bancos recuperados
- **Suporte para arquivos FRM**: Adicionar suporte para arquivos `.frm` para melhorar a precisão da recuperação
- **Detecção Automática de Estrutura**: Identificação e reconstrução automática da estrutura da tabela
- **Painel de Exportação de Dados**: Exportar dados recuperados em vários formatos (CSV, SQL, JSON)
- **Autenticação e Controle de Acesso**: Sistema de login para ambientes multiusuário
- **API REST**: Integração com outros sistemas via API
- **Suporte para PostgreSQL**: Expandir para recuperação de bancos PostgreSQL
- **Integração com Serviços de Nuvem**: Suporte para recuperar arquivos de buckets S3, Google Cloud Storage, etc
- **Versão Standalone**: Versão sem Docker para ambientes com restrições
- **Análise de Integridade**: Ferramentas para análise da integridade dos dados recuperados

## 🤝 Contribuições

Contribuições são bem-vindas! Para contribuir:

1. Faça um fork do projeto
2. Crie uma branch para sua feature (`git checkout -b feature/nova-feature`)
3. Commit suas mudanças (`git commit -m 'Adiciona nova feature'`)
4. Push para a branch (`git push origin feature/nova-feature`)
5. Abra um Pull Request

## 📄 Licença

Este projeto está licenciado sob a licença MIT - veja o arquivo LICENSE para detalhes.

---

Desenvolvido com ❤️ para ajudar DBA's em momentos de crise.
