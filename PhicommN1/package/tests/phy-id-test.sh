#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-21
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
program=$here/../../ethernet/phy-id.sh
fail() { echo "FAIL N1 phy-id: $*" >&2; exit 1; }
for tool in fdtget fdtput dtc; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo 'SKIP N1 phy-id: device-tree-compiler not installed'
        exit 0
    fi
done
export LC_ALL=C
work=$(mktemp -d)
trap 'rm -rf "$work"' 0
trap 'exit 1' HUP INT TERM
node=/soc/bus@c8834000/mdio@558/mdio@0/ethernet-phy@0
id=ethernet-phy-id001c.c916
c22=ethernet-phy-ieee802.3-c22
default=meson-gxl-s905d-phicomm-n1.dtb
pass=0
check() {
    title=$1; shift
    "$@" || fail "$title"
    echo "PASS $title"
    pass=$((pass + 1))
}
dtc -I dts -O dtb -o "$work/stock.dtb" "$here/fixtures/n1-phy.dts"
cp -f "$work/stock.dtb" "$work/kernel.dtb"
fdtput -t s "$work/kernel.dtb" /unrelated test-value new-kernel
fixture() {
    root=$work/$1
    base=${2:-$default}
    dtb=$root/boot/dtb/amlogic/$base
    state=$root/var/lib/openxplay-phicomm-n1/dtb
    backup=$state/$base
    record=$backup.sha256
    tmp=$root/boot/dtb/amlogic/.$base.openxplay-new
    phy=$root/sys/bus/mdio_bus/devices/mdio_mux-0.0:00/phy_id
    running=$root/proc/device-tree$node/compatible
    mkdir -p "$(dirname "$dtb")"
    printf 'FDT=/dtb/amlogic/%s\n' "$base" > "$root/boot/uEnv.txt"
    cp -f "$work/stock.dtb" "$dtb"
    OPENXPLAY_N1_ROOT=$root
    export OPENXPLAY_N1_ROOT
}
# A sysfs MDIO device with a phy_id whose of_node link points at a device-tree node.
mdio_device() {
    device=$root/sys/bus/mdio_bus/devices/$1
    mkdir -p "$device" "$root/sys/firmware/devicetree/base$3"
    ln -sfn "$root/sys/firmware/devicetree/base$3" "$device/of_node"
    printf '%s\n' "$2" > "$device/phy_id"
}
identify() { mdio_device mdio_mux-0.0:00 0x001cc916 "$node"; }
apply() { sh "$program" apply > "$root/output" 2>&1; }
revert() { sh "$program" revert > "$root/output" 2>&1; }
status() {
    sh "$program" status > "$root/status"
    printf '%s\n' "$1" > "$root/expected-status"
    cmp "$root/expected-status" "$root/status"
}
digest() {
    value=$(sha256sum "$1")
    printf '%s\n' "${value%% *}"
}
one_line_diff() {
    dtc -I dtb -O dts "$backup" > "$root/stock.dts"
    dtc -I dtb -O dts "$dtb" > "$root/patched.dts"
    rc=0
    diff -U0 "$root/stock.dts" "$root/patched.dts" > "$root/change.diff" || rc=$?
    [ "$rc" -eq 1 ] || return 1
    [ "$(grep -c '^+[^+]' "$root/change.diff")" -eq 1 ] || return 1
    [ "$(grep -c '^-[^-]' "$root/change.diff")" -eq 0 ] || return 1
    grep -q '^+[[:space:]]*compatible = ' "$root/change.diff"
}

fixture unsupported
printf 'FDT=/dtb/amlogic/other.dtb\n' > "$root/boot/uEnv.txt"
check 'unsupported FDT skipped' apply
check 'unsupported FDT untouched' cmp "$work/stock.dtb" "$dtb"
check 'unsupported FDT logged' grep -q unsupported "$root/output"
check 'unsupported status' status 'unsupported FDT=/dtb/amlogic/other.dtb'

