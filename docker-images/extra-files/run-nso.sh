#!/bin/bash

source /opt/ncs/current/ncsrc
source /opt/ncs/installdirs
export NCS_CONFIG_DIR NCS_LOG_DIR NCS_RUN_DIR

# install signal handlers
trap sighup_handler HUP
trap sigint_handler INT
trap sigquit_handler QUIT
trap sigterm_handler TERM

sighup_handler() {
    echo "run-nso.sh: received SIGHUP, restarting NSO"
    RESTART_REQUESTED=true
    stop_nso
    start_nso
}

sigint_handler() {
    echo "run-nso.sh: received SIGINT, stopping NSO"
    stop_nso
    exit 130 # 128+2
}

sigquit_handler() {
    echo "run-nso.sh: received SIGQUIT, stopping NSO"
    stop_nso
    exit 131 # 128+3
}

sigterm_handler() {
    echo "run-nso.sh: received SIGTERM, stopping NSO"
    stop_nso
    exit 143 # 128+15
}

# -- start NSO in the background
# The 'set +-m' are for job control monitor mode. As job control monitor mode is
# disabled per default, starting new processes places them in the same process
# group as this script. When ctrl-c is pressed, SIGINT is delivered to all the
# processes in the foreground process group, which would then include ncs. ncs
# is really the Erlang BEAM VM, just renamed, and it doesn't handle ^c well - it
# doesn't shut down ncs cleanly. To avoid this, we enable job control monitor
# mode so that ncs is started as a background task in a different process group,
# thus avoiding sending SIGINT to it on ^c. Instead we can handle SIGINT and
# nicely ask ncs to shut down.
start_nso() {
    set -m
    # output logs to stdout a la container style
    if [ "${CONTAINER_LOG_ENABLE}" == "true" ]; then
        verbose="--verbose"
        echo "run-nso.sh: NSO will log to container runtime through stdout"
    fi
    ncs --cd ${NCS_RUN_DIR} -c ${NCS_CONFIG_DIR}/ncs.conf --foreground ${verbose} --with-package-reload-force &
    NSO_PID="$!"
    set +m
}

# Stop NSO
stop_nso() {
    ncs --stop
}

# Increase JAVA VM MAX Heap size to 4GB, also enable the new G1 GC in Java 8
export NCS_JAVA_VM_OPTIONS="-Xmx4G -XX:+UseG1GC -XX:+UseStringDeduplication"

# Capture NSO version
# Determine NSO version with major / minor version component
if [[ $(ncs --version) =~ ^([0-9]+)\.([0-9]+) ]]; then
    NSO_MAJVER=${BASH_REMATCH[1]}
    NSO_MINVER=${BASH_REMATCH[2]}
else
    echo "Not a proper NSO version"
    exit 1
fi

# enable core dump
mkdir -p /nso/coredumps
echo '/nso/coredumps/core.%e.%t' > /proc/sys/kernel/core_pattern

# create required directories
mkdir -p /nso/etc
mkdir -p /log/traces
# create 'run-dir' directories, ncs and some of its tools have heuristics to
# validate that the run-dir is valid, e.g. 'packages' must exist, or ncs-backup
# thinks this is not a valid run-dir
mkdir -p /nso/etc /nso/run/cdb /nso/run/rollbacks /nso/run/scripts /nso/run/streams /nso/run/state /nso/run/backups /nso/run/packages

# Determine which ncs.conf to use and whether to mangle it
# If /nso/etc/ncs.conf exists, we will use it. Per default we do not mangle it
# and thus set MANGLE_CONFIG=false. If /nso/etc/ncs.conf does NOT exist, we
# instead default to mangling it by setting MANGLE_CONFIG=true. In either case,
# it is possible to override and force mangling of /nso/etc/ncs.conf by
# specifically setting MANGLE_CONFIG=true when starting up the container. Note
# how this is done on a copy of the configuration file, i.e. the mangling is not
# persisted. Similarly, it is possible to completely disable configuration
# mangling by explicitly setting MANGLE_CONFIG=false, although that is likely
# not very useful.
if [ -f /etc/ncs/ncs.conf ]; then
    export MANGLE_CONFIG=${MANGLE_CONFIG:-false}
    if [ "${MANGLE_CONFIG}" = "false" ]; then
        echo "NSO configuration found mounted at /etc/ncs/ncs.conf, using it verbatim"
    else
        echo "NSO configuration found mounted at /etc/ncs/ncs.conf, using it and will mangle it"
    fi
