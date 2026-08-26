# Versioning and releases

GoPull uses [semantic versioning](https://semver.org): `MAJOR.MINOR.PATCH`.

| bump | when |
|---|---|
| **major** | a change that breaks how the app is used or removes something people relied on |
| **minor** | a new capability — preview, GPS overlays, a new export path |
| **patch** | fixes and internal work with no new capability |

## One source of truth

The version lives in **`MARKETING_VERSION`** in the Xcode project, and nothing else stores a copy.
`GENERATE_INFOPLIST_FILE` turns it into `CFBundleShortVersionString`; `AppVersion` reads it back
for the menu bar; the git tag is derived from it. So the running app, the bundle and the tag
cannot drift apart.

`tools/version` is the only thing that writes it:

```bash
tools/version                 # 1.1.0
tools/version minor           # 1.2.0 (build 3)
tools/version set 2.0.0       # exact
tools/version tag             # prints the tag command for the current version
```

Bumping also increments `CURRENT_PROJECT_VERSION` (the build number). macOS compares that when
deciding whether a build is newer, so it must only ever go up.

## Branching

```
main                      always releasable; every commit on it is a merged PR
│
├── feature/1.2.0         one release's worth of work
│   ├── feature/1.2.0-gpmf-parser      one unit of work
│   ├── feature/1.2.0-overlay-render
│   └── feature/1.2.0-export-pipeline
```

**The separator is a hyphen, not a slash**, and that is not a style choice. Git stores refs as
paths, so `refs/heads/feature/1.2.0` is a *file* and `refs/heads/feature/1.2.0/gpmf-parser` would
need it to be a *directory*. Creating the second fails outright:

```
fatal: cannot lock ref 'refs/heads/feature/1.2.0/gpmf-parser':
       'refs/heads/feature/1.2.0' exists; cannot create ...
```

`feature/1.2.0-gpmf-parser` sorts next to its release branch and has no such problem.

1. **Branch the release** off `main`, named for the version it will ship as:
   `git checkout main && git pull && git checkout -b feature/1.2.0`
2. **Branch each piece of work** off that: `git checkout -b feature/1.2.0-gpmf-parser`.
   One branch per feature or fix, small enough to review on its own.
3. **Merge each sub-branch back** into the release branch as it finishes:
   `git checkout feature/1.2.0 && git merge --no-ff feature/1.2.0-gpmf-parser`.
   `--no-ff` keeps each piece of work visible as a unit in the history.
4. **Bump the version** on the release branch when the work is done:
   `tools/version minor` — one commit, so the diff shows exactly what shipped.
5. **Open the PR** from `feature/1.2.0` into `main`. The PR description is the release notes;
   write it as one, because it becomes them.
6. **Merge, then tag** the merge commit on `main`:
   ```bash
   git checkout main && git pull
   git tag -a v1.2.0 -m "GoPull 1.2.0" && git push origin v1.2.0
   ```
7. **Cut the GitHub release** against that tag, with the PR description as the notes and a built
   `GoPull.app` attached if there is one.

## Tag before you build the release artifact

Tag first, then build from the tagged commit, so the `.app` you attach reports the version the
tag claims. `tools/version tag` prints the exact command for whatever the project currently says.

## History

| version | what |
|---|---|
| 1.0.0 | first release: mount the card, import clips |
| 1.1.0 | stability pass (long imports, selection) and clip preview from the camera's proxies |
