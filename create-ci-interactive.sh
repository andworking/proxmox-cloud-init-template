#!/usr/bin/env bash
# Proxmox cloud-init template builder.
# The guest agent is installed on the clone's first boot, not baked into the
# image: virt-customize rebuilds Debian's initramfs without virtio_scsi and
# the first boot panics. libguestfs is intentionally not used.
set -euo pipefail
shopt -s inherit_errexit

VMID=9998
VM_NAME=""
CI_USER=""
IMG_URL=""

MEMORY_MB=4096
CORES=2
CPU_TYPE="host"
BRIDGE="vmbr0"
NET_MODEL="virtio"
STORAGE="local-lvm"
SNIPPET_STORAGE="local"
SNIPPET_NAME="qemu-guest-agent.yaml"
SNIPPET_DIR=""
IPCONFIG0="ip=dhcp"
DISK_RESIZE="+10G"
SSH_KEYFILE=""
NAMESERVER=""
CI_PASSWORD=""

OS_CHOICE=""
ASSUME_YES=0
SHOW_HELP=0

WORKDIR=""
VM_CREATED=0
TEMPLATE_READY=0

# EXIT covers normal failure, Ctrl+C and SIGTERM. SIGKILL cannot run a trap;
# reap_stale_workdirs removes those leftovers on the next start.
cleanup() {
  local rc=$?
  if [[ -n "${WORKDIR}" && -d "${WORKDIR}" ]]; then
    rm -rf "${WORKDIR}"
  fi
  if [[ "${VM_CREATED}" -eq 1 && "${TEMPLATE_READY}" -eq 0 ]]; then
    printf 'Откат незавершённой ВМ %s\n' "${VMID}" >&2
    qm destroy "${VMID}" --purge >/dev/null 2>&1 || true
  fi
  exit "${rc}"
}
trap cleanup EXIT

die() {
  printf 'ОШИБКА: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Использование:
  create-ci-template.sh                  интерактивное меню
  create-ci-template.sh --default        Ubuntu 24.04, значения по умолчанию
  create-ci-template.sh --os N [опции]   без меню

ОС:
  1  Ubuntu 24.04 LTS
  2  Ubuntu 22.04 LTS
  3  Debian 12 (genericcloud)
  4  AlmaLinux 9

Опции:
  --vmid ID                 VMID (100–999999999)
  --name NAME               имя шаблона
  --memory MB               ОЗУ
  --cores N                 ядра
  --cpu TYPE                тип CPU (host, kvm64, ...)
  --bridge BR               мост, по умолчанию vmbr0
  --storage STORAGE         хранилище диска
  --snippet-storage STORAGE dir-хранилище со snippets, по умолчанию local
  --user USER               пользователь cloud-init
  --ipconfig STRING         например ip=dhcp или ip=10.0.0.10/24,gw=10.0.0.1
  --resize SIZE             прирост диска, например +10G
  --ssh-key FILE            публичный ключ
  --nameserver IP           DNS, если не нужен DHCP
  --yes                     не спрашивать подтверждение
  --help
EOF
}

ask() {
  local prompt=$1
  local default=${2-}
  local value=""
  if [[ -n "${default}" ]]; then
    read -r -p "${prompt} [${default}]: " value || die "Ввод прерван"
    printf '%s\n' "${value:-${default}}"
  else
    read -r -p "${prompt}: " value || die "Ввод прерван"
    printf '%s\n' "${value}"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Не найдена команда: $1"
}

