#!/usr/bin/env python3
"""Materialize a source tree from stack.toml.

Usage: scripts/apply-stack.py darling DIR [--lock FILE]
       scripts/apply-stack.py metal DIR

`darling` checks out Darling at its pinned commit with all submodules (shallow, as Darling's
own CI does), except that each override's submodule is moved to its base commit and its topics
are merged onto it in order. The submodule is first checked out at the commit its parent
records, from the URL in the parent's .gitmodules (relative URLs resolve against the parent's
upstream), so that commit must still exist. Submodules inside an override are initialized from the merged
tree. Nothing is committed in the parent repositories: their gitlinks still name the upstream
commits, and the working tree is what gets built. The resolved state is written to the lock
file (default DIR/../stack.lock).

`metal` checks out the Metal.jl used by the smoke test the same way.

Merge commits get a fixed author, committer and date (the base commit's), so the same
stack.toml gives the same commit IDs. A topic whose branch has moved past its pinned commit
only gets a warning: the pin is what is built.
"""

import os
import subprocess
import sys
import tomllib

HERE = os.path.dirname(os.path.abspath(__file__))
STACK = os.path.join(HERE, "..", "stack.toml")


def url(repo):
    return f"https://github.com/{repo}.git"


def git(cwd, *args, env=None, capture=False):
    cmd = ["git", "-C", cwd, *args]
    if capture:
        return subprocess.run(cmd, check=True, env=env, stdout=subprocess.PIPE, text=True).stdout.strip()
    subprocess.run(cmd, check=True, env=env)


def warn(msg):
    prefix = "::warning::" if os.environ.get("GITHUB_ACTIONS") else "warning: "
    print(prefix + msg, file=sys.stderr)


def fetch(cwd, repo, commit, depth=None):
    args = ["fetch", "--quiet", "--no-tags"]
    if depth:
        args.append(f"--depth={depth}")
    elif git(cwd, "rev-parse", "--is-shallow-repository", capture=True) == "true":
        args.append("--unshallow")   # merges need the history down to the merge base
    git(cwd, *args, url(repo), commit)


def check_branch(topic):
    out = subprocess.run(["git", "ls-remote", url(topic["repo"]), "refs/heads/" + topic["branch"]],
                         check=True, stdout=subprocess.PIPE, text=True).stdout.split()
    head = out[0] if out else None
    if head != topic["commit"]:
        warn(f"{topic['repo']} {topic['branch']} is at {head or 'nothing'}, "
             f"stack.toml pins {topic['commit']}")


def merge_topics(cwd, spec):
    """Check out spec's base in cwd and merge its topics in order; returns the new HEAD."""
    fetch(cwd, spec["repo"], spec["base"])
    for t in spec.get("topics", []):
        fetch(cwd, t["repo"], t["commit"])
        check_branch(t)
    git(cwd, "checkout", "--quiet", "--detach", spec["base"])
    date = git(cwd, "show", "-s", "--format=%cI", spec["base"], capture=True)
    env = dict(os.environ,
               GIT_AUTHOR_NAME="MetalDarling", GIT_AUTHOR_EMAIL="metaldarling@invalid",
               GIT_COMMITTER_NAME="MetalDarling", GIT_COMMITTER_EMAIL="metaldarling@invalid",
               GIT_AUTHOR_DATE=date, GIT_COMMITTER_DATE=date)
    for t in spec.get("topics", []):
        # explicit, so that the user's merge.ff or commit.gpgSign can't change the result
        git(cwd, "merge", "--quiet", "--ff", "--no-gpg-sign", "--no-edit",
            "-m", f"Merge {t['repo']} {t['branch']}", t["commit"], env=env)
    return git(cwd, "rev-parse", "HEAD", capture=True)


def submodule_paths(cwd):
    if not os.path.exists(os.path.join(cwd, ".gitmodules")):
        return []
    out = git(cwd, "config", "--file", ".gitmodules", "--get-regexp", r"^submodule\..*\.path$",
              capture=True)
    return [line.split(" ", 1)[1] for line in out.splitlines()]


def init_submodules(root, rel, overrides, lock):
    """Initialize the submodules of root/rel, applying overrides, then recurse."""
    cwd = os.path.join(root, rel)
    paths = submodule_paths(cwd)
    if not paths:
        return
    git(cwd, "submodule", "--quiet", "update", "--init", "--depth=1", "--jobs=8")
    for p in paths:
        sub = os.path.join(rel, p) if rel else p
        if sub in overrides:
            spec = overrides.pop(sub)
            subdir = os.path.join(root, sub)
            gitlink = git(subdir, "rev-parse", "HEAD", capture=True)
            head = merge_topics(subdir, spec)
            tree = git(subdir, "rev-parse", "HEAD^{tree}", capture=True)
            lock.append(f'[[override]]\npath = "{sub}"\nrepo = "{spec["repo"]}"\n'
                        f'gitlink = "{gitlink}"\nbase = "{spec["base"]}"\n'
                        f'head = "{head}"\ntree = "{tree}"\ntopics = [\n'
                        + "".join(f'    "{t["repo"]} {t["branch"]} {t["commit"]}",\n'
                                  for t in spec.get("topics", [])) + "]\n")
        init_submodules(root, sub, overrides, lock)


def new_repo(path, repo):
    if os.path.exists(path) and os.listdir(path):
        sys.exit(f"apply-stack: {path} exists and is not empty")
    os.makedirs(path, exist_ok=True)
    git(path, "init", "--quiet")
    # relative submodule URLs resolve against origin
    git(path, "remote", "add", "origin", url(repo))


def darling(path, lockfile, stack):
    d = stack["darling"]
    new_repo(path, d["repo"])
    fetch(path, d["repo"], d["commit"], depth=1)
    git(path, "checkout", "--quiet", "--detach", d["commit"])
    overrides = {o["path"]: o for o in d.get("override", [])}
    if len(overrides) != len(d.get("override", [])):
        sys.exit("apply-stack: two overrides for one path")
    lock = [f'[darling]\nrepo = "{d["repo"]}"\ncommit = "{d["commit"]}"\n']
    init_submodules(path, "", overrides, lock)
    if overrides:
        sys.exit(f"apply-stack: no submodule at {', '.join(overrides)}")
    status = git(path, "submodule", "status", "--recursive", capture=True)
    lock.append("# git submodule status --recursive ('+': moved by an override)\n"
                + "".join(f"# {line}\n" for line in status.splitlines()))
    with open(lockfile, "w") as io:
        io.write("# Generated by scripts/apply-stack.py from stack.toml.\n\n" + "\n".join(lock))
    print(f"apply-stack: darling in {path}, lock in {lockfile}")


def metal(path, stack):
    m = stack["metal"]
    new_repo(path, m["repo"])
    head = merge_topics(path, m)
    print(f"apply-stack: Metal.jl in {path} at {head}")


def main(argv):
    if len(argv) not in (2, 4) or argv[0] not in ("darling", "metal") or \
            (len(argv) == 4 and (argv[0] != "darling" or argv[2] != "--lock")):
        sys.exit(__doc__.split("\n\n")[1])
    with open(STACK, "rb") as io:
        stack = tomllib.load(io)
    path = os.path.abspath(argv[1])
    if argv[0] == "darling":
        lockfile = argv[3] if len(argv) == 4 else os.path.join(os.path.dirname(path), "stack.lock")
        darling(path, lockfile, stack)
    else:
        metal(path, stack)


if __name__ == "__main__":
    main(sys.argv[1:])
