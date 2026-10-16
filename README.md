# Cluster

What every project of mine shares to run in the Kubernetes cluster (k3s) on the VPS: the one command that launches a project, the template a project's files are made from, and the nginx sites in front of the cluster.

What runs in the cluster is decided by the private repository `Fleet`: Flux, inside the cluster, applies whatever it says. A project's own repository holds its code, its Dockerfiles and the workflow that builds its images. Nothing logs in to the VPS to deploy.

| File | Where it runs | What it does |
|---|---|---|
| `k8s-launch` | PC, Git Bash | **The one command.** Takes a project that exists and builds, and makes it a live site that deploys on push |
| `k8s-new-project` | PC | Fills in `k8s-template/` for one project: its own files, and its folder in Fleet. Run by `k8s-launch` |
| `k8s-template/` | | The files a project needs (`fleet/` is its folder in Fleet), and `README.md`, the same launch done by hand |
| `nginx/` | VPS, `/etc/nginx/sites-available/` | The sites in front of the cluster: `projects` (every launched project), `flux` (GitHub's webhooks to Flux), `rem-servers` (the portal) |
| `*.test.sh` | PC | The scripts' checks |

## Launching a project

A project is yours to create, in whatever language. Once it exists and builds, on the PC, in Git Bash, in this folder:

```bash
./k8s-launch ../MyApp
```

It asks for a repository name if the folder is not on GitHub yet, and for the project's name, which is also its site: `<name>.remservers.me`. Then it shows what it is about to do and asks once. After that it does not stop until the site answers over HTTPS:

1. checks everything it can without changing anything (it also brings the Fleet folder up to date);
2. makes the folder a git repository and creates the GitHub repository (public), if there is none;
3. writes the project's workflow, and a Dockerfile for each piece that has none (`k8s-new-project repo`);
4. stores the web app's build values (`VITE_...`) as GitHub variables, and adds the webhook that tells Flux about each build;
5. commits, pushes, and waits for the images to be built;
6. writes the project's folder in Fleet with those images (`k8s-new-project fleet`), encrypts the backend's settings into it, commits and pushes Fleet;
7. waits for the site.

Flux sees the Fleet commit within seconds (a webhook), creates the namespace `app-<name>` and the pods, and the generic nginx site `projects` serves `<name>.remservers.me` with the wildcard certificate. No nginx file, certificate or DNS record per project.

**What the project must be**

- A web app in `frontend/`, and optionally a backend in `backend/`. The web app is served at `/`, the backend at `/api`.
- A piece with a `Dockerfile` is used as it is, whatever the language. The launch then asks four things about its image: the port it listens on, an address that answers 200 without a login, the user number it runs as, and its memory ceiling. The image must not run as root; the cluster refuses those.
- A piece without one gets the template's, if it is a Vite web app (`npm run build` into `dist/`) or a Node backend (`npm run build` into `dist/`, started with `node dist/server.js` on port 3000). Anything else: write a Dockerfile for it first.
- A public repository. The cluster downloads images without a login.
- A name that is free: not a site that exists (`rag`, `portal`, `panel`, `status`, `monitor`, `node`, `flux`, ...), not a part of the cluster, not already in Fleet.

**Settings**

- `VITE_` values are read from `frontend/.env.production`, else `frontend/.env`. They are shown before anything happens, because they end up readable in the built site.
- The backend's settings are read from `backend/.env.production`, else `backend/.env`. SOPS encrypts each value with the cluster's public key into `apps/<name>/backend.env` in Fleet; only the cluster can read them, and Flux turns them into the Secret `backend-env`. The plain values are never printed, never on a command line, never in a repository. With no file, the backend starts without settings.

**Running it again** is safe: every step looks before it acts. After the first launch it never commits again. It does its part and leaves the commits to you:

- a `backend/` that was added gets its Dockerfile, its part of the workflow, and its files in Fleet. Commit and push the project first (that builds the backend's image), then Fleet;
- `./k8s-launch ../MyApp --settings` encrypts the backend's settings file into Fleet again. Commit and push Fleet, and the backend restarts with them by itself. Without that flag, settings that exist are never replaced.
- a first launch that stopped (a red pipeline, say) goes on from where it stopped.

**The first commit is checked.** A folder that is not on GitHub yet becomes public with everything in it. Before that, the launch looks for files that look like secrets (`.env`, key and certificate files, service-account files), for private keys inside files, and for any value of the backend's settings written into a file. It stops on any of them.

**Taking a project out:** delete `apps/<name>/` and `clusters/rem-vm/app-<name>.yaml` from Fleet in one commit and push. Flux deletes the namespace and everything in it, and the site goes quiet. On GitHub, delete the repository, and its image packages (`<name>-web`, `<name>-api`) under Profile, Packages: deleting a repository leaves them behind.

**What it does not do:** create the project, a database for it, or a monitor for its site; blue-green for it (add a `Canary` in its Fleet folder like the ones in `apps/rem-servers/`); sites behind the Cloudflare tunnel; a project with no web app.

### Before the first launch (done once)

1. **GitHub's command-line tool**, logged in as the account that owns the repositories: `winget install --id GitHub.cli`, then `gh auth login` (answer "No" when it offers to handle git's own login).
2. **SOPS and age on the PC**: `winget install --id SecretsOPerationS.SOPS -e` and `winget install --id FiloSottile.age -e`.
3. **Fleet next to this folder**: `git clone https://github.com/remuriin/Fleet.git`. It holds `.sops.yaml` (the cluster's age public key) and `projects-hook` (the path of the shared webhook), which the launch reads.
4. **The webhook secret** in `~/.fleet/webhook-token`, the same one the cluster has (Secret `webhook-token` in `flux-system`).
5. In place already, on the VPS and in Cloudflare: the wildcard DNS record `*.remservers.me` ("DNS only"), the wildcard certificate, the nginx sites `projects` and `flux`, and the catch-all `000-catch-all` (unknown names get no answer).

### What keeps it safe

- Nothing logs in to the VPS: not the launch, not a pipeline. The cluster pulls from Fleet and from ghcr.io.
- A project lives in `app-<name>`, and nginx only reaches namespaces with that prefix, so no other namespace can become public by accident.
- A namespace is marked with the repository it was made for. A second repository cannot launch under a name that is taken.
- The backend's settings are in Fleet only encrypted. The key that opens them is in the cluster (and in my password manager), never in a repository.
- The webhook secret goes from its file to GitHub, never onto a command line or the screen. A webhook call can only ask Flux to look now.

## Deploy on push

A project's workflow builds its images and pushes them with three tags: the commit, `main`, and `main-<commit>-<commit time>`. GitHub then calls Flux's webhook. Flux finds the new `main-...` tag (the highest commit time wins), its bot writes it into the project's file in Fleet, and Flux rolls the pod. Build done to new pod: about 10 to 30 seconds.

Going back: in Fleet, take the `# {"$imagepolicy": ...}` marker off the image line and set the old tag by hand (the bot then leaves that line alone). Put the marker back to follow `main` again. For the apps under blue-green (Flagger), a new version that fails its checks is thrown away by itself.

## Tests

```bash
bash k8s-template.test.sh        # k8s-new-project
bash k8s-launch.test.sh          # k8s-launch, from end to end
```

Both need only bash and git. They put pretend programs (`gh`, `sops`, `curl`) in place of the real ones, keep GitHub and Fleet as folders, and keep every file in a throwaway folder.

Until 2026-10-14 a pipeline deployed by logging in to the VPS over SSH as the user `deploy` and running `k8s-deploy`, and a launch ran `k8s-up-project` on the VPS. Flux replaced both; the git history before that date has them.
