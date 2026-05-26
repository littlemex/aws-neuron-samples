#!/bin/bash
# setup-persistence.sh - runs on the instance to set up persistent storage.
#
# Responsibilities:
#   - Format and mount the NVMe instance store (/dev/nvme1n1 -> /mnt/local)
#   - Mount the EFS file system at /mnt/efs with sticky 1777 permissions
#   - Symlink /home/${CODE_USER} and ${HOME_DIR} onto EFS so state
#     survives instance replacement and Spot stop/start
#   - Set the code-server user's HOME to /home/${CODE_USER} (usermod +
#     systemd override) so code-server writes config/extensions to EFS
#   - Symlink ~/.cache onto NVMe (faster, ephemeral)
#   - Neuron NEFF compile cache: NVMe primary + EFS backup, with a
#     rsync pull on restore and a systemd timer pushing back every 10 min
#
# The script is idempotent. Running it a second time is safe and is in
# fact how the persistence state is rebuilt after a Spot stop/start
# (which wipes the NVMe instance store).
#
# Environment variables:
#   EFS_ID                  required  e.g. fs-XXXXXXXXXXXXXXXXX
#   EFS_SUBPATH             default   /neuron-workspace
#   CODE_USER               default   coder
#   HOME_DIR                default   /work
#   NEFF_RESTORE_FROM_EFS   default   yes (copy cache from EFS backup to NVMe on start)
#   AWS_REGION              default   (unset - must be provided)
#
# Usage:
#   Invoked via SSM Run Command by tasks/code-server-setup.json
#   (the 00-setup-persistence task). Can also be run directly on the
#   instance as root: `bash /tmp/setup-persistence.sh`.

set -e

EFS_ID="${EFS_ID:-}"
EFS_SUBPATH="${EFS_SUBPATH:-/neuron-workspace}"
CODE_USER="${CODE_USER:-coder}"
HOME_DIR="${HOME_DIR:-/work}"
REGION="${AWS_REGION:-}"
NEFF_RESTORE_FROM_EFS="${NEFF_RESTORE_FROM_EFS:-yes}"

