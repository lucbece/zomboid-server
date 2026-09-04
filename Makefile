# Atajos para operar el servidor de Project Zomboid.
# Requiere: docker + docker compose, y un .env (cp .env.example .env).
SHELL := /bin/bash
.DEFAULT_GOAL := help

# setup.sh instala tofu y el CLI oci en ~/.local/bin (no hay sudo en el camino feliz), y esa
# carpeta no siempre esta en el PATH de una sesion recien abierta.
export PATH := $(HOME)/.local/bin:$(PATH)

# Idioma del CLI. Misma resolucion que scripts/lib/i18n.sh (entorno > .env > locale > en);
# se pisa por linea de comando con  ZS_LANG=en make ...  El catalogo necesita bash 4, por eso
# se lo invoca con bash y no con el /bin/sh del $(shell).
ZS_LANG ?= $(shell bash -c 'source scripts/lib/i18n.sh >/dev/null 2>&1; echo $$ZS_LANG')
# Los mensajes de las recetas salen del mismo catalogo que los de los scripts.
I18N := source scripts/lib/i18n.sh
NO_LOG = $(shell bash -c '$(I18N); t make.no_log')
NO_IDLE_LINE = $(shell bash -c '$(I18N); t make.idle.no_line')

COMPOSE := docker compose
# venv del bot de Discord en su instancia (ver infra/cloud-init-bot.yaml).
BOT_VENV := /opt/pz-bot-venv
SERVICE := zomboid
DATA_UID := $(shell id -u)
DATA_GID := $(shell id -g)

.PHONY: help setup doctor deploy destroy-all
.PHONY: dirs mcrcon render up down restart logs rcon status
.PHONY: backup restore wipe update
.PHONY: infra-init infra-plan infra-apply infra-destroy
.PHONY: require-ip remote-status remote-logs remote-restart remote-down remote-up remote-rcon remote-backup remote-diff sync
.PHONY: watchdog-install watchdog-status
.PHONY: notifier-install notifier-status
.PHONY: mod-updater-install mod-updater-status mods-check
.PHONY: encuesta-up encuesta-down encuesta-estado encuesta-resultados encuesta-aplicar
.PHONY: panel-up panel-down panel-estado panel-token panel-tokens panel-revoke panel-log
.PHONY: require-bot-ip bot-install bot-status bot-logs bot-tests idle-shutdown-install idle-shutdown-status

# Cada descripcion trae los dos idiomas:  target: ## English ## es: Castellano
help: ## Show this help ## es: Muestra esta ayuda
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) \
	  | awk -v lang='$(ZS_LANG)' '{ \
	      c = index($$0, ":"); if (c == 0) next; target = substr($$0, 1, c - 1); \
	      h = index($$0, "## "); if (h == 0) next; rest = substr($$0, h + 3); \
	      e = index(rest, "## es: "); en = rest; es = ""; \
	      if (e > 0) { en = substr(rest, 1, e - 1); es = substr(rest, e + 7); } \
	      sub(/[ \t]+$$/, "", en); \
	      d = (lang == "es" && es != "") ? es : en; \
	      printf "  \033[36m%-13s\033[0m %s\n", target, d }'

# =============================================================================================
# Los cuatro comandos del camino feliz (ver README.md)
# =============================================================================================

setup: ## Configuration assistant: asks everything and writes .env and terraform.tfvars ## es: Asistente de configuracion: te pregunta todo y escribe .env y terraform.tfvars
	@./setup.sh

doctor: ## Check that everything is ready and explain what is missing ## es: Revisa que este todo listo y explica que falta
	@scripts/doctor.sh

deploy: ## Create the cloud server end to end. Usage: make deploy [YES=1] [DRY_RUN=1] ## es: Crea el server en la nube de punta a punta. Uso: make deploy [YES=1] [DRY_RUN=1]
	@scripts/deploy.sh $(if $(YES),--yes,) $(if $(DRY_RUN),--dry-run,)

destroy-all: ## Delete the cloud server to stop paying (final backup and confirmation) ## es: Borra el server de la nube para dejar de pagar (con backup final y confirmacion)
	@scripts/destroy-all.sh $(if $(DRY_RUN),--dry-run,)

dirs: ## Create the bind mounts with the right UID (uid/gid 1000 = the image's steam user) ## es: Crea los bind mounts con el UID correcto (uid/gid 1000 = usuario steam de la imagen)
	@mkdir -p data/zomboid data/workshop
	@bash -c '$(I18N); t make.dirs.done "$(DATA_UID)" "$(DATA_GID)"; echo'

