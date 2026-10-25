# coreelec-monitoring

Prometheus monitoring for a CoreELEC box: `node_exporter` plus a small
collector for Kodi process metrics.

It was written to catch one specific failure: on CoreELEC's 32-bit
userland Kodi has only 4 GiB of address space. When that space gets
fragmented (for example by add-ons that memory-map large SQLite
databases), Kodi can no longer allocate its stream cache as one block
and starting a video fails with `Open - Unhandled exception`.
`kodi_largest_free_vma_bytes` shows how close the box is to that point.

## Install

On the box, as root:

```sh
wget -qO- https://raw.githubusercontent.com/twiebe/coreelec-monitoring/main/install.sh | sh
```

Run it again to update. Unchanged files are left alone and services are
only restarted when something changed.

Settings are passed as environment variables:

```sh
wget -qO- https://raw.githubusercontent.com/twiebe/coreelec-monitoring/main/install.sh | LISTEN_ADDRESS=:9100 INTERVAL=30 sh
```

| Variable         | Default | Meaning                              |
|------------------|---------|--------------------------------------|
| `LISTEN_ADDRESS` | `:9100` | node_exporter listen address         |
| `INTERVAL`       | `30`    | collector interval in seconds        |

## Layout

Everything lives in `/storage/monitoring`, which survives CoreELEC
updates (a factory reset wipes it):

```
/storage/monitoring/
├── bin/node_exporter          pinned release, checksum verified
├── bin/kodi-metrics.sh        Kodi collector
├── systemd/                   unit files
├── textfile/kodi.prom         collector output
└── uninstall.sh
```

The units are only symlinked into `/storage/.config/system.d`:

- `monitoring-node-exporter.service`
- `monitoring-kodi-metrics.timer`, which runs `monitoring-kodi-metrics.service`

## Uninstall

```sh
sh /storage/monitoring/uninstall.sh
```

or, if that directory is already gone:

```sh
wget -qO- https://raw.githubusercontent.com/twiebe/coreelec-monitoring/main/install.sh | sh -s -- --uninstall
```

## Metrics

Besides the standard `node_*` metrics:

| Metric | Meaning |
|--------|---------|
| `kodi_up` | 1 if a `kodi.bin` process was found |
| `kodi_process_start_time_seconds` | start time of the Kodi process, shows restarts and crashes |
| `kodi_userland_bits` | 32 or 64 |
| `kodi_vm_size_bytes`, `kodi_vm_peak_bytes` | address space in use (VmSize, VmPeak) |
| `kodi_vm_rss_bytes` | resident memory |
| `kodi_threads` | number of threads |
| `kodi_largest_free_vma_bytes` | largest free gap in the address space, i.e. the largest single allocation that can still succeed |
| `kodi_address_space_bytes` | 4 GiB, only exported for 32-bit processes |
| `kodi_vma_regions` | number of memory mappings |
| `kodi_anon_mapped_bytes` | address space of unnamed anonymous mappings |
| `kodi_file_mapped_bytes{path}` | address space mapped from a file below `/storage`, summed over all its mappings |
| `kodi_file_mappings{path}` | number of separate mappings of that file |

On a 64-bit userland `kodi_largest_free_vma_bytes` is huge and carries
no warning value.

## Prometheus

```yaml
scrape_configs:
  - job_name: coreelec
    static_configs:
      - targets: ["coreelec.lan:9100"]
```

Alert before video playback starts failing. The threshold should be
comfortably above the cache memory size in Kodi's settings (Services >
Caching):

```yaml
groups:
  - name: kodi
    rules:
      - alert: KodiAddressSpaceFragmented
        expr: kodi_userland_bits == 32 and kodi_largest_free_vma_bytes < 256 * 1024 * 1024
        for: 5m
        annotations:
          summary: "Kodi has no free block of 256 MiB left, video playback may fail"
      - alert: KodiDown
        expr: kodi_up == 0
        for: 5m
```

## Grafana

`grafana/coreelec-kodi.json` is a dashboard for these metrics. Import it
via Dashboards > New > Import and pick the Prometheus data source. Set
the "Kodi cache memory size" variable to the value configured in Kodi;
it is drawn as the danger line under the largest free block. Kodi
restarts and crashes show up as annotations.

Port 9100 has to be reachable; if the CoreELEC firewall is enabled, allow
it there.
