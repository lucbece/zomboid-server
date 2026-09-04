#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034  # las claves llevan puntos y shellcheck lee MSG[a.b]
# como aritmetica; el array MSG lo declara y lo lee scripts/lib/i18n.sh, que hace source
# de este archivo.
# Catalogo de mensajes en castellano. Lo carga scripts/lib/i18n.sh; no es ejecutable.
#
# Tiene que definir exactamente las mismas claves que scripts/lib/i18n/en.sh:
# scripts/i18n-check.sh falla si no. Los placeholders son de printf (%s, %d); un signo de
# porcentaje literal se escribe %%.

# --- ui.sh ------------------------------------------------------------------------------------
MSG[ui.label.ok]="OK     "
MSG[ui.label.warn]="AVISO  "
MSG[ui.label.miss]="FALTA  "
MSG[ui.error]="Error:"
MSG[ui.confirm.yes]="[S/n]"
MSG[ui.confirm.no]="[s/N]"

# --- lib/oci-instance.sh ------------------------------------------------------------------------
MSG[oci.ocid.fail]="oci-instance: ERROR: no se pudo obtener el OCID.
  Probar: cd infra/terraform/envs/prod && tofu output -raw instance_ocid
  O exportar INSTANCE_OCID=ocid1.instance.oc1...."
MSG[oci.cli.missing]="oci-instance: ERROR: falta el CLI 'oci'. Instalarlo en un venv (ver docs/runbook.md)."

# --- lib/notificar.sh ---------------------------------------------------------------------------
MSG[notif.json.fail]="ADVERTENCIA: no se pudo armar el JSON del webhook (falta jq y python3?)"
MSG[notif.post.fail]="ADVERTENCIA: el POST al webhook de Discord fallo"

# --- setup.sh -----------------------------------------------------------------------------------
MSG[setup.help]="Asistente de configuracion del servidor de Project Zomboid.

  ./setup.sh                 # modo normal: te va preguntando y te explica cada cosa
  ./setup.sh --no-preguntar  # no pregunta nada: usa los valores de las variables ZS_*
  ./setup.sh --ayuda

Que hace: revisa que estén las herramientas, te ayuda a conectar tu cuenta de Oracle Cloud,
inventa las contraseñas por vos y escribe los dos archivos de configuración que necesita el
deploy:

  infra/terraform/envs/prod/terraform.tfvars   (lo lee OpenTofu para crear la máquina)
  .env                                          (config del server; el de la nube lo genera
                                                 cloud-init a partir del tfvars)

Se puede volver a correr las veces que haga falta: te muestra lo que ya elegiste como
respuesta por defecto y solo cambia lo que cambies.

Modo --no-preguntar (lo usan las pruebas y el CI). Variables aceptadas:
  ZS_LANG
  ZS_PUBLIC_NAME  ZS_MAX_PLAYERS  ZS_OCPUS  ZS_MEMORY_GB  ZS_ALERT_EMAIL  ZS_BUDGET_USD
  ZS_REGION
  ZS_TENANCY_OCID  ZS_ADMIN_CIDR  ZS_SSH_PUBLIC_KEY  ZS_REPO_URL  ZS_BUCKET_NAME
  ZS_ADMIN_PASSWORD  ZS_RCON_PASSWORD  ZS_SERVER_PASSWORD
  ZS_SKIP_OCI=1     no valida ~/.oci/config ni el CLI oci"
MSG[setup.unknown_option]="opción desconocida: %s (probá ./setup.sh --ayuda)"
MSG[setup.pause.default]="Cuando termines apretá Enter para seguir"
MSG[setup.pause.start]="Enter para empezar."
MSG[setup.welcome]="
  ============================================================
   Servidor de Project Zomboid: asistente de configuración
  ============================================================

  Esto NO crea nada en la nube todavía y NO gasta plata. Solo prepara los archivos de
  configuración. Después, cuando quieras, corrés  make deploy  y ahí sí se crea el servidor.

  Vas a necesitar:
    - una cuenta de Oracle Cloud ya creada y con tarjeta cargada (el README explica cómo)
    - un mail donde recibir los avisos de gasto
    - unos 5 minutos

  Si algo no lo entendés, apretá Enter para aceptar el valor entre corchetes: son valores
  razonables para empezar."
