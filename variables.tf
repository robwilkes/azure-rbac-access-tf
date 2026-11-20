#------------------------------------------------------------------------------
# Subscription and scope
#------------------------------------------------------------------------------

variable "subscription_id" {
  type        = string
  description = "Subscription the azurerm provider signs in to. Role assignments use full scope IDs, so they can target any management group or subscription this identity can manage."
}

variable "subscriptions" {
  type        = map(string)
  description = "Subscription CAF name (as used in group names, e.g. sub-payroll-prod) => subscription ID."
}

variable "tenant_id" {
  type        = string
  default     = null
  description = "The Entra tenant ID. Required by entries with scope = { tenant_root = true }: the Tenant Root Group's management group ID is the tenant ID."

  validation {
    condition     = var.tenant_id == null || can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.tenant_id))
    error_message = "tenant_id must be a GUID, e.g. \"dafd8e97-d9be-460b-bc05-7ce7b13a1113\"."
  }
}

#------------------------------------------------------------------------------
# Access group ownership and PIM defaults
#------------------------------------------------------------------------------

variable "access_group_owners" {
  type        = list(string)
  description = "Object IDs of the platform team principals that own every access group. Users or service principals only: groups can't own groups."
}

variable "access_group_defaults" {
  type = object({
    enabled                            = bool   # true: PIM policy + eligible membership; false: active membership, no PIM
    maximum_duration                   = string # ISO 8601 activation cap, e.g. "PT4H"
    require_justification              = bool
    require_multifactor_authentication = bool
    require_approval                   = bool   # needs approver_group (here or per group) when true
    approver_group                     = string # display name of the group whose members approve; null when unused
    entra_role_assignable              = bool   # azuread_group.assignable_to_role: gates Microsoft Entra ID (directory) role assignment to this group only - Azure RBAC roles work on any security group. Changing it recreates the group
    active_membership_expire_after     = string # ISO 8601 cap on hand-added active membership, e.g. "P15D"; null = no cap
  })
  description = "Baseline PIM settings for every access group. A group's own pim block overrides any field here, field by field; the resolved settings appear in the access_groups output. Nothing is derived from role names."
}

#------------------------------------------------------------------------------
# Custom roles
#------------------------------------------------------------------------------

variable "custom_roles" {
  type = map(object({
    code = string
    id   = string
  }))
  default     = {}
  description = "Custom role name => { code, id }. Codes start with cr-. The id must be the role definition ID valid at the scopes it's assigned."

  validation {
    condition     = alltrue([for r in values(var.custom_roles) : startswith(r.code, "cr-")])
    error_message = "Custom role codes must start with cr-."
  }

  validation {
    condition     = alltrue([for r in values(var.custom_roles) : !can(regex("(^|-)approval$", r.code))])
    error_message = "Custom role codes must not be or end in approval; the -approval name segment is reserved for approval-gated access groups."
  }
}

#------------------------------------------------------------------------------
# Scope bundles
#------------------------------------------------------------------------------

variable "scope_bundles" {
  type        = map(list(string))
  default     = {}
  description = "Bundle name => absolute Azure scope IDs that share one role (e.g. the VM, NIC, vNet and bastion host that all need Reader for Bastion RDP). Referenced as scope = { bundle = \"<name>\" }; the bundle name is the scope token in the group name rbac-<bundle>-<role code>."

  validation {
    condition     = alltrue([for name, ids in var.scope_bundles : can(regex("^[a-z0-9]+(-[a-z0-9]+)*$", name)) && length(ids) > 0])
    error_message = "Scope bundle names are lowercase slugs (letters, digits, single hyphens), and each bundle lists at least one scope ID."
  }

  validation {
    condition     = alltrue(flatten([for ids in values(var.scope_bundles) : [for id in ids : can(regex("^/[^ ]+[^ /]$", id))]]))
    error_message = "Scope bundle IDs must be absolute (start with /), contain no spaces, and not end with /."
  }
}

#------------------------------------------------------------------------------
# Access groups
#------------------------------------------------------------------------------

