# NSYS Vectored (`vectored`)

**vectored** is a lightweight, agentless configuration deployment tool for Linux systems, built around **rsync**, **SSH**, and **systemd**.

It lets you **push configuration sets** from a controller to one or more servers, with built-in staging, validation, promotion, logging, and optional alerting — all without running background daemons or agents on your fleet.

## Presentation

vectored is designed for operators who want:

- 🔁 **Push-based config deployment** (no polling, no agents)
- 🧱 **Atomic-ish updates** via staging → validation → promotion
- 🧰 **Simple building blocks** (bash, rsync, ssh)
- ⚙️ **First-class systemd integration**
- 📜 **Clear logging** (journald, syslog)
- 📬 **Optional email alerts on failure**
- 📦 **Clean packaging** (`.deb`, no mutable version files)

vectored does *one thing well*:  
**reliably copy configuration to remote hosts and apply it safely.**

### What vectored is *not*

vectored does **not** aim to be:
- a full configuration management platform (only focusing on the essentials for quick, reliable config deployment)
- a replacement for Ansible / Puppet / Salt / Chef
- a state convergence engine
- a secrets manager

vectored assumes:
- you already manage secrets appropriately
- you know what files belong where
- you want explicit control over *when* changes are pushed

It intentionally stays small, explicit, and transparent.


## Quick example

A deployment vector is defined by two things:
- an **inventory** (where to deploy)
- a **set** (what to deploy and how)

Using systemd’s templated units, you run vectored like this:

```bash
systemctl start vectored@ghibli:nginx.service
```

This means:
- use inventory: `ghibli`
- deploy set: `nginx`

Under the hood, vectored will:
1. rsync files to a staging directory on each target
2. run an optional validation command
3. promote the staged files to the live location
4. run an optional apply/reload command
5. log everything to journald (and optionally syslog/email)


## Installation

### Debian / Ubuntu (recommended)

#### NSYS Packages repository (recommended) 
You can install vectored on Debian-based systems via the NSYS Packages repository:

```bash
curl -fsSL https://packages.nodsoft.net/install.sh | sudo bash
sudo apt install vectored
```

#### Manual .deb installation
vectored is also available as a `.deb` package, found in the releases. Install it with:
```bash
sudo dpkg -i vectored_<version>_amd64.deb
```

Configuration lives in:
```
/etc/vectored/
  inventory.d/
  sets.d/
```
Of course, preserved across package upgrades.

### systemd hardening

The Debian package installs a vendor drop-in for every `vectored@` service
instance. The existing service also enables `NoNewPrivileges=yes` and
`PrivateTmp=yes`. These protections apply to the local controller and its
children, not to commands run on remote hosts over SSH. The standalone CLI is
not sandboxed by this drop-in.

| Setting | Effect on the local service |
| --- | --- |
| `NoNewPrivileges=yes` | Prevents child processes from gaining privileges through setuid/setgid executables or file capabilities. |
| `PrivateTmp=yes` | Gives the service private `/tmp` and `/var/tmp` directories. |
| `ProtectKernelTunables=yes` | Makes kernel tunable interfaces read-only or inaccessible. |
| `ProtectKernelModules=yes` | Blocks loading or unloading kernel modules and limits access to module interfaces. |
| `ProtectControlGroups=yes` | Makes the cgroup hierarchy read-only. |
| `CapabilityBoundingSet=~…` | Removes the listed administrative, kernel, tracing, audit-control and MAC capabilities from the service and its children. |
| `LockPersonality=yes` | Prevents changing the process execution personality. |
| `RestrictRealtime=yes` | Denies requests for real-time scheduling. |
| `RestrictSUIDSGID=yes` | Denies creating files or changing modes with setuid or setgid bits. |

No source, SSH or lock paths need to be reconfigured for this drop-in. The
existing `PrivateTmp` already hides host files under `/tmp` and `/var/tmp`;
the kernel, module and cgroup protections also restrict those special paths.
Other paths remain subject to ordinary permissions. Root retains
significant privileges, including access to protected files; trusted profiles,
inventories, sets, local SSH helpers and remote credentials remain security
critical. This is defense in depth, not confinement of arbitrary shell code.

Custom local helpers that administer the kernel or use the removed capabilities
may require a local policy adjustment. The filesystem protections use mount
namespaces and can fail to start in restricted containers; systemd and kernel
support also determine which protections are effective. Test a representative
instance after upgrades, including custom SSH helpers and alert delivery:

```bash
sudo systemctl daemon-reload
sudo systemctl start vectored@inventory:set.service
sudo systemctl status vectored@inventory:set.service
sudo journalctl -u vectored@inventory:set.service -b
```

Administrators can add overrides with `systemctl edit vectored@.service` (all
instances), or `systemctl edit vectored@inventory:set.service` (one instance).
If the vendor drop-in prevents startup, it can be disabled for all instances
by masking this drop-in by name, without changing package files:

```bash
sudo mkdir -p /etc/systemd/system/vectored@.service.d
sudo ln -s /dev/null /etc/systemd/system/vectored@.service.d/10-hardening.conf
sudo systemctl daemon-reload
```

Remove the symlink and reload systemd to restore the packaged policy. A local
file with the same name takes precedence, so check for an existing override
before creating the symlink. Disabling the drop-in removes its protections;
the original service's `NoNewPrivileges` and `PrivateTmp` settings remain.

### From source
You can also run vectored directly from source.
```bash
git clone https://github.com/Nodsoft/vectored.git
cd vectored
sudo ./vectored.sh --help
```


## Concepts at a glance

- **Inventory**
  Defines targets (user, host, port).

- **Set**
  Defines what to sync, where to stage, how to validate, and how to apply.

- **Instance name (vectors)**
  `vectored@<inventory>:<set>`
  *(`example: `vectored@ghibli:nginx`)*

- **Profiles**
  Optional environment overrides (mail, logging, flags), layered per inventory, per set, or per instance.


## Logging and alerting

The vectored logging and alerting system supports three channels:

- **journald**: always enabled on debian-based installs
- **syslog**: enabled with `--syslog` or via systemd
- **email alerts**: optional, triggered on failure

Email configuration is done via environment variables:

```bash
VECTORED_MAIL_TO="ops@example.org"
VECTORED_MAIL_SUBJECT_PREFIX="[vectored]"
```

vectored relies on standard mail tooling (`mail`, `sendmail`, `msmtp`, etc.).


## Safety notes

A few important things to keep in mind when using vectored in production:
- Vectored does not deploy secrets by default — exclude them explicitly.
- `--delete` is opt-in and should be used carefully.
- Always use `--dry-run` when testing new sets.
- Validation commands should be idempotent and fast.

Operator intent is always preferred over automation magic when using vectored.


## License
This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.


## Status
Vectored is actively developed and used in Nodsoft Systems' production environments.
Issues, ideas, and contributions are more than welcome.
