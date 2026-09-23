# Harness for the instantOS *live* ISO (diagnostic harness, not the regular
# suite): boot the ISO, assert the boot menu and the live session visually,
# then inspect the running system over the virtio serial console. The
# pre-welcome bare desktop is captured while the bar is up (needle live-bar).
#
# Flow:
#   1. assert the syslinux boot menu (needle iso-bootloader) and append
#      `console=hvc0 console=ttyS0` to the kernel cmdline (Tab-edit)
#   2. assert the bare desktop bar (needle live-bar) in the gap before the
#      Welcome window, save that frame, then assert Welcome (live-welcome)
#      while the screen console keeps screenshots rolling (~5 min under TCG)
#   3. log in as root on hvc0 (empty password), run forensics
#   4. strict asserts: session, X/XWayland, wallpaper (swaybg), live setup
#   5. E2E_OFFLINE=1: Phase 0 spike asserts for the offline-injected ISO
#      (offlineiso.md): the xorriso-injected bundle is mounted where the
#      installer probes it, and the offline image wiring shipped
#
# UEFI runs (UEFI=1, OVMF): the syslinux iso-bootloader needle does not
# match systemd-boot, and the serial console needs a cmdline edit whose
# hotkeys differ ('e' + Ctrl+X, not Tab + Enter). Spike scope is therefore:
# boot the default entry untouched and assert the desktop chain (OVMF ->
# systemd-boot -> kernel -> greetd -> instantwm); the polling screenshots
# land the systemd-boot menu frames in testresults as future needle
# material. Serial-console asserts are BIOS-only until that needle exists.
#
# Section dumps print `SECTION_<name>` markers (zsh chokes on words starting
# with `=` — an earlier `echo ===x` run died on equals-expansion).
use Mojo::Base 'basetest';
use testapi;

