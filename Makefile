# Atajos para operar el servidor de Project Zomboid.
# Requiere: docker + docker compose, y un .env (cp .env.example .env).
SHELL := /bin/bash
.DEFAULT_GOAL := help

COMPOSE := docker compose
SERVICE := zomboid
DATA_UID := $(shell id -u)
DATA_GID := $(shell id -g)

.PHONY: help dirs mcrcon render up down restart logs rcon status

help: ## Muestra esta ayuda
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

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
