# Scenario 140: Signal Device Directory Fanout

This scenario starts a real `workflow-server`, loads released
`workflow-plugin-signal v0.36.0` as an external plugin, and drives
participant-parametric HTTP routes through an app-managed Signal device
directory.

The proof uses a scenario-owned local-file device directory, prepares device
bundles through the Workflow API, publishes three devices, verifies identical
publish replay is idempotent, rejects a mismatched same-device replay, revokes
one device, and fanout-prepares only the two active devices with
`step.signal_device_fanout_prepare`.

It restarts the Workflow server against the same device directory file, verifies
active-device state survived, then corrupts the snapshot and confirms the
directory fails closed on startup. The local file is the only dependency seam;
the Workflow server, external plugin loader, and Signal plugin steps run
unchanged.
