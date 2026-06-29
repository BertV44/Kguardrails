# Kyverno Guardrails for Veeam Kasten

Vendor-neutral [Kyverno](https://kyverno.io/) `ClusterPolicy` resources that add
operational guardrails for [Veeam Kasten](https://docs.kasten.io/latest/) on
Kubernetes / OpenShift. The policies standardize data-protection configuration
and constrain risky backup/restore operations at admission time.

All content is anonymized and generic: example namespaces (`app-team-a`,
`kasten-io`), generic labels, and no customer or environment-specific
identifiers. Sensitive-resource lists and allow-list labels are configurable.

> **Project status: work in progress.**
> CRD field paths were reconciled against a live cluster in two passes:
> `oc explain` (Kasten CRDs dated 2025-12) and a live **object dump**
> (2026-06-29, **K10 8.5.12**). Per-policy state is in the matrix below
> (`verified` / `partially-verified` / `unverified`). The lab runs **K10 8.5.12
> (v8.x, not v9.0)** with **no admission webhooks** of any kind, so the v9.0
> admission Tech Preview path (Scope B) cannot be exercised end-to-end there;
> Scope B policies still enforce via Kyverno's own webhook. See
> [docs/RESEARCH.md](docs/RESEARCH.md) for the reconciliation details, including
> what policies 4 and 5 still need to close. Keep all policies in `Audit` until
> fully verified.

## Status legend

| Tag | Meaning |
| --- | --- |
| `[available]` | Targets Kasten v8.x resources (standard objects and the Kasten `Policy` CRD). The mechanism is supported today. |
| `[preview]` | Targets Kasten v9.0 admission control on **Actions** and **RestorePoints**, which is a **Tech Preview** feature in v9.0. Requires the v9.0 admission webhook to be enabled for these resources. |
| `[unverified]` | CRD field paths / JMESPath not yet confirmed against a live object. Now applies only to policy 4 (`spec.filters` is an opaque map and no live object populated it). |

## Policy matrix

| # | Policy | Scope | Availability | Verification | Type | Default action | Subject |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | [require-policy-preset](require-policy-preset/) | A | `[available]` | verified | validate | Audit | `Policy` |
| 2 | [require-resource-exclusions](require-resource-exclusions/) | A | `[available]` | verified | validate | Audit | `Policy` |
| 3 | [require-expiry-on-manual-actions](require-expiry-on-manual-actions/) | B | `[preview]` | verified (policyName label) | validate | Audit | `BackupAction`, `RunAction` |
| 4 | [exclude-sensitive-on-restore](exclude-sensitive-on-restore/) | B | `[preview]` | unverified (filters is opaque map; no populated object) | validate + mutate | Audit | `RestoreAction` |
| 5 | [deny-immutable-restorepoint-deletion](deny-immutable-restorepoint-deletion/) | B | `[preview]` | corrected; label marker; profile unresolvable on v8.x | validate (deny on DELETE) | Audit | `RestorePoint`, `RestorePointContent` |
| 6 | [forbid-cross-namespace-restore](forbid-cross-namespace-restore/) | B | `[preview]` | verified | validate | Audit | `RestoreAction` |

**Scope A** — admission on standard Kubernetes objects and the Kasten `Policy`
CRD (`config.kio.kasten.io/v1alpha1`). Available on Kasten v8.x.

**Scope B** — admission on Kasten **Actions** (`actions.kio.kasten.io/v1alpha1`)
and **RestorePoints** (`apps.kio.kasten.io/v1alpha1`). Kasten v9.0 newly routes
these through the admission controller (Tech Preview).

## What each policy does

1. **require-policy-preset** — every Kasten `Policy` must reference a
   `PolicyPreset` via `spec.presetRef`; inline `spec.frequency` /
   `spec.subFrequency` / `spec.retention` are denied. Standardizes schedule and
   retention through presets.
2. **require-resource-exclusions** — every `Policy` with a backup action must
   exclude a configurable sensitive-resource list (default: `secrets`) via
   `spec.actions[].backupParameters.filters.excludeResources`.
3. **require-expiry-on-manual-actions** — a manual (non-policy-managed)
   `BackupAction` / `RunAction` must set `spec.expiresAt`. Policy-managed actions
   (carrying the `k10.kasten.io/policyName` label) are exempt.
4. **exclude-sensitive-on-restore** — a `RestoreAction` must exclude a
   configurable sensitive-resource list (default: `secrets`) via `spec.filters`.
   Ships as a **validate** policy and a separate **mutate** companion
   (`exclude-sensitive-on-restore-mutate`) that injects the exclusion
   automatically while preserving any existing exclusions.
5. **deny-immutable-restorepoint-deletion** — denies `DELETE` of a
   policy-managed `RestorePoint` / `RestorePointContent` exported to immutable
   storage. Immutability is resolved with a Kyverno `context.apiCall` to the
   originating Location `Profile` (`spec.locationSpec.objectStore.protectionPeriod`).
   See the design note below.
6. **forbid-cross-namespace-restore** — denies a `RestoreAction` whose
   `spec.targetNamespace` differs from the source application namespace
   (`spec.subject.namespace`), unless a configurable allow-list annotation
   (`veeamkasten.dev/allow-cross-namespace-restore: "true"`) is present.
   Restore-in-place (empty `targetNamespace`) is always allowed.

### Design note — policy 5 immutability resolution

Immutability is **not** a field on the RestorePoint object; it is a property of
the Location `Profile` the data was exported to. Policy 5 resolves it at
admission time via a `context.apiCall` to that Profile. Two things are
`[unverified]` and must be confirmed on a live cluster before relying on this
policy:

- the path from a `RestorePoint`/`RestorePointContent` to its originating
  Profile (the policy currently assumes `spec.location.profile.{name,namespace}`
  — almost certainly version-specific);
- whether `k10.kasten.io/policyName` is present on these objects (docs scope it
  primarily to `ClusterRestorePoint`).

If the Profile cannot be resolved at admission time, the immutability signal is
unavailable and the policy will not deny. This limitation is documented inline
in the policy.

## Prerequisites

- A Kubernetes / OpenShift cluster with **Kyverno** installed (policies declare
  `kyverno.io/kyverno-version: 1.12.1`; tested with Kyverno CLI 1.18.1).
- **Veeam Kasten** installed:
  - Scope A policies: **Kasten v8.x** or later.
  - Scope B policies: **Kasten v9.0** with admission control on **Actions** and
    **RestorePoints** enabled. This is a **Tech Preview** feature in v9.0; the
    API server must route `actions.kio.kasten.io` and `apps.kio.kasten.io`
    objects through the admission webhook for these policies to take effect.
- Confirm the installed version and admission scope:

  ```
  oc get crd | grep kasten.io
  oc get validatingwebhookconfigurations | grep -i kasten
  ```

## Install

Apply a single policy:

```
oc apply -f require-policy-preset/require-policy-preset.yaml
```

Apply all policies:

```
oc apply -f require-policy-preset/require-policy-preset.yaml \
         -f require-resource-exclusions/require-resource-exclusions.yaml \
         -f require-expiry-on-manual-actions/require-expiry-on-manual-actions.yaml \
         -f exclude-sensitive-on-restore/exclude-sensitive-on-restore.yaml \
         -f exclude-sensitive-on-restore/exclude-sensitive-on-restore-mutate.yaml \
         -f deny-immutable-restorepoint-deletion/deny-immutable-restorepoint-deletion.yaml \
         -f forbid-cross-namespace-restore/forbid-cross-namespace-restore.yaml
```

Apply only the Scope A (`[available]`) policies first if you are on Kasten v8.x.

## Switching from Audit to Enforce

Every policy defaults to `spec.validationFailureAction: Audit` (violations are
reported, not blocked) so the repo is safe to drop into any cluster. To block
non-compliant resources at admission time, set the field to `Enforce` on the
policy you want to enforce:

```
oc patch clusterpolicy require-policy-preset \
  --type merge -p '{"spec":{"validationFailureAction":"Enforce"}}'
```

Or edit the policy YAML (`spec.validationFailureAction: Enforce`) before
applying. Move policies to `Enforce` one at a time and only after the
`[unverified]` field paths have been confirmed for your Kasten version.

## Configuration

- **Sensitive-resource lists** (policies 2 and 4) are defined in a
  `sensitiveResources` context variable inside each policy (default: `secrets`).
  Edit that list, or replace the block with a ConfigMap lookup, e.g.:

  ```yaml
  context:
    - name: sensitiveResources
      apiCall:
        urlPath: "/api/v1/namespaces/kyverno/configmaps/kasten-sensitive-resources"
        jmesPath: "data.resources | parse_json(@)"
  ```

- **Cross-namespace allow-list** (policy 6) uses the annotation
  `veeamkasten.dev/allow-cross-namespace-restore: "true"`. Change the annotation
  key in the policy's `allowCrossNamespace` context variable to match your
  convention.

## Testing

Each policy folder contains generic good/bad test resources and a Kyverno CLI
test (`kyverno-test.yaml`). Run the whole suite from the repo root:

```
kyverno test .
```

Notes on the Scope B tests:

- DELETE-scoped rules (policy 5) simulate the operation with
  `globalValues: { request.operation: DELETE }` in a `values.yaml`.
- Policy 5's Profile `apiCall` is mocked offline by injecting `protectionPeriod`
  per resource in `values.yaml` (Kyverno CLI 1.18.1 has no `apiCallResponses`).
- Policy 4's validate and mutate rules are tested in **separate** directories
  (`.kyverno-test/` and `.kyverno-test-mutate/`) because, at admission, mutation
  runs before validation and would otherwise repair the resource before the
  validate rule evaluates it.

## Repository layout

```
<policy-name>/
  <policy-name>.yaml            # the ClusterPolicy
  .kyverno-test/
    kyverno-test.yaml           # Kyverno CLI test
    resources.yaml              # good/bad test resources
docs/
  RESEARCH.md                   # Phase 1 findings, field paths, open questions
```

## Annotations

Each policy carries the standard Kyverno annotations
(`policies.kyverno.io/title`, `category: Veeam Kasten`, `subject`,
`description`, `kyverno.io/kyverno-version`, `policies.kyverno.io/minversion`,
`kyverno.io/kubernetes-version`) plus custom markers:

- `veeamkasten.dev/scope`: `A` or `B`
- `veeamkasten.dev/availability`: `available-v8` or `preview-v9`
- `veeamkasten.dev/status`: `unverified` until confirmed against a live cluster

## References

- Upstream Kyverno Kasten policies: <https://github.com/kyverno/policies/tree/main/kasten>
- Kasten opt-out strategy: <https://veeamkasten.dev/implementing-opt-out-backup-strategy-with-kyverno> and <https://github.com/michaelcourcy/kasten-opt-out>
- Kasten API documentation: <https://docs.kasten.io/latest/api/>
- Kasten v9.0 announcement (admission control for Actions/RestorePoints, Preview)
