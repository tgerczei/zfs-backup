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
	${R_RMOD} /usr/sbin/zfs get -pHo value creation ${1} &>/dev/null
	return $?
}

function snapuse() {
	 ${R_RMOD} /usr/sbin/zfs get -Hpo value usedbysnapshots ${1}
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
	SNAPSHOTS=( $(/usr/sbin/zfs list -rt snapshot -d1 -Ho name -S creation ${DATASET} 2>/dev/null) )
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
			RMOD="${R_RMOD} sudo"
		fi
	fi

	# check target
	check_dataset ${SAVETO} ||	{
								logger -t $(basename ${0%.sh}) -p user.notice "target dataset \"${SAVETO}\" in configuration entry #${COUNTER} does not exist; omitting"
								continue 2
								}

	R_SNAPSHOTS=( $(${R_RMOD} /usr/sbin/zfs list -rt snapshot -d1 -Ho name -S creation ${SAVETO}/$( basename ${DATASET}) 2>/dev/null) )
	R_USED_BEFORE=$(snapuse ${SAVETO}/$( basename ${DATASET}))

	# determine current timestamp
	DATE=$(date +%Y-%m-%d-%H%M)

	# determine the name of the current snapshot to create
	NEWSNAP="${DATASET}@${DATE}"
	
	# take a snapshot
	/usr/sbin/zfs snapshot -r ${NEWSNAP}
	
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
																/usr/sbin/zfs send -R${R_SNAPMODIFIER} ${LASTSNAP} | ${RMOD} /usr/sbin/zfs recv -Feuv ${SAVETO} 2>&1 >> ${LOGFILE}
																}
		else
			# ensure this does not remain in effect
			unset SNAPMODIFIER R_SNAPMODIFIER
	fi
	
	# send backup
	/usr/sbin/zfs send -R${SNAPMODIFIER} ${NEWSNAP} | ${RMOD} /usr/sbin/zfs recv -Feuv ${SAVETO} 2>&1 >> ${LOGFILE}
	
	# if replication is unsuccessful, omit the aging check so as to prevent data loss
	if [ $? -eq 0 ]
		then
			THRESHOLD=$(( $KEEP * 24 * 3600 ))
			for SNAPSHOT in ${SNAPSHOTS[*]}
				do
					TIMESTAMP=$(/usr/sbin/zfs get -pHo value creation "${SNAPSHOT}")
					AGE=$(( $NOW - $TIMESTAMP ))
					if [ $AGE -ge $THRESHOLD ]
						then
							/usr/sbin/zfs destroy -r ${SNAPSHOT} 2>&1 >> ${LOGFILE}
							${RMOD} /usr/sbin/zfs destroy -r ${SAVETO}/$(basename ${SNAPSHOT}) 2>&1 >> ${LOGFILE}
					fi
				done
		else
			logger -t $(basename ${0%.sh}) -p user.notice "failed to replicate ${NEWSNAP} to ${TARGET}:${SAVETO}, no aging"
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
	R_DELTA=$(( $R_USED_AFTER - $R_USED_BEFORE ))

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
    unset R_RMOD RMOD
}

#### END FUNCTIONS ####

#### BEGIN LOGIC ####

while getopts hf:m: OPTION
	do
		case "$OPTION" in
			f)
				# configuration file for install mode
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
		mailx -s "${ME}_${RUNDATE}" ${RECIPIENT} < ${LOGFILE}
fi

#### END LOGIC ####
