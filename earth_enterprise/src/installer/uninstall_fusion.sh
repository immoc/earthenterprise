#!/bin/bash
#
# Copyright 2017 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# NOTE: requires xmllint from libxml2-utils

set +x

# config values
ASSET_ROOT=""
GEFUSIONUSER_NAME=""
GROUPNAME=""

# directory locations
BININSTALLROOTDIR="/etc/init.d"
BININSTALLPROFILEDIR="/etc/profile.d"
BASEINSTALLDIR_OPT="/opt/google"
BASEINSTALLDIR_ETC="/etc/opt/google"
BASEINSTALLDIR_VAR="/var/opt/google"
INITSCRIPTUPDATE="/usr/sbin/update-rc.d"
CHKCONFIG="/sbin/chkconfig"
OS_RELEASE="/etc/os-release"

# script arguments
BACKUPFUSION=true
DELETE_FUSION_USER=true
DELETE_FUSION_GROUP=true

# derived directories
SYSTEMRC="$BASEINSTALLDIR_ETC/systemrc"
FUSIONBININSTALL="$BININSTALLROOTDIR/gefusion"
UNUNINSTALL_LOG_DIR="$BASEINSTALLDIR_OPT/install"
UNINSTALL_LOG="$UNUNINSTALL_LOG_DIR/fusion_uninstall_$(date +%Y_%m_%d.%H%M%S).log"
BACKUP_DIR="$BASEINSTALLDIR_VAR/fusion-backups/$(date +%Y_%m_%d.%H%M%S)"
GENERAL_LOG="$BASEINSTALLDIR_VAR/log"
CONFIG_VOLUME=""

# additional variables
LONG_VERSION="5.1.3"
GEE="Google Earth Enterprise"
GEEF="Google Earth Enterprise Fusion"
HAS_EARTH_SERVER=false
ROOT_USERNAME="root"
SUPPORTED_OS_LIST=("Ubuntu", "Red Hat Enterprise Linux (RHEL)")
UBUNTUKEY="ubuntu"
REDHATKEY="rhel"
MACHINE_OS=""
MACHINE_OS_VERSION=""
MACHINE_OS_FRIENDLY=""

#-----------------------------------------------------------------
# Main Functions
#-----------------------------------------------------------------
main_preuninstall()
{
    show_intro

    # Root/Sudo check
	if [ "$EUID" != "0" ]; then 
		show_need_root
		exit 1
	fi

    # Argument check
    if ! parse_arguments "$@"; then
        exit 1
    fi

    if ! determine_os; then
        exit 1
    fi

    if ! check_prereq_software; then
        exit 1
    fi

	# check to see if GE Fusion processes are running
	if ! check_fusion_processes_running; then
		show_fusion_running_message
		exit 1
	fi

    if ! load_systemrc_config; then
        exit 1
    fi

    GROUP_EXISTS=$(getent group $GROUPNAME)
	USERNAME_EXISTS=$(getent passwd $GEFUSIONUSER_NAME)

    if [ -f "$BININSTALLROOTDIR/geserver" ]; then
        HAS_EARTH_SERVER=true
    else
        HAS_EARTH_SERVER=false
    fi

    if ! verify_systemrc_config_values; then
        exit 1
    fi

    if ! verify_user_and_group; then
        exit 1
    fi

    if ! prompt_uninstall_confirmation; then
        exit 1
    fi

    if [ $BACKUPFUSION == true ]; then
        # Backing up current Fusion setup
        backup_fusion
    fi
}

main_uninstall()
{
    remove_fusion_daemon
    change_volume_ownership
    remove_files_from_target
    remove_user
    remove_group    
    show_final_success_message
}

#-----------------------------------------------------------------
# Pre-uninstall Functions
#-----------------------------------------------------------------
show_intro()
{
    echo -e "\nUninstalling $GEEF $LONG_VERSION"
    echo -e "\nThis will remove features installed by the Fusion installer."
    echo -e "It will NOT remove files and folders created after the installation."
}

show_need_root()
{
	echo -e "\nYou must have root privileges to uninstall $GEEF.\n"
	echo -e "Log in as the $ROOT_USERNAME user or use the 'sudo' command to run this uninstaller."
	echo -e "The uninstaller must exit."
}

