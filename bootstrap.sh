#!/usr/bin/env bash
set -euo pipefail

# ───────── banner ─────────
echo -e "\n\033[1;33m*** Ubuntu 22.04+ required – NOT tested on macOS / WSL / CentOS ***\033[0m"
[[ $EUID -eq 0 ]] && { echo "❌  Run as an unprivileged user (with sudo), not root."; exit 1; }

# ───────── helpers ─────────
prompt()  { local v=$1 d=$2; shift 2; read -rp "$*${d:+ [$d]}: " a; printf -v "$v" '%s' "${a:-$d}"; }
secret()  { local v=$1; shift; read -srp "$*: " a; echo; printf -v "$v" '%s' "$a"; }
confirm() { read -rp "Continue? [y/N]: " a; [[ $a =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; } }
log()     { printf "\e[1;32m▸ %s\e[0m\n" "$*"; }
warn()    { printf "\e[1;33m! %s\e[0m\n" "$*"; }

# ───────── user input ─────────
prompt DEPLOY_TARGET "ec2"             "Deploy target (ec2|local)"
prompt GITHUB_USER   ""                "GitHub username"
prompt GITHUB_REPO   "python-app"      "GitHub repository name to create/use"
secret GITHUB_PAT    "GitHub PAT (repo+workflow)"
prompt DOCKERHUB_USER ""               "Docker Hub username"
secret DOCKERHUB_PAT  "Docker Hub PAT/password"

if [[ $DEPLOY_TARGET == ec2 ]]; then
  PUBLIC_IP=$(curl -s ifconfig.me || curl -s https://checkip.amazonaws.com)
  BASE_DOMAIN="${PUBLIC_IP}.nip.io"
  echo "→ Using nip.io domain: $BASE_DOMAIN"
else
  prompt BASE_DOMAIN "test.com"        "Base domain for ingress"
fi

prompt APP_NS       "python"           "App namespace"
prompt ARGO_NS      "argo-cd"          "Argo CD namespace"
prompt RUNNER_NS    "actions-runner-system" "Self-hosted runner namespace"
prompt KIND_CLUSTER "devcluster"       "(local) kind cluster name"
confirm

# ───────── derived vars ─────────
img_repo="$DOCKERHUB_USER/python-app"     # exported later for yq
py_host="python-app.${BASE_DOMAIN}"
argo_host="argo.${BASE_DOMAIN}"

# ───────── install prereqs ─────────
log "Installing base packages"
sudo apt-get update -qq
sudo apt-get install -y curl gnupg ca-certificates lsb-release python3 python3-pip jq

install_bin(){ log "Installing $1"; curl -fsSL "$2" -o "$1"; chmod +x "$1"; sudo mv "$1" /usr/local/bin/; }

command -v docker  &>/dev/null || {
  log "Installing Docker Engine"
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc >/dev/null
  echo \
   "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker "$USER"
}

command -v kubectl &>/dev/null || install_bin kubectl "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
command -v kind    &>/dev/null || install_bin kind    https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64
command -v helm    &>/dev/null || { log "Installing Helm"; curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash; }
command -v yq      &>/dev/null || { log "Installing yq"; wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64; chmod +x /usr/local/bin/yq; }
log "yq version → $(yq --version)"

# Use sudo if current shell not in docker group yet
if docker info &>/dev/null; then DOCKER=docker; KIND=kind; else warn "Using sudo for docker/kind"; DOCKER='sudo docker'; KIND='sudo kind'; fi

# ───────── Local kind (if requested) ─────────
if [[ $DEPLOY_TARGET == local ]]; then
  log "Creating kind cluster $KIND_CLUSTER"
  cat >kind.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
  - containerPort: 443
    hostPort: 443
EOF
  $KIND delete cluster --name "$KIND_CLUSTER" >/dev/null 2>&1 || true
  $KIND create cluster --name "$KIND_CLUSTER" --config kind.yaml
  log "Deploying ingress-nginx (kind)"
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.0/deploy/static/provider/kind/deploy.yaml
  kubectl -n ingress-nginx wait deployment ingress-nginx-controller --for=condition=Available --timeout=180s
fi

# ───────── sample Flask app + image ─────────
log "Creating sample Flask app"
mkdir -p src
cat >src/app.py <<'PY'
from flask import Flask, jsonify
import datetime, socket
app = Flask(__name__)
@app.route("/api/v1/info")
def info():
    return jsonify({
        "time": datetime.datetime.now().strftime("%I:%M:%S%p on %B %d, %Y"),
        "hostname": socket.gethostname(),
        "message": "You are doing great, little human! <3",
        "deployed_on": "kubernetes"
    })
@app.route("/api/v1/healthz")
def health(): return jsonify({"status":"up"}), 200
if __name__ == "__main__": app.run(host="0.0.0.0", port=5000)
PY

cat >Dockerfile <<'DOCKER'
FROM python:3.12-alpine
WORKDIR /app
COPY src/ /app
RUN pip install --no-cache-dir flask==3.0.3
EXPOSE 5000
CMD ["python","/app/app.py"]
DOCKER

log "Building & pushing seed image"
echo "$DOCKERHUB_PAT" | $DOCKER login -u "$DOCKERHUB_USER" --password-stdin
$DOCKER build -t "$img_repo:v0" .
$DOCKER push "$img_repo:v0"

# ───────── Helm chart ─────────
log "Creating Helm chart"
rm -rf charts/python-app || true
helm create charts/python-app >/dev/null
rm -rf charts/python-app/charts charts/python-app/templates/{tests,serviceaccount.yaml,hpa.yaml}

# export so yq can access via env()
export IMG_REPO="$img_repo" PY_HOST="$py_host"

yq -i '
  .image.repository = env(IMG_REPO) |
  .image.tag        = "v0"          |
  .service.port     = 5000          |
  .serviceAccount.create = false    |
  .ingress.enabled  = true          |
  .ingress.className= "nginx"       |
  .ingress.tls      = true          |
  .ingress.hosts    = [{"host": env(PY_HOST), "paths":[{"path":"/","pathType":"Prefix"}]}]
' charts/python-app/values.yaml

# ───────── Git repository bootstrap ─────────
log "Pushing initial commit to GitHub"
git init -q && git branch -M main || true
git add .
git -c user.email="$GITHUB_USER@users.noreply.github.com" \
    -c user.name="$GITHUB_USER" commit -m "initial bootstrap" || true
API="https://api.github.com/repos/$GITHUB_USER/$GITHUB_REPO"
[[ $(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: token $GITHUB_PAT" $API) == 404 ]] && {
  warn "Repo not found – creating"
  curl -s -H "Authorization: token $GITHUB_PAT" -d '{"name":"'"$GITHUB_REPO"'","private":false}' https://api.github.com/user/repos >/dev/null
}
git remote add origin https://github.com/$GITHUB_USER/$GITHUB_REPO.git || true
git push -u https://"$GITHUB_USER":"$GITHUB_PAT"@github.com/"$GITHUB_USER"/"$GITHUB_REPO".git main

# ───────── Argo CD ─────────
log "Installing Argo CD via Helm"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo update >/dev/null

cat >argocd-values.yaml <<EOF
global:
  ingress:
    enabled: true
    className: nginx
    hosts: ["$argo_host"]
    tls: true
redis-ha: { enabled: false }
server: { replicas: 1 }
repoServer: { replicas: 1 }
applicationSet: { replicas: 1 }
EOF

helm upgrade --install argo-cd argo/argo-cd -n "$ARGO_NS" --create-namespace -f argocd-values.yaml --wait --timeout 5m
argo_pass=$(kubectl -n "$ARGO_NS" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)

log "Installing Argo CD CLI"
curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x argocd && sudo mv argocd /usr/local/bin/

# port-forward for CLI login
log "Port-forwarding Argo CD (localhost:9443)"
kubectl -n "$ARGO_NS" port-forward svc/argo-cd-argocd-server 9443:443 >/tmp/argo_pf.log 2>&1 &
pf_pid=$!
sleep 5

log "Logging into Argo CD CLI"
argocd login localhost:9443 --insecure --grpc-web --username admin --password "$argo_pass"

log "Registering repo & creating application"
argocd repo add https://github.com/$GITHUB_USER/$GITHUB_REPO.git --username "$GITHUB_USER" --password "$GITHUB_PAT" --insecure >/dev/null || true
argocd app create python-app \
  --repo https://github.com/$GITHUB_USER/$GITHUB_REPO.git \
  --path charts/python-app \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace "$APP_NS" \
  --sync-policy Automated --self-heal >/dev/null || true
argocd app sync python-app >/dev/null

kill "$pf_pid" && wait "$pf_pid" 2>/dev/null || true

# ───────── Actions Runner Controller ─────────
log "Deploying self-hosted runner"
helm repo add actions-runner-controller https://actions-runner-controller.github.io/actions-runner-controller >/dev/null
helm repo update >/dev/null
kubectl create namespace "$RUNNER_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$RUNNER_NS" create secret generic controller-manager \
  --from-literal=github_token="$GITHUB_PAT" --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install arc actions-runner-controller/actions-runner-controller \
  -n "$RUNNER_NS" --set syncPeriod=30s --set githubWebhookServer.enabled=false --wait

cat <<EOF | kubectl apply -f -
apiVersion: actions.summerwind.dev/v1alpha1
kind: RunnerDeployment
metadata:
  name: selfhosted-python
  namespace: $RUNNER_NS
spec:
  template:
    spec:
      repository: $GITHUB_USER/$GITHUB_REPO
      labels: ["self-hosted"]
EOF
kubectl -n "$RUNNER_NS" rollout status deploy/selfhosted-python-runner-deployment --timeout=300s || true

# ───────── CI/CD workflow file ─────────
log "Adding GitHub Actions workflow"
mkdir -p .github/workflows
cat >.github/workflows/ci-cd.yaml <<'YAML'
name: CI-CD
on:
  push:
    paths: ["src/**"]
    branches: [main]

jobs:
  ci:
    runs-on: ubuntu-latest
    outputs:
      commit: ${{ steps.sha.outputs.sha6 }}
    steps:
      - id: sha
        run: echo "sha6=${GITHUB_SHA::6}" >> "$GITHUB_OUTPUT"
      - uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}
      - uses: docker/build-push-action@v6
        with:
          push: true
          tags: IMAGE_REPO_PLACEHOLDER:${{ steps.sha.outputs.sha6 }}

  cd:
    needs: ci
    runs-on: self-hosted
    steps:
      - uses: actions/checkout@v4
      - run: |
          command -v yq >/dev/null || {
            wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
            chmod +x /usr/local/bin/yq
          }
          yq -i '.image.tag = "${{ needs.ci.outputs.commit }}"' charts/python-app/values.yaml
      - uses: EndBug/add-and-commit@v9
        with:
          message: "Bump image tag → ${{ needs.ci.outputs.commit }}"
      - run: |
          kubectl -n ARGO_NS_PLACEHOLDER annotate --overwrite application python-app auto-sync=$(date +%s)
YAML
sed -i "s#IMAGE_REPO_PLACEHOLDER#$img_repo#g" .github/workflows/ci-cd.yaml
sed -i "s#ARGO_NS_PLACEHOLDER#$ARGO_NS#g"       .github/workflows/ci-cd.yaml

git add .github/workflows/ci-cd.yaml
git commit -m "Add CI/CD workflow" || true
git push https://"$GITHUB_USER":"$GITHUB_PAT"@github.com/"$GITHUB_USER"/"$GITHUB_REPO".git main

# ───────── finish ─────────
cat <<EOF

=================================================================
🔑  Add these repo secrets (Settings → Secrets → Actions):

  DOCKERHUB_USERNAME = $DOCKERHUB_USER
  DOCKERHUB_TOKEN    = (your Docker Hub PAT)
  ARGOCD_PASSWORD    = $argo_pass
-----------------------------------------------------------------
Argo CD UI : https://$argo_host   (admin / \$ARGOCD_PASSWORD)
Flask API  : https://$py_host/api/v1/info
Repo       : https://github.com/$GITHUB_USER/$GITHUB_REPO
=================================================================
\033[1;32mBootstrap complete – push a change to ./src/ and watch CI/CD!\033[0m
EOF

