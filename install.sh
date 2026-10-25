#!/bin/sh
# Install (or update) Prometheus monitoring for a CoreELEC box:
#   - node_exporter, listening on :9100
#   - a textfile collector that exports Kodi process metrics
#     (address space, RSS, threads, file mappings)
#
# Everything lives in /storage/monitoring, so it survives CoreELEC updates.
# The systemd units are only symlinked into /storage/.config/system.d.
# Safe to run again: unchanged files are left alone, services are only
# restarted when something changed.
#
#   wget -qO- https://raw.githubusercontent.com/twiebe/coreelec-monitoring/main/install.sh | sh
#
# Remove everything again with either of
#   sh /storage/monitoring/uninstall.sh
#   wget -qO- https://raw.githubusercontent.com/twiebe/coreelec-monitoring/main/install.sh | sh -s -- --uninstall
#
# Settings (environment variables):
#   LISTEN_ADDRESS   node_exporter listen address        (default :9100)
#   INTERVAL         collector interval in seconds       (default 30)

# Everything is wrapped in main(), so a truncated download runs nothing.
main() {
	set -eu

	NODE_EXPORTER_VERSION=1.12.1
	PREFIX=/storage/monitoring
	UNIT_DIR=/storage/.config/system.d
	LISTEN_ADDRESS=${LISTEN_ADDRESS:-:9100}
	INTERVAL=${INTERVAL:-30}

	EXPORTER_UNIT=monitoring-node-exporter.service
	COLLECTOR_UNIT=monitoring-kodi-metrics.service
	COLLECTOR_TIMER=monitoring-kodi-metrics.timer

	case "${1:-}" in
		"") install ;;
		--uninstall) write_uninstaller | sh ;;
		*) die "unknown argument: $1 (only --uninstall is supported)" ;;
	esac
}

log() { echo "coreelec-monitoring: $*"; }
die() { echo "coreelec-monitoring: error: $*" >&2; exit 1; }

install() {
	[ "$(id -u)" = 0 ] || die "must run as root"
	[ -d /storage ] || die "/storage not found, this is meant for CoreELEC/LibreELEC"
	command -v systemctl >/dev/null || die "systemctl not found"
	case "$INTERVAL" in
		''|*[!0-9]*) die "INTERVAL must be a number of seconds" ;;
	esac

	mkdir -p "$PREFIX/bin" "$PREFIX/systemd" "$PREFIX/textfile" "$UNIT_DIR"

	EXPORTER_CHANGED=0
	COLLECTOR_CHANGED=0

	install_node_exporter

	write_uninstaller | put_file "$PREFIX/uninstall.sh" 755 || true
	write_collector | put_file "$PREFIX/bin/kodi-metrics.sh" 755 && COLLECTOR_CHANGED=1
	write_exporter_unit | put_file "$PREFIX/systemd/$EXPORTER_UNIT" 644 && EXPORTER_CHANGED=1
	write_collector_unit | put_file "$PREFIX/systemd/$COLLECTOR_UNIT" 644 && COLLECTOR_CHANGED=1
	write_collector_timer | put_file "$PREFIX/systemd/$COLLECTOR_TIMER" 644 && COLLECTOR_CHANGED=1

	link_unit "$EXPORTER_UNIT" && EXPORTER_CHANGED=1
	link_unit "$COLLECTOR_UNIT" && COLLECTOR_CHANGED=1
	link_unit "$COLLECTOR_TIMER" && COLLECTOR_CHANGED=1

	systemctl daemon-reload
	systemctl enable --quiet "$EXPORTER_UNIT" "$COLLECTOR_TIMER"

	if [ "$EXPORTER_CHANGED" = 1 ]; then
		systemctl restart "$EXPORTER_UNIT"
	else
		systemctl start "$EXPORTER_UNIT"
	fi
	if [ "$COLLECTOR_CHANGED" = 1 ]; then
		systemctl restart "$COLLECTOR_TIMER"
	else
		systemctl start "$COLLECTOR_TIMER"
	fi
	# Produce the first sample right away instead of waiting for the timer.
	systemctl start "$COLLECTOR_UNIT" || log "warning: first collector run failed, see: journalctl -u $COLLECTOR_UNIT"

	log "node_exporter $NODE_EXPORTER_VERSION listening on $LISTEN_ADDRESS"
	log "Kodi metrics every ${INTERVAL}s in $PREFIX/textfile/kodi.prom"
	log "check: wget -qO- http://127.0.0.1:${LISTEN_ADDRESS##*:}/metrics | grep ^kodi_"
}

