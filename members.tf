#------------------------------------------------------------------------------
# Access groups with pim.enabled = false: plain active membership instead of
# PIM eligibility.
#------------------------------------------------------------------------------

resource "azuread_group_member" "active" {
  for_each = { for k, m in local.memberships : k => m if !m.pim.enabled }

  group_object_id  = azuread_group.access[each.value.group].object_id
  member_object_id = data.azuread_group.function[each.value.member].object_id
}
