#------------------------------------------------------------------------------
# No PIM: active membership
#
# For access groups with pim.enabled = false, function groups are added as
# plain active members instead of PIM-eligible ones.
#------------------------------------------------------------------------------

resource "azuread_group_member" "active" {
  for_each = { for k, m in local.memberships : k => m if !m.pim.enabled }

  group_object_id  = azuread_group.access[each.value.group].object_id
  member_object_id = data.azuread_group.function[each.value.member].object_id
}
