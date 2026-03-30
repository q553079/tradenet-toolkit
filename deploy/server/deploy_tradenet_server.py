from __future__ import annotations

import json
import os
import posixpath
import sys
from pathlib import Path

import paramiko


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: deploy_tradenet_server.py <job.json>")

    job = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8-sig"))
    server = job["server"]
    local = job["local"]

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(
        hostname=server["host"],
        port=server["port"],
        username=server["user"],
        password=server["password"],
        timeout=20,
        banner_timeout=20,
        auth_timeout=20,
    )

    sftp = client.open_sftp()
    remote_script = "/tmp/install-tradenet-server.sh"
    sftp.put(local["installer_path"], remote_script)
    sftp.chmod(remote_script, 0o755)

    env_exports = []
    for key, value in server["environment"].items():
        escaped = str(value).replace("'", "'\"'\"'")
        env_exports.append(f"export {key}='{escaped}'")

    command = " && ".join(env_exports + [remote_script])
    stdin, stdout, stderr = client.exec_command(command, timeout=300)
    out = stdout.read().decode("utf-8", "replace")
    err = stderr.read().decode("utf-8", "replace")
    exit_code = stdout.channel.recv_exit_status()

    Path(local["remote_stdout_path"]).write_text(out, encoding="utf-8")
    Path(local["remote_stderr_path"]).write_text(err, encoding="utf-8")

    if exit_code != 0:
        raise SystemExit(f"remote install failed with exit code {exit_code}")

    Path(local["artifact_dir"]).mkdir(parents=True, exist_ok=True)
    for filename in ("client-wireguard.conf", "tradenet-client-artifact.json", "server-summary.txt"):
        remote_path = posixpath.join(server["artifact_dir"], filename)
        local_path = Path(local["artifact_dir"]) / filename
        sftp.get(remote_path, str(local_path))

    sftp.close()
    client.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
