# Variables
KIND_CLUSTER_NAME := $(if $(CLUSTER_NAME),$(CLUSTER_NAME),taskteck-cluster)
DOMAIN := $(if $(LOCAL_DOMAIN),$(LOCAL_DOMAIN),.taskteck.local)

ARGOCD_SECRET_NAME := argocd-keys
ARGOCD_NAMESPACE := argo-cd

CURL := curl
DOCKER := docker
HELM := helm
KIND := kind
KUBECTL := kubectl
JQ := jq
YQ := yq
ARGOCD := argocd

REQUIRED_BINS := docker kind helm kubectl jq yq curl argocd

default:
	@echo $(KIND_CLUSTER_NAME)

# Verifica se os binários necessários estão instalados
.PHONY: check-prerequisites
check-prerequisites:
	@$(foreach bin,$(REQUIRED_BINS), \
		if ! [ -x "$(shell command -v $(bin))" ]; then \
			echo "Error: $(bin) is not installed or not in the PATH"; \
			exit 1; \
		fi; \
	)
	@$(shell echo "----------------------------------------------------------------------------------------------$@")

# Remove o cluster
.PHONY: destroy-cluster
destroy-cluster: check-prerequisites
	$(KIND) delete cluster --name $(KIND_CLUSTER_NAME)
	@if $(KIND) network ls -f name=kind -q; then $(DOCKER) network rm $(docker network ls -f name=kind -q); fi

# Cria o cluster
.PHONY: create-cluster
create-cluster: check-prerequisites
ifeq (, $(shell $(KIND) get clusters | grep $(KIND_CLUSTER_NAME)))
	@if $(KIND) network ls -f name=kind -q; then $(DOCKER) network rm $(docker network ls -f name=kind -q); fi
	@$(KIND) create cluster --name $(KIND_CLUSTER_NAME) --config .kind/config.yaml
	$(MAKE) .setup-cluster
else
	@echo "Cluster already exists"
endif

# Configura cluster
.PHONY: .setup-cluster
.setup-cluster: check-prerequisites .setup-network .setup-apps

# Configura network
.PHONY: .setup-network
.setup-network: check-prerequisites setup-cilium setup-metallb setup-ingress

# Configura apps
.PHONY: .setup-apps
.setup-apps: check-prerequisites setup-argocd

.PHONY: setup-cilium
setup-cilium: check-prerequisites
	$(HELM) upgrade --install cilium cilium \
		--repo=https://helm.cilium.io \
		--version 1.15.0 \
		--namespace kube-system \
		--create-namespace \
		--reuse-values \
		--set ipam.mode=kubernetes \
		--set hostPort.enabled=true \
		--set hostsPort.enabled=true \
		--set nodePort.enabled=true \
		--set externalIPs.enabled=true \
		--set kubeProxyReplacement=strict \
		--set hostServices.enabled=true \
		--set cluster.name=$(KIND_CLUSTER_NAME) \
		--set hubble.relay.enabled=true \
		--set hubble.ui.enabled=true \
		--set hubble.metrics.enabled="{dns,drop,tcp,flow,port-distribution,icmp,http}"
	$(KUBECTL) rollout status -n kube-system daemonset/cilium

.PHONY: setup-metallb
setup-metallb: check-prerequisites
	@$(HELM) upgrade --install metallb metallb \
		--repo=https://metallb.github.io/metallb \
		--version 0.13.7 \
		--namespace metallb-system \
		--create-namespace
	@$(KUBECTL) rollout status -n metallb-system deployment/metallb-controller

ifeq ("true","$(shell docker network inspect -f '{{.EnableIPv6}}' kind)")
	$(eval DOCKER_SUBNET_FILTER:="{{(index .IPAM.Config 1).Subnet}}")
else
	$(eval DOCKER_SUBNET_FILTER:="{{(index .IPAM.Config 0).Subnet}}")
endif

	$(eval DOCKER_SUBNET := $(shell docker network inspect -f '$(DOCKER_SUBNET_FILTER)' kind))
	@$(HELM) upgrade --install metallb-config ./assets/metallb-config/helm \
		--namespace metallb-system \
		--create-namespace \
		--set addressPool.addresses[0]="$(DOCKER_SUBNET)"

.PHONY: setup-ingress
setup-ingress: check-prerequisites
	$(HELM) upgrade --install ingress-nginx ingress-nginx \
		--repo=https://kubernetes.github.io/ingress-nginx \
		--version 4.11.2 \
		--namespace kube-system \
		--create-namespace \
		--set controller.updateStrategy.type=RollingUpdate \
		--set controller.updateStrategy.rollingUpdate.maxUnavailable=1 \
		--set controller.hostPort.enabled=true \
		--set controller.terminationGracePeriodSeconds=0 \
		--set controller.service.type=NodePort \
		--set controller.watchIngressWithoutClass=true \
		--set-string controller.nodeSelector."ingress-ready"=true \
		--set controller.tolerations[0].key="node-role.kubernetes.io/master" \
		--set controller.tolerations[0].operator="Equal" \
		--set controller.tolerations[0].effect="NoSchedule" \
		--set controller.tolerations[1].key="node-role.kubernetes.io/control-plane" \
		--set controller.tolerations[1].operator="Equal" \
		--set controller.tolerations[1].effect="NoSchedule" \
		--set controller.publishService.enabled=true \
		--set controller.allowSnippetAnnotations=true
	$(KUBECTL) rollout status -n kube-system deployment/ingress-nginx-controller

.PHONY: setup-argocd
setup-argocd: check-prerequisites
	@$(HELM) upgrade --install argo-cd argo-cd \
		--repo=https://argoproj.github.io/argo-helm \
		--version 7.1.3 \
		--namespace $(ARGOCD_NAMESPACE) \
		--create-namespace \
		--set global.domain=argocd$(DOMAIN) \
		--set server.ingress.enabled=true \
		--set server.ingress.ingressClassName=nginx \
		--set server.ingress.hostname="argocd$(DOMAIN)" \
		--set server.ingress.annotations."nginx\.ingress\.kubernetes\.io/force-ssl-redirect"=false \
		--set server.ingress.annotations."nginx\.ingress\.kubernetes\target_namespace.io/ssl-redirect"=false \
		--set configs.params."server\.insecure"=true \
		--set configs.annotations."server\.insecure"=true \
		--set configs.cm.annotations."url"="http://argocd$(DOMAIN)" \
		--set notifications.argocdUrl="http://argocd$(DOMAIN)" \
		--set server.extraArgs[0]="--insecure" \
		--set configs.secret.argocdServerAdminPassword=$$($(ARGOCD) account bcrypt --password $(ARGOCD_SECRET))
	@echo "Aguardando argocd"
	@until $(CURL) --output /dev/null --silent --head --fail http://argocd$(DOMAIN); do printf '.'; sleep 10; done
	@$(ARGOCD) login argocd$(DOMAIN) --username admin --password $(ARGOCD_SECRET) --insecure --grpc-web --plaintext
	@$(ARGOCD) repo add ghcr.io/actions/actions-runner-controller-charts --type helm --name actions-runner-controller-charts --enable-oci
	@$(ARGOCD) repo add ghcr.io/external-secrets/charts --type helm --name external-secrets --enable-oci
	@./scripts/pre-calls.sh pre-end
