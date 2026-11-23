#------------------------------------------------------------------------------
# Plan-time standard checks: a failing precondition stops the plan.
#------------------------------------------------------------------------------

resource "terraform_data" "access_group_standard" {
  for_each = local.access_groups
  input    = each.key

  lifecycle {
    precondition {
      condition = each.value.azure_role == null || each.value.role_code != "unknown-role"
      # coalesce() keeps the message evaluable for tenant-scoped groups (azure_role is null); Terraform evaluates error_message even when the condition passes.
      error_message = "${each.key}: Azure RBAC role \"${coalesce(each.value.azure_role, "-")}\" has no role code. Add it to the role code list in naming.tf, or to var.custom_roles."
    }

    precondition {
      condition     = length(each.value.entra_roles) == 0 || each.value.pim.entra_role_assignable
      error_message = "${each.key}: Entra ID roles can only be assigned to role-assignable groups. Set pim = { entra_role_assignable = true }."
    }

    precondition {
      condition     = can(regex("^rbac-[a-z0-9]+(-[a-z0-9]+)*$", each.key))
      error_message = "${each.key}: names use lowercase letters, digits and single hyphens only."
    }

    precondition {
      condition     = length(each.key) <= 64
      error_message = "${each.key} is ${length(each.key)} characters; the limit is 64."
    }

    precondition {
      condition = each.value.scope_ids == null || alltrue([for sid in each.value.scope_ids : !strcontains(sid, "unknown-subscription")])
      # try() keeps the message evaluable for tenant-scoped groups (scope is null); same error_message caveat as above.
      error_message = "${each.key}: subscription \"${coalesce(try(each.value.scope.subscription, null), "-")}\" isn't in var.subscriptions."
    }

    precondition {
      condition     = each.value.scope_ids == null || try(each.value.scope.tenant_root, false) != true || !strcontains(each.value.scope_ids[0], "unknown-tenant")
      error_message = "${each.key}: scope = { tenant_root = true } needs var.tenant_id set to the tenant's ID (the Tenant Root Group's management group ID)."
    }

    precondition {
      condition     = each.value.scope_ids == null || length(each.value.scope_ids) > 0
      error_message = "${each.key}: scope bundle \"${coalesce(try(each.value.scope.bundle, null), "-")}\" isn't in var.scope_bundles."
    }

    precondition {
      condition     = !each.value.pim.enabled || can(regex("^(PT?\\d+[HM]|P\\d+D(T\\d+[HM])?)$", each.value.pim.maximum_duration))
      error_message = "${each.key}: maximum_duration \"${each.value.pim.maximum_duration}\" is not an ISO 8601 duration (e.g. PT4H, P1D)."
    }

    precondition {
      condition     = !each.value.pim.require_approval || each.value.pim.approver_group != null
      error_message = "${each.key}: require_approval is true but no approver_group is set (on the group or in access_group_defaults)."
    }

    precondition {
      condition     = !each.value.pim.entra_role_assignable || each.value.pim.enabled
      error_message = "${each.key}: entra_role_assignable groups cannot take direct (active) membership - Entra blocks group nesting in role-assignable groups. Set pim = { enabled = true } so membership comes via PIM eligibility."
    }
  }
}
