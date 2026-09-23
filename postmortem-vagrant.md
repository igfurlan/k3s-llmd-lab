# Postmortem — three VMs that would not boot

**Phase:** 2 (Vagrant provisioning of the Rocky Linux nodes)
**Date:** 20–21 September 2026
**Impact:** ~4 hours. No data loss. The cluster now boots in 73 seconds.

---

## Summary

After a successful first build, every subsequent boot of the VMs appeared to hang.
Vagrant sat at `Waiting for machine to boot` until it timed out.

The root cause was a **single VirtualBox setting**: `ioapic=off`. VirtualBox
requires the I/O APIC to run a guest with more than one CPU. With it off, it
silently hands the guest **one** CPU and ignores the configured count entirely —
no warning, no error, no log line. Every node configured for 4 vCPUs was running
on 1.

On a single vCPU, under a hypervisor already running in compatibility mode, boots
took longer than Vagrant's 600-second timeout. A slow boot and a hung boot look
identical from the outside.

**Fix:** enable the I/O APIC, and raise the boot timeout to match the environment.
Boot time went from *exceeding 600s* to **72.8s**.

---

## Environment

| Component | Version / value |
|---|---|
| Host | AMD Ryzen 7 9800X3D (8C/16T), 30.8 GB RAM, Windows 11 Pro 26200 |
| VirtualBox | 7.2.18 |
| Vagrant | 2.4.9 |
| Box | `rockylinux/9` v5.0.0 → Rocky Linux 9.8, kernel `5.14.0-503.14.1.el9_5` |
| Nodes | 3 × 4 vCPU / 6144 MB, `192.168.56.11-13` on a host-only network |

**Important environmental fact:** VirtualBox has no access to AMD-V on this host.
Windows keeps a hypervisor resident (VBS/Hyper-V), so VirtualBox falls back to
**NEM** — the Windows Hypervisor Platform API. From `VBox.log`:

```
HM: HMR3Init: Attempting fall back to NEM: AMD-V is not available
NEM: WHvCapabilityCodeHypervisorPresent is TRUE, so this might work...
```

Every VM exit is therefore expensive. This did not *cause* the failure, but it
set the performance baseline that turned one lost vCPU into a total outage.

---

## Symptom

```
==> k3s-server: Booting VM...
==> k3s-server: Waiting for machine to boot. This may take a few minutes...
    k3s-server: SSH address: 127.0.0.1:2222
    k3s-server: SSH auth method: private key
Timed out while waiting for the machine to boot.
```

The VM reported `running` in VirtualBox. Port 2222 accepted TCP connections. The
console showed kernel messages that stopped around the 7.5-second mark and never
advanced.

---

## Root cause

```
$ VBoxManage showvminfo k3s-server --machinereadable | grep -E '^ioapic|^cpus'
cpus=4
ioapic="off"
```

```
$ nproc
1

$ dmesg | grep smpboot
smpboot: Allowing 1 CPUs, 0 hotplug CPUs
smpboot: SMP disabled
smp: Brought up 1 node, 1 CPU
```

VirtualBox requires the I/O APIC for SMP guests. The `rockylinux/9` box ships with
it off, and **Vagrant's `vb.cpus` does not enable it**. The configuration said 4;
the guest got 1; nothing anywhere reported a conflict.

---

## Contributing factors

1. **Silent failure.** VirtualBox neither warns nor logs when it discards the CPU
   count. The only evidence is a mismatch between `cpus=` and the guest's `nproc`.
2. **`boot_timeout` was 600s**, tuned for a normal hypervisor. Under NEM on one
   vCPU, boots exceeded it — so a *slow* boot presented as a *hung* boot.
3. **The failure appeared after a `dnf update`**, creating a compelling but false
   correlation with the new kernel. The real trigger was simply a reboot; the
   first build had already been running on 1 vCPU, just without anyone noticing.
4. **The evidence was on screen and misread.** The provisioning banner printed
   `CPUS: 1` beside a Vagrantfile specifying 4. The kernel printed
   `clocksource: Not enough CPUs to check clocksource 'tsc'` — a literal statement
   of the problem. Both were passed over.

---

## Hypotheses that were wrong

Recorded deliberately: four of the five were plausible, and eliminating them is
what produced the config audit that found the real cause.

