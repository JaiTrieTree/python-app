#!/usr/bin/env bash
set -euo pipefail

# ───────── banner ─────────
echo -e "\n\033[1;33m★ One-shot K8s / Argo CD / GitHub Actions bootstrap ★\033[0m"
[[ $EUID -eq 0 ]] && { echo "Run as normal user (with sudo), not root"; exit 1; }

# ───────── helper functions ─────────
prompt()  { local v=$1 d=$2; shift 2; read -rp "$*${d:+ [$d]}: " a; printf -v "$v" '%s' "${a:-$d}"; }
secret()  { local v=$1; shift; read -srp "$*: " a; echo; printf -v "$v" '%s' "$a"; }
confirm() { read -rp "Continue? [y/N]: " a; [[ $a =~ ^[Yy]$ ]] || { echo "Aborted"; exit 1; } }
log()     { printf "\e[1;32m▸ %s\e[0m\n" "$*"; }
die()     { printf "\e[1;31m✖ %s\e[0m\n" "$*" >&2; exit 1; }
spinner() { while kill -0 "$1" 2>/dev/null; do printf '.'; sleep 1; done; echo; }

# ───────── user input ─────────
prompt TARGET "ec2"   "Deploy target (ec2 | local-kind)"
prompt GH_USER ""     "GitHub username/owner"
prompt GH_REPO "python-app" "GitHub repository to create/use"
secret GH_PAT  "GitHub Personal Access Token (repo & workflow scopes)"
prompt DH_USER "" "Docker Hub username"
secret DH_PAT  "Docker Hub PAT / password"