mcrcon: ## Build ./bin/mcrcon if the system has none ## es: Compila ./bin/mcrcon si no hay uno en el sistema
	@scripts/build-mcrcon.sh

render: dirs ## Render config/ + .env -> data/zomboid/Server/ ## es: Renderiza config/ + .env -> data/zomboid/Server/
	@scripts/render-config.sh

up: render ## Render the configuration and start the server ## es: Renderiza la config y levanta el server
	@$(COMPOSE) up -d
	@bash -c '$(I18N); t make.up.started; echo'

down: ## Clean shutdown: warning + save + quit over RCON (never a bare 'docker stop') ## es: Apagado limpio: aviso + save + quit por RCON (nunca 'docker stop' a secas)
	@scripts/stop.sh

restart: ## Clean shutdown + re-render + start (applies mod and ini changes) ## es: Apagado limpio + re-render de la config + arranque (para aplicar cambios de mods/ini)
	@scripts/restart.sh

logs: ## Follow the server log ## es: Sigue el log del server
	@$(COMPOSE) logs -f $(SERVICE)

rcon: ## Admin command over RCON. Usage: make rcon CMD=players ## es: Comando de admin por RCON. Uso: make rcon CMD=players
	@test -n '$(CMD)' || { bash -c '$(I18N); t make.rcon.usage; echo'; exit 1; }
	@scripts/rcon.sh '$(CMD)'

status: ## Container state and connected players ## es: Estado del contenedor y de los jugadores conectados
	@$(COMPOSE) ps
	@bash -c '$(I18N); t make.status.players; echo'
	@scripts/rcon.sh players 2>/dev/null || bash -c '$(I18N); t make.status.rcon_down; echo'

# =============================================================================================
# Operacion de la partida (Fase 2)
# =============================================================================================

backup: ## World backup: save + tar + rclone to the bucket. Usage: make backup [LABEL=pre-wipe] ## es: Backup del mundo: save + tar + rclone al bucket. Uso: make backup [LABEL=pre-wipe]
	@scripts/backup.sh $(LABEL)

restore: ## Restore a backup. Usage: make restore FILE=backups/zomboid-....tar.zst ## es: Restaura un backup. Uso: make restore FILE=backups/zomboid-....tar.zst
	@test -n '$(FILE)' || { bash -c '$(I18N); t make.restore.usage; echo'; exit 1; }
	@scripts/restore.sh '$(FILE)'

wipe: ## Delete the game (takes a 'pre-wipe' backup first). Asks for confirmation. ## es: Borra la partida (backup 'pre-wipe' primero). Pide confirmacion.
	@scripts/wipe.sh

update: ## Clean shutdown + docker compose pull + start (applies a new compose digest) ## es: Apagado limpio + docker compose pull + arranque (aplica un digest nuevo del compose)
	@scripts/update.sh

# =============================================================================================
# Infraestructura (OpenTofu)
# =============================================================================================

TF_DIR  := infra/terraform/envs/prod
TOFU    ?= tofu

infra-init: ## tofu init in infra/terraform/envs/prod ## es: tofu init en infra/terraform/envs/prod
	@$(TOFU) -chdir=$(TF_DIR) init

infra-plan: ## tofu plan ## es: tofu plan
	@$(TOFU) -chdir=$(TF_DIR) plan

infra-apply: ## tofu apply (creates or updates the VM in OCI) ## es: tofu apply (crea/actualiza la VM en OCI)
	@$(TOFU) -chdir=$(TF_DIR) apply

infra-destroy: ## tofu destroy. Careful: deletes the VM and the boot volume (bucket backups remain) ## es: tofu destroy. OJO: borra la VM y el boot volume (los backups del bucket quedan)
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
	@test -n '$(VM_IP)' || { bash -c '$(I18N); t make.require_ip "$(TF_DIR)"; echo'; exit 1; }

remote-status: require-ip ## Server state on the VM ## es: Estado del server en la VM
	@$(REMOTE) 'cd $(VM_DIR) && make status'

remote-logs: require-ip ## Follow the server log on the VM (Ctrl-C to exit) ## es: Sigue el log del server en la VM (Ctrl-C para salir)
	@$(REMOTE) -t 'cd $(VM_DIR) && make logs'

remote-up: require-ip ## Start the server on the VM ## es: Levanta el server en la VM
	@$(REMOTE) 'cd $(VM_DIR) && make up'

remote-down: require-ip ## Clean server shutdown on the VM (does not stop the VM) ## es: Apagado limpio del server en la VM (no apaga la VM)
	@$(REMOTE) 'cd $(VM_DIR) && make down'

