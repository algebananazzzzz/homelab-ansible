SHELL := bash
# Sourced rather than included, since make cannot parse the multi-line CA key.
ENV := set -a && source .env && set +a &&
PLAYBOOK := $(ENV) .venv/bin/ansible-playbook site.yml
TERRAFORM := $(ENV) .venv/bin/terraform -chdir=infra

TERRAFORM_VERSION := 1.16.5
TERRAFORM_SHA256 := 2bc2fcfff033265c9e02ca0351f01794eb122f62a9b2a49a3294b9e49eaab5e4

.PHONY: setup deploy check plan apply

setup:
	python3 -m venv .venv
	.venv/bin/pip install -r requirements.txt
	.venv/bin/ansible-galaxy collection install -r collections/requirements.yml
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
