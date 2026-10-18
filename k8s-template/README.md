# A new project in the cluster, by hand

**`k8s-launch` does all of this in one command** (see the `README.md` one folder up). This page is the same launch step by step: for understanding what the command does, for a project it does not fit, and for when one step has to be redone by hand.

It fits a repository shaped like `RaaS` and `RemServers`: a web app in `frontend/` (built with `npm run build` into `dist/`) and, optionally, a Node backend in `backend/` (`npm run build` into `dist/`, started with `node dist/server.js` on port 3000). A piece that brings its own Dockerfile keeps it; `k8s-new-project` then takes the port, the health address, the user number and the memory ceiling as settings (its first lines say how).

A backend with no web app (an API only) fits too: it gets the whole site. Use `api-only` in both commands below (step 1 and step 4 show how).

How the cluster, Flux and the pipeline work is written up in `DevLogs/cluster/Kubernetes-and-pipeline.md`.

## Before you start

- **A project name**, lowercase with dashes (`my-app`). It becomes the site (`my-app.remservers.me`), the namespace (`app-my-app`) and the start of the image names. It must not be in Fleet's `apps/` yet.
- Fleet cloned next to the `Cluster` folder, up to date (`git pull --rebase`).

## 1. The project's own files (PC, Git Bash)

From the `Cluster` folder. Leave `api` out for a project with no backend.

```bash
./k8s-new-project repo ../MyApp my-app api
```

An API only: `./k8s-new-project repo ../MyApi my-api api-only` (no web app files, no web part in the workflow).

It writes `.github/workflows/image.yml`, and `frontend/Dockerfile`, `frontend/nginx.conf`, `frontend/.dockerignore` (and with a backend `backend/Dockerfile`, `backend/.dockerignore`) for each piece that has no Dockerfile. A file that exists is kept, and it commits nothing.

Then look at what it wrote:

- **Values the web app needs while building** (Vite's `VITE_` ones): an `ARG` line each in `frontend/Dockerfile`, and the same names under `build-args` in the workflow. Both have a commented example. Each one also goes into the repository's **Variables** (Settings, Secrets and variables, Actions).

## 2. GitHub: the repository and its webhook

The repository must be public (the cluster downloads images without a login). Then the webhook, in PowerShell, with the path from Fleet's `projects-hook` file:

```powershell
gh api repos/remuriin/MyApp/hooks -f name=web -F active=true -f "events[]=workflow_run" -f "config[url]=https://flux.remservers.me<path from projects-hook>" -f "config[content_type]=json" -F "config[secret]=@$HOME\.fleet\webhook-token"
```

## 3. Commit, push, and wait for the images

The first run of the workflow builds the images. Note the commit (`git rev-parse HEAD`) and its time (`git show -s --format=%ct HEAD`): the image tag is `main-<commit>-<time>`.

## 4. The project's folder in Fleet (PC, Git Bash)

```bash
./k8s-new-project fleet ../Fleet my-app MyApp main-<commit>-<time> main-<commit>-<time> env
```

(the second tag is the backend's; `env` only if the backend has settings). An API only has one tag, the backend's: `./k8s-new-project fleet ../Fleet my-api MyApi api-only main-<commit>-<time> env`. Its folder has no `web.yaml`, and its route sends the whole site to the backend. It writes `apps/my-app/` (namespace, Deployments, Services, the images Flux watches, the list of them) and `clusters/rem-vm/app-my-app.yaml` (the line that tells Flux to apply that folder).

With settings, encrypt them into the folder (the age public key is in Fleet's `.sops.yaml`):

```bash
tr -d '\r' < ../MyApp/backend/.env > ~/.fleet/plain.env
sops -e --input-type dotenv --output-type dotenv --age age1... ~/.fleet/plain.env > ../Fleet/apps/my-app/backend.env
rm ~/.fleet/plain.env
```

Check two things in what it wrote:

- **The backend's readiness address** in `apps/my-app/api.yaml`: an address that answers 200 without a login. The template asks `/`.
- **Settings that say `localhost`**: inside a pod that is the pod itself. Name the VPS by its own address, `10.0.0.135`, in the `env:` part of `api.yaml` (commented example there).

Commit and push Fleet. Within seconds Flux creates `app-my-app` and the pods, and `https://my-app.remservers.me` answers.

## 5. Check it (VPS)

```bash
sudo flux get kustomizations app-my-app --kubeconfig=/etc/rancher/k3s/k3s.yaml
sudo kubectl -n app-my-app get pods,svc
```

If a pod does not come up: `sudo kubectl -n app-my-app describe pod -l app=api` and `sudo kubectl -n app-my-app logs deployment/api`.

## 6. Write it down

Add the project to `DevLogs/cluster/Kubernetes-and-pipeline.md`: the table of namespaces, and the picture.

## Taking a project out again

In Fleet, delete `apps/my-app/` and `clusters/rem-vm/app-my-app.yaml` in one commit, and push. Flux deletes the namespace and everything in it. On GitHub, delete the repository, and its image packages (Profile, Packages): deleting a repository does not delete them, and a later project with the same name would run into them.
