#!/usr/bin/env python3
"""Reads .github/workflows/image.yml for test.sh.

  workflow.py step <job> <step id>   print that step's run: script, as written
  workflow.py contract               check what the file's shape must guarantee

The contract is about structure the scripts cannot show by running: which job
holds which permission, that nothing reaches the registry before the image is
checked, that every action is pinned to a commit.
"""
import re
import sys
from pathlib import Path

import yaml

WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/image.yml"
PINNED = re.compile(r"^[\w.-]+/[\w.-]+(/[\w./-]+)?@[0-9a-f]{40}$")


def load(path=WORKFLOW):
    with open(path) as f:
        return yaml.safe_load(f)  # resolves the &anchors the jobs share


def triggers(wf):
    return wf.get("on", wf.get(True))  # YAML 1.1 reads a bare `on` as true


def step(wf, job, sid):
    for s in wf["jobs"][job]["steps"]:
        if s.get("id") == sid:
            return s
    raise KeyError(f"{job} has no step {sid}")


def index(steps, pred, what):
    for i, s in enumerate(steps):
        if pred(s):
            return i
    raise AssertionError(f"no step that {what}")


def uses(name):
    return lambda s: s.get("uses", "").split("@")[0] == name


def contract(wf):
    errors = []
    try:
        _contract(wf, errors)
    except (AssertionError, KeyError, TypeError) as e:  # a step or key it needs is gone
        errors.append(str(e))
    return errors


def _contract(wf, errors):
    def check(ok, msg):
        if not ok:
            errors.append(msg)

    on = triggers(wf)
    check(list(on) == ["workflow_call"], f"only workflow_call may trigger it, not {list(on)}")
    call = on["workflow_call"] or {}
    check("secrets" not in call, "it takes no secrets: GITHUB_TOKEN is all it needs")
    inputs = set((call.get("inputs") or {}).keys())
    for name in ("image", "images", "registry", "repository", "tags", "push"):
        check(name not in inputs, f"input {name!r} would let a caller choose where or what it pushes")
    check(wf.get("permissions") == {}, "the workflow grants nothing by default")

    validate, publish = wf["jobs"]["validate"], wf["jobs"]["publish"]
    check(set(wf["jobs"]) == {"validate", "publish"}, f"unexpected jobs {sorted(wf['jobs'])}")
    check(validate.get("permissions") == {"contents": "read"}, "validate reads, nothing more")
    check(publish.get("permissions") == {"contents": "read", "packages": "write"},
          "publish holds packages: write and nothing else")
    check(publish.get("needs") == "validate", "publish runs only after validate passes")
    check(re.fullmatch(r"needs\.validate\.outputs\.publish == 'true'", publish.get("if", "")) is not None,
          "publish runs only when validate planned it")

    for name, job in wf["jobs"].items():
        check(isinstance(job.get("timeout-minutes"), int), f"{name} has a timeout")
        for s in job["steps"]:
            label = f"{name}: {s.get('name', s.get('uses'))}"
            if "uses" in s:
                check(PINNED.match(s["uses"]) is not None, f"{label} is pinned to a full commit sha")
            if uses("actions/checkout")(s):
                check((s.get("with") or {}).get("persist-credentials") is False,
                      f"{label} leaves no token in .git/config")
            if "run" in s:
                check("${{" not in s["run"], f"{label} takes its inputs from env, not ${{{{ }}}} in the script")

    vsteps = validate["steps"]
    for s in vsteps:
        label = f"validate: {s.get('name')}"
        check(not uses("docker/login-action")(s), f"{label} must not log in")
        check((s.get("with") or {}).get("push") in (None, False), f"{label} must not push")
        check("secrets." not in yaml.safe_dump(s), f"{label} must not see a secret")
    index(vsteps, lambda s: s.get("id") == "healthcheck", "checks the HEALTHCHECK in validate")

    psteps = publish["steps"]
    plan = index(psteps, lambda s: s.get("id") == "plan", "plans in publish")
    refuse = index(psteps, lambda s: s.get("if") == "steps.plan.outputs.publish != 'true'", "refuses an unplanned publish")
    health = index(psteps, lambda s: s.get("id") == "healthcheck", "checks the HEALTHCHECK in publish")
    tags = index(psteps, lambda s: s.get("id") == "tags", "checks the tags")
    login = index(psteps, uses("docker/login-action"), "logs in")
    pushes = [i for i, s in enumerate(psteps) if (s.get("with") or {}).get("push") is True]
    check(len(pushes) == 1, "exactly one step pushes")
    check(plan < refuse < health < tags < login < min(pushes, default=-1),
          "plan, refuse, healthcheck and tag checks all come before login and push")
    check(login == len(psteps) - 2 and pushes == [len(psteps) - 1], "login and push are the last two steps")

    meta = step(wf, "publish", "meta")["with"]
    check(meta["images"] == "${{ steps.plan.outputs.image }}", "the image is the one plan derived")
    check(meta.get("flavor") == "latest=false", "latest comes from the default branch alone")
    check("date" not in meta["tags"], "no date-based tags")
    push = psteps[pushes[0]]["with"] if pushes else {}
    check(push.get("tags") == "${{ steps.meta.outputs.tags }}", "it pushes the checked tags")


