#------------------------------------------------------------------------------
# Groups looked up, not created: fn- function groups (owned by AD sync; must
# exist before the plan) and approver groups (resolved by display name only
# when a group actually requires approval).
#------------------------------------------------------------------------------

data "azuread_group" "function" {
  for_each         = local.function_groups
  display_name     = each.value
  security_enabled = true
}

data "azuread_group" "approvers" {
  for_each         = local.approver_groups
  display_name     = each.value
  security_enabled = true
}