# Prints the body of one storage.cfg section (without the header).
storage_section() {
  local id=$1
  awk -v id="${id}" '
    {
      line=$0
      sub(/\r$/, "", line)
      sub(/[ \t]+$/, "", line)
    }
    !found && line ~ /^[^#[:space:]]/ {
      split(line, a, ": ")
      gsub(/[ \t]+$/, "", a[2])
      if (a[2] == id) { found=1; next }
    }
    found && line ~ /^[^[:space:]#]/ { exit }
    found { print line }
  ' /etc/pve/storage.cfg
}

set_os_params() {
  local choice=$1
  local default_name=""
  local default_user=""
  case "${choice}" in
    1)
      IMG_URL="https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img"
      default_name="ubuntu-2404-ci"
      default_user="ubuntu"
      ;;
    2)
      IMG_URL="https://cloud-images.ubuntu.com/releases/jammy/release/ubuntu-22.04-server-cloudimg-amd64.img"
      default_name="ubuntu-2204-ci"
      default_user="ubuntu"
      ;;
    3)
      # genericcloud already contains virtio drivers for KVM.
      # The larger "generic" image is for physical hardware.
      IMG_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
      default_name="debian-12-ci"
      default_user="debian"
      ;;
    4)
      IMG_URL="https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2"
      default_name="almalinux-9-ci"
      default_user="almalinux"
      ;;
    *)
      die "Неверный выбор ОС: ${choice}. Допустимо 1–4."
      ;;
  esac
  [[ -n "${VM_NAME}" ]] || VM_NAME="${default_name}"
  [[ -n "${CI_USER}" ]] || CI_USER="${default_user}"
}

select_os_menu() {
  local os_sel=""
  while true; do
    echo ""
    echo "Выберите дистрибутив:"
    echo "1) Ubuntu 24.04 LTS"
    echo "2) Ubuntu 22.04 LTS"
    echo "3) Debian 12"
    echo "4) AlmaLinux 9"
    echo ""
    read -r -p "Выбор [1]: " os_sel || die "Ввод прерван"
    os_sel="${os_sel:-1}"
    case "${os_sel}" in
      1|2|3|4) set_os_params "${os_sel}"; return ;;
      *) echo "Введите число от 1 до 4." ;;
    esac
  done
}

interactive_config() {
  select_os_menu
  echo ""
  echo "Параметры ВМ (Enter — значение по умолчанию)"
  echo ""
  VMID=$(ask "VM ID" "${VMID}")
  VM_NAME=$(ask "Имя ВМ" "${VM_NAME}")
  MEMORY_MB=$(ask "ОЗУ (МБ)" "${MEMORY_MB}")
  CORES=$(ask "Ядра CPU" "${CORES}")
  CPU_TYPE=$(ask "Тип CPU" "${CPU_TYPE}")
  BRIDGE=$(ask "Сетевой мост" "${BRIDGE}")
  STORAGE=$(ask "Хранилище диска" "${STORAGE}")
  CI_USER=$(ask "Пользователь cloud-init" "${CI_USER}")
  IPCONFIG0=$(ask "IP (ip=dhcp или ip=ADDR/MASK,gw=GW)" "${IPCONFIG0}")
  DISK_RESIZE=$(ask "Увеличение диска" "${DISK_RESIZE}")
  NAMESERVER=$(ask "DNS (пусто — оставить DHCP)" "")
  SSH_KEYFILE=$(ask "Путь к публичному SSH-ключу (пусто — пропустить)" "")
  read -r -s -p "Пароль cloud-init (пусто — не задавать): " CI_PASSWORD || die "Ввод прерван"
  echo ""
}

