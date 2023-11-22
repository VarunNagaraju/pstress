#!/bin/bash
# Created by Mohit Joshi

# Internal variables, please do not change
RANDOM=`date +%s%N | cut -b14-19`;
RANDOMD=$(echo $RANDOM$RANDOM$RANDOM | sed 's/..\(......\).*/\1/');
RESUME_MODE=0;REPEAT_MODE=0;WORKDIRACTIVE=0;ENGINE=InnoDB;
TRIAL=0;SCRIPT_PWD=$(cd `dirname $0` && pwd);
MYSQLD_START_TIMEOUT=60;PXC=0;PXC_START_TIMEOUT=60

function Help()
{
echo "usage: 1.[RESUME MODE] $BASH_SOURCE --incident-dir=<val> --resume-dir=<val> --step=<val>"
echo "       2.[REPEAT MODE] $BASH_SOURCE --incident-dir=<val> --resume-dir=<val> --step=<val> --repeat=<val>"
echo "  --incident-dir: The parent incident directory generated by pstress-run.sh"
echo "  --resume-dir  : The directory path where the replay runs will be saved"
echo "  --step        : The step from where the pstress runs will be resumed"
echo "  --repeat      : Repeat the step provided number of times"
}

function parse_args() {
  local param value
  local positional_params=""
  while [[ $# -gt 0 ]]; do
      param=`echo $1 | awk -F= '{print $1}'`
      value=`echo $1 | awk -F= '{print $2}'`

      # possible positional parameter
      if [[ ! $param =~ ^--[^[[:space:]]]* ]]; then
        positional_params+="$1 "
        shift
        continue
      fi
      case $param in
        --help)
          Help
          exit
          ;;
        --incident-dir)
          INCIDENT_DIR=$value
          ;;
        --resume-dir)
          RESUME_DIR=$value
	  RESUME_MODE=1
          ;;
	--repeat)
	  REPEAT=$value
	  REPEAT_MODE=1
	  ;;
        --step)
          STEP=$value
          ;;
        *)
          echo "ERROR: unknown parameter \"$param\""
          exit 1
          ;;
        esac
        shift
    done

}

# Output Function
function echoit(){
  if [ ${REPEAT_MODE} -eq 1 ]; then
    echo "[$(date +'%T')] [${TRIAL}.${COUNT}] $1"
  else
    echo "[$(date +'%T')] [${TRIAL}] $1"
  fi 
}

# Trap ctrl-c
trap ctrl-c SIGINT

function ctrl-c(){
  echoit "CTRL+C was pressed. Attempting to terminate running processes..."
  KILL_PIDS=`ps -ef | grep "${RANDOMD}" | grep -v "grep" | awk '{print $2}' | tr '\n' ' '`
  if [ "${KILL_PIDS}" != "" ]; then
    echoit "Terminating the following PID's: ${KILL_PIDS}"
    kill -9 ${KILL_PIDS} >/dev/null 2>&1
  fi
  echoit "Done. Terminating replay-test.sh with exit code 2..."
  exit 2
}

# Kill the server
function kill_server(){
  SIG=$1
  echoit "Killing the server with Signal $SIG";
  { kill -${SIG} ${MPID} && wait ${MPID}; } 2>/dev/null
}

# Start the server
function start_server() {
  PORT=$[50000 + ( $RANDOM % ( 9999 ) ) ]
  echoit "Starting mysqld server..."
  CMD="${BIN} ${MYSAFE} ${MYEXTRA} --basedir=${BASEDIR} --datadir=$DATADIR --tmpdir=$TEMPDIR \
--core-file --port=$PORT --pid_file=$PID_FILE --socket=$SOCKET ${KEYRING_PARAM}  \
--log-output=none --log-error-verbosity=3 --log-error=$ERROR"
  echoit "$CMD"
  $CMD > ${ERROR} 2>&1 &
  MPID="$!"

  echoit "Waiting for mysqld (pid: ${MPID}) to fully start..."
  for X in $(seq 0 ${MYSQLD_START_TIMEOUT}); do
    sleep 1
    if [ "$MPID" == "" ]; then echoit "Assert! $MPID empty. Terminating!"; exit 1; fi

# Check if mysqld is started successfully
    if ${BASEDIR}/bin/mysqladmin -uroot -S${SOCKET} ping > /dev/null 2>&1; then
      echoit "Server started ok. Client: `echo ${BIN} | sed 's|/mysqld|/mysql|'` -uroot -S${SOCKET}"
      break;
    fi
    if [ $X -eq ${MYSQLD_START_TIMEOUT} ]; then
      echoit "Server (PID: $MPID | Socket: $SOCKET) failed to start after ${MYSQLD_START_TIMEOUT} seconds. Will issue extra kill -9 to ensure it's gone"
      { kill -9 $MPID && wait $MPID; } 2>/dev/null
      exit 1
    fi
  done
}