determine_os()
{
    local retval=0
    local test_os=""
    local test_versionid=""

    if [ -f "$OS_RELEASE" ]; then
        test_os="$(cat $OS_RELEASE | sed -e 's:\"::g' | grep ^NAME= | sed 's:name=::gI')"
        test_versionid="$(cat $OS_RELEASE | sed -e 's:\"::g' | grep ^VERSION_ID= | sed 's:version_id=::gI')"

        MACHINE_OS_FRIENDLY="$test_os $test_versionid"
        MACHINE_OS_VERSION=$test_versionid

        if [[ "${test_os,,}" == "ubuntu"* ]]; then
            MACHINE_OS=$UBUNTUKEY
        elif [ "${test_os,,}" == "red hat"* ]; then
            MACHINE_OS=$REDHATKEY
        else
            MACHINE_OS=""
            echo -e "\nThe uninstaller could not determine your machine's operating system."
            echo -e "Supported Operating Systems: ${SUPPORTED_OS_LIST[*]}\n"
            retval=1
        fi
    else
        echo -e "\nThe uninstaller could not determine your machine's operating system."
        echo -e "Missing file: $OS_RELEASE\n"
        retval=1
    fi

    return $retval
}

show_help()
{
	echo -e "\nUsage:  sudo ./uninstall_fusion.sh [-f -ndgu]\n"

	echo -e "-h \t\tHelp - display this help screen"	
    echo -e "-ndgu \t\tDo Not Delete Fusion User and Group - do not delete the fusion user account and group.  Default is to delete both."
    echo -e "-nobk \t\tNo Backup - do not backup the current fusion setup. Default is to backup \n\t\tthe setup before uninstalling.\n"
}

parse_arguments()
{
	local parse_arguments_retval=0
    
	while [ $# -gt 0 ]
	do
		case "${1,,}" in
			-h|-help|--help)
				show_help
				parse_arguments_retval=1
				break
				;;
            -nobk)
				BACKUPFUSION=false				
				;;
            -ndgu)
                DELETE_FUSION_USER=false
                DELETE_FUSION_GROUP=false
                ;;
			*)
				echo -e "\nArgument Error: $1 is not a valid argument."
				show_help
				parse_arguments_retval=1
				break
				;;
		esac

        if [ $# -gt 0 ]
		then
		    shift
		fi
	done	
	
	return $parse_arguments_retval;
}


software_check()
{
	local software_check_retval=0
	
	# args: $1: ubuntu package
	# args: $: rhel package

    if [ "$MACHINE_OS" == "$UBUNTUKEY" ] && [ ! -z "$1" ]; then
        if [[ -z "$(dpkg --get-selections | sed s:install:: | sed -e 's:\s::g' | grep ^$1\$)" ]]; then
            echo -e "Install $1 and restart the $GEEF $LONG_VERSION uninstaller."
            software_check_retval=1
        fi
    elif [ "$MACHINE_OS" == "$REDHATKEY" ] && [ ! -z "$2" ]; then
        if [[ -z "$(rpm -qa | grep ^$2\$)" ]]; then
            echo -e "Install $2 and restart the $GEEF $LONG_VERSION uninstaller."
            software_check_retval=1
        fi
	else 
		echo -e "\nThe installer could not determine your machine's operating system."
            echo -e "Supported Operating Systems: ${SUPPORTED_OS_LIST[*]}\n"
            software_check_retval=1
    fi

	return $software_check_retval
}

check_prereq_software()
{
	local check_prereq_software_retval=0

	if ! software_check "libxml2-utils" "libxml2-.*x86_64"; then
		check_prereq_software_retval=1
	fi

	return $check_prereq_software_retval
}

check_fusion_processes_running()
{
	check_fusion_processes_running_retval=0

	local manager_running=$(ps -e | grep gesystemmanager | grep -v grep)
	local res_provider_running=$(ps -ef | grep geresourceprovider | grep -v grep)

	if [ ! -z "$manager_running" ] || [ ! -z "$res_provider_running" ]; then
		check_fusion_processes_running_retval=1
	fi

	return $check_fusion_processes_running_retval
}

