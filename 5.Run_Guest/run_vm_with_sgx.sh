#!/bin/bash

# Script: run_td.sh
# Description: Launch TDX (Trust Domain Extensions) virtual machine

set -euo pipefail  # Exit on error, undefined variables, and pipe failures

# Define path variables
QEMU_BINARY="/home/yunge/teeio-staging-kernel/qemu-v10.1.0-rc0/build/qemu-system-x86_64"
OVMF_BIOS="/home/yunge/teeio-staging-kernel/tdvf-edk2-stable20240801/Build/IntelTdx/RELEASE_GCC5/FV/OVMF.fd"
DISK_IMAGE="/home/yunge/td-ubunt-1.qcow2"
 

# Boot mode flag. 1: TDVM; 0: regular VM
TDX_MODE="${TDX_MODE:-0}"

# Define TDVM parameters
MEMORY_SIZE="${MEMORY_SIZE:-16G}"
CPU_CORES="${CPU_CORES:-8}"
# 1: print VM boot logs to terminal; 0: disable live boot log printing
SHOW_BOOT_LOG="${SHOW_BOOT_LOG:-1}"
# 1: enable SGX support; 0: disable SGX support
ENABLE_SGX="${ENABLE_SGX:-0}"
# EPC size for SGX when ENABLE_SGX=1, e.g. 64M, 128M, 1G
SGX_EPC_SIZE="${SGX_EPC_SIZE:-4G}"
# Host SSH forward port for guest 22
HOST_SSH_PORT="${HOST_SSH_PORT:-10022}"

# Host resource variables (will be populated by get_host_resources)
HOST_MEMORY_GB=""
HOST_CPU_CORES=""

# Function to check if required files exist
check_file() {
    local file_path="$1"
    local file_desc="$2"
    
    if [[ ! -f "${file_path}" ]]; then
        echo "Error: ${file_desc} does not exist: ${file_path}" >&2
        echo "Please check the path and ensure the file exists." >&2
        return 1
    fi
    return 0
}

# Function to get host physical resources
get_host_resources() {
    # Get total physical memory in GB
    local total_mem_kb
    total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    HOST_MEMORY_GB=$((total_mem_kb / 1024 / 1024))
    
    # Get physical CPU cores (not including hyperthreading)
    HOST_CPU_CORES=$(lscpu | grep "Core(s) per socket:" | awk '{print $4}')
    local sockets
    sockets=$(lscpu | grep "Socket(s):" | awk '{print $2}')
    HOST_CPU_CORES=$((HOST_CPU_CORES * sockets))
}

