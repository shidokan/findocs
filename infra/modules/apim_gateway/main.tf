################################################################################
# FinDocs AI Gateway — Azure API Management Module
#
# Provisions:
#   - API Management instance (configurable SKU per environment)
#   - System-assigned managed identity (used to authenticate to Azure OpenAI)
#   - API definition for Azure OpenAI proxy
#   - Backend pool with primary + failover Azure OpenAI deployments
#   - Named values for per-tenant config (rate limits, quotas, pricing, tenant IDs)
#   - Per-tenant subscriptions (subscription key = tenant credential)
#   - Application Insights logger for cost-attribution policy
#   - All six policy XML files applied (global + 5 specialized)
#
# Usage:
#   module "gateway" {
#     source = "./modules/apim_gateway"
#     ...   (see variables.tf)
#   }
################################################################################

terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }
}

# -----------------------------------------------------------------------------
# 1. API Management instance
# -----------------------------------------------------------------------------
resource "azurerm_api_management" "this" {
  name                = var.apim_name
  resource_group_name = var.resource_group_name
  location            = var.location
  publisher_name      = "FinDocs AI Platform"
  publisher_email     = var.publisher_email
  sku_name            = var.sku_name # e.g. "Developer_1" / "Premium_1"

  identity {
    type = "SystemAssigned"
  }

  dynamic "virtual_network_configuration" {
    for_each = var.subnet_id != null ? [1] : []
    content {
      subnet_id = var.subnet_id
    }
  }
  virtual_network_type = var.subnet_id != null ? "External" : "None"

  tags = var.tags
}

# -----------------------------------------------------------------------------
# 2. Application Insights logger (target for cost-attribution.xml)
# -----------------------------------------------------------------------------
resource "azurerm_api_management_logger" "ai" {
  name                = "findocs-cost-logger"
  api_management_name = azurerm_api_management.this.name
  resource_group_name = var.resource_group_name
  resource_id         = var.application_insights_id

  application_insights {
    instrumentation_key = var.application_insights_instrumentation_key
  }
}

# -----------------------------------------------------------------------------
# 3. Named values: pricing table, tenant config, content safety endpoint
# -----------------------------------------------------------------------------
locals {
  pricing_named_values = {
    "price-gpt-4o-prompt-per-1k"     = "0.0025"
    "price-gpt-4o-completion-per-1k" = "0.01"
    "price-ada-002-per-1k"           = "0.0001"
  }

  rate_limit_named_values = {
    "rate-limit-standard" = "60"  # requests / minute
    "rate-limit-premium"  = "600" # requests / minute
  }

  token_limit_named_values = {
    "token-limit-standard" = "10000"  # tokens / minute
    "token-limit-premium"  = "100000" # tokens / minute
  }

  content_safety_named_values = {
    "content-safety-endpoint"            = var.content_safety_endpoint
    "content-safety-threshold-default"   = "4"
  }

  # Per-tenant ID lookups: named value "tenant-id-{subscription-id}" -> tenant slug
  # Populated dynamically in the subscription resource below.

  static_named_values = merge(
    local.pricing_named_values,
    local.rate_limit_named_values,
    local.token_limit_named_values,
    local.content_safety_named_values,
  )

  static_secret_values = {
    "content-safety-key" = var.content_safety_key
  }
}

resource "azurerm_api_management_named_value" "static" {
  for_each            = local.static_named_values
  name                = each.key
  api_management_name = azurerm_api_management.this.name
  resource_group_name = var.resource_group_name
  display_name        = each.key
  value               = each.value
  secret              = false
}

resource "azurerm_api_management_named_value" "secrets" {
  for_each            = local.static_secret_values
  name                = each.key
  api_management_name = azurerm_api_management.this.name
  resource_group_name = var.resource_group_name
  display_name        = each.key
  value               = each.value
  secret              = true
}

# -----------------------------------------------------------------------------
# 4. Backend pool — primary and failover Azure OpenAI deployments
# -----------------------------------------------------------------------------
resource "azurerm_api_management_backend" "primary" {
  name                = "backend-id-primary"
  resource_group_name = var.resource_group_name
  api_management_name = azurerm_api_management.this.name
  protocol            = "http"
  url                 = var.openai_primary_endpoint

  credentials {
    header = {
      "api-key" = "{{openai-primary-key}}"
    }
  }
}

resource "azurerm_api_management_backend" "failover" {
  name                = "backend-id-failover"
  resource_group_name = var.resource_group_name
  api_management_name = azurerm_api_management.this.name
  protocol            = "http"
  url                 = var.openai_failover_endpoint

  credentials {
    header = {
      "api-key" = "{{openai-failover-key}}"
    }
  }
}

