# FinDocs AI Platform

A multi-tenant Azure-based AI platform for retrieval-augmented financial document analysis. Built to demonstrate **AI platform engineering at enterprise scale** — not a single-tenant RAG application, but the infrastructure that hosts and governs AI workloads across multiple internal customers.

> Companion portfolio piece to [100products](https://github.com/shidokan/100products), which demonstrates application-level RAG. This repo demonstrates the **platform layer** that an enterprise builds underneath multiple such applications.

## What this demonstrates

**For AI Platform Engineer roles**, this repo shows hands-on ownership of the capabilities the role description typically asks for:

| Platform capability | Where it lives in this repo |
|---|---|
| **AI Gateway architecture** — traffic routing, rate limiting, quota enforcement, failover | `infra/modules/apim_gateway/` (Azure API Management with AI policies) |
| **Per-tenant token quota** and rate limiting at the gateway | `infra/modules/apim_gateway/policies/tenant-token-quota.xml`, `tenant-rate-limit.xml` |
| **Cost attribution** — token-level usage tagged to internal customers | `infra/modules/apim_gateway/policies/cost-attribution.xml`, `observability/kusto/` |
| **Foundry runtime management** — capacity planning, deployment pool, version pinning | `infra/modules/foundry/` |
| **Per-tenant index isolation** with shared embedding model | `infra/modules/ai_search_tenant/` |
| **AI deployment pipelines** — dev → staging → prod with quality gates | `pipelines/agent-deploy.yml` |
| **Platform governance** — Architecture Decision Records, runbooks, Azure Policy | `governance/` |
| **Observability** — KQL queries, Azure Workbooks, alerts | `observability/` |
| **Multi-region failover** of backend OpenAI deployments | `infra/modules/apim_gateway/policies/backend-failover.xml` |
| **Content safety** policy enforcement at the gateway | `infra/modules/apim_gateway/policies/content-safety.xml` |

## Architecture summary

```
                  ┌───────────────────────────────────────┐
                  │  Azure API Management (Premium)       │
                  │  AI Gateway                           │
                  │                                       │
                  │  • Subscription key → Tenant lookup   │
                  │  • Per-tenant request rate limit      │
                  │  • Per-tenant token quota (TPM/TPD)   │
                  │  • Cost attribution headers           │
                  │  • Content Safety policy enforcement  │
                  │  • Backend pool with failover         │
                  │  • Audit log → Log Analytics          │
                  └─────────────┬─────────────────────────┘
                                │
              ┌─────────────────┼─────────────────┐
              ▼                 ▼                 ▼
        ┌─────────┐       ┌─────────┐       ┌─────────┐
        │  Tech   │       │  Banks  │       │ Energy  │
        │ Tenant  │       │ Tenant  │       │ Tenant  │
        │         │       │         │       │         │
        │ AAPL,   │       │ JPM,    │       │ XOM,    │
        │ MSFT,   │       │ BAC,    │       │ CVX,    │
        │ NVDA…   │       │ WFC…    │       │ COP…    │
        │         │       │         │       │         │
        │ Private │       │ Private │       │ Private │
        │  Index  │       │  Index  │       │  Index  │
        └────┬────┘       └────┬────┘       └────┬────┘
             │                 │                 │
             └──── shared ─────┼──── shared ─────┘
                               ▼
              ┌──────────────────────────────────┐
              │ Azure OpenAI (gpt-4o + ada-002)  │
              │ shared deployment pool           │
              │ Primary: East US                 │
              │ Failover: East US 2              │
              │ Usage tagged with tenant ID      │
              └──────────────────────────────────┘
                               ▲
                               │
              ┌────────────────┴───────────────┐
              │ SEC EDGAR bulk-download ETL    │
              │ (Azure Functions timer trigger,│
              │  monthly per-sector ingest)    │
              └────────────────────────────────┘
```

See [`ARCHITECTURE.md`](./ARCHITECTURE.md) for full system design with component-level detail.

## Repository structure

```
findocs/
├── infra/                     Terraform IaC for the platform
│   ├── modules/
│   │   ├── apim_gateway/      ← THE differentiator (APIM with AI policies)
│   │   ├── foundry/           Azure OpenAI deployment pool
│   │   ├── ai_search_tenant/  Per-tenant vector index module
│   │   └── observability/     Log Analytics, App Insights, alerts
│   └── environments/          dev / staging / prod tfvars
├── pipelines/                 CI/CD pipelines
│   ├── agent-deploy.yml       Dev→Staging→Prod with quality gates
│   ├── ingest-edgar.yml       Monthly SEC EDGAR ETL
│   ├── apim-policies-deploy.yml  Policy versioning + deployment
│   └── infra-promote.yml      Terraform plan/apply
├── ingestion/                 SEC EDGAR ETL (Python)
│   ├── edgar_fetcher.py
│   ├── filing_chunker.py
│   └── tenant_router.py
├── api/                       Tenant-aware FastAPI service
│   ├── findocs_rag.py
│   ├── tenant_context.py
│   └── cost_tracker.py
├── observability/             KQL, Workbooks, alerts
│   └── kusto/                 Per-tenant usage, cost attribution queries
└── governance/                Platform governance artifacts
    ├── adr/                   Architecture Decision Records
    ├── policies/              Azure Policy assignments
    └── runbooks/              Tenant onboarding, incident response
```

## Tenants and data

Three sector-aligned tenants for demonstration, each ingesting SEC EDGAR public filings:

| Tenant | Companies | Filing types | Approx documents |
|---|---|---|---|
| **Tech** | AAPL, MSFT, NVDA, GOOGL, META, AMZN, ORCL, IBM, ADBE, CRM | 10-K, 10-Q (last 3 fiscal years) | ~120 |
| **Banks** | JPM, BAC, WFC, C, GS, MS, USB, PNC, TFC, COF | 10-K, 10-Q (last 3 fiscal years) | ~120 |
| **Energy** | XOM, CVX, COP, EOG, OXY, PSX, MPC, VLO, SLB, HAL | 10-K, 10-Q (last 3 fiscal years) | ~120 |

After chunking (typical 10-K is 80-150 pages, section-aware splits): roughly 2,500-3,500 vector chunks per tenant index.

## Quick start (development environment)

```bash
# 1. Clone and set up
git clone https://github.com/shidokan/findocs.git
cd findocs
cp .env.template .env  # fill in Azure subscription details

# 2. Provision infrastructure
cd infra
terraform init
terraform plan -var-file=environments/dev.tfvars
terraform apply -var-file=environments/dev.tfvars

# 3. Ingest filings for one tenant (start small)
cd ../ingestion
python edgar_fetcher.py --tenant tech --companies AAPL,MSFT,NVDA --filings 10-K,10-Q

# 4. Deploy the FastAPI service
cd ../api
docker build -t findocs-rag .
# (deploy to Container Apps via the agent-deploy pipeline)

# 5. Test through APIM gateway
APIM_KEY="<tech-tenant-subscription-key>"
APIM_URL="<your-apim-instance>.azure-api.net"
curl -X POST "https://${APIM_URL}/openai/chat" \
     -H "Ocp-Apim-Subscription-Key: ${APIM_KEY}" \
     -H "Content-Type: application/json" \
     -d '{"question":"Compare cloud revenue growth between Microsoft and Amazon in FY2025"}'
```

See [`infra/README.md`](./infra/README.md) for full deployment walkthrough.

## Architecture Decision Records

Substantive design decisions are documented as ADRs in [`governance/adr/`](./governance/adr/):

- [001 — APIM vs. AKS-hosted custom gateway](./governance/adr/001-apim-vs-aks-gateway.md)
- [002 — Shared vs. isolated Foundry deployment pool](./governance/adr/002-shared-vs-isolated-foundry-pool.md)
- [003 — Tenant cost attribution model](./governance/adr/003-tenant-cost-attribution-model.md)
- 004 — Multi-region failover strategy *(planned)*
- 005 — RAG vs. fine-tuning per-tenant *(planned)*

## License

MIT — see [LICENSE](./LICENSE).

## Author

John Carlo Cueva — Principal Cloud / AI Architect

This repo accompanies the [100products](https://github.com/shidokan/100products) application-level RAG demo. Together they cover the application layer (100products) and the platform layer (FinDocs) of an enterprise AI engineering portfolio.
