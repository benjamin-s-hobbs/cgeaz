# Control Mappings

Every policy, collector, and gate rule in this repo, mapped to the NIST 800-53 Rev 5
category it serves. This file is what turns the repo from code into a control catalog —


## Stage 01 — Foundation

| Component | What it does | NIST 800-53 Rev 5 |
|---|---|---|
| Management group hierarchy + initiative assignment | Controls inherit to every current and future subscription — compliance by design | CM-2, CM-6 |
| `cge-require-env-tag-rg` (Audit) | Inventory hygiene; owner accountability feeds the POA&M | CM-8, PM-5 |
| `cge-deny-public-blob` (Deny) | Prevents public blob exposure at the API, before the resource exists | AC-3, AC-4 |
| `cge-dine-storage-diagnostics` (DeployIfNotExists) | Logging that enforces its own coverage | AU-2, AU-12 |
| Remediation identity (user-assigned, whitelist roles) | Every automated change has a named, auditable author | AC-2, AU-10 |
| Log Analytics workspace + Activity Log routing | Central audit trail beyond the 90-day default | AU-9, AU-11 |
| `cge-require-kv-purge-protection` (Audit) | Enforces recoverability of cryptographic keys against malicious or accidental deletion | CP-9, SI-12 |
| `cge-require-app-tls-1-2` (Audit) | Ensures web traffic is encrypted in transit using modern protocols | SC-8 |
| `cge-require-storage-cmek` (Audit) | Enforces customer-managed keys for data-at-rest encryption | SC-28, SC-12 |
| `cge-require-cosmos-private-endpoint` (Audit) | Forces data-plane traffic onto a Private Endpoint by disabling public access | SC-7 |
| `cge-deny-nic-public-ip` (Audit) | Prevents public IPs on network interfaces to enforce centralized perimeter routing | SC-7 |
| `cge-require-sql-tde` (Audit) | Intercepts explicit attempts to disable Transparent Data Encryption on Azure SQL | SC-28 |
| `cge-require-sub-owner` (AuditIfNotExists) | Flags subscriptions missing the Owner role to enforce administrative accountability | AC-6 |

## Stage 03 — Evidence Store

| Component | What it does | NIST 800-53 Rev 5 |
|---|---|---|
| Cosmos DB (assessments / frameworks / mappings) | Owned evidence schema; collect once, crosswalk to every framework | CA-2, CA-7 |
| WORM immutability policy on `reports` | Artifacts tamper-proof by platform guarantee | AU-9, SI-7 |
| Shared keys disabled + data-plane RBAC | Identity or nothing; no credentials to steal or rotate | IA-2, IA-5 |
| Collector Function (Security Reader + Cosmos write only) | Continuous control-test capture with lineage; cannot alter what it observes | CA-7 |
| Collector/reporter identity split | The recorder of facts cannot author the narrative — SoD by role scopes | AC-5 |

## Stage 04 — Reporting

| Component | What it does | NIST 800-53 Rev 5 |
|---|---|---|
| POA&M generator (daily, SLA-dated) | Weakness management with owners and dates, from the store only | CA-5, PM-4 |
| SAR generator (weekly) | Assessment reporting where every number traces to a stored document | CA-2, CA-4 |

## Stage 06 — Enforcement

| Component | What it does | NIST 800-53 Rev 5 |
|---|---|---|
| `cge-fix-public-blob` (Modify, mode ladder) | Auto-remediation through the dedicated identity; human-approved in dry-run | SI-2, CM-6 |
| `remediation_mode` variable | Escalation is a reviewed diff — automation acts, humans authorize | CM-3 |

## Repo gates (policy/)

| Rule | Mistake it makes unmergeable | NIST 800-53 Rev 5 |
|---|---|---|
| `storage.rego` | Pipeline storage below the pipeline's own standard | CM-6 |
| `policy_identity.rego` | Remediation that silently never runs | CM-5 |
| `broad_roles.rego` | Owner/Contributor grants in governance code | AC-6 |
| `drift.yml` + KQL tripwire | Out-of-band change going unnoticed | SI-4, CM-3 |