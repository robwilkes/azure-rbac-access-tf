#------------------------------------------------------------------------------
# Access groups: cloud-only. One Azure RBAC role at one scope or bundle,
# Entra ID roles tenant-wide, or a role bound inside another service (outside
# Terraform).
#------------------------------------------------------------------------------

resource "azuread_group" "access" {
  for_each = local.access_groups

  display_name            = each.key
  description             = "Grants ${each.value.service != null ? "${each.value.service} role \"${each.value.service_role}\" (this group is bound to the role in ${each.value.service}, outside Terraform)" : each.value.azure_role != null ? each.value.azure_role : "Microsoft Entra ID roles (${join(", ", each.value.entra_roles)})"}${each.value.service != null ? "" : each.value.scope_ids == null ? ", tenant-wide" : (each.value.scope.bundle != null ? " across ${length(each.value.scope_ids)} scopes in bundle \"${each.value.scope.bundle}\"" : " on ${each.value.scope_ids[0]}")}. ${each.value.pim.enabled ? "PIM: max activation ${each.value.pim.maximum_duration}${each.value.pim.require_approval ? ", approval required" : ""}." : "Active membership, no PIM."}"
  security_enabled        = true
  assignable_to_role      = each.value.pim.entra_role_assignable # changing it recreates the group
  owners                  = var.access_group_owners
  prevent_duplicate_names = true

  # No `members` here: PIM and azuread_group_member own membership.

  depends_on = [terraform_data.access_group_standard]
}