# Start the PXC server
function start_pxc_server() {
  ${BASEDIR}/bin/mysqld --defaults-file=${CONFIG1} $STARTUP_OPTION $MYEXTRA $PXC_MYEXTRA --wsrep-new-cluster > ${ERR_FILE1} 2>&1 &
  pxc_startup_status 1
  ${BASEDIR}/bin/mysqld --defaults-file=${CONFIG2} $STARTUP_OPTION $MYEXTRA $PXC_MYEXTRA > ${ERR_FILE2} 2>&1 &
  pxc_startup_status 2
  ${BASEDIR}/bin/mysqld --defaults-file=${CONFIG3} $STARTUP_OPTION $MYEXTRA $PXC_MYEXTRA > ${ERR_FILE3} 2>&1 &
  pxc_startup_status 3

  echoit "Checking 3 node PXC Cluster startup..."
  for X in $(seq 0 10); do
    sleep 1
    CLUSTER_UP=0;
    if ${BASEDIR}/bin/mysqladmin -uroot -S${SOCKET1} ping > /dev/null 2>&1; then
      if [ `${BASEDIR}/bin/mysql -uroot -S${SOCKET1} -e"show global status like 'wsrep_cluster_size'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_cluster" | awk '{print $2}'` -eq 3 ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
      if [ `${BASEDIR}/bin/mysql -uroot -S${SOCKET2} -e"show global status like 'wsrep_cluster_size'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_cluster" | awk '{print $2}'` -eq 3 ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
      if [ `${BASEDIR}/bin/mysql -uroot -S${SOCKET3} -e"show global status like 'wsrep_cluster_size'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_cluster" | awk '{print $2}'` -eq 3 ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
      if [ "`${BASEDIR}/bin/mysql -uroot -S${SOCKET1} -e"show global status like 'wsrep_local_state_comment'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_local" | awk '{print $2}'`" == "Synced" ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
      if [ "`${BASEDIR}/bin/mysql -uroot -S${SOCKET2} -e"show global status like 'wsrep_local_state_comment'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_local" | awk '{print $2}'`" == "Synced" ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
      if [ "`${BASEDIR}/bin/mysql -uroot -S${SOCKET3} -e"show global status like 'wsrep_local_state_comment'" | sed 's/[| \t]\+/\t/g' | grep "wsrep_local" | awk '{print $2}'`" == "Synced" ]; then CLUSTER_UP=$[ ${CLUSTER_UP} + 1]; fi
    fi
      # If count reached 6 (there are 6 checks), then the Cluster is up & running and consistent in it's Cluster topology views (as seen by each node)
    if [ ${CLUSTER_UP} -eq 6 ]; then
      ISSTARTED=1
      echoit "3 Node PXC Cluster started ok. Clients:"
      echoit "Node #1: `echo ${BIN} | sed 's|/mysqld|/mysql|'` -uroot -S${SOCKET1}"
      echoit "Node #2: `echo ${BIN} | sed 's|/mysqld|/mysql|'` -uroot -S${SOCKET2}"
      echoit "Node #3: `echo ${BIN} | sed 's|/mysqld|/mysql|'` -uroot -S${SOCKET3}"
      break
    fi
  done
}

# Repeat a particular step
function repeat_step() {
  TRIAL=${STEP}
  echoit "====== TRIAL #${TRIAL} ($COUNT) ======"
  echoit "Ensuring there are no relevant mysqld server running..."
  KILLPID=$(ps -ef | grep mysqld | grep -v grep | awk '{print $2}' | tr '\n' ' ')
  { kill -9 $KILLPID && wait $KILLPID; } 2>/dev/null
  if [ ${PXC} -eq 0 ]; then
    mkdir -p ${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/log
    mkdir ${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/data ${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/tmp
    echoit "Copying datadir from incident directory ${INCIDENT_DIR}/${TRIAL}/data into ${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT";
    rsync -ar --exclude='*core*' ${INCIDENT_DIR}/${TRIAL}/data/ ${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/data 2>&1
  elif [ ${PXC} -eq 1 ]; then
    mkdir -p ${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/tmp1 ${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/tmp2 ${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/tmp3
    mkdir ${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/node1 ${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/node2 ${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/node3
    echoit "Copying datadir from incident directory ${INCIDENT_DIR}/${TRIAL}/node1 into ${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT";
    echoit "Copying datadir from incident directory ${INCIDENT_DIR}/${TRIAL}/node2 into ${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT";
    echoit "Copying datadir from incident directory ${INCIDENT_DIR}/${TRIAL}/node3 into ${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT";
    rsync -ar --exclude='*core*' ${RESUME_INCIDENT_DIR}/${TRIAL}/node1/ ${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/node1 2>&1
    rsync -ar --exclude='*core*' ${RESUME_INCIDENT_DIR}/${TRIAL}/node2/ ${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/node2 2>&1
    rsync -ar --exclude='*core*' ${RESUME_INCIDENT_DIR}/${TRIAL}/node3/ ${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/node3 2>&1
    echoit "Copying config file from ${INCIDENT_DIR}/${TRIAL}/n1.cnf into ${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/n1.cnf"
    echoit "Copying config file from ${INCIDENT_DIR}/${TRIAL}/n2.cnf into ${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/n2.cnf"
    echoit "Copying config file from ${INCIDENT_DIR}/${TRIAL}/n3.cnf into ${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/n3.cnf"
    cp ${INCIDENT_DIR}/${TRIAL}/n1.cnf ${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/n1.cnf
    cp ${INCIDENT_DIR}/${TRIAL}/n2.cnf ${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/n2.cnf
    cp ${INCIDENT_DIR}/${TRIAL}/n3.cnf ${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/n3.cnf

    sed -i "s|$RUNDIR/$TRIAL|$RESUME_INCIDENT_DIR/$TRIAL.$COUNT|g" ${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/n1.cnf
    sed -i "s|$RUNDIR/$TRIAL|$RESUME_INCIDENT_DIR/$TRIAL.$COUNT|g" ${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/n2.cnf
    sed -i "s|$RUNDIR/$TRIAL|$RESUME_INCIDENT_DIR/$TRIAL.$COUNT|g" ${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/n3.cnf

    sed -i "s|$INCIDENT_DIR/$TRIAL|$RESUME_INCIDENT_DIR/$TRIAL.$COUNT|g" ${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/n1.cnf
    sed -i "s|$INCIDENT_DIR/$TRIAL|$RESUME_INCIDENT_DIR/$TRIAL.$COUNT|g" ${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/n2.cnf
    sed -i "s|$INCIDENT_DIR/$TRIAL|$RESUME_INCIDENT_DIR/$TRIAL.$COUNT|g" ${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/n3.cnf

    sed -i 's|safe_to_bootstrap:.*$|safe_to_bootstrap: 1|' ${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/node1/grastate.dat
  fi

# Start server
  if [ ${PXC} -eq 0 ]; then
    SOCKET=${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/socket.sock
    DATADIR=${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/data
    TEMPDIR=${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/tmp
    ERROR=${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/log/master.err
    PID_FILE=${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/pid.pid
    start_server
  elif [ $PXC -eq 1 ]; then
    SOCKET1=${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/node1/node1_socket.sock
    SOCKET2=${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/node2/node2_socket.sock
    SOCKET3=${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/node3/node3_socket.sock
    CONFIG1=${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/n1.cnf
    CONFIG2=${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/n2.cnf
    CONFIG3=${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/n3.cnf
    ERR_FILE1=${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/node1/node1.err
    ERR_FILE2=${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/node2/node2.err
    ERR_FILE3=${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/node3/node3.err
    start_pxc_server
  fi

# Start pstress
  LOGDIR=${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/
  METADATA_PATH=${RESUME_INCIDENT_DIR}
  start_pstress

# Terminate mysqld
  kill_server $SIGNAL
  sleep 5 #^ Ensure the mysqld is gone completely
  if [ $(ls -l ${RESUME_INCIDENT_DIR}/${TRIAL}/*/*core* 2>/dev/null | wc -l) -ge 1 ]; then
    echoit "mysqld coredump detected at $(ls ${RESUME_INCIDENT_DIR}/${TRIAL}/*/*core* 2>/dev/null)"
    echoit "Bug found (as per error log): $(${SCRIPT_PWD}/search_string.sh ${RESUME_INCIDENT_DIR}/${TRIAL}/log/master.err)"
  fi

  echoit "pstress run details:$(grep -i 'SUMMARY.*queries failed' ${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/*.sql ${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/*.log | sed 's|.*:||')"

}

function resume_pstress() {
  TRIAL=$[ ${TRIAL} + 1 ]
  echoit "====== TRIAL #${TRIAL} ======"
  echoit "Ensuring there are no relevant mysqld server running"
  KILLPID=$(ps -ef | grep mysqld | grep -v grep | awk '{print $2}' | tr '\n' ' ')
  { kill -9 $KILLPID && wait $KILLPID; } 2>/dev/null
  if [ $PXC -eq 0 ]; then
    mkdir -p ${RESUME_INCIDENT_DIR}/${TRIAL}/data ${RESUME_INCIDENT_DIR}/${TRIAL}/tmp ${RESUME_INCIDENT_DIR}/${TRIAL}/log
    echoit "Copying datadir from previous trial ${RESUME_INCIDENT_DIR}/$((${TRIAL}-1))/data into ${RESUME_INCIDENT_DIR}/${TRIAL}/data";
    rsync -ar --exclude='*core*' ${RESUME_INCIDENT_DIR}/$(($TRIAL-1))/data/ ${RESUME_INCIDENT_DIR}/${TRIAL}/data 2>&1
    if [ ${ENCRYPTION_RUN} -eq 1 -a ${COMPONENT_KEYRING_FILE} -eq 1 ]; then
      sed -i "s|$RUNDIR/$(($TRIAL-1))|$RESUME_INCIDENT_DIR/$TRIAL|g" ${RESUME_INCIDENT_DIR}/${TRIAL}/data/component_keyring_file.cnf
    fi
  elif [ $PXC -eq 1 ]; then
    mkdir -p ${RESUME_INCIDENT_DIR}/${TRIAL}/tmp1 ${RESUME_INCIDENT_DIR}/${TRIAL}/tmp2 ${RESUME_INCIDENT_DIR}/${TRIAL}/tmp3
    mkdir ${RESUME_INCIDENT_DIR}/${TRIAL}/node1 ${RESUME_INCIDENT_DIR}/${TRIAL}/node2 ${RESUME_INCIDENT_DIR}/${TRIAL}/node3
    echoit "Copying datadir from ${RESUME_INCIDENT_DIR}/$((${TRIAL}-1))/node1 into ${RESUME_INCIDENT_DIR}/${TRIAL}/node1";
    echoit "Copying datadir from ${RESUME_INCIDENT_DIR}/$((${TRIAL}-1))/node2 into ${RESUME_INCIDENT_DIR}/${TRIAL}/node2";
    echoit "Copying datadir from ${RESUME_INCIDENT_DIR}/$((${TRIAL}-1))/node3 into ${RESUME_INCIDENT_DIR}/${TRIAL}/node3";
    rsync -ar --exclude='*core*' ${RESUME_INCIDENT_DIR}/$((${TRIAL}-1))/node1/ ${RESUME_INCIDENT_DIR}/${TRIAL}/node1 2>&1
    rsync -ar --exclude='*core*' ${RESUME_INCIDENT_DIR}/$((${TRIAL}-1))/node2/ ${RESUME_INCIDENT_DIR}/${TRIAL}/node2 2>&1
    rsync -ar --exclude='*core*' ${RESUME_INCIDENT_DIR}/$((${TRIAL}-1))/node3/ ${RESUME_INCIDENT_DIR}/${TRIAL}/node3 2>&1
    echoit "Copying config file from ${INCIDENT_DIR}/${TRIAL}/n1.cnf into ${RESUME_INCIDENT_DIR}/${TRIAL}/n1.cnf"
    echoit "Copying config file from ${INCIDENT_DIR}/${TRIAL}/n2.cnf into ${RESUME_INCIDENT_DIR}/${TRIAL}/n2.cnf"
    echoit "Copying config file from ${INCIDENT_DIR}/${TRIAL}/n3.cnf into ${RESUME_INCIDENT_DIR}/${TRIAL}/n3.cnf"
    cp ${INCIDENT_DIR}/${TRIAL}/n1.cnf ${RESUME_INCIDENT_DIR}/${TRIAL}/n1.cnf
    cp ${INCIDENT_DIR}/${TRIAL}/n2.cnf ${RESUME_INCIDENT_DIR}/${TRIAL}/n2.cnf
    cp ${INCIDENT_DIR}/${TRIAL}/n3.cnf ${RESUME_INCIDENT_DIR}/${TRIAL}/n3.cnf

    sed -i "s|$RUNDIR/$TRIAL|$RESUME_INCIDENT_DIR/$TRIAL|g" ${RESUME_INCIDENT_DIR}/${TRIAL}/n1.cnf
    sed -i "s|$RUNDIR/$TRIAL|$RESUME_INCIDENT_DIR/$TRIAL|g" ${RESUME_INCIDENT_DIR}/${TRIAL}/n2.cnf
    sed -i "s|$RUNDIR/$TRIAL|$RESUME_INCIDENT_DIR/$TRIAL|g" ${RESUME_INCIDENT_DIR}/${TRIAL}/n3.cnf

    sed -i "s|$INCIDENT_DIR/$TRIAL|$RESUME_INCIDENT_DIR/$TRIAL|g" ${RESUME_INCIDENT_DIR}/${TRIAL}/n1.cnf
    sed -i "s|$INCIDENT_DIR/$TRIAL|$RESUME_INCIDENT_DIR/$TRIAL|g" ${RESUME_INCIDENT_DIR}/${TRIAL}/n2.cnf
    sed -i "s|$INCIDENT_DIR/$TRIAL|$RESUME_INCIDENT_DIR/$TRIAL|g" ${RESUME_INCIDENT_DIR}/${TRIAL}/n3.cnf

    sed -i 's|safe_to_bootstrap:.*$|safe_to_bootstrap: 1|' ${RESUME_INCIDENT_DIR}/${TRIAL}/node1/grastate.dat
  fi

# Start server
  if [ $PXC -eq 0 ]; then
    SOCKET=${RESUME_INCIDENT_DIR}/${TRIAL}/socket.sock
    DATADIR=${RESUME_INCIDENT_DIR}/${TRIAL}/data
    TEMPDIR=${RESUME_INCIDENT_DIR}/${TRIAL}/tmp
    ERROR=${RESUME_INCIDENT_DIR}/${TRIAL}/log/master.err
    PID_FILE=${RESUME_INCIDENT_DIR}/${TRIAL}/pid.pid
    start_server
  elif [ $PXC -eq 1 ]; then
    SOCKET1=${RESUME_INCIDENT_DIR}/${TRIAL}/node1/node1_socket.sock
    SOCKET2=${RESUME_INCIDENT_DIR}/${TRIAL}/node2/node2_socket.sock
    SOCKET3=${RESUME_INCIDENT_DIR}/${TRIAL}/node3/node3_socket.sock
    CONFIG1=${RESUME_INCIDENT_DIR}/${TRIAL}/n1.cnf
    CONFIG2=${RESUME_INCIDENT_DIR}/${TRIAL}/n2.cnf
    CONFIG3=${RESUME_INCIDENT_DIR}/${TRIAL}/n3.cnf
    ERR_FILE1=${RESUME_INCIDENT_DIR}/${TRIAL}/node1/node1.err
    ERR_FILE2=${RESUME_INCIDENT_DIR}/${TRIAL}/node2/node2.err
    ERR_FILE3=${RESUME_INCIDENT_DIR}/${TRIAL}/node3/node3.err
    start_pxc_server
  fi

# Start pstress
  LOGDIR=${RESUME_INCIDENT_DIR}/${TRIAL}
  METADATA_PATH=${RESUME_INCIDENT_DIR}
  start_pstress

# Terminate mysqld
  kill_server $SIGNAL
  sleep 5 #^ Ensure the mysqld is gone completely
  if [ $(ls -l ${RESUME_INCIDENT_DIR}/${TRIAL}/*/*core* 2>/dev/null | wc -l) -ge 1 ]; then
    echoit "mysqld coredump detected at $(ls ${RESUME_INCIDENT_DIR}/${TRIAL}/*/*core* 2>/dev/null)"
    echoit "Bug found (as per error log): $(${SCRIPT_PWD}/search_string.sh ${RESUME_INCIDENT_DIR}/${TRIAL}/log/master.err)"
  fi
  echoit "pstress run details:$(grep -i 'SUMMARY.*queries failed' ${RESUME_INCIDENT_DIR}/${TRIAL}/*.sql ${RESUME_INCIDENT_DIR}/${TRIAL}/*.log | sed 's|.*:||')"
}

# Start pstress on running server
function start_pstress() {
  echoit "Starting pstress run for step:${TRIAL} ..."
  if [ ${PXC} -eq 0 ]; then
    CMD="${PSTRESS_BIN} --database=test --threads=${THREADS} --queries-per-thread=${QUERIES_PER_THREAD} --logdir=${LOGDIR} --user=root --socket=$SOCKET --seed ${SEED} --step ${TRIAL} --metadata-path ${METADATA_PATH}/ --seconds ${PSTRESS_RUN_TIMEOUT} ${DYNAMIC_QUERY_PARAMETER} --engine=${ENGINE}"
    echoit "$CMD"
    $CMD > ${LOGDIR}/pstress.log 2>&1 &
    PSPID="$!"
  elif [ ${PXC} -eq 1 ]; then
    CMD="${PSTRESS_BIN} --database=test --threads=${THREADS} --queries-per-thread=${QUERIES_PER_THREAD} --logdir=${LOGDIR} --user=root --socket=${SOCKET1} --seed ${SEED} --step ${TRIAL} --metadata-path ${METADATA_PATH}/ --seconds ${PSTRESS_RUN_TIMEOUT} ${DYNAMIC_QUERY_PARAMETER} --engine=${ENGINE}"
    echoit "$CMD"
    $CMD > ${LOGDIR}/pstress.log 2>&1 &
    PSPID="$!"
  fi

  echoit "pstress running (Max duration: ${PSTRESS_RUN_TIMEOUT}s)..."
  for X in $(seq 1 ${PSTRESS_RUN_TIMEOUT}); do
    sleep 1
    if [ "`ps -ef | grep $PSPID | grep -v grep`" == "" ]; then  # pstress ended
      break
    fi
    if [ $X -ge ${PSTRESS_RUN_TIMEOUT} ]; then
      echoit "${PSTRESS_RUN_TIMEOUT}s timeout reached. Terminating this trial..."
      if [ ${TIMEOUT_INCREMENT} != 0 ]; then
        echoit "TIMEOUT_INCREMENT option was enabled and set to ${TIMEOUT_INCREMENT} sec"
        echoit "${TIMEOUT_INCREMENT}s will be added to the next trial timeout."
      else
        echoit "TIMEOUT_INCREMENT option was disabled and set to 0"
      fi
      PSTRESS_RUN_TIMEOUT=$[ ${PSTRESS_RUN_TIMEOUT} + ${TIMEOUT_INCREMENT} ]
      break
    fi
  done
}

function pxc_startup_status() {
  NR=$1
  for X in $(seq 0 ${PXC_START_TIMEOUT}); do
    sleep 1
    if [ ${RESUME_MODE} -eq 1 ]; then
      if ${BASEDIR}/bin/mysqladmin -uroot -S${RESUME_INCIDENT_DIR}/${TRIAL}/node$NR/node${NR}_socket.sock ping > /dev/null 2>&1; then
        break
      fi
    elif [ $REPEAT_MODE -eq 1 ]; then
      if ${BASEDIR}/bin/mysqladmin -uroot -S${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/node$NR/node${NR}_socket.sock ping > /dev/null 2>&1; then
        break
      fi
    fi
    if [ $X -eq ${PXC_START_TIMEOUT} ]; then
      if [ ${RESUME_MODE} -eq 1 ]; then
        echo "Could not start the server. Check error logs: ${RESUME_INCIDENT_DIR}/${TRIAL}/node$NR/node$NR.err"
      else
        echo "Could not start the server. Check error logs: ${RESUME_INCIDENT_DIR}/${TRIAL}.$COUNT/node$NR/node$NR.err"
      fi
      exit 1
    fi
  done
}

parse_args $*
if [ $# -eq 0 ]; then
  Help
  exit 1
fi

if [ "${RESUME_DIR}" == "" ]; then
  Help
  exit 1
elif [ "${INCIDENT_DIR}" == "" ]; then
  Help
  exit 1
elif [ "${STEP}" == "" ]; then
  Help
  exit 1
fi

# Additional checks
# 1. Check if provided incident directory exists
# 2. Check if provided resume directory exists
if [ ! -d ${INCIDENT_DIR} ]; then
  echo "${INCIDENT_DIR} path does not exist"
  exit 1
elif [ ! -d ${RESUME_DIR} ]; then
  echo "${RESUME_DIR} path does not exist"
  exit 1
fi

if [ ${REPEAT_MODE} -eq 1 ]; then
  echo "Running pstress in repeat mode"
  RESUME_MODE=0
elif [ ${RESUME_MODE} -eq 1 ]; then
  echo "Running pstress in resume mode"
else
  echo "Invalid option(s) passed. Terminating..."
  exit 1
fi

CONFIGURATION_FILE=$(find ${INCIDENT_DIR} -name '*.conf' | xargs readlink -f)
if [[ ${CONFIGURATION_FILE} =~ "pstress-run-PXC" ]]; then PXC=1; fi
source ${CONFIGURATION_FILE}
RUNDIR=$(cat ${INCIDENT_DIR}/pstress-run.log | grep "Rundir:" | grep -oP '(?<=Rundir: )[^ ]*')
if [ -f ${INCIDENT_DIR}/seed ]; then
  SEED=$(cat ${INCIDENT_DIR}/seed)
else
  echo "Unable to find seed file in the ${INCIDENT_DIR}"
  echo "Make sure to use the parent incident directory generated by pstress"
  exit 1
fi

if [ ${ENGINE} == "RocksDB" ]; then
  ENCRYPTION_RUN=0
fi

if [ ${ENCRYPTION_RUN} -eq 0 ]; then
 PLUGIN_KEYRING_FILE=0
 COMPONENT_KEYRING_FILE=0
fi

if [ ${PXC} -eq 1 ]; then
  DYNAMIC_QUERY_PARAMETER="$DYNAMIC_QUERY_PARAMETER --primary-key-probability 100 --alt-discard-tbs 0"
  if [ ${ENCRYPTION_RUN} -eq 1 ]; then
    if [ ${PLUGIN_KEYRING_FILE} -eq 1 ]; then
      KEYRING_PARAM="--early-plugin-load=keyring_file.so --keyring_file_data=keyring"
    fi
  elif [ ${ENCRYPTION_RUN} -eq 0 ]; then
     DYNAMIC_QUERY_PARAMETER="$DYNAMIC_QUERY_PARAMETER --no-encryption"
  fi
  if [ ${GCACHE_ENCRYPTION} -eq 0 ]; then
    DYNAMIC_QUERY_PARAMETER="$DYNAMIC_QUERY_PARAMETER --rotate-gcache-key 0"
  fi
elif [ ${PXC} -eq 0 ]; then
  if [ ${ENCRYPTION_RUN} -eq 1 ]; then
    if [ ${PLUGIN_KEYRING_FILE} -eq 1 ]; then
      KEYRING_PARAM="--early-plugin-load=keyring_file.so --keyring_file_data=keyring"
    fi
  elif [ ${ENCRYPTION_RUN} -eq 0 ]; then
    DYNAMIC_QUERY_PARAMETER="$DYNAMIC_QUERY_PARAMETER --no-encryption"
  fi
fi

# Find mysqld binary
if [ -r ${INCIDENT_DIR}/mysqld/bin/mysqld ]; then
  BIN=${INCIDENT_DIR}/mysqld/bin/mysqld
else
  echoit "Assert: there is no (script readable) mysqld binary at ${INCIDENT_DIR}/bin/mysqld ?"
  exit 1
fi

rm -rf ${RESUME_DIR}/${RANDOMD}
RESUME_INCIDENT_DIR=${RESUME_DIR}/${RANDOMD}

if [ ${PXC} -eq 1 ]; then
  mkdir -p ${RESUME_INCIDENT_DIR}/cert
  cp ${INCIDENT_DIR}/node1.template/*.pem ${RESUME_INCIDENT_DIR}/cert/
fi

if [ ${RESUME_MODE} -eq 1 ]; then
  echo "Resuming pstress iterations from step:${STEP}"
  TRIAL=$[ ${STEP} - 1 ]
  if [ ${STEP} -gt 1 ]; then
    echo "Generating new trial workdir ${RESUME_INCIDENT_DIR}/${TRIAL}"
    mkdir -p ${RESUME_INCIDENT_DIR}/${TRIAL}
    if [ ${PXC} -eq 0 ]; then
      echo "Taking backup of datadir from ${INCIDENT_DIR}/${TRIAL}/data into ${RESUME_INCIDENT_DIR}/${TRIAL}/"
      rsync -ar --exclude='*core*' ${INCIDENT_DIR}/${TRIAL}/data/ ${RESUME_INCIDENT_DIR}/${TRIAL}/data 2>&1
    elif [ ${PXC} -eq 1 ]; then
      echo "Taking backup of datadir from ${INCIDENT_DIR}/${TRIAL}/node1 into ${RESUME_INCIDENT_DIR}/${TRIAL}/"
      echo "Taking backup of datadir from ${INCIDENT_DIR}/${TRIAL}/node2 into ${RESUME_INCIDENT_DIR}/${TRIAL}/"
      echo "Taking backup of datadir from ${INCIDENT_DIR}/${TRIAL}/node3 into ${RESUME_INCIDENT_DIR}/${TRIAL}/"
      rsync -ar --exclude='*core*' ${INCIDENT_DIR}/${TRIAL}/node1/ ${RESUME_INCIDENT_DIR}/${TRIAL}/node1 2>&1
      rsync -ar --exclude='*core*' ${INCIDENT_DIR}/${TRIAL}/node2/ ${RESUME_INCIDENT_DIR}/${TRIAL}/node2 2>&1
      rsync -ar --exclude='*core*' ${INCIDENT_DIR}/${TRIAL}/node3/ ${RESUME_INCIDENT_DIR}/${TRIAL}/node3 2>&1
    fi
    echo "Copying step_${TRIAL}.dll file into ${RESUME_INCIDENT_DIR}"
  elif [ ${STEP} -eq 1 ]; then
    echo "If you intend to resume from step 1, execute pstress-run.sh using same seed number"
    exit 1
  else
    echo "Invalid step provided. Exiting..."
    exit 1
  fi

  if [ -f ${INCIDENT_DIR}/step_${TRIAL}.dll ]; then
    cp ${INCIDENT_DIR}/step_${TRIAL}.dll ${RESUME_INCIDENT_DIR}
  else
    echo "The step_${TRIAL}.dll file does not exist. Can not continue"
    exit 1
  fi

  LEFT_TRIALS=$[ ${TRIALS} - ${TRIAL} ]
  for X in $(seq 1 ${LEFT_TRIALS}); do
    resume_pstress
  done
elif [ ${REPEAT_MODE} -eq 1 ]; then
  echo "Repeating step ${STEP} (${REPEAT}) number of times"
  mkdir -p ${RESUME_INCIDENT_DIR}/${STEP}
  if [ ${STEP} -gt 1 ]; then
    if [ ${PXC} -eq 0 ]; then
      echo "Taking backup of datadir from ${INCIDENT_DIR}/${STEP}/data into ${RESUME_INCIDENT_DIR}/${STEP}/"
      rsync -ar --exclude='*core*' ${INCIDENT_DIR}/${STEP}/data/ ${RESUME_INCIDENT_DIR}/${STEP}/data 2>&1
    elif [ ${PXC} -eq 1 ]; then
      echo "Taking backup of datadir from ${INCIDENT_DIR}/${STEP}/node1 into ${RESUME_INCIDENT_DIR}/${STEP}/"
      echo "Taking backup of datadir from ${INCIDENT_DIR}/${STEP}/node2 into ${RESUME_INCIDENT_DIR}/${STEP}/"
      echo "Taking backup of datadir from ${INCIDENT_DIR}/${STEP}/node3 into ${RESUME_INCIDENT_DIR}/${STEP}/"
      rsync -ar --exclude='*core*' ${INCIDENT_DIR}/${STEP}/node1/ ${RESUME_INCIDENT_DIR}/${STEP}/node1 2>&1
      rsync -ar --exclude='*core*' ${INCIDENT_DIR}/${STEP}/node2/ ${RESUME_INCIDENT_DIR}/${STEP}/node2 2>&1
      rsync -ar --exclude='*core*' ${INCIDENT_DIR}/${STEP}/node3/ ${RESUME_INCIDENT_DIR}/${STEP}/node3 2>&1
    fi
    echo "Copying step_$((${STEP}-1)).dll file into ${RESUME_INCIDENT_DIR}"
    cp ${INCIDENT_DIR}/step_$((${STEP}-1)).dll ${RESUME_INCIDENT_DIR}
  elif [ ${STEP} -eq 1 ]; then
    echo "If you intend to repeat step 1, please perform a normal run using same seed number"
    exit 1
  else
    echo "Invalid step provided. Exiting..."
    exit 1
  fi

  for COUNT in $(seq 1 ${REPEAT}); do
    repeat_step
  done
fi
echoit "Done. Attempting to cleanup the pstress rundir ${RUNDIR}..."
rm -rf ${RUNDIR}
if [ ${RESUME_MODE} -eq 1 ]; then
  echoit "The results of this run can be found in the resume dir ${RESUME_DIR}..."
elif [ ${REPEAT_MODE} -eq 1 ]; then
  echoit "The results of this run can be found in the repeat dir ${RESUME_DIR}..."
fi
echoit "Done. Exiting $0 with exit code 0..."
exit 0
