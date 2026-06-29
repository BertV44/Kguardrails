# RESEARCH — Kyverno Guardrails for Veeam Kasten

Phase 1 findings. This document is the ground-truth reference that Phase 2
(policy implementation) builds on.

## OBJECT-LEVEL RECONCILIATION (cluster dump 2026-06-29, K10 8.5.12)

A second pass against a live cluster dump (`kasten-guardrails-dump.txt`,
`kube:admin @ api.ocp.cp4d.kastenevents.com`, captured 2026-06-29) provided the
real *object* shapes the 2025-12 `oc explain` pass could not. Key facts:

- **Kasten version = K10 8.5.12** (helm chart `k10-8.5.12`, config `version:
  8.5.12`, `multiClusterVersion: 2.5`; Kasten CRDs created 2026-06-16). This is
  **v8.x, not v9.0** — so the v9.0 "Admission Controller Policy Enforcement"
  Tech Preview is **not installable on this lab at all**, not merely disabled.
- **No admission webhooks** of any kind (dump section 3 = `(none)` for both
  Validating and Mutating). Confirms Scope B enforcement here can only run
  through Kyverno's own webhook, never a Kasten-native one.

| Policy | Prev verdict | New verdict (2026-06-29) | Object-level evidence |
| --- | --- | --- | --- |
| 3 require-expiry-on-manual-actions | partial | **verified** | Manual `RestoreAction restore-etcd-vgtcc` carried only `appName`/`appNamespace`; every policy-created action carried `k10.kasten.io/policyName`+`policyNamespace`+`runActionName`. Discriminator confirmed. (No manual BackupAction/RunAction existed to observe directly.) |
| 4 exclude-sensitive-on-restore | blocked | **unverified (still)** | Real RestoreAction omitted `spec.filters` entirely; real BackupAction had `spec.filters: {}`. Confirms field is optional/opaque, but **no object populated `excludeResources`** → exact sub-key shape still unconfirmable from a live object. |
| 5 deny-immutable-restorepoint-deletion | corrected | **corrected again** | Two real bugs fixed — see below. |

**Policy 5 — corrections from real objects (supersede the 2025-12 notes):**
- **protectionPeriod path was wrong.** The 2025-12 pass changed it to
  `spec.export.location.objectStore.protectionPeriod`. The live Profile
  `etcd-minio` uses **`spec.locationSpec.objectStore`** (objectStoreType S3, no
  `export.location` wrapper) — matching §4.3/§4.7 and the upstream
  `kasten-immutable-location-profile` policy. The apiCall now reads
  `spec.locationSpec.objectStore.protectionPeriod` first, with
  `spec.export.location.objectStore.protectionPeriod` as a defensive secondary.
- **The status-based managed marker does not exist on 8.5.12.** Real
  RestorePointContent status = `{actionTime, restorePointRef, scheduledTime,
  state: Bound}`; real RestorePoint status = `{actionTime, logicalSizeBytes,
  physicalSizeBytes, scheduledTime}`. **No `originatingPolicies`, no
  `artifacts[].meta.*.profileRef`.** The old precondition
  (`length(originatingPolicies) > 0`) would never match → policy inert. Both
  objects DO carry the `k10.kasten.io/policyName` label, so the marker is now the
  **label** (consistent with policy 3).
- **Profile is not resolvable from the restore-point object on 8.5.12.** The only
  profile reference is on the originating Action (`spec.profile`), not on the
  RP/RPC. With `profileName` empty the apiCall cannot resolve a Profile, so the
  policy degrades safely to *allow* (documented LIMITATION). The artifacts paths
  are retained as forward-compatible best-effort. A real enforcement path would
  chain label → `Policy.spec.actions[].exportParameters.profile` → Profile, which
  needs the Policy export schema confirmed first.

## CLUSTER RECONCILIATION (oc explain, cluster CRDs dated 2025-12-03)

A live `oc explain --recursive` dump of the Kasten lab CRDs reconciled the
doc-only assumptions below. Net result:

