#------------------------------------------------------------------------------
# Naming rules and PIM settings resolution for the Azure RBAC access standard.
#
# Built from variables only, so it can be planned and tested without Azure
# access.
#------------------------------------------------------------------------------

locals {
  # The standard's role codes. Add new ones here (by PR), never inline in tfvars.
  builtin_role_codes = {
    "Owner"                                   = "owner"
    "Contributor"                             = "contributor"
    "Reader"                                  = "reader"
    "User Access Administrator"               = "uaa"
    "Role Based Access Control Administrator" = "rbacadmin"
    "Virtual Machine Contributor"             = "vmcontributor"
    "Virtual Machine Administrator Login"     = "vmadminlogin"
    "Virtual Machine User Login"              = "vmuserlogin"
    "Network Contributor"                     = "netcontributor"
    "Key Vault Administrator"                 = "kvadmin"
    "Key Vault Secrets User"                  = "kvsecretsuser"
    "Monitoring Reader"                       = "monreader"
  }

  role_codes = merge(local.builtin_role_codes, { for name, r in var.custom_roles : name => r.code })

  # Pass 1: scope kind. Entra-only groups (no scope) are tenant-scoped.
  _scoped = [
    for g in var.access_groups : merge(g, {
      scope_kind = g.scope == null ? "tenant" : (g.scope.resource_group != null ? "rg" : (g.scope.subscription != null ? "sub" : "mg"))
    })
  ]

  # Pass 2: name parts and scope ID. coalesce() keeps the unused map entries null-safe;
  # the outer ternary skips them entirely for tenant-scoped groups, where g.scope is null.
  # Service entries use the service name as the naming token and carry no scope ID.
  _resolved = [
    for g in local._scoped : merge(g, {
      role_code = g.azure_role != null ? lookup(local.role_codes, g.azure_role, "unknown-role") : null

      scope_token = g.service != null ? g.service : (g.scope == null ? "entra" : {
        mg  = "mg-${coalesce(g.scope.management_group, "-")}"
        sub = coalesce(g.scope.subscription, "-")
        rg  = coalesce(g.scope.resource_group, "-")
      }[g.scope_kind])

      scope_id = g.scope == null ? null : {
        mg  = "/providers/Microsoft.Management/managementGroups/${coalesce(g.scope.management_group, "-")}"
        sub = "/subscriptions/${lookup(var.subscriptions, coalesce(g.scope.subscription, "-"), "unknown-subscription")}"
        rg  = "/subscriptions/${lookup(var.subscriptions, coalesce(g.scope.subscription, "-"), "unknown-subscription")}/resourceGroups/${coalesce(g.scope.resource_group, "-")}"
      }[g.scope_kind]
    })
  ]

  # Final map, keyed by the derived group name: rbac-<scope token>-<name part>,
  # the name part being the service slug, the Azure role code, or the Entra
  # name_suffix. Two entries that resolve to the same name (same role, same
  # scope) fail the plan with a duplicate key error.
  # PIM settings are resolved field by field: the group's own pim block wins,
  # unset fields inherit var.access_group_defaults. Nothing is inferred from the role.
  # g.pim is null (not an error) when absent, and its unset optional fields are
  # null, so each field checks both before falling back to the default. A for
  # expression over the object would not work here: it unifies all value types
  # to string, turning booleans into "true"/"false".
  access_groups = {
    for g in local._resolved : "rbac-${g.scope_token}-${g.service != null ? g.service_role : (g.role_code != null ? g.role_code : g.name_suffix)}" => merge(g, {
      pim = {
        enabled                            = g.pim != null && g.pim.enabled != null ? g.pim.enabled : var.access_group_defaults.enabled
        maximum_duration                   = g.pim != null && g.pim.maximum_duration != null ? g.pim.maximum_duration : var.access_group_defaults.maximum_duration
        require_justification              = g.pim != null && g.pim.require_justification != null ? g.pim.require_justification : var.access_group_defaults.require_justification
        require_multifactor_authentication = g.pim != null && g.pim.require_multifactor_authentication != null ? g.pim.require_multifactor_authentication : var.access_group_defaults.require_multifactor_authentication
        require_approval                   = g.pim != null && g.pim.require_approval != null ? g.pim.require_approval : var.access_group_defaults.require_approval
        approver_group                     = g.pim != null && g.pim.approver_group != null ? g.pim.approver_group : var.access_group_defaults.approver_group
        entra_role_assignable              = g.pim != null && g.pim.entra_role_assignable != null ? g.pim.entra_role_assignable : var.access_group_defaults.entra_role_assignable
        active_membership_expire_after     = g.pim != null && g.pim.active_membership_expire_after != null ? g.pim.active_membership_expire_after : var.access_group_defaults.active_membership_expire_after
      }
      custom_role_id = g.azure_role != null ? try(var.custom_roles[g.azure_role].id, null) : null
    })
  }

  # Groups with a PIM policy (eligible membership).
  pim_groups = { for name, g in local.access_groups : name => g if g.pim.enabled }

  # Distinct Entra ID role names actually used; looked up by display name so a typo fails the plan.
  entra_role_names = toset(flatten([for g in values(local.access_groups) : g.entra_roles]))

  # One entry per (access group, Entra ID role) pair.
  entra_role_pairs = {
    for p in flatten([
      for name, g in local.access_groups : [
        for r in g.entra_roles : { key = "${name}|${r}", group = name, role_name = r }
      ]
    ]) : p.key => p
  }

  # Distinct approver groups actually used; looked up by display name. The standard
  # precondition guarantees require_approval implies a non-null approver_group.
  approver_groups = toset([for g in values(local.access_groups) : g.pim.approver_group if g.pim.require_approval && g.pim.approver_group != null])

  # One entry per (access group, function group) pair.
  memberships = {
    for m in flatten([
      for name, g in local.access_groups : [
        for member in g.members : {
          key    = "${name}/${member}"
          group  = name
          member = member
          pim    = g.pim
        }
      ]
    ]) : m.key => m
  }

  function_groups = toset(flatten([for g in values(local.access_groups) : g.members]))
}
