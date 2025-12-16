#!/usr/bin/env bash
set -euo pipefail

### =========================================================
### Aide
### =========================================================
usage() {
cat <<'EOF'
Backrest + Restic installer / manager

USAGE:
  install-backrest.sh <command> [options]

COMMANDS:
  install       Installe et configure Backrest + Restic
  status        Affiche l'état de Backrest et des sauvegardes
  uninstall     Désinstalle Backrest (mode interactif)
  --help        Affiche cette aide

OPTIONS (install uniquement):
  --remote-type TYPE        cifs | webdav
  --remote-path PATH
  --remote-login LOGIN
  --remote-password PASS

EXEMPLES:
  ./install-backrest.sh install
  ./install-backrest.sh status
  ./install-backrest.sh uninstall
EOF
exit 0
}

[[ $# -eq 0 ]] && usage
[[ "$1" == "--help" || "$1" == "-h" ]] && usage

COMMAND="$1"
shift

### =========================================================
### Variables globales
### =========================================================
SERVICE="backrest"
INSTALL_DIR="/opt/backrest"
LOCAL_REPO="${HOME}/backup"
REMOTE_REPO="${HOME}/backup_remote"
SOURCE_DIR="${HOME}/user_data"

OVERRIDE_DIR="/etc/systemd/system/${SERVICE}.service.d"
CRED_DIR="/etc/systemd/credentials/${SERVICE}.service"
OVERRIDE_FILE="${OVERRIDE_DIR}/override.conf"

### =========================================================
### STATUS
### =========================================================
if [[ "$COMMAND" == "status" ]]; then
    echo "=== Service systemd ==="
    systemctl status backrest --no-pager || true

    echo
    echo "=== Ports ouverts ==="
    ss -lntp | grep backrest || echo "Backrest non actif"

    echo
    echo "=== Dépôts Backrest ==="
    backrest cli repo list 2>/dev/null || echo "Backrest non configuré"

    echo
    echo "=== Plans de sauvegarde ==="
    backrest cli backup list 2>/dev/null || echo "Aucun plan trouvé"

    exit 0
fi

### =========================================================
### UNINSTALL (interactif)
### =========================================================
if [[ "$COMMAND" == "uninstall" ]]; then
    echo "Désinstallation de Backrest"

    read -rp "Conserver les fichiers de configuration et dépôts Restic ? [y/N] " KEEP
    KEEP="${KEEP:-N}"

    echo "Arrêt du service"
    sudo systemctl stop backrest 2>/dev/null || true

    echo "Suppression du service"
    sudo systemctl disable backrest 2>/dev/null || true
    sudo rm -f /etc/systemd/system/backrest.service
    sudo rm -rf "$OVERRIDE_DIR"

    echo "Suppression de l'installation"
    sudo rm -rf "$INSTALL_DIR"

    if [[ "$KEEP" =~ ^[Yy]$ ]]; then
        echo "Conservation des données utilisateur"
    else
        echo "Suppression des données utilisateur"
        rm -rf "$LOCAL_REPO" "$REMOTE_REPO"
        rm -rf "$HOME/.config/backrest"
        sudo rm -rf "$CRED_DIR"
    fi

    sudo systemctl daemon-reload

    echo "Backrest désinstallé"
    exit 0
fi

### =========================================================
### INSTALL
### =========================================================
if [[ "$COMMAND" != "install" ]]; then
    echo "Commande inconnue : $COMMAND"
    usage
fi

### ----------------------------
### Parsing paramètres install
### ----------------------------
REMOTE_TYPE=""
REMOTE_PATH=""
REMOTE_LOGIN=""
REMOTE_PASSWORD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --remote-type) REMOTE_TYPE="$2"; shift 2 ;;
        --remote-path) REMOTE_PATH="$2"; shift 2 ;;
        --remote-login) REMOTE_LOGIN="$2"; shift 2 ;;
        --remote-password) REMOTE_PASSWORD="$2"; shift 2 ;;
        *) echo "Option inconnue : $1"; usage ;;
    esac
done

if [[ -n "$REMOTE_TYPE" ]]; then
    [[ -z "$REMOTE_PATH" || -z "$REMOTE_LOGIN" || -z "$REMOTE_PASSWORD" ]] && {
        echo "Configuration distante incomplète"
        exit 1
    }
fi

