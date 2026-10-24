# GitHub Actions runner setup

`setup.sh` provisions Ubuntu self-hosted runners, their toolchains, Android E2E
support, and a daily cleanup cron.

For initial registration, run `bash setup.sh` and provide the GitHub token, owner,
repository, and runner settings through the prompts or environment variables.
To update only an existing host's tools and OS configuration:

```sh
bash setup.sh --os-only
```

This mode does not ask for GitHub credentials or re-register installed runners.
Set `RUNNER_WORKDIR` if the installation is not under `/opt/actions-runner`.
Run provisioning while jobs are idle; updated runner environment settings can
restart active services. See [CLAUDE.md](CLAUDE.md) for the configuration variables
and Android toolchain details.

## Cleanup policy

Provisioning installs `/usr/local/bin/runner-cleanup.sh` and schedules it daily at
03:00 via `/etc/cron.d/runner-cleanup`. Logs go to `/var/log/runner-cleanup.log`.

The script resolves the runner account's actual home directory with `getent`,
then removes aged entries under `<runner-home>/.cache`. A missing `.cache`
directory is skipped. The existing `find -mtime +1` cutoff means at least two
complete 24-hour periods, rather than exactly 24 hours.

For `.cache/petsy-e2e`, cleanup removes aged `.tar` archives individually, only
when their corresponding `.lock` can be acquired without waiting. Lock files
remain in place so concurrent readers/writers keep using the same lock inode.
Archive age is checked again under the lock; cache hits refresh archive timestamps.

Deploy changes to the installed cron script by rerunning `setup.sh --os-only`.
Editing this repository alone does not update the host's installed cleanup script.

## GitHub Actions caches that local cleanup can manage

GitHub stores remote cache archives separately from the files restored onto the
runner. This cron cleans local files only; remote caches follow
[GitHub's cache management rules](https://docs.github.com/en/actions/using-workflows/caching-dependencies-to-speed-up-workflows).

Place disposable tool caches under `$HOME/.cache`, where `$HOME` is the runner
service user's home. This can differ from both `/home/runner` and the home of the
account running provisioning. Use a persistent path for caches reused across jobs.

This example caches npm downloads with [actions/cache](https://github.com/actions/cache).
It isolates directories and cache keys by runner instance, preventing concurrent
jobs on different instances from restoring into the same mutable directory.

```yaml
steps:
  - uses: actions/checkout@v7

  - uses: actions/setup-node@v7
    id: node
    with:
      node-version-file: src/mobile/.tool-versions
      package-manager-cache: false

  - name: Configure managed npm cache
    id: npm-cache
    run: |
      cache_dir="$HOME/.cache/npm-${RUNNER_NAME}"
      mkdir -p "$cache_dir"
      touch "$cache_dir"
      echo "NPM_CONFIG_CACHE=$cache_dir" >> "$GITHUB_ENV"
      echo "path=$cache_dir" >> "$GITHUB_OUTPUT"

  - uses: actions/cache@v6
    with:
      path: ${{ steps.npm-cache.outputs.path }}
      key: npm-${{ runner.os }}-${{ runner.arch }}-${{ runner.name }}-${{ steps.node.outputs.node-version }}-${{ hashFiles('src/mobile/package-lock.json') }}

  - name: Install dependencies
    working-directory: src/mobile
    run: |
      touch "$NPM_CONFIG_CACHE"
      npm ci --prefer-offline
```

Touch the top-level managed cache directory after restoration and before use:
cleanup checks that directory's modification time, not the newest nested file.
This keeps active caches fresh even when restoration preserves old timestamps.
The age cutoff must exceed the workflow's maximum runtime.

A download-cache hit still requires `npm ci`; it avoids downloading packages,
but does not restore `node_modules`. If using `setup-node`'s built-in `cache: npm`
instead, set `NPM_CONFIG_CACHE` before that action so it also uses the managed
location. Do not enable both caching mechanisms for the same directory.

For installed dependencies or APK caches, include all relevant build inputs in
the key: OS/architecture, runtime version, lockfiles, patches, and build settings.
Only skip installation or compilation on an exact compatible hit. Keep mutable
working copies separate between jobs; if sharing local archives, use per-key
locks and atomic publication, as the Petsy E2E cache does.