def broken():
    """Each a way the workflow could go wrong that contract() must catch."""

    def unpinned(wf):
        wf["jobs"]["validate"]["steps"][0]["uses"] = "actions/checkout@v4"

    def login_in_validate(wf):
        login = next(s for s in wf["jobs"]["publish"]["steps"] if uses("docker/login-action")(s))
        wf["jobs"]["validate"]["steps"].append(dict(login))

    def push_in_validate(wf):
        next(s for s in wf["jobs"]["validate"]["steps"] if s.get("name") == "Build every platform")["with"]["push"] = True

    def packages_in_validate(wf):
        wf["jobs"]["validate"]["permissions"]["packages"] = "write"

    def image_input(wf):
        triggers(wf)["workflow_call"]["inputs"]["image"] = {"type": "string"}

    def inherits_secrets(wf):
        triggers(wf)["workflow_call"]["secrets"] = {"token": {"required": False}}

    def push_before_healthcheck(wf):
        s = wf["jobs"]["publish"]["steps"]
        h = next(i for i, x in enumerate(s) if x.get("id") == "healthcheck")
        s.append(s.pop(h))

    def no_refusal(wf):
        wf["jobs"]["publish"]["steps"] = [s for s in wf["jobs"]["publish"]["steps"]
                                          if s.get("if") != "steps.plan.outputs.publish != 'true'"]

    def unconditional_publish(wf):
        del wf["jobs"]["publish"]["if"]

    def credentials_kept(wf):
        wf["jobs"]["publish"]["steps"][0] = {"uses": wf["jobs"]["publish"]["steps"][0]["uses"]}

    def interpolated_run(wf):
        step(wf, "validate", "plan")["run"] += '\necho "${{ github.head_ref }}"\n'

    def caller_image(wf):
        step(wf, "publish", "meta")["with"]["images"] = "${{ inputs.image }}"

    def latest_on_tags(wf):
        del step(wf, "publish", "meta")["with"]["flavor"]

    def calver(wf):
        step(wf, "publish", "meta")["with"]["tags"] += "type=raw,value={{date 'YYYY.MM.DD'}}\n"

    def pull_request_trigger(wf):
        triggers(wf)["pull_request"] = None

    return [f for f in locals().values() if callable(f)]


def main(argv):
    if argv == ["contract-catches"]:
        missed = 0
        for mutate in broken():
            wf = load()
            mutate(wf)
            if contract(wf):
                print(f"ok: contract catches {mutate.__name__}")
            else:
                print(f"FAIL: contract misses {mutate.__name__}", file=sys.stderr)
                missed += 1
        return 1 if missed else 0
    if argv[:1] == ["step"] and len(argv) == 3:
        print(step(load(), argv[1], argv[2])["run"], end="")
        return 0
    if argv == ["contract"]:
        errors = contract(load())
        for e in errors:
            print(f"FAIL: contract: {e}", file=sys.stderr)
        return 1 if errors else 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
