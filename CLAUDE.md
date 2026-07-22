# CLAUDE.md

Contexto pra assistentes (Claude Code) trabalharem neste repositório.

## O que é

Stack **standalone** do [SigNoz](https://signoz.io) para rodar com
`docker compose up -d`, sem Coolify/Foundry. Objetivo: clonar num servidor e
subir com um comando. Configs **e dados** ficam em **pastas locais** (bind
mounts), nada em volume nomeado.

Não é o repositório do SigNoz — é só um empacotamento de deploy.

## Comandos essenciais

```bash
./generate-env.sh                 # gera .env (segredo JWT) + cria ./data/*
docker compose up -d              # sobe a stack
docker compose config             # valida o compose (usar após qualquer edição)
docker compose logs -f schema-migrator-sync   # 1ª subida: esperar exit 0
docker compose ps                 # status/health
docker compose down               # para (mantém dados em ./data)
docker compose pull && docker compose up -d    # atualizar imagens
```

## Versões (jul/2026 — as mais recentes)

| Componente | Imagem |
|---|---|
| SigNoz | `signoz/signoz:v0.134.0` |
| OTel Collector | `signoz/signoz-otel-collector:v0.144.6` |
| Schema migrator | `signoz/signoz-schema-migrator:v0.144.6` |
| ClickHouse | `clickhouse/clickhouse-server:25.12.5` |
| ZooKeeper | `signoz/zookeeper:3.9.3` |

**Esquema de versões (importante):** o `signoz/signoz` segue as tags do git do
repo SigNoz. Já `signoz-otel-collector` e `signoz-schema-migrator` têm
numeração PRÓPRIA (repo `SigNoz/signoz-otel-collector`) e **devem sempre usar a
mesma tag entre si**. Para achar as últimas:
- app: `git ls-remote --tags https://github.com/SigNoz/signoz.git 'refs/tags/v*'`
- collector/migrator: `gh release list --repo SigNoz/signoz-otel-collector`

## Arquitetura / ordem de boot

`depends_on` já garante a sequência (não reordenar):

```
init-clickhouse (baixa histogram-quantile) ─┐
zookeeper-1 (healthy) ──────────────────────┴─▶ clickhouse (healthy)
   └─▶ schema-migrator-sync (roda migrations, completa) ─▶ signoz (healthy) ─▶ otel-collector
                                                        └─▶ schema-migrator-async
```

- UI: host `:58080` → container `:8080` · OTLP HTTP: `:4318` · OTLP gRPC: `:4317`

## Gotchas (não repetir erros passados)

1. **ClickHouse deve ser a imagem NÃO-alpine.** A `-alpine` pode não ter `bash`,
   e o `init-clickhouse` roda `bash -c ...` → falha → `clickhouse` nunca sobe →
   stack inteira trava. Foi a causa de um deploy travado.
2. **Hostnames são fixos pelos configs.** `clickhouse/cluster.xml` referencia os
   hosts `clickhouse` e `zookeeper-1`; o opamp aponta `ws://signoz:4320`. Se
   renomear um serviço no compose, ajustar os XML/yaml correspondentes.
3. **histogram-quantile:** o `custom-function.xml` usa `<command>./histogramQuantile</command>`,
   então o binário tem que ser um ARQUIVO em `user_scripts/histogramQuantile`
   (não um diretório). O `init-clickhouse` e o `clickhouse` compartilham o mesmo
   bind mount `./data/clickhouse` pra esse binário persistir.
4. **Permissão de bind mount:** o container do SigNoz roda como root (Dockerfile
   sem `USER`), então sqlite em pasta local funciona. Se ClickHouse/ZooKeeper
   reclamarem de permissão, ver seção de permissões no README.
5. **Sem magic-envs do Coolify.** Nada de `SERVICE_URL_*`, `SERVICE_REALBASE64_*`
   ou `exclude_from_hc` (essa última quebra o `docker compose` puro).
6. **Feature-gate `NormalizeName` do collector.** A flag
   `--feature-gates=-pkg.translator.prometheus.NormalizeName` (o `-` = desabilitar)
   NÃO existe mais a partir da `v0.144.6`: o gate graduou pra "stable" e não pode
   ser desabilitado → o collector aborta no boot em loop
   (`Error: invalid argument ... feature gate ... is stable, can not be disabled`).
   A correção é REMOVER essa linha do `command:` do `otel-collector`. Conferir
   flags de feature-gate a cada bump do collector.

## Segredos

- `SIGNOZ_JWT_SECRET` fica no `.env` (gitignored). `generate-env.sh` gera.
- `.env` e `data/` **nunca** vão pro git. É repo **público** — conferir antes de
  commitar que nenhum segredo entrou (`git ls-files | grep -i env`).

## De onde vieram os configs

Os XML/yaml em `clickhouse/`, `signoz/` e o `otel-collector-config.yaml` foram
extraídos da tag **`v0.129.0`** do repo SigNoz — a última que ainda os continha
antes de `deploy/` ser removido (migração pro Foundry). Ao atualizar as imagens,
conferir se esses configs seguem compatíveis com as versões novas.

## Ao atualizar versões

1. Editar as tags em `docker-compose.yaml` (manter collector == migrator).
2. `docker compose config` pra validar.
3. Rodar e acompanhar `schema-migrator-sync` até `exit 0`.
4. Atualizar a tabela de versões aqui e no `README.md`.