show_fusion_running_message()
{
	echo -e "\n$GEEF has active running processes."
	echo -e "To use this uninstaller, you must stop all fusion services.\n"	
}

load_systemrc_config()
{
    local load_systemrc_config_retval=0

    if [ -f "$SYSTEMRC" ]; then
        ASSET_ROOT=$(xmllint --xpath '//Systemrc/assetroot/text()' $SYSTEMRC)
		GEFUSIONUSER_NAME=$(xmllint --xpath '//Systemrc/fusionUsername/text()' $SYSTEMRC)
		GROUPNAME=$(xmllint --xpath '//Systemrc/userGroupname/text()' $SYSTEMRC)	
    else
        load_systemrc_config_retval=1
        echo -e "\nThe system configuration file [$SYSTEMRC] could not be found on your system."
        echo -e "This uninstaller cannot continue without a valid system configuration file.\n"
        load_systemrc_config_retval=1
    fi

    return $load_systemrc_config_retval
}

backup_fusion()
{
	export BACKUP_DIR=$BACKUP_DIR

	if [ ! -d $BACKUP_DIR ]; then
		mkdir -p $BACKUP_DIR
	fi

	# copy log files.
	mkdir -p $BACKUP_DIR/log

	if [ -f "$GENERAL_LOG/gesystemmanager.log" ]; then 
		cp -f $GENERAL_LOG/gesystemmanager.log $BACKUP_DIR/log
	fi

	if [ -f "$GENERAL_LOG/geresourceprovider.log" ]; then 
		cp -f $GENERAL_LOG/geresourceprovider.log $BACKUP_DIR/log
	fi

	# copy some other random files.
	if [ -f "$BININSTALLROOTDIR/gevars.sh" ]; then 
		cp -f $BININSTALLROOTDIR/gevars.sh $BACKUP_DIR
	fi

	if [ -d "$BASEINSTALLDIR_ETC/openldap" ]; then 
		cp -rf $BASEINSTALLDIR_ETC/openldap $BACKUP_DIR
	fi

	if [ -f "$SYSTEMRC" ]; then 
		cp -f $SYSTEMRC $BACKUP_DIR
	fi

	# Change the ownership of the backup folder.
	chown -R $ROOT_USERNAME:$ROOT_USERNAME $BACKUP_DIR

    echo -e "\nThe uninstaller has performed a backup of the existing $GEEF $LONG_VERSION configuration"
    echo -e "files to the following location:"
    echo -e "\n$BACKUP_DIR"
    echo -e "\nThe source volume(s) and asset root remain unchanged.\n"
    pause
}

pause()
{
	printf "Press <ENTER> to continue..."
	read -r continueKey
}

get_array_index()
{
    # need to have a set test value -- technically, the return status is an unsigned 8 bit value, so negative numbers won't work
    # need a value large enough that can be tested against
    local get_array_index_retval=$INVALID_INDEX 

    # args $1: array
    # args $2: choice/selection

    local array_list=("${!1}")
    local selection=$2
    
    for i in "${!array_list[@]}"; 
    do
        if [[ "${array_list[$i]}" == "${selection}" ]]; then
            get_array_index_retval=$i
            break
        fi
    done

    return $get_array_index_retval
}

prompt_to_action()
{
    # args- $1: array
    # args- $2: repeatable prompt
    
    local prompt_to_action_choice=""
    local prompt_to_action_validAnswers=("${!1}")

    while [[ " ${prompt_to_action_validAnswers[*]} " != *"${prompt_to_action_choice^^} "* ]] || [ -z "$prompt_to_action_choice" ]
    do
        printf "$2 "
        read -r prompt_to_action_choice
    done

    get_array_index prompt_to_action_validAnswers[@] ${prompt_to_action_choice^^}
    prompt_to_action_retval=$?

    return $prompt_to_action_retval
}

