# Cluster

What every project of mine shares to run in the Kubernetes cluster (k3s) on the VPS and deploy on a push to `main`: the one command that launches a project, the script GitHub's workflows are allowed to run, and the template a project's files are made from.

The projects themselves keep their own files (`Dockerfile`, `k8s/`, `.github/workflows/image.yml`) in their own repositories.

| File | Where it runs | What it does |
|---|---|---|
| `k8s-launch` | PC, Git Bash | **The one command.** Takes a project that exists and builds, and makes it a live site that deploys on push |
| `k8s-up-project` | VPS, as root, through SSH | The VPS half of a launch: namespace, settings, pods, nginx site, certificate. Run by `k8s-launch` |
| `k8s-add-project` | VPS, with sudo | Makes a project's deploy key and pins it to the project's namespace. Run by `k8s-launch` |
| `k8s-new-project` | PC and VPS | Fills in `k8s-template/` for one project. Run by `k8s-launch` and by `k8s-up-project` |
| `k8s-deploy` | VPS, as root, through SSH | What a pipeline may do: make one deployment run the image of one commit; goes back by itself if the new pod is not healthy |
| `sudoers-deploy` | VPS | Lets the `deploy` user run `k8s-deploy` and nothing else |
| `k8s-template/` | | The files a project needs, and `README.md`, the same launch done by hand |
| `*.test.sh`, `k8s-test-tools.sh` | PC | The scripts' checks |

## Launching a project

A project is yours to create, in whatever language. Once it exists and builds, on the PC, in Git Bash, in this folder:

```bash
./k8s-launch ../MyApp
```

It asks for the SSH key's passphrase, the project's name, its site (`<name>.remservers.me` unless you say otherwise) and, if the folder is not on GitHub yet, a repository name. Then it shows what it is about to do and asks once. After that it does not stop until the site answers over HTTPS:

1. checks everything it can without changing anything;
2. makes the folder a git repository and creates the GitHub repository (public), if there is none;
3. writes the cluster files into the project (`k8s-new-project`);
4. stores the web app's build values (`VITE_...`) as GitHub variables, and the deploy key as the secret `DEPLOY_KEY`;
5. has the VPS create the namespace, the backend's settings, the pods, the nginx site and the certificate (`k8s-up-project`);
6. commits, pushes, waits for the pipeline, and fetches the site.

The pods are created before the push, waiting for an image that does not exist yet. The push builds it and the pipeline's deploy step hands it to them, so the very first run is green.

**What the project must be**

- A web app in `frontend/`, and optionally a backend in `backend/`. The web app is served at `/`, the backend at `/api`.
- A piece with a `Dockerfile` is used as it is, whatever the language. The launch then asks four things about its image: the port it listens on, an address that answers 200 without a login, the user number it runs as, and its memory ceiling. The image must not run as root; the cluster refuses those.
- A piece without one gets the template's, if it is a Vite web app (`npm run build` into `dist/`) or a Node backend (`npm run build` into `dist/`, started with `node dist/server.js` on port 3000). Anything else: write a Dockerfile for it first.
- A public repository. The cluster downloads images without a login.

**Settings**

- `VITE_` values are read from `frontend/.env.production`, else `frontend/.env`. They are shown before anything happens, because they end up readable in the built site.
- The backend's settings are read from `backend/.env.production`, else `backend/.env`, and become the secret `backend-env` in the project's namespace. They travel over the SSH connection straight into the secret: never printed, never on a command line, never in the repository or the image. With no file, the secret is created empty.

**Running it again** is safe: every step looks before it acts. After the first launch it never commits again. It does its part and leaves the commit to you:

- a `backend/` that was added gets its files, its pod and its `/api` route. Until you commit and push, that pod waits for its image and `/api` answers 502;
- `./k8s-launch ../MyApp --settings` sends the backend's settings file again and restarts the backend. Without that flag, settings that exist are never replaced.

