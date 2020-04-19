#!/usr/bin/env bash
# create and rotate ZFS backups | 150415 | tamas@gerczei.eu

#### BEGIN FUNCTIONS ####

function usage() {
	# print synopsis
	printf "\n-=[ ZFS back-up utility ]=-\n\n\
	usage: $(basename $0) [-h] [-m <e-mail_address>] -f <fully_qualified_configuration_file_name>\n\n\
A configuration (f)ile must be supplied. An e-(m)ail address for reporting is optional.\n"
}

function check_dataset() {
	${R_RMOD} zfs get -pHo value creation ${1} &>/dev/null
	return $?
}

function snapuse() {
	 ${R_RMOD} zfs get -Hpo value usedbysnapshots ${1}
}

function human() {
	# found at http://unix.stackexchange.com/a/191787
	nawk 'function human(x)	{
							x[1]/=1024;
							if (x[1]>=1000) { x[2]++; human(x); }
							}
							{a[1]=$1; a[2]=0; human(a); printf "%.2f%s\n",a[1],substr("KMGTEPYZ",a[2]+1,1)}' <<< $1
}

function backup() {
	# check source
	check_dataset ${DATASET} ||	{
								logger -t $(basename ${0%.sh}) -p user.notice "source dataset \"${DATASET}\" in configuration entry #${COUNTER} does not exist; omitting"
								continue 2
								}

	# determine which local snapshots exist already
	SNAPSHOTS=( $(zfs list -rt snapshot -d1 -Ho name -S creation ${DATASET} 2>/dev/null) )
	LASTSNAP=${SNAPSHOTS[0]}
	L_USED_BEFORE=$(snapuse ${DATASET})

	# check target configuration
	if [[ ${SAVETO} =~ ^[a-zA-z0-9]+@ ]]
		then
		# remote target
		NETLOC=$(cut -d: -f1 <<< ${SAVETO}) # strip dataset name
		USER=$(cut -d@ -f1 <<< ${NETLOC})   # obtain user
		TARGET=$(cut -d@ -f2 <<< ${NETLOC}) # obtain host
		SAVETO=$(cut -d: -f2 <<< ${SAVETO}) # drop parsed data
		unset NETLOC

		# check remote host availability and user validity
		/usr/bin/ssh ${USER}@${TARGET} true &>/dev/null
		if [ $? -ne 0 ]
			then
				# failed to connect, bail out
				logger -t $(basename ${0%.sh}) -p user.notice "${TARGET} is unreachable as ${USER}"
				continue 2
		else
			# configure for remote access
			R_RMOD="ssh ${USER}@${TARGET}"
			if [ $USER != 'root' ]
				then
					RMOD="${R_RMOD} sudo"
			fi
		fi
	fi

	# check target
	check_dataset ${SAVETO} ||	{
								logger -t $(basename ${0%.sh}) -p user.notice "target dataset \"${SAVETO}\" in configuration entry #${COUNTER} does not exist; omitting"
								continue 2
								}

	R_SNAPSHOTS=( $(${R_RMOD} zfs list -rt snapshot -d1 -Ho name -S creation ${SAVETO}/$( basename ${DATASET}) 2>/dev/null) )
	check_dataset ${SAVETO}/$( basename ${DATASET}) && R_USED_BEFORE=$(snapuse ${SAVETO}/$( basename ${DATASET}))

	# determine current timestamp
	DATE=$(date +%Y-%m-%d-%H%M)

	# determine the name of the current snapshot to create
	NEWSNAP="${DATASET}@${DATE}"
	
	# take a snapshot
	zfs snapshot -r ${NEWSNAP}
	
	# check if source is encrypted
	if [ $ENCRYPTION_FEATURE != "disabled" ]
		then
			# encryption feature available
			ENCRYPTION=$(zfs get -Ho value encryption ${DATASET})
			if [[ ${ENCRYPTION} != "off" ]]
				then
					# encryption in use, send raw stream
					RAW_MOD="w"
			fi
	fi

	# determine whether to do differential send or not
	if [ ! -z ${LASTSNAP} ]
		then
			# local snapshot(s) found
			SNAPMODIFIER="i ${LASTSNAP}"
			check_dataset ${SAVETO}/$(basename ${LASTSNAP}) ||	{
																# last local snapshot is not available at the destination location
																if [ ${#R_SNAPSHOTS[*]} -ge 1 ]
																	then
																		# remote snapshot(s) found
																		R_SNAPMODIFIER="I $(dirname ${DATASET})/$(basename ${R_SNAPSHOTS[*]:(-1)})"
																fi
																# send any previous snapshots
																zfs send -Rv${RAW_MOD}${R_SNAPMODIFIER} ${LASTSNAP} | ${RMOD:-$R_RMOD} zfs recv -Feu${RESUME_MOD}v ${SAVETO} 2>&1 >> ${LOGFILE}
																}
		else
			# ensure this does not remain in effect
			unset SNAPMODIFIER R_SNAPMODIFIER
	fi
	
	# send backup
	zfs send -Rv${RAW_MOD}${SNAPMODIFIER} ${NEWSNAP} | ${RMOD:-$R_RMOD} zfs recv -Feu${RESUME_MOD}v ${SAVETO} 2>&1 >> ${LOGFILE}
	
	# if replication is unsuccessful, omit the aging check so as to prevent data loss
	if [ $? -eq 0 ]
		then
			THRESHOLD=$(( $KEEP * 24 * 3600 ))
			for SNAPSHOT in ${SNAPSHOTS[*]}
				do
					TIMESTAMP=$(zfs get -pHo value creation "${SNAPSHOT}")
					AGE=$(( $NOW - $TIMESTAMP ))
					if [ $AGE -ge $THRESHOLD ]
						then
							zfs destroy -r ${SNAPSHOT} 2>&1 >> ${LOGFILE}
							${RMOD:-$R_RMOD} zfs destroy -r ${SAVETO}/$(basename ${SNAPSHOT}) 2>&1 >> ${LOGFILE}
					fi
				done
		else
			MY_EXIT_CODE=$?
			logger -t $(basename ${0%.sh}) -p user.notice "failed to replicate ${NEWSNAP} (rc: $MY_EXIT_CODE) to ${TARGET:-local}:${SAVETO}, no aging"
	fi

	# re-evaluate snapshot data usage
	unset R_RMOD RMOD
	L_USED_AFTER=$(snapuse ${DATASET})

	if [ ! -z $TARGET ] && [ ! -z $USER ]
		then
			R_RMOD="ssh ${USER}@${TARGET}"
	fi
			
	R_USED_AFTER=$(snapuse ${SAVETO}/$( basename ${DATASET}))
	L_DELTA=$(( $L_USED_AFTER - $L_USED_BEFORE ))
	R_DELTA=$(( $R_USED_AFTER - ${R_USED_BEFORE:-0} ))

	for DELTA in L_DELTA R_DELTA
		do
			unset WHAT WHERE
			eval _DELTA=\$$DELTA

			if [ $_DELTA -lt 0 ]
				then
					_DELTA=$(( $_DELTA * -1 ))
					WHAT="freed"
			fi

			if [[ $DELTA =~ ^L ]]
				then
					WHERE="$(dirname ${DATASET})"
				else
					WHERE="${SAVETO}"
			fi

			if [ $_DELTA -ne 0 ]
				then
					_DELTA=$(human $_DELTA)
					logger -t $(basename ${0%.sh}) -p user.notice "$_DELTA ${WHAT:-allocated} in \"${WHERE}\" by backing up \"${DATASET}\""
			fi
		done

	# reset remote configuration
	unset R_RMOD RMOD RAW_MOD
}

#### END FUNCTIONS ####

#### BEGIN LOGIC ####

while getopts hf:m: OPTION
	do
		case "$OPTION" in
			f)
				# configuration file
				CFGFILE="$OPTARG"
				;;

			m)
				# e-mail recipient for log
				RECIPIENT="$OPTARG"
				;;

			h|\?)
				# display help
				usage
				exit 1
				;;
		esac
	done