menu() {
  local choice=""
  while true; do
    echo ""
    echo "Proxmox Cloud-Init Template Creator"
    echo "-----------------------------------"
    echo "1) Ubuntu 24.04 со значениями по умолчанию"
    echo "2) Выбрать образ и параметры"
    echo "3) Выход"
    echo ""
    read -r -p "Выберите вариант: " choice || die "Ввод прерван"
    case "${choice}" in
      1) set_os_params 1; return ;;
      2) interactive_config; return ;;
      3) exit 0 ;;
      *) echo "Введите 1, 2 или 3." ;;
    esac
  done
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h) SHOW_HELP=1; shift ;;
      --default) OS_CHOICE=1; ASSUME_YES=1; shift ;;
      --yes|-y) ASSUME_YES=1; shift ;;
      --os)
        [[ $# -ge 2 ]] || die "--os требует значение"
        OS_CHOICE=$2; shift 2 ;;
      --vmid)
        [[ $# -ge 2 ]] || die "--vmid требует значение"
        VMID=$2; shift 2 ;;
      --name)
        [[ $# -ge 2 ]] || die "--name требует значение"
        VM_NAME=$2; shift 2 ;;
      --memory)
        [[ $# -ge 2 ]] || die "--memory требует значение"
        MEMORY_MB=$2; shift 2 ;;
      --cores)
        [[ $# -ge 2 ]] || die "--cores требует значение"
        CORES=$2; shift 2 ;;
      --cpu)
        [[ $# -ge 2 ]] || die "--cpu требует значение"
        CPU_TYPE=$2; shift 2 ;;
      --bridge)
        [[ $# -ge 2 ]] || die "--bridge требует значение"
        BRIDGE=$2; shift 2 ;;
      --storage)
        [[ $# -ge 2 ]] || die "--storage требует значение"
        STORAGE=$2; shift 2 ;;
      --snippet-storage)
        [[ $# -ge 2 ]] || die "--snippet-storage требует значение"
        SNIPPET_STORAGE=$2; shift 2 ;;
      --user)
        [[ $# -ge 2 ]] || die "--user требует значение"
        CI_USER=$2; shift 2 ;;
      --ipconfig)
        [[ $# -ge 2 ]] || die "--ipconfig требует значение"
        IPCONFIG0=$2; shift 2 ;;
      --resize)
        [[ $# -ge 2 ]] || die "--resize требует значение"
        DISK_RESIZE=$2; shift 2 ;;
      --ssh-key)
        [[ $# -ge 2 ]] || die "--ssh-key требует значение"
        SSH_KEYFILE=$2; shift 2 ;;
      --nameserver)
        [[ $# -ge 2 ]] || die "--nameserver требует значение"
        NAMESERVER=$2; shift 2 ;;
      *)
        die "Неизвестный аргумент: $1 (см. --help)"
        ;;
    esac
  done
}

validate_config() {
  [[ -n "${IMG_URL}" ]] || die "Не выбран образ"
  if ! [[ "${VMID}" =~ ^[0-9]+$ ]] || (( VMID < 100 || VMID > 999999999 )); then
    die "VMID должен быть числом от 100 до 999999999"
  fi
  if ! [[ "${MEMORY_MB}" =~ ^[0-9]+$ ]] || (( MEMORY_MB < 512 || MEMORY_MB > 1048576 )); then
    die "Память: число от 512 до 1048576 МБ"
  fi
  if ! [[ "${CORES}" =~ ^[0-9]+$ ]] || (( CORES < 1 || CORES > 256 )); then
    die "Ядра: число от 1 до 256"
  fi
  [[ "${DISK_RESIZE}" =~ ^\+?[0-9]+[KMGT]$ ]] || die "Размер диска: например +10G"
  [[ "${IPCONFIG0}" =~ ^ip= ]] || die "IP должен начинаться с ip="
  [[ "${VM_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] || die "Некорректное имя ВМ"
  [[ "${CI_USER}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Некорректное имя пользователя"
  [[ "${CPU_TYPE}" =~ ^[A-Za-z0-9,_+.-]+$ ]] || die "Некорректный тип CPU"
  [[ "${BRIDGE}" =~ ^[A-Za-z0-9._-]+$ ]] || die "Некорректное имя моста"
  [[ "${STORAGE}" =~ ^[A-Za-z0-9._-]+$ ]] || die "Некорректное хранилище"
  [[ "${SNIPPET_STORAGE}" =~ ^[A-Za-z0-9._-]+$ ]] || die "Некорректное хранилище сниппетов"
  [[ -d "/sys/class/net/${BRIDGE}/bridge" ]] || die "Мост не найден: ${BRIDGE}"
  if [[ -n "${NAMESERVER}" && ! "${NAMESERVER}" =~ ^[0-9A-Fa-f.:\ ]+$ ]]; then
    die "Некорректный DNS"
  fi
  if [[ -n "${SSH_KEYFILE}" ]]; then
    [[ -f "${SSH_KEYFILE}" ]] || die "SSH-ключ не найден: ${SSH_KEYFILE}"
    if grep -q "PRIVATE KEY" "${SSH_KEYFILE}"; then
      die "Нужен публичный ключ (.pub), не приватный"
    fi
    if ! grep -qE '^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp256) ' "${SSH_KEYFILE}"; then
      die "Файл не похож на публичный SSH-ключ"
    fi
  fi
}

require_disk_storage() {
  local section content status
  section=$(storage_section "${STORAGE}")
  [[ -n "${section}" ]] || die "Хранилище не найдено: ${STORAGE}"
  content=$(printf '%s\n' "${section}" | awk '$1=="content" { print $2; exit }')
  [[ "${content}" == *images* ]] || die "У ${STORAGE} нет content type images"
  status=$(pvesm status --storage "${STORAGE}" | awk 'NR==2 { print $3 }')
  [[ "${status}" == "active" ]] || die "Хранилище ${STORAGE} не в состоянии active"
}

check_snippet_storage() {
  local section content path
  section=$(storage_section "${SNIPPET_STORAGE}")
  [[ -n "${section}" ]] || die "Хранилище сниппетов не найдено: ${SNIPPET_STORAGE}"
  content=$(printf '%s\n' "${section}" | awk '$1=="content" { print $2; exit }')
  path=$(printf '%s\n' "${section}" | awk '$1=="path" { print $2; exit }')
  if [[ "${content}" != *snippets* || -z "${path}" ]]; then
    die "У ${SNIPPET_STORAGE} нет snippets. Datacenter → Storage → ${SNIPPET_STORAGE} → Content → включите Snippets."
  fi
  SNIPPET_DIR="${path%/}/snippets"
}

write_snippet() {
  mkdir -p "${SNIPPET_DIR}"
  # First line must stay #cloud-config. Shared by every template from this script.
  printf '%s\n' \
    '#cloud-config' \
    '# qemu-guest-agent is installed on first boot, on the real virtio disk.' \
    'package_update: true' \
    'package_upgrade: false' \
    'package_reboot_if_required: false' \
    'packages:' \
    '  - qemu-guest-agent' \
    'runcmd:' \
    '  - systemctl enable --now qemu-guest-agent' \
    > "${SNIPPET_DIR}/${SNIPPET_NAME}"
  chmod 644 "${SNIPPET_DIR}/${SNIPPET_NAME}"
}

print_plan() {
  local key_label="нет"
  local dns_label="из DHCP"
  local pass_label="нет"
  [[ -z "${SSH_KEYFILE}" ]] || key_label="${SSH_KEYFILE}"
  [[ -z "${NAMESERVER}" ]] || dns_label="${NAMESERVER}"
  [[ -z "${CI_PASSWORD}" ]] || pass_label="задан"
  cat <<EOF

Будет создан шаблон:
  VMID:       ${VMID}
  Имя:        ${VM_NAME}
  Образ:      ${IMG_URL}
  ОЗУ/CPU:    ${MEMORY_MB} МБ, ${CORES} ядер, ${CPU_TYPE}
  Диск:       ${STORAGE}, расширение ${DISK_RESIZE}
  Сеть:       ${NET_MODEL}, мост ${BRIDGE}, ${IPCONFIG0}
  DNS:        ${dns_label}
  Пользователь: ${CI_USER}
  SSH-ключ:   ${key_label}
  Пароль:     ${pass_label}
  Сниппет:    ${SNIPPET_STORAGE}:snippets/${SNIPPET_NAME}

EOF
}

confirm() {
  local answer=""
  read -r -p "Создать шаблон? [y/N]: " answer || die "Ввод прерван"
  case "${answer}" in
    y|Y|yes|Yes|д|Д) return 0 ;;
    *) return 1 ;;
  esac
}

# Drops image leftovers when a previous run died with SIGKILL or a host panic.
reap_stale_workdirs() {
  local dir pid cmdline marker
  marker=$(basename "$0")
  shopt -s nullglob
  for dir in /var/tmp/ci-template-*; do
    [[ -d "${dir}" ]] || continue
    pid=""
    [[ -f "${dir}/pid" ]] && pid=$(cat "${dir}/pid" 2>/dev/null || true)
    if [[ -n "${pid}" && -r "/proc/${pid}/cmdline" ]]; then
      cmdline=$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)
      if [[ "${cmdline}" == *"${marker}"* ]]; then
        continue
      fi
    fi
    printf 'Удаление осиротевшего каталога %s\n' "${dir}"
    rm -rf "${dir}"
  done
  # Previous version of this script downloaded straight into /tmp.
  rm -f /tmp/cloud-img-*.img
  shopt -u nullglob
}

verify_checksum() {
  local url=$1
  local file=$2
  local sums_url="${url%/*}/SHA256SUMS"
  local sums_file name expected actual
  sums_file=$(mktemp)
  if ! wget -q --timeout=60 --tries=3 -O "${sums_file}" "${sums_url}"; then
    rm -f "${sums_file}"
    echo "Предупреждение: SHA256SUMS недоступен, проверка суммы пропущена."
    return 0
  fi
  name=$(basename "${url}")
  expected=$(awk -v n="${name}" '
    {
      f=$2
      sub(/\r/, "", f)
      sub(/^\*/, "", f)
      if (f == n) { print $1; exit }
    }
  ' "${sums_file}")
  rm -f "${sums_file}"
  [[ -n "${expected}" ]] || die "Файл ${name} не найден в SHA256SUMS"
  actual=$(sha256sum "${file}" | awk '{ print $1 }')
  [[ "${actual}" == "${expected}" ]] || die "Контрольная сумма не совпала"
  echo "Контрольная сумма совпала."
}

download_image() {
  reap_stale_workdirs
  WORKDIR=$(mktemp -d /var/tmp/ci-template-XXXXXX)
  printf '%s\n' "$$" > "${WORKDIR}/pid"
  local img="${WORKDIR}/disk.img"
  echo "Загрузка образа..."
  wget --timeout=60 --tries=3 -O "${img}" "${IMG_URL}"
  verify_checksum "${IMG_URL}" "${img}"
  qemu-img info "${img}" >/dev/null 2>&1 || die "Скачанный файл не является образом диска"
  printf '%s\n' "${img}" > "${WORKDIR}/image-path"
}

imported_image_path() {
  cat "${WORKDIR}/image-path"
}

# Proxmox prints either of these lines:
#   unused0: successfully imported disk 'local-lvm:vm-8000-disk-0'
#   successfully imported disk as 'local-lvm:vm-8000-disk-0'
parse_imported_volid() {
  local import_log=$1
  printf '%s\n' "${import_log}" | awk -F"'" '/successfully imported disk/ { print $2; exit }'
}

create_vm() {
  local img vol import_log
  img=$(imported_image_path)

  echo "Создание ВМ ${VMID} (${VM_NAME})..."
  qm create "${VMID}" \
    --name "${VM_NAME}" \
    --memory "${MEMORY_MB}" \
    --cores "${CORES}" \
    --cpu "${CPU_TYPE}" \
    --ostype l26 \
    --net0 "${NET_MODEL},bridge=${BRIDGE}" \
    --scsihw virtio-scsi-single \
    --agent "enabled=1,fstrim_cloned_disks=1" \
    --serial0 socket \
    --vga serial0 \
    --rng0 source=/dev/urandom
  VM_CREATED=1

  echo "Импорт диска в ${STORAGE}..."
  import_log=$(qm importdisk "${VMID}" "${img}" "${STORAGE}" 2>&1) || {
    printf '%s\n' "${import_log}" >&2
    die "Импорт диска не удался"
  }
  printf '%s\n' "${import_log}"
  vol=$(parse_imported_volid "${import_log}")
  [[ -n "${vol}" ]] || die "Не удалось разобрать имя тома после importdisk"

  echo "Удаление временного образа..."
  rm -rf "${WORKDIR}"
  WORKDIR=""

  # Filesystem growth happens in the guest (cloud-init growpart) on first boot.
  qm set "${VMID}" \
    --scsi0 "${vol},iothread=1,discard=on,ssd=1" \
    --ide2 "${STORAGE}:cloudinit" \
    --boot order=scsi0 \
    --citype nocloud \
    --ciuser "${CI_USER}" \
    --ipconfig0 "${IPCONFIG0}" \
    --cicustom "vendor=${SNIPPET_STORAGE}:snippets/${SNIPPET_NAME}" \
    --description "Cloud-init template ${VM_NAME}. qemu-guest-agent installs on first boot."

  if [[ -n "${SSH_KEYFILE}" ]]; then
    qm set "${VMID}" --sshkeys "${SSH_KEYFILE}"
  fi
  if [[ -n "${NAMESERVER}" ]]; then
    qm set "${VMID}" --nameserver "${NAMESERVER}"
  fi
  if [[ -n "${CI_PASSWORD}" ]]; then
    qm set "${VMID}" --cipassword "${CI_PASSWORD}"
  fi

  echo "Расширение диска на ${DISK_RESIZE}..."
  qm resize "${VMID}" scsi0 "${DISK_RESIZE}"

  echo "Конвертация в шаблон..."
  qm template "${VMID}"
  TEMPLATE_READY=1

  cat <<EOF

Шаблон создан.
  VMID: ${VMID}
  Имя:  ${VM_NAME}
  Диск: ${vol}
  Пользователь: ${CI_USER}
  Консоль: serial (в UI Proxmox)
  QEMU Guest Agent: включён в конфиге ВМ.
    Пакет ставится на первой загрузке клона, клону нужен интернет.

Клон:
  qm clone ${VMID} <NEW_ID> --name <name>
  qm start <NEW_ID>
  qm agent <NEW_ID> ping
EOF
  if [[ -z "${SSH_KEYFILE}" && -z "${CI_PASSWORD}" ]]; then
    echo "  Ключ на шаблоне не задан. Перед стартом: qm set <NEW_ID> --sshkeys <file.pub>"
  fi
}

main() {
  parse_args "$@"
  if [[ "${SHOW_HELP}" -eq 1 ]]; then
    usage
    exit 0
  fi

  [[ "${EUID}" -eq 0 ]] || die "Запустите скрипт от root на узле Proxmox"
  require_cmd qm
  require_cmd pvesm
  require_cmd wget
  require_cmd qemu-img
  require_cmd sha256sum
  [[ -f /etc/pve/storage.cfg ]] || die "Нет /etc/pve/storage.cfg — это не узел Proxmox?"

  if [[ -z "${OS_CHOICE}" ]]; then
    [[ -t 0 ]] || die "Нет TTY. Укажите --default или --os N --yes"
    menu
  else
    set_os_params "${OS_CHOICE}"
  fi

  validate_config
  require_disk_storage
  check_snippet_storage
  if qm status "${VMID}" >/dev/null 2>&1; then
    die "VMID ${VMID} уже занят. Освободите его: qm destroy ${VMID} --purge"
  fi

  print_plan
  if [[ "${ASSUME_YES}" -eq 0 ]]; then
    [[ -t 0 ]] || die "Добавьте --yes для запуска без подтверждения"
    confirm || exit 0
  fi

  write_snippet
  download_image
  create_vm
}

main "$@"
