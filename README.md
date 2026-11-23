# terraform-azurerm-rbac-access

This module implements the Azure RBAC access standard: cloud-only `rbac-` access groups, each holding one Azure RBAC role at one scope, Microsoft Entra ID roles tenant-wide, or a role assigned inside another service (Intune and similar), with AD-synced `fn-` function groups as members (eligible through PIM for Groups, or active when PIM is switched off for a group).

It creates:

- A cloud-only security group (`rbac-*`) per access entry, named after what it grants, with an `-approval` segment in the name when activation requires approval.
- Azure RBAC role assignments at management group (including the Tenant Root Group), subscription, or resource group scope — one assignment per scope, so a `scope_bundles` entry fans one role out over many scopes under a single group.
- Tenant-wide Microsoft Entra ID (directory) role assignments for Entra-only access groups.
- Service-role access groups (`rbac-<service>-<service_role>`, e.g. `rbac-intune-helpdeskoperator`): the group, its PIM policy and eligibility schedules are created here; the role itself is bound to the group inside that service, by that service's admins.
- PIM for Groups activation policies (duration, MFA, justification, approval) on access groups with PIM enabled.
- Permanent eligibility schedules linking the `fn-` function groups into PIM-enabled access groups, or active `azuread_group_member` links when PIM is off.
- Plan-time standard checks that stop the plan on configuration that breaks the naming, scoping, or PIM rules.

## What this module is for

