#!/usr/bin/env bash
# Source this script to set up the Synopsys tool environment for Lab 2:
#
#     source setup.sh          # bash
#     source env.cshrc         # tcsh (Apporto default workflow)
#
# Works on both the Apporto ECE Cad Lab and the ECE vault server by
# auto-detecting the tool installation. Safe to source repeatedly.

if [ -n "${BASH_SOURCE[0]}" ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "Please run 'source setup.sh' (not './setup.sh') so the environment sticks." >&2
    return 1 2>/dev/null || exit 1
fi

# ---------------------------------------------------------------- locate tools
if [ -d /usr/local2/synopsys ]; then
    # Apporto ECE Cad Lab
    VCS_HOME=$(ls -d /usr/local2/synopsys/vcs_* 2>/dev/null | sort | tail -1)
    VERDI_HOME=$(ls -d /usr/local2/synopsys/verdi_*/verdi/* 2>/dev/null | sort | tail -1)
    SYN_HOME=$(ls -d /usr/local2/synopsys/syn_* 2>/dev/null | sort | tail -1)
    export PDK_DIR="${PDK_DIR:-/usr/local2/cadence/NCSU/SRC/FreePDK45}"
elif [ -d /home/tools/synopsys ]; then
    # ECE vault server
    VCS_HOME=$(ls -d /home/tools/synopsys/vcs/*/ 2>/dev/null | sort | tail -1)
    VERDI_HOME=$(ls -d /home/tools/synopsys/verdi/*/ 2>/dev/null | sort | tail -1)
    SYN_HOME=$(ls -d /home/tools/synopsys/DC23/syn/*/ 2>/dev/null | sort | tail -1)
    VCS_HOME=${VCS_HOME%/}
    VERDI_HOME=${VERDI_HOME%/}
    SYN_HOME=${SYN_HOME%/}
    # The synthesis scripts expect $PDK_DIR/osu_soc/lib/files/gscl45nm.db.
    # Build a stable symlink farm with that layout for the local FreePDK.
    _FREEPDK_FILES=/mnt/vault0/PDKs/OSU_FreePDK/OSU_FreePDK_stdcells/osu_freepdk_1.0/lib/files
    _PDK_LINK_DIR="${HOME}/.cache/addv/pdk"
    if [ -d "$_FREEPDK_FILES" ]; then
        mkdir -p "$_PDK_LINK_DIR/osu_soc/lib"
        ln -sfn "$_FREEPDK_FILES" "$_PDK_LINK_DIR/osu_soc/lib/files"
        export PDK_DIR="$_PDK_LINK_DIR"
    else
        export PDK_DIR="${PDK_DIR:-/mnt/vault0/PDKs/OSU_FreePDK/OSU_FreePDK_stdcells/osu_freepdk_1.0}"
    fi
    unset _FREEPDK_FILES _PDK_LINK_DIR
else
    echo "setup.sh: error: no Synopsys installation found (looked in /usr/local2 and /home/tools)." >&2
    return 1 2>/dev/null || exit 1
fi

export VCS_HOME VERDI_HOME

# ------------------------------------------------------------------- tool PATH
for _dir in "$VCS_HOME/bin" "$VCS_HOME/linux64/bin" \
            "$VERDI_HOME/bin" "$VERDI_HOME/platform/linux64/bin" \
            "$SYN_HOME/bin"; do
    [ -d "$_dir" ] && PATH="$_dir:$PATH"
done
unset _dir
export PATH

# Verdi FSDB PLI needs its shared libraries on the library path
export LD_LIBRARY_PATH="$VERDI_HOME/share/PLI/VCS/linux64:/usr/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# ------------------------------------------------------------------- licenses
export LM_LICENSE_FILE="${LM_LICENSE_FILE:-27020@enlicense5.eas.asu.edu}"
export SNPSLMD_LICENSE_FILE="${SNPSLMD_LICENSE_FILE:-$LM_LICENSE_FILE}"

echo "Synopsys environment ready:"
echo "  VCS_HOME   = $VCS_HOME"
echo "  VERDI_HOME = $VERDI_HOME"
echo "  SYN_HOME   = $SYN_HOME"
echo "  PDK_DIR    = $PDK_DIR"
echo "  license    = $LM_LICENSE_FILE"
