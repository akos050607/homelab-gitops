#!/usr/bin/env python3
"""Turn a Keycloak partial-export into something worth committing.

A raw export is not a source file. It carries database identifiers that change
on every rebuild, the six clients Keycloak creates for itself, and a masked
client secret. Committing it as-is produces a diff nobody can review and a realm
that cannot be re-imported into a fresh database.

Three transformations, each with a reason:

1. Strip every `id` / `containerId`. They are database primary keys. A rebuilt
   realm generates new ones, so leaving them in means every export diffs against
   the last one even when nothing changed — and a diff that is always noisy is a
   diff nobody reads.

2. Drop Keycloak's own clients (account, admin-cli, broker, ...) and their roles.
   Keycloak creates them on realm creation. Importing them is at best redundant
   and at worst a conflict.

3. Put the placeholders back. Keycloak masks the client secret as `**********`
   on export; that is not the value, so committing it would silently break the
   next import. It is replaced with the marker the initContainer substitutes.
   The `users` block is carried over from the existing committed file, because
   partial-export omits users entirely and the demo user's password marker lives
   there.

Credentials are never exported and never written here. A registered passkey is
bound to one authenticator and exists only in the database — realm CONFIGURATION
is declarative; a user's enrolled credential is runtime state and cannot be.
"""
import json
import sys

BUILTIN_CLIENTS = {
    "account", "account-console", "admin-cli", "broker",
    "realm-management", "security-admin-console",
}
VOLATILE_KEYS = {"id", "containerId"}


def strip_volatile(node):
    if isinstance(node, dict):
        return {k: strip_volatile(v) for k, v in node.items() if k not in VOLATILE_KEYS}
    if isinstance(node, list):
        return [strip_volatile(v) for v in node]
    return node


def main(raw_path, current_yaml, out_path):
    realm = json.load(open(raw_path))

    realm = strip_volatile(realm)

    realm["clients"] = [c for c in realm.get("clients", [])
                        if c.get("clientId") not in BUILTIN_CLIENTS]

    roles = realm.get("roles", {})
    if isinstance(roles.get("client"), dict):
        roles["client"] = {k: v for k, v in roles["client"].items()
                           if k not in BUILTIN_CLIENTS}

    # Keycloak exports a masked secret. Restore the marker the initContainer
    # substitutes, so the committed realm stays importable.
    for c in realm["clients"]:
        if c.get("secret") in ("**********", "", None) and not c.get("publicClient", False):
            c["secret"] = "__OIDC_CLIENT_SECRET__"

    # partial-export omits users. Carry the block over from what is committed.
    import yaml
    current = yaml.safe_load(open(current_yaml))
    previous = json.loads(current["data"]["homelab-realm.json"])
    if "users" in previous:
        realm["users"] = previous["users"]

    # Guard: nothing that looks like a live secret may reach the repository.
    blob = json.dumps(realm)
    if "**********" in blob:
        sys.exit("refusing to write: a masked secret survived normalisation")

    json.dump(realm, open(out_path, "w"), indent=2, sort_keys=True, ensure_ascii=False)
    print(f"    clients kept : {[c['clientId'] for c in realm['clients']]}")
    print(f"    flows        : {len(realm.get('authenticationFlows', []))}")
    print(f"    browserFlow  : {realm.get('browserFlow')}")
    print(f"    users        : {[u['username'] for u in realm.get('users', [])]}")


if __name__ == "__main__":
    main(*sys.argv[1:4])