Use this module to grant human access to Azure and Entra ID through the standard pattern: users are never added to role assignments or cloud groups directly. Access flows `user → fn- function group (AD-synced) → rbac- access group (cloud-only) → role at a scope`, with PIM for Groups gating activation. Each `access_groups` entry grants one of three things: an Azure RBAC role at one scope, a set of Microsoft Entra ID roles tenant-wide, or a role the owning service assigns to the group outside Terraform — e.g. Intune's built-in *Helpdesk Operator*, bound by Intune admins to `rbac-intune-helpdeskoperator`, instead of handing out tenant-wide Intune Administrator in Entra.

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
  tenant_id           = "00000000-0000-0000-0000-000000000000" # needed by scope = { tenant_root = true }
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
    {
      azure_role = "Management Group Contributor"
      scope      = { tenant_root = true } # Tenant Root Group: scope ID composed from tenant_id, so rbac-tenant-mgcontributor has no GUID
      members    = ["fn-platform-leads"]
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

or a role that lives inside another service (Intune and similar). The module creates the PIM-able group; the service's own admins bind the role to it:

```hcl
{
  service      = "intune"            # the group is named rbac-intune-helpdeskoperator
  service_role = "helpdeskoperator" # the role the Intune admin will bind to this group, inside Intune
  members      = ["fn-helpdesk"]
}
```

Azure RBAC group names are derived from the role code (`rbac-mg-landingzones-vmcontributor`); scope is `management_group`, `subscription`, `subscription` + `resource_group`, `tenant_root = true` for the Tenant Root Group — its management group ID is the tenant ID, composed from `var.tenant_id`, so no GUID enters the name (`rbac-tenant-mgcontributor`) — or `bundle` for a named set of scope IDs from `var.scope_bundles`, where the bundle name is the naming token (`rbac-jumpbox-reader`). Entra-only groups need an explicit `name_suffix` instead, and one activation of such a group grants every listed role at once. Service entries take no scope and no `name_suffix`: the name is `rbac-<service>-<service_role>`, and this module never touches the service-side role binding — hand the group's object ID (from the `access_groups` output) to the service's admins, who assign `service_role` to it there. Names also state the approval requirement: when the resolved PIM settings require approval, the name gains a trailing `-approval` segment (`rbac-sub-payroll-prod-owner-approval`), because the PIM policy — approval included — belongs to the group. Every PIM setting is explicit: set it on the entry's `pim` block, or leave it to `access_group_defaults` — nothing is inferred from the role name.

### Different approval requirements need different groups

The activation policy (approval, duration, justification) is a property of the access group, not of each member link — one access group cannot be approval-free for one function group and approval-gated for another. Write two entries for the same role and scope; the name flag keeps them apart:

```hcl
{
  entra_roles = ["Security Administrator"]
  name_suffix = "securityadmin"
  members     = ["fn-platform-leads"] # eligible without approval
  pim         = { entra_role_assignable = true } # -> rbac-entra-securityadmin
}

{
  entra_roles = ["Security Administrator"]
  name_suffix = "securityadmin"
  members     = ["fn-security-admins"] # eligible only with approval
  pim         = { require_approval = true, entra_role_assignable = true } # -> rbac-entra-securityadmin-approval
}
```

With identical policy, put both function groups in the same entry's `members` instead — one group, one policy. The `-approval` segment is reserved: `name_suffix`, `service_role` and custom role codes must not be or end in `approval`.

### Resolving Entra ID role names

`entra_roles` entries are display names, matched case-insensitively and trimmed against three sources in ascending priority — the last match wins:

1. **Activated directory roles** (`/directoryRoles`) — a custom role created through this API is assigned by its instance object ID.
2. **Built-in role templates** (`/directoryRoleTemplates`) — every built-in role, activated or not. The assignment resource takes a built-in's *template* ID, so on a collision with an activated instance the template wins, and a built-in nobody has ever been assigned still resolves.
3. **`var.entra_custom_role_ids`** — explicit display name => role definition ID pins for custom roles created via the unified role management API (`GET /roleManagement/directory/roleDefinitions`), which never appear in either list above:

```hcl
entra_custom_role_ids = {
  "Payroll Data Steward" = "99999999-9999-9999-9999-999999999999" # find the ID at GET /roleManagement/directory/roleDefinitions or in the portal URL of the role
}
```

A name that matches no source fails the plan with a message naming the group and the role. How each requested name resolved — the ID and its source (`pinned`, `template` or `instance`) — is an output, so a resolution is inspectable in the plan instead of silently applied (see `entra_roles` under Outputs).

### One role, many scopes: scope bundles

Some grants are one role repeated across many individual resources — Bastion RDP to a jump host, for example, needs `Reader` on each VM, NIC, vNet and the bastion host itself. A scope bundle names that set once in `var.scope_bundles`; entries then reference it, and the module makes one role assignment per scope ID under a single group (one PIM policy, one eligibility wiring):

```hcl
scope_bundles = {
  jumpbox = [
    "/subscriptions/.../resourceGroups/rg-hub-australiaeast/providers/Microsoft.Network/bastionHosts/bas-hub-australiaeast",
    "/subscriptions/.../resourceGroups/rg-alz-platform-prd-australiaeast-001/providers/Microsoft.Network/virtualNetworks/vnet-platform-prd-australiaeast",
    # ... VMs and NICs ...
  ]
}
```

```hcl
{
  azure_role = "Reader"
  scope      = { bundle = "jumpbox" }
  members    = ["fn-jumpbox-staff"] # internal staff: permanent, as before
  pim        = { enabled = false } # -> rbac-jumpbox-reader
}

{
  azure_role = "Reader"
  scope      = { bundle = "jumpbox" }
  members    = ["fn-jumpbox-vendors"] # vendors: activation with approval
  pim        = { require_approval = true } # -> rbac-jumpbox-reader-approval
}
```

Editing a bundle's contents only adds or removes role assignments — the group, its PIM policy and its eligibility schedules are untouched. Renaming the bundle key renames and replaces the groups.

## Key inputs

| Input                 | Description                                                                        |
| --------------------- | ------------------------------------------------------------------------------------ |
| subscription_id       | Subscription the azurerm provider signs in to (documentation of intent).           |
| subscriptions         | Subscription CAF name => subscription ID, used to build scopes and group names.    |
| tenant_id             | Entra tenant ID; required by `scope = { tenant_root = true }` (the Tenant Root Group's ID). |
| scope_bundles         | Bundle name => absolute scope IDs sharing one role, referenced as `scope = { bundle = "<name>" }`. |
| access_group_owners   | Object IDs of the principals that own every access group.                          |
| access_group_defaults | Baseline PIM settings; a group's own `pim` block overrides field by field.         |
| access_groups         | One entry per access group: Azure role + scope, Entra roles, or `service` + `service_role`; members, PIM overrides. |
| custom_roles          | Custom role name => `{ code, id }` for roles outside the built-in role code list.  |
| entra_custom_role_ids | Entra ID display name => role definition ID; pins custom roles created via the unified role management API that can't be resolved by name. Wins over the by-name lookup on a collision. |

## PIM settings

Each setting maps 1:1 to an Entra attribute. A group's `pim` block overrides `access_group_defaults` field by field; unset fields inherit the default. The resolved settings appear in the `access_groups` output, so what a group actually gets is always inspectable.

| Setting                          | Default   | Meaning (Entra attribute)                                                                                                                                          |
| -------------------------------- | --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `enabled`                        | `true`    | PIM for Groups policy on the access group. `false` = plain active membership, no policy                                                                              |
| `maximum_duration`               | `"PT8H"`  | `activation_rules.maximum_duration`, ISO 8601 (e.g. `"PT4H"`)                                                                                                      |
| `require_justification`          | `true`    | `activation_rules.require_justification`                                                                                                                           |
| `require_multifactor_authentication` | `true` | `activation_rules.require_multifactor_authentication`                                                                                                              |
| `require_approval`               | `false`   | `activation_rules.require_approval`; needs an `approver_group`; when true (with PIM on) the group name gains the `-approval` segment                                     |
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

# Intune Helpdesk Operator: PIM wiring here; the role binding is made in Intune
{ service = "intune", service_role = "helpdeskoperator", members = ["fn-helpdesk"] }
```

## Outputs

- access_groups — the access groups managed here and what each one grants (object ID, role(s) or service binding, scope IDs, members, resolved PIM settings). Useful for access reviews, audit reporting, and handing group object IDs to other teams (including the service admins who bind service roles to `rbac-<service>-*` groups).
- entra_roles — how each requested Entra ID role display name resolved to a role ID: the id plus its source (`pinned`, `template` or `instance`); a null id means the name was not found and the plan fails before applying.

## Deployment permissions

Deploying this module requires the appropriate Azure RBAC and Microsoft Entra permissions:

- Microsoft Graph application permissions: `Group.ReadWrite.All`, `RoleManagement.ReadWrite.Directory` (for role-assignable groups and Entra ID role assignment), `RoleManagementPolicy.ReadWrite.AzureADGroup`, `PrivilegedEligibilitySchedule.ReadWrite.AzureADGroup`
- The identity must be Privileged Role Administrator (or Global Administrator) to create and manage role-assignable groups.
- Azure: Role Based Access Control Administrator, conditioned to group principals, at the top management group the scopes sit under — for `tenant_root` entries, at the Tenant Root Group.
- Service-role groups need no extra permissions: only the group and its PIM wiring are created here. Binding the role inside the service (e.g. Intune's Helpdesk Operator) is done with that service admin's own permissions.

## Plan-time validation

The plan fails on:

- Setting more than one of `azure_role`, `entra_roles`, `service`, or none of them
- `service` without `service_role`, or a `service`/`service_role` that isn't a lowercase slug (letters, digits, single hyphens)
- An Entra-only group without `name_suffix`, or a `name_suffix` on an Azure RBAC or service group
- A scope mismatch: `azure_role` without a scope, or `entra_roles`/`service` with one; a scope with more than one of `management_group`, `subscription`, `tenant_root`, `bundle`, or `tenant_root = false`
- Entra ID roles on a group whose resolved settings don't have `entra_role_assignable = true`
- An Azure RBAC role with no role code (add it to `naming.tf` or `custom_roles`)
- An invalid `maximum_duration` (ISO 8601 like `PT4H`/`P1D`) when PIM is enabled
- `require_approval = true` without an `approver_group` (on the group or in `access_group_defaults`)
- A subscription missing from `var.subscriptions`
- `scope = { bundle = "<name>" }` where `<name>` isn't in `var.scope_bundles`, a bundle name that isn't a lowercase slug, an empty bundle, or a bundle scope ID that isn't absolute (starts with `/`, no spaces)
- `scope = { tenant_root = true }` without `var.tenant_id`, or a `tenant_id` that isn't a GUID
- Members that aren't `fn-` groups
- Two entries that resolve to the same group name (same role, scope and approval requirement)
- A `name_suffix`, `service_role` or custom role code that is or ends in `approval` (that name segment is reserved)
- An Entra ID role display name that matches no built-in template, activated directory role, or pinned ID in `var.entra_custom_role_ids`
- Names over 64 characters or not lowercase

`naming.tf`, `standard.tf` and `variables.tf` need no Azure access, so they can be checked in CI.

## Implementation notes

- A change to an entry's role, service pair (`service` + `service_role`) or scope changes the group name, so Terraform replaces the group. This is intended, because the name describes what the group grants. For bundle entries the bundle key is the scope: editing the bundle's scope IDs only churns role assignments, the group stays.
- Flipping a group's resolved `require_approval` (or `enabled`) moves the `-approval` segment in or out of the name, so the group is replaced; the name states the governance that applies.
- One approval-gated group per role and scope: two entries that differ only in `approver_group` resolve to the same name and fail the plan.
- A service entry with `pim = { enabled = false }` gets plain active membership like any other group — legal, but the usual intent for service roles is PIM.
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
| `outputs.tf`      | `access_groups` and `entra_roles` outputs                             |
| `examples/basic/` | Complete root module example (service desk, payroll, Entra and Intune)            |
