# Integration tests

The unit tests under `t/unit/` mock the array, the REST client, and the
multipath/sysfs layer. They prove internal logic and PVE contracts but **cannot**
validate array- or host-facing behaviour.

Real validation happens against hardware (a VSP E590H + a PVE cluster) following
[`docs/INTEGRATION_CHECKLIST.md`](../../docs/INTEGRATION_CHECKLIST.md), which lists
every baked-in assumption, where it lives in the code, how to verify it, and what to
change if it is wrong.

Add executable integration tests here as the bring-up progresses (they require live
credentials and a target array, so they are not part of `make test`). Record results
— date, DKCMAIN/microcode version, PVE version, pass/fail, deviations — so the
checklist reflects what has actually been confirmed.
