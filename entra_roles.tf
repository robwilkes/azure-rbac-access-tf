#------------------------------------------------------------------------------
# Entra ID (directory) roles: tenant-wide
#
# The provider has no by-name lookup; it lists every directory role, so we
# match on display name.
#------------------------------------------------------------------------------

data "azuread_directory_roles" "all" {
  count = length(local.entra_role_names) > 0 ? 1 : 0
}

locals {
  # display name => object id for the Entra ID roles used by this configuration.
  entra_role_ids = {
    for r in(length(data.azuread_directory_roles.all) > 0 ? data.azuread_directory_roles.all[0].roles : []) : r.display_name => r.object_id
  }
}

resource "azuread_directory_role_assignment" "entra" {
  for_each = local.entra_role_pairs

  principal_object_id = azuread_group.access[each.value.group].object_id
  role_id             = try(local.entra_role_ids[each.value.role_name], null) # precondition below fails the plan with a clear message when this is null

  lifecycle {
    precondition {
      condition     = try(local.entra_role_ids[each.value.role_name], null) != null
      error_message = "${each.value.group}: Entra ID role \"${each.value.role_name}\" was not found in the tenant; check the display name (e.g. \"Teams Administrator\")."
    }
  }
}
