#!/usr/bin/env bash
set -euo pipefail

################################################################################
# 0. CLI flags
################################################################################
DEPLOY_TARGET="ec2"           # default
while [[ $# -gt 0 ]]; do
  case $1 in
    --target) DEPLOY_TARGET="$2"; shift 2 ;;
    *) echo "Unknown flag $1"; exit 1 ;;
  esac
done

################################################################################
# 1. Helpers
################################################################################
banner()   { printf "\n\033[1;33m*** %s ***\033[0m\n" "$*"; }
log()      { printf "\e[1;32m▸ %s\e[0m\n" "$*"; }
warn()     { printf "\e[1;33m! %s\e[0m\n" "$*"; }
prompt()   { local var=$1 def=$2; shift 2; read -rp "$*${def:+ [$def]}: " val; printf -v "$var" '%s' "${val:-$def}"; }
secret()   { local var=$1; shift; read -srp "$*: " val; echo; printf -v "$var" '%s' "$val"; }
need()     { command -v "$1" &>/dev/null || { warn "$1 not found"; exit 1; } }

[[ $EUID -eq 0 ]] && { echo "Run as a normal user (with sudo), not root"; exit 1; }
banner "Ubuntu 22.04+ required (tested on EC2 & kind)"

################################################################################
# 2. User input
################################################################################
prompt GITHUB_USER  ""            "GitHub username"
prompt GITHUB_REPO  "python-app"  "GitHub repository to create/use"
secret GITHUB_PAT   "GitHub PAT (repo + workflow)"
prompt DOCKERHUB_USER ""          "Docker Hub username"
secret DOCKERHUB_PAT  "Docker Hub token/password"