elif [ -f /nso/etc/ncs.conf ]; then
    export MANGLE_CONFIG=${MANGLE_CONFIG:-false}
    if [ "${MANGLE_CONFIG}" = "false" ]; then
        echo "NSO configuration found in volume at /nso/etc/ncs.conf, using it verbatim"
    else
        echo "NSO configuration found in volume at /nso/etc/ncs.conf, using it and will mangle it"
    fi
    cp /nso/etc/ncs.conf /etc/ncs/ncs.conf
else
    export MANGLE_CONFIG=${MANGLE_CONFIG:-true}
    if [ "${MANGLE_CONFIG}" = "false" ]; then
        echo "No NSO configuration found in volume, using /etc/ncs/ncs.conf.in verbatim"
    else
        echo "No NSO configuration found in volume, using /etc/ncs/ncs.conf.in and will mangle it"
    fi
    cp /etc/ncs/ncs.conf.in /etc/ncs/ncs.conf
fi

# Handle CDB crypto keys
# This generates the file, as it looks in newer version of NSO, with the AES256
# key. NSO version 5.2 and earlier (though not 4.x) do not support AES256 and
# thus, cannot consume this file when it is present. To get around this, we
# strip out the AES256 file before feeding the file to ncs.
if [ ! -f /nso/etc/ncs.crypto_keys ]; then
    echo "No CDB crypto_keys file found, generating one!"
    cat >/nso/etc/ncs.crypto_keys <<EOF
# Generated by NSO in Docker startup script
# keys used for encrypted string types
DES3CBC_KEY1=$(< /dev/urandom tr -dc a-f0-9 | head -c16)
DES3CBC_KEY2=$(< /dev/urandom tr -dc a-f0-9 | head -c16)
DES3CBC_KEY3=$(< /dev/urandom tr -dc a-f0-9 | head -c16)
DES3CBC_IV=$(< /dev/urandom tr -dc a-f0-9 | head -c16)

AESCFB128_KEY=$(< /dev/urandom tr -dc a-f0-9 | head -c32)
AESCFB128_IV=$(< /dev/urandom tr -dc a-f0-9 | head -c32)

AES256CFB128_KEY=$(< /dev/urandom tr -dc a-f0-9 | head -c64)
EOF

fi

echo "# This file is generated by NSO in Docker startup script" >/etc/ncs/ncs.crypto_keys

