#!/bin/bash

## Ensure this is set to the name ##
##  of your Ombi systemd service  ##
ombiservicename="ombi"

##   Default variables   ##
## Change only if needed ##
logfile="/var/log/ombiupdater.log"
ombiservicefile="/etc/systemd/system/$ombiservicename.service"
defaultinstalldir="/opt/Ombi"
defaultuser="ombi"
defaultgroup="nogroup"
declare -i verbosity=-1

## Do not modify anything below this line ##
##   unless you know what you are doing   ##

while [ $# -gt 0 ]; do
  case "$1" in
    --verbosity|-v=*)
      verbosity="${1#*=}"
      ;;
    *)
      printf "***************************\n"
      printf "* Error: Invalid argument.*\n"
      printf "***************************\n"
      exit 1
  esac
  shift
done

declare -A LOG_LEVELS=([-1]="none" [0]="emerg" [1]="alert" [2]="crit" [3]="err" [4]="warning" [5]="notice" [6]="info" [7]="debug" [8]="trace")
function .log () {
    local LEVEL=${1}
    shift
    if [[ $verbosity =~ ^-?[0-8]$ ]]; then
            if [ $verbosity -ge $LEVEL ]; then
            echo "[${LOG_LEVELS[$LEVEL]}]" "$@"
        fi
    fi
	if [ $verbosity -eq 8 ] || [ $LEVEL -ne 8 ]; then
        echo "[${LOG_LEVELS[$LEVEL]}]" "$@" >> $logfile
    fi
}

