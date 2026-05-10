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

### 1. Clone this repo somewhere permanent

```bash
git clone https://github.com/jmichaux/runpod_utils.git ~/runpod_utils
chmod +x ~/runpod_utils/local_setup.sh ~/runpod_utils/local_pf.sh
```

### 2. Make sure you have an SSH key on your Mac

`local_setup.sh` wires `~/.ssh/id_ed25519` as the identity file for `ssh runpod`. If you don't already have one:

```bash
ssh-keygen -t ed25519 -C "you@email.com"
```

### 3. Register the public key with RunPod

This is what lets you `ssh runpod` at all. RunPod copies any account-level SSH public keys into every new pod's `~/.ssh/authorized_keys` at boot, so once this is done you don't have to redo it per-pod.

1. Go to the RunPod console → **Settings** → **SSH Public Keys** ([direct link](https://www.runpod.io/console/user/settings)).
2. Click **Add Public Key** and paste the contents of:

   ```bash
   cat ~/.ssh/id_ed25519.pub
   ```
3. Save.

> Also make sure the pod template you're using has SSH exposed — most official RunPod templates do, and the dashboard will show an IP/port under **Connect** if so. If you only see "Web Terminal," pick a template with SSH enabled.

### 4. (Optional) Register the same key with GitHub on your Mac

Only needed if you want to git-push from your Mac. The workflow below does all git operations from the pod, so this is optional. If you want it: paste `cat ~/.ssh/id_ed25519.pub` at https://github.com/settings/ssh/new.

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
3. Open the integrated terminal (``Ctrl+` ``) — it's a shell on the pod, so steps 4–6 below can be run from there instead of a separate `ssh runpod` session.

> If VS Code hangs on "Setting up SSH Host runpod", it's usually because `StrictHostKeyChecking no` got bypassed by a stale entry. `local_setup.sh` rewrites the host block on each run, so re-running it fixes most issues.

### 4. Get `pod_setup.sh` onto the pod

The base image may or may not have `git` — some RunPod templates do, minimal ones don't. Try these in order:

```bash
# Option 1 — git clone (preferred; works if git is on the base image)
git clone https://github.com/jmichaux/runpod_utils.git
cd runpod_utils

# Option 2 — curl (works without git; downloads the file so you can inspect
# before running, rather than piping to bash)
curl -fsSLO https://raw.githubusercontent.com/jmichaux/runpod_utils/main/pod_setup.sh

# Option 3 — scp from your Mac (fallback if neither git nor curl is on the pod).
# Run this on your Mac, not the pod:
scp ~/runpod_utils/pod_setup.sh runpod:~/
```

Then run it on the pod:

```bash
bash pod_setup.sh
```

> Editing this repo: option 1 gives you a real git checkout, but the pod doesn't have GitHub auth wired up until `pod_setup.sh` finishes. The expected workflow is to edit `runpod_utils` on your Mac (cloned in Mac-setup step 1) and push from there; pods pull the latest `main` on each bring-up. To iterate on `pod_setup.sh` from the pod itself, finish step 5 first, then `git clone` (or change the existing clone's remote to SSH) once GitHub auth is set up.

**Flags** — all optional, defaults install both Claude Code and Codex:

```bash
bash pod_setup.sh --install-codex=0    # Claude only
bash pod_setup.sh --install-claude=0   # Codex only
bash pod_setup.sh --install-claude=0 --install-codex=0  # neither
```

You can pass identity and key info to wire everything up in one shot:

```bash
GH_USER=yourname \
GIT_NAME='Your Name' \
GIT_EMAIL='you@email.com' \
OPENAI_API_KEY='sk-...' \
bash pod_setup.sh --install-codex=0
```

### 5. Follow the printed checklist

At the end the script prints a "Do next" list. At minimum:

- Add your SSH public key to GitHub (printed by the script — only on first pod or after monthly rotation)
- Run `claude login` if you're using Claude Code and no auth backup was found
- Run `gh auth login`
- Run `source ~/.bashrc`

### 6. Clone and set up your project

`pod_setup.sh` installed git, so now you can clone your actual project repo and run its setup script:

```bash
cd /workspace
git clone <your-project-repo>
cd <your-project>
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