remote-restart: require-ip ## Clean server restart on the VM (applies configuration and mod changes) ## es: Reinicio limpio del server en la VM (aplica cambios de config/mods)
	@$(REMOTE) 'cd $(VM_DIR) && make restart'

remote-rcon: require-ip ## RCON command against the VM. Usage: make remote-rcon CMD=players ## es: Comando RCON contra la VM. Uso: make remote-rcon CMD=players
	@test -n '$(CMD)' || { bash -c '$(I18N); t make.remote_rcon.usage; echo'; exit 1; }
	@$(REMOTE) "cd $(VM_DIR) && ./scripts/rcon.sh '$(CMD)'"

remote-backup: require-ip ## Force a backup on the VM (stored in the bucket) ## es: Fuerza un backup en la VM (queda en el bucket)
	@$(REMOTE) 'cd $(VM_DIR) && ./scripts/backup.sh'

remote-diff: require-ip ## Show the uncommitted changes left on the VM (autorepair leaves them) ## es: Muestra los cambios sin commitear que quedaron en la VM (los deja autorepair)
	@$(REMOTE) 'git -C $(VM_DIR) status --short && echo "--- diff ---" && git -C $(VM_DIR) diff'
	@bash -c '$(I18N); t make.remote_diff.note; echo'

# =============================================================================================
# Watchdog y auto-arreglo (docs/self-healing.md)
# =============================================================================================

watchdog-install: require-ip ## Install and enable the watchdog on the VM (timer every 2 minutes) ## es: Instala y habilita el watchdog en la VM (timer cada 2 minutos)
	@$(MAKE) sync VM_IP=$(VM_IP) >/dev/null
	@$(REMOTE) "sudo install -m 644 -o root -g root \
	              '$(VM_DIR)/infra/systemd/zomboid-watchdog.service' \
	              '$(VM_DIR)/infra/systemd/zomboid-watchdog.timer' /etc/systemd/system/ && \
	            sudo install -d -m 755 -o $(VM_USER) -g $(VM_USER) /var/log/zomboid /var/tmp/zomboid-watchdog && \
	            sudo systemctl daemon-reload && \
	            sudo systemctl enable --now zomboid-watchdog.timer"
	@bash -c '$(I18N); t make.watchdog.installed; echo'
	@bash -c '$(I18N); t make.watchdog.discord; echo'

watchdog-status: require-ip ## Watchdog state on the VM and the last lines of its log ## es: Estado del watchdog en la VM y ultimas lineas de su log
	@$(REMOTE) 'systemctl list-timers --no-pager zomboid-watchdog.timer; \
	            systemctl status --no-pager --lines=5 zomboid-watchdog.service || true; \
	            echo "--- /var/log/zomboid/watchdog.log ---"; \
	            tail -n $${N:-20} /var/log/zomboid/watchdog.log 2>/dev/null || echo "$(NO_LOG)"'

# =============================================================================================
# Mods al dia con el Workshop (docs/mods.md, "Mod updates")
# =============================================================================================

mod-updater-install: require-ip ## Install and enable the mod updater on the VM (timer every 5 minutes) ## es: Instala y habilita el actualizador de mods en la VM (timer cada 5 minutos)
	@$(MAKE) sync VM_IP=$(VM_IP) >/dev/null
	@$(REMOTE) "sudo install -m 644 -o root -g root \
	              '$(VM_DIR)/infra/systemd/zomboid-mod-updater.service' \
	              '$(VM_DIR)/infra/systemd/zomboid-mod-updater.timer' /etc/systemd/system/ && \
	            sudo install -d -m 755 -o $(VM_USER) -g $(VM_USER) /var/log/zomboid /var/tmp/zomboid-mod-updater && \
	            sudo install -m 644 -o $(VM_USER) -g $(VM_USER) /dev/null /var/tmp/zomboid-ops.lock && \
	            sudo systemctl daemon-reload && \
	            sudo systemctl enable --now zomboid-mod-updater.timer"
	@bash -c '$(I18N); t make.modupd.installed; echo'
	@bash -c '$(I18N); t make.modupd.policy; echo'

mod-updater-status: require-ip ## Mod updater state on the VM and the last lines of its log ## es: Estado del actualizador de mods en la VM y ultimas lineas de su log
	@$(REMOTE) 'systemctl list-timers --no-pager zomboid-mod-updater.timer; \
	            systemctl status --no-pager --lines=5 zomboid-mod-updater.service || true; \
	            echo "--- /var/log/zomboid/mod-updater.log ---"; \
	            tail -n $${N:-20} /var/log/zomboid/mod-updater.log 2>/dev/null || echo "$(NO_LOG)"'

