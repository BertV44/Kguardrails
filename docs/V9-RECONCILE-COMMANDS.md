# V9.0 reconciliation — cluster commands to run on the test cluster

This branch (`v9-admission-reconcile`) holds the prep for re-reconciling the
guardrail policies once the lab is upgraded to **Veeam Kasten v9.0**, which adds
*Admission Controller Policy Enforcement for Backup and Restore Operations*
(Tech Preview) — the path the current v8.5.12 lab cannot exercise.

Run the commands below on the test cluster **after** the v9.0 upgrade, then hand
the output back so the policies can be moved from `[preview]`/`unverified` to
verified. The fastest path is the dump script:

```bash
./scripts/kasten-v9-dump.sh > kasten-v9-dump.txt 2>&1
```

It is **read-only** by default. The end-to-end admission tests in §6 create and
delete objects and are therefore kept separate / commented — run them
deliberately.

Everything assumes you are logged in (`oc login --token=... --server=...`) with
cluster-admin and that Kasten is installed in `kasten-io`.

---

## 0. Gate: confirm this is actually v9.0 and admission is enabled

```bash
# Installed K10 version (was 8.5.12 on the old lab)
oc -n kasten-io get k10s.apik10.kasten.io -o jsonpath='{.items[*].spec.version}'; echo
# Cross-check via the gateway image tag
oc -n kasten-io get deploy -l component=gateway \
  -o jsonpath='{.items[*].spec.template.spec.containers[*].image}'; echo
```

If the version is not `9.x`, stop — the v9.0 admission path is not present yet.

## 1. The new bit — v9.0 admission webhooks / policies

The whole reason for this branch. Capture *how* v9.0 routes Actions and
RestorePoints through admission and which engine(s) are wired in (Kyverno / OPA
Gatekeeper / native ValidatingAdmissionPolicy).

```bash
# Kasten-native validating/mutating webhooks (were "(none)" on 8.5.12)
oc get validatingwebhookconfigurations -o name | grep -i kasten
oc get mutatingwebhookconfigurations   -o name | grep -i kasten
# Full rules: which apiGroups / resources / operations are intercepted
oc get validatingwebhookconfigurations -o yaml \
  | grep -iE 'name:|kasten|kio\.kasten|actions|restorepoint|operations|apiGroups|resources' 

# Native Validating Admission Policies (v8.0+ groundwork, may carry v9 rules)
oc get validatingadmissionpolicies.admissionregistration.k8s.io 2>/dev/null
oc get validatingadmissionpolicybindings.admissionregistration.k8s.io 2>/dev/null
oc get validatingadmissionpolicies.admissionregistration.k8s.io -o yaml 2>/dev/null

# Is Kyverno present and are ITS webhooks intercepting the Kasten CRDs?
oc get pods -A | grep -i kyverno
oc get validatingwebhookconfigurations -o name | grep -i kyverno
```

> Goal: confirm that DELETE on `apps.kio.kasten.io/*` and CREATE/UPDATE on
> `actions.kio.kasten.io/*` are actually admitted through a webhook in v9.0.
> This is the precondition for every Scope B policy (3, 4, 5, 6) to enforce.

## 2. Served CRD versions and full schemas (catch new API points)

v9.0 may add fields or bump served versions. Re-capture the recursive schemas and
diff against `docs/RESEARCH.md` §4.

```bash
oc get crd -o custom-columns='NAME:.metadata.name,VERSIONS:.spec.versions[*].name' \
  | grep kasten.io

for crd in \
  policies.config.kio.kasten.io \
  policypresets.config.kio.kasten.io \
  profiles.config.kio.kasten.io \
  backupactions.actions.kio.kasten.io \
  restoreactions.actions.kio.kasten.io \
  runactions.actions.kio.kasten.io \
  restorepoints.apps.kio.kasten.io \
  restorepointcontents.apps.kio.kasten.io ; do
    echo "===== oc explain $crd --recursive ====="
    oc explain "$crd" --recursive
done
```

