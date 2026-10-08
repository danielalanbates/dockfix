# Archive

Code that was tried and did not work goes here, with a note on why, so nobody retries it blindly.

- *DiskArbitration `DAAppearanceTime` as the mount time* (never committed): it reports when diskarbitrationd first saw each disk — on 2026-10-08 every disk, including the internal one, showed 18:54:35. Replaced by the mount-point folder's creation time (see Sources/DockFix/Volumes.swift).