| Policy | Verdict | Detail |
| --- | --- | --- |
| 1 require-policy-preset | **verified** | `spec.presetRef.{name,namespace}`, `spec.frequency`, `spec.subFrequency`, `spec.retention.{hourly,daily,weekly,monthly,yearly,table}`, `spec.actions[].action` all exist as coded. |
| 2 require-resource-exclusions | **verified** | `spec.actions[].backupParameters.filters.excludeResources[]` confirmed; entries carry `group/version/resource/name/matchLabels/matchExpressions`. Filters are per-action (`backupParameters`, `restoreParameters`, `restoreClusterParameters`, `batchRestoreParameters`, `stageParameters`, `validateParameters`, `backupClusterParameters`). |
| 6 forbid-cross-namespace-restore | **verified** | `RestoreAction.spec.targetNamespace` and `spec.subject.{apiVersion,kind,name,namespace}` confirmed. |
| 3 require-expiry-on-manual-actions | **partial** | `BackupAction.spec.expiresAt` and `RunAction.spec.expiresAt` confirmed. Manual-vs-managed label NOT verifiable via explain — needs `--show-labels`. |
| 4 exclude-sensitive-on-restore | **blocked** | `RestoreAction.spec.filters` is an OPAQUE `map[string]` in the CRD (no sub-schema). `BackupAction.spec.filters` likewise. Structured shape only published under the Policy CRD's `*Parameters.filters`. Needs a real RestoreAction. |
| 5 deny-immutable-restorepoint-deletion | **corrected** | See below. Several original assumptions were wrong. |

**Corrections applied to policy 5:**
- ~~Profile immutability field is **`spec.export.location.objectStore.protectionPeriod`** (NOT `spec.locationSpec.objectStore.protectionPeriod`).~~ **SUPERSEDED 2026-06-29:** the live Profile uses `spec.locationSpec.objectStore.protectionPeriod` (see the object-level section at the top).
- `RestorePointContent` has **no `spec`** (status only). The old `spec.location.profile.*` path was invalid.
- Originating policy is recorded at `status.restorePointContentDetails.originatingPolicies[]` (RestorePointContent) and `status.restorePointDetails.originatingPolicies[]` (RestorePoint) — used as the policy-managed marker.
- Originating Profile ref lives (nested, per-artifact) at
  `status.<details>.artifacts[].meta.{kanister,dataservice,...}.profileRef.{name,namespace}` — exact sub-key still needs a real object.
- `RestorePoint.spec.restorePointContentRef.name` confirmed.

**Environment facts:**
- `oc get validatingwebhookconfigurations | grep -i kasten` returned **nothing** — no Kasten-native admission webhook on this cluster, so the v9.0 admission feature (Tech Preview) is not deployed here. Scope B policies still enforce via Kyverno's own webhook, but live end-to-end testing of the Kasten v9.0 path is not possible on this cluster.
- CRDs present: `policies`, `policypresets`, `profiles` (`config.kio.kasten.io`); `backupactions`, `restoreactions`, `runactions` (`actions.kio.kasten.io`); `restorepoints`, `restorepointcontents` (`apps.kio.kasten.io`). Kasten version string not captured (re-run with `oc -n kasten-io get k10s -o yaml | grep -i version`).

**Still to run on the cluster** (to close policies 3, 4, 5):
```
oc get backupactions.actions.kio.kasten.io -A --show-labels
oc get restorepoints.apps.kio.kasten.io -A --show-labels
oc get restorepointcontents.apps.kio.kasten.io -A -o yaml | sed -n '1,160p'
oc get restoreactions.actions.kio.kasten.io -A -o yaml | sed -n '1,120p'
oc -n kasten-io get k10s.apik10.kasten.io -o yaml | grep -i version
```

---


## 0. Status of this document

- **Method**: doc-only. At the time of writing, no live Kasten cluster was
  reachable to run the `oc explain` calls (see Section 1). Every CRD field path
  and JMESPath anchor below is therefore tagged **`[unverified]`** and must be
  reconciled against a live cluster with `oc explain` before policies are
  shipped as `[available]`.
- **Sources**: upstream `kyverno/policies/kasten`, the Kasten opt-out blog and
  repo, the Kasten API docs (`docs.kasten.io/latest/api/`), and the Veeam Kasten
  v9.0 announcement. Specific URLs are cited inline.
- **Legend**:
  - `[available]` — confirmed for Kasten v8.x (still needs `oc explain` to lift
    the `[unverified]` tag on exact paths).
  - `[preview]` — Kasten v9.0 Tech Preview feature; requires the v9.0 admission
    controller to be enabled on Actions/RestorePoints.
  - `[unverified]` — taken from docs/upstream only; not yet confirmed against a
    live cluster schema.

## 1. Cluster access status (blocker for ground-truth)

