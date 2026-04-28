# Rainbow Dashboard In-Cluster Deployment

This guide deploys the dashboard as a pod in your Kubernetes cluster (Minikube or EKS).

## Quick Start (Minikube)

### Build and Deploy

```bash
# Build dashboard image and deploy to minikube
skaffold run --profile dashboard

# Verify deployment
kubectl get deployment rainbow-dashboard
kubectl get service rainbow-dashboard
```

### Access the Dashboard

#### Port Forward (Minikube)
```bash
kubectl port-forward svc/rainbow-dashboard 8787:8787
# Open http://localhost:8787
```

#### NodePort (Minikube with IP)
```bash
# Get minikube IP
MINIKUBE_IP=$(minikube ip)

# Convert to NodePort (optional)
kubectl patch svc rainbow-dashboard -p '{"spec":{"type":"NodePort"}}'
NODE_PORT=$(kubectl get svc rainbow-dashboard -o jsonpath='{.spec.ports[0].nodePort}')

# Open http://$MINIKUBE_IP:$NODE_PORT
```

## Logs and Debugging

```bash
# View dashboard logs
kubectl logs deployment/rainbow-dashboard -f

# Watch status
kubectl get pods -l app=rainbow-dashboard -w
```

## Deployment Structure

- **Dockerfile**: [Dockerfile.dashboard](../Dockerfile.dashboard)
- **Manifest**: [dashboard-deployment.yaml](dashboard-deployment.yaml)
- **Service**: ClusterIP on port 8787, requires port-forward or NodePort

### RBAC

The dashboard requires read-only access to:
- `TemporalWorkerDeployments` (temporal.io)
- `Deployments` (apps)

These are configured in `dashboard-deployment.yaml`.

## EKS Deployment

For Amazon EKS:

1. Push dashboard image to ECR
2. Update `image:` in `dashboard-deployment.yaml` to ECR URI
3. Create LoadBalancer service (optional):

```yaml
apiVersion: v1
kind: Service
metadata:
  name: rainbow-dashboard-lb
  namespace: default
spec:
  type: LoadBalancer
  ports:
    - port: 80
      targetPort: 8787
  selector:
    app: rainbow-dashboard
```

Then access at `http://<ELB-DNS>:80`

## Updating the Dashboard

To rebuild and redeploy after code changes:

```bash
# For minikube (uses local docker)
skaffold run --profile dashboard

# For EKS, rebuild image and push to ECR, then:
kubectl rollout restart deployment/rainbow-dashboard
```