**The first commit is checked.** A folder that is not on GitHub yet becomes public with everything in it. Before that, the launch looks for files that look like secrets (`.env`, key and certificate files, service-account files), for private keys inside files, and for any value of the backend's settings written into a file. It stops on any of them.

**What it does not do:** create the project, a database for it, or a monitor for its site; remove a project (see "Taking a project out again" in `k8s-template/README.md`); sites behind the Cloudflare tunnel; a project with no web app.

### Before the first launch (done once)

1. **A passphrase on the SSH key** the PC uses for the VPS: `ssh-keygen -p -f ~/.ssh/id_rsa`. The launch refuses a key without one. It asks for the passphrase once per run and keeps the key unlocked in memory only while it runs.
2. **GitHub's command-line tool**, logged in as the account that owns the repositories: `winget install --id GitHub.cli`, then `gh auth login` (answer "No" when it offers to handle git's own login).
3. **One wildcard DNS record**, `*.remservers.me` to the VPS, "DNS only". After that no project needs a DNS step.
4. **A catch-all nginx site on the VPS**, so a name nobody claims gets no answer instead of some other site (`/etc/nginx/sites-available/000-catch-all`: `default_server` on 80 and 443, `return 444`).
5. The VPS set up as below.

### What keeps it safe

- The VPS never applies a file from the PC. `k8s-up-project` is handed values only (a name, a site, addresses, a port, a path, a user number, a memory size), checks every one, and fills in the template that is on the VPS.
- A namespace is marked with the repository it was made for. No other project can launch into it, and namespaces made by hand, like the cluster's own, cannot be taken over.
- The launch stops unless the VPS has exactly the version of these scripts that is on the PC, committed and pushed.
- The deploy key is made on the VPS and handed straight to GitHub. It is never written to the PC's disk and never shown.
- What a pipeline may do on the VPS is unchanged: `k8s-deploy`, for its own namespace, and nothing else.

## Deploy on push

A project's GitHub workflow builds its image, then logs in to the VPS over SSH as the `deploy` user and asks for one deployment to run that commit's image. `k8s-deploy` sets the image, waits for the new pod, and goes back to the previous image by itself if the new pod is not healthy within two minutes (the workflow then fails).

What a project's key can do is fixed by its line in `authorized_keys`: no shell, no forwarding, only `k8s-deploy` for that project's namespace. The script accepts a deployment name and a full commit and changes nothing but the image's tag. The cluster's own port (6443) stays closed to the internet.

The pipeline only updates what already exists. A project's namespace, deployments and services are created once by hand (`kubectl apply`), and so is any later change to a `k8s/*.yaml` file. Applying a deployment file also sets its image back to `:main`, the newest build.

## Setting up the VPS (done once)

```bash
sudo git clone https://github.com/remuriin/Cluster.git /opt/cluster
sudo install -o root -g root -m 755 /opt/cluster/k8s-deploy /usr/local/sbin/k8s-deploy
sudo install -o root -g root -m 440 /opt/cluster/sudoers-deploy /etc/sudoers.d/deploy
sudo visudo -cf /etc/sudoers.d/deploy
sudo useradd --system --create-home --shell /bin/sh deploy
sudo install -d -o root -g root -m 755 /home/deploy/.ssh
```

`k8s-deploy` runs from its installed copy. After a change to it here: `cd /opt/cluster && sudo git pull`, then the first `install` line again.

## Tests

```bash
bash k8s-template.test.sh        # k8s-new-project
bash k8s-up-project.test.sh      # k8s-up-project and k8s-add-project
bash k8s-launch.test.sh          # k8s-launch, from end to end
docker run --rm -v "$PWD":/d:ro bash:5 bash /d/k8s-deploy.test.sh
```

The first three need only bash and git. They put pretend programs (`gh`, `ssh`, `kubectl`, `nginx`, `certbot`) in place of the real ones and keep every file in a throwaway folder; in the last of the three, the pretend SSH runs the real VPS scripts, so both halves of a launch are checked together. `k8s-deploy`'s test runs in a throwaway container.
