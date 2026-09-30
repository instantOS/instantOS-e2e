# Boot the live ISO, capture the desktop, then inspect it over serial.
# UEFI uses the default boot entry and visual checks only: its systemd-boot
# menu has no needle/editor flow for adding serial kernel arguments yet.
# Investigation history is in docs/FINDINGS.md (live ISO diagnostic history).
use Mojo::Base 'basetest';
use testapi;
use lib '/tests/tests', '/casedir/tests';
use installer_base qw(login_instant_iso assert_offline_bundle);

sub run {
    my $offline = get_var('E2E_FLOW', 'live') eq 'offline';
    my $uefi    = get_var('UEFI');

    if ($uefi) {
        # Let systemd-boot select its default entry.
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

    # Capture the wallpaper before Welcome covers the desktop.
    assert_screen('live-bar', 1200);
    save_screenshot();    # -> bare-desktop frame (wallpaper evidence)

    # Wait for the live session: greetd -> instantWM -> Welcome window.
    # Screenshots are taken while polling, so boot states land in testresults.
    assert_screen('live-welcome', 1200);
    save_screenshot();

    if ($uefi) {
        # Serial inspection requires the BIOS menu edit above.
        record_info('liveiso-uefi',
            'desktop reached over UEFI on the injected ISO; serial asserts are BIOS-only'
        );
        return;
    }

    login_instant_iso();

    # Wait for live setup, then collect diagnostics before assertions can stop
    # the module. Console output is retained in virtio_console.log.
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
        # Child environments expose the PATH and runtime directory used by autostart.
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
    # greetd reports this session as Type=tty; check the Wayland socket itself.
    assert_script_run('ls /run/user/1000/wayland-* >/dev/null 2>&1',        timeout => 60,
        fail_message => 'no Wayland compositor socket in the session runtime dir');

    # XWayland and xorg-server-common are allowed; a full Xorg server is not.
    assert_script_run('! pacman -Q xorg-server', timeout => 60);
    assert_script_run('! pgrep -x Xorg',          timeout => 60);

    # Check setup completion after the session diagnostics.
    assert_script_run('test -e /run/instantos-liveautostart.done',          timeout => 60,
        fail_message => 'liveautostart never finished (see SECTION_autostart_lock / SECTION_child_env)');
    assert_script_run('systemctl is-active --quiet NetworkManager',         timeout => 60,
        fail_message => 'NetworkManager should be started by liveautostart');
    # Wallpaper end-to-end: settings.toml seeded by instantos-setup and
    # swaybg packaged → autostart's apply_configured_wallpaper must have
    # spawned the Wayland wallpaper setter.
    assert_script_run('pgrep -u instantos -x swaybg',                       timeout => 60,
        fail_message => 'wallpaper not applied (swaybg missing or appearance.wallpaper_path unset)');

    # Verify the shipped offline bundle and its wiring.
    if ($offline) {
        script_run('echo SECTION_offline_bundle; ls /run/archiso/bootmnt/offline-repo 2>&1; '
             . 'ls /run/archiso/bootmnt/offline-repo/core/os/x86_64/ 2>&1 | head -3; '
             . 'wc -l /run/archiso/bootmnt/offline-repo/packages.list 2>&1; '
             . 'grep -m1 "^Server" /etc/pacman.d/mirrorlist', timeout => 120);
        assert_offline_bundle();
        record_info('offline', 'bundle mounted, snapshot shipped, mirrorlist prefers file://');
    }

    record_info('liveiso', 'boot, session, forensics and wallpaper capture done');
}

1;
