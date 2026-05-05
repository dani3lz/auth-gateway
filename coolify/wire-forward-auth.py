#!/usr/bin/env python3
"""
Append (or replace) traefik forward-auth labels on the supabase-studio service.
Usage: wire-forward-auth.py <SUPABASE_UUID> <VALIDATOR_UUID> <AUTH_HOST>
"""
import sys
import yaml

if len(sys.argv) != 4:
    sys.stderr.write(__doc__)
    sys.exit(2)
SUPA, VAL, AUTH_HOST = sys.argv[1], sys.argv[2], sys.argv[3]
PATH = f"/data/coolify/services/{SUPA}/docker-compose.yml"

with open(PATH) as f:
    d = yaml.safe_load(f)

studio = d["services"]["supabase-studio"]
labels = studio.get("labels", {})
if isinstance(labels, list):
    labels = {l.split("=", 1)[0]: l.split("=", 1)[1] for l in labels if "=" in l}

# Strip any prior auth middlewares we manage
for k in list(labels):
    if any(s in k for s in (
        "studio-basicauth",
        "authelia",
        "authentik",
        "auth-gateway",
    )):
        del labels[k]

verify_addr = f"http://validator-{VAL}:8080/verify"

labels["traefik.http.middlewares.auth-gateway.forwardauth.address"] = verify_addr
labels["traefik.http.middlewares.auth-gateway.forwardauth.trustForwardHeader"] = "true"
labels["traefik.http.middlewares.auth-gateway.forwardauth.authResponseHeaders"] = (
    "X-User-Id,X-User-Email,X-User-Role"
)
labels[f"traefik.http.routers.http-0-{SUPA}-supabase-studio.middlewares"] = (
    "redirect-to-https,auth-gateway"
)
labels[f"traefik.http.routers.https-0-{SUPA}-supabase-studio.middlewares"] = (
    "gzip,auth-gateway"
)

studio["labels"] = labels
with open(PATH, "w") as f:
    yaml.safe_dump(d, f, default_flow_style=False, sort_keys=False, width=999)
print(f"wired forward-auth on {PATH} -> {verify_addr}")