prompt_to_quit()
{
    # args- $1: repeatable prompt
    local prompt_to_quit_retval=0
    local prompt_to_quit_validAnswers=(X C)
    local prompt_to_quit_index=1
    
    prompt_to_action prompt_to_quit_validAnswers[@] "$1"
    prompt_to_quit_index=$?

    if [ $prompt_to_quit_index -eq 1 ]; then
        prompt_to_quit_retval=0
    else		
        echo -e "Exiting the Uninstaller.\n"	
        prompt_to_quit_retval=1
    fi        

    return $prompt_to_quit_retval
}

verify_systemrc_config_values()
{
    # now let's make sure that the config values read from systemrc each contain data
    if [ -z "$ASSET_ROOT" ] || [ -z "$GEFUSIONUSER_NAME" ] || [ -z "$GROUPNAME" ]; then
        echo -e "\nThe [$SYSTEMRC] configuration file contains invalid data."
        echo -e "\nAsset Root: \t\t$ASSET_ROOT"
        echo -e "Fusion User: \t$GEFUSIONUSER_NAME"
        echo -e "Fusion Group: \t\t$GROUPNAME"
        echo -e "\nThe uninstaller requires a system configuration file with valid data."
        echo -e "Exiting the uninstaller.\n"
        return 1
    else
        return 0
    fi
}

verify_user_and_group()
{
    local retval=0
    
    if [ $DELETE_FUSION_USER == true ] && [ $HAS_EARTH_SERVER == true ]; then
        echo -e "\nYou cannot delete the fusion user [$GEFUSIONUSER_NAME] because $GEE is installed on this server."
        echo -e "$GEE uses this account too."        
        retval=1
    fi

    if [ $DELETE_FUSION_GROUP == true ] && [ $HAS_EARTH_SERVER == true ]; then
        echo -e "\nYou cannot delete the fusion group [$GROUPNAME] because $GEE is installed on this server."
        echo -e "$GEE uses this user group too."
        retval=1
    fi

    if [ $retval -eq 1 ]; then
        echo -e "Exiting the uninstaller.\n"
    fi

    return $retval
}

prompt_uninstall_confirmation()
{
    local backupStringValue=""
    local deleteUserValue=""
    local deleteGroupValue=""

    if [ $BACKUPFUSION == true ]; then
		backupStringValue="YES"
	else
		backupStringValue="NO"
	fi

    if [ $DELETE_FUSION_USER == true ]; then
        deleteUserValue="YES - Delete fusion user [$GEFUSIONUSER_NAME]"
    else
        deleteUserValue="NO"
    fi

    if [ $DELETE_FUSION_GROUP == true ]; then
        deleteGroupValue="YES - Delete fusion group [$GROUPNAME]"
    else
        deleteGroupValue="NO"
    fi

    echo -e "\nYou have chosen to install $GEEF with the following settings:\n"
	echo -e "Backup Fusion: \t\t$backupStringValue"
	echo -e "Delete Fusion User: \t$deleteUserValue"
	echo -e "Delete Fusion Group: \t$deleteGroupValue\n"

    if [ $DELETE_FUSION_USER == true ] && [ $DELETE_FUSION_GROUP == true ]; then
        echo -e "You have chosen to remove the fusion group and user."
        echo -e "Note: this may take some time to change ownership of the asset and source volumes to \"$ROOT_USERNAME\".\n"
    elif [ $DELETE_FUSION_USER == true ]; then
        echo -e "You have chosen to remove the fusion user."
        echo -e "Note: this may take some time to change ownership of the asset and source volumes to \"$ROOT_USERNAME\".\n"
    elif [ $DELETE_FUSION_GROUP == true ]; then
        echo -e "You have chosen to remove the fusion group."
        echo -e "Note: this may take some time to change ownership of the asset and source volumes to \"$ROOT_USERNAME\".\n"
    fi
    
    if ! prompt_to_quit "X (Exit) the uninstaller and change the above settings - C (Continue) to uninstall."; then
		return 1	
	else
        echo -e "\nProceeding with installation..."
		return 0
    fi
}

#-----------------------------------------------------------------
# Uninstall Functions
#-----------------------------------------------------------------
remove_fusion_daemon()
{
    test -f $CHKCONFIG && $CHKCONFIG --del gefusion 
    test -f $INITSCRIPTUPDATE && $INITSCRIPTUPDATE -f gefusion remove

    rm -f $FUSIONBININSTALL
}