# Function to convert memory size to GB for comparison
memory_to_gb() {
    local mem_size="$1"
    if [[ "${mem_size}" =~ ^([0-9]+)M$ ]]; then
        echo $(( ${BASH_REMATCH[1]} / 1024 ))
    elif [[ "${mem_size}" =~ ^([0-9]+)G$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "0"
    fi
}

# Function to validate VM parameters
validate_parameters() {
    # Get host resources first
    get_host_resources
    
    # Check if memory size is valid format
    if [[ ! "${MEMORY_SIZE}" =~ ^[0-9]+[MG]$ ]]; then
        echo "Error: Invalid memory size format: ${MEMORY_SIZE}" >&2
        echo "Expected format: <number>M or <number>G (e.g., 4G, 512M)" >&2
        exit 1
    fi
    
    # Check if CPU cores is a positive integer
    if [[ ! "${CPU_CORES}" =~ ^[1-9][0-9]*$ ]]; then
        echo "Error: Invalid CPU cores: ${CPU_CORES}" >&2
        echo "Expected: positive integer" >&2
        exit 1
    fi
    
    # Check memory against host capacity
    local vm_memory_gb
    vm_memory_gb=$(memory_to_gb "${MEMORY_SIZE}")
    if [[ ${vm_memory_gb} -gt ${HOST_MEMORY_GB} ]]; then
        echo "Error: VM memory (${MEMORY_SIZE}) exceeds host physical memory (${HOST_MEMORY_GB}G)" >&2
        echo "Please reduce the memory size to fit within available physical memory" >&2
        exit 1
    fi
    
    # Check CPU cores against host capacity
    if [[ ${CPU_CORES} -gt ${HOST_CPU_CORES} ]]; then
        echo "Error: VM CPU cores (${CPU_CORES}) exceeds host physical cores (${HOST_CPU_CORES})" >&2
        echo "Please reduce the CPU cores to fit within available physical cores" >&2
        exit 1
    fi

    # Validate SGX switch
    if [[ ! "${ENABLE_SGX}" =~ ^[01]$ ]]; then
        echo "Error: Invalid ENABLE_SGX: ${ENABLE_SGX}" >&2
        echo "Expected: 0 or 1" >&2
        exit 1
    fi

    # Validate SGX EPC size format when SGX is enabled
    if [[ "${ENABLE_SGX}" == "1" ]] && [[ ! "${SGX_EPC_SIZE}" =~ ^[0-9]+[MG]$ ]]; then
        echo "Error: Invalid SGX EPC size format: ${SGX_EPC_SIZE}" >&2
        echo "Expected format: <number>M or <number>G (e.g., 64M, 1G)" >&2
        exit 1
    fi

    if [[ ! "${HOST_SSH_PORT}" =~ ^[1-9][0-9]*$ ]] || [[ "${HOST_SSH_PORT}" -gt 65535 ]]; then
        echo "Error: Invalid HOST_SSH_PORT: ${HOST_SSH_PORT}" >&2
        echo "Expected: integer between 1 and 65535" >&2
        exit 1
    fi
    
    # Display resource allocation info
    echo "Host Resources: ${HOST_MEMORY_GB}G RAM, ${HOST_CPU_CORES} CPU cores"
    echo "VM Allocation: ${MEMORY_SIZE} RAM, ${CPU_CORES} CPU cores"
}

# Main execution starts here
main() {
    echo "=== TDX Virtual Machine Launcher ==="
    echo "Checking required files..."
    
    # Validate parameters first
    validate_parameters
    
    # Check QEMU executable
    if ! check_file "${QEMU_BINARY}" "QEMU executable"; then
        echo "Hint: Please ensure QEMU is properly compiled and located at the specified path" >&2
        exit 1
    fi
    
    # Check OVMF BIOS file
    if ! check_file "${OVMF_BIOS}" "OVMF BIOS file"; then
        echo "Hint: Please ensure OVMF is properly compiled and located at the specified path" >&2
        exit 1
    fi
    
    # Check disk image file
    if ! check_file "${DISK_IMAGE}" "Disk image file"; then
        echo "Hint: Please ensure the disk image file exists at the specified path" >&2
        echo "      You can download RHEL 9.6 image from the corresponding distribution website" >&2
        exit 1
    fi
    
    echo "All required files check passed!"
    if [[ "${TDX_MODE:-1}" == "1" ]]; then
        echo "TDVM (TDX Virtual Machine) will be started..."
    else
        echo "Regular VM (non-TDX) will be started..."
    fi
    echo "Memory: ${MEMORY_SIZE}, CPU Cores: ${CPU_CORES}"
    echo "SSH Forward: 127.0.0.1:${HOST_SSH_PORT} -> guest:22"
    if [[ "${SHOW_BOOT_LOG:-1}" == "1" ]]; then
        echo "Boot Log: enabled (live console + td-guest.log)"
    else
        echo "Boot Log: disabled (QEMU will run in background)"
    fi
    if [[ "${ENABLE_SGX}" == "1" ]] && [[ "${TDX_MODE:-1}" != "1" ]]; then
        echo "SGX: enabled (EPC size: ${SGX_EPC_SIZE})"
    elif [[ "${ENABLE_SGX}" == "1" ]] && [[ "${TDX_MODE:-1}" == "1" ]]; then
        echo "SGX: requested, but ignored in TDX mode"
    else
        echo "SGX: disabled"
    fi
    echo "========================================"
    
    # Launch QEMU with TDX configuration
    # Check if TDX mode is requested via an environment variable or argument (default: TDX enabled)
    local console_args=()
    local daemon_args=()
    local sgx_args=()
    local numa_args=()
    local cpu_arg="host"
    local machine_regular="q35,hpet=off,kernel_irqchip=split"
    local machine_tdx="q35,hpet=off,kernel_irqchip=split,confidential-guest-support=tdx"

    if [[ "${ENABLE_SGX}" == "1" ]] && [[ "${TDX_MODE:-1}" != "1" ]]; then
        cpu_arg="host,+sgx,+sgxlc"
        sgx_args=(
            -object "memory-backend-ram,id=ram0,size=${MEMORY_SIZE}"
            -object "memory-backend-epc,id=epc0,size=${SGX_EPC_SIZE}"
        )
        machine_regular+=" ,sgx-epc.0.memdev=epc0,sgx-epc.0.node=0"
        machine_regular="${machine_regular// ,/,}"
        numa_args=(
            -numa "node,nodeid=0,memdev=ram0"
        )
    fi

    if [[ "${SHOW_BOOT_LOG:-1}" == "1" ]]; then
        console_args=(
            -chardev stdio,id=mux,mux=on,logfile=td-guest.log
            -device virtio-serial,romfile=
            -device virtconsole,chardev=mux
            -monitor chardev:mux
            -serial chardev:mux
        )
        daemon_args=()
    else
        console_args=(
            -monitor none
            -serial none
        )
        daemon_args=(
            -daemonize
        )
    fi

    if [[ "${TDX_MODE:-1}" == "1" ]]; then
        echo "Launching in TDX (confidential VM) mode..."
        exec "${QEMU_BINARY}" \
            -accel kvm \
            -cpu "${cpu_arg}" \
            -m "${MEMORY_SIZE}" \
            -smp "${CPU_CORES}" \
            -object "memory-backend-ram,id=mem0,size=${MEMORY_SIZE}" \
            -object '{"qom-type":"tdx-guest","id":"tdx","quote-generation-socket":{"type": "vsock", "cid":"2","port":"4050"}}' \
            -machine "${machine_tdx}" \
            -bios "${OVMF_BIOS}" \
            -nographic \
            -nodefaults \
            -vga none \
            -netdev user,id=nic0_td,hostfwd=tcp::${HOST_SSH_PORT}-:22 \
            -device virtio-net-pci,netdev=nic0_td \
 	        -drive "file=${DISK_IMAGE},if=none,id=virtio-disk0" \
            -device virtio-blk-pci,drive=virtio-disk0 \
            -pidfile /tmp/tdx-demo-td-pid.pid \
            -device vhost-vsock-pci,guest-cid=3 \
            "${sgx_args[@]}" \
            "${daemon_args[@]}" \
            "${console_args[@]}"
    else
        echo "Launching in regular VM mode..."
        exec "${QEMU_BINARY}" \
            -accel kvm \
            -cpu "${cpu_arg}" \
            -m "${MEMORY_SIZE}" \
            -smp "${CPU_CORES}" \
            -machine "${machine_regular}" \
            -bios "${OVMF_BIOS}" \
            -nographic \
            -nodefaults \
            -vga none \
            -netdev user,id=nic0_td,hostfwd=tcp::${HOST_SSH_PORT}-:22 \
            -device virtio-net-pci,netdev=nic0_td \
            -drive "file=${DISK_IMAGE},if=none,id=virtio-disk0" \
            -device virtio-blk-pci,drive=virtio-disk0 \
            -pidfile /tmp/tdx-demo-td-pid.pid \
            -device vhost-vsock-pci,guest-cid=3 \
            "${sgx_args[@]}" \
            "${numa_args[@]}" \
            "${daemon_args[@]}" \
            "${console_args[@]}"
    fi
}

# Execute main function
main "$@"
