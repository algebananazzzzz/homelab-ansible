SHELL := bash
PLAYBOOK := set -a; . ./.env; set +a; .venv/bin/ansible-playbook playbooks/site.yml

.PHONY: setup deploy check

setup:
	python3 -m venv .venv
	.venv/bin/pip install -r requirements.txt
	.venv/bin/ansible-galaxy collection install -r collections/requirements.yml

deploy:
	$(PLAYBOOK)

check:
	$(PLAYBOOK) --check --diff
