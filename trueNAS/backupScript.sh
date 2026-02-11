#!/usr/bin/env bash
# GitHub Copilot
# Backup-Script für TrueNAS Scale
# Erstellt Versioned Backups der System-Konfiguration + Boot-Pool (optional)
# und kopiert App-Data aus einem ZFS-Dataset-Snapshot. Behaltene Versionen: 7 (konfigurierbar)
# Datei: /Users/ben/Documents/DeV/HomeLab/trueNAS/backupScript.sh

set -euo pipefail

# === Konfiguration (anpassen) ===
TARGET_DIR="/mnt/backup/trueNAS-backups"   # Zielverzeichnis (muss gemountet/zugreifbar sein)
KEEP_VERSIONS=7                            # wie viele Versionen behalten
BOOT_POOL="freenas-boot"                   # Name des Boot-Pools (falls vorhanden)
DATASET="tank/apps"                        # Dataset, aus dem Snapshots erstellt werden sollen
# Liste der Application-Relativpfade innerhalb des Dataset-Mountpoints (ohne führenden /)
# Beispiel: ("app1/data" "app2/config")
APP_PATHS=("nextcloud" "plex/Library")     # anpassen
# Ob ZFS send von Boot-Pool erzeugen (true/false). Wenn false: nur kopieren von /etc etc.
BACKUP_BOOT_POOL=true

# === Ende Konfiguration ===

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
SYS_BACKUP_DIR="${TARGET_DIR}/system-config/${TIMESTAMP}"
APP_BACKUP_BASE="${TARGET_DIR}/apps"
BOOT_BACKUP_DIR="${TARGET_DIR}/boot-pool"

mkdir -p "${SYS_BACKUP_DIR}"
mkdir -p "${APP_BACKUP_BASE}"
mkdir -p "${BOOT_BACKUP_DIR}"

# Sicherstellen: root
if [ "$(id -u)" -ne 0 ]; then
    echo "Dieses Script muss als root ausgeführt werden." >&2
    exit 1
fi

# Hilfsfunktion: alte Versionen aufräumen
cleanup_old_versions() {
    local dir="$1"
    local keep="$2"
    [ -d "${dir}" ] || return 0
    # sortiert nach Modifikationszeit (neueste zuerst), löscht ältere als KEEP
    mapfile -t items < <(find "${dir}" -mindepth 1 -maxdepth 1 -type d -printf "%T@ %p\n" | sort -rn | awk '{print $2}')
    local count=${#items[@]}
    if [ "${count}" -le "${keep}" ]; then
        return 0
    fi
    for ((i=keep; i<count; i++)); do
        rm -rf -- "${items[i]}"
    done
}

# -------------------
# 1) System-Config & wichtige Pfade kopieren
# -------------------
echo "Backup: System-Konfiguration -> ${SYS_BACKUP_DIR}"

# Versuche Middleware-Config-Export (TrueNAS API), falls vorhanden
if command -v midclt >/dev/null 2>&1; then
    # erzeugt JSON-Export der Konfiguration (Middleware call), falls möglich
    if midclt call config.save > "${SYS_BACKUP_DIR}/truenas-config.json" 2>/dev/null; then
        echo "Middleware-Konfig exportiert."
    else
        echo "Middleware-Konfig export fehlgeschlagen (Ignoriere)." >&2
    fi
fi

# Wichtige Verzeichnisse kopieren (Anpassen falls gewünscht)
# Achtung: /data, /var/db, /etc, /root werden gesichert
declare -a SYS_PATHS=(
    "/etc"
    "/var/db"
    "/root"
    "/boot"
    "/data"    # enthält bei TrueNAS einige DBs / Pool-Mounts
)

for p in "${SYS_PATHS[@]}"; do
    if [ -e "${p}" ]; then
        dest="${SYS_BACKUP_DIR}$(echo "${p}" | sed 's|/*$||')"
        mkdir -p "$(dirname "${dest}")"
        cp -aL --preserve=mode,timestamps,ownership "${p}" "${dest}" || echo "Warnung: Kopieren ${p} fehlgeschlagen" >&2
    fi
done

# Aufräumen alter System-Backups
cleanup_old_versions "${TARGET_DIR}/system-config" "${KEEP_VERSIONS}"

# -------------------
# optional: Boot-Pool snapshot + zfs send
# -------------------
if [ "${BACKUP_BOOT_POOL}" = true ]; then
    if zfs list "${BOOT_POOL}" >/dev/null 2>&1; then
        BOOT_SNAP="${BOOT_POOL}@backup-${TIMESTAMP}"
        echo "Erzeuge Snapshot ${BOOT_SNAP}"
        zfs snapshot "${BOOT_SNAP}"
        BOOT_OUT="${BOOT_BACKUP_DIR}/boot_${TIMESTAMP}.zfs.gz"
        echo "Sende Boot-Pool Snapshot nach ${BOOT_OUT}"
        # zfs send komprimiert streamen
        if zfs send -R "${BOOT_SNAP}" | gzip > "${BOOT_OUT}"; then
            echo "Boot-Pool gesichert."
        else
            echo "Fehler bei zfs send für ${BOOT_POOL}" >&2
        fi
        # optional Snapshot auf Boot-Pool entfernen (behalten lokale snapshot ist ok)
        # zfs destroy "${BOOT_SNAP}" || true
        cleanup_old_versions "${BOOT_BACKUP_DIR}" "${KEEP_VERSIONS}"
    else
        echo "Boot-Pool ${BOOT_POOL} nicht gefunden, überspringe Boot-Backup." >&2
    fi
fi

# -------------------
# 2) Snapshot des Datasets erzeugen und App-Data aus Snapshot kopieren
# -------------------
# Erzeuge Snapshot
if ! zfs list "${DATASET}" >/dev/null 2>&1; then
    echo "Dataset ${DATASET} existiert nicht." >&2
    exit 1
fi

DATASET_SNAP="${DATASET}@backup-${TIMESTAMP}"
echo "Erzeuge Snapshot ${DATASET_SNAP}"
zfs snapshot "${DATASET_SNAP}"

# Ermitteln des Mountpoints des Datasets
MOUNTPOINT="$(zfs get -H -o value mountpoint "${DATASET}")"
if [ -z "${MOUNTPOINT}" ] || [ "${MOUNTPOINT}" = "legacy" ]; then
    echo "Dataset ${DATASET} hat keinen standard Mountpoint oder ist 'legacy'." >&2
    # Nutzer muss Mountpoint setzen oder alternative Methode verwenden
    exit 1
fi

for rel in "${APP_PATHS[@]}"; do
    src="${MOUNTPOINT}/.zfs/snapshot/backup-${TIMESTAMP}/${rel}"
    if [ ! -e "${src}" ]; then
        echo "Warnung: Quelle ${src} existiert nicht, überspringe ${rel}" >&2
        continue
    fi
    # Zielverzeichnis pro App und Timestamp
    app_name="$(basename "${rel}")"
    dest_dir="${APP_BACKUP_BASE}/${app_name}/${TIMESTAMP}"
    mkdir -p "${dest_dir}"
    echo "Kopiere ${src} -> ${dest_dir}"
    # rsync mit Erhalt von Rechten/Links/Times
    rsync -aHAX --delete "${src}/" "${dest_dir}/"
    # Aufräumen alte Versionen pro App
    cleanup_old_versions "${APP_BACKUP_BASE}/${app_name}" "${KEEP_VERSIONS}"
done

# optional: Snapshot entfernen (oder behalten, je nach Strategie)
# zfs destroy "${DATASET_SNAP}" || true

echo "Backup abgeschlossen."