`oc` client v4.21.10 is installed. Three kube contexts exist:

| Context | Server | State |
| --- | --- | --- |
| `default/api-kasten-se-lab-...:6443/Michael.Courcy@veeam.com` | `https://api.kasten-se-lab.selab.kastendemo.com:6443` | Reachable, **token expired** ("the server has asked for the client to provide credentials") |
| `default/api-oc02-home:6443/kube:admin` | `https://localhost:16443` | Connection refused |
| `default/localhost:16443/kube:admin` | `https://localhost:16443` | Connection refused (current context) |

All three use static bearer tokens. The Kasten lab token needs refreshing
(OpenShift `oc login --token=...`). **The following commands from the project
brief must be run once a valid token is available, and their output folded back
into Sections 3–4 to remove the `[unverified]` tags:**

```
oc explain policies.config.kio.kasten.io --recursive
oc explain policypresets.config.kio.kasten.io --recursive
oc explain backupactions.actions.kio.kasten.io --recursive
oc explain restoreactions.actions.kio.kasten.io --recursive
oc explain runactions.actions.kio.kasten.io --recursive
oc explain restorepoints.apps.kio.kasten.io --recursive
oc explain restorepointcontents.apps.kio.kasten.io --recursive
oc get crd | grep kasten.io
# Version + admission scope:
oc -n kasten-io get deploy -l component=gateway -o jsonpath='{.items[*].spec.template.spec.containers[*].image}'
oc get validatingwebhookconfigurations | grep -i kasten
```

## 2. Kasten version and v9.0 admission-control availability

- **Installed version**: `[unverified]` — not yet read from the cluster. The
  `latest` docs alias rendered 7.x/8.x content during research, so the docs
  `latest` may lag v9.0.
- **v9.0 admission control on Actions/RestorePoints**: confirmed by the Veeam
  Kasten v9.0 announcement to be **Preview (Tech Preview)**, not GA. Verbatim
  feature title: *"Admission Controller Policy Enforcement for Backup and
  Restore Operation (Preview)"*.
  - Sources: <https://www.veeam.com/blog/veeam-kasten-v9-enterprise-kubernetes-resilience.html>
    and a corroborating third-party writeup.
  - Supported engines: **Kyverno, OPA Gatekeeper, and native Validating
    Admission Policies**.
  - Behavior: "Actions and RestorePoints are now evaluated at admission time —
    before the operation executes, not after." Builds on the v8.0 Validating
    Admission Policy work.
  - Stated guardrail examples (these map 1:1 onto our Scope B policies):
    prevent cross-namespace restores, strip unauthorized resource types from
    recovery, require expiration dates on manual actions, control who can modify
    backup policies.

**Consequence**: every Scope B policy (3–6) must be flagged `[preview v9.0]` and
documented as requiring the v9.0 admission webhook on Actions/RestorePoints.

## 3. API groups, kinds, and how to match them

| API group / version | Kinds | Scope |
| --- | --- | --- |
| `config.kio.kasten.io/v1alpha1` | `Policy`, `PolicyPreset`, `Profile` | A `[available v8.x]` |
| `apps.kio.kasten.io/v1alpha1` | `RestorePoint`, `RestorePointContent`, `ClusterRestorePoint`, `Application` | B `[preview v9.0]` |
| `actions.kio.kasten.io/v1alpha1` | `BackupAction`, `RestoreAction`, `ExportAction`, `ImportAction`, `RunAction`, `BackupClusterAction` | B `[preview v9.0]` |

**Matching convention (from upstream Kyverno Kasten policies):** Kasten CRDs are
matched in `match`/`exclude` blocks by the **compound kind string**, not the
bare kind:

```yaml
match:
  any:
  - resources:
      kinds:
      - config.kio.kasten.io/v1alpha1/Policy   # not just "Policy"
```

Likewise `config.kio.kasten.io/v1alpha1/Profile`,
`actions.kio.kasten.io/v1alpha1/RestoreAction`,
`apps.kio.kasten.io/v1alpha1/RestorePoint`, etc. `[unverified]` — confirm the
served versions with `oc get crd`.

## 4. Resolved field paths (per CRD)

All `[unverified]` until confirmed with `oc explain`. Source: `docs.kasten.io/latest/api/`.

### 4.1 Policy — `config.kio.kasten.io/v1alpha1` `[available v8.x]`

