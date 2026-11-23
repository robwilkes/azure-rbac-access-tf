#------------------------------------------------------------------------------
# What was created: the access groups, and how each Entra role name resolved
#------------------------------------------------------------------------------

output "access_groups" {
  value = {
    for name, g in local.access_groups : name => {
      object_id    = azuread_group.access[name].object_id
      azure_role   = g.azure_role
      entra_roles  = g.entra_roles
      service      = g.service
      service_role = g.service_role
      scope_ids    = g.scope_ids
      members      = g.members
      pim          = g.pim
    }
  }
  description = "Access groups managed here and what each one grants, including the resolved PIM settings."
}

output "entra_roles" {
  value = {
    for name in local.entra_role_names : name => {
      id     = try(local.entra_role_ids[lower(trimspace(name))], null)
      source = try(local.entra_role_sources[lower(trimspace(name))], null)
    }
  }
  description = "How each requested Entra ID role display name resolved to a role ID: the id plus its source - pinned (var.entra_custom_role_ids), template (built-in role, activated or not), or instance (activated directory role). A null id means the name was not found; the plan fails before applying."
}
