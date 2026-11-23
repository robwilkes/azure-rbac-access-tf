#------------------------------------------------------------------------------
# Entra ID (directory) roles: tenant-wide
#
# Display names are matched case-insensitively and trimmed against three
# sources, last match wins:
#
#   1. /directoryRoles - activated instances; old-API custom roles assign by
#      instance object ID. Not filtered on template_id (cloned custom roles
#      keep their source's template ID and would be dropped).
#   2. /directoryRoleTemplates - every built-in, activated or not. Assignments
#      take a built-in's *template* ID, so the template wins over an activated
#      instance, and unactivated built-ins still resolve.
#   3. var.entra_custom_role_ids - pins for custom roles created via the
#      unified role management API (GET /roleManagement/directory/
#      roleDefinitions), which never appear in either list above.
#------------------------------------------------------------------------------

data "azuread_directory_roles" "all" {
  count = length(local.entra_role_names) > 0 ? 1 : 0
}

data "azuread_directory_role_templates" "all" {
  count = length(local.entra_role_names) > 0 ? 1 : 0
}

locals {
  # Normalised display name => object ID of activated role instances.
  entra_instance_role_ids = {
    for r in(length(data.azuread_directory_roles.all) > 0 ? data.azuread_directory_roles.all[0].roles : []) : lower(trimspace(r.display_name)) => r.object_id
  }

  # Normalised display name => template ID of built-in roles.
  entra_template_role_ids = {
    for t in(length(data.azuread_directory_role_templates.all) > 0 ? data.azuread_directory_role_templates.all[0].role_templates : []) : lower(trimspace(t.display_name)) => t.object_id
  }

  # Normalised display name => pinned role definition ID.
  entra_pinned_role_ids = {
    for name, id in var.entra_custom_role_ids : lower(trimspace(name)) => id
  }

  # Merged lookup used by the assignment resource: pins > templates > instances.
  entra_role_ids = merge(
    local.entra_instance_role_ids,
    local.entra_template_role_ids,
    local.entra_pinned_role_ids,
  )

  # Normalised display name => resolving source ("pinned", "template" or
  # "instance"); same merge priority as entra_role_ids, so the two maps cannot
  # disagree. Surfaced by the entra_roles output for plan-time inspection.
  entra_role_sources = merge(
    { for name in keys(local.entra_instance_role_ids) : name => "instance" },
    { for name in keys(local.entra_template_role_ids) : name => "template" },
    { for name in keys(local.entra_pinned_role_ids) : name => "pinned" },
  )
}

resource "azuread_directory_role_assignment" "entra" {
  for_each = local.entra_role_pairs

  principal_object_id = azuread_group.access[each.value.group].object_id
  role_id             = try(local.entra_role_ids[each.value.role_key], null) # precondition below fails the plan with a clear message when this is null

  lifecycle {
    precondition {
      condition     = try(local.entra_role_ids[each.value.role_key], null) != null
      error_message = "${each.value.group}: Entra ID role \"${each.value.role_name}\" was not found in the tenant (checked built-in role templates and activated directory roles, case-insensitively). Check the display name; for a custom role created via the unified role management API, pin its ID in var.entra_custom_role_ids - find it at GET /roleManagement/directory/roleDefinitions or in the portal URL of the role."
    }
  }
}