# Standalone uninstaller, kept as $PREFIX/uninstall.sh. --uninstall runs
# the same script, so there is only one copy of the removal logic.
write_uninstaller() {
	cat <<EOF
#!/bin/sh
# Remove coreelec-monitoring: stop the services, remove the unit links
# from $UNIT_DIR and delete $PREFIX.
set -u
[ "\$(id -u)" = 0 ] || { echo "coreelec-monitoring: error: must run as root" >&2; exit 1; }
for unit in $COLLECTOR_TIMER $COLLECTOR_UNIT $EXPORTER_UNIT; do
	systemctl disable --now "\$unit" >/dev/null 2>&1 || true
	rm -f "$UNIT_DIR/\$unit"
done
systemctl daemon-reload
rm -rf "$PREFIX"
echo "coreelec-monitoring: removed"
EOF
}

# link_unit NAME: symlink the unit from $PREFIX/systemd into $UNIT_DIR.
# Returns 0 if the link was created or changed.
link_unit() {
	target="$PREFIX/systemd/$1"
	[ "$(readlink "$UNIT_DIR/$1" 2>/dev/null)" = "$target" ] && return 1
	ln -sfn "$target" "$UNIT_DIR/$1"
	log "linked $UNIT_DIR/$1"
	return 0
}

# put_file DEST MODE: write stdin to DEST if the content differs.
# Returns 0 if DEST was changed, 1 if it already had this content.
put_file() {
	tmp="$1.tmp.$$"
	cat >"$tmp"
	chmod "$2" "$tmp"
	if [ -f "$1" ] && cmp -s "$tmp" "$1"; then
		rm -f "$tmp"
		return 1
	fi
	mv -f "$tmp" "$1"
	log "updated $1"
	return 0
}

# download URL DEST: prefer curl, BusyBox wget's own TLS fails against
# GitHub on some builds. The checksum is verified either way.
download() {
	if command -v curl >/dev/null; then
		curl -fsSL -o "$2" "$1"
	else
		wget -qO "$2" "$1"
	fi
}

install_node_exporter() {
	marker="$PREFIX/bin/node_exporter.version"
	if [ -x "$PREFIX/bin/node_exporter" ] && [ "$(cat "$marker" 2>/dev/null)" = "$NODE_EXPORTER_VERSION" ]; then
		return 0
	fi

	# The binary is static, so the kernel architecture decides, not the
	# (possibly 32-bit) userland.
	case "$(uname -m)" in
		aarch64)
			arch=arm64
			sha256=ad35b605f9954b9f1ffddf5ba054bdc5a98d790b9eae5291e1eeb83f1ecbd0e7 ;;
		armv7l|armv8l)
			arch=armv7
			sha256=ae3d72fbf77f9ebed553c24465310e0880383f45d3d1566357ce7a31a997acb2 ;;
		x86_64)
			arch=amd64
			sha256=b51d8a76aa2a9156a55d501aca6276fae09e262259a5e4e831d2c2222f084e63 ;;
		*) die "unsupported architecture: $(uname -m)" ;;
	esac

	name="node_exporter-$NODE_EXPORTER_VERSION.linux-$arch"
	url="https://github.com/prometheus/node_exporter/releases/download/v$NODE_EXPORTER_VERSION/$name.tar.gz"
	work="$PREFIX/.download.$$"
	rm -rf "$work"
	mkdir -p "$work"

	log "downloading $name"
	download "$url" "$work/ne.tar.gz" || { rm -rf "$work"; die "download failed: $url"; }
	[ "$(sha256sum "$work/ne.tar.gz" | cut -d' ' -f1)" = "$sha256" ] ||
		{ rm -rf "$work"; die "checksum mismatch for $url"; }
	tar -xzf "$work/ne.tar.gz" -C "$work"
	mv -f "$work/$name/node_exporter" "$PREFIX/bin/node_exporter"
	chown 0:0 "$PREFIX/bin/node_exporter"
	chmod 755 "$PREFIX/bin/node_exporter"
	rm -rf "$work"
	echo "$NODE_EXPORTER_VERSION" >"$marker"
	EXPORTER_CHANGED=1
}

