# Prefer KVM when the host can open it and create a VM; keep TCG selectable.
kvm_available() {
    python3 - <<'PY'
import fcntl
import os
import sys

try:
    fd = os.open('/dev/kvm', os.O_RDWR | os.O_CLOEXEC)
    try:
        if fcntl.ioctl(fd, 0xAE00, 0) != 12:  # KVM_GET_API_VERSION
            sys.exit(1)
        vm = fcntl.ioctl(fd, 0xAE01, 0)  # KVM_CREATE_VM
        os.close(vm)
    finally:
        os.close(fd)
except OSError:
    sys.exit(1)
PY
}

configure_acceleration() {
    local mode=$1
    local -n accel_vars=$2 accel_args=$3
    if [ "$mode" != tcg ] && kvm_available; then
        accel_args+=(--device /dev/kvm)
        unset 'accel_vars[qemu_no_kvm]'
        echo 'VM acceleration: KVM' >&2
    elif [ "$mode" = kvm ]; then
        echo 'KVM requested but /dev/kvm is not usable; use --tcg for emulation' >&2
        return 2
    else
        # The caller supplies an associative array through this nameref.
        # shellcheck disable=SC2034,SC2154
        accel_vars[qemu_no_kvm]=1
        echo 'VM acceleration: TCG' >&2
    fi
}
