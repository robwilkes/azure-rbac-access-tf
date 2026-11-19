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
}

#------------------------------------------------------------------------------
# Access groups
#------------------------------------------------------------------------------

variable "access_groups" {
  type = list(object({
    azure_role  = optional(string)           # display name of an Azure RBAC role; needs scope
    entra_roles = optional(list(string), []) # display names of Microsoft Entra ID (directory) roles; tenant-wide
    name_suffix = optional(string)           # explicit slug for the derived name, e.g. "microsoft365admin"; only when azure_role is null
    scope = optional(object({
      management_group = optional(string)
      subscription     = optional(string) # key in var.subscriptions
      resource_group   = optional(string) # needs subscription
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
  description = "One entry per access group and the function groups that get it: either one Azure RBAC role at one scope (azure_role + scope), or Microsoft Entra ID roles tenant-wide (entra_roles + name_suffix). Group names are derived; PIM settings come from this entry's pim block, falling back to var.access_group_defaults field by field."

  validation {
    condition     = alltrue([for g in var.access_groups : (g.azure_role != null) != (length(g.entra_roles) > 0)])
    error_message = "Each access group sets exactly one of azure_role (with a scope) or entra_roles (tenant-wide), not both and not neither."
  }

  validation {
    condition     = alltrue([for g in var.access_groups : g.azure_role != null || g.name_suffix != null])
    error_message = "Entra-only access groups need name_suffix, e.g. name_suffix = \"microsoft365admin\"; the group is named rbac-entra-<name_suffix>."
  }

  validation {
    condition     = alltrue([for g in var.access_groups : g.azure_role == null || g.name_suffix == null])
    error_message = "name_suffix is only used when azure_role is null; Azure RBAC group names are derived from the role code."
  }

  validation {
    condition     = alltrue([for g in var.access_groups : (g.azure_role != null) == (g.scope != null)])
    error_message = "azure_role entries need a scope (management_group or subscription); entra_roles are tenant-wide and take no scope."
  }

  validation {
    condition     = alltrue([for g in var.access_groups : g.scope == null || (g.scope.management_group != null) != (g.scope.subscription != null)])
    error_message = "Each scope sets either management_group or subscription (plus an optional resource_group), not both."
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