write_exporter_unit() {
	cat <<EOF
[Unit]
Description=Prometheus node_exporter
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$PREFIX/bin/node_exporter --web.listen-address=$LISTEN_ADDRESS --collector.textfile.directory=$PREFIX/textfile
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
}

write_collector_unit() {
	cat <<EOF
[Unit]
Description=Write Kodi process metrics for node_exporter

[Service]
Type=oneshot
Environment=TEXTFILE_DIR=$PREFIX/textfile
ExecStart=/bin/sh $PREFIX/bin/kodi-metrics.sh
EOF
}

write_collector_timer() {
	cat <<EOF
[Unit]
Description=Collect Kodi process metrics every ${INTERVAL}s

[Timer]
OnBootSec=${INTERVAL}s
OnUnitActiveSec=${INTERVAL}s
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
}

write_collector() {
	cat <<'EOF'
#!/bin/sh
# Write Kodi process metrics in Prometheus text format for the
# node_exporter textfile collector. Installed by coreelec-monitoring.
#
# The interesting one on 32-bit userlands is kodi_largest_free_vma_bytes:
# Kodi allocates its stream cache (Settings > Services > Caching > memory
# size) as one contiguous block. Once no free gap of that size is left in
# the 4 GiB address space, starting a video fails with "Open - Unhandled
# exception".

set -eu

TEXTFILE_DIR=${TEXTFILE_DIR:-/storage/monitoring/textfile}
PROCESS=${PROCESS:-kodi.bin}
OUT="$TEXTFILE_DIR/kodi.prom"
TMP="$OUT.$$"
trap 'rm -f "$TMP"' EXIT

# Only paths below this prefix get per-file mapping series, which keeps
# the label set small (databases, add-on files) and skips system libraries.
FILE_PREFIX=${FILE_PREFIX:-/storage/}

pid=""
for p in $(pidof "$PROCESS" 2>/dev/null || true); do
	if [ "$p" != "$$" ] && [ -r "/proc/$p/maps" ]; then
		pid=$p
		break
	fi
done

{
	echo "# HELP kodi_up Whether a Kodi process was found."
	echo "# TYPE kodi_up gauge"
	if [ -z "$pid" ]; then
		echo "kodi_up 0"
		exit_early=1
	else
		echo "kodi_up 1"
		exit_early=0
	fi
} >"$TMP"

if [ "$exit_early" = 1 ]; then
	mv -f "$TMP" "$OUT"
	trap - EXIT
	exit 0
fi

# ELF class byte of the running binary: 01 = 32-bit, 02 = 64-bit.
case "$(od -An -tx1 -j4 -N1 "/proc/$pid/exe" 2>/dev/null | tr -d ' ')" in
	01) bits=32 ;;
	02) bits=64 ;;
	*) bits=0 ;;
esac

started=$(stat -c %Y "/proc/$pid" 2>/dev/null || echo 0)

