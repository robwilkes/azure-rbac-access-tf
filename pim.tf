#------------------------------------------------------------------------------
# PIM for Groups: the activation policy on each PIM-enabled access group,
# plus the permanent eligibility schedules that link function groups in.
#------------------------------------------------------------------------------

resource "azuread_group_role_management_policy" "member" {
  for_each = local.pim_groups

  group_id = azuread_group.access[each.key].object_id
  role_id  = "member"

  activation_rules {
    maximum_duration                   = each.value.pim.maximum_duration
    require_justification              = each.value.pim.require_justification
    require_multifactor_authentication = each.value.pim.require_multifactor_authentication
    require_approval                   = each.value.pim.require_approval

    dynamic "approval_stage" {
      for_each = each.value.pim.require_approval ? [1] : []
      content {
        primary_approver {
          object_id = data.azuread_group.approvers[each.value.pim.approver_group].object_id
          type      = "groupMembers"
        }
      }
    }
  }

  # Function groups stay eligible; access reviews do the pruning.
  eligible_assignment_rules {
    expiration_required = false
  }

  # Caps active membership added by hand outside Terraform; omitted when null.
  dynamic "active_assignment_rules" {
    for_each = each.value.pim.active_membership_expire_after == null ? [] : [1]
    content {
      expire_after = each.value.pim.active_membership_expire_after
    }
  }
}

resource "azuread_privileged_access_group_eligibility_schedule" "member" {
  for_each = { for k, m in local.memberships : k => m if m.pim.enabled }

  group_id             = azuread_group.access[each.value.group].object_id
  principal_id         = data.azuread_group.function[each.value.member].object_id
  assignment_type      = "member"
  permanent_assignment = true
  justification        = "Function group eligibility managed by Terraform"

  depends_on = [azuread_group_role_management_policy.member]
}
