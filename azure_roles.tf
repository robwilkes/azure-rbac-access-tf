#------------------------------------------------------------------------------
# Azure RBAC role assignments: one per (access group, scope) pair; a scope
# bundle fans the same role out to one assignment per scope ID.
#------------------------------------------------------------------------------

resource "azurerm_role_assignment" "access" {
  for_each = local.role_assignment_pairs

  scope                = each.value.scope_id
  role_definition_name = each.value.custom_role_id == null ? each.value.role_name : null
  role_definition_id   = each.value.custom_role_id
  principal_id         = azuread_group.access[each.value.group].object_id
  principal_type       = "Group" # also required if the deploying identity has an ABAC condition on principal type
  description          = "Access group ${each.value.group}"
}
