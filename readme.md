# `fio` benchmarking

Collection of `fio` scripts for benchmarking HDDs/SSDs and various filesystems/parameters.

[Interpreting fio output]

## ZFS zvol testing

For reasons inexplicable to me, if [`sync=0`], testing on ZFS zvols takes extremely long.

The following have been observed:

- Slowdown is proportional to drive size (1TB drive hangs for ~24m, 10TB drive hangs for 2hr30min)
- Happens for ZFS zvols. Does not happen for the raw disk, Btrfs or ZFS datasets..
- Both sequential-only and random-only tests cause this
- `fio` is stuck in the `D` state (uninterruptible sleep).

Probing further, `fio` is waiting on `cv_timedwait_common`:

```sh
❯ sudo ps -eo pid,stat,command,wchan | awk '$3 ~ /^fio/ { print }'
2532587 Sl+  fio --output-format=json -- hrtimer_nanosleep
2533391 Ds   fio --output-format=json -- cv_timedwait_common
```

[`sync=0`]: https://fio.readthedocs.io/en/latest/fio_doc.html#cmdoption-arg-sync
[Interpreting fio output]: https://fio.readthedocs.io/en/latest/fio_doc.html#interpreting-the-output