fixture missing-uenv
rm -f "$root/boot/uEnv.txt"
check 'missing uEnv skipped' apply
check 'missing uEnv status' status "unsupported missing $root/boot/uEnv.txt"
fixture missing-dtb
rm -f "$dtb"
check 'missing DTB skipped' apply
check 'missing DTB status' status "unsupported missing $dtb"

fixture missing-node
fdtput -r "$dtb" "$node"
cp -f "$dtb" "$root/before.dtb"
identify
check 'missing PHY node skipped' apply
check 'missing PHY node untouched' cmp "$root/before.dtb" "$dtb"
check 'missing node status' status "unpatched $dtb"

for kind in reset-gpios reg; do
    fixture "invalid-$kind"
    case "$kind" in reset-gpios) fdtput -d "$dtb" "$node" reset-gpios ;; reg) fdtput -t x "$dtb" "$node" reg 1 ;; esac
    cp -f "$dtb" "$root/before.dtb"
    identify
    check "invalid $kind skipped" apply
    check "invalid $kind untouched" cmp "$root/before.dtb" "$dtb"
done

fixture unidentified
check 'unidentified PHY skipped' apply
check 'unidentified PHY untouched' cmp "$work/stock.dtb" "$dtb"
check 'unidentified PHY retry logged' grep -q 'PHY not identified on this boot; will retry at the next boot' "$root/output"
check 'unpatched status' status "unpatched $dtb"
check 'unidentified PHY has no backup' test ! -e "$backup"

fixture wrong-id
identify
printf '0x001cc915\n' > "$phy"
mkdir -p "$(dirname "$running")"
printf '%s\000' "$id" > "$running"
check 'wrong PHY ID skipped despite running compatible' apply
check 'wrong PHY ID untouched' cmp "$work/stock.dtb" "$dtb"
check 'wrong PHY ID logged' grep -q 0x001cc915 "$root/output"

for kind in foreign single-string; do
    fixture "$kind-compatible"
    case "$kind" in
    foreign) fdtput -t s "$dtb" "$node" compatible vendor,chosen-phy ;;
    single-string) fdtput -t s "$dtb" "$node" compatible "$id $c22" ;;
    esac
    cp -f "$dtb" "$root/before.dtb"
    identify
    check "$kind compatible skipped" apply
    check "$kind compatible untouched" cmp "$root/before.dtb" "$dtb"
    check "$kind compatible status" status "unpatched $dtb"
done

fixture good-id
identify
check 'identified PHY patched' apply
check 'exact patched compatible' test "$(fdtget -t s "$dtb" "$node" compatible)" = "$id $c22"
check 'backup holds stock bytes' cmp "$work/stock.dtb" "$backup"
check 'patched checksum recorded' test "$(cat "$record")" = "$(digest "$dtb")"
check 'patch temporary file gone' test ! -e "$tmp"
check 'DTS diff adds only the compatible line' one_line_diff
check 'next boot effect logged' grep -q "patched $dtb; takes effect at the next boot" "$root/output"
check 'patched status' status "patched $dtb"
# status takes no lock, so it also works for a user who cannot write /run/lock.
mv "$root/run" "$root/run.saved"
: > "$root/run"
check 'status works without a writable lock directory' status "patched $dtb"
rm -f "$root/run"
mv "$root/run.saved" "$root/run"
cp -f "$dtb" "$root/first-patched.dtb"
cp -f "$record" "$root/first.sha256"
check 'second apply succeeds' apply
check 'second apply leaves patched bytes unchanged' cmp "$root/first-patched.dtb" "$dtb"
check 'second apply leaves backup unchanged' cmp "$work/stock.dtb" "$backup"
check 'second apply leaves checksum unchanged' cmp "$root/first.sha256" "$record"

fixture rebound-bus
mdio_device mdio_mux-3.0:00 0x001cc916 "$node"
check 'PHY on a renumbered bus is identified by its node' apply
check 'renumbered bus patch applied' status "patched $dtb"

