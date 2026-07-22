# SigNoz — stack standalone (docker compose)

Stack autocontida do [SigNoz](https://signoz.io) para subir com **um comando**,
sem Coolify. Todos os configs **e os dados** ficam em **pastas locais** (bind
mounts), nada em volume nomeado — fácil de clonar num servidor e rodar.

## Versões

| Componente | Imagem |
|---|---|
| SigNoz | `signoz/signoz:v0.134.0` |
| OTel Collector | `signoz/signoz-otel-collector:v0.144.6` |
| Schema migrator | `signoz/signoz-schema-migrator:v0.144.6` |
| ClickHouse | `clickhouse/clickhouse-server:25.12.5` |
| ZooKeeper | `signoz/zookeeper:3.9.3` |

## Subir (clonar → gerar env → up)

```bash
git clone https://github.com/RodriguesCosta/signoz-stack.git
cd signoz-stack
./generate-env.sh          # gera .env (segredo JWT) e cria as pastas ./data
docker compose up -d
```

Na **primeira subida**, o `schema-migrator-sync` aplica as migrations e pode
levar alguns minutos — é normal. Acompanhe:

```bash
docker compose logs -f schema-migrator-sync   # tem que terminar e sair (exit 0)
docker compose ps                             # todos running/healthy
docker compose logs -f signoz otel-collector
```

## Acessar

- **UI**: http://localhost:58080  (no 1º acesso você cria o usuário admin)
- **Ingestão OTLP**:
  - HTTP → `http://localhost:4318`
  - gRPC → `localhost:4317`

## Estrutura

```
signoz-stack/
├── docker-compose.yaml
├── generate-env.sh            # gera .env + pastas de dados
├── .env.example               # modelo (o .env real NÃO vai pro git)
├── clickhouse/                # configs do ClickHouse
│   ├── config.xml
│   ├── users.xml
│   ├── cluster.xml
│   └── custom-function.xml
├── signoz/
│   ├── prometheus.yml
│   └── otel-collector-opamp-config.yaml
├── otel-collector-config.yaml
├── dashboards/                # dashboards pré-carregados (opcional)
└── data/                      # DADOS PERSISTENTES — criado pelo script, fora do git
    ├── clickhouse/
    ├── zookeeper/
    └── sqlite/                # dashboards, alertas, usuários
```

## Operar

```bash
docker compose ps                              # status
docker compose logs -f signoz                  # logs de um serviço
docker compose down                            # parar (mantém os dados em ./data)
docker compose pull && docker compose up -d    # atualizar imagens depois
```

## Zerar tudo (apaga os dados)

```bash
docker compose down
rm -rf ./data/clickhouse/* ./data/zookeeper/* ./data/sqlite/*
```

## Se der erro de permissão no ClickHouse/ZooKeeper

Bind mount às vezes esbarra em permissão dependendo do host. Se algum container
reclamar de "permission denied" na pasta de dados:

```bash
docker compose down
sudo chown -R 101:101 ./data/clickhouse    # uid do usuário clickhouse
sudo chmod -R 777 ./data/zookeeper ./data/sqlite
docker compose up -d
```

## Notas

- O `.env` (com o `SIGNOZ_JWT_SECRET`) e a pasta `data/` **não vão para o git**
  (`.gitignore`). Cada servidor gera o seu com `./generate-env.sh`.
- E-mail/SMTP vem **desligado**. Para ligar alertas por e-mail, preencha as
  variáveis `SIGNOZ_EMAILING_SMTP_*` no `.env` e mude
  `SIGNOZ_EMAILING_ENABLED=true` no `docker-compose.yaml`.
- Telemetria de uso (`SIGNOZ_STATSREPORTER_ENABLED`) vem **desligada**.
