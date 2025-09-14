**design → build → push to GCR → deploy to GKE → access via LoadBalancer**.

---

# 0) One-time GCP setup (CLI)

```bash
# Login & select your project
#gcloud auth login
gcloud auth login --no-launch-browser
gcloud config set project YOUR_PROJECT_ID

# (If you’re brand new) enable required APIs
gcloud services enable container.googleapis.com containerregistry.googleapis.com

# Allow Docker to push to GCR
gcloud auth configure-docker gcr.io
```

> Replace `YOUR_PROJECT_ID` everywhere below.

---

# 1) Project structure + Node.js sample app

```bash
mkdir node-gke-demo && cd node-gke-demo

cat > app.js <<'EOF'
const express = require('express');
const app = express();
const PORT = process.env.PORT || 3000;

app.get('/', (_req, res) => {
  res.send('Hello from Node.js on GKE via LoadBalancer! 🚀');
});

app.listen(PORT, () => {
  console.log(`App listening on port ${PORT}`);
});
EOF

cat > package.json <<'EOF'
{
  "name": "node-gke-demo",
  "version": "1.0.0",
  "description": "Sample Node.js app for GCR + GKE",
  "main": "app.js",
  "scripts": {
    "start": "node app.js"
  },
  "dependencies": {
    "express": "^4.19.2"
  }
}
EOF

npm install --production
```

---

# 2) Dockerfile (+ .dockerignore)

```bash
cat > Dockerfile <<'EOF'
# Small production base
FROM node:20-alpine

# Create app dir
WORKDIR /usr/src/app

# Install deps (leverage Docker layer cache)
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev || npm install --omit=dev

# Copy source
COPY . .

# App listens on 3000
EXPOSE 3000

# Run
CMD ["npm", "start"]
EOF

cat > .dockerignore <<'EOF'
node_modules
npm-debug.log
.DS_Store
.git
EOF
```

---

# 3) Build & push Docker image to **GCR**

# Using Artifact Registry (preferred modern)

```bash
REGION=us-east4
REPO=node-images
IMAGE="$REGION-docker.pkg.dev/$PROJECT_ID/$REPO/node-gke-demo:1"

# One-time (if repo doesn't exist)
gcloud artifacts repositories create $REPO \
  --repository-format=docker --location=$REGION

gcloud auth configure-docker $REGION-docker.pkg.dev

# Build & push
docker build -t $IMAGE .
docker push $IMAGE

# Update deployment
kubectl set image deploy/node-gke-demo node-gke-demo=$IMAGE
kubectl rollout status deploy/node-gke-demo


```


-----

```bash
# Image coordinates
export PROJECT_ID=YOUR_PROJECT_ID
export IMAGE_NAME=node-gke-demo
export IMAGE_TAG=v1
export IMAGE_URI=gcr.io/$PROJECT_ID/$IMAGE_NAME:$IMAGE_TAG

# Build locally
docker build -t $IMAGE_URI .

# Push to Google Container Registry
docker push $IMAGE_URI

gcloud container images list --repository=gcr.io/x-object-472022-q2

```

---

# 4) Kubernetes manifests (Deployment + Service: LoadBalancer)

```bash
mkdir k8s

# Deployment
cat > k8s/deployment.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: node-gke-demo
  labels:
    app: node-gke-demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: node-gke-demo
  template:
    metadata:
      labels:
        app: node-gke-demo
    spec:
      containers:
      - name: node-gke-demo
        image: $IMAGE_URI
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 3000
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 250m
            memory: 256Mi
EOF

# Service (external LoadBalancer)
cat > k8s/service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: node-gke-demo
spec:
  type: LoadBalancer
  selector:
    app: node-gke-demo
  ports:
  - name: http
    port: 80
    targetPort: 3000
EOF
```

> Note: `deployment.yaml` interpolates `$IMAGE_URI` from your current shell. If you open a new shell later, re-export those vars before re-creating the file, or just hardcode the image.

---

# 5) Create a GKE cluster & deploy with kubectl

### Option A: **Autopilot** (simplest)

With Autopilot:

>You are billed only for what your Pods request (CPU, RAM, ephemeral storage, persistent volumes).

