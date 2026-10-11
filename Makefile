SHELL := bash
PLAYBOOK := .venv/bin/ansible-playbook site.yml
TERRAFORM := CLOUDFLARE_API_TOKEN=$$(.venv/bin/sops -d --extract '["cloudflare_api_token"]' inventories/homelab/group_vars/all.sops.yml) .venv/bin/terraform -chdir=infra

SOPS_VERSION := 3.13.3
SOPS_SHA256 := e5bec3346a873ae91d871550f3e698c1aad962aff462a080e40f25fde17fef6b
AGE_VERSION := 1.3.2
AGE_SHA256 := cbe24006683f8eb669266162894b9a522a1af52f2665fbc63a4bb032ed26ac10
TERRAFORM_VERSION := 1.16.5
TERRAFORM_SHA256 := 2bc2fcfff033265c9e02ca0351f01794eb122f62a9b2a49a3294b9e49eaab5e4

.PHONY: setup deploy check plan apply

setup:
	python3 -m venv .venv
	.venv/bin/pip install -r requirements.txt
	.venv/bin/ansible-galaxy collection install -r collections/requirements.yml
	curl -fsSLo .venv/bin/sops https://github.com/getsops/sops/releases/download/v$(SOPS_VERSION)/sops-v$(SOPS_VERSION).linux.amd64
	echo "$(SOPS_SHA256)  .venv/bin/sops" | sha256sum -c -
	chmod 755 .venv/bin/sops
	curl -fsSLo .venv/age.tar.gz https://github.com/FiloSottile/age/releases/download/v$(AGE_VERSION)/age-v$(AGE_VERSION)-linux-amd64.tar.gz
	echo "$(AGE_SHA256)  .venv/age.tar.gz" | sha256sum -c -
	tar -xzf .venv/age.tar.gz -C .venv/bin --strip-components=1 age/age age/age-keygen
	rm .venv/age.tar.gz
	curl -fsSLo .venv/terraform.zip https://releases.hashicorp.com/terraform/$(TERRAFORM_VERSION)/terraform_$(TERRAFORM_VERSION)_linux_amd64.zip
	echo "$(TERRAFORM_SHA256)  .venv/terraform.zip" | sha256sum -c -
	unzip -o -d .venv/bin .venv/terraform.zip terraform
	rm .venv/terraform.zip
	.venv/bin/terraform -chdir=infra init -backend-config=config/lab.tfbackend

deploy:
	$(PLAYBOOK)

check:
	$(PLAYBOOK) --check --diff

plan:
	$(TERRAFORM) plan

apply:
	$(TERRAFORM) apply