MSG[setup.tools.title]="1. Herramientas en esta computadora"
MSG[setup.tools.install_hint]="Instalalo con:  sudo apt install %s   (o el gestor de paquetes de tu sistema)"
MSG[setup.bash.old]="bash %s: hace falta bash 4 o más nuevo"
MSG[setup.bash.macos]="En macOS:  brew install bash  y volvé a correr ./setup.sh con el bash nuevo"
MSG[setup.tools.missing]="instalá lo que falta y volvé a correr ./setup.sh"
MSG[setup.tofu.unzip]="hace falta 'unzip':  sudo apt install unzip"
MSG[setup.tofu.downloading]="  Bajando OpenTofu %s..."
MSG[setup.tofu.ok]="OpenTofu %s"
MSG[setup.tofu.missing]="OpenTofu: es el programa que crea la máquina en la nube"
MSG[setup.tofu.confirm]="Lo instalo en ~/.local/bin (no hace falta sudo)?"
MSG[setup.tofu.installed]="OpenTofu instalado en ~/.local/bin/tofu"
MSG[setup.tofu.install_failed]="no se pudo instalar OpenTofu. Instrucciones manuales: docs/runbook.md §1.5"
MSG[setup.tofu.manual]="Instrucciones manuales: docs/runbook.md §1.5"
MSG[setup.tofu.required]="sin OpenTofu no se puede desplegar"
MSG[setup.ssh.from_env]="clave SSH tomada de ZS_SSH_PUBLIC_KEY"
MSG[setup.ssh.found]="clave SSH: %s"
MSG[setup.ssh.missing]="no tenés una clave SSH (es lo que te deja entrar a la máquina de la nube)"
MSG[setup.ssh.confirm]="La creo ahora? (no te va a pedir contraseña)"
MSG[setup.ssh.created]="clave creada en %s"
MSG[setup.ssh.required]="hace falta una clave SSH. Creala con:  ssh-keygen -t ed25519"
MSG[setup.ssh.bad_format]="la clave pública SSH no tiene la forma esperada (tiene que empezar con ssh-ed25519)"
MSG[setup.gh.ok]="GitHub CLI conectado (se usa solo si tu repo es privado)"
MSG[setup.gh.missing]="GitHub CLI (gh) no está o no está conectado: no pasa nada, es opcional"
MSG[setup.oci.title]="2. Cuenta de Oracle Cloud"
MSG[setup.oci.python]="hace falta python3"
MSG[setup.oci.skipped]="ZS_SKIP_OCI=1: me salteo la verificación de la cuenta de Oracle Cloud"
MSG[setup.oci.apikey]="
  Falta conectar tu cuenta de Oracle Cloud con esta computadora. Es un archivo con una clave
  que Oracle te genera. Hacelo así (5 minutos):

   1. Entrá a https://cloud.oracle.com e iniciá sesión.
   2. Arriba a la derecha, ícono de la persona -> \"My profile\".
   3. En el menú de la izquierda, \"API keys\" -> botón \"Add API key\".
   4. Dejá marcado \"Generate API key pair\" y apretá \"Download private key\".
      Se te baja un archivo .pem: guardalo, es tu llave.
   5. Apretá \"Add\". Oracle te muestra un cuadro de texto con varias líneas
      (user=..., fingerprint=..., tenancy=..., region=...). Copialo entero.
   6. En esta computadora, ejecutá en otra terminal:

        mkdir -p ~/.oci && chmod 700 ~/.oci
        mv ~/Descargas/*.pem ~/.oci/oci_api_key.pem     (o ~/Downloads)
        chmod 600 ~/.oci/oci_api_key.pem
        nano ~/.oci/config

      Pegá el cuadro que copiaste y agregá al final la línea:

        key_file=/home/TU_USUARIO/.oci/oci_api_key.pem

      Guardá con Ctrl+O, Enter, Ctrl+X. Después:

        chmod 600 ~/.oci/config"
MSG[setup.oci.pause]="Cuando lo tengas listo, apretá Enter."
MSG[setup.oci.config_ok]="archivo de la cuenta: %s"
MSG[setup.oci.key_ok]="clave privada de la API: %s"
MSG[setup.oci.key_bad]="la línea key_file= de %s apunta a un archivo que no existe"
MSG[setup.oci.key_hint]="Corregila con la ruta completa del .pem que bajaste de Oracle."
MSG[setup.oci.config_missing]="sigue sin haber %s: podés seguir, pero 'make deploy' va a fallar"
MSG[setup.oci.cli_ok]="CLI oci instalado"
MSG[setup.oci.cli_missing]="el programa 'oci' no está (sirve para prender y apagar el server, y para chequeos)"
MSG[setup.oci.cli_confirm]="Lo instalo en ~/.venvs/oci (sin sudo)?"
MSG[setup.oci.cli_installed]="oci instalado (~/.local/bin/oci)"
MSG[setup.oci.cli_failed]="no se pudo instalar el CLI oci; seguimos sin él"
MSG[setup.oci.auth_ok]="la cuenta de Oracle Cloud responde: la clave está bien configurada"
MSG[setup.oci.auth_fail]="Oracle no acepta la clave todavía"
MSG[setup.oci.auth_hint1]="Revisá user=, fingerprint=, tenancy= y key_file= en %s."
MSG[setup.oci.auth_hint2]="Para ver el error completo:  oci iam region list"
MSG[setup.server.title]="3. Cómo querés tu server"
MSG[setup.q.lang]="Idioma / Language"
MSG[setup.q.public_name]="Nombre del server (lo ven tus amigos)"
MSG[setup.default.public_name]="Mi server de Zomboid"
MSG[setup.err.public_name]="el nombre no puede tener comillas dobles, barra invertida, signo pesos ni acento grave"
MSG[setup.q.max_players]="Cuántos jugadores como máximo"
MSG[setup.err.max_players]="la cantidad de jugadores tiene que ser un número"
MSG[setup.err.ocpus]="ZS_OCPUS tiene que ser un número entero de 1 o más"
MSG[setup.err.memory]="ZS_MEMORY_GB tiene que ser un número entero de 6 o más (el heap de la JVM son memory_gb - 4)"
MSG[setup.q.alert_email]="Mail donde recibir los avisos de gasto de Oracle"
MSG[setup.err.alert_email]="hace falta un mail válido para las alertas de gasto"
MSG[setup.q.budget]="Aviso de gasto cuando el mes pase de (USD)"
MSG[setup.err.budget]="el presupuesto tiene que ser un número entero"
MSG[setup.region.saopaulo]="São Paulo, Brasil        | ~30 ms desde Argentina  (recomendada acá)"
MSG[setup.region.vinhedo]="Vinhedo, Brasil          | ~30 ms desde Argentina"
MSG[setup.region.santiago]="Santiago, Chile          | ~25-35 ms desde Argentina"
MSG[setup.region.ashburn]="Ashburn, EEUU (costa E)  | ~140 ms desde Argentina, ~20 ms desde EEUU este"
MSG[setup.region.phoenix]="Phoenix, EEUU (oeste)    | ~180 ms desde Argentina, ~20 ms desde EEUU oeste"
MSG[setup.region.frankfurt]="Frankfurt, Alemania      | ~230 ms desde Argentina, ~20 ms desde Europa"
MSG[setup.region.madrid]="Madrid, España           | ~210 ms desde Argentina, ~20 ms desde España"
MSG[setup.region.london]="Londres, Reino Unido     | ~220 ms desde Argentina, ~15 ms desde UK"
MSG[setup.region.intro]="
  Región (dónde va a estar la máquina). Elegí la más cercana a donde viven los jugadores:"
MSG[setup.region.warning]="
  IMPORTANTE: tiene que ser la MISMA región que elegiste al crear la cuenta de Oracle
  (la \"home region\"). Si no coincide, el deploy falla. Si no te acordás, es la que
  aparece arriba a la derecha en la consola de Oracle."
MSG[setup.q.region]="Número de región, o escribí el código a mano"
MSG[setup.err.region]="el código de región no parece válido: %s"
MSG[setup.region.mismatch]="elegiste %s pero tu cuenta dice %s"
MSG[setup.region.mismatch_hint]="Si el deploy falla con 'NotAuthorizedOrNotFound', usá la de tu cuenta."
MSG[setup.q.tenancy]="ID de tu cuenta de Oracle (la línea 'tenancy=' de ~/.oci/config)"
MSG[setup.err.tenancy]="el ID de la cuenta tiene que empezar con ocid1.tenancy. Sacalo de %s"
MSG[setup.err.no_ip]="no pude averiguar tu IP pública. Ponela a mano: curl https://ifconfig.me"
MSG[setup.admin_cidr.intro]="
  Tu IP de internet es la única desde la que vas a poder administrar el server.
  (Tus amigos entran igual desde cualquier lado: esto es solo para administrar.)
  Si tu conexión cambia de IP, más adelante corrés ./setup.sh y make deploy de nuevo."
MSG[setup.q.admin_cidr]="Tu IP de admin"
MSG[setup.err.admin_cidr]="la IP de admin tiene que tener la forma 1.2.3.4/32"
MSG[setup.repo.title]="4. De dónde baja la configuración la máquina"
MSG[setup.repo.public]="tu repo es público: la máquina lo baja sola, no hay nada más que hacer"
MSG[setup.repo.private]="tu repo es privado (o no existe todavía)"
MSG[setup.repo.private_hint1]="Voy a usar %s y una llave de solo lectura que se carga en GitHub."
MSG[setup.repo.private_hint2]="Si preferís evitar ese paso, hacé el repo público en GitHub -> Settings -> General."
MSG[setup.repo.ssh]="tu repo se clona por SSH: se va a usar una llave de solo lectura"
MSG[setup.repo.key_no]="no"
MSG[setup.repo.key_yes]="sí"
MSG[setup.repo.summary]="  Repo: %s   (llave de solo lectura: %s)"
MSG[setup.pass.title]="5. Contraseñas"
MSG[setup.pass.intro]="  Se generan tres contraseñas distintas. No hace falta que las memorices: quedan guardadas
  en los archivos de configuración y 'make deploy' te va a mostrar la que le tenés que pasar
  a tus amigos.

    - del server: la que ponen tus amigos para entrar
    - de admin:   tu usuario administrador dentro del juego
    - de RCON:    la usa el programa para hablar con el server, no la escribe nadie"
MSG[setup.pass.label.server]="del server"
MSG[setup.pass.label.admin]="de admin"
MSG[setup.pass.label.rcon]="de RCON"
MSG[setup.q.password]="Contraseña %s (Enter acepta la sugerida)"
MSG[setup.err.password]="la contraseña %s tiene que tener entre 8 y 64 caracteres, sin espacios, comillas, barra invertida ni signo pesos"
MSG[setup.write.title]="6. Guardando la configuración"
MSG[setup.mods.count]="config/mods.txt (%s mods del Workshop)"
MSG[setup.mods.vanilla]="config/mods.txt (sin mods activos: partida vanilla)"
MSG[setup.mods.created]="config/mods.txt creado (partida vanilla, sin mods)"
MSG[setup.mods.hint1]="Para agregar mods editá config/mods.txt: una línea por item del Workshop, el formato"
MSG[setup.mods.hint2]="está explicado adentro del archivo y en docs/mods.md. Se aplican con make deploy o make restart."
MSG[setup.sandbox.created]="config/servertest_SandboxVars.lua creado (reglas vanilla del juego)"
MSG[setup.sandbox.hint1]="Para cambiar las reglas editá ese archivo (cada valor está explicado adentro) o usá la"
MSG[setup.sandbox.hint2]="encuesta (docs/survey.md). Varias reglas quedan fijas al crear el mundo: decidilas antes de la primera partida."
MSG[setup.summary.mods_some]="%s (config/mods.txt)"
MSG[setup.summary.mods_none]="ninguno, partida vanilla (config/mods.txt)"
MSG[setup.summary]="
  ============================================================
   Listo. Así te quedó configurado:
  ============================================================

    Nombre del server ...... %s
    Jugadores máximo ....... %s
    Máquina ................ %s OCPU / %s GB (heap de la JVM: %s)
    Región ................. %s
    Avisos de gasto ........ %s (a partir de %s USD/mes)
    Administración desde ... %s
    Contraseña del server .. %s
    Mods ................... %s

  Ahora:

    make doctor     revisa que esté todo listo (opcional, 10 segundos)
    make deploy     crea el servidor en la nube (tarda 20-40 minutos la primera vez)

  A partir de acá SÍ se empieza a gastar plata: alrededor de 90 USD/mes si dejás la máquina
  prendida todo el tiempo. Para dejar de pagar:  make destroy-all"

# --- scripts/doctor.sh ----------------------------------------------------------------------------
MSG[doctor.help]="Revisa que esté todo listo para desplegar y operar el server, y explica en una línea qué
hacer con cada cosa que falta.

  make doctor            # revisión completa
  scripts/doctor.sh -q   # solo lo que está mal (lo usa scripts/deploy.sh antes de arrancar)

Códigos de salida:
  0  todo lo bloqueante está en orden (puede haber AVISOs)
  1  falta algo sin lo cual \`make deploy\` no puede funcionar"
MSG[doctor.unknown_option]="opción desconocida: %s"
MSG[doctor.header]="
  ============================================================
   Revisión del server de Project Zomboid
  ============================================================"
MSG[doctor.title.1]="1. Programas necesarios"
MSG[doctor.bash.old]="bash %s es muy viejo (hace falta 4 o más)"
MSG[doctor.bash.macos]="En macOS:  brew install bash"
MSG[doctor.cmd.missing]="falta %s"
MSG[doctor.cmd.hint]="Instalalo con:  sudo apt install %s"
MSG[doctor.tofu.ok]="OpenTofu %s"
MSG[doctor.tofu.missing]="falta OpenTofu (es el programa que crea la máquina en la nube)"
MSG[doctor.tofu.hint]="Corré ./setup.sh: te lo instala solo en ~/.local/bin"
MSG[doctor.ssh.ok]="clave SSH: %s"
MSG[doctor.ssh.missing]="no tenés clave SSH (es lo que te deja entrar a la máquina)"
MSG[doctor.ssh.hint]="Creala con:  ssh-keygen -t ed25519"
MSG[doctor.gh.ok]="GitHub CLI conectado (opcional: sirve para cargar la llave del repo privado)"
MSG[doctor.gh.missing]="GitHub CLI (gh) no está o no está conectado: es opcional"
MSG[doctor.gh.hint]="Solo hace falta si tu repo es privado. Se puede hacer a mano desde la web."
MSG[doctor.title.2]="2. Cuenta de Oracle Cloud"
MSG[doctor.oci.profile_ok]="%s con perfil [DEFAULT]"
MSG[doctor.oci.profile_missing]="%s no tiene un perfil [DEFAULT]"
MSG[doctor.oci.profile_hint]="La primera línea del archivo tiene que ser exactamente:  [DEFAULT]"
MSG[doctor.oci.key_ok]="clave privada de la API: %s"
MSG[doctor.oci.key_missing]="la línea key_file= de %s no apunta a un archivo que exista"
MSG[doctor.oci.key_hint]="Poné la ruta completa del .pem que bajaste de Oracle, por ejemplo %s"
MSG[doctor.oci.config_missing]="no existe %s: la computadora no está conectada a tu cuenta de Oracle"
MSG[doctor.oci.config_hint]="Corré ./setup.sh: te guía paso a paso para crear la API key."
MSG[doctor.oci.cli_ok]="programa 'oci' instalado"
MSG[doctor.oci.auth_ok]="Oracle acepta tu clave: la cuenta responde"
MSG[doctor.oci.auth_fail]="Oracle no acepta tu clave todavía"
MSG[doctor.oci.auth_hint1]="Para ver el error completo:  oci iam region-subscription list"
MSG[doctor.oci.auth_hint2]="Revisá user=, fingerprint=, tenancy= y key_file= en %s."
MSG[doctor.oci.cli_missing]="el programa 'oci' no está instalado"
MSG[doctor.oci.cli_hint1]="No es imprescindible para desplegar, pero sirve para prender/apagar el server."
MSG[doctor.oci.cli_hint2]="Corré ./setup.sh y aceptá instalarlo (queda en ~/.venvs/oci, sin sudo)."
MSG[doctor.title.3]="3. Configuración de tu server"
MSG[doctor.tfvars.placeholder]="terraform.tfvars todavía tiene valores de ejemplo (dice CAMBIAME)"
MSG[doctor.tfvars.placeholder_hint]="Corré ./setup.sh para completarlo."
MSG[doctor.tfvars.key_missing]="falta %s en terraform.tfvars"
MSG[doctor.setup_hint]="Corré ./setup.sh."
MSG[doctor.tfvars.perms]="terraform.tfvars tiene permisos %s: tiene contraseñas adentro"
MSG[doctor.tfvars.perms_hint]="Arreglalo con:  chmod 600 %s"
MSG[doctor.tfvars.missing]="no existe terraform.tfvars: el server no está configurado"
MSG[doctor.env.missing]="no existe .env"
MSG[doctor.env.hint]="Solo hace falta para correr el server en esta computadora. Lo crea ./setup.sh."
MSG[doctor.mods.count]="config/mods.txt: %s mods del Workshop"
MSG[doctor.mods.vanilla]="config/mods.txt: sin mods activos (partida vanilla)"
MSG[doctor.mods.vanilla_hint]="Para agregar mods, editá config/mods.txt (el formato está adentro y en docs/mods.md)."
MSG[doctor.mods.missing]="no existe config/mods.txt: la partida va a ser vanilla (sin mods)"
MSG[doctor.mods.missing_hint]="Lo crea ./setup.sh, o:  cp config/mods.example.txt config/mods.txt"
MSG[doctor.sandbox.missing]="no existe config/servertest_SandboxVars.lua: reglas vanilla del juego"
MSG[doctor.sandbox.hint]="Lo crea ./setup.sh, o:  cp config/servertest_SandboxVars.example.lua config/servertest_SandboxVars.lua"
MSG[doctor.repo.public]="el repo %s es público: la máquina lo va a poder bajar"
MSG[doctor.repo.private]="el repo %s no se puede bajar sin contraseña"
MSG[doctor.repo.private_hint1]="Hacelo público en GitHub -> Settings -> General -> Change visibility,"
MSG[doctor.repo.private_hint2]="o volvé a correr ./setup.sh para usar una llave de solo lectura."
MSG[doctor.repo.ssh]="el repo %s se baja por SSH con una llave de solo lectura"
MSG[doctor.repo.key_ok]="el repo ya tiene una llave de solo lectura cargada en GitHub"
MSG[doctor.repo.key_missing]="el repo todavía no tiene ninguna llave cargada en GitHub"
MSG[doctor.repo.key_hint]="'make deploy' la va a cargar por vos."
MSG[doctor.repo.unreadable]="no pude leer repo_url de terraform.tfvars"
MSG[doctor.title.4]="4. Server en la nube"
MSG[doctor.cloud.none]="todavía no desplegaste nada (no hay nada creado ni nada que se esté cobrando)"
MSG[doctor.cloud.none_hint]="Cuando quieras crearlo:  make deploy"
MSG[doctor.cloud.ip]="IP del server: %s"
MSG[doctor.cloud.ip_unknown]="desconocida"
MSG[doctor.cloud.running]="la máquina está PRENDIDA (y se está cobrando)"
MSG[doctor.cloud.running_hint]="Para ver si el juego responde:  make remote-status"
MSG[doctor.cloud.stopped]="la máquina está APAGADA (no se cobra cómputo, solo el disco)"
MSG[doctor.cloud.stopped_hint]="Para prenderla:  ./scripts/cloud-start.sh"
MSG[doctor.cloud.state_unknown]="no pude consultar el estado de la máquina"
MSG[doctor.cloud.state_hint]="Probá:  oci compute instance get --instance-id %s"
MSG[doctor.cloud.state_other]="estado de la máquina: %s"
MSG[doctor.backup.last]="último backup guardado: %s"
MSG[doctor.backup.none]="todavía no hay ningún backup en la nube (bucket %s)"
MSG[doctor.backup.none_hint]="El backup automático corre todos los días. Para forzar uno:  make remote-backup"
MSG[doctor.cloud.no_oci]="no puedo consultar el estado de la máquina sin el programa 'oci' configurado"
MSG[doctor.final.ok]="
  ------------------------------------------------------------
   Está todo listo. El siguiente paso es:   make deploy
  ------------------------------------------------------------"
MSG[doctor.final.problems]="
  ------------------------------------------------------------
   Hay %s cosa(s) marcada(s) como FALTA más arriba.
   Arreglalas (casi siempre alcanza con correr ./setup.sh) y volvé a probar con: make doctor
  ------------------------------------------------------------"

# --- scripts/deploy.sh ------------------------------------------------------------------------------
MSG[deploy.help]="Crea (o actualiza) el servidor en la nube, de punta a punta.

  make deploy              # lo normal: muestra qué va a hacer y pide confirmación una vez
  make deploy YES=1        # sin confirmación
  scripts/deploy.sh --dry-run   # solo muestra los pasos, no toca nada ni gasta plata

Los pasos son:
  1. revisión previa (scripts/doctor.sh)
  2. tofu init                       (baja los plugins de Oracle Cloud)
  3. si el repo es privado: crear la llave de solo lectura y cargarla en GitHub
  4. tofu apply                      (acá se crea la máquina: empieza a cobrarse)
  5. esperar a que la máquina acepte conexiones           (hasta 10 minutos)
  6. esperar a que el juego termine de instalarse y arranque (hasta 30 minutos)
  7. mostrar lo que hay que pasarle a los amigos

Es idempotente: si ya está todo desplegado, no cambia nada y vuelve a mostrar los datos."
MSG[deploy.unknown_option]="opción desconocida: %s"
MSG[deploy.simulated]="          (simulado) %s"
MSG[deploy.step1]="Paso 1 de 7: revisando que esté todo en orden"
MSG[deploy.ok]="todo en orden"
MSG[deploy.dryrun_warn]="falta algo, pero como es una simulación sigo igual para mostrarte los pasos"
MSG[deploy.blocked]="
  No puedo seguir hasta que se resuelva lo de arriba.
  En la mayoría de los casos alcanza con correr:  ./setup.sh"
MSG[deploy.no_tfvars]="falta %s. Corré ./setup.sh"
MSG[deploy.step2]="Paso 2 de 7: preparando las herramientas (se bajan una sola vez)"
MSG[deploy.step3.public]="Paso 3 de 7: tu repo es público, la máquina lo baja sola (nada que hacer)"
MSG[deploy.step3.private]="Paso 3 de 7: llave de solo lectura para que la máquina baje tu repo privado"
MSG[deploy.key.loaded]="la llave ya estaba cargada en GitHub"
MSG[deploy.key.simulated]="gh repo deploy-key add ... -R %s --title zomboid-vm"
MSG[deploy.key.added]="llave cargada en GitHub automáticamente"
MSG[deploy.key.manual]="
  Hay que darle permiso a la máquina para bajar tu repo privado. Es un copy/paste:

   1. Copiá esta línea entera (es una llave que solo sirve para LEER tu repo):

%s

   2. Entrá a tu repo en GitHub -> Settings -> Deploy keys -> \"Add deploy key\".
   3. Title: zomboid-vm       Key: pegá la línea de arriba.
   4. NO marques \"Allow write access\".
   5. Apretá \"Add key\"."
MSG[deploy.key.prompt]="  Cuando la hayas cargado, apretá Enter para seguir: "
MSG[deploy.step4]="Paso 4 de 7: creando el servidor en Oracle Cloud"
MSG[deploy.money]="
  Arriba está la lista de lo que se va a crear en Oracle Cloud.
  A partir de acá SE EMPIEZA A COBRAR: alrededor de 90 USD por mes con la máquina prendida
  todo el tiempo. Para dejar de pagar en cualquier momento:  make destroy-all"
MSG[deploy.confirm]="¿Creo el servidor?"
MSG[deploy.cancelled]="  Cancelado. No se creó nada."
MSG[deploy.ip_fail]="el servidor se creó pero no pude leer su IP. Probá: %s -chdir=%s output"
MSG[deploy.ip]="IP del servidor: %s"
MSG[deploy.step5]="Paso 5 de 7: esperando a que la máquina prenda (hasta 10 minutos)"
MSG[deploy.ssh.simulated]="ssh %s@%s true  en un bucle hasta que responda"
MSG[deploy.ssh_ok]="la máquina responde"
MSG[deploy.waiting]="esperando"
MSG[deploy.ssh_timeout]="
  La máquina no respondió en 10 minutos. Cosas para revisar:
    - ¿Cambió tu IP de internet? Corré ./setup.sh de nuevo y después make deploy.
    - En la consola de Oracle, ¿la instancia figura como RUNNING?
    - Más ayuda: docs/runbook.md, sección \"No entra por SSH\"."
MSG[deploy.step6]="Paso 6 de 7: instalando y arrancando el juego (hasta 30 minutos la primera vez)"
MSG[deploy.patience]="          Esto tarda porque la máquina baja el juego entero (unos 10 GB) y lo instala.
          Podés dejarlo corriendo e ir a hacer otra cosa. Si cortás con Ctrl+C no rompés
          nada: el servidor sigue instalándose solo y podés volver con  make deploy."
MSG[deploy.logs.simulated]="ssh %s@%s 'cd /opt/zomboid-server && docker compose logs zomboid'"
MSG[deploy.logs.simulated2]="hasta ver '*** SERVER STARTED ****' o cortar a los 30 minutos"
MSG[deploy.phase.preparing]="preparando la máquina y bajando el juego"
MSG[deploy.phase.starting]="arrancando el juego"
MSG[deploy.phase.default]="preparando la máquina"
MSG[deploy.cloudinit_error]="
  La preparación de la máquina falló. Para ver por qué:

    ssh USUARIO@IP 'sudo tail -50 /var/log/cloud-init-output.log'

  El caso más común es que la llave de solo lectura del repo no esté cargada en GitHub.
  Más ayuda: docs/runbook.md, \"El server no arranca después de un tofu apply\"."
MSG[deploy.slow]="
  Pasaron 30 minutos y el juego todavía no terminó de arrancar. No necesariamente está roto:
  con una conexión lenta el primer arranque puede tardar más. Para mirar en vivo qué hace:

    make remote-logs

  Volvé a correr  make deploy  cuando quieras y retoma desde acá."
MSG[deploy.game_up]="el juego está arriba"
MSG[deploy.step7]="Paso 7 de 7: listo"
MSG[deploy.final]="
  ============================================================
   PASALE ESTO A TUS AMIGOS
  ============================================================

   En Project Zomboid: Join -> pestaña Favorites -> Add server

     Nombre .................. %s
     IP ...................... %s
     Puerto .................. %s
     Contraseña del server ... %s

     El \"Account username\" y \"Account password\" los elige cada uno: son suyos y se crean
     solos la primera vez que entran.

  ============================================================
   TUS 5 COMANDOS
  ============================================================

     make remote-status      ¿está arriba? ¿quién está jugando?
     make remote-logs        ver qué está pasando (Ctrl+C para salir)
     make remote-restart     reiniciar (aplica cambios de mods o de reglas)
     make remote-backup      guardar una copia de la partida ahora mismo
     make destroy-all        borrar todo y dejar de pagar

   Para agregar mods: editá config/mods.txt (formato adentro del archivo) y corré  make sync RESTART=1
   Manual completo: README.md      Referencia avanzada: docs/runbook.md"

# --- scripts/destroy-all.sh -------------------------------------------------------------------------
MSG[destroy.help]="Borra el servidor de la nube para dejar de pagar.

  make destroy-all          # pide escribir el nombre del server para confirmar
  scripts/destroy-all.sh --dry-run

Antes de borrar intenta guardar una última copia de la partida en la nube, así podés volver
a levantar todo más adelante con \`make deploy\` + \`scripts/restore.sh\`."
MSG[destroy.unknown_option]="opción desconocida: %s"
MSG[destroy.default_name]="Mi server de Zomboid"
MSG[destroy.simulated]="          (simulado) %s"
MSG[destroy.nothing]="
  No encuentro ningún servidor creado desde esta computadora (no hay estado de OpenTofu).

  Si ya lo borraste, no hay nada que hacer y no se te está cobrando nada por la máquina.
  Si lo creaste desde OTRA computadora, tenés que borrarlo desde esa, o a mano en la consola
  de Oracle Cloud: menú -> Compute -> Instances -> los tres puntos -> Terminate."
MSG[destroy.confirm_block]="
  ============================================================
   BORRAR TODO
  ============================================================

  Se borra, sin vuelta atrás:

    - la máquina del servidor (%s)
    - su disco, con la partida que tenga adentro
    - la red y la IP fija (tus amigos van a tener que cargar la IP nueva si volvés a crearlo)

  NO se borra:

    - las copias de seguridad guardadas en la nube (bucket \"%s\")
      Se siguen cobrando, pero son centavos: unos 0,03 USD por GB por mes.

  Antes de borrar voy a intentar guardar una última copia de la partida."
MSG[destroy.no_ip]="sin IP"
MSG[destroy.confirm_prompt]="  Escribí el nombre del server (%s) para confirmar: "
MSG[destroy.mismatch]="no coincide: no se borró nada"
MSG[destroy.step.backup]="Guardando una última copia de la partida"
MSG[destroy.backup.simulated]="ssh %s@%s 'cd /opt/zomboid-server && ./scripts/backup.sh final'"
MSG[destroy.backup_ok]="copia guardada en la nube con la etiqueta 'final'"
MSG[destroy.backup_fail]="la copia final falló"
MSG[destroy.confirm_anyway]="¿Borro igual?"
MSG[destroy.cancelled]="cancelado: no se borró nada"
MSG[destroy.vm_down]="la máquina no responde (puede estar apagada): no se pudo hacer la copia final"
MSG[destroy.step.destroy]="Borrando el servidor (tarda 2-5 minutos)"
MSG[destroy.final]="
  ============================================================
   Listo: el servidor ya no existe y dejaste de pagarlo
  ============================================================

  Lo único que puede seguir generando un costo mínimo son las copias de seguridad guardadas
  en Oracle Cloud, en el bucket \"%s\". Son unos centavos por mes y te
  sirven si algún día querés volver a levantar la partida:

     make deploy
     ssh USUARIO@IP_NUEVA 'cd /opt/zomboid-server && ./scripts/restore.sh oci:%s/ARCHIVO.tar.zst'

  Si querés borrar también las copias y no dejar nada:

     Desde la consola: menú -> Storage -> Buckets -> %s -> borrar los
     objetos y después el bucket. Después, menú -> Identity -> Compartments -> zomboid ->
     Delete (solo se puede si ya está vacío).

  Con el programa 'oci' instalado, lo mismo desde la terminal:

     oci os object bulk-delete --bucket-name %s --namespace %s
     oci os bucket delete --bucket-name %s --namespace %s

  Verificá que no quede nada facturándose en: Billing & Cost Management -> Cost Analysis
  (región %s)."

# --- scripts/render-config.sh -----------------------------------------------------------------------
MSG[render.need_envsubst]="falta envsubst (paquete gettext-base)"
MSG[render.no_env]="no existe %s. Copiar .env.example a .env y completarlo."
MSG[render.no_tpl]="no existe %s"
MSG[render.bad_workshop_id]="%s:%s: workshop id invalido '%s'"
MSG[render.missing_modid]="%s:%s: falta el mod_id para el workshop %s"
MSG[render.no_mods]="render-config: no existe config/mods.txt: partida vanilla (sin mods).
render-config:   para agregar mods:  cp config/mods.example.txt config/mods.txt  (ver docs/mods.md)"
MSG[render.vanilla_block]="render-config: ERROR: el server venia con mods y ahora no habria ninguno.
render-config:   Mods= actual: %s
render-config:   Si falta config/mods.txt, restauralo (en la VM lo trae 'make sync' desde tu PC).
render-config:   Para pasar a vanilla a proposito:  ALLOW_VANILLA=1 make restart"
MSG[render.no_tpl_vars]="el template no tiene ninguna variable, revisar %s"
MSG[render.missing_vars]="faltan variables en %s: %s"
MSG[render.empty_vars]="variables vacias en %s: %s"
MSG[render.placeholders]="quedaron placeholders sin resolver en el ini renderizado"
MSG[render.no_sandbox]="render-config: no existe config/servertest_SandboxVars.lua: reglas vanilla (config/servertest_SandboxVars.example.lua).
render-config:   para personalizarlas:  cp config/servertest_SandboxVars.example.lua config/servertest_SandboxVars.lua"
MSG[render.lua_copied]="render-config: lua copiados a %s/"

# --- scripts/wipe.sh --------------------------------------------------------------------------------
MSG[wipe.unknown_option]="opcion desconocida: %s"
MSG[wipe.warning]="
  WIPE de la partida.

  Se borra:   %s
              %s/db
              %s/backups (los backups nativos del server)

  Se conserva: un backup final etiquetado 'pre-wipe' en backups/ y en el bucket, y toda la
               config versionada de config/.

  Los personajes de todos los jugadores desaparecen. No se puede deshacer salvo con
  scripts/restore.sh sobre el backup 'pre-wipe'."
MSG[wipe.prompt]="Escribi 'wipe' para continuar: "
MSG[wipe.cancelled]="cancelado"
MSG[wipe.backup]="backup final etiquetado 'pre-wipe'"
MSG[wipe.backup_failed]="el backup pre-wipe fallo; no se borra nada"
MSG[wipe.no_data]="no hay %s: nada que respaldar"
MSG[wipe.deleting]="borrando %s"
MSG[wipe.done]="
wipe: listo. Antes de arrancar la partida definitiva:

  1. Editar config/servertest_SandboxVars.lua (varias opciones quedan fijadas al crear el mundo).
  2. Editar config/mods.txt (los mods definitivos; sin el archivo la partida es vanilla).
  3. Revisar config/servertest.ini.tpl (PVP, MaxPlayers, backups).
  4. Desde la PC: make sync (mods.txt no esta en git; en la VM solo llega por rsync).
  5. make up"

# --- scripts/backup.sh ------------------------------------------------------------------------------
MSG[backup.unknown_option]="opcion desconocida: %s"
MSG[backup.bad_label]="etiqueta invalida: '%s'"
MSG[backup.no_data]="no existe %s: no hay nada que respaldar"
MSG[backup.saving]="el server esta arriba: pidiendo un save antes de copiar"
MSG[backup.save_failed]="ADVERTENCIA: el save por RCON fallo; se copia igual (puede quedar inconsistente)"
MSG[backup.not_running]="el server no esta corriendo: se copia el estado en disco tal cual"
MSG[backup.skip_missing]="aviso: %s no existe todavia, se omite"
MSG[backup.no_targets]="no hay ninguno de Saves/Server/db en %s"
MSG[backup.creating]="creando %s"
MSG[backup.done]="listo: %s"
MSG[backup.uploading]="subiendo a %s:%s"
MSG[backup.uploaded]="subido"
MSG[backup.upload_failed]="ADVERTENCIA: rclone fallo. El backup local quedo en %s"
MSG[backup.local_only]="sin BACKUP_BUCKET en .env o sin rclone instalado: solo backup local"
MSG[backup.pruning]="borrando backups locales de mas de %s dias"

# --- scripts/restore.sh -----------------------------------------------------------------------------
MSG[restore.unknown_option]="opcion desconocida: %s"
MSG[restore.usage]="uso: %s [--yes] <archivo|remoto:bucket/nombre>"
MSG[restore.need_rclone]="hace falta rclone para bajar '%s'"
MSG[restore.downloading]="bajando %s"
MSG[restore.rclone_failed]="rclone no dejo %s"
MSG[restore.not_found]="no existe '%s' y no parece un remoto de rclone (falta 'remoto:')"
MSG[restore.bad_tar]="%s no es un tar valido o falta el compresor"
MSG[restore.warning]="
  Se va a RESTAURAR:  %s
  Sobre:              %s

  Esto apaga el server, borra el mundo actual (Saves/Multiplayer/servertest y db/) y lo
  reemplaza por el del backup. Antes se guarda un backup de seguridad etiquetado 'pre-restore'."
MSG[restore.prompt]="Escribi 'restore' para continuar: "
MSG[restore.cancelled]="cancelado"
MSG[restore.safety_backup]="backup de seguridad del estado actual"
MSG[restore.safety_failed]="ADVERTENCIA: el backup de seguridad fallo"
MSG[restore.removing]="borrando %s actual"
MSG[restore.extracting]="extrayendo"
MSG[restore.starting]="levantando el server"
MSG[restore.done]="listo. Seguir el arranque con 'make logs'."

# --- scripts/update.sh ------------------------------------------------------------------------------
MSG[update.backup]="backup antes de tocar nada"
MSG[update.backup_failed]="ADVERTENCIA: el backup fallo"
MSG[update.stopping]="apagado limpio"
MSG[update.pulling]="docker compose pull"
MSG[update.starting]="arrancando con la imagen nueva"
MSG[update.done]="listo. Verificar la version del juego con: make logs | grep -i version"

# --- scripts/stop.sh --------------------------------------------------------------------------------
MSG[stop.not_running]="el contenedor no esta corriendo, nada que hacer"
MSG[stop.disable_restart]="desactivando el auto-restart del contenedor"
MSG[stop.no_players]="no hay jugadores conectados, se omite el aviso"
MSG[stop.warning]="avisando a los jugadores (%ss)"
MSG[stop.save]="save"
MSG[stop.save_failed]="ADVERTENCIA: el save por RCON fallo"
MSG[stop.quit]="quit"
MSG[stop.rcon_down]="ADVERTENCIA: RCON no responde; se cae al SIGTERM del entrypoint (que tambien manda quit)"
MSG[stop.waiting]="esperando a que el contenedor termine de guardar (max %ss)"
MSG[stop.exited]="el contenedor salio despues de %ss"
MSG[stop.ok]="ok"
MSG[stop.still_alive]="ADVERTENCIA: sigue vivo despues de %ss, forzando 'docker compose stop'"
MSG[stop.forced]="ok (apagado forzado)"

# --- scripts/restart.sh -----------------------------------------------------------------------------
MSG[restart.done]="restart: server arrancando. Seguir con 'make logs'."

# --- scripts/rcon.sh --------------------------------------------------------------------------------
MSG[rcon.no_env]="no existe %s"
MSG[rcon.no_password]="falta RCONPASSWORD en .env"
MSG[rcon.no_mcrcon]="no se encontro mcrcon. Correr 'make mcrcon' para compilarlo en ./bin/mcrcon."
MSG[rcon.usage]="uso: %s <comando rcon> [comando...]"

# --- scripts/build-mcrcon.sh ------------------------------------------------------------------------
MSG[mcrcon.already_path]="build-mcrcon: ya hay un mcrcon en el PATH (%s), no hace falta compilar"
MSG[mcrcon.already_local]="build-mcrcon: %s ya existe"
MSG[mcrcon.need_gcc]="build-mcrcon: falta gcc (apt install build-essential)"
MSG[mcrcon.need_git]="build-mcrcon: falta git"
MSG[mcrcon.done]="build-mcrcon: %s listo"

# --- scripts/cloud-start.sh -------------------------------------------------------------------------
MSG[cloudstart.starting]="cloud-start: START sobre %s"
MSG[cloudstart.up_hint]="cloud-start: VM prendida. El server tarda ~1 min mas en levantar."
MSG[cloudstart.connect]="cloud-start: los amigos se conectan a %s:16261"
MSG[cloudstart.up]="cloud-start: VM prendida."

# --- scripts/cloud-stop.sh --------------------------------------------------------------------------
MSG[cloudstop.unknown_option]="cloud-stop: opcion desconocida: %s"
MSG[cloudstop.clean]="cloud-stop: apagado limpio del server en %s"
MSG[cloudstop.ssh_failed]="cloud-stop: ADVERTENCIA: el apagado por SSH fallo; el SOFTSTOP igual dispara el ExecStop del systemd"
MSG[cloudstop.no_ip]="cloud-stop: ADVERTENCIA: no se pudo resolver la IP; se va derecho al SOFTSTOP"
MSG[cloudstop.softstop]="cloud-stop: SOFTSTOP sobre %s"
MSG[cloudstop.done]="cloud-stop: VM detenida. OCI no cobra computo con la instancia en STOPPED."

# --- scripts/idle-shutdown.sh -----------------------------------------------------------------------
MSG[idle.not_running]="el server no esta corriendo, nada que hacer"
MSG[idle.rcon_down]="RCON no responde; se resetea el contador por las dudas"
MSG[idle.players]="hay jugadores conectados (%s), se resetea el contador"
MSG[idle.idle_for]="sin jugadores hace %ss (umbral %ss)"
MSG[idle.dryrun]="DRY_RUN: aca apagaria el server y la VM"
MSG[idle.stopping]="apagando el server"
MSG[idle.backup]="backup"
MSG[idle.backup_failed]="ADVERTENCIA: el backup fallo"
MSG[idle.vm_off]="apagando la VM"

# --- scripts/render-cloud-init.sh -------------------------------------------------------------------
MSG[cloudinit.unknown_mode]="modo desconocido '%s': usar 'https', 'ssh' o 'bot'"
MSG[cloudinit.no_out]="falta el archivo de salida. Uso: %s {https|ssh|bot} salida.yaml"
MSG[cloudinit.no_tofu]="falta 'tofu' en el PATH"
MSG[cloudinit.done]="render-cloud-init: modo '%s' -> %s"

# --- scripts/encuesta.sh ----------------------------------------------------------------------------
MSG[survey.usage]="uso: scripts/encuesta.sh <comando>

  up          sincroniza tools/ e infra/systemd/, instala la unit y arranca la encuesta
  down        para y deshabilita la encuesta (los votos quedan en la VM)
  estado      estado de la unit y cuantas personas votaron
  resultados  baja votos.jsonl y muestra el conteo (no toca config/)
  aplicar     el conteo + escribe los cambios en config/ y muestra el diff"
MSG[survey.no_ip]="no hay IP de la VM. Probar: scripts/encuesta.sh %s con VM_IP=203.0.113.10"
MSG[survey.step.sync]="Sincronizando el repo a la VM (%s)"
MSG[survey.step.install]="Instalando y arrancando la encuesta"
MSG[survey.up]="Encuesta arriba en http://%s:%s"
MSG[survey.up_hint1]="Pasales ese link a los amigos. Cierra sola cuando corras: make encuesta-down"
MSG[survey.up_hint2]="Si no abre desde afuera, falta el puerto en el NSG:"
MSG[survey.up_hint3]="  survey_port = %s en infra/terraform/envs/prod/terraform.tfvars + make infra-apply"
MSG[survey.step.down]="Parando la encuesta"
MSG[survey.down_ok]="Encuesta apagada. Los votos siguen en %s/votos.jsonl"
MSG[survey.down_hint]="Para contarlos: make encuesta-resultados"
MSG[survey.step.status]="Estado de la encuesta en %s"
MSG[survey.status.nores]="la encuesta no responde en el puerto %s"
MSG[survey.status.votes]="lineas en votos.jsonl:"
MSG[survey.status.novotes]="todavia no hay votos.jsonl"
MSG[survey.step.results]="Bajando los votos"
MSG[survey.results_fail]="no se pudo bajar %s/votos.jsonl (todavia no voto nadie?)"
MSG[survey.results_ok]="Votos en %s"
MSG[survey.no_votes]="no hay %s. Correr primero: make encuesta-resultados"
MSG[survey.unknown_cmd]="comando desconocido: %s"

# --- scripts/panel.sh -------------------------------------------------------------------------------
MSG[panel.usage]="uso: scripts/panel.sh <comando>

  up                      sincroniza el repo, instala la unit, abre el puerto y arranca el panel
  down                    para el panel y cierra el puerto en ufw (los tokens quedan en la VM)
  estado                  estado de la unit, /salud y moderadores cargados
  token add <nombre>      crea un token y imprime la URL completa para ese moderador
  token list              lista los moderadores (no imprime los tokens enteros)
  token revoke <nombre>   desactiva el token de un moderador
  log [N]                 ultimas N acciones registradas (default 20)"
MSG[panel.no_ip]="no hay IP de la VM. Probar: scripts/panel.sh %s con VM_IP=203.0.113.10"
MSG[panel.step.sync]="Sincronizando el repo a la VM (%s)"
MSG[panel.step.install]="Instalando y arrancando el panel"
MSG[panel.up]="Panel arriba en http://%s:%s"
MSG[panel.up_hint1]="Sin token no se ve nada: cada moderador necesita el suyo."
MSG[panel.up_hint2]="  make panel-token NAME=Fulano   -> imprime la URL para pasarle por privado"
MSG[panel.up_hint3]="Si no abre desde afuera, falta el puerto en el NSG:"
MSG[panel.up_hint4]="  panel_port = %s en infra/terraform/envs/prod/terraform.tfvars + make infra-apply"
MSG[panel.step.down]="Parando el panel"
MSG[panel.down_ok]="Panel apagado. Los tokens siguen en %s/moderadores.json"
MSG[panel.down_hint]="El puerto sigue abierto en el NSG hasta que pongas panel_port = 0 y apliques."
MSG[panel.step.status]="Estado del panel en %s"
MSG[panel.status.nores]="el panel no responde en el puerto %s"
MSG[panel.token.usage_add]="uso: scripts/panel.sh token add <nombre>"
MSG[panel.token.create_fail]="no se pudo crear el token"
MSG[panel.token.empty]="el token salio vacio"
MSG[panel.token.created]="Token creado para %s"
MSG[panel.token.hint1]="Pasaselo por mensaje privado. Ese link ES la credencial: quien lo tenga puede"
MSG[panel.token.hint2]="reiniciar el server. Para darlo de baja: make panel-revoke NAME=%s"
MSG[panel.token.usage_revoke]="uso: scripts/panel.sh token revoke <nombre>"
MSG[panel.token.revoked]="Token revocado. El panel lo toma solo, sin reiniciar el servicio."
MSG[panel.token.usage]="uso: scripts/panel.sh token add|list|revoke"
MSG[panel.log.title]="Ultimas %s acciones del panel"
MSG[panel.log.none]="(todavia no hay acciones registradas)"
MSG[panel.unknown_cmd]="comando desconocido: %s"

# --- scripts/watchdog.sh ----------------------------------------------------------------------------
MSG[watchdog.unit_not_installed]="la unit %s no esta instalada: se omite el chequeo"
MSG[watchdog.rcon_grace]="el contenedor arranco hace %ss (gracia %ss): no se chequea RCON"
MSG[watchdog.rcon_fail]="RCON no responde (%s/%s)"
MSG[watchdog.df_fail]="no se pudo leer df de %s"
MSG[watchdog.dryrun.restart]="DRY_RUN: aca correria WARN_SECONDS=0 scripts/restart.sh"
MSG[watchdog.dryrun.critical]="DRY_RUN: aca pararia el server, armaria el bundle y volveria a levantarlo"
MSG[watchdog.dryrun.disk]="DRY_RUN: aca borraria backups locales viejos, logs de mas de 7 dias y capas de Docker"
MSG[watchdog.dryrun.autorepair]="DRY_RUN: aca correria scripts/autorepair.sh"
MSG[watchdog.stopping]="parando el server"
MSG[watchdog.stop_failed]="ADVERTENCIA: stop.sh fallo, se cae a 'docker compose down'"
MSG[watchdog.diagnostic]="diagnostico en %s"
MSG[watchdog.starting]="arrancando"
MSG[watchdog.started]="el server arranco despues de %ss"
MSG[watchdog.disk_freed]="espacio libre: %s MB -> %s MB"
MSG[watchdog.escalated]="[ESCALADO] %s (repetida, no se notifica de nuevo): %s"
MSG[watchdog.autorepair_off]="CLAUDE_AUTOREPAIR no esta en 1: no se llama a autorepair.sh"
MSG[watchdog.autorepair_missing]="ADVERTENCIA: CLAUDE_AUTOREPAIR=1 pero no existe scripts/autorepair.sh"
MSG[watchdog.autorepair_call]="llamando a scripts/autorepair.sh (intento %s de hoy por '%s')"
MSG[watchdog.autorepair_rc]="autorepair.sh salio con codigo %s (ver %s)"
MSG[watchdog.lock_unwritable]="ADVERTENCIA: no se puede escribir el lock %s: se saltea esta pasada"
MSG[watchdog.lock_busy]="ya hay una operacion en curso (watchdog o mod-updater), se saltea esta"
MSG[watchdog.healthy]="sano: unit activa, contenedor arriba, RCON responde, log limpio"

# --- scripts/mod-updater.sh -------------------------------------------------------------------------
MSG[modupd.dryrun.notify]="DRY_RUN: aca notificaria [%s] %s -- %s"
MSG[modupd.dryrun.servermsg]="DRY_RUN: aca mandaria por RCON servermsg \"%s\""
MSG[modupd.servermsg_fail]="ADVERTENCIA: no se pudo mandar el servermsg"
MSG[modupd.dryrun.restart]="DRY_RUN: aca correria WARN_SECONDS=%s scripts/restart.sh (mods: %s)"
MSG[modupd.restarting]="reiniciando el server (WARN_SECONDS=%s) por: %s"
MSG[modupd.no_mods]="config/mods.txt no declara ningun mod: nada que chequear"
MSG[modupd.api_fail]="la API de Steam no respondio (curl fallo): no se hace nada en esta pasada"
MSG[modupd.compare_fail]="la respuesta de la API no sirve (comparar.py salio con %s): no se hace nada"
MSG[modupd.check.no_mods]="mod-updater: config/mods.txt no declara ningun mod"
MSG[modupd.check.api_fail]="mod-updater: la API de Steam no respondio"
MSG[modupd.lock_unwritable]="ADVERTENCIA: no se puede escribir el lock %s: se saltea esta pasada"
MSG[modupd.lock_busy]="hay otra operacion en curso (watchdog o mod-updater), se saltea esta pasada"
MSG[modupd.ops_busy]="hay un restart/stop/wipe/update/backup corriendo, se saltea esta pasada"
MSG[modupd.weird]="mods sin comparacion util: %s"
MSG[modupd.inconsistent]="estado inconsistente (fase esperando sin pendientes): se cierra el ciclo"
MSG[modupd.waiting_steamcmd]="esperando a que SteamCMD termine de bajar: %s"
MSG[modupd.closed_cycle]="los mods pendientes quedaron al dia sin que reiniciemos nosotros: se cierra el ciclo"
MSG[modupd.all_current]="todos los mods declarados estan al dia"
MSG[modupd.only_log]="sigue desactualizado %s y MOD_UPDATE_AUTO_RESTART=0: solo se registra"
MSG[modupd.rcon_down]="RCON no responde: se pospone el reinicio por mods (de eso se ocupa el watchdog)"
MSG[modupd.pending]="reinicio pendiente en %s minuto(s) por: %s"

# --- scripts/autorepair.sh --------------------------------------------------------------------------
MSG[autorepair.usage]="uso: scripts/autorepair.sh --bundle <dir> --motivo <texto> [--intentos <n>]

  --bundle    directorio del diagnostico que armo el watchdog (obligatorio)
  --motivo    que detecto el watchdog: crash-loop, patron-fatal, oom, rcon, disco
  --intentos  cuantas veces se escalo hoy por el mismo motivo (default 1)"
MSG[autorepair.unknown_option]="autorepair: opcion desconocida: %s"
MSG[autorepair.disabled]="CLAUDE_AUTOREPAIR no esta en 1 en .env: no se llama a Claude"
MSG[autorepair.bad_bundle]="autorepair: ERROR: --bundle tiene que apuntar a un directorio existente"
MSG[autorepair.no_quota]="sin cupo (%s/%s en la ultima hora, %s/%s hoy)"
MSG[autorepair.missing_file]="autorepair: falta %s"
MSG[autorepair.dryrun]="DRY_RUN: comando que se correria (el prompt va recortado)"
MSG[autorepair.running]="corriendo claude (timeout %s, max-turns %s)"
MSG[autorepair.exit]="claude salio con %s (is_error=%s, turnos=%s, costo USD %s)"
MSG[autorepair.no_text]="(sin texto: revisar autorepair.json y autorepair.err)"

# --- Makefile ---------------------------------------------------------------------------------------
MSG[make.dirs.done]="dirs: data/zomboid y data/workshop listos (%s:%s)"
MSG[make.up.started]="up: arrancando. Ver progreso con 'make logs'; el server esta arriba cuando aparece '*** SERVER STARTED ****'."
MSG[make.rcon.usage]="uso: make rcon CMD=players"
MSG[make.remote_rcon.usage]="uso: make remote-rcon CMD=players"
MSG[make.status.players]="--- jugadores ---"
MSG[make.status.rcon_down]="(RCON no responde: el server no esta arriba todavia)"
MSG[make.restore.usage]="uso: make restore FILE=backups/zomboid-YYYYmmdd-HHMM.tar.zst"
MSG[make.require_ip]="No hay VM_IP. Opciones:
  make remote-status VM_IP=203.0.113.10
  cd %s && tofu output -raw public_ip     (requiere el .tfstate local)"
MSG[make.require_bot_ip]="No hay BOT_IP. Opciones:
  make bot-status BOT_IP=203.0.113.10
  cd %s && tofu output -raw bot_public_ip   (requiere bot_enabled = true)"
MSG[make.remote_diff.note]="Si hay cambios, traerlos al repo a mano y commitearlos; la VM se re-clona en cada tofu apply."
MSG[make.watchdog.installed]="watchdog: instalado. Primer chequeo en menos de 2 minutos; verlo con 'make watchdog-status'."
MSG[make.watchdog.discord]="watchdog: para que avise por Discord, DISCORD_WEBHOOK_URL en el .env DE LA VM (ver docs/self-healing.md)."
MSG[make.modupd.installed]="mod-updater: instalado. Primer chequeo en menos de 5 minutos; verlo con 'make mod-updater-status'."
MSG[make.modupd.policy]="mod-updater: la politica de reinicio sale del .env DE LA VM (MOD_UPDATE_*, ver docs/mods.md)."
MSG[make.notifier.installed]="notifier: instalado. Con el server arriba publica el estado actual en menos de un minuto."
MSG[make.notifier.webhook]="notifier: necesita DISCORD_WEBHOOK_URL en el .env DE LA VM (ver docs/discord.md)."
MSG[make.sync.done]="sync: config y scripts actualizados en %s"
MSG[make.sync.note]="sync: NO se sincronizan .env, data/ ni bin/ (son propios de la VM)."
MSG[make.sync.hint]="sync: para aplicar los cambios: make remote-restart (o make sync RESTART=1)"
MSG[make.no_log]="(todavia no hay log)"
MSG[make.bot.installed]="bot: instalado. Los comandos /pz aparecen en Discord apenas se conecta ('make bot-status')."
MSG[make.panel_token.usage]="uso: make panel-token NAME=Fulano"
MSG[make.panel_revoke.usage]="uso: make panel-revoke NAME=Fulano"
MSG[make.idle.installed]="idle-shutdown: activado. Con 0 jugadores durante IDLE_MINUTES la VM se apaga sola."
MSG[make.idle.note]="idle-shutdown: solo tiene sentido con el bot andando, si no nadie la puede volver a prender."
MSG[make.idle.no_line]="(sin linea de idle-shutdown)"
