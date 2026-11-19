#------------------------------------------------------------------------------
# Azure RBAC role assignments
#
# One assignment per access group that carries an Azure RBAC role, at the
# scope the entry resolved to (management group, subscription or resource
# group).
#------------------------------------------------------------------------------

resource "azurerm_role_assignment" "access" {
  for_each = { for name, g in local.access_groups : name => g if g.azure_role != null }

  scope                = each.value.scope_id
  role_definition_name = each.value.custom_role_id == null ? each.value.azure_role : null
  role_definition_id   = each.value.custom_role_id
  principal_id         = azuread_group.access[each.key].object_id
  principal_type       = "Group" # also required if the deploying identity is limited by an ABAC condition on principal type
  description          = "Access group ${each.key}"
}