variable "access_groups" {
  type = list(object({
    azure_role   = optional(string)           # display name of an Azure RBAC role; needs scope
    entra_roles  = optional(list(string), []) # display names of Microsoft Entra ID (directory) roles; tenant-wide
    name_suffix  = optional(string)           # explicit slug for the derived name, e.g. "microsoft365admin"; entra_roles entries only
    service      = optional(string)           # naming token for a role assigned inside another service (e.g. "intune"); no scope
    service_role = optional(string)           # role slug inside that service (e.g. "helpdeskoperator"); group is named rbac-<service>-<service_role>; this module never assigns that role
    scope = optional(object({
      management_group = optional(string)
      subscription     = optional(string) # key in var.subscriptions
      resource_group   = optional(string) # needs subscription
      tenant_root      = optional(bool)   # true: the Tenant Root Group; needs var.tenant_id; the GUID never enters the group name
      bundle           = optional(string) # key in var.scope_bundles: one role across many scopes; the bundle name is the naming token
    }))
    members = list(string) # function groups (fn-*)
    pim = optional(object({
      enabled                            = optional(bool)
      maximum_duration                   = optional(string)
      require_justification              = optional(bool)
      require_multifactor_authentication = optional(bool)
      require_approval                   = optional(bool)
      approver_group                     = optional(string)
      entra_role_assignable              = optional(bool)
      active_membership_expire_after     = optional(string)
    })) # unset fields inherit var.access_group_defaults
  }))
  description = "One entry per access group and the function groups that get it: one Azure RBAC role at one scope (azure_role + scope), Microsoft Entra ID roles tenant-wide (entra_roles + name_suffix), or a role assigned inside another service (service + service_role) - the group and its PIM setup are created here, the service-side role binding is done by that service's admins. Group names are derived, gaining a trailing -approval when activation requires approval; PIM settings come from this entry's pim block, falling back to var.access_group_defaults field by field."

  validation {
    condition     = alltrue([for g in var.access_groups : (g.azure_role != null ? 1 : 0) + (length(g.entra_roles) > 0 ? 1 : 0) + (g.service != null ? 1 : 0) == 1])
    error_message = "Each access group sets exactly one of azure_role (with a scope), entra_roles (tenant-wide), or service + service_role (service-managed role), not several and not none."
  }

  validation {
    condition = alltrue([
      for g in var.access_groups : g.service == null || (
        g.service_role != null
        && can(regex("^[a-z0-9]+(-[a-z0-9]+)*$", g.service))
        && can(regex("^[a-z0-9]+(-[a-z0-9]+)*$", g.service_role))
      )
    ])
    error_message = "Service entries set both service and service_role, each lowercase letters, digits and single hyphens (e.g. service = \"intune\", service_role = \"helpdeskoperator\")."
  }

  validation {
    condition     = alltrue([for g in var.access_groups : g.azure_role != null || g.service != null || g.name_suffix != null])
    error_message = "Entra-only access groups need name_suffix, e.g. name_suffix = \"microsoft365admin\"; the group is named rbac-entra-<name_suffix>."
  }

  validation {
    condition     = alltrue([for g in var.access_groups : g.name_suffix == null || (g.azure_role == null && g.service == null)])
    error_message = "name_suffix is only used by entra_roles entries; Azure RBAC names are derived from the role code, service names from service + service_role."
  }

  validation {
    condition = alltrue([
      for g in var.access_groups : (
        (g.name_suffix == null || !can(regex("(^|-)approval$", g.name_suffix)))
        && (g.service_role == null || !can(regex("(^|-)approval$", g.service_role)))
      )
    ])
    error_message = "name_suffix and service_role must not be or end in approval: the -approval name segment is reserved for groups whose activation requires approval."
  }

  validation {
    condition     = alltrue([for g in var.access_groups : (g.azure_role != null) == (g.scope != null)])
    error_message = "azure_role entries need a scope (management_group or subscription); entra_roles and service entries take no scope."
  }

  validation {
    condition     = alltrue([for g in var.access_groups : g.scope == null || (g.scope.management_group != null ? 1 : 0) + (g.scope.subscription != null ? 1 : 0) + (g.scope.tenant_root == true ? 1 : 0) + (g.scope.bundle != null ? 1 : 0) == 1])
    error_message = "Each scope sets exactly one of management_group, subscription (plus an optional resource_group), tenant_root = true, or bundle (a key of var.scope_bundles)."
  }

  validation {
    condition     = alltrue([for g in var.access_groups : g.scope == null || g.scope.tenant_root == null || g.scope.tenant_root])
    error_message = "scope.tenant_root is set to true or left out: omit the attribute for management_group and subscription scopes."
  }

  validation {
    condition     = alltrue([for g in var.access_groups : g.scope == null || g.scope.resource_group == null || g.scope.subscription != null])
    error_message = "A resource_group scope also needs its subscription."
  }

  # If you adopt "reuse existing single-purpose AD groups", relax this prefix check.
  validation {
    condition     = alltrue([for g in var.access_groups : length(g.members) > 0 && alltrue([for m in g.members : startswith(m, "fn-")])])
    error_message = "Members must be function groups (fn-*), at least one per access group. Users are never added directly."
  }
}