if [ -z "${CFGFILE}" ]
	then
		echo "No configuration file supplied!"
		exit 1
fi

## sanity checks
# verify configuration file
if [ ! -f "${CFGFILE}" ]
	then
		# cannot proceed
		logger -t $(basename ${0%.sh}) -p user.notice "can not access configuration file \""${CFGFILE}"\""
		exit 1
fi

# determine platform
PLATFORM_VERSION=$(uname -v)
if [[ "$PLATFORM_VERSION" =~ ^joyent ]]
	then
		# SmartOS GZ has GNU date shipped by default but no perl interpreter on-board
		TIMECMD="\$(date +%s)"
		# determine pool name
		POOL_NAME=$(/usr/bin/sysinfo | /usr/bin/json Zpool)
		ENCRYPTION_FEATURE=$(/usr/sbin/zpool get -Ho value feature@encryption ${POOL_NAME})
		if [ $? -ne 0 ]
			then
				# feature unknown, outdated PI
				logger -t $(basename ${0%.sh}) -p user.notice "ZFS encryption is not supported on $PLATFORM_VERSION"
				ENCRYPTION_FEATURE="disabled"
		fi

		EXTENSION_FEATURE=$(/usr/sbin/zpool get -Ho value feature@extensible_dataset ${POOL_NAME})
		if [ $? -ne 0 ]
			then
				# feature unknown, outdated PI
				logger -t $(basename ${0%.sh}) -p user.notice "extensible datasets are not supported on $PLATFORM_VERSION"
				EXTENSION_FEATURE="disabled"
			else
				# check if resuming is supported
				if [ $EXTENSION_FEATURE == "active" ]
					then
						# extensible_dataset feature available
						RESUME_MOD="s"
				fi
		fi
fi

# determine current timestamp
eval NOW="${TIMECMD:-\$(perl -e 'print time')}"
if [ $? -ne 0 ]
	then
		# cannot proceed
		logger -t $(basename ${0%.sh}) -p user.notice "failed to determine current time on $PLATFORM_VERSION"
		exit 1
fi

# determine current timestamp
RUNDATE=$(date +%Y-%m-%d-%H%M)

# determine the name of this script
ME=$(basename ${0%.sh})

# define logging directory, defaulting to "/tmp" if omitted
LOGDIR="/var/log"

# determine session logfile
LOGFILE="${LOGDIR:-/tmp}/${ME}_${RUNDATE}.txt"

while read -u 4 DATASET SAVETO KEEP ENABLED
	# alternate file descriptor in use because SSH might be involved and we can not pass '-n' to it because we need stdin for 'zfs recv'
	do
		let COUNTER++
		if [ ${ENABLED} == "Y" ]
			then
				backup
		fi
	done 4<<< "$(egrep -v '^(#|$)' "${CFGFILE}")" # graciously overlook any comments or blank lines

if [ ! -z "${RECIPIENT}" ]
	then
		# report the outcome by e-mailing the session log
		sendmail ${RECIPIENT} <<- EOF
			Subject: ${ME}_${RUNDATE}
			Auto-Submitted: auto-generated

			$(cat ${LOGFILE})
			EOF
fi

#### END LOGIC ####
