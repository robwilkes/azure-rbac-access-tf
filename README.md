# terraform-azurerm-rbac-access

This module implements the Azure RBAC access standard: cloud-only `rbac-` access groups, each holding either one Azure RBAC role at one scope or Microsoft Entra ID roles tenant-wide, with AD-synced `fn-` function groups as members (eligible through PIM for Groups, or active when PIM is switched off for a group).

It creates:

- A cloud-only security group (`rbac-*`) per access entry, named after what it grants.
- Azure RBAC role assignments at management group, subscription, or resource group scope.
- Tenant-wide Microsoft Entra ID (directory) role assignments for Entra-only access groups.
- PIM for Groups activation policies (duration, MFA, justification, approval) on access groups with PIM enabled.
- Permanent eligibility schedules linking the `fn-` function groups into PIM-enabled access groups, or active `azuread_group_member` links when PIM is off.
- Plan-time standard checks that stop the plan on configuration that breaks the naming, scoping, or PIM rules.

## What this module is for

Use this module to grant human access to Azure and Entra ID through the standard pattern: users are never added to role assignments or cloud groups directly. Access flows `user → fn- function group (AD-synced) → rbac- access group (cloud-only) → role at a scope`, with PIM for Groups gating activation. Each `access_groups` entry grants either one Azure RBAC role at one scope, or a set of Microsoft Entra ID roles tenant-wide.

## Prerequisites

Before using this module, ensure that:

