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
7. **`system.trace_log` engole o disco.** Sintoma: `data/` cresce vários GB/dia
   sem que a telemetria (`signoz_*`) cresça junto. Num deploy real chegou a
   **21 GiB / 1 bilhão de linhas** enquanto todo o `signoz_*` somava < 1 GiB.
   Causa: `global_profiler_real_time_period_ns` (server-level) vem LIGADO por
   padrão (10s) e amostra TODAS as threads do servidor, inclusive as de
   background — essas linhas têm `query_id = ''`. Medido: ~435 linhas/s
   (~33M/dia) antes, ~2 linhas/s depois. Corrigido em
   `clickhouse/system-logs.xml` (montado em `config.d/`), que também põe TTL e
   partição diária nas tabelas `system.*` — elas vêm com partição MENSAL e
   NENHUM TTL, ou seja, crescem pra sempre. Três pegadinhas ao aplicar:
   - Desabilitar `query_profiler_*` no `users.xml` NÃO resolve: aquilo é
     perfil de usuário e cobre só queries (eram 1,4% do volume). O que importa
     é o `global_profiler_*`, que é server-level.
   - `global_profiler_*` NÃO recarrega a quente. `docker compose up -d` não
     basta — precisa de `docker compose restart clickhouse`.
   - Ao mudar `partition_by`/`ttl` de uma tabela de sistema, o ClickHouse
     RENOMEIA a antiga para `trace_log_0` etc. e cria uma nova vazia. Então
     **truncar ANTES do restart** — senão os GB só mudam de nome. Depois,
     dropar as `*_log_<N>` remanescentes.

   Diagnóstico rápido de "quem está ocupando disco":
   ```sql
   SELECT database, table, formatReadableSize(sum(bytes_on_disk)), sum(rows)
   FROM system.parts WHERE active GROUP BY database, table
   ORDER BY sum(bytes_on_disk) DESC LIMIT 20
   ```

   Retenção da telemetria de verdade (`signoz_*`) é outra história: também não
   vem configurada por padrão, mas se ajusta na UI em *Settings → Retention*.
8. **`system.metric_log` crava CPU em loop infinito de merge.** Sintoma: ClickHouse
   a 100%+ de CPU constante SEM queries e SEM merges visíveis em `system.merges`;
   threads campeãs no `top -H` chamadas `MergeMu…`; `system.errors` com milhares
   de `MEMORY_LIMIT_EXCEEDED`; log com `Exception is in merge_task ... table
   system.metric_log`. Causa: a `metric_log` tem ~1.200 colunas e o merge abre um
   write-stream (buffers de MBs) POR COLUNA → em máquina pequena (7,5 GiB) estoura
   o limite de memória, falha e re-tenta pra sempre. Efeito colateral: o contador
   `MergesMutationsMemoryTracking` (ver `system.metrics`) fica inflado (~6,7 GiB
   com RSS real de 2 GiB) e satura o tracker total — aí TODA alocação de merge
   falha na hora. TTL NÃO resolve (o problema é o merge, não a retenção).
   Correção em `clickhouse/system-logs.xml`: `remove="1"` na `metric_log` e nas
   demais tabelas de log pesadas (só a `query_log` fica). Ao aplicar:
   - A config só impede a RECRIAÇÃO. Ordem certa: `docker compose restart
     clickhouse` (zera o tracker vazado e carrega a config) e DEPOIS
     `DROP TABLE IF EXISTS system.<tabela> SYNC` de cada uma.
   - Usar `SYNC` no drop: sem ele, database Atomic segura os dados no `store/`
     por 8 min (`database_atomic_delay_before_drop_table_sec`) e o `du` não cai.

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
