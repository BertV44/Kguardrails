#!/usr/bin/env bash
#
# kasten-v9-dump.sh — read-only reconnaissance dump for the Veeam Kasten v9.0
# reconciliation (see docs/V9-RECONCILE-COMMANDS.md).
#
# Usage:
#   oc login --token=... --server=https://api.<cluster>:6443
#   ./scripts/kasten-v9-dump.sh > kasten-v9-dump.txt 2>&1
#
# READ-ONLY: only `oc get` / `oc explain`. No object is created, mutated or
# deleted. Safe to run on the test cluster. Hand the output back to close
# policies 4 and 5 and to verify the v9.0 admission path.

set -uo pipefail
NS="${KASTEN_NS:-kasten-io}"

hr() { echo; echo "===== $* ====="; }

echo "# Kasten v9 reconcile dump - $(date -u) - $(oc whoami 2>/dev/null) @ $(oc whoami --show-server 2>/dev/null)"

hr "0. VERSION GATE"
oc -n "$NS" get k10s.apik10.kasten.io -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.version}{"\n"}{end}' 2>&1
echo "gateway image(s):"
oc -n "$NS" get deploy -l component=gateway \
  -o jsonpath='{range .items[*]}{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}{end}' 2>&1

hr "1. ADMISSION WEBHOOKS / POLICIES (the v9.0 new bit)"
echo "--- Kasten validating webhooks ---"
oc get validatingwebhookconfigurations -o name 2>&1 | grep -i kasten || echo "(none)"
echo "--- Kasten mutating webhooks ---"
oc get mutatingwebhookconfigurations -o name 2>&1 | grep -i kasten || echo "(none)"
echo "--- Kyverno webhooks ---"
oc get validatingwebhookconfigurations -o name 2>&1 | grep -i kyverno || echo "(none)"
echo "--- ValidatingAdmissionPolicies ---"
oc get validatingadmissionpolicies.admissionregistration.k8s.io 2>&1 || true
oc get validatingadmissionpolicybindings.admissionregistration.k8s.io 2>&1 || true
echo "--- webhook rules touching kasten CRDs ---"
oc get validatingwebhookconfigurations -o yaml 2>&1 \
  | grep -iE 'name:|kio\.kasten|actions|restorepoint|operations:|apiGroups:|resources:' || true

hr "2. CRD VERSIONS + RECURSIVE SCHEMAS"
oc get crd -o custom-columns='NAME:.metadata.name,VERSIONS:.spec.versions[*].name' 2>&1 | grep kasten.io
for crd in \
  policies.config.kio.kasten.io \
  policypresets.config.kio.kasten.io \
  profiles.config.kio.kasten.io \
  backupactions.actions.kio.kasten.io \
  restoreactions.actions.kio.kasten.io \
  runactions.actions.kio.kasten.io \
  restorepoints.apps.kio.kasten.io \
  restorepointcontents.apps.kio.kasten.io ; do
    hr "oc explain $crd --recursive"
    oc explain "$crd" --recursive 2>&1
done

hr "3. POLICY 4 - RestoreAction.spec.filters (need a populated example)"
oc get restoreactions.actions.kio.kasten.io -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\tfilters="}{.spec.filters}{"\n"}{end}' 2>&1
echo "--- full RestoreActions ---"
oc get restoreactions.actions.kio.kasten.io -A -o yaml 2>&1 | sed -n '1,200p'

hr "4. POLICY 5 - RP/RPC status, Policy export schema, Profile immutability"
echo "--- RestorePointContents (check status.*.originatingPolicies / artifacts) ---"
oc get restorepointcontents.apps.kio.kasten.io -A -o yaml 2>&1 | sed -n '1,200p'
echo "--- RestorePoints ---"
oc get restorepoints.apps.kio.kasten.io -A -o yaml 2>&1 | sed -n '1,160p'
echo "--- Policies (spec.actions[].exportParameters.profile) ---"
oc -n "$NS" get policies.config.kio.kasten.io -o yaml 2>&1 | sed -n '1,200p'
echo "--- Profiles (locationSpec vs export.location + protectionPeriod) ---"
oc -n "$NS" get profiles.config.kio.kasten.io -o yaml 2>&1 | sed -n '1,160p'

hr "5. LABELS (manual vs policy-managed)"
for k in backupactions runactions restoreactions ; do
  echo "--- $k ---"
  oc get "$k.actions.kio.kasten.io" -A --show-labels 2>&1
done
oc get restorepoints.apps.kio.kasten.io        -A --show-labels 2>&1
oc get restorepointcontents.apps.kio.kasten.io -A --show-labels 2>&1

hr "6. POLICY REPORTS (Kyverno audit results, if any)"
oc get policyreports,clusterpolicyreports -A 2>&1 || echo "(none)"

echo
echo "# END"