unzip-strip() (
    local zip=$1
    local dest=${2:-.}
    local temp=$(mktemp -d) && tar -zxf "$zip" -C "$temp" && mkdir -p "$dest" &&
    shopt -s dotglob && local f=("$temp"/*) &&
    if (( ${#f[@]} == 1 )) && [[ -d "${f[0]}" ]] ; then
        cp -r "$temp"/*/* "$dest"
    else
        cp -r "$temp"/* "$dest"
    fi && rm -rf "$temp"/* "$temp"
)

.log 6 "Verboity level: [${LOG_LEVELS[$verbosity]}]"
scriptuser=$(whoami)
.log 7 "Update script running as: $scriptuser"
if [ -e $ombiservicefile ]; then
    .log 6 "Ombi service file for systemd found...parsing..."
    ombiservice=$(<$ombiservicefile)
    installdir=$(grep -Po '(?<=WorkingDirectory=)(\S|(?<=\\)\s)+' <<< "$ombiservice")
    user=$(grep -Po '(?<=User=)(\w+)' <<< "$ombiservice")
    group=$(grep -Po '(?<=Group=)(\w+)' <<< "$ombiservice")
    .log 6 "Parsing complete: InstallDir: $installdir, User: $user, Group: $group"
fi

if [ -z ${installdir+x} ]; then
    .log 5 "InstallDir not parsed...setting to default: $defaultinstalldir"
    installdir="$defaultinstalldir"
fi
if [ -z ${user+x} ]; then
    .log 5 "User not parsed...setting to default: $defaultuser"
    user="$defaultuser"
fi
if [ -z ${group+x} ]; then
    .log 5 "Group not parsed...setting to default: $defaultgroup"
    group="$defaultgroup"
fi

.log 6 "Downloading Ombi update..."
declare -i i=1
declare -i j=5
while [ $i -le $j ]
do
    .log 6 "Checking for latest version"
    json=$(curl -sL https://ombiservice.azurewebsites.net/api/update/DotNetCore)
	.log 8 "json: $json"
    latestversion=$(grep -Po '(?<="updateVersionString":")([^"]+)' <<<  "$json")
    .log 7 "latestversion: $latestversion"
    json=$(curl -sL https://ci.appveyor.com/api/projects/tidusjar/requestplex/build/$latestversion)
    .log 8 "json: $json"
    jobId=$(grep -Po '(?<="jobId":")([^"]+)' <<<  "$json")
    .log 7 "jobId: $jobId"
    version=$(grep -Po '(?<="version":")([^"]+)' <<<  "$json")
    .log 7 "version: $version"
	if [ $latestversion != $version ]; then
		.log 2 "Build version does not match expected version"
		exit 1
	fi
    .log 6 "Latest version: $version...determining expected file size..."
    size=$(curl -sL https://ci.appveyor.com/api/buildjobs/$jobId/artifacts | grep -Po '(?<="linux.tar.gz","type":"File","size":)(\d+)')
    .log 7 "size: $size"
    if [ -e $size ]; then
        if [ $i -lt $j ]; then
            .log 3 "Unable to determine update file size...[attempt $i of $j]"
        else
            .log 2 "Unable to determine update file size...[attempt $i of $j]...Bailing!"
            exit 2
        fi
        i+=1
        continue
	elif [[ $size =~ ^-?[0-9]+$ ]]; then
        .log 6 "Expected file size: $size...downloading..."
        break
	else
        .log 1 "Invalid file size value...bailing!"
        exit 99
    fi
done
tempdir=$(mktemp -d)
file="$tempdir/ombi_$version.tar.gz"
wget --quiet -O $file "https://ci.appveyor.com/api/buildjobs/$jobId/artifacts/linux.tar.gz"
.log 6 "Version $version downloaded...checking file size..."
if [ $(wc -c < $file) != $size ]; then
    .log 3 "Downloaded file size does not match expected file size...bailing!"
    exit 2
fi
.log 6 "File size validated...checking Ombi service status..."

declare -i running=0
if [ "`systemctl is-active $ombiservicename`" == "active" ]; then
    running=1
    .log 6 "Ombi is active...attempting to stop..."
    declare -i i=1
    j=5
    while [ $i -le $j ]
    do
        if [ $scriptuser = "root" ]; then
            systemctl stop $ombiservicename.service > /dev/null 2>&1
        else
            sudo systemctl stop $ombiservicename.service > /dev/null 2>&1
        fi
        if [ $? -ne 0 ] || [ "`systemctl is-active $ombiservicename`" == "active" ] ; then
            if [ $i -lt $j ]; then
                .log 3 "Failed to stop Ombi...[attempt $i of $j]"
            else
                .log 2 "Failed to stop Ombi...[attempt $i of $j]...Bailing!"
                exit 2
            fi
            i+=1
            continue
        elif [ "`systemctl is-active $ombiservicename`" == "inactive" ]; then
            .log 6 "Ombi stopped...installing update..."
            break
        else
            .log 1 "Unknown error...bailing!"
            exit 99
        fi
    done
else
    .log 6 "Ombi is not active...installing update..."
fi

unzip-strip $file $installdir
.log 6 "Update installed...setting ownership..."
chown -R $user:$group $installdir

if [ $running -eq 1 ]; then
    .log 6 "Ownership set...starting Ombi..."
    declare -i i=1
    j=5
    while [ $i -le $j ]
    do
        if [ $scriptuser = "root" ]; then
            systemctl systemctl start $ombiservicename.service > /dev/null 2>&1
        else
            sudo systemctl start $ombiservicename.service > /dev/null 2>&1
        fi    
        if [ $? -ne 0 ] || [ "`systemctl is-active $ombiservicename`" != "active" ] ; then
            if [ $i -lt $j ]; then
                .log 3 "Failed to start Ombi...[attempt $i of $j]"
            else
                .log 2 "Failed to start Ombi...[attempt $i of $j]...Bailing!"
               exit 3
            fi
            i+=1
            continue
        elif [ "`systemctl is-active $ombiservicename`" == "active" ]; then
            .log 6 "Ombi started...cleaning up..."
            break
        else
            .log 1 "Unknown error...bailing!"
            exit 99
        fi
    done
else
    .log 6 "Ownership set...not starting Ombi"
fi

.log 6 "Cleaning up..."
rm -rf "$tempdir"/* "$tempdir"
.log 6 "Update complete"