remove_user()
{
    if [ $HAS_EARTH_SERVER == false ] && [ $DELETE_FUSION_USER == true ] && [ ! -z "$USERNAME_EXISTS" ]; then
        echo -e "\nDeleting user $GEFUSIONUSER_NAME"
        userdel $GEFUSIONUSER_NAME
    fi
}

remove_group()
{
    if [ $HAS_EARTH_SERVER == false ] && [ $DELETE_FUSION_GROUP == true ] && [ ! -z "$GROUP_EXISTS" ]; then
        echo -e "\nDelete group $GROUPNAME"
        groupdel $GROUPNAME
    fi
}

change_volume_ownership()
{
    CONFIG_VOLUME="$ASSET_ROOT/.config/volumes.xml"

    if [ $DELETE_FUSION_USER == true ] || [ $DELETE_FUSION_GROUP == true ]; then
        if [ ! -f "$CONFIG_VOLUME" ]; then
            echo -e "\nThe volume configuration file [$CONFIG_VOLUME] does not exist.  This may be indicative of a corrupted install."
            echo -e "Continuing on with the uninstall.\n"
            pause
        else
            echo -e "\nChanging ownership for all volumes to $ROOT_USERNAME:$ROOT_USERNAME"

            local volume_name="test"
            local index=1
            local max_index=$(expr "$(xmllint --xpath 'count(//VolumeDefList/volumedefs/item/localpath)' $CONFIG_VOLUME)")

            while [ $index -le $max_index ]; 
            do                
                volume_name=$(xmllint --xpath "//VolumeDefList/volumedefs/item[$index]/localpath/text()" $CONFIG_VOLUME)

                if [ -d "$volume_name" ]; then
                    echo -e "Changing ownership for $volume_name"
                    chown -R $ROOT_USERNAME:$ROOT_USERNAME $volume_name
                else
                    echo -e "Does not exist: $volume_name"
                fi

                index=$(($index+1))
            done
        fi
    fi
}

remove_files_from_target()
{
    printf "\nRemove files from target directories..."

    # TODO: What file is this referring to?
    # rm -f /opt/google/Uninstall_$INSTALLER_TITLE$
    rm -f $BASEINSTALLDIR_VAR/run/geresourceprovider.pid
    rm -f $BASEINSTALLDIR_VAR/run/gesystemmanager.pid
    rm -rf $BASEINSTALLDIR_ETC/.fusion_install_mode

    if [ $HAS_EARTH_SERVER == false ]; then
        rm -rf $BASEINSTALLDIR_ETC
        rm -rf $BASEINSTALLDIR_VAR/log
        rm -rf $BASEINSTALLDIR_VAR/run
        rm -rf $BASEINSTALLDIR_OPT/install
        rm -rf $BASEINSTALLDIR_OPT/.users

        # TODO: Why are these excluded from the uninstall process (since we exclude servers with ES installed)?
        # rm -rf /opt/google/qt
        # rm -rf /opt/google/lib64
        # rm -rf /opt/google/lib
        # rm -rf /opt/google/share
        # rm -rf /opt/google/gepython
        # rm -rf /opt/google/bin
    fi

    # final file -- remove systemrc
    rm -f $SYSTEMRC

	printf "DONE\n"
}

remove_links()
{
    printf "Removing system links..."

	rm -rf $BASEINSTALLDIR_OPT/etc
    rm -rf $BASEINSTALLDIR_OPT/log
    rm -rf $BASEINSTALLDIR_OPT/run

	printf "DONE\n"	
}

show_final_success_message()
{
    echo -e "\n$GEEF $LONG_VERSION was successfully uninstalled."
    echo -e "The backup configuration files are located in:"
    echo -e "\n$BACKUP_DIR\n"
}

#-----------------------------------------------------------------
# Pre-install Main
#-----------------------------------------------------------------
mkdir -p $UNUNINSTALL_LOG_DIR
exec 2> $UNINSTALL_LOG

main_preuninstall "$@"

#-----------------------------------------------------------------
# Install Main
#-----------------------------------------------------------------
main_uninstall