if [ ${NSO_MAJVER} -eq 4 ]; then
    echo "NSO version $(ncs --version) has inlined crypto keys, updating ncs.conf from /nso/etc/ncs.crypto_keys"
    echo "# Crypto keys are inlined in ncs.conf for NSO 4.x" >/etc/ncs/ncs.crypto_keys
    cat /nso/etc/ncs.crypto_keys >> /etc/ncs/ncs.crypto_keys
    # We need to produce this (note lack of AES256):
    # <encrypted-strings>
    #   <DES3CBC>
    #     <key1>{{NSO_DES_KEY1}}</key1>
    #     <key2>{{NSO_DES_KEY2}}</key2>
    #     <key3>{{NSO_DES_KEY3}}</key3>
    #     <initVector>{{NSO_DES_INIT}}</initVector>
    #   </DES3CBC>
    #   <AESCFB128>
    #     <key>{{NSO_AES_KEY}}</key>
    #     <initVector>{{NSO_AES_INIT}}</initVector>
    #   </AESCFB128>
    #   <AES256CFB128>
    #     <key>{{NSO_AES_256_KEY}}</key>
    #   </AES256CFB128>
    # </encrypted-strings>
    xmlstarlet edit --inplace -N x=http://tail-f.com/yang/tailf-ncs-config \
               --delete '/x:ncs-config/x:encrypted-strings' \
               -s '/x:ncs-config' -t elem -n 'encrypted-strings' \
               -s '/x:ncs-config/encrypted-strings' -t elem -n 'DES3CBC' \
               -s '/x:ncs-config/encrypted-strings/DES3CBC' -t elem -n 'key1' \
               -v $(awk -F= '/DES3CBC_KEY1/ { print $2 }' /nso/etc/ncs.crypto_keys) \
               -s '/x:ncs-config/encrypted-strings/DES3CBC' -t elem -n 'key2' \
               -v $(awk -F= '/DES3CBC_KEY2/ { print $2 }' /nso/etc/ncs.crypto_keys) \
               -s '/x:ncs-config/encrypted-strings/DES3CBC' -t elem -n 'key3' \
               -v $(awk -F= '/DES3CBC_KEY3/ { print $2 }' /nso/etc/ncs.crypto_keys) \
               -s '/x:ncs-config/encrypted-strings/DES3CBC' -t elem -n 'initVector' \
               -v $(awk -F= '/DES3CBC_IV/ { print $2 }' /nso/etc/ncs.crypto_keys) \
               -s '/x:ncs-config/encrypted-strings' -t elem -n 'AESCFB128' \
               -s '/x:ncs-config/encrypted-strings/AESCFB128' -t elem -n 'key' \
               -v $(awk -F= '/AESCFB128_KEY/ { print $2 }' /nso/etc/ncs.crypto_keys) \
               -s '/x:ncs-config/encrypted-strings/AESCFB128' -t elem -n 'initVector' \
               -v $(awk -F= '/AESCFB128_IV/ { print $2 }' /nso/etc/ncs.crypto_keys) \
               /etc/ncs/ncs.conf
elif [ ${NSO_MAJVER} -eq 5 ] && [ ${NSO_MINVER} -lt 3 ]; then
    echo "NSO version $(ncs --version) does not support AES256, stripping"
    cat /nso/etc/ncs.crypto_keys | grep -v AES256CFB128 >> /etc/ncs/ncs.crypto_keys
else
    echo "NSO version $(ncs --version) supports AES256, using ncs.crypto_keys verbatim"
    cat /nso/etc/ncs.crypto_keys >> /etc/ncs/ncs.crypto_keys
fi

# check whether SSH keys still exist in the "old" location
if [ -f /nso/ssh/ssh_host_*_key ]; then
    echo "Please move your existing SSH keys from /nso/ssh to /nso/etc/ssh"
    exit 1
fi

# generate SSH key if one doesn't exist
if [ ${NSO_MAJVER} -lt 5 ] || ([ ${NSO_MAJVER} -eq 5 ] && [ ${NSO_MINVER} -lt 3 ]); then
    echo "NSO version < 5.3 does not support ed25519 type keys, defaulting to rsa"
    SSH_HOST_KEY_TYPE=rsa
elif [ -z "${SSH_HOST_KEY_TYPE}" ] && [ -f /nso/etc/ssh/ssh_host_rsa_key ]; then
    echo "NSO version $(ncs --version) supports ed25519 host key type, but rsa keys exist in /nso/etc/ssh/ssh_host_rsa_key.\nPlease consider migrating to ed25519 by removing the old keys!"
    SSH_HOST_KEY_TYPE=rsa
fi
export SSH_HOST_KEY_TYPE=${SSH_HOST_KEY_TYPE:-ed25519}
if [ ! -f /nso/etc/ssh/ssh_host_${SSH_HOST_KEY_TYPE}_key ]; then
    echo "No SSH key of type ${SSH_HOST_KEY_TYPE} found, generating one!"
    mkdir -p /nso/etc/ssh
    ssh-keygen -m PEM -t ${SSH_HOST_KEY_TYPE} -f /nso/etc/ssh/ssh_host_${SSH_HOST_KEY_TYPE}_key -N ''
fi
# copy the (generated) SSH keys from the volume to config dir
cp -pr /nso/etc/ssh /etc/ncs/