# If AWS_REGION is not provided, fall back to IMDSv2. SSM Run Command does not
# populate AWS_REGION by default, so this guarantees the script works both from
# an interactive shell and through SSM.
if [ -z "$REGION" ]; then
    TOKEN=$(curl -sSfX PUT http://169.254.169.254/latest/api/token \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)
    if [ -n "$TOKEN" ]; then
        REGION=$(curl -sSf -H "X-aws-ec2-metadata-token: $TOKEN" \
            http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || true)
    fi
fi

if [ -z "$EFS_ID" ]; then
    echo "[setup-persistence] ERROR: EFS_ID is required (export EFS_ID=fs-xxxx before running)" >&2
    exit 1
fi
if [ -z "$REGION" ]; then
    echo "[setup-persistence] ERROR: AWS_REGION not set and IMDS lookup failed." >&2
    echo "[setup-persistence]        export AWS_REGION=<region> before running." >&2
    exit 1
fi

log() { echo "[setup-persistence] $*"; }

# -------- Step 1: NVMe instance store --------
# trn2.3xlarge has 1 instance store NVMe, trn2.48xlarge has 4. The kernel
# enumerates EBS volumes and instance stores together as /dev/nvmeN, and the
# ordering is not guaranteed across instance types. Identify instance stores
# by AWS NVMe vendor model "Amazon EC2 NVMe Instance Storage" and exclude any
# device that already hosts the root filesystem.
log "Step 1: NVMe instance store -> /mnt/local"

ROOT_SRC=$(findmnt -n -o SOURCE / 2>/dev/null | sed 's|p[0-9]\+$||')
log "  root device (excluded): ${ROOT_SRC:-unknown}"

INSTANCE_STORE_DEVS=()
for d in /dev/nvme*n1; do
    [ -b "$d" ] || continue
    [ "$d" = "$ROOT_SRC" ] && continue
    model=$(cat /sys/class/nvme/$(basename "$d" | sed 's/n1$//')/model 2>/dev/null | tr -d ' ' || true)
    if echo "$model" | grep -qi "InstanceStorage"; then
        INSTANCE_STORE_DEVS+=("$d")
    fi
done
log "  detected instance store devices: ${INSTANCE_STORE_DEVS[*]:-(none)}"

LOCAL_DEV=""
NSTORES=${#INSTANCE_STORE_DEVS[@]}
if [ "$NSTORES" -eq 0 ]; then
    log "  [WARN] no instance store NVMe found; skipping /mnt/local"
elif [ "$NSTORES" -eq 1 ]; then
    LOCAL_DEV="${INSTANCE_STORE_DEVS[0]}"
else
    # Multiple instance stores -> assemble md RAID0
    DEBIAN_FRONTEND=noninteractive apt-get install -yq mdadm >/dev/null 2>&1 || true
    LOCAL_DEV="/dev/md0"
    if [ ! -b "$LOCAL_DEV" ]; then
        log "  creating RAID0 across ${INSTANCE_STORE_DEVS[*]}"
        # Wipe any old superblocks (e.g. after Spot stop/start the disks come back blank,
        # but on first boot they may have leftover signatures from prior tenants).
        for d in "${INSTANCE_STORE_DEVS[@]}"; do
            wipefs -a "$d" >/dev/null 2>&1 || true
            mdadm --zero-superblock --force "$d" >/dev/null 2>&1 || true
        done
        mdadm --create --verbose "$LOCAL_DEV" --level=0 --raid-devices="$NSTORES" \
            "${INSTANCE_STORE_DEVS[@]}" --run
    else
        log "  RAID0 $LOCAL_DEV already assembled"
    fi
fi

if [ -n "$LOCAL_DEV" ] && [ -b "$LOCAL_DEV" ]; then
    if ! mount | grep -q " /mnt/local "; then
        if ! blkid "$LOCAL_DEV" >/dev/null 2>&1; then
            log "  formatting $LOCAL_DEV (first time or post-stop wipe)"
            mkfs.ext4 -F "$LOCAL_DEV"
        fi
        mkdir -p /mnt/local
        mount "$LOCAL_DEV" /mnt/local || {
            log "  mount failed, reformat + retry"
            mkfs.ext4 -F "$LOCAL_DEV"
            mount "$LOCAL_DEV" /mnt/local
        }
        chmod 1777 /mnt/local
        log "  mounted $LOCAL_DEV -> /mnt/local"
    else
        log "  /mnt/local already mounted"
    fi
fi

# -------- Step 2: mount EFS and fix permissions --------
log "Step 2: EFS mount + 1777 permissions"
mkdir -p /mnt/efs
if ! mount | grep -q "/mnt/efs"; then
    DEBIAN_FRONTEND=noninteractive apt-get update -yq
    DEBIAN_FRONTEND=noninteractive apt-get install -yq nfs-common rsync
    for i in 1 2 3 4 5 6; do
        mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport \
            "${EFS_ID}.efs.${REGION}.amazonaws.com:/" /mnt/efs && break
        log "  EFS mount retry $i"; sleep 10
    done
    log "  mounted /mnt/efs"
fi
# Make /mnt/efs and our subroot 1777-sticky so the code-server user can mkdir
chmod 1777 /mnt/efs 2>/dev/null || true
EFS_HOME_ROOT="/mnt/efs${EFS_SUBPATH}"
mkdir -p "${EFS_HOME_ROOT}"
chmod 1777 "${EFS_HOME_ROOT}" 2>/dev/null || true
mkdir -p "${EFS_HOME_ROOT}/home-${CODE_USER}" "${EFS_HOME_ROOT}/work"
# Also create the persistent NEFF cache directory on EFS
mkdir -p "${EFS_HOME_ROOT}/neuron-compile-cache"
chmod 1777 "${EFS_HOME_ROOT}/neuron-compile-cache" 2>/dev/null || true

# -------- Step 3: persist the mounts in /etc/fstab --------
log "Step 3: /etc/fstab"
if ! grep -q "${EFS_ID}.efs" /etc/fstab; then
    cat >> /etc/fstab <<EOF

# Persistent EFS for /home and /work
${EFS_ID}.efs.${REGION}.amazonaws.com:/ /mnt/efs nfs4 nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport,_netdev 0 0
EOF
fi
# Note: we deliberately do NOT add /mnt/local to /etc/fstab. The set of NVMe
# instance store devices (and md device names) is not stable across stop/start
# on Spot or instance-type swaps, so persisting a fixed entry would race with
# the early-boot mount and leave the box in maintenance mode. setup-persistence.sh
# is idempotent and is re-run on boot via the recovery hook to remount /mnt/local.

# -------- Step 4: symlink /home/${CODE_USER} and /work onto EFS --------
log "Step 4: migrate /home/${CODE_USER} and /work -> EFS"
# If setup-code-server.sh has not run yet the code-server user may not exist; create it.
if ! id -u "${CODE_USER}" >/dev/null 2>&1; then
    log "  user ${CODE_USER} not yet created, creating preliminarily"
    useradd -m -d "${HOME_DIR}" -s /bin/bash -G sudo "${CODE_USER}" || true
fi

LINK_HOME="/home/${CODE_USER}"
EFS_HOME="${EFS_HOME_ROOT}/home-${CODE_USER}"
EFS_WORK="${EFS_HOME_ROOT}/work"

# Replace /home/${CODE_USER} with a symlink onto EFS (migrate existing data with rsync)
# Idempotency:
#   - if the current symlink target already matches -> no-op
#   - if the target differs (subpath change, second instance) -> rsync into the
#     new target, then repoint the symlink (the old target is left for manual cleanup)
CURRENT_LINK_TARGET=$(readlink -f "${LINK_HOME}" 2>/dev/null || echo "")
EXPECTED_HOME=$(readlink -f "${EFS_HOME}" 2>/dev/null || echo "${EFS_HOME}")
if [ "${CURRENT_LINK_TARGET}" != "${EXPECTED_HOME}" ]; then
    log "  /home/${CODE_USER} symlink change: '${CURRENT_LINK_TARGET}' -> '${EXPECTED_HOME}'"
    mkdir -p "${EFS_HOME}"
    # If the old target has data but the new target is empty, rsync across
    if [ -L "${LINK_HOME}" ] && [ -n "${CURRENT_LINK_TARGET}" ] && [ -d "${CURRENT_LINK_TARGET}" ] && \
       [ -z "$(ls -A "${EFS_HOME}" 2>/dev/null)" ]; then
        log "  rsync ${CURRENT_LINK_TARGET}/ -> ${EFS_HOME}/"
        rsync -aAX "${CURRENT_LINK_TARGET}/" "${EFS_HOME}/" 2>/dev/null || true
    elif [ ! -L "${LINK_HOME}" ] && [ -d "${LINK_HOME}" ] && \
         [ -z "$(ls -A "${EFS_HOME}" 2>/dev/null)" ]; then
        log "  rsync ${LINK_HOME}/ -> ${EFS_HOME}/"
        rsync -aAX "${LINK_HOME}/" "${EFS_HOME}/" 2>/dev/null || true
    fi
    # If code-server is running against the current path, stop it first
    systemctl stop "code-server@${CODE_USER}" 2>/dev/null || true
    pkill -u "${CODE_USER}" 2>/dev/null || true
    sleep 2
    # Move the existing entry aside and create the symlink
    if [ -L "${LINK_HOME}" ]; then
        rm -f "${LINK_HOME}"
    elif [ -d "${LINK_HOME}" ]; then
        mv "${LINK_HOME}" "${LINK_HOME}.pre-efs-$(date +%s)"
    fi
    ln -sfn "${EFS_HOME}" "${LINK_HOME}"
    chown -h "${CODE_USER}:${CODE_USER}" "${LINK_HOME}"
fi

# Same pattern for /work
CURRENT_WORK_TARGET=$(readlink -f "${HOME_DIR}" 2>/dev/null || echo "")
EXPECTED_WORK=$(readlink -f "${EFS_WORK}" 2>/dev/null || echo "${EFS_WORK}")
if [ "${CURRENT_WORK_TARGET}" != "${EXPECTED_WORK}" ]; then
    log "  ${HOME_DIR} symlink change: '${CURRENT_WORK_TARGET}' -> '${EXPECTED_WORK}'"
    mkdir -p "${EFS_WORK}"
    if [ -L "${HOME_DIR}" ] && [ -n "${CURRENT_WORK_TARGET}" ] && [ -d "${CURRENT_WORK_TARGET}" ] && \
       [ -z "$(ls -A "${EFS_WORK}" 2>/dev/null)" ]; then
        log "  rsync ${CURRENT_WORK_TARGET}/ -> ${EFS_WORK}/"
        rsync -aAX "${CURRENT_WORK_TARGET}/" "${EFS_WORK}/" 2>/dev/null || true
    elif [ ! -L "${HOME_DIR}" ] && [ -d "${HOME_DIR}" ] && \
         [ -z "$(ls -A "${EFS_WORK}" 2>/dev/null)" ]; then
        rsync -aAX "${HOME_DIR}/" "${EFS_WORK}/" 2>/dev/null || true
    fi
    if [ -L "${HOME_DIR}" ]; then
        rm -f "${HOME_DIR}"
    elif [ -d "${HOME_DIR}" ]; then
        mv "${HOME_DIR}" "${HOME_DIR}.pre-efs-$(date +%s)"
    fi
    ln -sfn "${EFS_WORK}" "${HOME_DIR}"
    chown -h "${CODE_USER}:${CODE_USER}" "${HOME_DIR}"
fi

# Final ownership + permissions
chown -R "${CODE_USER}:${CODE_USER}" "${EFS_HOME}" "${EFS_WORK}"
chmod 750 "${EFS_HOME}" "${EFS_WORK}"

# Ensure the user's HOME is /home/${CODE_USER}
CURRENT_HOME=$(getent passwd "${CODE_USER}" | cut -d: -f6)
if [ "${CURRENT_HOME}" != "${LINK_HOME}" ]; then
    systemctl stop "code-server@${CODE_USER}" 2>/dev/null || true
    pkill -u "${CODE_USER}" 2>/dev/null || true
    sleep 2
    usermod -d "${LINK_HOME}" "${CODE_USER}" || true
    log "  usermod: HOME -> ${LINK_HOME}"
fi

# -------- Step 5: code-server systemd override --------
log "Step 5: systemd override (HOME=${LINK_HOME})"
OVERRIDE_DIR="/etc/systemd/system/code-server@${CODE_USER}.service.d"
mkdir -p "${OVERRIDE_DIR}"
cat > "${OVERRIDE_DIR}/override.conf" <<EOF
[Service]
Environment=HOME=${LINK_HOME}
Environment=XDG_CONFIG_HOME=${LINK_HOME}/.config
Environment=NEURON_COMPILE_CACHE_URL=/var/tmp/neuron-compile-cache
EOF
systemctl daemon-reload 2>/dev/null || true

# -------- Step 6: symlink ~/.cache onto NVMe --------
log "Step 6: ~/.cache -> /mnt/local/cache-${CODE_USER}"
CACHE_SRC="/mnt/local/cache-${CODE_USER}"
REAL_HOME_RESOLVED=$(readlink -f "${LINK_HOME}" 2>/dev/null || echo "${LINK_HOME}")
CACHE_DST="${REAL_HOME_RESOLVED}/.cache"

if [ -d /mnt/local ] && mount | grep -q "/mnt/local"; then
    mkdir -p "${CACHE_SRC}"
    chown -R "${CODE_USER}:${CODE_USER}" "${CACHE_SRC}"
    if [ -d "${CACHE_DST}" ] && [ ! -L "${CACHE_DST}" ]; then
        rsync -aAX "${CACHE_DST}/" "${CACHE_SRC}/" 2>/dev/null || true
        rm -rf "${CACHE_DST}"
    fi
    ln -sfn "${CACHE_SRC}" "${CACHE_DST}"
    chown -h "${CODE_USER}:${CODE_USER}" "${CACHE_DST}"
    log "  .cache -> NVMe"
else
    # If NVMe is unavailable, just leave .cache on EFS (slower, but fine)
    log "  NVMe unavailable, leave .cache on EFS home"
fi

# -------- Step 7: NEFF cache (NVMe primary + EFS persistent backup) --------
# Strategy:
#   - primary: /mnt/local/neuron-compile-cache (NVMe, fast, wiped on Spot stop)
#   - backup:  /mnt/efs/${EFS_SUBPATH}/neuron-compile-cache (EFS, durable, slower)
#   - /var/tmp/neuron-compile-cache -> primary (this is what Neuron writes to)
#   - On start: if the EFS backup has content, rsync it to NVMe to restore cache hits
#   - Every 10 min: systemd timer rsyncs NVMe -> EFS to persist new cache entries
log "Step 7: NEFF cache (NVMe primary + EFS backup)"
NEFF_LOCAL="/mnt/local/neuron-compile-cache"
NEFF_EFS="${EFS_HOME_ROOT}/neuron-compile-cache"
NEFF_SYMLINK="/var/tmp/neuron-compile-cache"

mkdir -p "${NEFF_EFS}"
chmod 1777 "${NEFF_EFS}" 2>/dev/null || true

if [ -d /mnt/local ] && mount | grep -q "/mnt/local"; then
    mkdir -p "${NEFF_LOCAL}"
    chmod 1777 "${NEFF_LOCAL}" 2>/dev/null || true

    # Restore EFS -> NVMe (pulls cached NEFFs back after a Spot start)
    if [ "${NEFF_RESTORE_FROM_EFS}" = "yes" ] && [ -n "$(ls -A "${NEFF_EFS}" 2>/dev/null)" ]; then
        log "  restoring NEFF from EFS backup (${NEFF_EFS}) to NVMe primary (${NEFF_LOCAL})"
        rsync -aAX --ignore-existing "${NEFF_EFS}/" "${NEFF_LOCAL}/" 2>/dev/null || true
    fi

    # Point /var/tmp/neuron-compile-cache at the NVMe primary
    if [ ! -L "${NEFF_SYMLINK}" ]; then
        [ -e "${NEFF_SYMLINK}" ] && rm -rf "${NEFF_SYMLINK}.old" && mv "${NEFF_SYMLINK}" "${NEFF_SYMLINK}.old" || true
        ln -sfn "${NEFF_LOCAL}" "${NEFF_SYMLINK}"
    fi
    log "  ${NEFF_SYMLINK} -> ${NEFF_LOCAL}"

    # Reverse rsync (NVMe -> EFS) every 10 min to make the NEFF cache durable
    BACKUP_SCRIPT="/usr/local/bin/neff-backup-to-efs.sh"
    cat > "${BACKUP_SCRIPT}" <<EOF
#!/bin/bash
# Every 10 minutes, rsync the NVMe NEFF cache to the EFS backup
set -e
if mount | grep -q "/mnt/local" && mount | grep -q "/mnt/efs"; then
    rsync -aAX --delete-after "${NEFF_LOCAL}/" "${NEFF_EFS}/" 2>/dev/null || true
fi
EOF
    chmod +x "${BACKUP_SCRIPT}"

    # systemd timer (preferred over cron on current Ubuntu server)
    TIMER_UNIT="/etc/systemd/system/neff-backup.timer"
    SERVICE_UNIT="/etc/systemd/system/neff-backup.service"
    cat > "${SERVICE_UNIT}" <<EOF
[Unit]
Description=NEFF cache backup to EFS
After=mnt-efs.mount mnt-local.mount

[Service]
Type=oneshot
ExecStart=${BACKUP_SCRIPT}
EOF
    cat > "${TIMER_UNIT}" <<EOF
[Unit]
Description=NEFF cache backup every 10 min
Requires=neff-backup.service

[Timer]
OnBootSec=5min
OnUnitActiveSec=10min
Unit=neff-backup.service

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now neff-backup.timer 2>/dev/null || true
    log "  neff-backup.timer enabled (NVMe -> EFS every 10 min)"
else
    # No NVMe: point the cache at EFS directly (slower but still durable)
    if [ ! -L "${NEFF_SYMLINK}" ]; then
        [ -e "${NEFF_SYMLINK}" ] && mv "${NEFF_SYMLINK}" "${NEFF_SYMLINK}.old" || true
        ln -sfn "${NEFF_EFS}" "${NEFF_SYMLINK}"
    fi
    log "  NVMe unavailable, ${NEFF_SYMLINK} -> EFS (${NEFF_EFS})"
fi

# Restart code-server to pick up the systemd override
systemctl restart "code-server@${CODE_USER}" 2>/dev/null || true

# -------- Step 8: verify --------
log "Step 8: verify"
df -h /mnt/efs /mnt/local 2>/dev/null | awk 'NR>1 {print "  "$0}'
echo ""
ls -la "${LINK_HOME}" "${HOME_DIR}" "${NEFF_SYMLINK}" 2>/dev/null | awk '{print "  "$0}'
echo ""
echo "  coder passwd: $(getent passwd ${CODE_USER})"
echo ""
# write test
sudo -u "${CODE_USER}" bash -c 'touch /mnt/efs/.wt_$$ && rm /mnt/efs/.wt_$$ && echo "  /mnt/efs WRITE OK"'
sudo -u "${CODE_USER}" bash -c 'touch /home/coder/.wt_$$ && rm /home/coder/.wt_$$ && echo "  /home/coder WRITE OK"'
sudo -u "${CODE_USER}" bash -c 'touch /var/tmp/neuron-compile-cache/.wt_$$ && rm /var/tmp/neuron-compile-cache/.wt_$$ && echo "  NEFF cache WRITE OK"'

log "DONE. Persistent setup complete."