mods-check: require-ip ## Compare the VM mods with the Workshop (read only, restarts nothing) ## es: Compara los mods de la VM con el Workshop (solo lectura, no reinicia nada)
	@$(REMOTE) 'cd $(VM_DIR) && ./scripts/mod-updater.sh --check'

# =============================================================================================
# Avisos de estado en Discord (docs/discord.md)
# =============================================================================================

notifier-install: require-ip ## Install and enable the Discord notifications on the VM (daemon) ## es: Instala y habilita los avisos de Discord en la VM (daemon)
	@$(MAKE) sync VM_IP=$(VM_IP) >/dev/null
	@$(REMOTE) "sudo install -m 644 -o root -g root \
	              '$(VM_DIR)/infra/systemd/zomboid-notifier.service' /etc/systemd/system/ && \
	            sudo install -d -m 755 -o $(VM_USER) -g $(VM_USER) /var/tmp/zomboid-notifier && \
	            sudo systemctl daemon-reload && \
	            sudo systemctl enable --now zomboid-notifier.service && \
	            sudo systemctl restart zomboid-notifier.service"
	@bash -c '$(I18N); t make.notifier.installed; echo'
	@bash -c '$(I18N); t make.notifier.webhook; echo'

notifier-status: require-ip ## Discord notifications state on the VM and their last lines ## es: Estado de los avisos de Discord en la VM y sus ultimas lineas
	@$(REMOTE) 'systemctl status --no-pager --lines=0 zomboid-notifier.service || true; \
	            echo "--- journalctl -u zomboid-notifier ---"; \
	            sudo journalctl -u zomboid-notifier -n $${N:-20} --no-pager 2>/dev/null \
	              || echo "$(NO_LOG)"'

sync: require-ip ## rsync config/, scripts/, tools/, infra/systemd/, the Makefile and the compose file to the VM. Usage: make sync [RESTART=1] ## es: rsync de config/, scripts/, tools/, infra/systemd/, Makefile y compose a la VM. Uso: make sync [RESTART=1]
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
	@bash -c '$(I18N); t make.sync.done "$(VM_USER)@$(VM_IP):$(VM_DIR)"; echo'
	@bash -c '$(I18N); t make.sync.note; echo'
	@if [ -n '$(RESTART)' ]; then $(MAKE) remote-restart; else \
	  bash -c '$(I18N); t make.sync.hint; echo'; fi

# =============================================================================================
# Encuesta de reglas de la partida (tools/encuesta)
# =============================================================================================

encuesta-up: ## Start the web survey on the VM and print the URL to share with your friends ## es: Levanta la encuesta web en la VM e imprime la URL para pasarles a los amigos
	@scripts/encuesta.sh up

encuesta-down: ## Stop the survey (the votes stay on the VM) ## es: Apaga la encuesta (los votos quedan guardados en la VM)
	@scripts/encuesta.sh down

encuesta-estado: ## Survey state and how many people voted ## es: Estado de la encuesta y cuantas personas votaron
	@scripts/encuesta.sh estado

encuesta-resultados: ## Download the votes and show the tally and the proposed changes ## es: Baja los votos y muestra el conteo y la propuesta de cambios
	@scripts/encuesta.sh resultados

encuesta-aplicar: ## Write what the vote chose into config/ and show the diff ## es: Escribe en config/ lo que gano la votacion y muestra el diff
	@scripts/encuesta.sh aplicar

# =============================================================================================
# Panel de moderadores (tools/panel)
# =============================================================================================

panel-up: ## Start the moderator panel on the VM (port 8081) and install the unit ## es: Levanta el panel de moderadores en la VM (puerto 8081) e instala la unit
	@scripts/panel.sh up

panel-down: ## Stop the panel (the tokens stay on the VM) ## es: Apaga el panel (los tokens quedan guardados en la VM)
	@scripts/panel.sh down

panel-estado: ## Panel state, /salud and the moderators loaded ## es: Estado del panel, /salud y moderadores cargados
	@scripts/panel.sh estado

panel-token: ## Create a moderator token and print its URL. Usage: make panel-token NAME=Fulano ## es: Crea el token de un moderador e imprime su URL. Uso: make panel-token NAME=Fulano
	@test -n '$(NAME)' || { bash -c '$(I18N); t make.panel_token.usage; echo'; exit 1; }
	@scripts/panel.sh token add '$(NAME)'

panel-tokens: ## List the moderators that have a token (does not print the tokens) ## es: Lista los moderadores con token (no imprime los tokens)
	@scripts/panel.sh token list