# check whether SSL cert still exists in the "old" location
if [ -f /nso/ssl/cert/host.cert ]; then
    echo "Please move your existing SSL certificate from /nso/ssl to /nso/etc/ssl"
    exit 1
fi

# generate SSL cert if one doesn't exist
if [ ! -f /nso/etc/ssl/cert/host.cert ]; then
    echo "No SSL certs found, generating a self-signed one!"
    mkdir -p /nso/etc/ssl/cert
    openssl req -new -newkey rsa:4096 -x509 -sha256 -days 30 -nodes -out /nso/etc/ssl/cert/host.cert -keyout /nso/etc/ssl/cert/host.key \
            -subj "/C=SE/ST=NA/L=/O=NSO/OU=WebUI/CN=Mr. Self-Signed"
fi
cp -pr /nso/etc/ssl /etc/ncs/

# If necessary, i.e. if starting NSO >4 on a CDB written by NSO 4, compact CDB.
# If there is no CDB on disk, ncs --cdb-debug-dump will return "Error..." and we
# won't match that, thus such an error is handled correctly. Running
# --cdb-debug-dump on a large CDB takes a considereable amount of time,
# potentially hours for multi GB size. By using head, we exit early, leaving a
# broken pipe to ncs, which will in turn exit. This works since the interesting
# data is in the header that is printed first.
CDB_MAJVER=$(ncs --cdb-debug-dump /nso/run/cdb | head | awk '/^Version:.*from.*version/ { printf($2) }')
if [ -n "${CDB_MAJVER}" ] && [ "${CDB_MAJVER}" -eq 4 ] && [ "${NSO_MAJVER}" -ge 5 ]; then
    echo "run-nso.sh: CDB written by NSO version 4 but now running version 5. Will attempt to compact CDB"
    ncs --cdb-compact /nso/run/cdb
    echo "run-nso.sh: CDB compaction done"
fi

# pre-start scripts
for FILE in $(ls /etc/ncs/pre-ncs-start.d/*.sh 2>/dev/null); do
    echo "run-nso.sh: running pre start script ${FILE}"
    ${FILE} || exit 1
done

start_nso

# sleep a bit so ncs has a chance to start up IPC port etc
sleep 3
# Wait for NSO to start by continuously ensuring the NSO PID is alive, i.e. that
# NSO hasn't exited and NSO reports having started up. If CDB is corrupt or
# there are other similar problems during startup, ncs --wait-started will hang,
# since it is waiting for NSO. If NSO has died, there is no point waiting, thus
# we also check for the NSO PID being alive.
echo "Waiting for NSO to start..."
for I in $(seq 60); do
    if ! kill -s 0 ${NSO_PID} >/dev/null 2>&1; then
        wait ${NSO_PID}
        EXIT_CODE=$?
        echo "run-nso.sh: NSO exited during startup (exit code ${EXIT_CODE}) - exiting container"
        exit ${EXIT_CODE}
    fi
    ncs --wait-started 10 && break
done

# post-start scripts
for FILE in $(ls /etc/ncs/post-ncs-start.d/*.sh 2>/dev/null); do
    echo "run-nso.sh: running post start script ${FILE}"
    ${FILE} || exit 1
done

# wait forever on the ncs process, we run ncs in background and wait on it like
# this, with a signal handler for HUP, INT & TERM so that we upon receiving
# those signals can run ncs --stop rather than having those signals sent
# directly to ncs. For HUP we set RESTART_REQUESTED=true and will take another
# spin in our loop.
while true; do
    echo "run-nso.sh: waiting for signals or NSO (PID ${NSO_PID}) to exit..."
    RESTART_REQUESTED=false
    wait ${NSO_PID}
    EXIT_CODE=$?
    if [ "${RESTART_REQUESTED}" = true ]; then
        echo "run-nso.sh: NSO exited (exit code ${EXIT_CODE}) - NSO restarting..."
    else
        echo "run-nso.sh: NSO exited (exit code ${EXIT_CODE}) - exiting container"
        exit ${EXIT_CODE}
    fi
done
