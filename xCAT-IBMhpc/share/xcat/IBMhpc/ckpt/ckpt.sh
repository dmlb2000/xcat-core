#! /bin/bash

# Checkpoint/Restart related environment setup

# virtualized pts support
rm -f /dev/ptmx
ln -s /dev/pts/ptmx /dev/ptmx
chmod 666 /dev/ptmx

# unlinked file support
for fs in ext3 ext4 nfs gpfs tmpfs; do
    FSROOTS=$(grep " $fs " /proc/mounts | cut -d ' ' -f 2)
    if [ "$FSROOTS" ]; then
        for rootfs in $FSROOTS; do
            if [ -w $rootfs ]; then
                CKPTDIR="$rootfs/lost+found"

                [ -e $CKPTDIR ] && [ ! -d $CKPTDIR ] && rm -f $CKPTDIR

                if [ ! -e $CKPTDIR ]; then
                    mkdir -p $CKPTDIR
                    [ "$?" -eq "0" ] && echo "made dir $CKPTDIR"
                fi
            fi
        done
    fi
done

