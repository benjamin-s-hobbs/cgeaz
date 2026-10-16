# Automated GRC Engineering Pipeline
**CGE-AZ Capstone Project | Benjamin Sullivan Hobbs**

This repository contains a complete, automated Governance, Risk, and Compliance (GRC) engineering pipeline deployed entirely via Infrastructure-as-Code (Terraform) and GitHub Actions. It replaces manual screenshot-gathering with continuous, defensible, and self-correcting policy enforcement.

## How to use this repo

1. **Review the Controls:** Start with `docs/CONTROLS.md` to see exactly how the Terraform code maps to NIST 800-53 Rev 5 requirements.
2. **Examine the Infrastructure:** Navigate through the `stages/` directories in numerical order to see how the governance architecture is layered. Pay special attention to `stages/05-narrative` for the zero-key AI infrastructure.
3. **Inspect the Automation:** Review `.github/scripts/asset_collector.py` and `generate_narrative.py` to see how evidence is queried, locked into WORM storage, and narrated by the LLM.
4. **Check the Gates:** Look at the `.rego` files in the `policy/` directory to see the "governance of governance" — the rules that prevent broad `Owner` roles or public storage accounts from being merged into this repository.

## The Pipeline Stages

This pipeline operates in a continuous loop deployed across six Terraform root modules:

```text
1 Discovery → 2 Activation → 3 Evidence Store → 4 Reporting → 5 Narrative → 6 Enforcement ↺
   detect        enable         Cosmos DB +        SSP Asset      Azure AI      Azure Policy
   what runs     what's         WORM Blob          Inventory      Foundry       + remediation
                 missing                           JSON           (gpt-4o-mini) identity
```
1. **Discovery:** Detects the current state of the environment without altering it.
2. **Activation:** Closes measurement gaps (e.g., turning on diagnostic settings).
3. **Evidence Store:** Collects Azure Resource Graph (ARG) data into a NoSQL Cosmos DB, formatted by resource provider.
4. **Reporting:** Generates machine-readable JSON artifacts and locks them immutably into Azure Blob WORM storage.
5. **Narrative (AI Integration):** Reads strictly from the immutable WORM blob, generates an auditor-ready prose digest using `gpt-4o-mini` (Zero-Key Auth), and dispatches it to stakeholders via Azure Communication Services.
6. **Enforcement:** Escalates policies from Audit to Deny/Modify using a dedicated managed identity.


## The Scenario: FAFO, Inc.

I was brought on as the first GRC Engineer for **FAFO, Inc.**, a 90-person health-analytics SaaS company. 

**The Current State:** The company’s Azure environment spans 3 subscriptions, was built by 4 engineers over the last 2 years, and houses approximately 400 resources. There is zero governance. There are no Azure Policy assignments in the tenant, and security evidence consists entirely of manual screenshots stored in a shared drive.

**The Mission:** The CTO has given me 30 days and a dedicated Azure sandbox subscription with full access to build an automated compliance engine to unblock a massive sales bottleneck. The pending deals stacking up include:
1. **Hospital Network:** Requires HIPAA evidence (contract pending).
2. **Federal Pilot (via a Prime):** Requires NIST 800-53 artifacts (machine-readable preferred).
3. **Enterprise Buyers:** Two major buyers require SOC 2 and are burying the team in security questionnaires.

## Architectural Decisions

**Decision 1: Framework Selection — NIST 800-53 Rev 5**
While HIPAA is our immediate "bread and butter" requirement for Deal 1, I deliberately selected NIST 800-53 Rev 5 as the foundational framework for this pipeline. My previous work demonstrated the ability to map controls directly to HIPAA, but NIST 800-53 provides the rigor necessary to generate machine-readable artifacts (OSCAL/SSP). By aiming for the highest tier of evidence creation and securely integrating AI for executive summaries, we achieve a **Write Once, Read Many** evidence store. We collect the technical truth once, and crosswalk it to satisfy HIPAA, SOC 2, and the Federal Pilot simultaneously.

**Decision 2: Schema Extension — Asset Inventory & ARG Collector**
With 400 previously unmanaged resources, FAFO desperately needed continuous visibility. I extended the Cosmos DB schema with an `AssetInventory` container, fed by a custom Azure Resource Graph (ARG) Python collector. This collector runs weekly, mapping every provisioned asset, its location, and its `owner`/`env` tags. This replaces manual spreadsheets with a mathematically provable inventory, which is a hard requirement for SOC 2 (CC3.2) and NIST (CM-8).

**Decision 3: KQL Tripwires — Taming the "Wild West"**
FAFO's 4 engineers have had unchecked "Wild West" access for two years. To establish operational oversight without immediately breaking their workflows, I deployed specific KQL tripwires:
*   `alert-manual-rbac`: Detects out-of-band role assignments bypassing our IaC pipeline.
*   `alert-kv-secret-reads`: Alerts when humans (not pipelines) read Key Vault secrets.
*   `alert-out-of-hours-admin`: Detects administrative changes occurring outside standard business hours.
*   `alert-pim-activations`: Audits Privileged Identity Management usage.
These provide immediate situational awareness to the security team and prove to auditors that we actively monitor administrative access (NIST AU-6, SOC 2 CC7.2).

**Decision 4: Custom Policies — Securing Health Analytics (PHI)**
Because FAFO handles health data, I authored custom policies focused on data protection and accountability. Phased escalation of these policies is the proposed roadmap, from Audit (to observe where there are gaps without breaking the environment) >> to Deny (to prevent any undesirable new configurations) >> to Modify (providing a path to remediate existing resources) >> to deployIfNotExists (to remediate gaps in coverage and close configuration drift)
*   **Require `env` and `owner` tags on Resource Groups (Audit):** Forces accountability for the 400 existing resources.
*   **Deny Public Blob Access:** Prevents accidental exposure of PHI at the API level before the resource even deploys.
*   **Require Key Vault Purge Protection, Storage CMEK, and SQL TDE (Audit):** Ensures cryptographic keys are recoverable and enforces data-at-rest encryption.
*   **Require App Service TLS 1.2 (Audit):** Enforces modern transit encryption.
These policies mathematically guarantee compliance with HIPAA Safeguards and NIST SC-8 / SC-28.


## The rules the pipeline lives by

* **Discovers first, then acts.** Stage one changes nothing; activation closes only the measured gap.
* **Collect once, map to wherever needed.** One assessment document serves every framework through the mappings crosswalk.
* **Reports read from Write Once, Read Many (WORM) immutable storage only.** Every number is an permanent fact with a timestamped receipt. The AI only reads locked facts; it cannot hallucinate live state.
* **Zero keys.** Managed identities and Entra ID OpenID Connect (OIDC) are used end-to-end. The evidence store disables shared keys entirely, and the AI model is accessed via Cognitive Services RBAC.
* **Automation acts; humans authorize.** Escalation (audit → dry-run → enforce) is a reviewed one-line diff.
* **Changes go through the repo, never the portal.** Drift detectors and KQL tripwires monitor for out-of-band portal changes.

## Repository Layout

```text
stages/            One directory per pipeline stage — each a Terraform root module.
.github/scripts/   Python automation (ARG collectors, WORM committers, AI narrators).
.github/workflows/ CI/CD pipelines (compliance gates, weekly automated collectors).
policy/            OPA/conftest Rego rules that gate this repo's own PRs.
docs/              Setup guides, architectural decisions, and control mappings.
```

*"The work, works"*