| Path | Notes |
| --- | --- |
| `spec.presetRef.name`, `spec.presetRef.namespace` | Reference to a `PolicyPreset`. Used by policy 1. |
| `spec.actions[].action` | `backup \| export \| import \| restore \| report`. Confirmed by upstream 3-2-1 policy. |
| `spec.actions[].backupParameters.filters.includeResources` | Resource include filter on the backup action. |
| `spec.actions[].backupParameters.filters.excludeResources` | Resource exclude filter. Used by policy 2. |
| `spec.actions[].backupParameters.filters.includeExtraResources` / `excludeExtraResources` | Additional filter lists. |
| `spec.actions[].exportParameters.{frequency, profile.{name,namespace}, exportData.enabled}` | Export action params. |
| `spec.selector.matchExpressions[].{key,operator,values}`, `spec.selector.matchLabels` | Special keys: `k10.kasten.io/appNamespace`, `k10.kasten.io/virtualMachineRef`. |
| `spec.frequency` | `@hourly`/`@daily`/... |
| `spec.subFrequency.{minutes,hours,weekdays,days,months}` | |
| `spec.retention.{hourly,daily,weekly,monthly,yearly}` | Inline retention (what policy 1 will forbid when a preset is required). |
| `spec.backupWindow.{start,end}.{hour,minute}`, `spec.comment`, `spec.paused` | |

> **Filter-path caveat**: docs place resource filters under the **action's**
> `*Parameters.filters` (e.g. `spec.actions[].backupParameters.filters.*`), not a
> top-level `spec.filters`. The brief notes the exact path "varies by version".
> **Must confirm with `oc explain policies.config.kio.kasten.io --recursive`**
> whether filters are per-action (`spec.actions[].backupParameters.filters`) or
> also exist at another level before writing policy 2.

### 4.2 PolicyPreset — `config.kio.kasten.io/v1alpha1` `[available v8.x]`

| Path | Notes |
| --- | --- |
| `spec.backup.{frequency, retention}` | Required. |
| `spec.export.{frequency, retention, profile.{name,namespace}}` | Optional. |
| `spec.comment` | |

> The `presetRef` linkage is documented on the **Policy** page, not the
> PolicyPreset page. A Policy that uses a preset supplies app-specific info
> (selector); the preset supplies schedule/retention/location.

### 4.3 Profile (Location Profile) — `config.kio.kasten.io/v1alpha1` `[available v8.x]`

| Path | Notes |
| --- | --- |
| `spec.type` | e.g. `Location`. |
| `spec.locationSpec.objectStore.protectionPeriod` | **Immutability anchor.** Go duration (e.g. `720h0m0s`). Required for `VeeamVaultAzure`, optional for S3. Confirmed by upstream `kasten-immutable-location-profile` policy. |

### 4.4 BackupAction / RunAction — `actions.kio.kasten.io/v1alpha1` `[preview v9.0]`

| Path | Notes |
| --- | --- |
| `spec.subject.{name,namespace}` (BackupAction) | The app being backed up. |
| `spec.subject.{kind,name,namespace}` (RunAction; `kind: Policy`) | RunAction runs a Policy on demand. |
| `spec.expiresAt` | RFC3339 (e.g. `2002-10-02T15:00:00Z`). Used by policy 3. |
| `spec.filters.{includeResources,excludeResources}` (BackupAction) | Per-action filters. |
| `status.restorePoint.{name,namespace}` (BackupAction) | Resulting restore point. |
| `status.policySpec.{actions,selector}` (RunAction) | |

### 4.5 RestoreAction — `actions.kio.kasten.io/v1alpha1` `[preview v9.0]`

| Path | Notes |
| --- | --- |
| `spec.subject.{kind,name,namespace}` (`kind: RestorePoint`) | The restore-point reference; **`spec.subject.namespace` is the source application namespace** — used by policy 6. |
| `spec.targetNamespace` | Destination namespace. Policy 6 compares this against the source. |
| `spec.filters.{includeResources,excludeResources}` | Used by policy 4 (exclude Secrets etc.). |
| `spec.overwriteExisting` | bool. |

### 4.6 RestorePoint / RestorePointContent — `apps.kio.kasten.io/v1alpha1` `[preview v9.0]`

