variable "apim_name" {
  description = "Name of the API Management instance. Must be globally unique."
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group containing the APIM instance."
  type        = string
}

variable "location" {
  description = "Azure region for the APIM instance."
  type        = string
  default     = "eastus"
}

variable "sku_name" {
  description = "APIM SKU. Developer_1 for dev, Premium_1 (or higher) for production with VNet support and zone redundancy."
  type        = string
  default     = "Developer_1"
  validation {
    condition = contains(
      ["Developer_1", "Basic_1", "Standard_1", "Standard_2", "Premium_1", "Premium_2", "Premium_4"],
      var.sku_name
    )
    error_message = "sku_name must be a valid APIM SKU. Premium_X is required for production VNet/zone-redundancy features."
  }
}

variable "publisher_email" {
  description = "Email address shown as the API publisher contact."
  type        = string
}

variable "subnet_id" {
  description = "Optional subnet ID for VNet-integrated APIM (Premium tier required)."
  type        = string
  default     = null
}

# -----------------------------------------------------------------------------
# Backend OpenAI configuration
# -----------------------------------------------------------------------------
variable "openai_primary_endpoint" {
  description = "Endpoint URL of the primary Azure OpenAI deployment, e.g. https://findocs-eus.openai.azure.com"
  type        = string
}

variable "openai_primary_key" {
  description = "API key for the primary Azure OpenAI deployment. Stored as APIM secret."
  type        = string
  sensitive   = true
}

variable "openai_failover_endpoint" {
  description = "Endpoint URL of the failover Azure OpenAI deployment (different region)."
  type        = string
}

variable "openai_failover_key" {
  description = "API key for the failover Azure OpenAI deployment. Stored as APIM secret."
  type        = string
  sensitive   = true
}

# -----------------------------------------------------------------------------
# Content Safety
# -----------------------------------------------------------------------------
variable "content_safety_endpoint" {
  description = "Endpoint URL of the Azure AI Content Safety resource."
  type        = string
}

variable "content_safety_key" {
  description = "API key for the Azure AI Content Safety resource. Stored as APIM secret."
  type        = string
  sensitive   = true
}

# -----------------------------------------------------------------------------
# Observability
# -----------------------------------------------------------------------------
variable "application_insights_id" {
  description = "Resource ID of the Application Insights instance receiving cost attribution events."
  type        = string
}

variable "application_insights_instrumentation_key" {
  description = "Instrumentation key for Application Insights."
  type        = string
  sensitive   = true
}

# -----------------------------------------------------------------------------
# Tenants
# -----------------------------------------------------------------------------
variable "tenants" {
  description = <<-EOT
    Map of tenant slug -> configuration. Each tenant gets:
      - An APIM subscription (its credential into the platform)
      - tenant-id-{subscription-id} and tenant-tier-{slug} named values
      - Tier-based rate limit and token quota enforced by policy

    Example:
      tenants = {
        tech = {
          tier = "standard"
        }
        banks = {
          tier = "premium"
        }
        energy = {
          tier = "standard"
        }
      }
  EOT
  type = map(object({
    tier = string
  }))
  default = {
    tech   = { tier = "standard" }
    banks  = { tier = "premium" }
    energy = { tier = "standard" }
  }

  validation {
    condition = alltrue([
      for k, v in var.tenants : contains(["standard", "premium"], v.tier)
    ])
    error_message = "Each tenant tier must be 'standard' or 'premium'."
  }
}

variable "tags" {
  description = "Resource tags applied to APIM."
  type        = map(string)
  default = {
    workload    = "ai-platform"
    component   = "ai-gateway"
    managed_by  = "terraform"
    cost_center = "platform-engineering"
  }
}