### ----------------------------
### Dépendances
### ----------------------------
sudo apt update
sudo apt install -y curl jq restic openssl systemd

if [[ -n "$REMOTE_TYPE" ]]; then
    case "$REMOTE_TYPE" in
        cifs) sudo apt install -y cifs-utils ;;
        webdav) sudo apt install -y davfs2 ;;
        *) echo "Type distant non supporté"; exit 1 ;;
    esac
fi

### ----------------------------
### Répertoires
### ----------------------------
mkdir -p "$LOCAL_REPO" "$SOURCE_DIR"
[[ -n "$REMOTE_TYPE" ]] && mkdir -p "$REMOTE_REPO"

### ----------------------------
### Installation Backrest
### ----------------------------
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64) TAG="x86_64" ;;
    aarch64|arm64) TAG="arm64" ;;
    armv7l) TAG="armv7" ;;
    *) echo "Architecture non supportée"; exit 1 ;;
esac

URL=$(curl -fsSL https://api.github.com/repos/garethgeorge/backrest/releases/latest |
      jq -r ".assets[] | select(.name|contains(\"Linux_${TAG}\")) | .browser_download_url")

TMP="$(mktemp -d)"
curl -fsSL "$URL" -o "$TMP/backrest.tgz"
sudo mkdir -p "$INSTALL_DIR"
sudo tar -xzf "$TMP/backrest.tgz" -C "$INSTALL_DIR"
cd "$INSTALL_DIR"
sudo ./install.sh

### ----------------------------
### Credentials systemd
### ----------------------------
sudo mkdir -p "$CRED_DIR"
sudo chmod 700 "$CRED_DIR"

RESTIC_PASS="$(openssl rand -base64 32)"
printf '%s' "$RESTIC_PASS" | sudo systemd-creds encrypt \
  --name=restic-password \
  --output="$CRED_DIR/restic-password.cred" -

if [[ -n "$REMOTE_TYPE" ]]; then
    printf '%s' "$REMOTE_LOGIN" | sudo systemd-creds encrypt \
      --name=remote-user \
      --output="$CRED_DIR/remote-user.cred" -
    printf '%s' "$REMOTE_PASSWORD" | sudo systemd-creds encrypt \
      --name=remote-password \
      --output="$CRED_DIR/remote-password.cred" -
fi

unset RESTIC_PASS REMOTE_LOGIN REMOTE_PASSWORD

### ----------------------------
### Override systemd
### ----------------------------
sudo mkdir -p "$OVERRIDE_DIR"
sudo tee "$OVERRIDE_FILE" > /dev/null <<EOF
[Service]
Environment="BACKREST_PORT=0.0.0.0:9898"
Environment="RESTIC_PASSWORD_FILE=/run/credentials/${SERVICE}.service/restic-password"
Nice=10

LoadCredential=restic-password
LoadCredential=remote-user
LoadCredential=remote-password
EOF

sudo systemctl daemon-reload
sudo systemctl restart backrest
sleep 5

### ----------------------------
### Configuration Backrest
### ----------------------------
CLI="backrest cli"

$CLI repo add --name local --type local --path "$LOCAL_REPO"

$CLI backup add \
  --name local-hourly \
  --repo local \
  --path "$SOURCE_DIR" \
  --schedule "@hourly" \
  --keep-last 12 \
  --nice 15 \
  --ionice idle

if [[ -n "$REMOTE_TYPE" ]]; then

    case "$REMOTE_TYPE" in
        cifs)
            MOUNT_CMD="mount -t cifs $REMOTE_PATH $REMOTE_REPO \
-o username=\$(cat /run/credentials/${SERVICE}.service/remote-user),password=\$(cat /run/credentials/${SERVICE}.service/remote-password),vers=3.1.1"
            ;;
        webdav)
            MOUNT_CMD="mount -t davfs $REMOTE_PATH $REMOTE_REPO"
            ;;
    esac

    $CLI hook add --name mount-remote --when pre-backup --command "$MOUNT_CMD"
    $CLI hook add --name umount-remote --when post-backup --command "umount $REMOTE_REPO"

    $CLI repo add --name remote --type local --path "$REMOTE_REPO"

    $CLI backup add \
      --name remote-daily \
      --repo remote \
      --path "$SOURCE_DIR" \
      --schedule "@daily" \
      --keep-last 10
fi

echo "Installation terminée avec succès"