if [[ $DEPLOY_TARGET == ec2 ]]; then
  PUBLIC_IP=$(curl -s ifconfig.me || curl -s https://checkip.amazonaws.com)
  BASE_DOMAIN="${PUBLIC_IP}.nip.io"
  log "Using nip.io domain: $BASE_DOMAIN"
else
  prompt BASE_DOMAIN "test.com" "Base domain for local ingress"
fi

prompt APP_NS       "python"         "K8s namespace for the app"
prompt ARGO_NS      "argo-cd"        "K8s namespace for Argo CD"
prompt RUNNER_NS    "actions-runner-system" "Namespace for ARC"
prompt KIND_CLUSTER "devcluster"     "Kind cluster name (local mode)"

read -rp "Continue? [y/N]: " ans
[[ $ans =~ ^[Yy]$ ]] || { echo "Aborted"; exit 1; }

IMAGE_REPO="$DOCKERHUB_USER/python-app"
PY_HOST="python-app.${BASE_DOMAIN}"
ARGO_HOST="argo.${BASE_DOMAIN}"

################################################################################
# 3. System packages & CLIs
################################################################################
log "Installing base packages"
sudo apt-get update -qq
sudo apt-get install -y curl gnupg ca-certificates lsb-release python3 python3-pip jq

install_bin() {
  local name=$1 url=$2
  log "Installing $name"
  curl -fsSL "$url" -o "$name"
  chmod +x "$name"
  sudo mv "$name" /usr/local/bin/
}

command -v docker &>/dev/null || {
  log "Installing Docker"
  sudo apt-get install -y docker.io
  sudo usermod -aG docker "$USER" || true
}

command -v kubectl &>/dev/null || \
  install_bin kubectl "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
command -v helm &>/dev/null || \
  { curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash; }
command -v kind &>/dev/null || \
  install_bin kind https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64
command -v yq &>/dev/null || \
  install_bin yq https://github.com/mikefarah/yq/releases/download/v4.46.1/yq_linux_amd64

DOCKER="docker"; KIND="kind"
docker info &>/dev/null || { DOCKER="sudo docker"; KIND="sudo kind"; }

################################################################################
# 4. Cluster (kind when local)
################################################################################
if [[ $DEPLOY_TARGET == local ]]; then
  log "Creating kind cluster $KIND_CLUSTER"
  cat <<EOF >kind.yaml
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
  log "Ingress-nginx for kind"
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.0/deploy/static/provider/kind/deploy.yaml
  kubectl -n ingress-nginx wait deploy/ingress-nginx-controller \
      --for=condition=Available --timeout=180s
fi

################################################################################
# 5. Sample app & seed image
################################################################################
log "Creating sample Flask app"
mkdir -p src
cat >src/app.py <<'PY'
from flask import Flask, jsonify
import datetime, socket
app = Flask(__name__)
@app.route("/api/v1/info")
def info():
    return jsonify({
        "time": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "hostname": socket.gethostname(),
        "message": "You are doing great, little human! ❤️",
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

log "Building & pushing v0 image"
echo "$DOCKERHUB_PAT" | $DOCKER login -u "$DOCKERHUB_USER" --password-stdin
$DOCKER build -t "$IMAGE_REPO:v0" .
$DOCKER push "$IMAGE_REPO:v0"

################################################################################
# 6. Helm chart
################################################################################
log "Creating Helm chart"
rm -rf charts/python-app || true
helm create charts/python-app >/dev/null
rm -rf charts/python-app/{charts,templates/tests*,templates/serviceaccount.yaml,templates/hpa.yaml}

yq -i '
  .image.repository = strenv(IMAGE_REPO) |
  .image.tag        = "v0" |
  .service.port     = 5000 |
  .serviceAccount.create = false |
  .ingress.enabled  = true  |
  .ingress.className= "nginx" |
  .ingress.tls      = true  |
  .ingress.hosts    = [{"host":"'"$PY_HOST"'","paths":[{"path":"/","pathType":"Prefix"}]}]
' charts/python-app/values.yaml

################################################################################
# 7. Git repo push
################################################################################
log "Bootstrapping Git repository"
git init -q && git branch -M main || true
git add .
git -c user.email="$GITHUB_USER@users.noreply.github.com" \
    -c user.name="$GITHUB_USER" commit -m "bootstrap project" || true

repo_check=$(curl -s -o /dev/null -w '%{http_code}' \
              -H "Authorization: token $GITHUB_PAT" \
              https://api.github.com/repos/$GITHUB_USER/$GITHUB_REPO)
if [[ $repo_check == 404 ]]; then
  warn "Repo not found – creating"
  curl -s -H "Authorization: token $GITHUB_PAT" \
       -d '{"name":"'"$GITHUB_REPO"'","private":false}' \
       https://api.github.com/user/repos >/dev/null
fi
git remote add origin https://github.com/$GITHUB_USER/$GITHUB_REPO.git || true
git push -u https://$GITHUB_USER:$GITHUB_PAT@github.com/$GITHUB_USER/$GITHUB_REPO.git main

################################################################################
# 8. Argo CD (Helm)
################################################################################
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
redis-ha: { enabled: false }
server: { replicas: 1 }
EOF
helm upgrade --install argo-cd argo/argo-cd \
  -n "$ARGO_NS" --create-namespace -f argocd-values.yaml --wait --timeout 5m

ARGO_PASS=$(kubectl -n "$ARGO_NS" get secret argocd-initial-admin-secret \
                 -o jsonpath='{.data.password}' | base64 -d)

log "Installing argocd CLI"
install_bin argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64

# ── Port-forward for local, direct DNS for EC2
if [[ $DEPLOY_TARGET == local ]]; then
  kubectl -n "$ARGO_NS" port-forward svc/argo-cd-argocd-server 9443:443 >/tmp/argo-pf.log 2>&1 &
  PF_PID=$!; sleep 5
  ARGO_URL="localhost:9443"
else
  ARGO_URL="$ARGO_HOST"
fi

log "Logging into Argo CD CLI"
argocd login "$ARGO_URL" --insecure --grpc-web \
       --username admin --password "$ARGO_PASS"

[[ ${PF_PID:-} ]] && { kill "$PF_PID"; wait "$PF_PID" 2>/dev/null || true; }

################################################################################
# 9. Register repo & Application (RBAC-safe K8s manifests)
################################################################################
log "Registering repo & creating Application"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: repo-$GITHUB_REPO
  namespace: $ARGO_NS
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/$GITHUB_USER/$GITHUB_REPO.git
  username: $GITHUB_USER
  password: $GITHUB_PAT
EOF

cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: python-app
  namespace: $ARGO_NS
  finalizers: ["resources-finalizer.argocd.argoproj.io"]
spec:
  project: default
  source:
    repoURL: https://github.com/$GITHUB_USER/$GITHUB_REPO.git
    path: charts/python-app
    targetRevision: HEAD
  destination:
    server: https://kubernetes.default.svc
    namespace: $APP_NS
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

################################################################################
# 10. cert-manager + ARC
################################################################################
log "Installing cert-manager"
CM_VER=v1.15.0
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/${CM_VER}/cert-manager.crds.yaml
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/${CM_VER}/cert-manager.yaml
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=180s

log "Deploying Actions-Runner-Controller"
helm repo add actions-runner-controller https://actions-runner-controller.github.io/actions-runner-controller >/dev/null
helm repo update >/dev/null
kubectl create namespace "$RUNNER_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$RUNNER_NS" create secret generic controller-manager \
  --from-literal=github_token="$GITHUB_PAT" --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install arc actions-runner-controller/actions-runner-controller \
    -n "$RUNNER_NS" \
    --set syncPeriod=30s \
    --set githubWebhookServer.enabled=false \
    --wait

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
kubectl -n "$RUNNER_NS" rollout status deploy/selfhosted-python-runner-deployment \
  --timeout=300s || true

################################################################################
# 11. CI/CD workflow
################################################################################
log "Adding CI/CD workflow"
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
      commit_id: ${{ steps.sha.outputs.short }}
    steps:
      - id: sha
        run: echo "short=${GITHUB_SHA::6}" >>$GITHUB_OUTPUT

      - name: Docker login
        uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}

      - name: Build & push
        uses: docker/build-push-action@v5
        with:
          push: true
          tags: IMAGE_REPO_PLACEHOLDER:${{ steps.sha.outputs.short }}

  cd:
    needs: ci
    runs-on: self-hosted
    env:
      IMAGE_TAG: ${{ needs.ci.outputs.commit_id }}
    steps:
      - uses: actions/checkout@v4

      - name: Ensure yq
        run: |
          command -v yq >/dev/null || {
            wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/download/v4.46.1/yq_linux_amd64
            chmod +x /usr/local/bin/yq
          }

      - name: Bump image tag
        run: yq -i '.image.tag = env(IMAGE_TAG)' charts/python-app/values.yaml

      - name: Commit chart change
        uses: EndBug/add-and-commit@v9
        with:
          message: "Update image tag -> ${{ env.IMAGE_TAG }}"

      - name: Argo sync
        env:
          ARGO_PASS: ${{ secrets.ARGOCD_PASSWORD }}
        run: |
          argocd login argocd-server.ARGO_NS_PLACEHOLDER.svc --insecure \
                --username admin --password "$ARGO_PASS"
          argocd app sync python-app
YAML

sed -i "s#IMAGE_REPO_PLACEHOLDER#$IMAGE_REPO#g" .github/workflows/ci-cd.yaml
sed -i "s#ARGO_NS_PLACEHOLDER#$ARGO_NS#g"       .github/workflows/ci-cd.yaml

git add .github/workflows/ci-cd.yaml
git commit -m "Add CI/CD workflow" || true
git push https://$GITHUB_USER:$GITHUB_PAT@github.com/$GITHUB_USER/$GITHUB_REPO.git main

################################################################################
# 12. Summary
################################################################################
banner "DONE – next steps"

cat <<EOF
1.  **Add repo-level secrets** in GitHub → Settings → Secrets → Actions:

    DOCKERHUB_USERNAME = $DOCKERHUB_USER
    DOCKERHUB_TOKEN    = <your-hub-token>
    ARGOCD_PASSWORD    = $ARGO_PASS

2.  Argo CD UI  : https://$ARGO_HOST  (admin / \$ARGO_PASS)
    Sample API  : https://$PY_HOST/api/v1/info

3.  Push code changes under ./src/ – watch GitHub Actions, ARC runner,
    and Argo CD roll out the new image automatically 🎉
EOF

