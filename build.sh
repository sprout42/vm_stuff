#!/bin/bash -e
#
# Creates a headless VM with libvirt allowing custom scripts to be run during
# setup to create VMs in a way that I like so they have the standardized tools
# I like my VMs to have.

# Script variable defaults

# Default to the user KVM/QEMU session
#SESSION="qemu:///session"

# Default RAM and CPUs
RAM="4096"
CPUS="2"
SIZE="20G"
GRAPHICS="none"
USB=( )

# Default package list
PKGS="vim,tmux,git,curl,wget,cargo"

# Don't resume installs by default
RESUME="no"


usage() {
    if [ $# -eq 1 ]; then
        ret=$1
    else
        ret=0
    fi

cat << EOF
usage: $0 [-h] [-m <ram>] [-c <cpus>] [-s <disk size>] [-g <graphics opt>]
          [-u <vid1:pid1,vid2:pid2>] [-r <extra install script>]
          [-i <pkg1,pkg2>] [--session <qemu session uri>] [--resume] name dist

Standardized VM build script

positional arguments:
  name          VM Name
  dist          Linux distribution to build the VM from
                run "virt-builder -l" to get valid options

optional arguments:
  -h, --help    Show this help message and exit
  -m|--memory   RAM to give the VM (default: $RAM)
  -c|--cpus     VCPUs to give the VM (default: $CPUS)
  -s|--size     Size of qcow2 image to create (default: $SIZE)
  -g|--graphics VM graphics option (default: $GRAPHICS)
  -u|--usb      one or more USB VID:PID devices to attach to the VM
  -r|--run      Additional install script to run
  -i|--install  Default packages to install on the target VM when building
                (default: $PKGS)
  --session     LIBVIRT session to connect to for installing the VM. Can also
                use the standard LIBVIRT_DEFAULT_URI environment variable
  --resume      Resume a failed install (will skip steps if the expected
                output file already exists)
EOF
    exit $ret
}

# Get a list of the valid virt-builder dist values
# TODO: commenting this out, it takes too long)
#valid_dists=( $(virt-builder -l --list-format json | jq -r '.templates[]."os-version"') )

while [ "$#" -gt 0 ]; do
    case $1 in
        -m|--memory)
            if [ "$#" -ge "2" ] && [ "${2:0:1}" != '-' ]; then
                if [[ $2 =~ ^[0-9]+$ ]]; then
                    RAM=$2
                    shift
                else
                    echo "ERROR: invalid $1 argument: $2"
                    usage 1
                fi
            else
                echo "ERROR: $1 param requires argument"
                usage 1
            fi
            shift
            ;;
        -c|--cpu|--cpus)
            if [ "$#" -ge "2" ] && [ "${2:0:1}" != '-' ]; then
                if [[ $2 =~ ^[0-9]+$ ]]; then
                    CPUS=$2
                    shift
                else
                    echo "ERROR: invalid $1 argument: $2"
                    usage 1
                fi
            else
                echo "ERROR: $1 param requires argument"
                usage 1
            fi
            shift
            ;;
        -s|--size)
            if [ "$#" -ge "2" ] && [ "${2:0:1}" != '-' ]; then
                SIZE=$2
                shift
            else
                echo "ERROR: $1 param requires argument"
                usage 1
            fi
            shift
            ;;
        -g|--graphics)
            if [ "$#" -ge "2" ] && [ "${2:0:1}" != '-' ]; then
                GRAPHICS=$2
                shift
            else
                echo "ERROR: $1 param requires argument"
                usage 1
            fi
            shift
            ;;
        -u|--usb)
            if [ "$#" -ge "2" ] && [ "${2:0:1}" != '-' ]; then
                # Multiple devices are allowed so convert from a comma separated
                # list into multiple 0xVID:0xPID strings that can be passed
                # straight to the virt-install --host-device param
                USB=( $(echo "$2" | sed -n -e "s/\([0-9A-Fa-f]\{4\}\):\([0-9A-Fa-f]\{4\}\),\?/0x\1:0x\2 /gp") )
                shift
            else
                echo "ERROR: $1 param requires argument"
                usage 1
            fi
            shift
            ;;
        -r|--run)
            if [ "$#" -ge "2" ] && [ "${2:0:1}" != '-' ]; then
                if [ -f "$2" ]; then
                    SYSPREP_SCRIPT=$2
                    shift
                else
                    echo "ERROR: $2 is not a valid file"
                    usage 1
                fi
            else
                echo "ERROR: $1 param requires argument"
                usage 1
            fi
            shift
            ;;
        -i|--install)
            if [ "$#" -ge "2" ] && [ "${2:0:1}" != '-' ]; then
                PKGS=$2
                shift
            else
                echo "ERROR: $1 param requires argument"
                usage 1
            fi
            shift
            ;;
        --session)
            if [ "$#" -ge "2" ] && [ "${2:0:1}" != '-' ]; then
                CONNECT=$2
                shift
            else
                echo "ERROR: $1 param requires argument"
                usage 1
            fi
            shift
            ;;
        --resume)
            RESUME="yes"
            shift
            ;;
        -?|-h|--help)
            usage 0
            ;;
        *)
            #if [[ " ${valid_dists[@]} " =~ " $2 " ]]; then
            #    # If this is a valid virt-builder dist assume it is the dist to
            #    # use to build the VM
            #    if [ -z "$DIST" ]; then
            #        DIST=$2
            #    else
            #        echo "ERROR: multiple dist arguments detected: $DIST, $2" 1>&2
            #        usage 1
            #    fi
            #else
            #    if [ -z "$NAME" ]; then
            #        DIST=$2
            #    else
            #        echo "ERROR: multiple name arguments detected: $NAME, $2" 1>&2
            #        usage 1
            #    fi
            #fi

            # First arg is name, second is dist
            if [ -z "$NAME" ]; then
                NAME=$1
                shift
            elif [ -z "$DIST" ]; then
                DIST=$1
                shift
            else
                echo "ERROR: unknown argument $1" 1>&2
                usage 1
            fi
            ;;
    esac
