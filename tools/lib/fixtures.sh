# Credentials come from the same fixture injected into the guest.
fixture_password() {
    python3 -c 'import sys, tomllib
with open(sys.argv[1], "rb") as f:
    print(tomllib.load(f)["answers"]["Password"])
' "$REPO_ROOT/assets/questions-$1.toml"
}
