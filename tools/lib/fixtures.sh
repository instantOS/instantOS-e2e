# Credentials come from the same fixture injected into the guest.
fixture_answer() {
    python3 -c 'import sys, tomllib
with open(sys.argv[1], "rb") as f:
    print(tomllib.load(f)["answers"][sys.argv[2]])
' "$REPO_ROOT/assets/questions-$1.toml" "$2"
}

fixture_password() { fixture_answer "$1" Password; }
fixture_encryption_password() { fixture_answer "$1" EncryptionPassword; }
