#!/usr/bin/env bash
# Bootstrap script for Python App on K8s
# Created by: JaiTrieTree
# Last updated: 2025-07-20 08:34:41 UTC

set -euo pipefail

# ───────────────── banner ─────────────────
echo -e "\n\033[1;33m*** Ubuntu 22.04+ required – not tested on macOS / WSL / CentOS ***\033[0m"
[[ $EUID -eq 0 ]] && { echo "❌ Run as an unprivileged user (with sudo), not root."; exit 1; }

# ───────── helpers ─────────
prompt()  { local var=$1 def=$2; shift 2; read -rp "$*${def:+ [$def]}: " ans; printf -v "$var" '%s' "${ans:-$def}"; }
secret()  { local var=$1; shift; read -srp "$*: " ans; echo; printf -v "$var" '%s' "$ans"; }
confirm() { read -rp "Continue? [y/N]: " ans; [[ $ans =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; } }
log()     { printf "\e[1;32m▸ %s\e[0m\n" "$*"; }
warn()    { printf "\e[1;33m! %s\e[0m\n" "$*"; }

# ───────── user input ─────────
prompt DEPLOY_TARGET "ec2"         "Deploy target (ec2|local)"
prompt GITHUB_USER   ""            "GitHub username"
prompt GITHUB_REPO   "python-app"  "GitHub repository"
secret GITHUB_PAT    "GitHub PAT (repo + workflow scopes)"
prompt DOCKERHUB_USER "" "Docker Hub username"
secret DOCKERHUB_PAT  "Docker Hub PAT / password"

if [[ $DEPLOY_TARGET == ec2 ]]; then
  PUBLIC_IP=$(curl -s ifconfig.me || curl -s https://checkip.amazonaws.com)
  BASE_DOMAIN="${PUBLIC_IP}.nip.io"
  echo "→ Using nip.io domain: ${BASE_DOMAIN}"
else
  prompt BASE_DOMAIN "test.com"    "Base domain (ingress FQDNs)"
fi

prompt APP_NS       "python"    "K8s namespace for the app"
prompt ARGO_NS      "argo-cd"   "K8s namespace for Argo CD"
prompt RUNNER_NS    "actions-runner-system" "Namespace for self-hosted runners"
prompt KIND_CLUSTER "devcluster" "Kind cluster name (if local)"
confirm

IMAGE_REPO="$DOCKERHUB_USER/python-app"
PY_HOST="python-app.${BASE_DOMAIN}"
ARGO_HOST="argo.${BASE_DOMAIN}"

# ───────── packages & CLIs ─────────
log "Installing prerequisites"
sudo apt-get update -qq
sudo apt-get install -y curl gnupg ca-certificates lsb-release python3 python3-pip jq unzip

install_bin(){ log "Installing $1"; curl -fsSL "$2" -o "$1"; chmod +x "$1"; sudo mv "$1" /usr/local/bin/; }

command -v docker &>/dev/null || {
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
}

command -v kubectl &>/dev/null || \
  install_bin kubectl "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
command -v kind &>/dev/null    || install_bin kind https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64
command -v helm &>/dev/null    || { log "Installing helm"; curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash; }
command -v yq &>/dev/null      || {
  log "Installing yq"
  sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
  sudo chmod +x /usr/local/bin/yq
}

# Install AWS CLI v2 if we're on EC2
if [[ $DEPLOY_TARGET == ec2 ]]; then
  command -v aws &>/dev/null || {
    log "Installing AWS CLI v2"
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip -q awscliv2.zip
    sudo ./aws/install
    rm -rf aws awscliv2.zip
  }
fi

# wrapper for sudo‐less/with-sudo docker & kind
if docker info &>/dev/null; then DOCKER=docker; KIND=kind
else warn "Adding sudo prefix for docker/kind"; DOCKER='sudo docker'; KIND='sudo kind'; fi

# ───────── local kind cluster (if requested) ─────────
if [[ $DEPLOY_TARGET == local ]]; then
  log "Creating kind cluster ${KIND_CLUSTER}"
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

# ───────── sample app & image ─────────
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
$DOCKER build -t "$IMAGE_REPO:v0" .
$DOCKER push "$IMAGE_REPO:v0"

# ───────── Helm chart ─────────
log "Scaffolding Helm chart"
rm -rf charts/python-app || true
mkdir -p charts/python-app/templates
mkdir -p charts/python-app/charts

cat >charts/python-app/Chart.yaml <<EOF
apiVersion: v2
name: python-app
description: A Helm chart for Python Flask app
type: application
version: 0.1.0
appVersion: "1.0.0"
EOF

cat >charts/python-app/values.yaml <<EOF
replicaCount: 1

image:
  repository: ${IMAGE_REPO}
  tag: v0
  pullPolicy: Always

service:
  type: ClusterIP
  port: 5000

ingress:
  enabled: true
  className: nginx
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
  hosts:
    - host: ${PY_HOST}
      paths:
        - path: /
          pathType: Prefix
EOF

cat >charts/python-app/templates/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
  labels:
    app: {{ .Release.Name }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app: {{ .Release.Name }}
    spec:
      containers:
        - name: {{ .Release.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - containerPort: {{ .Values.service.port }}
EOF

cat >charts/python-app/templates/service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}
  labels:
    app: {{ .Release.Name }}
spec:
  type: {{ .Values.service.type }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: {{ .Values.service.port }}
      protocol: TCP
      name: http
  selector:
    app: {{ .Release.Name }}
EOF

cat >charts/python-app/templates/ingress.yaml <<'EOF'
{{- if .Values.ingress.enabled -}}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ .Release.Name }}
  {{- with .Values.ingress.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  ingressClassName: {{ .Values.ingress.className }}
  rules:
    {{- range .Values.ingress.hosts }}
    - host: {{ .host | quote }}
      http:
        paths:
          {{- range .paths }}
          - path: {{ .path }}
            pathType: {{ .pathType }}
            backend:
              service:
                name: {{ $.Release.Name }}
                port:
                  number: {{ $.Values.service.port }}
          {{- end }}
    {{- end }}
{{- end }}
EOF

# ───────── Git repo bootstrap ─────────
log "Initializing Git repository"
git init -q && git branch -M main || true
git add .
git -c user.email="$GITHUB_USER@users.noreply.github.com" \
    -c user.name="$GITHUB_USER" commit -m "initial bootstrap" || true

resp=$(curl -s -o /dev/null -w '%{http_code}' \
        -H "Authorization: token $GITHUB_PAT" \
        https://api.github.com/repos/$GITHUB_USER/$GITHUB_REPO)
if [[ $resp == 404 ]]; then
  warn "GitHub repo not found – creating"
  curl -s -H "Authorization: token $GITHUB_PAT" \
       -d '{"name":"'"$GITHUB_REPO"'","private":false}' \
       https://api.github.com/user/repos >/dev/null
fi
git remote add origin https://github.com/$GITHUB_USER/$GITHUB_REPO.git || true
git push -u https://$GITHUB_USER:$GITHUB_PAT@github.com/$GITHUB_USER/$GITHUB_REPO.git main

# ───────── Configure cluster namespaces ─────────
log "Setting up cluster namespaces"
kubectl create namespace "$APP_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "$ARGO_NS" --dry-run=client -o yaml | kubectl apply -f -

# ───────── Argo CD install (WITH PERMISSIONS FIXES) ─────────
log "Installing Argo CD via Helm"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo update >/dev/null

# Create values file with proper configuration
cat >argocd-values.yaml <<EOF
server:
  extraArgs:
    - --insecure # Allow operation without TLS
  service:
    type: NodePort # Expose via NodePort for easier access
  ingress:
    enabled: true
    ingressClassName: nginx
    hosts:
      - ${ARGO_HOST}
    annotations:
      nginx.ingress.kubernetes.io/force-ssl-redirect: "false"
      nginx.ingress.kubernetes.io/ssl-redirect: "false"
      nginx.ingress.kubernetes.io/backend-protocol: "HTTP"

configs:
  cm:
    admin.enabled: "true" # Enable admin user
    timeout.reconciliation: 180s

redis:
  enabled: true

controller:
  replicas: 1
EOF

helm upgrade --install argocd argo/argo-cd -n "$ARGO_NS" -f argocd-values.yaml --wait --timeout 5m

ARGO_PASS=$(kubectl -n "$ARGO_NS" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d || echo "admin")
log "Argo CD admin password: $ARGO_PASS"

log "Installing Argo CD CLI"
curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x argocd && sudo mv argocd /usr/local/bin/

# ───────── Create explicit ingress for Argo CD ─────────
log "Creating explicit ingress for Argo CD"
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server-ingress
  namespace: $ARGO_NS
  annotations:
    nginx.ingress.kubernetes.io/force-ssl-redirect: "false"
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
spec:
  ingressClassName: nginx
  rules:
  - host: ${ARGO_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 80
EOF

# ───────── Wait for Argo CD to fully initialize ─────────
log "Waiting for Argo CD to fully initialize..."
kubectl -n "$ARGO_NS" wait --for=condition=Available deployment/argocd-server --timeout=300s || true

# ───────── Create repo as a Kubernetes resource directly ─────────
log "Creating Git repository directly via Kubernetes resource"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: repo-${GITHUB_REPO}
  namespace: ${ARGO_NS}
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/${GITHUB_USER}/${GITHUB_REPO}.git
  username: ${GITHUB_USER}
  password: ${GITHUB_PAT}
EOF

# ───────── Create and deploy the Python application ─────────
log "Deploying Python application directly"
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: python-app
  namespace: ${APP_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: python-app
  template:
    metadata:
      labels:
        app: python-app
    spec:
      containers:
      - name: python-app
        image: ${IMAGE_REPO}:v0
        ports:
        - containerPort: 5000
---
apiVersion: v1
kind: Service
metadata:
  name: python-app
  namespace: ${APP_NS}
spec:
  ports:
  - port: 5000
    targetPort: 5000
  selector:
    app: python-app
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: python-app-ingress
  namespace: ${APP_NS}
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
  - host: ${PY_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: python-app
            port:
              number: 5000
EOF

# ───────── Create application in Argo CD ─────────
log "Creating Argo CD application directly via Kubernetes resource"
cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: python-app
  namespace: ${ARGO_NS}
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  destination:
    namespace: ${APP_NS}
    server: https://kubernetes.default.svc
  project: default
  source:
    path: charts/python-app
    repoURL: https://github.com/${GITHUB_USER}/${GITHUB_REPO}.git
    targetRevision: HEAD
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

# ───────── Open ports if we're on EC2 ─────────
if [[ $DEPLOY_TARGET == ec2 ]]; then
  log "Opening required ports in EC2 security group"

  # Get security group ID
  SG_ID=$(aws ec2 describe-instances --instance-ids $(curl -s http://169.254.169.254/latest/meta-data/instance-id) --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "unknown")

  if [[ $SG_ID != "unknown" ]]; then
    # Open HTTP and HTTPS ports
    aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 80 --cidr 0.0.0.0/0 2>/dev/null || true
    aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 443 --cidr 0.0.0.0/0 2>/dev/null || true

    # Open NodePort range
    aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 30000-32767 --cidr 0.0.0.0/0 2>/dev/null || true

    log "Security group ports opened"
  else
    warn "Couldn't determine security group ID - please open ports manually"
  fi
fi

# ───────── Installing cert-manager (required by actions-runner-controller) ─────────
log "Installing cert-manager (required dependency for Actions Runner Controller)"
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.1/cert-manager.yaml
kubectl -n cert-manager wait --for=condition=Available deployment/cert-manager-webhook --timeout=120s || true
sleep 10 # Give cert-manager some time to initialize properly

# ───────── actions-runner-controller ─────────
log "Deploying self-hosted GitHub Actions runner"
helm repo add actions-runner-controller https://actions-runner-controller.github.io/actions-runner-controller >/dev/null
helm repo update >/dev/null
kubectl create namespace "$RUNNER_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$RUNNER_NS" create secret generic controller-manager \
  --from-literal=github_token="$GITHUB_PAT" --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install arc actions-runner-controller/actions-runner-controller \
     -n "$RUNNER_NS" --set syncPeriod=30s --set githubWebhookServer.enabled=false --wait --timeout 300s || true

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

# ───────── CI/CD workflow ─────────
log "Adding CI/CD workflow"
mkdir -p .github/workflows
cat >.github/workflows/ci-cd.yaml <<'YAML'
name: ci-cd
on:
  push:
    paths: ["src/**"]
    branches: [main]

jobs:
  ci:
    runs-on: ubuntu-latest
    outputs:
      commit_id: ${{ env.COMMIT_ID }}
    steps:
      - name: Short SHA
        run: echo "COMMIT_ID=${GITHUB_SHA::6}" >> "$GITHUB_ENV"

      - name: Docker login
        uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}

      - name: Build & push
        uses: docker/build-push-action@v6
        with:
          push: true
          tags: IMAGE_REPO_PLACEHOLDER:${{ env.COMMIT_ID }}

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
            sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
            sudo chmod +x /usr/local/bin/yq
          }

      - name: Bump image tag
        run: yq -i -Y '.image.tag = env(IMAGE_TAG)' charts/python-app/values.yaml

      - name: Commit chart change
        uses: EndBug/add-and-commit@v9
        with:
          message: "Update image tag -> ${{ env.IMAGE_TAG }}"

      - name: Sync Argo CD application via kubectl
        run: |
          kubectl -n ARGO_NS_PLACEHOLDER patch application python-app --type=merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' || true
          sleep 5
          kubectl -n ARGO_NS_PLACEHOLDER get application python-app -o jsonpath='{.status.sync.status}'
YAML

# Replace placeholder for IMAGE_REPO and Argo CD namespace
sed -i "s#IMAGE_REPO_PLACEHOLDER#$IMAGE_REPO#g" .github/workflows/ci-cd.yaml
sed -i "s#ARGO_NS_PLACEHOLDER#$ARGO_NS#g"       .github/workflows/ci-cd.yaml

git add .github/workflows/ci-cd.yaml
git commit -m "Add CI/CD workflow" || true
git push https://$GITHUB_USER:$GITHUB_PAT@github.com/$GITHUB_USER/$GITHUB_REPO.git main

# ───────── Get NodePorts for services ─────────
ARGOCD_NODE_PORT=$(kubectl get svc -n "$ARGO_NS" argocd-server -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "Not exposed")

# ───────── final notes ─────────
cat <<EOF

=================================================================
🔑  **Add three repository secrets** (GitHub → Settings → Secrets → Actions)

  DOCKERHUB_USERNAME = $DOCKERHUB_USER
  DOCKERHUB_TOKEN    = $DOCKERHUB_PAT
  ARGOCD_PASSWORD    = $ARGO_PASS

-----------------------------------------------------------------
Argo CD UI:
  • Ingress URL: http://$ARGO_HOST
  • NodePort URL (if ingress fails): http://$PUBLIC_IP:$ARGOCD_NODE_PORT
  • Login: admin / $ARGO_PASS

Python API:
  • Ingress URL: http://$PY_HOST/api/v1/info

Git repo:
  • https://github.com/$GITHUB_USER/$GITHUB_REPO

=================================================================
\033[1;32mBootstrap complete – push a change to ./src/ and watch CI/CD!\033[0m

If you can't access the services through the domain names:
1. Make sure ports 80, 443 and NodePorts (30000-32767) are open in your EC2 security group
2. Try accessing via NodePort directly if ingress isn't working
=================================================================
EOF
