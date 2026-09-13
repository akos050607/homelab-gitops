#!/usr/bin/env bash
#
# Validates every manifest in this repository. CI runs THIS FILE — the workflow
# only sets up a runner and calls it — so a green run on a laptop means a green
# run in Actions.
#
#   ./scripts/validate.sh            # all four checks
#   ./scripts/validate.sh lint       # just one
#
# Requires ./scripts/install-tools.sh to have been run first.
#
# This repo is reconciled by Argo CD with selfHeal enabled, so whatever lands on
# main is deployed. Nothing here deploys anything — these are gates, not steps.
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BIN="$ROOT/bin"
VENV="$ROOT/.venv"
RENDER_DIR="$ROOT/.render"

# The Kubernetes version to validate against. Pin this to the cluster's actual
# minor version — validating against a release you do not run proves nothing.
#   kubectl version -o json | jq -r .serverVersion.gitVersion
K8S_VERSION="${K8S_VERSION:-1.33.0}"

# Schemas for the built-in API plus a catalog covering the CRDs this repo uses:
# Argo CD Application, cert-manager ClusterIssuer, Bitnami SealedSecret, and the
# Prometheus operator kinds that kube-prometheus-stack renders.
CRD_SCHEMAS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

MANIFESTS=(root-app.yaml apps/*.yaml identity/*.yaml)

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
head_() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

FAILED=()

require_tools() {
  local missing=0
  for t in "$BIN/kubeconform" "$BIN/yq" "$VENV/bin/yamllint"; do
    [ -x "$t" ] || { red "missing: $t"; missing=1; }
  done
  command -v helm >/dev/null || { red "missing: helm"; missing=1; }
  if [ "$missing" -ne 0 ]; then
    red "run ./scripts/install-tools.sh first"
    exit 127
  fi
}

# -----------------------------------------------------------------------------
# lint — YAML well-formedness and style. Catches tabs, bad indentation, trailing
# whitespace, duplicate keys (which silently override in YAML) and implicit
# octals. Configured in .yamllint.yml.
# -----------------------------------------------------------------------------
check_lint() {
  head_ "lint · yamllint"
  if "$VENV/bin/yamllint" -c .yamllint.yml -f parsable \
        "${MANIFESTS[@]}" .yamllint.yml .github/workflows/*.yml; then
    green "  no findings"
  else
    red "  yamllint failed"; FAILED+=("lint")
  fi
}

# -----------------------------------------------------------------------------
# validate — schema-check every manifest against the Kubernetes API, including
# the CRDs. `-strict` rejects unknown fields, which is what turns `replias:`
# from a silently ignored key into a build failure.
# -----------------------------------------------------------------------------
check_validate() {
  head_ "validate · kubeconform (k8s $K8S_VERSION, strict)"
  if "$BIN/kubeconform" \
        -strict -summary -output pretty \
        -kubernetes-version "$K8S_VERSION" \
        -schema-location default \
        -schema-location "$CRD_SCHEMAS" \
        "${MANIFESTS[@]}"; then
    green "  all manifests valid"
  else
    red "  kubeconform failed"; FAILED+=("validate")
  fi
}

# -----------------------------------------------------------------------------
# render — three manifests are Argo CD Applications that reference a Helm chart
# and carry a values block as an opaque string. `validate` checks the
# Application wrapper and never looks inside that string, so this check renders
# each chart with its real values and schema-checks the result.
#
# What this DOES catch (verified, not assumed):
#   - malformed YAML inside the values block          -> helm fails
#   - values that break template rendering            -> helm fails
#   - values producing structurally invalid objects   -> kubeconform fails
#   - a targetRevision range matching no chart version-> helm fails
#
# What it does NOT catch: a misspelled key the chart simply ignores. Helm has no
# strict-values mode, and even charts shipping values.schema.json (Loki does)
# accept unknown keys and loose types. Tested: `totallyBogusKey: 42` and
# `replicas: "three"` both render clean. Worth knowing the limit of your own gate.
#
# CustomResourceDefinition is skipped, and the reason is a real gap rather than a
# convenience: kubernetes-json-schema publishes no schema for the kind at all
# (every variant of customresourcedefinition*.json is a 404 upstream), so
# kubeconform reports `could not find schema` for any chart that templates its
# CRDs. The cloudnative-pg chart renders 11 of them and is the first chart here
# to do so — kube-prometheus-stack ships its CRDs in `crds/`, which `helm
# template` skips entirely, so the repo never hit this before.
#
# Skipping the definitions costs little: a CRD is itself a schema, authored
# upstream, not by this repository. What matters is that the custom resources
# written HERE are checked, and they are — `validate` runs the CNPG `Cluster` at
# identity/03 against the CRDs-catalog schema. The gap is that a malformed CRD
# shipped by a chart would reach the cluster unflagged.
# -----------------------------------------------------------------------------
check_render() {
  head_ "render · helm template -> kubeconform"
  rm -rf "$RENDER_DIR"; mkdir -p "$RENDER_DIR"
  local found=0 failed=0

  for f in "${MANIFESTS[@]}"; do
    [ -f "$f" ] || continue
    while IFS=$'\t' read -r name repo chart version ns; do
      [ -n "${name:-}" ] || continue
      found=$((found + 1))
      local values="$RENDER_DIR/${name}.values.yaml"
      local out="$RENDER_DIR/${name}.rendered.yaml"

      "$BIN/yq" eval-all \
        "select(.kind == \"Application\" and .metadata.name == \"$name\") | .spec.source.helm.values // \"\"" \
        "$f" > "$values"

      printf '  %-22s %s %s\n' "$name" "$chart" "$version"
      if helm template "$name" "$chart" \
            --repo "$repo" --version "$version" \
            --namespace "${ns:-default}" \
            -f "$values" > "$out" 2> "$RENDER_DIR/${name}.err"; then
        :
      else
        red "    helm template failed:"
        sed 's/^/      /' "$RENDER_DIR/${name}.err" | head -20
        failed=1
        continue
      fi
      # Surface chart-level warnings (e.g. deprecation) without failing on them.
      if [ -s "$RENDER_DIR/${name}.err" ]; then
        sed 's/^/      note: /' "$RENDER_DIR/${name}.err" | head -5
      fi
    done < <("$BIN/yq" eval-all \
        'select(.kind == "Application" and .spec.source.chart != null)
         | [.metadata.name, .spec.source.repoURL, .spec.source.chart,
            .spec.source.targetRevision, (.spec.destination.namespace // "default")]
         | @tsv' "$f" 2>/dev/null | grep -v '^$')
  done

  if [ "$found" -eq 0 ]; then
    red "  no chart-backed Applications found — extraction is broken"
    FAILED+=("render"); return
  fi

  if [ "$failed" -eq 0 ]; then
    echo "  validating rendered output..."
    if "$BIN/kubeconform" \
          -strict -summary -output pretty \
          -kubernetes-version "$K8S_VERSION" \
          -schema-location default \
          -schema-location "$CRD_SCHEMAS" \
          -skip CustomResourceDefinition \
          "$RENDER_DIR"/*.rendered.yaml; then
      green "  $found chart(s) rendered and valid"
      return
    fi
  fi
  red "  render failed"; FAILED+=("render")
}

# -----------------------------------------------------------------------------
# policy — invariants this repository claims about itself, enforced rather than
# remembered. The repo is public and the whole point of Sealed Secrets is that
# nothing readable is ever committed; that should not depend on vigilance.
# -----------------------------------------------------------------------------
check_policy() {
  head_ "policy · repository invariants"
  local bad=0

  # (1) No plaintext Secret, ever. Uses yq rather than grep so that the word
  #     "Secret" appearing inside a SealedSecret or a comment is not a hit.
  echo "  [1] no plaintext Secret objects"
  for f in "${MANIFESTS[@]}"; do
    [ -f "$f" ] || continue
    local hit
    hit="$("$BIN/yq" eval-all \
      'select(.kind == "Secret") | .metadata.name // "unnamed"' "$f" 2>/dev/null | grep -v '^$' || true)"
    if [ -n "$hit" ]; then
      red "      $f contains a plaintext Secret: $hit"
      red "      commit a SealedSecret instead (kubeseal --format=yaml < secret.yaml)"
      bad=1
    fi
  done

  # (2) No placeholder text. Same idea as the `verify:clean` guard on the CV
  #     site: a template value that reaches production is a defect, and the
  #     cheapest place to catch it is before merge.
  echo "  [2] no placeholder text"
  local patterns='REPLACE THIS|CHANGEME|your-actual-email|PLACEHOLDER|example\.com|<your-'
  local hits
  hits="$(grep -nEI "$patterns" "${MANIFESTS[@]}" 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    echo "$hits" | sed 's/^/      /' | while read -r l; do red "$l"; done
    bad=1
  fi

  if [ "$bad" -eq 0 ]; then green "  invariants hold"; else FAILED+=("policy"); fi
}

# -----------------------------------------------------------------------------

require_tools

case "${1:-all}" in
  lint)     check_lint ;;
  validate) check_validate ;;
  render)   check_render ;;
  policy)   check_policy ;;
  all)      check_lint; check_validate; check_render; check_policy ;;
  *) echo "usage: $0 [all|lint|validate|render|policy]" >&2; exit 2 ;;
esac

echo
if [ "${#FAILED[@]}" -eq 0 ]; then
  green "PASS"
  exit 0
fi
red "FAIL: ${FAILED[*]}"
exit 1
