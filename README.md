# Cluster

What every project of mine shares to run in the Kubernetes cluster (k3s) on the VPS and deploy on a push to `main`: the script GitHub's workflows are allowed to run, the template for a new project, and the two scripts that fill it in.

The projects themselves keep their own files (`Dockerfile`, `k8s/`, `.github/workflows/image.yml`) in their own repositories.

| File | Where it runs | What it does |
|---|---|---|
| `k8s-deploy` | VPS, as root, through SSH | Makes one deployment run the image of one commit; goes back by itself if the new pod is not healthy |
| `sudoers-deploy` | VPS | Lets the `deploy` user run `k8s-deploy` and nothing else |
| `k8s-add-project` | VPS, with sudo | Makes a project's deploy key and pins it to the project's namespace |
| `k8s-new-project` | PC, Git Bash | Copies `k8s-template/` into a project's repository with the names filled in |
| `k8s-template/` | | The files a project needs, and `README.md`, the checklist for a new project |
| `*.test.sh` | PC | The scripts' checks |

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

## A new project

`k8s-template/README.md`, from the top.

## Tests

```bash
bash k8s-template.test.sh
docker run --rm -v "$PWD":/d:ro bash:5 bash /d/k8s-deploy.test.sh
docker run --rm -v "$PWD":/d:ro alpine sh -c "apk add -q bash openssh-keygen coreutils && bash /d/k8s-template.test.sh vps"
```

The last two put pretend programs in place of the real ones, so they only ever run in a throwaway container.
