#------------------------------------------------------------------------------
# Access groups: what was created and what each group grants
#------------------------------------------------------------------------------

output "access_groups" {
  value = {
    for name, g in local.access_groups : name => {
      object_id   = azuread_group.access[name].object_id
      azure_role  = g.azure_role
      entra_roles = g.entra_roles
      scope       = g.scope_id
      members     = g.members
      pim         = g.pim
    }
  }
  description = "Access groups managed here and what each one grants, including the resolved PIM settings."
}
