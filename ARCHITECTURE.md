# FinDocs AI Platform — Architecture

## Goals

1. **Multi-tenant AI workload hosting.** Multiple internal customer "tenants" share infrastructure (gateway, model deployments, observability) while keeping their data and quota isolated.
2. **Cost transparency.** Every token consumed is attributable to the tenant that consumed it. Platform team can publish a monthly chargeback report without manual reconciliation.
3. **Policy enforcement at the edge.** Rate limits, token quotas, content safety checks, and routing decisions happen at the API gateway — not in application code — so they apply uniformly regardless of how a tenant's agent is implemented.
4. **Resilience.** Backend model deployments fail over to a secondary region without application changes.
5. **Operational observability.** Platform team has real-time visibility into per-tenant usage, errors, latency, and cost; tenants get their own dashboards filtered by their tenant ID.

## Non-goals

- **Per-tenant model fine-tuning.** The platform uses shared base models. Per-tenant customization happens through prompts, retrieval, and per-tenant indexes — not by maintaining separate model weights.
- **Real-time data freshness.** SEC EDGAR filings update quarterly. The ingestion pipeline runs monthly. Real-time market data is out of scope.
- **End-user authentication.** The gateway authenticates tenants (each tenant is one application or team); tenants are responsible for their own end-user auth upstream of their requests.

## Component breakdown

### 1. Azure API Management (AI Gateway)

The single ingress point for all model traffic. Premium tier deployment for production (zonal redundancy, VNet integration, multi-region). Developer tier for non-prod environments.

**Inbound policies** (executed in order on every request):

1. **`global-inbound.xml`** — extracts the subscription key from the `Ocp-Apim-Subscription-Key` header, looks up the corresponding tenant ID from APIM's named-value store, sets internal context variables, and adds the tenant ID as a header forwarded to backend Azure OpenAI and to Log Analytics.
2. **`tenant-rate-limit.xml`** — `rate-limit-by-key` policy enforcing per-tenant requests-per-minute, keyed by tenant ID. Configurable per tenant via APIM named values.
3. **`tenant-token-quota.xml`** — `azure-openai-token-limit` policy (GA 2024) enforcing per-tenant tokens-per-minute and tokens-per-day. Counter keys use tenant ID.
4. **`content-safety.xml`** — `send-request` to Azure AI Content Safety on the user message; if severity exceeds threshold, returns 400 with a safety-violation response and logs the event.
5. **`backend-failover.xml`** — `retry` policy with exponential backoff; if primary Azure OpenAI region returns 429 or 5xx, automatically retries against the secondary region's deployment.

**Outbound policies**:

6. **`cost-attribution.xml`** — reads `prompt_tokens` and `completion_tokens` from the Azure OpenAI response, multiplies by per-model pricing constants, and emits a structured log entry to Log Analytics with: timestamp, tenant ID, model deployment name, region used, prompt tokens, completion tokens, estimated cost (USD).

All policies are versioned in this repo under `infra/modules/apim_gateway/policies/` and deployed via the `pipelines/apim-policies-deploy.yml` workflow.

### 2. Azure OpenAI Deployment Pool

A shared pool of model deployments serving all tenants:

| Deployment | Model | Region | Type | Capacity (TPM) |
|---|---|---|---|---|
| `gpt-4o-primary` | gpt-4o | East US | Global Standard | 150K |
| `gpt-4o-failover` | gpt-4o | East US 2 | Global Standard | 100K |
| `ada-002-primary` | text-embedding-ada-002 | East US | Global Standard | 250K |
| `ada-002-failover` | text-embedding-ada-002 | East US 2 | Global Standard | 150K |

Both regions are kept warm. APIM's `backend-failover.xml` policy routes traffic to primary; on 429 or 5xx, retries against failover.

