# Explicit overrides shared by the installer and diagnostic entry points.
# Context-specific exceptions preserve credentials for existing disks and UEFI
# live-session diagnostics without changing installation flow contracts.
validate_override() {
    local context=$1 key=${2%%=*}
    [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
        echo "Invalid variable: $key" >&2; return 2;
    }
    case "$context:${key^^}" in
        *:QEMUCPUS|*:QEMURAM|*:HDDSIZEGB|*:STORAGE_KEEP_FREE_GB|\
        verifydisk:PASSWORD|bootcap:PASSWORD|verifydisk:ENCRYPTION_PASSWORD|bootcap:ENCRYPTION_PASSWORD|liveiso:UEFI) return 0 ;;
    esac
    echo "Unsupported override: $key; use runner flags for scenario settings" >&2
    return 2
}
