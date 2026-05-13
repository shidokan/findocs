# ADR-003: Tenant Cost Attribution Model

| | |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-05-10 |
| **Deciders** | Principal AI Platform Engineer, Product Lead — AI Platform |
| **Consulted** | FinOps, SRE, Senior Agent Architect |
| **Informed** | Head of Agentic Engineering, Tenant team leads |

## Context

The FinDocs AI Platform hosts multiple internal tenants on shared infrastructure. Platform team needs to attribute variable costs (tokens, AI Search query operations, ingestion compute) to the specific tenant that consumed them, and to publish a monthly chargeback report.

Three approaches were evaluated:

1. **Azure-native subscription tagging** — separate Azure subscription per tenant; Cost Management produces per-subscription reports automatically.
2. **Resource tagging** — single shared subscription with `tenant_id` tags on Azure resources; Cost Management groups by tag.
3. **Application-level token-cost attribution** — gateway-side policy emits per-request log records with computed cost; aggregated via Kusto queries against Log Analytics.

## Decision

**Adopt option 3 (gateway-emitted token-cost attribution) as the primary cost model, with option 2 (resource tagging) as a complementary source for fixed-infrastructure cost.**

Per-request cost computation happens in `infra/modules/apim_gateway/policies/cost-attribution.xml`, which emits structured Log Analytics events tagged with `tenant_id`, `model_deployment`, `prompt_tokens`, `completion_tokens`, and `estimated_cost_usd`. Aggregation queries live in `observability/kusto/cost-by-tenant.kql`.

## Rationale

### Why not Azure-native subscription-per-tenant (option 1)

This is the most common pattern for multi-tenant chargeback in non-AI contexts (e.g., per-business-unit subscriptions). It doesn't work cleanly for AI workloads because:

- **Shared model deployments are the cost center.** A single Azure OpenAI deployment serves multiple tenants. There's no Azure-native way to slice a deployment's cost by which tenant consumed it. Azure Cost Management would attribute 100% of the deployment to whichever subscription owns the resource.
- **PTU economics get worse.** If we ever want to use Provisioned Throughput Units (high-commitment, reserved capacity), splitting them across subscriptions fragments capacity and increases minimum PTU buy. Shared deployments preserve PTU efficiency.
- **Operational overhead.** Per-tenant subscriptions multiply the management surface: per-subscription Foundry resources, per-subscription Key Vault, per-subscription RBAC, per-subscription quota requests to Microsoft. For a 10-tenant platform, that's 10x the operational footprint.
- **Onboarding latency.** Adding a new tenant becomes "provision a new Azure subscription" which involves enterprise enrollment, MCA agreements, and procurement — measured in days/weeks, not minutes.

### Why not pure resource tagging (option 2)

Resource tagging is necessary but not sufficient. Cost Management groups by tag, but:

- **Token costs are not associated with a resource — they're associated with a request.** A single Azure OpenAI deployment can't be tagged "tenant=tech" if multiple tenants share it.
- **Tag-based reporting has a 24-72 hour lag** from Azure Cost Management's billing pipeline, which is too slow for near-real-time tenant dashboards (a tenant wanting to verify "did my cost spike at 2pm?" needs sub-hour resolution).
- **Tag-based reporting cannot decompose** a single billing line item across multiple tenants. We'd need a separate model anyway to handle the "shared resource, split usage" case.

Resource tagging IS used for **fixed infrastructure cost** (APIM Premium baseline, AI Search baseline, networking) — those are tagged with `cost_center: platform-engineering` and absorbed by the platform team, not chargedback to tenants. See `infra/modules/apim_gateway/main.tf` for the tag scheme.

### Why gateway-emitted attribution wins

