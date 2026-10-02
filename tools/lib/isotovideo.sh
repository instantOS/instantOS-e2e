# Common lifecycle for installer and diagnostic harnesses.
# Upstream retains rolling tags, not historical digests. Resolve once per process
# so installation and standalone verification use the same backend even if the
# tag changes during a run. A failed pull is fatal, never a stale-cache fallback.
ISOTOVIDEO_TAG=registry.opensuse.org/devel/openqa/containers/isotovideo:qemu-x86
ISOTOVIDEO_IMAGE=''

resolve_isotovideo() {
    [ -z "$ISOTOVIDEO_IMAGE" ] || return 0
    docker pull "$ISOTOVIDEO_TAG" || return
    local resolved
    resolved=$(docker image inspect --format '{{.Id}}' "$ISOTOVIDEO_TAG") || return
    [[ $resolved =~ ^sha256:[0-9a-f]{64}$ ]] || {
        echo 'Could not resolve isotovideo image ID' >&2; return 1;
    }
    docker image inspect --format 'isotovideo: {{json .RepoDigests}} ({{.Id}})' "$resolved" || return
    ISOTOVIDEO_IMAGE=$resolved
}

# One VM per checkout: main and diagnostics share needles, images and results.
lock_suite() {
    exec 8>"$REPO_ROOT/.e2e.lock"
    flock -n 8 || { echo 'Another VM run is using this checkout' >&2; exit 1; }
}

# Both cleanup and input protection use this list.
HARNESS_STATE=(
    testresults raid ulogs vars.json serial0 virtio_console.log
    virtio_console_user.log video.ogv video_time.vtt qmp_socket.log
    autoinst-status.json backend.run base_state.json command-server-tmp
    os-autoinst.pid qemu.pid qemu_state.json qemuscreenshot
)

assert_harness_input_safe() {
    local harness=$1 input=$2 key path
    input=$(realpath "$input") || return
    for key in "${HARNESS_STATE[@]}"; do
        path=$(realpath -m "$harness/$key") || return
        if [[ $input == "$path" || $input == "$path/"* ]]; then
            echo "Input disk would be deleted by harness cleanup: $input; copy it outside $harness/$key" >&2
            return 2
        fi
    done
}

reset_harness() {
    local key
    # Reset logs too, so an early failure cannot publish artifacts of an older run.
    local -a paths=()
    for key in "${HARNESS_STATE[@]}"; do paths+=("$1/$key"); done
    rm -rf -- "${paths[@]}" 2>/dev/null || sudo -n rm -rf -- "${paths[@]}" || return
}

run_isotovideo() {
    local harness=$1 vars_name=$2 mounts_name=$3
    local -n stage_vars=$vars_name stage_mounts=$mounts_name
    local rc=0 key
    local -a args=(casedir=/tests)
    resolve_isotovideo || return
    reset_harness "$harness" || return
    for key in "${!stage_vars[@]}"; do args+=("$key=${stage_vars[$key]}"); done
    docker run --rm -w /tests --network host "${DOCKER_ARGS[@]}" \
        -v "$harness:/tests" -v "$REPO_ROOT/casedir:/casedir:ro" \
        "${stage_mounts[@]}" "$ISOTOVIDEO_IMAGE" \
        --exit-status-from-test-results "${args[@]}" || rc=$?
    # Always return artifacts, including when the test fails.
    if ! sudo -n chown -R "$(id -u):$(id -g)" "$harness" 2>/dev/null; then
        echo "WARNING: could not restore ownership of $harness" >&2
    fi
    return "$rc"
}