| # | Hypothesis | Why it looked right | Why it was wrong |
|---|---|---|---|
| 1 | Paravirt clock (`paravirtprovider=legacy`) | Console showed TSC declared unstable, falling back to `acpi_pm` | A genuine misconfiguration — `kvm` is correct for Linux guests — but the hang persisted after fixing it. The clock messages were a *symptom* of a starved single CPU. |
| 2 | Host-only adapter / `VBoxNetLwf` | Boot stopped on the `eth1` message twice, and the Windows event log showed repeated `VBoxNetLwf` internal driver errors | Disproved by booting with `CLUSTER_NET = :none`. It still hung on NAT alone, stopping instead on the last disk message. `eth1` was simply whatever printed last. |
| 3 | VirtualBox 7.2.x networking regression | Real, documented, unfixed bugs (VirtualBox/virtualbox#136, #345); guests reported hanging at network bring-up | Same disproof as #2. Networking was never involved. |
| 4 | New kernel from `dnf update` | Perfect timing correlation; hang sat at the kernel-to-userspace boundary | A freshly destroyed and rebuilt VM, on the box's original kernel with no updates applied, hung identically. |
| 5 | Windows sleeping / driver wedged | Plausible given the event-log errors | Never tested; superseded. A Windows reboot was recommended on this basis and would not have helped. |

---

## Fixes applied

All in the [Vagrantfile](Vagrantfile).

**1. Enable the I/O APIC — the actual fix.**

```ruby
vb.customize ["modifyvm", :id, "--ioapic", "on"]
```

**2. Raise the boot timeout to match the environment.**

```ruby
config.vm.boot_timeout = 1800
```

Under NEM, boots are legitimately slow. The default turns "slow" into "failed".

**3. Use the KVM paravirt clock.** Not the root cause, but correct for a Linux
guest — the default `legacy` provider leaves it reading raw TSC, which drifts
badly under a nested hypervisor.

```ruby
vb.customize ["modifyvm", :id, "--paravirtprovider", "kvm"]
```

**4. Pin the kernel.** Added while hypothesis #4 was live. Retained for now so
that only one variable changes at a time; **to be re-tested and probably removed.**

```
dnf update -y -q --exclude=kernel*
```

**5. Make the cluster network switchable.** Added to disprove hypothesis #2, kept
because it is the fastest way to isolate a future network fault.

```ruby
CLUSTER_NET = :hostonly   # or :intnet, or :none
```

---

## Result

| Metric | Before | After |
|---|---|---|
| Guest vCPUs | 1 (of 4 configured) | **4** |
| Boot | exceeded 600s timeout | **72.8s** |
| `vagrant reload` | failed every time | succeeds on all three nodes |

---

## Diagnostics that worked

**`ssh -vv` instead of guessing at the failure.** Vagrant's message said "timed
out". The real error was different:

```
debug1: kex_exchange_identification: write: Connection refused
```

*Connection refused*, not a timeout — and banner exchange happens **before**
authentication, which immediately ruled out the SSH key, its permissions, and the
entire auth path.

**CPU utilisation distinguishes hung from slow.** A guest doing work sits near
80–90% of a core. A genuinely stuck one sits near zero.

```powershell
$a = (Get-Process VBoxHeadless | Sort-Object CPU -Desc | Select -First 1).CPU
Start-Sleep 8
$b = (Get-Process VBoxHeadless | Sort-Object CPU -Desc | Select -First 1).CPU
"$([math]::Round((($b-$a)/8)*100,1))% of one core"
```

Measured 7.8% while "hung" and 87.7% while merely slow. This single check would
have saved hours.

**Compare configuration against what the guest reports.** Not what the tool was
told, what the OS actually sees:

```powershell
VBoxManage showvminfo <vm> --machinereadable | Select-String "^cpus=|^ioapic="
vagrant ssh <vm> -c "nproc"
```

**Read the console, not the wrapper.** `VBoxManage controlvm <vm> screenshotpng`
captures the guest framebuffer on a headless VM — but compare *timestamps*
between captures, not pixels. Two identical frames three seconds apart mean
nothing when boot is running 10× slow.

---

## Gotcha: `/usr/local/bin` is not on the PATH in a Vagrant provisioner

The k3s installer puts its binaries in `/usr/local/bin`:

```
[INFO]  Installing k3s to /usr/local/bin/k3s
[INFO]  Creating /usr/local/bin/kubectl symlink to k3s
```

That directory is on a normal interactive login's PATH, so `k3s kubectl get nodes`
works fine over `vagrant ssh`. It is **not** on the PATH of the non-interactive
shell Vagrant uses for `provision`, so the same command inside a provisioner
fails:

```
/tmp/vagrant-shell: line 19: k3s: command not found
```

The install had succeeded. Only the verification block that followed it broke —
and because that block was a `for` loop polling readiness, it silently burned all
90 iterations before exiting non-zero and failing the whole provisioner. The
symptom (a long wait, then failure) looked nothing like the cause (a missing
PATH entry).

**Fix:** call it by absolute path in any provisioner script.

```bash
K3S=/usr/local/bin/k3s
$K3S kubectl get --raw=/readyz
```

**General rule:** a provisioner shell is not a login shell. Anything installed
outside `/usr/bin` or `/bin` needs an absolute path or an explicit `PATH` export.
The same applies to `helm`, `kubectl` and anything else installed by a script
later in this project.

---

## Also fixed this phase

**Box version 6.0.0 returns 404.** The Vagrant Cloud registry lists
`rockylinux/9` v6.0.0 as `active`, but the `.box` artifact is missing:

```
The requested URL returned error: 404
```

v5.0.0 and v4.0.0 download cleanly. Metadata is not proof the artifact exists —
range-GET the URL before pinning a version:

```powershell
curl.exe -s -o NUL -L -r 0-1 -w "%{http_code}" <box-url>   # expect 206
```

---

## Open items — all closed by the migration

Each of these was listed as outstanding while the lab still ran on VirtualBox.
They were closed on 2026-09-23 by moving to Hyper-V rather than by being fixed
individually, which is itself the point: they were symptoms of one cause.

- ~~**Re-test the kernel pin.**~~ Removed. The guests run
  `5.14.0-687.49.1.el9_8` and Rocky 9.8 after a full `dnf update`.
- ~~**Root filesystem is 8.9 GB.**~~ Gone with the box. `generic/rocky9` is built
  at 128 GB with `autopart`, so the 30 GB data disk and its XFS mount were
  dropped entirely.
- ~~**AMD-V is unavailable to VirtualBox.**~~ Still true, and now irrelevant.
  Memory Integrity stays on; the VMs run on the hypervisor Windows already has
  rather than on one competing with it.

---

## Epilogue: the migration, measured

The postmortem above is about one wrong setting. The conclusion underneath it —
that the host itself was the limit — took another day to reach, and was settled
by measurement rather than argument.

The test is deliberately dumb: sleep 50 ms, fifty times, and see how long it
actually takes. A guest that is being scheduled returns ~51 ms. A guest that is
being descheduled cannot.

| | VirtualBox (NEM) | Hyper-V, first boot | Hyper-V, after reboot |
|---|---|---|---|
| `sleep 0.05` × 25 | multi-second stalls | `51 51 51 … 50 51` | `52 51 52 … 51 52` |
| `dmesg \| grep -c hrtimer` | 14 server / 6 per agent | **0** | **0** |
| Load average at rest | 13–19, with ~73% idle CPU | — | **0.03** |
| Nodes | flapping NotReady | 3 × Ready | 3 × Ready, unattended |

The Hyper-V columns were taken after a full `dnf update` and a k3s install, not
on an idle VM — the harder version of the test.

`hrtimer: interrupt took 3249948 ns` was the guest kernel reporting that it had
not run for 3.2 seconds. Every failure that looked like a Kubernetes problem
descended from that single fact: containerd RPCs hitting `DeadlineExceeded`,
PLEG going stale, metrics-server consuming 90% of a vCPU while failing its own
scrapes, and a control plane that could not finish starting in 19 minutes.

**The load average is the detail worth keeping.** 13–19 while the CPU is 73%
idle is not a busy machine; it is a queue of processes that are runnable and not
being run. That number alone should have redirected the investigation a day
earlier than it did.

### Lesson 5

**When every layer misbehaves at once, suspect the layer underneath them all.**
Four separate components were investigated on their own merits — containerd, the
kubelet, metrics-server, the API server. Each had a plausible local explanation.
None of them was wrong in itself; all four were downstream of a hypervisor that
could not keep its guests on a CPU. A fault that is everywhere is rarely in any
of the places it shows up.

---

## Lessons

1. **A timeout is not a diagnosis.** "Timed out waiting for boot" describes the
   observer, not the system. Find the error underneath it.
2. **Verify configuration against observed state.** Every layer here reported
   success: VirtualBox said 4 CPUs, Vagrant said it was booting, the VM said
   `running`. Only the guest knew the truth.
3. **Prefer the test that discriminates.** Four hypotheses were eliminated by one
   controlled experiment — booting with the second NIC removed. That test was
   available from the start.
4. **Read your own instrumentation.** The provisioning banner was written
   specifically to surface facts like `CPUS:`. Printing it is not the same as
   reading it.