done

# If DIST or NAME is not defined we can't build a VM
if [ -z "$DIST" ] && [ -z "$NAME" ]; then
    echo "ERROR: name and dist arguments not supplied" 1>&2
    usage 1
elif [ -z "$DIST" ]; then
    echo "ERROR: dist argument not supplied" 1>&2
    usage 1
elif [ -z "$NAME" ]; then
    echo "ERROR: name argument not supplied" 1>&2
    usage 1
fi

# Convert the virt-builder name to one that is understood by the rest of the
# libvirt tools
LIBVIRT_DIST=$(echo $DIST | tr -d '-')

DOMFILENAME="$NAME-$LIBVIRT_DIST"
DOMIMAGE="$DOMFILENAME.qcow2"
DOMXML="$DOMFILENAME.xml"

build_vm() {
    # Create script to add the default user (and the non-apt installable tools
    # I like)
    cat <<CREATE_USER_EOF > create_user.sh
#!/bin/bash -e
useradd -G sudo,cdrom,dialout,plugdev -U -m -s /bin/bash -p \$(openssl passwd -1 "$NAME") "$NAME"

cat <<'EOF' >> "/home/$NAME/.profile"

res() {

  old=\$(stty -g)
  stty raw -echo min 0 time 5

  printf '\\0337\\033[r\\033[999;999H\\033[6n\\0338' > /dev/tty
  IFS='[;R' read -r _ rows cols _ < /dev/tty

  stty "\$old"

  # echo "cols:\$cols"
  # echo "rows:\$rows"
  stty cols "\$cols" rows "\$rows"
}
[ "\$(tty)" == "/dev/ttyS0" ] && res
EOF

su --login "$NAME" -c "mkdir -p /home/$NAME/.local/bin"

su --login "$NAME" -c "git clone --depth 1 https://github.com/junegunn/fzf ~/.fzf"
su --login "$NAME" -c "~/.fzf/install --all --key-bindings --completion --update-rc"
su --login "$NAME" -c "cargo install ripgrep"

cat <<'EOF' >> "/home/$NAME/.bashrc"

set -o vi
export PATH="\$PATH:\$HOME/.local/bin"

# Add rust tools to the path
export PATH="\$PATH:\$HOME/.cargo/bin"
EOF
CREATE_USER_EOF

    echo "Building qcow2 image: $DOMIMAGE"

    # If the current kernel is not readable by the current user attempt to chmod
    # it temporarily
    kernel="/boot/vmlinuz-$(uname -r)"
    changed_kernel_perms="no"
    if [ ! -r "$kernel" ]; then
        changed_kernel_perms="yes"
        echo "Temporarily making $kernel readable for virt-builder"
        (
            set -x
            sudo chmod u+r "$kernel"
        )
    fi

    # If this is the ubuntu-16.04 image then a few more things are necessary to
    # get console output during boot
    if [ "$DIST" == "ubuntu-16.04" ]; then
        (
            set -x
            virt-builder \
                "$DIST" \
                --output "$DOMIMAGE" \
                --format=qcow2 \
                --size $SIZE \
                --hostname="$NAME" \
                --network \
                --timezone=America/New_York \
                --edit '/etc/default/grub:s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=ttyS0,115200n8"/' \
                --run-command 'update-grub' \
                --run-command 'dpkg-reconfigure -fnoninteractive openssh-server' \
                --run-command 'update-locale LANG=en_US.UTF-8' \
                --update \
                --install "$PKGS" \
                --run-command 'systemctl enable serial-getty@ttyS0.service' \
                --run-command 'systemctl start serial-getty@ttyS0.service' \
                --edit '/lib/systemd/system/serial-getty@.service:s/^(\[Service\]\n)/\1Environment=TERM=xterm-256color\n/' \
                --run create_user.sh
        )
    else
        (
            set -x
            virt-builder \
                "$DIST" \
                --output "$DOMIMAGE" \
                --format=qcow2 \
                --size $SIZE \
                --hostname="$NAME" \
                --network \
                --timezone=America/New_York \
                --run-command 'dpkg-reconfigure -fnoninteractive openssh-server' \
                --run-command 'update-locale LANG=en_US.UTF-8' \
                --update \
                --install "$PKGS" \
                --run-command 'systemctl enable serial-getty@ttyS0.service' \
                --run-command 'systemctl start serial-getty@ttyS0.service' \
                --edit '/lib/systemd/system/serial-getty@.service:s/^(\[Service\]\n)/\1Environment=TERM=xterm-256color\n/' \
                --run create_user.sh
        )
    fi

    if [ "$changed_kernel_perms" == "yes" ]; then
        echo "Setting $kernel permissions back to normal"
        (
            set -x
            sudo chmod u-r "$kernel"
        )
    fi
}