| Path | Notes |
| --- | --- |
| `spec.restorePointContentRef.name` (RestorePoint) | Links to its content. |
| `status.{state,logicalSizeBytes,physicalSizeBytes,scheduledTime,actionTime}` | `state` e.g. `Bound`. |
| label `k10.kasten.io/appName`, `k10.kasten.io/appNamespace`, `k10.kasten.io/appType` | Auto-applied. `appType` = `virtualMachine`/`namespace`. |
| label `k10.kasten.io/policyName`, `k10.kasten.io/policyNamespace` | **Policy-managed marker.** Used by policies 3 and 5 to distinguish policy-managed vs manual. |

> **Label-scope flag**: docs scope `k10.kasten.io/policyName` /
> `policyNamespace` to **ClusterRestorePoint** ("Populated for policy initiated
> BackupClusterAction only"). The brief assumes these labels on RestorePoint and
> on Actions. **Must confirm with `oc explain` / `oc get ... --show-labels`**
> exactly which kinds carry these labels, and whether manual `BackupAction`
> objects also carry them, before policies 3 and 5 key off them.

### 4.7 Immutability design note (anchor for policy 5)

There is **no immutability field on the RestorePoint/RestorePointContent
object**. Immutability is a property of the **Location Profile** the data was
exported to: `Profile.spec.locationSpec.objectStore.protectionPeriod`. To know
whether a given RestorePoint is immutable at admission time, a policy must
resolve the originating profile.

Candidate resolution for policy 5 (to investigate against the live cluster):

1. From the `RestorePointContent`, read the export location / profile reference
   (path `[unverified]` — likely under `status` or a `details` sub-resource).
2. Use a Kyverno `context.apiCall` to fetch that `Profile` and read
   `spec.locationSpec.objectStore.protectionPeriod`.
3. Treat non-empty `protectionPeriod` as "immutable".

If that linkage is not reliably available **at admission time** (e.g. the
profile reference is only populated post-export, or lives in a sub-resource not
visible to the webhook), document policy 5's immutability signal as
`[unverified]` and fall back to keying off the policy-managed label only, with
the limitation stated.

## 5. Upstream Kyverno Kasten policy conventions (to mirror)

Source: `https://github.com/kyverno/policies/tree/main/kasten` (raw files under
`.../main/kasten/<dir>/<dir>.yaml`).

### 5.1 Annotations present on every upstream policy

```yaml
metadata:
  annotations:
    policies.kyverno.io/title: <Title>
    policies.kyverno.io/category: Veeam Kasten
    policies.kyverno.io/subject: <Policy|Profile|Deployment,StatefulSet|Namespace>
    policies.kyverno.io/description: >-
      <description>
    kyverno.io/kyverno-version: 1.12.1
    policies.kyverno.io/minversion: <e.g. 1.12.0>
    kyverno.io/kubernetes-version: "1.24-1.30"
    # 3-2-1 also sets: policies.kyverno.io/severity: medium
```

Our addition (per brief Section 6): a custom annotation marking scope and
availability, e.g.

```yaml
    veeamkasten.dev/scope: "A"            # or "B"
    veeamkasten.dev/availability: "available-v8"   # or "preview-v9"
```

### 5.2 Default failure action

Upstream defaults most validate policies to `validationFailureAction: Audit`
(safe for public reuse). `kasten-hourly-rpo` uses `Enforce`. **We default to
`Audit`** and document the switch to `Enforce` per policy.

### 5.3 Reusable JMESPath / rule patterns observed

- **Validate via `deny` + conditions** (3-2-1):
  ```yaml
  validate:
    message: "..."
    deny:
      conditions:
        all:
        - key: [backup, export]
          operator: AnyNotIn
          value: "{{ request.object.spec.actions[].action }}"
  ```
- **Validate via `pattern`** (immutable-location-profile, data-protection-by-label):
  ```yaml
  validate:
    pattern:
      spec:
        (type): Location
        locationSpec:
          objectStore:
            protectionPeriod: "*"
  ```
- **`context.apiCall` against the live Kasten API** (generate-by-preset-label,
  hourly-rpo) — e.g. listing policies:
  ```yaml
  context:
  - name: existingPolicy
    apiCall:
      urlPath: "/apis/config.kio.kasten.io/v1alpha1/namespaces/kasten-io/policies"
      jmesPath: "items[] | length(@)"
  ```
  or core namespaces by label:
  ```yaml
      urlPath: "/api/v1/namespaces?labelSelector=appPriority%3Dcritical"
      jmesPath: "items[].metadata.name"
  ```
  This is the mechanism policy 5 will use to resolve the originating Profile.
- **`foreach`** over `spec.selector.matchExpressions[].values` (hourly-rpo) for
  per-element checks.
- **Exclude DELETE from a validate rule** (3-2-1):
  ```yaml
  exclude:
    any:
    - resources:
        operations: [DELETE]
  ```
  Policy 5 conversely **targets** `operations: [DELETE]`.

### 5.4 RBAC for generate rules

If any policy uses a `generate` rule on Kasten CRDs, the Kyverno
background-controller needs an explicit ClusterRole:

```yaml
rules:
- apiGroups: [config.kio.kasten.io]
  resources: [policies]
  verbs: [create, update, delete]
```

(Our six policies are validate/mutate, so this is informational unless we add a
generate variant.)

## 6. Opt-out pattern (reference for configurable allow-lists)

Source: `https://veeamkasten.dev/implementing-opt-out-backup-strategy-with-kyverno`
and `https://github.com/michaelcourcy/kasten-opt-out`.

- Uses a single `backup` label on **Namespaces** (`"true"`/`"false"`), default-on
  via a CREATE-time mutate; JMESPath operates on **namespace metadata**, not on
  Kasten CRDs.
- Triad = **mutate** (add label on namespace create) + **RBAC** (a narrow
  ClusterRole `namespace-patcher` with `verbs: [get, patch]` bound to a group) +
  **validate** (`Enforce`, scoped by `request.userInfo.groups` and
  `request.operation == UPDATE`) that locks down all label changes except the
  `backup` label.
- Notable JMESPath idiom for "compare ignoring one label":
  ```yaml
  key:   "{{ request.object.metadata.labels || `{}` | merge(@, {backup:null}) }}"
  value: "{{ request.oldObject.metadata.labels || `{}` | merge(@, {backup:null}) }}"
  operator: NotEquals
  ```

This is the model for the **configurable allow-list label/annotation** approach
in policy 6 (cross-namespace restore exception).

## 7. Per-policy design map

| # | Policy | Scope | Avail | Type | Primary anchors (all `[unverified]`) |
| --- | --- | --- | --- | --- | --- |
| 1 | `require-policy-preset` | A | `available-v8` | validate (deny) | require `spec.presetRef`; deny presence of inline `spec.frequency`/`spec.retention` |
| 2 | `require-resource-exclusions` | A | `available-v8` | validate | `spec.actions[].backupParameters.filters.excludeResources` must cover a configurable sensitive-GVR list (and/or BackupAction `spec.filters.excludeResources`) |
| 3 | `require-expiry-on-manual-actions` | B | `preview-v9` | validate | `BackupAction`/`RunAction`: if no `k10.kasten.io/policyName` label, require `spec.expiresAt` |
| 4 | `exclude-sensitive-on-restore` | B | `preview-v9` | validate + mutate variant | `RestoreAction.spec.filters.excludeResources` must exclude Secrets + configurable GVRs; mutate injects them |
| 5 | `deny-immutable-restorepoint-deletion` | B | `preview-v9` | validate (deny on DELETE) | DELETE on policy-managed `RestorePoint`/`RestorePointContent` exported to immutable storage; immutability resolved via `apiCall` to originating Profile `protectionPeriod` (see 4.7) |
| 6 | `forbid-cross-namespace-restore` | B | `preview-v9` | validate (deny) | deny when `spec.targetNamespace != spec.subject.namespace` unless configurable allow-list label/annotation present |

## 8. Open questions to resolve on the live cluster (must do before un-`[unverified]`-ing)

1. Exact served CRD versions and whether the compound-kind match strings are
   correct (`oc get crd | grep kasten.io`, `oc explain ... --recursive`).
2. Exact location of resource filters on `Policy` (per-action
   `backupParameters.filters` vs any other level) — gates policy 2.
3. Which kinds carry `k10.kasten.io/policyName`/`policyNamespace` (RestorePoint
   vs ClusterRestorePoint), and whether manual BackupActions carry it — gates
   policies 3 and 5.
4. How (and whether) a RestorePoint/RestorePointContent exposes its originating
   export Profile at admission time — gates policy 5's immutability signal.
5. Confirm `RestoreAction.spec.subject.namespace` is the source app namespace —
   gates policy 6.
6. Installed Kasten version and confirmation that the v9.0 Actions/RestorePoint
   admission webhook is present/enabled — gates all of Scope B.