sub run {
    my $offline = get_var('E2E_OFFLINE');
    my $uefi    = get_var('UEFI');

    if ($uefi) {
        # No menu interaction (see header): let the 15 s systemd-boot
        # timeout boot the default entry.
        record_info('uefi', 'UEFI run: booting the default entry, no menu interaction');
    } else {
        # The syslinux menu mirrors itself to ttyS0 (`SERIAL 0 115200`), but the
        # assertion is on the VGA framebuffer. 14 s countdown: get in fast.
        assert_screen('iso-bootloader', 180);

        # Edit the kernel cmdline (Tab on the selected entry): log to hvc0 for
        # scripted interaction (virtio console) and to ttyS0 so boot messages are
        # pollable from here and persisted in serial0.
        send_key 'tab';
        type_string ' console=hvc0 console=ttyS0';
        send_key 'ret';
    }

    # Bare desktop first: the bar comes up ~2.5 min in, the Welcome window
    # only later, so a bar-only needle (opaque bar: solid $base background)
    # matches in the gap; its frame is the wallpaper evidence shot. This
    # replaces the old post-SIGKILL capture: killing Welcome does not clear
    # its surface (instantwm keeps the dead client's frame on screen), and
    # pre-fix images never rendered wallpaper art at all.
    assert_screen('live-bar', 1200);
    save_screenshot();    # -> bare-desktop frame (wallpaper evidence)

    # Wait for the live session: greetd -> instantWM -> Welcome window.
    # Screenshots are taken while polling, so boot states land in testresults.
    assert_screen('live-welcome', 1200);
    save_screenshot();

    if ($uefi) {
        # No serial console without the cmdline edit (systemd-boot needle +
        # editor flow is future work — see header). The UEFI spike question
        # is answered by the desktop itself: the injected ISO booted through
        # OVMF, systemd-boot, kernel, greetd and instantwm.
        record_info('liveiso-uefi',
            'desktop reached over UEFI on the injected ISO; serial asserts are BIOS-only'
        );
        return;
    }

    # --- hand over to the virtio serial console ---------------------------
    select_console('root-console');

    # If the hvc0 getty banner was printed before this console attached (or
    # is just late), poke it until it repaints. An empty line at the login
    # prompt only re-prompts.
    my $got_login = 0;
    for (1 .. 40) {
        $got_login = wait_serial('instantlive login:', timeout => 15, quiet => 1);
        last if $got_login;
        type_string "\n";
    }
    die 'no getty on hvc0 (console=hvc0 did not produce a serial login)'
        unless $got_login;

    # root has an empty password on the live image (overlay /etc/shadow).
    type_string "root\n";
    wait_serial('# ', 300);
    # Root's login shell is zsh, which is hostile to os-autoinst's script_run
    # markers: the marker is md5_base64(cmd) with `/` substituted to `~`
    # (hashed_string()), so ~1/64 of commands get a marker starting with `~`
    # → zsh tilde-expansion dies with "no such user or named directory" →
    # marker never prints → the command times out and kills the test (seen
    # live: marker `~6rU_`). zsh also eats words starting with `=` (its
    # equals-expansion). bash leaves unmatched ~words and =words literal, so
    # continue under bash --norc (default bash prompt still ends in "# ").
    type_string "exec bash --norc\n";
    wait_serial('# ', 60);
    script_run('stty cols 400 rows 100', timeout => 60);

    # --- forensics first: echoed on this console, lands in virtio_console.log
    # --- (kept before the strict asserts so a failing assert still leaves
    # --- evidence in the log).
    # Give liveautostart time to finish: it runs `pacman -Sy` and re mounts
    # the cowspace before touching its end-marker, which can take minutes on
    # the guest's network. Don't assert yet — dump status, assert later.
    script_run('for i in $(seq 72); do [ -e /run/instantos-liveautostart.done ] && break; sleep 5; done; ls -l /run/instantos-liveautostart.done 2>&1; pgrep -af "liveautostart|pacman" 2>&1', timeout => 420);

    my @cmds = (
        'echo SECTION_version; cat /etc/instantos/version',
        'echo SECTION_services; systemctl is-active display-manager greetd NetworkManager systemd-timesyncd 2>&1',
        'echo SECTION_sessions; loginctl 2>&1; loginctl list-sessions --no-legend 2>&1',
        'echo SECTION_procs; ps -eo user,pid,etimes,cmd | grep -E "instantwm|welcome|kitty|fzf|installapplet|liveautostart|pacman|greetd|agetty|Xorg|Xwayland|mako|waybar|flameshot" | grep -v grep',
        'echo SECTION_user_journal; sudo -u instantos XDG_RUNTIME_DIR=/run/user/1000 journalctl --user -b --no-pager > /tmp/uj.txt 2>&1; wc -l /tmp/uj.txt; grep -iE "liveautostart|autostart|welcome|sudo|error|fail" /tmp/uj.txt | tail -40',
        'echo SECTION_autostart_lock; ls -l /run/user/1000/instant_autostart.lock /tmp/instant_autostart.lock 2>&1; echo "lock pid: $(cat /run/user/1000/instant_autostart.lock 2>/dev/null)"; ls /run/user/1000/ 2>&1 | head -30',
        'echo SECTION_greetd_journal; journalctl -b -u greetd --no-pager 2>&1 | tail -50',
        'echo SECTION_instantwm_env; tr "\\0" "\\n" < /proc/$(pgrep -x instantwm | head -1)/environ 2>/dev/null | grep -E "^PATH=|^XDG_|^WAYLAND" ',
        'echo SECTION_session_procs; ps -eo user,pid,etimes,cmd | grep -iE "wallpaper|swaybg|swww|feh|hyprpaper|conky|installapplet|dot update|polkit|swayidle|instantautostart|ins autostart" | grep -v grep',
        'echo SECTION_user_units; sudo -u instantos XDG_RUNTIME_DIR=/run/user/1000 systemctl --user --no-pager list-units 2>&1 | grep -iE "mako|instantos|autostart|portal|polkit|graphical|xdg" | head -20; sudo -u instantos XDG_RUNTIME_DIR=/run/user/1000 systemctl --user --failed --no-pager 2>&1 | head -10',
        'echo SECTION_session_type; loginctl show-session 1 -p Type -p Class -p Active 2>&1; echo "-- root console env:"; tr "\\0" "\\n" < /proc/self/environ | grep -E "^(XDG_RUNTIME_DIR|PATH)=" ',
        'echo SECTION_versions; pacman -Q ins instantwm 2>&1',
        # Surviving children of `ins autostart` carry its spawn environment:
        # PATH/XDG_RUNTIME_DIR here decide why liveautostart/installapplet
        # (both /usr/local/bin) left no trace while /usr/bin spawns ran.
        'echo SECTION_child_env; for p in $(pgrep -x mako) $(pgrep -x kitty | head -1) $(pgrep -x hyprpolkitagent); do echo "-- pid $p $(cat /proc/$p/comm 2>/dev/null)"; tr "\\0" "\\n" < /proc/$p/environ 2>/dev/null | grep -E "^(PATH|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS|TMPDIR|WAYLAND_DISPLAY)="; done',
        'echo SECTION_lock_stat; stat -c "%y %s %n" /tmp/instant_autostart.lock 2>&1; echo "pid in lock: $(cat /tmp/instant_autostart.lock 2>&1)"',
        'echo SECTION_instantwm_strings; strings /usr/bin/instantwm | grep -E "^PATH=|env -i|INSTANTWM_AUTOSTART|ins autostart" | head -8',
        'echo SECTION_tty1; fuser -v /dev/tty1 2>&1; echo ---; systemctl is-active getty@tty1 2>&1; systemctl status getty@tty1 --no-pager -l 2>&1 | head -12',
        'echo SECTION_xstack; pacman -Q xorg-server xorg-xinit xorg-xwayland xf86-input-evdev xf86-input-synaptics xorg-server-common 2>&1; pgrep -ax Xorg; pgrep -ax Xwayland; ls -la /tmp/.X11-unix 2>&1; cat /etc/X11/Xwrapper.config 2>&1',
        'echo SECTION_wallpaper; ls -la /usr/share/liveutils/ 2>&1; find /home/instantos -maxdepth 4 -iname "*wallpaper*" 2>/dev/null | head; cat /home/instantos/.fehbg 2>&1',
        'echo SECTION_greetd; cat /etc/greetd/config.toml',
        'echo SECTION_cowspace; grep cowspace /proc/mounts; df -h /run/archiso 2>/dev/null | tail -1',
        'echo SECTION_plymouth; systemctl list-units --no-legend "plymouth*" 2>&1; grep -n "^HOOKS" /etc/mkinitcpio.conf',
        'echo SECTION_motd; cat /etc/motd',
        'echo SECTION_hooks; ls /etc/pacman.d/hooks/',
        'echo SECTION_display_manager_link; ls -l /etc/systemd/system/display-manager.service',
        'echo SECTION_dmesg_err; dmesg -l err,crit,alert,emerg | tail -20',
        'echo SECTION_journal_err; journalctl -p err -b --no-pager | tail -40',
    );
    for my $c (@cmds) {
        script_run($c, timeout => 180);
    }

    # --- strict assertions (everything the live ISO must satisfy) ---------
    assert_script_run('test -e /opt/instantos/.setup-done',                 timeout => 60);
    assert_script_run('test -L /etc/systemd/system/display-manager.service', timeout => 60);
    assert_script_run('systemctl is-active --quiet greetd',                 timeout => 60);
    assert_script_run('pgrep -u instantos -f instantwm > /dev/null',        timeout => 60);
    assert_script_run('pgrep -u instantos -f welcome > /dev/null',          timeout => 60);
    assert_script_run('grep -q cowspace /proc/mounts',                      timeout => 60);
    # Test-assumption fix (run 2d): greetd registers its session with logind
    # as Type=tty (instantwm's own environ has XDG_SESSION_TYPE=tty), so a
    # "Type=wayland" assert is wrong for this product's session model. Prove
    # Wayland the way the session actually does it: a compositor socket in
    # the runtime dir (raw Type/Class are dumped in SECTION_session_type).
    assert_script_run('ls /run/user/1000/wayland-* >/dev/null 2>&1',        timeout => 60,
        fail_message => 'no Wayland compositor socket in the session runtime dir');

    # The live ISO is Wayland-only by design (isotests.md §4: xorg groups
    # removed from packages.x86_64) — pin that at package AND process level.
    # Assert `xorg-server` specifically: xorg-server-common legitimately
    # remains as an xorg-xwayland dependency. XWayland itself may run
    # (rootless) for X clients; an Xorg server may not.
    assert_script_run('! pacman -Q xorg-server', timeout => 60);
    assert_script_run('! pgrep -x Xorg',          timeout => 60);

    # --- live-setup asserts (kept last: run 2c showed they can fail, and
    # --- everything above must still have run and been captured first) ----
    assert_script_run('test -e /run/instantos-liveautostart.done',          timeout => 60,
        fail_message => 'liveautostart never finished (see SECTION_autostart_lock / SECTION_child_env)');
    assert_script_run('systemctl is-active --quiet NetworkManager',         timeout => 60,
        fail_message => 'NetworkManager should be started by liveautostart');
    # Wallpaper end-to-end: settings.toml seeded by instantos-setup and
    # swaybg packaged → autostart's apply_configured_wallpaper must have
    # spawned the Wayland wallpaper setter.
    assert_script_run('pgrep -u instantos -x swaybg',                       timeout => 60,
        fail_message => 'wallpaper not applied (swaybg missing or appearance.wallpaper_path unset)');

    # --- E2E_OFFLINE=1: Phase 0 spike (offlineiso.md) ----------------------
    # The xorriso-injected bundle must be mounted exactly where the
    # installer probes it (/run/archiso/bootmnt), and the offline image
    # wiring (marker, dotfiles snapshot, file://-first mirrorlist) shipped.
    if ($offline) {
        script_run('echo SECTION_offline_bundle; ls /run/archiso/bootmnt/offline-repo 2>&1; '
             . 'ls /run/archiso/bootmnt/offline-repo/core/os/x86_64/ 2>&1 | head -3; '
             . 'wc -l /run/archiso/bootmnt/offline-repo/packages.list 2>&1; '
             . 'grep -m1 "^Server" /etc/pacman.d/mirrorlist', timeout => 120);
        assert_script_run(
            'test -e /run/archiso/bootmnt/offline-repo/core/os/x86_64/core.db',
            timeout => 60,
            fail_message => 'offline bundle not mounted at /run/archiso/bootmnt '
                . '(this path is the installer\'s entire offline probe)'
        );
        assert_script_run('test -e /run/archiso/bootmnt/offline-repo/packages.list', timeout => 60);
        assert_script_run('test -e /run/archiso/bootmnt/offline-repo/regions/regions.html', timeout => 60);
        assert_script_run('test -e /usr/share/instantos/offline-image', timeout => 60,
            fail_message => 'offline-image marker missing: this is not the offline image build');
        assert_script_run('test -e /usr/share/instantos/build-inputs/dotfiles/.git/config',
            timeout => 60,
            fail_message => 'dotfiles snapshot missing: instantos-setup deleted '
                . 'build-inputs despite the offline-image marker');
        assert_script_run(
            'grep -m1 "^Server" /etc/pacman.d/mirrorlist | grep -Fq "file:///run/archiso/bootmnt/offline-repo"',
            timeout => 60,
            fail_message => 'the shipped mirrorlist does not prefer the offline bundle'
        );
        record_info('offline', 'bundle mounted, snapshot shipped, mirrorlist prefers file://');
    }

    record_info('liveiso', 'boot, session, forensics and wallpaper capture done');
}

1;
