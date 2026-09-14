# homelab-gitops

Declarative state for a hybrid k3s cluster — a Hetzner CX33 control plane and a
physical edge node joined over a Tailscale mesh. **Argo CD reconciles this
repository into the cluster. Nothing here is applied by hand.**

The cluster itself is provisioned from
[`homelab-platform`](https://github.com/akos050607/homelab-platform), which
holds the Terraform, the architecture decision records, and the chaos log.

## Layout

| Path | What it is |
|---|---|
| `root-app.yaml` | The app-of-apps. Argo CD watches `apps/` from here. Applied once, at bootstrap. |
| `apps/namespace-monitoring.yaml` | The `monitoring` namespace, with `sync-wave: "-1"` so it exists before anything lands in it. |
| `apps/monitoring.yaml` | kube-prometheus-stack (Prometheus, Grafana, node-exporter, kube-state-metrics) as a Helm-backed Application. Alertmanager is disabled — there is nobody to page. |
| `apps/loki.yaml` | Loki in `SingleBinary` mode with filesystem storage — the distributed read/write/backend split is pure overhead on one 8 GB node. |
| `apps/promtail.yaml` | Promtail DaemonSet shipping container logs to Loki. |
| `apps/cluster-issuer-{prod,staging}.yaml` | cert-manager ACME issuers for Let's Encrypt. |
| `apps/sealed-{database-secret,grafana-admin}.yaml` | Sealed Secrets. Ciphertext only — see *Invariants*. |
| `apps/cnpg-operator.yaml` | CloudNativePG, the Postgres operator backing Keycloak. Its own namespace because it is cluster-scoped and installs CRDs. |
| `apps/identity.yaml` | The identity stack as one Argo CD Application, reading `identity/`. One health rollup, one sync unit. |
| `identity/` | Keycloak, its database, the realm, and the OIDC client application. Numbered files; the numbers are the sync order. |
| `identity/10-oidc-demo.yaml` | The relying party at `app.szenassy-akos.com`. Image pinned to the commit that built it, never `latest`, and no service account token mounted — it has no reason to reach the API. |
| `apps/demo-hpa.yaml` | A demo workload: Deployment, Service, TLS Ingress and an HPA (min 2 / max 8, 50% CPU). The Deployment deliberately declares **no** `replicas` — the HPA owns that field. |
| `apps/test-app.yaml` | The original hand-deployed nginx demo, kept as the example of Argo CD adopting an existing live object. |

## How a change reaches the cluster

```
branch ──► pull request ──► 4 CI checks ──► squash-merge to main
                                                    │
                                                    ▼
                                        Argo CD (automated sync,
                                         prune: true, selfHeal: true)
                                                    │
                                                    ▼
                                                 cluster
```

`main` is branch-protected and direct pushes are rejected. That is deliberate:
with `selfHeal: true`, an unreviewed push is applied within minutes and cannot
be undone with `kubectl` — Argo CD simply puts it back. The gate is not there to
stop a colleague; it is there because a bad merge is a live incident.

**CI validates. It never deploys.** No job in this repository holds a cluster
credential, and the Kubernetes API server is not reachable from the internet
anyway. Delivery is Argo CD pulling, not a pipeline pushing.

## Invariants this repository enforces on itself

1. **Only SealedSecrets are committed — never a plaintext `Secret`.**
2. **No placeholder text reaches `main`.**
3. Every manifest schema-validates against the Kubernetes API *and* the CRDs in
   use (Argo CD, cert-manager, Sealed Secrets, Prometheus operator).
4. Every Helm-backed Application renders successfully with its own values block.

Invariant 1 is the one worth dwelling on. A plaintext `Secret` is a *perfectly
schema-valid* manifest — `kubeconform` passes it without complaint. Schema
validation is a correctness control, not a security control, so the guard that
catches it is a separate check.

## The four checks

| Check | Catches | What the others miss |
|---|---|---|
| `lint` | Malformed YAML, tabs, bad indentation, trailing whitespace, **duplicate keys** (which silently override in YAML), implicit octals. | — |
| `validate` | Wrong `apiVersion`, misspelled or unknown fields, wrong types, missing required fields — in core kinds *and* CRs. | Only sees committed YAML. |
| `render` | Values that break a chart. | The `helm.values` block is an opaque **string**: `lint` never parses it and `validate` sees a valid string. Only rendering the chart looks inside. |
| `policy` | A plaintext `Secret`; placeholder text. | Both are schema-valid, so `validate` passes them. |

### What `render` does and does not catch

Verified by deliberately breaking each case, rather than assumed:

**Catches** — malformed YAML inside the values block; values that break template
rendering; values that produce structurally invalid Kubernetes objects (the
rendered output is fed back through `kubeconform`); a `targetRevision` range
matching no published chart version.

**Does not catch** — a misspelled key the chart simply ignores. Helm has no
strict-values mode, and even charts shipping a `values.schema.json` (Loki does)
accept unknown keys and loose types: `totallyBogusKey: 42` and
`replicas: "three"` both render clean. Worth knowing the limit of your own gate.

**Also does not catch — a malformed `CustomResourceDefinition` shipped by a
chart.** `kubernetes-json-schema` publishes no schema for that kind at all; every
variant of `customresourcedefinition*.json` is a 404 upstream, so kubeconform
answers `could not find schema` for any chart that templates its CRDs. The
cloudnative-pg chart renders eleven of them and was the first chart here to hit
it — kube-prometheus-stack ships its CRDs in `crds/`, which `helm template` skips
entirely. The kind is therefore explicitly skipped in `render`, which is honest
about the gap rather than hiding it behind `-ignore-missing-schemas`. Custom
resources written *in this repository* are still checked: `validate` runs the
CNPG `Cluster` at `identity/03-keycloak-db.yaml` against the CRDs-catalog schema.

## Running the checks locally

CI runs the same script this does — the workflow only sets up a runner and calls
it, so a green run here means a green run in Actions.

```bash
./scripts/install-tools.sh      # pinned kubeconform, yq, yamllint
./scripts/validate.sh           # all four checks
./scripts/validate.sh render    # or just one
```

Tool versions are pinned in `scripts/install-tools.sh` and installed into a
gitignored `bin/` and `.venv/`, so the laptop and the runner are on identical
versions.

`K8S_VERSION` (default `1.33.0`) sets the API version to validate against. Pin
it to the cluster's actual minor — validating against a release you do not run
proves nothing.

## Supply chain

`permissions: contents: read` on every job; `persist-credentials: false` so the
checkout token is never written into `.git/config`; runner pinned to
`ubuntu-24.04` rather than `ubuntu-latest`, and `helm` pinned rather than
inherited from the runner image.

Actions are pinned to major-version tags for consistency across these repos.
Tags are mutable — someone who compromises an action's repository can repoint
`v5` — so commit-SHA pinning is the hardened option. That trade is deliberate
here, and would go the other way for any workflow handling credentials.

## Identity

Keycloak at `auth.szenassy-akos.com`, backed by a CloudNativePG Postgres, with the
`homelab` realm imported from `identity/04-keycloak-realm.yaml`.

**No credential in this stack is authored by hand and committed.** The database
password is generated by the CNPG operator into `keycloak-db-app` and read with a
`secretKeyRef` — it exists nowhere in git, sealed or otherwise. The two values the
realm genuinely needs (the confidential client's secret, and the demo user's
initial password) are sealed at `identity/02`, and substituted into the realm JSON
by an initContainer before Keycloak opens the file.

The realm file is **generated, not hand-written**: `./scripts/export-realm.sh`
pulls the live realm back over `identity/04-keycloak-realm.yaml` and
`scripts/normalise-realm.py` makes it reviewable — stripping database
identifiers that change on every rebuild, dropping the six clients Keycloak
creates for itself, and restoring the placeholders. Keycloak masks secrets as
`**********` on export, and the normaliser refuses to write a file where that
mask survived, because committing it would silently break the next import.

This matters because of the limitation in *Known limitations* below: a one-shot
import means console changes live only in Postgres until exported, and an export
that is a manual clean-up gets done once and then rots. Verified by importing the
committed file into a throwaway realm and confirming it reproduces the
passwordless flow, the WebAuthn policy and the flow bindings from scratch.

What is **not** in git, and cannot be: the registered passkey. A WebAuthn
credential is bound to one authenticator and lives only in the database. Realm
*configuration* is declarative; an enrolled credential is runtime state.

That initContainer exists because **Keycloak's realm import performs no variable
substitution**: a `$` in the file is ignored, and `kc.sh import` rejects one
outright with `Character '$' not allowed` (keycloak/keycloak#12069, #20199). Only
the Operator's `spec.placeholders` does it natively. So the substitution happens
one step earlier, into an `emptyDir` that only that pod can read. What is
committed is the literal string `__OIDC_CLIENT_SECRET__`, and the initContainer
fails the pod if any placeholder survives — importing a realm whose admin password
is the literal text `__DEMO_USER_PASSWORD__` is a failure that should be loud.

## Known limitations

- `targetRevision: HEAD` — Argo CD tracks the branch tip with no promotion step
  between merge and deploy. There is no staging cluster to promote through.
- The chart ranges (`77.*`, `6.*`) float independently of git: CI can validate
  what resolves today, but Argo CD may sync a newer patch tomorrow with no
  commit. Pinning exact versions is the fix; the trade is manual patch bumps.
- kube-prometheus-stack is on `77.x` while upstream has moved well past it.
- The promtail chart is **deprecated upstream** in favour of Grafana Alloy —
  surfaced by the `render` check, which prints the chart's own warning.
- **The realm import is one-shot, not reconciling.** `--import-realm` imports only
  when the realm is *absent*; editing `identity/04-keycloak-realm.yaml` does not
  update a live realm. Argo CD will faithfully report the ConfigMap as Synced
  while the running realm differs from it — the same silent-divergence class as
  two controllers owning one field. The Keycloak Operator's `KeycloakRealmImport`
  reconciles properly and is the upgrade path; the trade is recorded in ADR-008.
- **Keycloak starts non-optimized.** `start --optimized` requires an image built
  with `kc.sh build --db=postgres`; the stock image has not been, so every cold
  start pays a ~40–60s augmentation step, and `readOnlyRootFilesystem` cannot be
  enabled because that step writes into the image filesystem. Building a
  purpose-built image in the GHCR pipeline fixes both at once.
- **One database instance, which is availability of zero.** A replica would not
  help: `local-path` is node-local, so both copies would sit on the same machine.
  Real HA needs storage that is not tied to one node.
- **CI is advisory.** It gates the repository, not the cluster: anyone with
  cluster access can still `kubectl apply` a plaintext Secret directly.
  Enforcement of that class of rule belongs in admission control — Kyverno or
  Gatekeeper — which is the obvious next layer and is not built here.
