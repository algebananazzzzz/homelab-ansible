SHELL := bash
PLAYBOOK := .venv/bin/ansible-playbook playbooks/site.yml

SOPS_VERSION := 3.13.3
SOPS_SHA256 := e5bec3346a873ae91d871550f3e698c1aad962aff462a080e40f25fde17fef6b
AGE_VERSION := 1.3.2
AGE_SHA256 := cbe24006683f8eb669266162894b9a522a1af52f2665fbc63a4bb032ed26ac10

.PHONY: setup deploy check

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

deploy:
	$(PLAYBOOK)

check:
	$(PLAYBOOK) --check --diff