- **Sub-second resolution.** Each request emits a log event within milliseconds of completion. Tenant dashboards can show cost-per-hour with no batch lag.
- **Granular dimensions.** Every cost record carries `tenant_id`, `tenant_tier`, `model_deployment`, `region`, `correlation_id`, prompt + completion tokens, and computed USD. Analysts can pivot on any of these.
- **Verifiable from response data.** Token counts come directly from Azure OpenAI's `usage` field in the response body, not estimated. The pricing multiplier is the only "lossy" step, and it's defined as a named value in APIM (updateable when Microsoft changes prices).
- **Works for any backend, not just OpenAI.** The same policy structure can attribute cost for embedding services, Content Safety calls, AI Search queries, and future model providers — anything that flows through the gateway.
- **Audit trail by design.** Every record has a correlation ID joining gateway log, FastAPI service log, and downstream Azure OpenAI log — useful for both billing disputes and incident investigation.

### Pricing source of truth

Per-1K-token prices are configured as APIM named values:

| Named value | Default | Source |
|---|---|---|
| `price-gpt-4o-prompt-per-1k` | 0.0025 | [Azure OpenAI pricing — gpt-4o input](https://azure.microsoft.com/pricing/details/cognitive-services/openai-service/) |
| `price-gpt-4o-completion-per-1k` | 0.01 | gpt-4o output |
| `price-ada-002-per-1k` | 0.0001 | text-embedding-ada-002 |

Updates to Microsoft pricing flow through the `pipelines/apim-policies-deploy.yml` workflow which validates and applies named-value changes. Historical pricing is preserved in git for audit (a tenant's monthly bill in October 2026 was computed against October 2026 prices).

The policy intentionally uses **list prices**, not committed-spend discounts (CSP/EA/MCA discounts). The platform team takes the spread as a contribution toward fixed infrastructure cost. ADR-005 (when written) will document the FinOps model that decides this spread per fiscal year.

## Consequences

### Positive

- Tenants get real-time cost visibility — supports the platform team's promise of cost transparency.
- Tenant onboarding is unaffected by cost-tracking complexity — adding a tenant means provisioning an APIM subscription and (optionally) a tenant AI Search index, not a new Azure subscription.
- Chargeback report generation is a single Kusto query (in `observability/kusto/monthly-chargeback.kql`).
- Pricing updates roll out as a code change with the same review process as policy changes.

### Negative

- **Estimated cost ≠ Azure-billed cost.** Our computed value is a list-price estimate; Microsoft's actual invoice reflects enterprise discounts, true-ups, and any reservation usage. Mitigation: monthly reconciliation script (in `observability/kusto/azure-vs-attribution-reconciliation.kql`) compares Kusto totals to Azure Cost Management actuals; deltas are explained in the chargeback report.
- **Custom code in policy XML is a maintenance vector.** If Azure OpenAI changes its response structure or introduces new pricing dimensions (e.g., image generation costs, fine-tuned model surcharges), the cost-attribution policy must be updated. Mitigation: integration tests in `pipelines/apim-policies-deploy.yml` exercise each model type's response shape; pricing dimensions are isolated in named values for low-touch updates.
- **No attribution for direct (bypassing-gateway) requests.** If a tenant goes around the gateway and hits Azure OpenAI directly (which would require an Azure OpenAI key, which they don't get), there's no attribution. Mitigation: network policy via private endpoints denies direct Azure OpenAI access; only APIM's managed identity is granted `Cognitive Services OpenAI User` role. This is enforced in `infra/modules/foundry/main.tf`.

### Neutral

- Log Analytics ingestion adds ~$25/month at expected volume (roughly 1M requests/month × ~400 bytes per record). Already accounted for in the platform's fixed cost model.

## Implementation status

- `cost-attribution.xml` policy — implemented and unit-tested
- `observability/kusto/cost-by-tenant.kql` — implemented; produces per-tenant daily/monthly cost rollups
- `observability/kusto/monthly-chargeback.kql` — implemented; produces month-end chargeback report formatted for finance team consumption
- Monthly reconciliation against Azure Cost Management — planned for Phase 2 (next quarter)

## References

- ADR-001 — APIM vs. AKS gateway (established the platform that emits these events)
- ADR-002 — Shared vs. isolated Foundry pool (established that deployments are shared, necessitating per-request attribution)
- `infra/modules/apim_gateway/policies/cost-attribution.xml`
- `observability/kusto/cost-by-tenant.kql`
- [FinOps Foundation — Cost Allocation methodologies](https://www.finops.org/framework/capabilities/cost-allocation/)