{
	cat <<METRICS
# HELP kodi_process_start_time_seconds Start time of the Kodi process.
# TYPE kodi_process_start_time_seconds gauge
kodi_process_start_time_seconds $started
# HELP kodi_userland_bits Bitness of the Kodi binary (32 or 64).
# TYPE kodi_userland_bits gauge
kodi_userland_bits $bits
METRICS

	awk '
		/^VmSize:/ { size = $2 * 1024 }
		/^VmPeak:/ { peak = $2 * 1024 }
		/^VmRSS:/  { rss = $2 * 1024 }
		/^Threads:/ { threads = $2 }
		END {
			print "# HELP kodi_vm_size_bytes Virtual address space in use (VmSize)."
			print "# TYPE kodi_vm_size_bytes gauge"
			printf "kodi_vm_size_bytes %.0f\n", size
			print "# HELP kodi_vm_peak_bytes Peak virtual address space (VmPeak)."
			print "# TYPE kodi_vm_peak_bytes gauge"
			printf "kodi_vm_peak_bytes %.0f\n", peak
			print "# HELP kodi_vm_rss_bytes Resident memory (VmRSS)."
			print "# TYPE kodi_vm_rss_bytes gauge"
			printf "kodi_vm_rss_bytes %.0f\n", rss
			print "# HELP kodi_threads Number of threads."
			print "# TYPE kodi_threads gauge"
			printf "kodi_threads %d\n", threads
		}
	' "/proc/$pid/status"

	# On a 32-bit process the free space above the last mapping counts too;
	# on 64-bit that space is practically unlimited and left out.
	limit=0
	[ "$bits" = 32 ] && limit=4294967296

	awk -v limit="$limit" -v prefix="$FILE_PREFIX" '
		function hex(s,    i, n) {
			n = 0
			s = tolower(s)
			for (i = 1; i <= length(s); i++)
				n = n * 16 + index("0123456789abcdef", substr(s, i, 1)) - 1
			return n
		}
		function esc(s) {
			gsub(/\\/, "\\\\", s)
			gsub(/"/, "\\\"", s)
			return s
		}
		{
			dash = index($1, "-")
			start = hex(substr($1, 1, dash - 1))
			end = hex(substr($1, dash + 1))
			regions++

			# The first 64 KiB are never mappable (vm.mmap_min_addr).
			lo = (NR == 1) ? 65536 : prev_end
			if (start > lo && start - lo > gap) gap = start - lo
			prev_end = end

			path = ""
			for (i = 6; i <= NF; i++) path = path (i > 6 ? " " : "") $i
			size = end - start
			if (path == "") anon += size
			else if (index(path, prefix) == 1) {
				fbytes[path] += size
				fcount[path]++
			}
		}
		END {
			if (limit > 0 && limit > prev_end && limit - prev_end > gap) gap = limit - prev_end

			print "# HELP kodi_largest_free_vma_bytes Largest free gap in the address space; the biggest single allocation that can still succeed."
			print "# TYPE kodi_largest_free_vma_bytes gauge"
			printf "kodi_largest_free_vma_bytes %.0f\n", gap
			if (limit > 0) {
				print "# HELP kodi_address_space_bytes Size of the address space (only for 32-bit processes)."
				print "# TYPE kodi_address_space_bytes gauge"
				printf "kodi_address_space_bytes %.0f\n", limit
			}
			print "# HELP kodi_vma_regions Number of memory mappings."
			print "# TYPE kodi_vma_regions gauge"
			printf "kodi_vma_regions %d\n", regions
			print "# HELP kodi_anon_mapped_bytes Address space of anonymous mappings."
			print "# TYPE kodi_anon_mapped_bytes gauge"
			printf "kodi_anon_mapped_bytes %.0f\n", anon

			print "# HELP kodi_file_mapped_bytes Address space mapped from a file, summed over all mappings of it."
			print "# TYPE kodi_file_mapped_bytes gauge"
			for (p in fbytes) printf "kodi_file_mapped_bytes{path=\"%s\"} %.0f\n", esc(p), fbytes[p]
			print "# HELP kodi_file_mappings Number of separate mappings of a file."
			print "# TYPE kodi_file_mappings gauge"
			for (p in fcount) printf "kodi_file_mappings{path=\"%s\"} %d\n", esc(p), fcount[p]
		}
	' "/proc/$pid/maps"
} >>"$TMP"

mv -f "$TMP" "$OUT"
trap - EXIT
EOF
}

main "$@"