if [[ $TARGET == ec2 ]]; then
  PUB_IP=$(curl -s https://checkip.amazonaws.com)
  DOMAIN="${PUB_IP}.nip.io"
  echo "Using nip.io domain: ${DOMAIN}"
else
  prompt DOMAIN "test.local" "Base domain for ingress (kind only)"
fi

prompt APP_NS   "python"    "App namespace"
prompt ARGO_NS  "argo-cd"   "Argo CD namespace"
prompt ARC_NS   "actions-runner-system" "ARC namespace"
prompt KIND_CL  "devcluster" "kind cluster name (local only)"
confirm

# ───────── constants ─────────
IMAGE_REPO="$DH_USER/python-app"
PY_HOST="python-app.${DOMAIN}"
ARGO_HOST="argo.${DOMAIN}"

# ───────── base packages ─────────
log "Installing base packages"
sudo apt-get update -qq
sudo apt-get install -y curl gnupg ca-certificates lsb-release \
                        jq python3 python3-pip

# ───────── CLI installers ─────────
install_bin () { curl -fsSL "$2" -o "$1" && chmod +x "$1" && sudo mv "$1" /usr/local/bin; }

command -v docker >/dev/null || {
  log "Installing Docker Engine"
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc >/dev/null
  echo \
   "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
   | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
       docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker "$USER" || true
  log "Added $USER to docker group (re-login not required for script)"
}

command -v kubectl >/dev/null || \
  install_bin kubectl "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
command -v kind    >/dev/null || install_bin kind https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64
command -v helm    >/dev/null || { curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash; }
command -v yq      >/dev/null || install_bin yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
command -v argocd  >/dev/null || install_bin argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64

DOCKER=docker; KIND=kind
docker info >/dev/null 2>&1 || { DOCKER='sudo docker'; KIND='sudo kind'; }

# ───────── kind (local) ─────────
if [[ $TARGET == local-kind ]]; then
  log "Creating kind cluster $KIND_CL"
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
  $KIND delete cluster --name "$KIND_CL" >/dev/null 2>&1 || true
  $KIND create cluster --name "$KIND_CL" --config kind.yaml
  log "Deploying ingress-nginx (kind)"
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.0/deploy/static/provider/kind/deploy.yaml
  kubectl -n ingress-nginx wait deploy/ingress-nginx-controller --for=condition=Available --timeout=180s
fi

# ───────── sample app / Docker image ─────────
log "Scaffolding Flask app"
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

log "Building and pushing seed image"
echo "$DH_PAT" | $DOCKER login -u "$DH_USER" --password-stdin
$DOCKER build -t "$IMAGE_REPO:v0" .
$DOCKER push "$IMAGE_REPO:v0"

# ───────── Helm chart ─────────
log "Creating Helm chart"
rm -rf charts/python-app || true
helm create charts/python-app >/dev/null
rm -rf charts/python-app/charts charts/python-app/templates/{tests,serviceaccount.yaml,hpa.yaml}

yq eval -i "
  .image.repository = \"$IMAGE_REPO\" |
  .image.tag = \"v0\" |
  .service.port = 5000 |
  .serviceAccount.create = false |
  .ingress.enabled = true |
  .ingress.className = \"nginx\" |
  .ingress.tls = true |
  .ingress.hosts = [{\"host\":\"$PY_HOST\",\"paths\":[{\"path\":\"/\",\"pathType\":\"Prefix\"}]}]
" charts/python-app/values.yaml

# ───────── Git repo bootstrap ─────────
log "Initializing Git repo"
git init -q && git branch -M main || true
git add .
git -c user.email="$GH_USER@users.noreply.github.com" -c user.name="$GH_USER" commit -m "bootstrap" || true

resp=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: token $GH_PAT" https://api.github.com/repos/$GH_USER/$GH_REPO)
if [[ $resp == 404 ]]; then
  log "Creating GitHub repository $GH_REPO"
  curl -s -H "Authorization: token $GH_PAT" -d "{\"name\":\"$GH_REPO\",\"private\":false}" https://api.github.com/user/repos >/dev/null
fi
git remote add origin https://github.com/$GH_USER/$GH_REPO.git 2>/dev/null || true
git push -u https://$GH_USER:$GH_PAT@github.com/$GH_USER/$GH_REPO.git main

# ───────── Argo CD ─────────
log "Installing Argo CD"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo update >/dev/null
cat >argocd-values.yaml <<EOF
global:
  ingress:
    enabled: true
    className: nginx
    hosts: ["${ARGO_HOST}"]
    tls: true
    annotations:
      nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
      nginx.ingress.kubernetes.io/ssl-passthrough: "true"
redis-ha: { enabled: false }
server:
  extraArgs: ["--insecure"]   # allow http for CLI port-forward
EOF
helm upgrade --install argo-cd argo/argo-cd -n "$ARGO_NS" --create-namespace -f argocd-values.yaml --wait --timeout 5m

ARGO_PASS=$(kubectl -n "$ARGO_NS" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)

# ───────── Argo CD CLI login (port-forward → localhost) ─────────
log "Port-forwarding Argo CD (9443) for bootstrap"
kubectl -n "$ARGO_NS" port-forward svc/argo-cd-argocd-server 9443:443 >/tmp/argo_pf.log 2>&1 &
PF_PID=$!
sleep 5
argocd login localhost:9443 --username admin --password "$ARGO_PASS" --insecure --grpc-web

log "Registering repo & creating Application"
# Repo secret via K8s (avoids RBAC trouble)
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-${GH_REPO}
  namespace: ${ARGO_NS}
  labels: { argocd.argoproj.io/secret-type: repository }
stringData:
  type: git
  url: https://github.com/${GH_USER}/${GH_REPO}.git
  username: ${GH_USER}
  password: ${GH_PAT}
EOF

kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: python-app
  namespace: ${ARGO_NS}
spec:
  destination:
    namespace: ${APP_NS}
    server: https://kubernetes.default.svc
  project: default
  source:
    repoURL: https://github.com/${GH_USER}/${GH_REPO}.git
    path: charts/python-app
    targetRevision: HEAD
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

# ───────── cert-manager (for ARC) ─────────
log "Installing cert-manager (CRDs first)"
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.4/cert-manager.crds.yaml
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.4/cert-manager.yaml
kubectl -n cert-manager wait deploy/cert-manager-webhook --for=condition=Available --timeout=120s

# ───────── Actions Runner Controller + runner ─────────
log "Installing ARC & runner"
helm repo add actions-runner-controller https://actions-runner-controller.github.io/actions-runner-controller >/dev/null
helm repo update >/dev/null
kubectl create namespace "$ARC_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$ARC_NS" create secret generic controller-manager --from-literal=github_token="$GH_PAT" --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install arc actions-runner-controller/actions-runner-controller -n "$ARC_NS" --wait

cat <<EOF | kubectl apply -f -
apiVersion: actions.summerwind.dev/v1alpha1
kind: RunnerDeployment
metadata: { name: app-runner, namespace: $ARC_NS }
spec:
  template:
    spec:
      repository: ${GH_USER}/${GH_REPO}
      labels: ["self-hosted"]
EOF
kubectl -n "$ARC_NS" rollout status deploy/app-runner-runner-deployment --timeout=300s || true

# ───────── CI/CD workflow ─────────
log "Adding GitHub Actions workflow"
mkdir -p .github/workflows
cat >.github/workflows/ci-cd.yaml <<'YAML'
name: CI-CD
on:
  push:
    branches: [main]
    paths: ["src/**"]

jobs:
  build:
    runs-on: ubuntu-latest
    outputs: { tag: ${{ steps.sha.outputs.tag }}
    steps:
      - id: sha
        run: echo "tag=${GITHUB_SHA::6}" >> $GITHUB_OUTPUT
      - uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}
      - uses: docker/build-push-action@v6
        with:
          push: true
          tags: IMAGE_REPO:${{ steps.sha.outputs.tag }}

  deploy:
    needs: build
    runs-on: self-hosted
    env:
      TAG: ${{ needs.build.outputs.tag }}
    steps:
      - uses: actions/checkout@v4
      - run: |
          command -v yq >/dev/null || { wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && chmod +x /usr/local/bin/yq; }
          yq eval -i '.image.tag = env(TAG)' charts/python-app/values.yaml
      - uses: EndBug/add-and-commit@v9
        with: { message: "Update image tag -> ${{ env.TAG }}" }
      - run: kubectl -n ARGO_NS apply -f charts/python-app   # plain sync; ARC pod has kube-config
YAML
sed -i "s#IMAGE_REPO#$IMAGE_REPO#g" .github/workflows/ci-cd.yaml
sed -i "s#ARGO_NS#$ARGO_NS#g"       .github/workflows/ci-cd.yaml

git add .github/workflows/ci-cd.yaml
git commit -m "add CI/CD workflow" || true
git push https://$GH_USER:$GH_PAT@github.com/$GH_USER/$GH_REPO.git main

# ───────── cleanup + info ─────────
kill $PF_PID 2>/dev/null || true  # stop port-forward

cat <<EOF

────────────────────────────────────────────────────────────────
Argo CD UI  : https://${ARGO_HOST}   (user: admin)
Initial PW  : ${ARGO_PASS}

Flask API   : https://${PY_HOST}/api/v1/info

Add **repository secrets** in GitHub:

  DOCKERHUB_USERNAME = ${DH_USER}
  DOCKERHUB_TOKEN    = ${DH_PAT}
  ARGOCD_PASSWORD    = ${ARGO_PASS}

Push a change to ./src/ – self-hosted runner builds, pushes,
bumps Helm, and Argo CD auto-syncs. Enjoy! 🚀
────────────────────────────────────────────────────────────────
EOF

