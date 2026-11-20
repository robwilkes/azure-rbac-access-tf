terraform {
  required_version = ">= 1.10.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.62"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}

  # Role assignments are made by this subscription's identity; scopes can
  # target any management group or subscription this identity can manage.
  subscription_id = "00000000-0000-0000-0000-000000000000"
}

provider "azuread" {}

module "rbac_access" {
  # Pin to a release tag once published, e.g. ?ref=v0.1.0
  source = "git::https://github.com/robwilkes/azure-rbac-access-tf.git?ref=v0.1.0"

  subscription_id = "00000000-0000-0000-0000-000000000000"

  # Key = the subscription's CAF name, which becomes part of group names.
  subscriptions = {
    "sub-payroll-prod" = "11111111-1111-1111-1111-111111111111"
  }

  # Tenant Root Group scope: its management group ID is the tenant ID, so the
  # module composes the scope from this instead of a GUID in the entry.
  tenant_id = "00000000-0000-0000-0000-000000000000"

  access_group_owners = ["33333333-3333-3333-3333-333333333333"] # platform team deployment SP

  # Baseline for every access group; a group's own pim block overrides field by field.
  access_group_defaults = {
    enabled                            = true
    maximum_duration                   = "PT8H"
    require_justification              = true
    require_multifactor_authentication = true
    require_approval                   = false
    approver_group                     = "fn-approvers" # display name; its members approve when require_approval is on
    entra_role_assignable              = false
    active_membership_expire_after     = "P15D" # acceptable values: "P15D", "P30D", "P90D", "P180D", or "P365D"
  }

  # One entry per access group. Names are derived; PIM settings are explicit, or inherited from the defaults.
  access_groups = [
    # Tenant Root Group: management-plane delegation over the whole Azure estate.
    # scope = { tenant_root = true } takes the scope ID from var.tenant_id, so no GUID in the name.
    {
      azure_role = "Management Group Contributor"
      scope      = { tenant_root = true } # -> rbac-tenant-mgcontributor
      members    = ["fn-platform-leads"]
    },

    # Service desk: central operations, so management group scope
    {
      azure_role = "Virtual Machine Contributor" # inherits defaults: PIM, MFA + justification, 8 h, no approval
      scope      = { management_group = "landingzones" }
      members    = ["fn-helpdesk"]
    },
    {
      azure_role = "Reader" # active membership, no PIM
      scope      = { management_group = "landingzones" }
      members    = ["fn-helpdesk"]
      pim        = { enabled = false }
    },

    # Payroll landing zone (prod)
    {
      azure_role = "Reader"
      scope      = { subscription = "sub-payroll-prod" }
      members    = ["fn-payroll-devs"]
      pim        = { enabled = false }
    },
    {
      azure_role = "Contributor" # inherits defaults (PIM, 8 h); nothing else changes at RG scope
      scope      = { subscription = "sub-payroll-prod", resource_group = "rg-payroll-prod-aue-001" }
      members    = ["fn-payroll-devs"]
    },
    {
      azure_role = "Owner" # short cap, approval and role-assignable group spelled out here, not assumed
      scope      = { subscription = "sub-payroll-prod" }
      members    = ["fn-payroll-admins"]
      pim        = { maximum_duration = "PT4H", require_approval = true, entra_role_assignable = true }
    },
    {
      azure_role = "Key Vault Secrets User" # prod secrets: raised above the defaults by explicit override
      scope      = { subscription = "sub-payroll-prod", resource_group = "rg-payroll-prod-aue-001" }
      members    = ["fn-payroll-devs"]
      pim        = { maximum_duration = "PT4H", require_approval = true, entra_role_assignable = true }
    },

    # Microsoft 365 administration: Entra ID (directory) roles are tenant-wide, so no scope.
    # One activation of the access group grants every listed role at once. Approval is
    # required, so the group is named rbac-entra-microsoft365admin-approval.
    {
      entra_roles = ["Teams Administrator", "License Administrator", "Exchange Administrator"]
      name_suffix = "microsoft365admin"
      members     = ["fn-microsoft365-admins"]
      pim         = { require_approval = true, approver_group = "fn-approvers", entra_role_assignable = true }
    },

    # Security Administrator: the PIM policy lives on the group, so fn-groups with
    # different approval requirements cannot share one access group. Same role, two
    # groups; the name carries the -approval flag.
    {
      entra_roles = ["Security Administrator"]
      name_suffix = "securityadmin"
      members     = ["fn-platform-leads"]
      pim         = { entra_role_assignable = true } # rbac-entra-securityadmin
    },
    {
      entra_roles = ["Security Administrator"]
      name_suffix = "securityadmin"
      members     = ["fn-security-admins"]
      pim         = { require_approval = true, entra_role_assignable = true } # rbac-entra-securityadmin-approval, approvers inherited from defaults
    },

    # Intune Helpdesk Operator: the group and its PIM eligibility are managed here;
    # the Intune admin binds the built-in role to this group in the Intune portal.
    {
      service      = "intune"
      service_role = "helpdeskoperator"
      members      = ["fn-helpdesk"]
    },
  ]
}

output "access_groups" {
  value       = module.rbac_access.access_groups
  description = "What each access group grants, with its resolved PIM settings - the input for access reviews and audit reporting."
}
