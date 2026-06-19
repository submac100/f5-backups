# F5 BIG-IP UCS Backup → Git (AWX project)

Weekly UCS backups for BIG-IP devices, exported to a git archive repo, with
per-device retention (keep the current + previous backup; `keep_count: 2`).

Designed to run as an **AWX Job Template**. Starts with a single test device;
scales to HA pairs by adding hosts to the inventory.

## What it does

1. **Play 1** (per BIG-IP): saves the running config to disk, creates a UCS named
   `<host>-<YYYY-MM-DD>.ucs`, downloads it to the EE, then deletes the transient
   UCS from the device (toggle with `remove_remote_ucs`).
2. **Play 2** (localhost): clones the **archive** repo, adds the new UCS files,
   prunes each device to the newest `keep_count`, commits and pushes.

ISO-dated filenames mean a plain lexical sort is chronological, so retention is
just "keep the last N names per device" — no timestamp parsing.

## Files

| Path | Purpose |
|------|---------|
| `backup_ucs.yml` | the playbook (run this from the Job Template) |
| `inventory/hosts.yml` | devices to back up — one to start, add HA pairs later |
| `group_vars/all.yml` | retention, paths, archive repo URL, commit identity |
| `group_vars/bigip.yml` | F5 connection (provider dict, local connection) |
| `collections/requirements.yml` | `f5networks.f5_modules` (auto-installed on project sync) |
| `execution-environment/` | optional custom EE (see "Execution environment") |

## Runtime secrets (never committed)

| Variable | What | Supplied via |
|----------|------|--------------|
| `f5_username` / `f5_password` | BIG-IP backup account (Administrator role — UCS save needs it) | AWX credential |
| `git_pat` | token with write access to the **archive** repo | AWX credential |

`backups_repo` (the archive repo URL, minus `https://`) lives in
`group_vars/all.yml` — edit it to your repo.

---

## Wiring it up in AWX

### 1. Project
Resources → **Projects → Add** → Source Control type **Git**, point at *this* repo.
Attach an SCM credential if it's private. AWX syncs it and installs the collection
from `collections/requirements.yml`.

### 2. Credentials (custom credential types — one-time setup)

**F5 account** — Administration → Credential Types → Add:
- *Input config*
  ```yaml
  fields:
    - id: username
      type: string
      label: F5 Username
    - id: password
      type: string
      label: F5 Password
      secret: true
  required: [username, password]
  ```
- *Injector config*
  ```yaml
  extra_vars:
    f5_username: "{{ username }}"
    f5_password: "{{ password }}"
  ```
Then Resources → Credentials → Add one of this type with the real account.

**Git token** — same pattern, one field `token` (secret), injector:
```yaml
extra_vars:
  git_pat: "{{ token }}"
```

> Fast path for the very first manual test: skip the custom types and pass
> `f5_username`, `f5_password`, `git_pat` as **extra variables** on launch (or a
> Survey). Move them into credentials once it works.

### 3. Inventory
Resources → **Inventories → Add**, then add a host matching `inventory/hosts.yml`
(name `bigip-lab-01`, host var `ansible_host: <mgmt-ip>`). Or sync the inventory
from this project. Add both members when you move to HA pairs.

### 4. Job Template
Resources → **Templates → Add**:
- Inventory: the one above
- Project: this project
- Playbook: `backup_ucs.yml`
- Execution Environment: default `AWX EE` for the quick path (the collection is
  installed from the project), or your custom `f5-ee` (below)
- Credentials: the F5 + Git credentials from step 2

**Launch** it once manually against the single test device. Check the UCS lands
in the archive repo and old files prune correctly.

### 5. Schedule
On the Job Template → **Schedules → Add** → weekly. That replaces cron and is the
reason to run this in AWX rather than a shell job.

---

## Execution environment (optional, for production)

The quick path installs `f5networks.f5_modules` from the project on every sync.
To bake it in (faster, pinned, no per-run install):

```bash
cd execution-environment
pip install ansible-builder
./build.sh        # builds f5-ee:1.0 and imports it into Colima's k3s
```
Then register it in AWX (Administration → Execution Environments) with image
`f5-ee:1.0` and **pull policy `Never`** (it's local to the cluster), and select it
on the Job Template.

---

## Scaling to HA pairs
Add both members to `inventory/hosts.yml`. Play 1 backs up each host
independently; Play 2 prunes per-device, so each member keeps its own last N.
Group them in the inventory and target the group from one Job Template.

## Switching the export target to object storage
Replace Play 2's git tasks with an upload to S3/Azure Blob (e.g.
`amazon.aws.s3_object`) and let a bucket lifecycle / versioning policy enforce
retention instead of the prune step. Play 1 is unchanged. This is the
recommended shape for binary UCS at scale (no git history bloat, secrets stay
out of git).

## Restore (reference)
`tmsh load sys ucs <file>` on the target device after transferring the UCS back.
Validate platform/version compatibility first.
