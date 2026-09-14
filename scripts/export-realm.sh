#!/usr/bin/env bash
#
# Exports the live `homelab` realm back over identity/04-keycloak-realm.yaml.
#
# ADR-008 records the weakness this exists to manage: `--import-realm` is
# one-shot, so configuration done in the admin console lives only in Postgres
# until it is exported. An export that is a manual clean-up gets done once and
# then rots. This makes it one command with a reviewable diff.
#
#   ./scripts/export-realm.sh            # rewrite the ConfigMap
#   ./scripts/export-realm.sh --dry-run  # print the diff and change nothing
#
# Requires kubectl pointed at the cluster. Reads the admin credential from the
# Secret the SealedSecret decrypted into; nothing is prompted for and nothing is
# written to disk outside the repository.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$ROOT/identity/04-keycloak-realm.yaml"
KC="${KC_URL:-https://auth.szenassy-akos.com}"
REALM="${KC_REALM:-homelab}"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "==> reading admin credential from the cluster"
USER_NAME="$(kubectl -n identity get secret keycloak-bootstrap-admin -o jsonpath='{.data.username}' | base64 -d)"
PASS="$(kubectl -n identity get secret keycloak-bootstrap-admin -o jsonpath='{.data.password}' | base64 -d)"

echo "==> authenticating against $KC"
TOKEN="$(curl -sSf --max-time 30 \
  -d client_id=admin-cli -d grant_type=password \
  -d "username=$USER_NAME" --data-urlencode "password=$PASS" \
  "$KC/realms/master/protocol/openid-connect/token" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["access_token"])')"

echo "==> partial-export of realm '$REALM'"
curl -sSf --max-time 60 -X POST -H "Authorization: Bearer $TOKEN" \
  "$KC/admin/realms/$REALM/partial-export?exportGroupsAndRoles=true&exportClients=true" \
  > "$TMP/raw.json"

echo "==> normalising"
python3 "$ROOT/scripts/normalise-realm.py" "$TMP/raw.json" "$TARGET" "$TMP/realm.json"

python3 - "$TARGET" "$TMP/realm.json" <<'PY'
import json, sys, io
target, realm_file = sys.argv[1], sys.argv[2]
realm = open(realm_file).read().rstrip("\n")

header = []
for line in open(target):
    header.append(line)
    if line.startswith("data:"):
        break
body = "".join(header) + "  homelab-realm.json: |\n"
body += "".join("    " + l + "\n" for l in realm.split("\n"))
open(realm_file + ".yaml", "w").write(body)
PY

if [ "$DRY" = 1 ]; then
  diff -u "$TARGET" "$TMP/realm.json.yaml" || true
  echo "==> dry run, nothing written"
  exit 0
fi

cp "$TMP/realm.json.yaml" "$TARGET"
echo "==> wrote $TARGET"
echo
git -C "$ROOT" --no-pager diff --stat -- "$TARGET" || true
echo
echo "Review the diff, then run ./scripts/validate.sh before committing."
