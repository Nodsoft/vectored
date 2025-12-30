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

vectored is distributed as a `.deb` package.
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