run_custom_script() {
    # Now that the qcow image is created do any additional sysprep
    if [ ! -z "$SYSPREP_SCRIPT" ]; then
        echo "Running additional setup script $SYSPREP_SCRIPT"

        # Make sure to set the appropriate env variables so this script knows
        # the various filenames being used
        env NAME="$NAME" DIST="$DIST" DOMIMAGE="$DOMIMAGE" bash "$SYSPREP_SCRIPT"
    fi
}

create_vm_xml() {
    echo "Creating $NAME VM config: $DOMXML"

    install_opts="--import --name $NAME --memory $RAM --vcpus $CPUS --graphics $GRAPHICS --disk $DOMIMAGE,format=qcow2 --os-variant $LIBVIRT_DIST --network default --controller type=usb,model=qemu-xhci"

    if [ ! -z "$SESSION" ]; then
        install_opts="--connect $SESSION $install_opts"
    fi

    # User session does not work attaching USB devices at boot
    for dev in "${USB[@]}"; do
        install_opts="$install_opts --hostdev $dev"
    done

    (
        set -x
        virt-install $install_opts --print-xml > "$DOMXML"
    )
}

install_vm() {
    echo "Installing $DIST $NAME VM"
    virsh define "$DOMXML"
}

if [ -f "$DOMIMAGE" ]; then
    if [ "$RESUME" == "no" ]; then
        echo "Removing existing VM image $DOMIMAGE"
        (
            set -x
            rm "$DOMIMAGE"
        )
    else
        echo "$DOMIMAGE already exist, skipping build step"
    fi
fi

if [ ! -f "$DOMIMAGE" ]; then
    build_vm
fi

# A custom install script will have to do it's own checks
run_custom_script

if [ -f "$DOMXML" ]; then
    if [ "$RESUME" == "no" ]; then
        echo "Removing existing VM config $DOMXML"
        (
            set -x
            rm "$DOMXML"
        )
    else
        echo "$DOMXML already exist, skipping build step"
    fi
fi

if [ ! -f "$DOMXML" ]; then
    create_vm_xml
fi

if [ $(virsh domid $NAME > /dev/null 2>&1) ]; then if [ "$RESUME" == "no" ]; then
        echo "Undefining existing VM $DOMXML"
        (
            set -x
            virsh destroy "$NAME"
            virsh undefine "$NAME"
        )
        install_vm
    else
        echo "VM $NAME already created"
    fi
else
    install_vm
fi
