# ADR-001: AI Gateway — Azure API Management vs. Custom AKS-Hosted Gateway

| | |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-05-10 |
| **Deciders** | Principal AI Platform Engineer |
| **Consulted** | Senior Agent Architect, AI Security Lead, SRE |
| **Informed** | Head of Agentic Engineering, DevSecOps Engineer |

## Context

The FinDocs AI Platform needs a single ingress point for all model traffic across multiple internal tenants. This gateway must enforce:

- Per-tenant request rate limiting
- Per-tenant token quota (TPM / TPD)
- Cost attribution by tenant, model, region
- Content safety policy enforcement
- Backend failover across Azure OpenAI regions
- Centralized audit logging
- Subscription-key or OAuth-based tenant authentication

Three candidate architectures were evaluated:

1. **Azure API Management (APIM) with native AI policies** — managed PaaS, declarative XML policies, native `azure-openai-token-limit` and `azure-openai-emit-token-metric` policies (GA 2024).
2. **Custom gateway hosted on AKS** — Envoy/NGINX/Kong with custom Lua or WASM plugins for AI-specific policies.
3. **Hybrid** — APIM for external ingress, with an internal AKS sidecar layer for advanced policy logic.

## Decision

**Adopt option 1: Azure API Management with native AI policies as the sole AI gateway layer.**

Use Premium tier for production (zonal redundancy, multi-region deployment, VNet integration); Developer tier for dev/staging.

## Rationale

### Why APIM wins for this platform

1. **Native AI-aware policies remove ~80% of custom code.** The `azure-openai-token-limit` policy (GA 2024) understands token accounting from the response body without us writing token estimation logic. `azure-openai-emit-token-metric` and `azure-openai-semantic-cache-lookup` (preview) similarly cover common needs. With AKS+Envoy, every one of these would be custom Lua/WASM.

2. **Declarative XML policies are reviewable.** A 200-line XML policy file is auditable line-by-line in PRs. A 2,000-line Envoy Lua filter is not. For a regulated environment (financial services compliance, audit logging, internal SOC review), this matters substantially.

3. **Operational footprint is one managed service vs. an AKS cluster.** With APIM, we deploy XML policy updates via `az apim api policy create`. With custom AKS gateway, we'd own the gateway container image, the AKS node pool, the cert rotation, the autoscaling, the version-pinned Envoy upgrade cadence, and the in-cluster observability stack. For a platform team of 1-3 engineers, the marginal capacity to operate AKS is not justified by the marginal control.

4. **Built-in subscription key management aligns with enterprise patterns.** APIM subscriptions map cleanly to tenant credentials, with built-in key rotation and revocation. Custom gateway would need a separate identity store (Redis-backed key table, etc.).

5. **Cost is comparable at our scale.** APIM Premium 1-unit is ~$2,800/month. An AKS cluster with 3 nodes sized for gateway workload + storage + load balancer + monitoring is ~$2,000-2,500/month — close enough that the operational overhead of custom AKS isn't offset by infrastructure savings.

6. **Multi-region deployment is a checkbox.** APIM Premium supports multi-region with traffic-manager-style routing built in. With custom AKS, multi-region means a second AKS cluster, cross-region service mesh, and our own failover orchestration.

### Why we rejected custom AKS

- **Maintenance burden** dominates. Envoy version upgrades, mTLS certificate rotation, custom plugin compilation, plugin-version-to-Envoy-version compatibility — each is a recurring engineering task. APIM upgrades happen on Microsoft's schedule.
- **Custom policy logic correctness** — implementing token estimation from the OpenAI response in Lua exposes us to subtle bugs (e.g., handling streaming responses, tokenizer differences across model versions) that Microsoft's native APIM policy handles correctly by design.
- **Limited ecosystem maturity** — open-source AI gateways (Kong AI Gateway, Portkey, etc.) are improving but lack the depth of Azure-native integration. Each adds a vendor dependency outside our standardized Microsoft stack.
- **Team skill alignment.** The platform engineering team has deep APIM experience from existing API estate. Hiring or training for production Envoy operations is a significant ramp.