## 3. Close policy 4 — populated `RestoreAction.spec.filters`

On 8.5.12 no object ever populated `spec.filters.excludeResources`, so the exact
sub-key shape (`excludeResources[].resource` vs `.group/.version/...`) is still
unconfirmed. Trigger a restore **with resource exclusions** from the K10 UI/API,
then capture the live shape:

```bash
oc get restoreactions.actions.kio.kasten.io -A -o yaml | sed -n '1,200p'
# Just the filters block per action:
oc get restoreactions.actions.kio.kasten.io -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\t"}{.spec.filters}{"\n"}{end}'
```

> Compare the populated shape to the JMESPath in
> `exclude-sensitive-on-restore.yaml`
> (`spec.filters.excludeResources[].resource`). Adjust and lift `unverified`.

## 4. Close policy 5 — profile resolution + status on v9

Two unknowns from 8.5.12 to re-check on v9:

```bash
# (a) Do RP/RPC now expose originatingPolicies / artifacts in status on v9?
oc get restorepointcontents.apps.kio.kasten.io -A -o yaml | sed -n '1,200p'
oc get restorepoints.apps.kio.kasten.io        -A -o yaml | sed -n '1,160p'

# (b) Policy export schema: confirm the label -> Policy -> Profile chain
#     (spec.actions[].exportParameters.profile.{name,namespace}).
oc -n kasten-io get policies.config.kio.kasten.io -o yaml | sed -n '1,200p'

# (c) Profile immutability path: confirm spec.locationSpec.objectStore vs
#     spec.export.location.objectStore, and where protectionPeriod actually sits.
oc -n kasten-io get profiles.config.kio.kasten.io -o yaml | sed -n '1,160p'
oc explain profiles.config.kio.kasten.io.spec --recursive | grep -i -B2 protectionPeriod
```

> If v9 populates `status.*.originatingPolicies` / `artifacts[].meta.*.profileRef`,
> the original status-based design can be restored. If not, implement the
> label → Policy(`exportParameters.profile`) → Profile(`protectionPeriod`) apiCall
> chain confirmed by (b)+(c).

## 5. Re-capture labels (manual vs policy-managed) on v9

Confirm the `k10.kasten.io/policyName` discriminator still holds for Actions and
RestorePoints, and capture a **manual BackupAction/RunAction** (absent on 8.5.12).

```bash
for k in backupactions runactions restoreactions ; do
  echo "===== $k ====="; oc get "$k.actions.kio.kasten.io" -A --show-labels
done
oc get restorepoints.apps.kio.kasten.io       -A --show-labels
oc get restorepointcontents.apps.kio.kasten.io -A --show-labels
```

## 6. End-to-end admission tests (OPTIONAL — these mutate the cluster)

Only run deliberately, on a throwaway namespace. Each should be **denied** by the
matching policy once it is switched to `Enforce` (default is `Audit`).

```bash
# Policy 3 — manual BackupAction without spec.expiresAt should be denied.
# Policy 6 — RestoreAction with spec.targetNamespace != spec.subject.namespace denied.
# Policy 5 — oc delete restorepoint/<immutable, policy-managed> should be denied.
# Author these as small YAML manifests and `oc apply` / `oc delete` them, then
# check `oc get events` and the Kyverno PolicyReports:
oc get policyreports,clusterpolicyreports -A 2>/dev/null
```

---

## When the output is back

1. Diff schemas against `docs/RESEARCH.md` §4; update field paths.
2. Lift `unverified` on policy 4 and the v8.x limitation note on policy 5.
3. Flip `veeamkasten.dev/availability` to `available-v9` where the admission path
   is confirmed present.
4. `kyverno test .` must stay green; add cases reflecting any new shapes.
5. Open the PR from `v9-admission-reconcile` into `main`.
