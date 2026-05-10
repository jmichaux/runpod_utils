# runpod_utils

Scripts for spinning up and connecting to RunPod instances.

```
runpod_utils/
  local_setup.sh   # run on your Mac each time you get a new pod
  local_pf.sh      # run on your Mac to forward a port to the pod
  pod_setup.sh     # run on the pod itself
  README.md
```

---

## Mac setup (one time only)

Clone this repo somewhere permanent on your Mac:

```bash
git clone https://github.com/jmichaux/runpod_utils.git ~/runpod_utils
```

Make the scripts executable:

```bash
chmod +x ~/runpod_utils/local_setup.sh ~/runpod_utils/local_pf.sh
```

You need an SSH key at `~/.ssh/id_ed25519` — `local_setup.sh` wires this as the identity file for `ssh runpod`. If you don't have one:

```bash
ssh-keygen -t ed25519 -C "you@email.com"
```

Add the **public** key to your RunPod account's SSH keys (RunPod dashboard → Settings → SSH Public Keys) so it gets injected into each new pod's `authorized_keys`:

```bash
cat ~/.ssh/id_ed25519.pub
```

> Optional: if you also want to push/pull from GitHub on your Mac, add the same key at https://github.com/settings/ssh/new. The workflow below does all git operations from the pod, so this isn't required.

---

## Every time you spin up a new pod

### 1. Get the connection details

In the RunPod dashboard, find your pod's IP and SSH port under **Connect**. They'll look like `203.0.113.42:22042`.

### 2. Update your local SSH config

```bash
bash ~/runpod_utils/local_setup.sh 203.0.113.42:22042
```

### 3. SSH into the pod

```bash
ssh runpod
```

### 3b. (Recommended) Open the pod in VS Code

Once `local_setup.sh` has registered the `runpod` host, VS Code's Remote-SSH extension can connect using the same alias.

One-time setup:

1. Install the [Remote - SSH](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-ssh) extension.

Each new pod (after step 2):

1. `Cmd+Shift+P` → **Remote-SSH: Connect to Host…** → pick `runpod`.
2. Once connected, **File → Open Folder…** → `/workspace` (the persistent volume).
3. Open the integrated terminal (``Ctrl+` ``) — it's a shell on the pod, so steps 4–7 below can be run from there instead of a separate `ssh runpod` session.

> If VS Code hangs on "Setting up SSH Host runpod", it's usually because `StrictHostKeyChecking no` got bypassed by a stale entry. `local_setup.sh` rewrites the host block on each run, so re-running it fixes most issues.

### 4. Get this repo onto the pod

The pod doesn't have a GitHub-registered SSH key yet (that happens in step 5), so use HTTPS:

```bash
git clone https://github.com/jmichaux/runpod_utils.git
```

### 5. Run the pod setup script

```bash
bash runpod_utils/pod_setup.sh
```

**Flags** — all optional, defaults install both Claude Code and Codex:

```bash
bash runpod_utils/pod_setup.sh --install-codex=0    # Claude only
bash runpod_utils/pod_setup.sh --install-claude=0   # Codex only
bash runpod_utils/pod_setup.sh --install-claude=0 --install-codex=0  # neither
```

You can pass identity and key info to wire everything up in one shot:

```bash
GH_USER=yourname \
GIT_NAME='Your Name' \
GIT_EMAIL='you@email.com' \
OPENAI_API_KEY='sk-...' \
bash runpod_utils/pod_setup.sh --install-codex=0
```

### 6. Follow the printed checklist

At the end the script prints a "Do next" list. At minimum:

- Add your SSH public key to GitHub (printed by the script — only on first pod or after monthly rotation)
- Run `claude login` if you're using Claude Code and no auth backup was found
- Run `gh auth login`
- Run `source ~/.bashrc`

### 7. Run your project setup script

Go to your project repo and run its own setup script:

```bash
cd ~/my-project
bash setup_project.sh
```

---

## Port forwarding

To forward a port from the pod to your Mac (e.g. for Jupyter):

```bash
bash ~/runpod_utils/local_pf.sh 8888
```

Or with different local and remote ports:

```bash
bash ~/runpod_utils/local_pf.sh 8080 8888
```

Press `Ctrl+C` to stop the tunnel. The tunnel also gives you an interactive shell — just exit the shell to close it.

---

## What persists across pod restarts

| What | Where | Survives restart? |
|---|---|---|
| Code / checkpoints | `/workspace/` | ✅ Yes |
| HuggingFace model cache | `/workspace/.cache/huggingface` | ✅ Yes |
| SSH key | `/workspace/.ssh/` | ✅ Yes |
| API secrets | `/workspace/.pod-secrets` | ✅ Yes |
| Conda environments | `/root/conda-envs/` | ❌ No — rebuilt from `environment.yml` |
| Installed binaries | container FS | ❌ No — reinstalled by `pod_setup.sh` |

Always run `pod_setup.sh` on a fresh pod, even after a restart. It's idempotent — safe to run multiple times, skips anything already installed.

---

## SSH key rotation

`pod_setup.sh` rotates your SSH key monthly. When this happens it prints a warning. You'll need to:

1. Copy the new public key: `cat ~/.ssh/id_ed25519.pub`
2. Add it to GitHub: https://github.com/settings/ssh/new
3. Delete the old key: https://github.com/settings/keys
4. Verify: `ssh -T git@github.com`
