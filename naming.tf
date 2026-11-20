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
    "Management Group Contributor"            = "mgcontributor"
    "Management Group Reader"                 = "mgreader"
    "User Access Administrator"               = "uaa"
    "Role Based Access Control Administrator" = "rbacadmin"
    "Virtual Machine Contributor"             = "vmcontributor"
    "Virtual Machine Administrator Login"     = "vmadminlogin"
    "Virtual Machine User Login"              = "vmuserlogin"
    "Network Contributor"                     = "netcontributor"
    "Key Vault Administrator"                 = "kvadmin"
    "Key Vault Secrets User"                  = "kvsecretsuser"
    "Monitoring Reader"                       = "monreader"
    "Reader and Data Access"                  = "readerdataaccess"
    "Network-Management (alz)"                = "netmgmtalz"
  }

  role_codes = merge(local.builtin_role_codes, { for name, r in var.custom_roles : name => r.code })

  # Pass 1: scope kind. Entra-only groups (no scope) are tenant-scoped.
  _scoped = [
    for g in var.access_groups : merge(g, {
      scope_kind = g.scope == null ? "tenant" : (g.scope.bundle != null ? "bundle" : (g.scope.tenant_root == true ? "tenant-root" : (g.scope.resource_group != null ? "rg" : (g.scope.subscription != null ? "sub" : "mg"))))
    })
  ]

  # Pass 2: name parts and scope IDs. coalesce() keeps the unused map entries null-safe;
  # the outer ternary skips them entirely for tenant-scoped groups, where g.scope is null.
  # Service entries use the service name as the naming token and carry no scope ID.
  # Bundle entries take their scope IDs from var.scope_bundles and use the bundle name
  # as the naming token; an undefined bundle resolves to an empty list, caught by a
  # standard precondition.
  _resolved = [
    for g in local._scoped : merge(g, {
      role_code = g.azure_role != null ? lookup(local.role_codes, g.azure_role, "unknown-role") : null

      scope_token = g.service != null ? g.service : (g.scope == null ? "entra" : {
        bundle      = coalesce(g.scope.bundle, "-")
        tenant-root = "tenant"
        mg          = "mg-${coalesce(g.scope.management_group, "-")}"
        sub         = coalesce(g.scope.subscription, "-")
        rg          = coalesce(g.scope.resource_group, "-")
      }[g.scope_kind])

      scope_ids = g.scope == null ? null : (g.scope.bundle != null ? tolist(toset(lookup(var.scope_bundles, coalesce(g.scope.bundle, "-"), []))) : [{
        tenant-root = "/providers/Microsoft.Management/managementGroups/${coalesce(var.tenant_id, "unknown-tenant")}"
        mg          = "/providers/Microsoft.Management/managementGroups/${coalesce(g.scope.management_group, "-")}"
        sub         = "/subscriptions/${lookup(var.subscriptions, coalesce(g.scope.subscription, "-"), "unknown-subscription")}"
        rg          = "/subscriptions/${lookup(var.subscriptions, coalesce(g.scope.subscription, "-"), "unknown-subscription")}/resourceGroups/${coalesce(g.scope.resource_group, "-")}"
      }[g.scope_kind]])
    })
  ]

  # Pass 3: PIM settings resolved field by field (the group's own pim block wins,
  # unset fields inherit var.access_group_defaults; nothing is inferred from the
  # role), plus the custom role ID. g.pim is null (not an error) when absent, and
  # its unset optional fields are null, so each field checks both before falling
  # back to the default. A for expression over the object would not work here: it
  # unifies all value types to string, turning booleans into "true"/"false".
  _pimmed = [
    for g in local._resolved : merge(g, {
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
  ]

  # Final map, keyed by the derived group name: rbac-<scope token>-<name part>,
  # the name part being the service slug, the Azure role code, or the Entra
  # name_suffix, and a trailing -approval segment when activation requires
  # approval (the PIM policy is per group, so groups that differ only in
  # approval must be named differently). Reserved: the name part itself never
  # is or ends in approval (validated in variables.tf). Two entries that
  # resolve to the same name (same role, same scope, same approval
  # requirement) fail the plan with a duplicate key error.
  access_groups = {
    for g in local._pimmed : "rbac-${g.scope_token}-${g.service != null ? g.service_role : (g.role_code != null ? g.role_code : g.name_suffix)}${g.pim.enabled && g.pim.require_approval ? "-approval" : ""}" => g
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

  # One entry per (access group, scope) pair for Azure RBAC role assignments; a
  # scope bundle fans one role out into one assignment per scope ID. Keys are
  # "<group>|<scope id>" - scope IDs never contain a pipe.
  role_assignment_pairs = {
    for p in flatten([
      for name, g in local.access_groups : g.azure_role != null ? [
        for sid in g.scope_ids : {
          key            = "${name}|${sid}"
          group          = name
          scope_id       = sid
          role_name      = g.azure_role
          custom_role_id = g.custom_role_id
        }
      ] : []
    ]) : p.key => p
  }

  function_groups = toset(flatten([for g in values(local.access_groups) : g.members]))
}
