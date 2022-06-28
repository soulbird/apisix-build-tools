#!/usr/bin/env bash

# pre-set
set -euo pipefail
set -x

env

# =======================================
# Runtime default config
# =======================================
VAR_TENCENT_COS_UTILS_VERSION=${VAR_TENCENT_COS_UTILS_VERSION:-v0.11.0-beta}
VAR_RPM_WORKBENCH_DIR=${VAR_RPM_WORKBENCH_DIR:-/tmp/output}
VAR_GPG_PRIV_KET=${VAR_GPG_PRIV_KET:-/tmp/dep-gpg-publish.private}
VAR_GPG_PASSPHRASE=${VAR_GPG_PASSPHRASE:-/tmp/deb-gpg-publish.passphrase}


func_gpg_key_load() {
    # ${1} gpg private key
    # ${2} gpg key passphrase
    gpg --import --pinentry-mode loopback --batch --passphrase-file "${2}" "${1}"

    gpg --list-keys --fingerprint | grep "${GPG_MAIL}" -B 1 \
    | tr -d ' ' | head -1 | awk 'BEGIN { FS = "\n" } ; { print $1":6:" }' \
    | gpg --import-ownertrust
}

# =======================================
# COS extension
# =======================================
func_cos_utils_install() {
    # ${1} - COS util version
    curl -o /usr/bin/coscli -L "https://github.com/tencentyun/coscli/releases/download/${1}/coscli-linux"
    chmod 755 /usr/bin/coscli
}

func_cos_utils_credential_init() {
    # ${1} - COS endpoint
    # ${2} - COS SECRET_ID
    # ${3} - COS SECRET_KEY
    cat > "${HOME}/.cos.yaml" <<_EOC_
cos:
  base:
    secretid: ${2}
    secretkey: ${3}
    sessiontoken: ""
    protocol: https
_EOC_
}

# =======================================
# COS repo extension
# =======================================
func_repo_init() {
    # ${1} - repo workbench path
    mkdir -p "${1}"/ubuntu/{conf, old_debs}
        cat > "${1}"/ubuntu/conf/distributions <<_EOC_
Origin: apisix.apache.org
Label: apisix
Suite: stable
Codename: focal jammy trusty
Version: 2.14.1
Architectures: amd64
Components: main
Description: apisix debian repo
_EOC_

    cd "${1}"/ubuntu
    reprepro --ask-passphrase -Vb . export
}

func_repo_clone() {
    # ${1} - bucket name
    # ${2} - COS path
    # ${3} - target path
    coscli -e "${VAR_COS_ENDPOINT}" cp -r "cos://${1}/packages/${2}" "${3}"
}

func_repo_backup() {
    # ${1} - bucket name
    # ${2} - COS path
    # ${3} - backup tag
    echo "${VAR_COS_ENDPOINT}"
    echo "$1" "$2" "$3"
    coscli -e "${VAR_COS_ENDPOINT}" cp -r "cos://${1}/packages/${2}" "cos://${1}/packages/backup/${2}_${3}"
}

func_repo_backup_remove() {
    # ${1} - bucket name
    # ${2} - COS path
    # ${3} - backup tag
    coscli -e "${VAR_COS_ENDPOINT}" rm -r -f "cos://${1}/packages/backup/${2}_${3}"
}

func_repo_repodata_rebuild() {
    # ${1} - repo parent path
    find "${1}" -type d -name "*.deb" \
        -exec echo "reprepro for: {}" \; \
        -exec reprepro --ask-passphrase -Vb . includedeb focal {} \;
}

func_repo_repodata_sign() {
    # ${1} - repo parent path
    find "${1}" -type f -name "*repomd.xml" \
        -exec echo "sign repodata for: {}" \; \
        -exec gpg --batch --pinentry-mode loopback --passphrase-file "${VAR_GPG_PASSPHRASE}" --detach-sign --armor {} \;
}

func_repo_upload() {
    # ${1} - local path
    # ${2} - bucket name
    # ${3} - COS path
    coscli -e "${VAR_COS_ENDPOINT}" rm -r -f "cos://${2}/packages/${3}"
    coscli -e "${VAR_COS_ENDPOINT}" cp -r "${1}" "cos://${2}/packages/${3}"
}

func_repo_publish() {
    # ${1} - CI bucket
    # ${2} - repo publish bucket
    # ${3} - COS path
    coscli -e "${VAR_COS_ENDPOINT}" rm -r -f "cos://${2}/packages/${3}"
    coscli -e "${VAR_COS_ENDPOINT}" cp -r "cos://${1}/packages/${3}" "cos://${2}/packages"
}

# =======================================
# publish utils entry
# =======================================
case_opt=$1

case ${case_opt} in
init_cos_utils)
    func_cos_utils_install "${VAR_TENCENT_COS_UTILS_VERSION}"
    func_cos_utils_credential_init "${VAR_COS_ENDPOINT}" "${TENCENT_COS_SECRETID}" "${TENCENT_COS_SECRETKEY}"
    ;;
deb_gpg_init)
    func_gpg_key_load "${VAR_GPG_PRIV_KET}" "${VAR_GPG_PASSPHRASE}"
    ;;
repo_init)
    # create basic repo directory structure
    # useful when a new repo added
    func_repo_init /tmp
    ;;
repo_clone)
    func_repo_clone "${VAR_COS_BUCKET_REPO}" "ubuntu" /tmp/ubuntu/old_debs
    ;;
repo_backup)
    func_repo_backup "${VAR_COS_BUCKET_REPO}" "ubuntu" "${TAG_DATE}"
    ;;
repo_package_sync)
    VAR_REPO_MAJOR_VER=(focal jammy trusty)
    for i in "${VAR_REPO_MAJOR_VER[@]}"; do
        find "${VAR_RPM_WORKBENCH_DIR}" -type f -name "*.deb" \
            -exec echo "repo sync for: {}" \; \
            -exec cp -a {} /tmp/ubuntu/"${i}"/amd64 \;
    done
    ;;
repo_repodata_rebuild)
    func_repo_repodata_rebuild /tmp/ubuntu/old_debs
    #func_repo_repodata_sign /tmp/ubuntu
    ;;
repo_upload)
    func_repo_upload /tmp/ubuntu/dist "${VAR_COS_BUCKET_CI}" "ubuntu"
    func_repo_upload /tmp/ubuntu/pool "${VAR_COS_BUCKET_CI}" "ubuntu"
    ;;
repo_publish)
    func_repo_publish "${VAR_COS_BUCKET_CI}" "${VAR_COS_BUCKET_REPO}" "ubuntu"
    ;;
repo_backup_remove)
    func_repo_backup_remove "${VAR_COS_BUCKET_REPO}" "centos" "${TAG_DATE}"
    ;;
*)
    echo "Unknown method!"
esac
