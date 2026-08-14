# platform_engineer_project
The project is to demonstrate Platform Engineering  Skills(portfolio)

## Traefik installation

Traefik is installed through the Helm chart in `traefik/values.yaml`.

1. Add the Helm repository:

   ```bash
   helm repo add traefik https://traefik.github.io/charts
   helm repo update
   ```

2. Create the namespace:

   ```bash
   kubectl create namespace traefik --dry-run=client -o yaml | kubectl apply -f -
   ```

3. Install Traefik with the project values:

   ```bash
   helm install traefik traefik/traefik -n traefik -f traefik/values.yaml
   ```

4. Verify the rollout:

   ```bash
   kubectl -n traefik get pods,svc
   ```
