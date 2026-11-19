#------------------------------------------------------------------------------
# Function groups: owned by AD, looked up only
#
# Function groups (fn-*) are synced from AD and must exist before the plan.
# Approver groups are looked up by display name, only when a group actually
# requires approval.
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
