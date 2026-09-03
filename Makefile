# Atajos para operar el servidor de Project Zomboid.
# Requiere: docker + docker compose, y un .env (cp .env.example .env).
SHELL := /bin/bash
.DEFAULT_GOAL := help

# setup.sh instala tofu y el CLI oci en ~/.local/bin (no hay sudo en el camino feliz), y esa
# carpeta no siempre esta en el PATH de una sesion recien abierta.
export PATH := $(HOME)/.local/bin:$(PATH)

COMPOSE := docker compose
SERVICE := zomboid
DATA_UID := $(shell id -u)
DATA_GID := $(shell id -g)

.PHONY: help setup doctor deploy destroy-all
.PHONY: dirs mcrcon render up down restart logs rcon status
.PHONY: backup restore wipe update
.PHONY: infra-init infra-plan infra-apply infra-destroy
.PHONY: require-ip remote-status remote-logs remote-restart remote-down remote-up remote-rcon remote-backup sync
.PHONY: encuesta-up encuesta-down encuesta-estado encuesta-resultados encuesta-aplicar

help: ## Muestra esta ayuda
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-13s\033[0m %s\n", $$1, $$2}'

# =============================================================================================
# Los cuatro comandos del camino feliz (ver README.md)
# =============================================================================================

setup: ## Asistente de configuracion: te pregunta todo y escribe .env y terraform.tfvars
	@./setup.sh

doctor: ## Revisa que este todo listo y explica que falta, en castellano
	@scripts/doctor.sh

deploy: ## Crea el server en la nube de punta a punta. Uso: make deploy [YES=1] [DRY_RUN=1]
	@scripts/deploy.sh $(if $(YES),--yes,) $(if $(DRY_RUN),--dry-run,)

destroy-all: ## Borra el server de la nube para dejar de pagar (con backup final y confirmacion)
	@scripts/destroy-all.sh $(if $(DRY_RUN),--dry-run,)

dirs: ## Crea los bind mounts con el UID correcto (uid/gid 1000 = usuario steam de la imagen)
	@mkdir -p data/zomboid data/workshop
	@echo "dirs: data/zomboid y data/workshop listos ($(DATA_UID):$(DATA_GID))"

mcrcon: ## Compila ./bin/mcrcon si no hay uno en el sistema
	@scripts/build-mcrcon.sh

render: dirs ## Renderiza config/ + .env -> data/zomboid/Server/
	@scripts/render-config.sh

up: render ## Renderiza la config y levanta el server
	@$(COMPOSE) up -d
	@echo "up: arrancando. Ver progreso con 'make logs'; el server esta arriba cuando aparece '*** SERVER STARTED ****'."

down: ## Apagado limpio: aviso + save + quit por RCON (nunca 'docker stop' a secas)
	@scripts/stop.sh

restart: ## Apagado limpio + re-render de la config + arranque (para aplicar cambios de mods/ini)
	@scripts/restart.sh

logs: ## Sigue el log del server
	@$(COMPOSE) logs -f $(SERVICE)

rcon: ## Comando de admin por RCON. Uso: make rcon CMD=players
	@test -n '$(CMD)' || { echo "uso: make rcon CMD=players"; exit 1; }
	@scripts/rcon.sh '$(CMD)'

status: ## Estado del contenedor y de los jugadores conectados
	@$(COMPOSE) ps
	@echo "--- jugadores ---"
	@scripts/rcon.sh players 2>/dev/null || echo "(RCON no responde: el server no esta arriba todavia)"

# =============================================================================================
# Operacion de la partida (Fase 2)
# =============================================================================================

backup: ## Backup del mundo: save + tar + rclone al bucket. Uso: make backup [LABEL=pre-wipe]
	@scripts/backup.sh $(LABEL)

restore: ## Restaura un backup. Uso: make restore FILE=backups/zomboid-....tar.zst
	@test -n '$(FILE)' || { echo "uso: make restore FILE=backups/zomboid-YYYYmmdd-HHMM.tar.zst"; exit 1; }
	@scripts/restore.sh '$(FILE)'

wipe: ## Borra la partida (backup 'pre-wipe' primero). Pide confirmacion.
	@scripts/wipe.sh

update: ## Apagado limpio + docker compose pull + arranque (aplica un digest nuevo del compose)
	@scripts/update.sh

# =============================================================================================
# Infraestructura (OpenTofu)
# =============================================================================================

TF_DIR  := infra/terraform/envs/prod
TOFU    ?= tofu

infra-init: ## tofu init en infra/terraform/envs/prod
	@$(TOFU) -chdir=$(TF_DIR) init

infra-plan: ## tofu plan
	@$(TOFU) -chdir=$(TF_DIR) plan

infra-apply: ## tofu apply (crea/actualiza la VM en OCI)
	@$(TOFU) -chdir=$(TF_DIR) apply

infra-destroy: ## tofu destroy. OJO: borra la VM y el boot volume (los backups del bucket quedan)
	@$(TOFU) -chdir=$(TF_DIR) destroy

# =============================================================================================
# Operacion remota (desde la PC del admin contra la VM)
# =============================================================================================

VM_USER  ?= pz
VM_DIR   ?= /opt/zomboid-server
# Si no se pasa VM_IP=..., se lee del output de OpenTofu (evaluacion diferida: solo corre tofu
# cuando algun target remoto usa la variable). El grep no es paranoia: sin state, `tofu output`
# escribe un warning en stdout y sale con 0, asi que hay que quedarse solo con lo que es una IP.
VM_IP    ?= $(shell $(TOFU) -chdir=$(TF_DIR) output -raw -no-color public_ip 2>/dev/null \
              | grep -Eom1 '^([0-9]{1,3}\.){3}[0-9]{1,3}$$')
SSH      := ssh -o ConnectTimeout=10
REMOTE    = $(SSH) $(VM_USER)@$(VM_IP)

# Falla temprano y con un mensaje util si no hay IP. Es prerrequisito de todo target remoto.
require-ip:
	@test -n '$(VM_IP)' || { \
	  echo "No hay VM_IP. Opciones:"; \
	  echo "  make remote-status VM_IP=1.2.3.4"; \
	  echo "  cd $(TF_DIR) && tofu output -raw public_ip     (requiere el .tfstate local)"; \
	  exit 1; }

remote-status: require-ip ## Estado del server en la VM
	@$(REMOTE) 'cd $(VM_DIR) && make status'

remote-logs: require-ip ## Sigue el log del server en la VM (Ctrl-C para salir)
	@$(REMOTE) -t 'cd $(VM_DIR) && make logs'

remote-up: require-ip ## Levanta el server en la VM
	@$(REMOTE) 'cd $(VM_DIR) && make up'

remote-down: require-ip ## Apagado limpio del server en la VM (no apaga la VM)
	@$(REMOTE) 'cd $(VM_DIR) && make down'

remote-restart: require-ip ## Reinicio limpio del server en la VM (aplica cambios de config/mods)
	@$(REMOTE) 'cd $(VM_DIR) && make restart'

remote-rcon: require-ip ## Comando RCON contra la VM. Uso: make remote-rcon CMD=players
	@test -n '$(CMD)' || { echo "uso: make remote-rcon CMD=players"; exit 1; }
	@$(REMOTE) "cd $(VM_DIR) && ./scripts/rcon.sh '$(CMD)'"

remote-backup: require-ip ## Fuerza un backup en la VM (queda en el bucket)
	@$(REMOTE) 'cd $(VM_DIR) && ./scripts/backup.sh'

sync: require-ip ## rsync de config/, scripts/, tools/, infra/systemd/, Makefile y compose a la VM. Uso: make sync [RESTART=1]
	@rsync -az --delete-after --chmod=D755,F644 \
	  --include='/config/***' \
	  --include='/scripts/***' \
	  --include='/tools/***' \
	  --include='/infra/' \
	  --include='/infra/systemd/***' \
	  --include='/Makefile' \
	  --include='/docker-compose.yml' \
	  --exclude='*' \
	  ./ $(VM_USER)@$(VM_IP):$(VM_DIR)/
	@$(REMOTE) 'chmod +x $(VM_DIR)/scripts/*.sh'
	@echo "sync: config y scripts actualizados en $(VM_USER)@$(VM_IP):$(VM_DIR)"
	@echo "sync: NO se sincronizan .env, data/ ni bin/ (son propios de la VM)."
	@if [ -n '$(RESTART)' ]; then $(MAKE) remote-restart; else \
	  echo "sync: para aplicar los cambios: make remote-restart (o make sync RESTART=1)"; fi

# =============================================================================================
# Encuesta de reglas de la partida (tools/encuesta)
# =============================================================================================

encuesta-up: ## Levanta la encuesta web en la VM e imprime la URL para pasarles a los amigos
	@scripts/encuesta.sh up

encuesta-down: ## Apaga la encuesta (los votos quedan guardados en la VM)
	@scripts/encuesta.sh down

encuesta-estado: ## Estado de la encuesta y cuantas personas votaron
	@scripts/encuesta.sh estado

encuesta-resultados: ## Baja los votos y muestra el conteo y la propuesta de cambios
	@scripts/encuesta.sh resultados

encuesta-aplicar: ## Escribe en config/ lo que gano la votacion y muestra el diff
	@scripts/encuesta.sh aplicar