- the `fn-` function groups already exist in Entra ID — they are owned by AD sync and only looked up here,
- you have the subscription ID of every subscription referenced by a scope, keyed by its CAF name (the key becomes part of the group name),
- you have the object IDs of the platform team principals that will own the access groups (users or service principals only: groups can't own groups),
- you have agreed a PIM baseline for `access_group_defaults`.

The module does not create the function groups, management groups, access reviews, or break-glass accounts.

## Usage

```hcl
module "rbac_access" {
  source = "git::https://github.com/robwilkes/azure-rbac-access-tf.git?ref=v0.1.0"

  subscription_id     = "00000000-0000-0000-0000-000000000000"
  subscriptions       = { "sub-payroll-prod" = "11111111-1111-1111-1111-111111111111" }
  access_group_owners = ["33333333-3333-3333-3333-333333333333"]

  access_group_defaults = {
    enabled                        = true
    maximum_duration               = "PT8H"
    require_justification          = true
    require_multifactor_authentication = true
    require_approval               = false
    approver_group                 = "fn-approvers"
    entra_role_assignable          = false
    active_membership_expire_after = "P15D"
  }

  access_groups = [
    {
      azure_role = "Virtual Machine Contributor"
      scope      = { management_group = "landingzones" }
      members    = ["fn-helpdesk"]
    },
  ]
}
```

A complete root module example is available in the examples/basic directory.

## Adding access

Add one entry to `access_groups` in your tfvars. An entry grants either one Azure RBAC role at one scope:

```hcl
{
  azure_role = "Virtual Machine Contributor"
  scope      = { management_group = "landingzones" }
  members    = ["fn-helpdesk"]
}
```

or Microsoft Entra ID (directory) roles, which are tenant-wide and take no scope:

```hcl
{
  entra_roles = ["Teams Administrator", "License Administrator", "Exchange Administrator"]
  name_suffix = "microsoft365admin" # the group is named rbac-entra-microsoft365admin
  members     = ["fn-microsoft365-admins"]
  pim         = { entra_role_assignable = true } # required: Entra roles can only be assigned to role-assignable groups
}
```

Azure RBAC group names are derived from the role code (`rbac-mg-landingzones-vmcontributor`); scope is `management_group`, `subscription`, or `subscription` + `resource_group`. Entra-only groups need an explicit `name_suffix` instead, and one activation of such a group grants every listed role at once. Every PIM setting is explicit: set it on the entry's `pim` block, or leave it to `access_group_defaults` — nothing is inferred from the role name.

## Key inputs

| Input                 | Description                                                                        |
| --------------------- | ------------------------------------------------------------------------------------ |
| subscription_id       | Subscription the azurerm provider signs in to (documentation of intent).           |
| subscriptions         | Subscription CAF name => subscription ID, used to build scopes and group names.    |
| access_group_owners   | Object IDs of the principals that own every access group.                          |
| access_group_defaults | Baseline PIM settings; a group's own `pim` block overrides field by field.         |
| access_groups         | One entry per access group: role or Entra roles, scope, members, PIM overrides.    |
| custom_roles          | Custom role name => `{ code, id }` for roles outside the built-in role code list.  |

## PIM settings

Each setting maps 1:1 to an Entra attribute. A group's `pim` block overrides `access_group_defaults` field by field; unset fields inherit the default. The resolved settings appear in the `access_groups` output, so what a group actually gets is always inspectable.

| Setting                          | Default   | Meaning (Entra attribute)                                                                                                                                          |
| -------------------------------- | --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `enabled`                        | `true`    | PIM for Groups policy on the access group. `false` = plain active membership, no policy                                                                              |
| `maximum_duration`               | `"PT8H"`  | `activation_rules.maximum_duration`, ISO 8601 (e.g. `"PT4H"`)                                                                                                      |
| `require_justification`          | `true`    | `activation_rules.require_justification`                                                                                                                           |
| `require_multifactor_authentication` | `true` | `activation_rules.require_multifactor_authentication`                                                                                                              |
| `require_approval`               | `false`   | `activation_rules.require_approval`; needs an `approver_group`                                                                                                     |
| `approver_group`                 | `null`    | display name of the group whose members approve (`approval_stage.primary_approver`)                                                                                |
| `entra_role_assignable`          | `false`   | `azuread_group.assignable_to_role`: lets this group hold **Microsoft Entra ID (directory) roles** — Azure RBAC roles work on any security group. Immutable, max 500 per tenant; changing it recreates the group |
| `active_membership_expire_after` | `"P15D"`  | `active_assignment_rules.expire_after`, caps hand-added active membership; `null` = no cap                                                                         |

Eligibility schedules created here are permanent (`permanent_assignment = true`); access reviews do the pruning.

Examples:

```hcl
# Inherits every default (PIM, MFA + justification, 8 h, no approval)
{ azure_role = "Virtual Machine Contributor", scope = { management_group = "landingzones" }, members = ["fn-helpdesk"] }

# Read-only access: active membership, no PIM at all
{ azure_role = "Reader", scope = { subscription = "sub-payroll-prod" }, members = ["fn-payroll-devs"], pim = { enabled = false } }

# Prod secrets: short cap, approval, role-assignable group — spelled out, not assumed
{
  azure_role = "Key Vault Secrets User"
  scope      = { subscription = "sub-payroll-prod", resource_group = "rg-payroll-prod-aue-001" }
  members    = ["fn-payroll-devs"]
  pim        = { maximum_duration = "PT4H", require_approval = true, entra_role_assignable = true }
}

# Microsoft 365 administration: Entra ID roles are tenant-wide, no scope
{
  entra_roles = ["Teams Administrator", "License Administrator", "Exchange Administrator"]
  name_suffix = "microsoft365admin"
  members     = ["fn-microsoft365-admins"]
  pim         = { require_approval = true, approver_group = "fn-approvers", entra_role_assignable = true }
}
```

## Outputs

- access_groups — the access groups managed here and what each one grants (object ID, role(s), scope, members, resolved PIM settings). Useful for access reviews, audit reporting, and handing group object IDs to other teams.

## Deployment permissions

Deploying this module requires the appropriate Azure RBAC and Microsoft Entra permissions:

- Microsoft Graph application permissions: `Group.ReadWrite.All`, `RoleManagement.ReadWrite.Directory` (for role-assignable groups and Entra ID role assignment), `RoleManagementPolicy.ReadWrite.AzureADGroup`, `PrivilegedEligibilitySchedule.ReadWrite.AzureADGroup`
- The identity must be Privileged Role Administrator (or Global Administrator) to create and manage role-assignable groups.
- Azure: Role Based Access Control Administrator, conditioned to group principals, at the top management group the scopes sit under.

## Plan-time validation

The plan fails on:

- Setting both `azure_role` and `entra_roles`, or neither
- An Entra-only group without `name_suffix`, or a `name_suffix` on an Azure RBAC group
- A scope mismatch: `azure_role` without a scope, or `entra_roles` with one
- Entra ID roles on a group whose resolved settings don't have `entra_role_assignable = true`
- An Azure RBAC role with no role code (add it to `naming.tf` or `custom_roles`)
- An invalid `maximum_duration` (ISO 8601 like `PT4H`/`P1D`) when PIM is enabled
- `require_approval = true` without an `approver_group` (on the group or in `access_group_defaults`)
- A subscription missing from `var.subscriptions`
- Members that aren't `fn-` groups
- Two entries that resolve to the same group name (same role and scope)
- Names over 64 characters or not lowercase

`naming.tf`, `standard.tf` and `variables.tf` need no Azure access, so they can be checked in CI.

## Implementation notes

- A change to an entry's role or scope changes the group name, so Terraform replaces the group. This is intended, because the name describes what the group grants.
- Flipping `entra_role_assignable` recreates the group, because it can't be changed in place.
- One state per landing zone (plus one for platform-wide groups) keeps changes contained. The code is the same in each; only the tfvars differ.
- Not included: alerting on direct user assignments, access reviews, break-glass accounts.

## Repository layout

| File              | Contents                                                              |
| ----------------- | ------------------------------------------------------------------------ |
| `terraform.tf`    | Terraform and provider version constraints                            |
| `main.tf`         | Function-group and approver-group lookups (owned by AD)               |
| `naming.tf`       | Role codes, naming and PIM settings resolution (locals only)          |
| `standard.tf`     | Plan-time standard checks                                             |
| `groups.tf`       | The `rbac-` access groups                                             |
| `azure_roles.tf`  | Azure RBAC role assignments                                           |
| `entra_roles.tf`  | Tenant-wide Entra ID (directory) role assignments                     |
| `pim.tf`          | PIM activation policies and eligibility schedules                     |
| `members.tf`      | Active membership for groups with PIM switched off                    |
| `variables.tf`    | Inputs and input validation                                           |
| `outputs.tf`      | `access_groups` output                                                |
| `examples/basic/` | Complete root module example (service desk and payroll)               |