>You do not pay for idle node capacity because you don’t manage nodes at all — Google handles scheduling, scaling, and node lifecycle.

>Even if Google places your Pods on a large underlying VM, you’re only charged for the resources you explicitly asked for in your Pod’s resources.requests.

```bash
# Create an Autopilot cluster (regional)
gcloud container clusters create-auto demo-autopilot --region us-east4

# Get kubeconfig
gcloud container clusters get-credentials demo-autopilot --region us-east4

# (Optional) Use a namespace
kubectl create namespace demo || true
kubectl -n demo apply -f k8s/deployment.yaml
kubectl -n demo apply -f k8s/service.yaml

# Check rollout
kubectl -n demo rollout status deploy/node-gke-demo
kubectl -n demo get pods -o wide
kubectl -n demo get svc node-gke-demo
```

### Option B: **Standard** (if you prefer node control)

```bash
# Zonal standard cluster
gcloud container clusters create demo \
  --zone us-central1-a \
  --num-nodes 2

gcloud container clusters get-credentials demo --zone us-central1-a

kubectl create namespace demo || true
kubectl -n demo apply -f k8s/deployment.yaml
kubectl -n demo apply -f k8s/service.yaml
kubectl -n demo rollout status deploy/node-gke-demo
kubectl -n demo get svc node-gke-demo
```

---

# 6) Access the app via the LoadBalancer

```bash
# Watch until EXTERNAL-IP is assigned (can take 1–3 minutes)
kubectl -n demo get svc node-gke-demo -w
```

Once you see an `EXTERNAL-IP`, open it in your browser:

```
http://EXTERNAL-IP/
```

Or test via curl:

```bash
curl -s http://EXTERNAL-IP/
```

You should get:

```
Hello from Node.js on GKE via LoadBalancer! 🚀
```

---

## (Nice to have) Quick Makefile helper

```bash
cat > Makefile <<'EOF'
PROJECT_ID ?= YOUR_PROJECT_ID
IMAGE_NAME ?= node-gke-demo
IMAGE_TAG  ?= v1
IMAGE_URI  ?= gcr.io/$(PROJECT_ID)/$(IMAGE_NAME):$(IMAGE_TAG)
NS         ?= demo
REGION     ?= us-central1

.PHONY: build push deploy svc ip

build:
\tdocker build -t $(IMAGE_URI) .

push:
\tdocker push $(IMAGE_URI)

cluster:
\tgcloud container clusters create-auto demo-autopilot --region $(REGION)

auth:
\tgcloud container clusters get-credentials demo-autopilot --region $(REGION)

deploy:
\tkubectl create namespace $(NS) --dry-run=client -o yaml | kubectl apply -f -
\tsed "s|image: .*|image: $(IMAGE_URI)|" k8s/deployment.yaml | kubectl -n $(NS) apply -f -
\tkubectl -n $(NS) apply -f k8s/service.yaml
\tkubectl -n $(NS) rollout status deploy/$(IMAGE_NAME)

svc:
\tkubectl -n $(NS) get svc $(IMAGE_NAME)

ip:
\tkubectl -n $(NS) get svc $(IMAGE_NAME) -o jsonpath='{.status.loadBalancer.ingress[0].ip}'; echo
EOF
```

Use it like:

```bash
make build push
make cluster auth
make deploy
make ip   # then open http://<printed-ip>
```

---

## Cleanup (avoid costs)

```bash
# Delete app resources
kubectl -n demo delete -f k8s/service.yaml
kubectl -n demo delete -f k8s/deployment.yaml
kubectl delete namespace demo

# Delete cluster (Autopilot example)
gcloud container clusters delete demo-autopilot --region us-east4 --quiet

# (Optional) remove image from GCR
gcloud container images delete gcr.io/$PROJECT_ID/node-gke-demo@$(
  gcloud container images list-tags gcr.io/$PROJECT_ID/node-gke-demo \
  --filter="tags:$IMAGE_TAG" --format='get(digest)'
) --quiet
```

---

### Deliverables checklist for your repo

* `app.js`, `package.json`, `Dockerfile`, `.dockerignore`
* `k8s/deployment.yaml`, `k8s/service.yaml`
* `README.md` with the exact commands above
* Optional: `Makefile`, screenshots of `kubectl get svc` and browser hit


