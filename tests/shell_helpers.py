"""Run the actual Bash functions with isolated paths and external-command fixtures."""

import os
import signal
from pathlib import Path
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which("bash") or r"C:\Program Files\Git\bin\bash.exe"


def shell_path(path):
    value = str(Path(path).resolve()).replace("\\", "/")
    if len(value) > 1 and value[1] == ":":
        return "/" + value[0].lower() + value[2:]
    return value


def script_functions(path):
    source = Path(path).read_text(encoding="utf-8")
    if Path(path).name == "import.sh":
        source = source.split("\nis_change=1\n", 1)[0]
    # The original script unconditionally calls main; never execute that call in
    # function tests, where installation paths/system operations are substituted.
    if source.rstrip().endswith('main "$@"'):
        source = source.rstrip()[:-len('main "$@"')]
    return source


def run_bash(body, *, source="auto-deploy.sh", env=None, prelude="", replacements=None, args=(), timeout=20):
    environment = os.environ.copy()
    if env:
        environment.update({key: str(value) for key, value in env.items()})
    text = script_functions(ROOT / source)
    for old, new in (replacements or {}).items():
        text = text.replace(old, new)
    text = prelude + "\n" + text + "\n" + body
    # Native Windows jq uses CRLF stdout; normalize that test-tool boundary while
    # keeping the real jq implementation and queries under test.
    if os.name == "nt":
        text = 'jq() { command jq.exe "$@" | tr -d "\\r"; return "${PIPESTATUS[0]}"; }\n' + text
    command = [BASH, "--noprofile", "--norc", "-s", "--", *args]
    options = {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if os.name == "nt" else {"start_new_session": True}
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, env=environment, cwd=ROOT, **options)
    try:
        stdout, stderr = process.communicate(text, timeout=timeout)
    except subprocess.TimeoutExpired:
        # MSYS Bash may fork a process that retains the captured pipes. Terminate
        # the isolated process tree, not just its Windows launcher.
        if os.name == "nt":
            subprocess.run(["taskkill.exe", "/PID", str(process.pid), "/T", "/F"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        else:
            os.killpg(process.pid, signal.SIGKILL)
        process.communicate(timeout=5)
        raise
    return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