### Why we rejected hybrid

- The complexity multiplies: now we own both APIM policy XML AND custom AKS plugin logic, with the seam between them being its own failure mode.
- Most of the "advanced" reasons to need a custom layer (semantic caching, model arbitration across providers) are either (a) already shipping as APIM policies in preview or (b) not yet validated as production-essential for our portfolio. We'd be paying complexity cost for hypothetical future requirements.

## Consequences

### Positive

- Gateway functionality ships in weeks, not quarters
- All policy logic is reviewable by security and compliance in standard PR flow
- Multi-region failover is a configuration change, not an engineering project
- Tenant onboarding is reduced to "create a subscription, send the key" — fully automatable via Terraform
- Cost attribution logic lives in one declarative XML file (`cost-attribution.xml`) — testable, versioned, reproducible

### Negative

- **Vendor lock-in to Azure.** If the organization later migrates significant AI workload to GCP Vertex or self-hosted Llama on bare metal, the gateway layer would need to be rebuilt. Mitigation: keep the FastAPI service tenant-aware so it can be ported to a different gateway without rewriting business logic.
- **APIM policy debugging is harder than Lua/JS debugging.** No interactive debugger; iteration cycle is "edit XML → apply → curl → check trace logs." Mitigation: integration test suite in `pipelines/apim-policies-deploy.yml` validates each policy against a known-good response fixture before deployment.
- **Premium tier minimum cost is $2.8K/month even at zero traffic.** Mitigation: dev/staging environments use Developer tier ($50/mo); production cost is offset by per-tenant chargeback funded through cost-attribution.xml.
- **APIM has a request size limit (~256 KB body)** which may constrain very large prompt contexts. Mitigation: for >100K-token contexts, the FastAPI service can call Azure OpenAI directly via private endpoint with managed identity, bypassing the gateway. This is documented in the FastAPI service's tenant-context module.

### Neutral

- The `azure-openai-token-limit` and `azure-openai-emit-token-metric` policies became GA in 2024; if we'd evaluated this in 2023, the decision could have gone differently. ADR-002 (Foundry pool architecture) documents an analogous review for capacity allocation.

## Implementation notes

- Policy XML files live under `infra/modules/apim_gateway/policies/`. Each is independently testable.
- The combined policy is assembled in `infra/modules/apim_gateway/main.tf` via Terraform `file()` interpolation. This keeps each policy reviewable in isolation but deployed atomically.
- Policy changes propagate to APIM via the `pipelines/apim-policies-deploy.yml` GitHub Actions workflow, which validates the policy with `az apim api policy validate` before applying.
- Per-tenant rate and token limits are configured via APIM named values (not hardcoded in policy XML), so increasing a tenant's quota is a Terraform variable change, not a policy XML change.

## Revisit conditions

This decision should be revisited if:

- APIM policy size or complexity exceeds the maintainability ceiling (rough heuristic: >2,500 lines of combined XML, or >5 policies sharing complex state).
- A specific platform requirement materializes that APIM cannot meet (e.g., real-time per-request prompt rewriting requiring complex stateful logic).
- The organization standardizes on a different gateway product across the broader platform estate (i.e., a cross-cutting platform mandate from outside the AI engineering org).
- Microsoft signals deprecation of APIM AI policies in favor of a different product (unlikely; Microsoft is actively investing in this surface).

## References

- [Azure API Management — `azure-openai-token-limit` policy reference](https://learn.microsoft.com/azure/api-management/azure-openai-token-limit-policy)
- [Azure API Management — `azure-openai-emit-token-metric` policy reference](https://learn.microsoft.com/azure/api-management/azure-openai-emit-token-metric-policy)
- [APIM Premium tier features](https://learn.microsoft.com/azure/api-management/api-management-features)
- ADR-002 — Shared vs. isolated Foundry deployment pool
- ADR-003 — Tenant cost attribution model
