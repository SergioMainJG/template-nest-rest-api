#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DEST_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"
readonly SCRIPT_DIR PROJECT_DIR DEST_ROOT

usage() {
  cat <<'EOF'
Instala apps Quadlet (.kube + YAML + configs) en ~/.config/containers/systemd/<app>/

Uso:
  ./install.sh                   instala todas las apps (cada carpeta con <app>/<app>.kube)
  ./install.sh postgres caddy    instala solo esas
  ./install.sh app --start       instala la API; al arrancarla levanta postgres, dragonfly y caddy

Opciones:
  --force   sobrescribe archivos que ya existan en el destino
  --move    mueve en lugar de copiar (borra la carpeta de origen)
  --start   arranca o reinicia los servicios al terminar
EOF
}

force=false
move=false
start=false
apps=()

for arg in "$@"; do
  case "$arg" in
    --force) force=true ;;
    --move) move=true ;;
    --start) start=true ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "Opción desconocida: $arg" >&2
      exit 1
      ;;
    *) apps+=("$arg") ;;
  esac
done

if ! command -v podman >/dev/null 2>&1; then
  echo "✗ podman no está instalado." >&2
  exit 1
fi

if [[ ${#apps[@]} -eq 0 ]]; then
  for kube in "$SCRIPT_DIR"/*/*.kube; do
    apps+=("$(basename "$(dirname "$kube")")")
  done
fi

if [[ ${#apps[@]} -eq 0 ]]; then
  echo "✗ No se encontró ninguna carpeta <app>/<app>.kube junto al script." >&2
  exit 1
fi

copy_files() {
  local src="$1" dest="$2"
  local file rel target

  while IFS= read -r -d '' file; do
    rel="${file#"$src"/}"
    target="$dest/$rel"
    if [[ -e "$target" ]] && ! $force; then
      echo "  = $rel (ya existe, se conserva; usa --force para sobrescribir)"
      continue
    fi
    mkdir -p "$(dirname "$target")"
    cp "$file" "$target"
    echo "  + $rel"
  done < <(find "$src" -type f -print0)
}

set_permissions() {
  local dest="$1"

  find "$dest" -mindepth 1 -type d -exec chmod 755 {} +
  find "$dest" -type f -exec chmod 644 {} +
  find "$dest" -maxdepth 1 -name '*.yaml' -exec chmod 600 {} +
  chmod 700 "$dest"

  if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled; then
    find "$dest" -mindepth 1 ! -name '*.kube' ! -name '*.yaml' ! -name '*.build' \
      -exec chcon -t container_file_t {} +
  fi
}

check_unprivileged_ports() {
  local start_port
  start_port="$(cat /proc/sys/net/ipv4/ip_unprivileged_port_start 2>/dev/null || echo 1024)"
  if ((start_port > 80)); then
    echo "  ⚠ En rootless, Caddy no podrá usar los puertos 80/443 (ip_unprivileged_port_start=$start_port)."
    echo "    Solución permanente:"
    echo "      echo 'net.ipv4.ip_unprivileged_port_start=80' | sudo tee /etc/sysctl.d/99-unprivileged-ports.conf"
    echo "      sudo sysctl --system"
  fi
}

install_app() {
  local app="$1"
  local src="$SCRIPT_DIR/$app"
  local dest="$DEST_ROOT/$app"

  if [[ ! -f "$src/$app.kube" ]]; then
    echo "✗ $app: no existe $src/$app.kube" >&2
    return 1
  fi

  echo "→ $app → $dest"
  mkdir -p "$dest"
  copy_files "$src" "$dest"

  find "$dest" -maxdepth 1 \( -name '*.yaml' -o -name '*.build' \) \
    -exec sed -i -e "s|__APP_DIR__|$dest|g" -e "s|__PROJECT_DIR__|$PROJECT_DIR|g" {} +

  set_permissions "$dest"

  if grep -rq 'change-me' "$dest"; then
    echo "  ⚠ Quedan contraseñas 'change-me' en $dest: cámbialas antes de usarlo en serio."
  fi

  if [[ "$app" == "caddy" ]]; then
    check_unprivileged_ports
  fi

  if $move; then
    rm -rf "$src"
    echo "  − origen eliminado (--move)"
  fi
}

ordered_apps=()
has_app=false
for app in "${apps[@]}"; do
  if [[ "$app" == "app" ]]; then
    has_app=true
  else
    ordered_apps+=("$app")
  fi
done
if $has_app; then
  ordered_apps+=("app")
fi

for app in "${ordered_apps[@]}"; do
  install_app "$app"
done

systemctl --user daemon-reload

failed=false
for app in "${ordered_apps[@]}"; do
  if ! systemctl --user cat "$app.service" >/dev/null 2>&1; then
    echo "✗ Quadlet no generó $app.service. Revisa el error con:" >&2
    echo "    /usr/lib/systemd/system-generators/podman-system-generator --user --dryrun" >&2
    failed=true
    continue
  fi
  if $start; then
    systemctl --user restart "$app.service"
    echo "✓ $app.service iniciado"
  else
    echo "✓ $app.service listo → systemctl --user start $app.service"
  fi
done

if [[ "$(loginctl show-user "$USER" --property=Linger --value 2>/dev/null || true)" != "yes" ]]; then
  echo
  echo "⚠ Sin linger, los servicios solo corren mientras tengas una sesión abierta"
  echo "  y no arrancan al encender la máquina. Actívalo con:"
  echo "    loginctl enable-linger $USER"
fi

if $failed; then
  exit 1
fi
