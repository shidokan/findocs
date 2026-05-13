output "apim_id" {
  description = "Resource ID of the API Management instance."
  value       = azurerm_api_management.this.id
}

output "apim_gateway_url" {
  description = "Public gateway URL. Tenants make requests to {gateway_url}/openai/..."
  value       = azurerm_api_management.this.gateway_url
}

output "apim_principal_id" {
  description = "Principal ID of the system-assigned managed identity. Grant this Cognitive Services OpenAI User on the Foundry resource."
  value       = azurerm_api_management.this.identity[0].principal_id
}

output "tenant_subscriptions" {
  description = "Map of tenant slug -> APIM subscription primary key. Distribute these to tenants as their gateway credential."
  value = {
    for slug, _ in var.tenants : slug => azurerm_api_management_subscription.tenant[slug].primary_key
  }
  sensitive = true
}

output "tenant_subscription_ids" {
  description = "Map of tenant slug -> APIM subscription resource ID (not the key). Useful for cross-referencing in Log Analytics."
  value = {
    for slug, _ in var.tenants : slug => azurerm_api_management_subscription.tenant[slug].subscription_id
  }
}