For higher-cost-confidence workloads, a small **Provisioned Throughput Unit (PTU)** allocation can be reserved (e.g., 100 PTUs for gpt-4o) and APIM can route a designated tenant (high-priority enterprise) to PTU while others use Global Standard pay-as-you-go. This is documented in ADR-002.

### 3. Azure AI Search — Per-Tenant Indexes

Each tenant gets its own index in a shared Azure AI Search service (Standard S1 tier):

- `tech-filings` index
- `banks-filings` index
- `energy-filings` index

Tenants only ever query their own index. Index access is enforced by APIM policy — the tenant ID extracted from the subscription key determines which index the routed FastAPI service hits.

All indexes share the same schema (per-tenant `index_schema.json` in `infra/modules/ai_search_tenant/`):

| Field | Type | Purpose |
|---|---|---|
| `chunk_id` | String (key) | Unique per chunk |
| `parent_id` | String (filterable) | Filing-level grouping |
| `chunk` | String (searchable) | The text content |
| `text_vector` | Collection<Single>, 1536 dim | ada-002 embedding |
| `company_ticker` | String (filterable, facetable) | AAPL, MSFT, etc. |
| `filing_type` | String (filterable) | 10-K, 10-Q, 8-K |
| `fiscal_period` | String (filterable, sortable) | e.g. "2025-Q3" |
| `filing_date` | DateTimeOffset (filterable, sortable) | When SEC accepted it |
| `section` | String (filterable) | e.g. "Item 1A. Risk Factors" |
| `title` | String (searchable) | For citation display |

Hybrid + semantic search is enabled on every tenant index, matching the configuration of [100products](https://github.com/shidokan/100products).

### 4. SEC EDGAR Ingestion (Azure Functions)

A timer-triggered Azure Function runs monthly to fetch new filings:

1. Query SEC EDGAR's full-text search API for filings posted in the last 30 days for each tenant's company list.
2. Download each filing's main HTML/text file (respecting EDGAR's 10 req/sec rate limit and `User-Agent` requirement).
3. Section-aware chunking — splits 10-Ks and 10-Qs on Item headings (Item 1, Item 1A, Item 7, etc.) so chunks align with semantic document structure rather than arbitrary byte boundaries.
4. Embed via `ada-002-primary` deployment, write to the appropriate tenant index.
5. Emit ingestion metrics (filings processed, chunks created, embedding tokens consumed) to Log Analytics tagged with `tenant_id` and `pipeline_run_id`.

The Function App uses a system-assigned managed identity with `Search Service Contributor` and `Storage Blob Data Contributor` roles, plus an API key for Azure OpenAI embedding calls stored in Key Vault.

### 5. FastAPI Service (Tenant-Aware)

The actual RAG pipeline lives in `api/findocs_rag.py`. It receives requests that have already passed through APIM, reads the `X-Tenant-ID` header that APIM set, routes the AI Search query to that tenant's index, calls the gpt-4o deployment, returns a grounded response with citations.

The service is intentionally **tenant-unaware in its business logic** — the tenant ID is just a header value that determines which index to query. This means a single deployed FastAPI instance serves all tenants. Scale-out happens at the container level via Azure Container Apps' HTTP-based scaling rules.

### 6. Observability

Three layers:

**Platform-level**: Log Analytics workspace receives logs from APIM (one record per request, per `cost-attribution.xml`), Container Apps, AI Search, Azure OpenAI, Function App. Kusto queries in `observability/kusto/` produce:

- Token usage by tenant, per hour / day / month
- Cost by tenant, per model, per fiscal period
- Error rates by tenant and HTTP status
- Latency P50/P95/P99 by tenant and model
- Quota-breach events by tenant

**Workbook dashboards** in `observability/dashboards/` provide:

- Platform-overview dashboard for platform engineering team (all tenants, aggregated)
- Per-tenant dashboard accessible to that tenant only (using Azure Workbook variable scoping)

**Alerts** in `observability/alerts/`:

- Rate-limit breach (per tenant, threshold > 5 events in 5 min)
- Cost anomaly (per tenant, daily cost > 2x trailing 30-day average)
- Backend failover triggered (any region failover event)
- Indexer pipeline failure (monthly EDGAR run failed)

## Multi-region resilience

| Component | Primary region | Failover region | Failover mechanism |
|---|---|---|---|
| APIM | East US | East US 2 | Premium tier multi-region deployment with traffic manager |
| Azure OpenAI | East US | East US 2 | APIM `retry` policy in `backend-failover.xml` |
| AI Search | East US | East US 2 (async geo-replicated read replica) | DNS swap via runbook |
| Container Apps | East US | East US 2 | Front Door routing |
| Storage / Key Vault | East US (GRS) | East US 2 (failover endpoint) | Azure-managed |
| Log Analytics | East US | (single workspace; cross-region query via federation) | N/A |

## Identity and security

- **Tenant authentication** to the platform: APIM subscription keys (one per tenant). Future iteration: OAuth 2.0 client credentials flow with Entra ID app registration per tenant.
- **Backend authentication** (APIM → Azure OpenAI): APIM's system-assigned managed identity, granted `Cognitive Services OpenAI User` role on the Foundry resource.
- **Backend authentication** (Container Apps → AI Search): Container App's system-assigned managed identity, granted `Search Index Data Reader` on the relevant indexes.
- **Secrets**: All secrets (Azure OpenAI keys for fallback, EDGAR User-Agent string, internal tenant config) stored in Azure Key Vault. APIM named values and Container Apps env vars reference Key Vault via Managed Identity.
- **Network**: APIM in Premium tier deployed to a VNet with private endpoints to Foundry, AI Search, Key Vault, Storage. Public ingress only at APIM frontend; tenants cannot reach Foundry directly.

## Cost model

Order-of-magnitude monthly cost at moderate utilization (1M tokens/day total across all tenants):

| Component | SKU | Approx monthly cost |
|---|---|---|
| APIM Premium 1-unit | Premium_1 | $2,800 |
| Azure OpenAI (gpt-4o Global Standard) | Pay-per-token, ~$1,500 at 1M tokens/day | $1,500 |
| Azure OpenAI (ada-002) | Pay-per-token | $100 |
| AI Search Standard S1 (3 indexes, 3 partitions, 2 replicas) | S1 | $250 |
| Container Apps (scale-to-zero) | Consumption | $50 |
| Azure Functions (timer trigger) | Consumption | $5 |
| Log Analytics ingestion (~5 GB/month) | Pay-as-you-go | $25 |
| Storage (Blob + ADLS for filings, ~100 GB) | Standard LRS | $5 |
| Key Vault | Standard | $5 |
| **Total** | | **~$4,750** |

Per-tenant cost attribution via `cost-attribution.xml` enables monthly chargeback. Platform team retains the fixed infrastructure cost (APIM Premium, AI Search baseline); variable token costs flow to tenants.

For dev/staging environments, costs scale down significantly: APIM Developer tier (~$50/mo), AI Search Basic ($75/mo), and a single shared dev tenant — total ~$200/mo per non-prod environment.

## Roadmap

- **Phase 1** *(this repo)*: APIM AI gateway with rate/quota/cost policies, three demo tenants, Terraform IaC, SEC EDGAR ingestion, GitHub Actions deployment pipeline.
- **Phase 2**: Entra ID-based tenant auth (replace subscription keys); APIM workspace-per-tenant for self-service config; per-tenant Foundry sub-projects for stronger isolation.
- **Phase 3**: PTU allocation for tier-1 tenants with reserved capacity; semantic cache layer (Redis) for high-frequency queries; LangSmith integration for trace-level observability.
- **Phase 4**: Multi-region active-active with Cosmos DB-backed conversation state; chaos engineering tests for failover paths; FinOps dashboard with rolling 12-month cost projection per tenant.