fixture other-node
mdio_device mdio_mux-0.1:08 0x001cc916 /soc/bus@c8834000/mdio@558/mdio@1/ethernet-phy@8
check 'PHY ID on another node does not identify the external PHY' apply
check 'other node leaves DTB untouched' cmp "$work/stock.dtb" "$dtb"
check 'other node retry logged' grep -q 'PHY not identified on this boot' "$root/output"

fixture kernel-update
identify
apply || fail 'initial patch before kernel update'
cp -f "$work/kernel.dtb" "$dtb"
rm -f "$phy"
mkdir -p "$(dirname "$running")"
printf '%s\000%s\000' "$id" "$c22" > "$running"
check 'kernel update is initially unpatched' status "unpatched $dtb"
check 'running compatible permits kernel update patch' apply
check 'kernel update replaces the stock backup' cmp "$work/kernel.dtb" "$backup"
check 'kernel update checksum recorded' test "$(cat "$record")" = "$(digest "$dtb")"
check 'kernel update is patched' status "patched $dtb"
check 'kernel update diff adds only the compatible line' one_line_diff

fixture foreign-running
mkdir -p "$(dirname "$running")"
printf 'vendor,other\000%s\000' "$id" > "$running"
check 'only the first running compatible identifies the PHY' apply
check 'foreign first running compatible leaves DTB untouched' cmp "$work/stock.dtb" "$dtb"

for base in "$default" meson-gxl-s905d-phicomm-n1-thresh.dtb; do
    fixture "revert-$base" "$base"
    identify
    apply || fail "patch before reverting $base"
    check "revert succeeds for $base" revert
    check "revert restores stock bytes for $base" cmp "$work/stock.dtb" "$dtb"
    check "revert drops backup for $base" test ! -e "$backup"
    check "revert drops checksum for $base" test ! -e "$record"
    check "revert leaves no temporary file for $base" test ! -e "$tmp"
    check "reverted status for $base" status "unpatched $dtb"
done

fixture changed-before-revert
identify
apply || fail 'patch before changed-file revert'
cp -f "$work/kernel.dtb" "$dtb"
check 'changed DTB revert succeeds' revert
check 'changed DTB retained' cmp "$work/kernel.dtb" "$dtb"
check 'changed DTB backup dropped' test ! -e "$backup"
check 'changed DTB checksum dropped' test ! -e "$record"
check 'changed DTB action logged' grep -q 'discarding backup and checksum' "$root/output"

REAL_FDTPUT=$(command -v fdtput)
export REAL_FDTPUT
mkdir -p "$work/bin"
cat > "$work/bin/fdtput" <<'EOF'
#!/bin/sh
# SPDX-FileCopyrightText: 2026 OpenXPlay.org
# SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
# Created by riko chen on 2026-10-21
set -eu
case "$TEST_FDTPUT_MODE" in
fail) exit 1 ;;
noop) exit 0 ;;
esac
"$REAL_FDTPUT" "$@"
case "$TEST_FDTPUT_MODE" in
extra) "$REAL_FDTPUT" -t s "$3" /unrelated unexpected changed ;;
remove) "$REAL_FDTPUT" -d "$3" "$4" max-speed ;;
esac
EOF
chmod 0755 "$work/bin/fdtput"
for mode in fail noop extra remove; do
    fixture "failed-verification-$mode"
    identify
    if env PATH="$work/bin:$PATH" TEST_FDTPUT_MODE=$mode sh "$program" apply > "$root/output" 2>&1; then
        fail "accepted fdtput $mode"
    fi
    check "fdtput $mode leaves DTB untouched" cmp "$work/stock.dtb" "$dtb"
    check "fdtput $mode removes temporary file" test ! -e "$tmp"
    check "fdtput $mode leaves no checksum" test ! -e "$record"
done
echo "PASS $pass N1 PHY ID checks"