panel-revoke: ## Revoke a moderator token. Usage: make panel-revoke NAME=Fulano ## es: Revoca el token de un moderador. Uso: make panel-revoke NAME=Fulano
	@test -n '$(NAME)' || { bash -c '$(I18N); t make.panel_revoke.usage; echo'; exit 1; }
	@scripts/panel.sh token revoke '$(NAME)'

panel-log: ## Last panel actions (who restarted and when). Usage: make panel-log [N=50] ## es: Ultimas acciones del panel (quien reinicio y cuando). Uso: make panel-log [N=50]
	@scripts/panel.sh log $(N)

# =============================================================================================
# Encendido on-demand: bot de Discord y apagado por inactividad (docs/on-demand.md)
# =============================================================================================

# La instancia del bot es otra maquina: tiene su propia IP (efimera) y su propio output.
BOT_IP   ?= $(shell $(TOFU) -chdir=$(TF_DIR) output -raw -no-color bot_public_ip 2>/dev/null \
              | grep -Eom1 '^([0-9]{1,3}\.){3}[0-9]{1,3}$$')
BOT_REMOTE = $(SSH) $(VM_USER)@$(BOT_IP)

require-bot-ip:
	@test -n '$(BOT_IP)' || { bash -c '$(I18N); t make.require_bot_ip "$(TF_DIR)"; echo'; exit 1; }

bot-install: require-bot-ip ## Copy the bot to its instance, update the venv and restart it ## es: Copia el bot a su instancia, actualiza el venv y lo reinicia
	@rsync -az --delete-after --chmod=D755,F644 \
	  --include='/tools/' \
	  --include='/tools/pz-bot/***' \
	  --include='/infra/' \
	  --include='/infra/systemd/***' \
	  --exclude='*' \
	  ./ $(VM_USER)@$(BOT_IP):$(VM_DIR)/
	@$(BOT_REMOTE) "$(BOT_VENV)/bin/pip install -q -r $(VM_DIR)/tools/pz-bot/requirements.txt && \
	            sudo install -m 644 -o root -g root '$(VM_DIR)/infra/systemd/pz-bot.service' /etc/systemd/system/ && \
	            sudo install -d -m 755 -o $(VM_USER) -g $(VM_USER) /var/tmp/pz-bot && \
	            sudo systemctl daemon-reload && \
	            sudo systemctl enable pz-bot.service && \
	            sudo systemctl restart pz-bot.service"
	@bash -c '$(I18N); t make.bot.installed; echo'

bot-status: require-bot-ip ## Discord bot state and its last log lines ## es: Estado del bot de Discord y sus ultimas lineas de log
	@$(BOT_REMOTE) 'systemctl status --no-pager --lines=0 pz-bot.service || true; \
	            echo "--- journalctl -u pz-bot ---"; \
	            sudo journalctl -u pz-bot -n $${N:-20} --no-pager 2>/dev/null || echo "$(NO_LOG)"'

bot-logs: require-bot-ip ## Follow the bot log (Ctrl-C to exit) ## es: Sigue el log del bot (Ctrl-C para salir)
	@$(BOT_REMOTE) -t 'sudo journalctl -u pz-bot -f'

bot-tests: ## Run the bot tests (needs neither discord.py nor the oci SDK) ## es: Corre los tests del bot (no necesita discord.py ni el SDK de oci)
	@cd tools/pz-bot && python3 -m unittest

idle-shutdown-install: require-ip ## Enable the idle shutdown on the game VM (cron every 5 minutes) ## es: Activa el apagado por inactividad en la VM del juego (cron cada 5 min)
	@$(MAKE) sync VM_IP=$(VM_IP) >/dev/null
	@$(REMOTE) "sudo install -d -m 755 -o $(VM_USER) -g $(VM_USER) /var/log/zomboid && \
	            sudo sed -i 's|^#\(\*/5 .*idle-shutdown.sh.*\)$$|\1|' /etc/cron.d/zomboid && \
	            grep -q '^\*/5 .*idle-shutdown' /etc/cron.d/zomboid"
	@bash -c '$(I18N); t make.idle.installed; echo'
	@bash -c '$(I18N); t make.idle.note; echo'

idle-shutdown-status: require-ip ## Show whether the idle shutdown is enabled and its last log ## es: Muestra si el apagado por inactividad esta activo y su ultimo log
	@$(REMOTE) 'echo "--- /etc/cron.d/zomboid ---"; grep idle-shutdown /etc/cron.d/zomboid || echo "$(NO_IDLE_LINE)"; \
	            echo "--- /var/log/zomboid/idle.log ---"; \
	            tail -n $${N:-20} /var/log/zomboid/idle.log 2>/dev/null || echo "$(NO_LOG)"'
