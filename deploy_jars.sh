#!/bin/bash

set -euo pipefail

# ================= CONFIG =================

# Source Share (New JARs)
SRC_SHARE="//epsw/VistaPrd/epms/jars"
SRC_MOUNT="/mnt/src_jars"

# ep0 Share (Existing JARs)
ep0_SHARE="//ep0/apps/ep/java/jars/test/csp"
ep0_MOUNT="/mnt/csp_jars"

# Local PROD location
PROD_TARGET="/epps/bin/prod/jars"
PROD_ARCHIVE="$PROD_TARGET/archive"

# Credentials file
CRED_FILE="/etc/.creds1"

SERVICE1="rmi-jisam-1@tax.service"
SERVICE2="rmi-jisam-1@yearend.service"

DATE=$(date +%Y%m%d)
DEPLOY_STATUS="SUCCESS"

# ================= FUNCTIONS =================

error_exit() {
    echo "ERROR: $1"
    DEPLOY_STATUS="FAILED"
    cleanup
    exit 1
}

cleanup() {
    mount | grep -q "$SRC_MOUNT" && umount "$SRC_MOUNT"
    mount | grep -q "$ep0_MOUNT" && umount "$ep0_MOUNT"
    echo "Shares unmounted."
}

# ================= VALIDATION =================

if [ $# -eq 0 ]; then
    echo "Usage: $0 jar1.jar jar2.jar ..."
    exit 1
fi

mkdir -p "$SRC_MOUNT" "$ep0_MOUNT" "$PROD_ARCHIVE"

# ================= MOUNT SHARES =================

echo "Mounting source share..."
mount -t cifs "$SRC_SHARE" "$SRC_MOUNT" \
-o rw,credentials=$CRED_FILE,uid=0,gid=100,dir_mode=0777,file_mode=0777,_netdev \
|| error_exit "Source mount failed"

echo "Mounting ep0 share..."
mount -t cifs "$ep0_SHARE" "$ep0_MOUNT" \
-o rw,credentials=$CRED_FILE,uid=0,gid=100,dir_mode=0777,file_mode=0777,_netdev \
|| error_exit "ep0 mount failed"

# ================= DEPLOY LOOP =================

for JAR in "$@"
do
    echo "-----------------------------------"
    echo "Processing $JAR"

    # Validate source file
    if [ ! -f "$SRC_MOUNT/$JAR" ]; then
        error_exit "$JAR not found in source share"
    fi

    # ---- ep0 SHARE BACKUP ----
    if [ -f "$ep0_MOUNT/$JAR" ]; then
        echo "Backing up from ep0 share"
        mv "$ep0_MOUNT/$JAR" "$ep0_MOUNT/archive/${JAR}.${DATE}"
    fi

    echo "Copying new JAR to ep0 share"
    cp "$SRC_MOUNT/$JAR" "$ep0_MOUNT/"

    # ---- PROD BACKUP ----
    if [ -f "$PROD_TARGET/$JAR" ]; then
        echo "Backing up from PROD"
        mv "$PROD_TARGET/$JAR" "$PROD_ARCHIVE/${JAR}.${DATE}"
    fi

    echo "Copying to PROD location"
    cp "$SRC_MOUNT/$JAR" "$PROD_TARGET/"
done

# ================= SERVICE RESTART =================

echo "Restarting services..."
systemctl restart $SERVICE1 || error_exit "$SERVICE1 restart failed"
systemctl restart $SERVICE2 || error_exit "$SERVICE2 restart failed"

sleep 5

STATUS1=$(systemctl is-active $SERVICE1)
STATUS2=$(systemctl is-active $SERVICE2)

# ================= VERSION CHECK =================

echo "-----------------------------------"
echo "Deployed Versions (PROD)"

for file in "$@"
do
    if [ -f "$PROD_TARGET/$file" ]; then
        echo -n "$file : "
        unzip -c "$PROD_TARGET/$file" META-INF/MANIFEST.MF 2>/dev/null | \
        grep -i Implementation-Version || echo "Version not found"
    fi
done

cleanup

# ================= SUMMARY =================

echo "==================================="
echo "         DEPLOYMENT SUMMARY        "
echo "==================================="
echo "Deployment Status : $DEPLOY_STATUS"
echo "$SERVICE1 Status : $STATUS1"
echo "$SERVICE2 Status : $STATUS2"
echo "Deployment Date   : $DATE"
echo "==================================="

if [[ "$STATUS1" != "active" || "$STATUS2" != "active" ]]; then
    echo "WARNING: One or more services are not active!"
    exit 1
fi

echo "Deployment completed successfully."

exec > deploy_$(date +%Y%m%d).log 2>&1

#this script is now ready for the deployment 