# Backend keys stored as APIM secrets (referenced above as {{openai-primary-key}})
resource "azurerm_api_management_named_value" "openai_keys" {
  for_each = {
    "openai-primary-key"  = var.openai_primary_key
    "openai-failover-key" = var.openai_failover_key
  }
  name                = each.key
  api_management_name = azurerm_api_management.this.name
  resource_group_name = var.resource_group_name
  display_name        = each.key
  value               = each.value
  secret              = true
}

# -----------------------------------------------------------------------------
# 5. API definition (proxy to Azure OpenAI)
# -----------------------------------------------------------------------------
resource "azurerm_api_management_api" "openai" {
  name                  = "openai-api"
  resource_group_name   = var.resource_group_name
  api_management_name   = azurerm_api_management.this.name
  revision              = "1"
  display_name          = "Azure OpenAI Proxy (FinDocs)"
  path                  = "openai"
  protocols             = ["https"]
  service_url           = var.openai_primary_endpoint
  subscription_required = true

  subscription_key_parameter_names {
    header = "Ocp-Apim-Subscription-Key"
    query  = "subscription-key"
  }
}

# -----------------------------------------------------------------------------
# 6. Policy — applied at API level, references all six policy XML files
#
# Order of execution (matches the policy XML structure):
#   inbound:
#     1. global-inbound.xml       (auth, tenant ID resolution, headers)
#     2. tenant-rate-limit.xml    (per-tenant RPM)
#     3. tenant-token-quota.xml   (per-tenant TPM via azure-openai-token-limit)
#     4. content-safety.xml       (analyze user message against severity thresholds)
#     5. backend-failover.xml     (sets backend, configures retry)
#   outbound:
#     6. cost-attribution.xml     (extract token counts, compute cost, log to App Insights)
# -----------------------------------------------------------------------------
locals {
  policy_dir = "${path.module}/policies"

  combined_policy = <<-XML
    <policies>
      <inbound>
        ${file("${local.policy_dir}/global-inbound.xml")}
        ${file("${local.policy_dir}/tenant-rate-limit.xml")}
        ${file("${local.policy_dir}/tenant-token-quota.xml")}
        ${file("${local.policy_dir}/content-safety.xml")}
        ${file("${local.policy_dir}/backend-failover.xml")}
      </inbound>
      <backend>
        <base />
      </backend>
      <outbound>
        ${file("${local.policy_dir}/cost-attribution.xml")}
      </outbound>
      <on-error>
        <base />
      </on-error>
    </policies>
  XML
}

resource "azurerm_api_management_api_policy" "openai" {
  api_name            = azurerm_api_management_api.openai.name
  api_management_name = azurerm_api_management.this.name
  resource_group_name = var.resource_group_name
  xml_content         = local.combined_policy

  depends_on = [
    azurerm_api_management_named_value.static,
    azurerm_api_management_named_value.secrets,
    azurerm_api_management_named_value.openai_keys,
    azurerm_api_management_backend.primary,
    azurerm_api_management_backend.failover,
    azurerm_api_management_logger.ai,
  ]
}

# -----------------------------------------------------------------------------
# 7. Per-tenant subscriptions (one per entry in var.tenants)
#    Subscription key = tenant credential. Tenants pass this as
#    Ocp-Apim-Subscription-Key on every request.
# -----------------------------------------------------------------------------
resource "azurerm_api_management_subscription" "tenant" {
  for_each            = var.tenants
  resource_group_name = var.resource_group_name
  api_management_name = azurerm_api_management.this.name
  api_id              = azurerm_api_management_api.openai.id
  display_name        = "Tenant: ${each.key} (${each.value.tier})"
  state               = "active"
}

# Per-tenant named values that the policies look up:
#   tenant-id-{apim-subscription-id}  -> tenant slug (e.g. "tech")
#   tenant-tier-{tenant-slug}         -> tier ("standard" or "premium")
resource "azurerm_api_management_named_value" "tenant_id_lookup" {
  for_each            = var.tenants
  name                = "tenant-id-${azurerm_api_management_subscription.tenant[each.key].subscription_id}"
  api_management_name = azurerm_api_management.this.name
  resource_group_name = var.resource_group_name
  display_name        = "tenant-id-${azurerm_api_management_subscription.tenant[each.key].subscription_id}"
  value               = each.key
  secret              = false
}

resource "azurerm_api_management_named_value" "tenant_tier" {
  for_each            = var.tenants
  name                = "tenant-tier-${each.key}"
  api_management_name = azurerm_api_management.this.name
  resource_group_name = var.resource_group_name
  display_name        = "tenant-tier-${each.key}"
  value               = each.value.tier
  secret              = false
}
