#!/usr/bin/ksh
# Script:  ora_hot_bkup.ksh
# Description: 
#	This file backs up database files to ADSM.  It also
#       creates restore list that can be used by the ora_hot_restore.ksh
#       script to generate a restore script.
#
# Updated: 11/11/2002
#  modified for lower case SID
# Updated: 04/18/2014 - Jay - backup db files to disk (zipped). Write to TSM after.

export mail_file=/tmp/`date +%d+%T`.mail
#jay#export mail_list=it-database-services@glovia.com
export mail_list=support@glovia.com
export host=`hostname`;
export backup_type=hot


function init
{

echo "Verifying Script Directories";
if [[ -d $HOME/scripts ]]
then
export SCRIPT_DIR=$HOME/scripts
else
echo "No script directory: $HOME/scripts"
exit;
fi

# export Environment variables from <sid>_ora_env file
echo "Exporting Environment variables";
if [[ ! -f $1 ]]
then 
echo "INVALID ENVIRONMENT FILE: $1";
echo "USAGE:  ora_hot_bkup.ksh <sid>_ora_env";
return -1;
else
echo "VALID ENVIRONMENT FILE: $1";
export env_file=$1;
chmod u+x $1; #briefly give execute permission
. $1;    
chmod u-x $1;
fi

# set oracle env from IBM standard
. ~/.sentry.env_RMAN

# create general backup script folders and controlfile backup area
echo "Verifying backup folders";
if [[ ! -d $SCRIPT_DIR/backup ]]
then 
mkdir $SCRIPT_DIR/backup
mkdir $SCRIPT_DIR/backup/$sid_l
fi

if [[ ! -d $SCRIPT_DIR/backup/$sid_l ]]
then
mkdir $SCRIPT_DIR/backup/$sid_l
fi
export BSCRIPT_DIR=$SCRIPT_DIR/backup/$sid_l;
export BDB_DIR=/rman_oracle/backups
# create backup controlfile location if not present
if [[ ! -d $CTRL_BKUP_LOC ]]
then 
mkdir $CTRL_BKUP_LOC;
fi

# create dsm.opt.file if not present
if [[ ! -f $BSCRIPT_DIR/dsm.opt.hot.$sid_l ]]
then
echo "Create DSM_CONFIG file";
printf "Servername\t%s\n" $DSM_Servername > $BSCRIPT_DIR/dsm.opt.hot.$sid_l;
printf "password\t%s" $DSM_Password >> $BSCRIPT_DIR/dsm.opt.hot.$sid_l;
else 
echo "DSM_CONFIG file found";
fi
echo ORACLE_HOME: $ORACLE_HOME;
#Export Remaining Environment variables
export host=`hostname`;
export LOG=$BSCRIPT_DIR/backup.log
export sid_l=`echo $SID | tr '[:upper:]' '[:lower:]'`
export DSM_CONFIG=$BSCRIPT_DIR/dsm.opt.hot.$sid_l
export DSM_LOG=$BSCRIPT_DIR
export mail_file=/tmp/`date +%d+%T`.mail
#export mail_list=dbaprod@glovia.com
ORACLE_SID=$SID; export ORACLE_SID
ORACLE_TERM=xterm; export ORACLE_TERM
PATH=$PATH:$ORACLE_HOME/bin:/usr/lbin:/usr/bin:/usr/ccs/bin:/opt/cobol/bin:. export PATH
PS1=$ORACLE_SID\>
#****** OTHER VARIBLES *********************
echo "ENVIRONMENT VARIABLES SETUP FOR $host";
export BEGIN_TIME=`date`;
echo "BEGINNING HOT BACKUP OF $SID on $host at $BEGIN_TIME";
# REMOVE PREVIOUS LISTS...   wlm 4/30/2002

server=`hostname`

CLUSTER=""

if [[ -f ~/support/.cluster ]] ; then
    CLUSTER="`cat ~/support/.cluster | tr ' ' '_' | grep [a-zA-Z] | head -1 | awk '{print substr($1,1,35)}'`";
fi

ftpstart=`date "+%m/%d %H:%M"`
ftpdir=$HOME/support/reports

export ftp_name_start=`hostname`_

ftpFile=$ftpdir/${ftp_name_start}`date "+%m_%d_%H_%M"`
. ~/support/bin/dba_fun

oe $ORACLE_SID
$ORACLE_HOME/bin/sqlplus  -s /nolog>$ftpFile<<EOF
set heading off
set feedback off
connect / as sysdba
select 'DBSIZEGB:' || trunc(sum(bytes)/1024/1024/1024) from dba_data_files;
exit
EOF

DBSIZEGB=`grep DBSIZEGB $ftpFile | awk -F: '{print $2}'`

rm -f $ftpFile

if [[ -f $BSCRIPT_DIR/*.lst ]]
then
 #rm $BSCRIPT_DIR/*.lst;       #wlm 4/30/2002
 echo "HELLO"
fi
}

function backup_initora
{
echo "DSM_CONFIG: $DSM_CONFIG";
backup_files $ORACLE_HOME/dbs/init$SID.ora
if [[ $? -eq 0 ]]
then
  print " Backup of $ORACLE_HOME/dbs/init$SID.ora COMPLETE "
else
  print " Backup of $ORACLE_HOME/dbs/init$SID.ora Failed "
  return -1;
fi
print "$ORACLE_HOME/dbs/init$SID.ora" > $BSCRIPT_DIR/restore_inito.lst
return 0;
}

function backup_archivelogs
{
sqlplus -s /nolog<<EOF
connect system/$PASS;
alter system switch logfile;
alter system switch logfile;
!ls $ARCH_LOC > $BSCRIPT_DIR/archive_file_list.txt 
!sleep 10
EXIT
EOF
cd /
print "" >  $BSCRIPT_DIR/restore_arc.lst;  #wlm 6/12/2002
backup_files $BSCRIPT_DIR/archive_file_list.txt
  if [[ $? -eq 0 ]]
  then
    print " Backup of $BSCRIPT_DIR/archive_file_list.txt COMPLETE "
    print "$BSCRIPT_DIR/archive_file_list.txt" > $BSCRIPT_DIR/restore_arc.lst;  
  else
    print " Backup of $BSCRIPT_DIR/archive_file_list.txt  Failed "
    return -1;
  fi
  cat $BSCRIPT_DIR/archive_file_list.txt | while read FILENAME
  do
    echo "Copying Archive file " $FILENAME
    backup_files $ARCH_LOC/$FILENAME
    if [[ $? -eq 0 ]]
    then
      print "Backup of $ARCH_LOC/$FILENAME  COMPLETE "
      print "$ARCH_LOC/$FILENAME" >> $BSCRIPT_DIR/restore_arc.lst; 
      rm $ARCH_LOC/$FILENAME
    else
      print "Backup of $ARCH_LOC/$FILENAME FAILED "
      return -1;
    fi
  done
return 0;
}

function backup_controlfile
{
print "" > $BSCRIPT_DIR/restore_con.lst;

date
sqlplus -s /nolog<<EOF
connect system/$PASS;
alter system switch logfile;
!echo "Copying CONTROLFILE"
!rm $CTRL_BKUP_LOC/ctrlbk1.ctl
alter database backup controlfile to trace;
alter database backup controlfile to
 '$CTRL_BKUP_LOC/ctrlbk1.ctl';
EXIT
EOF
 backup_files $CTRL_BKUP_LOC/ctrlbk1.ctl
 if [[ $? -eq 0 ]]
 then
   print " Backup of $CTRL_BKUP_LOC/ctrlbk1.ctl COMPLETE "
 else
   print " Backup of $CTRL_BKUP_LOC/ctrlbk1.ctl Failed "
   return -1; 
 fi
print "$CTRL_BKUP_LOC/ctrlbk1.ctl" >> $BSCRIPT_DIR/restore_con.lst;
return 0;
}

function backup_redologs
{
#create file list for redo logs

sqlplus -s /nolog<<EOF
connect system/$PASS;
set echo off;
set pagesize 0;
set linesize 200;
set verify off;
set feedback off;
set echo off;
1 select member from v\$logfile;
save $BSCRIPT_DIR/logfile1.sql replace;
spool $BSCRIPT_DIR/logfile.lst;
@$BSCRIPT_DIR/logfile1.sql;
spool off;
exit;
EOF

echo "BACKING UP REDOLOGS";

 backup_files $BSCRIPT_DIR/logfile.lst;
 if [[ $? -eq 0 ]]
 then
   print " Backup of $BSCRIPT_DIR/logfile.lst COMPLETE "
 else
   print " Backup of $BSCRIPT_DIR/logfile.lst Failed "
   return -1; 
 fi
print "$BSCRIPT_DIR/logfile.lst" > $BSCRIPT_DIR/restore_logs.lst;

for FILENAME in `cat $BSCRIPT_DIR/logfile.lst`
do
    echo "Backup of $FILENAME IN PROGRESS";
    backup_files $FILENAME;
    if [[ $? -eq 0 ]]
    then
      print "Backup of $FILENAME  COMPLETE "
      print $FILENAME >> $BSCRIPT_DIR/restore_logs.lst;
    else
      print "Backup of $FILENAME FAILED "
      return -1;
    fi
done
return 0;

}
function backup_tablespaces
{
echo "************** BACKUP_TABLESPACES ****************"
sqlplus -s /nolog<<EOF 
connect system/$PASS;
set heading off;
set verify off;
set feedback off;
set pagesize 0;
select tablespace_name from dba_tablespaces;
spool $BSCRIPT_DIR/tablespace.lst
/
spool off;
EOF
cat $BSCRIPT_DIR/tablespace.lst | awk '!/SQL/ { print $1; }' > $BSCRIPT_DIR/temp1
if [[ $? -ne 0 ]]
then
 return -1;
fi

cat $BSCRIPT_DIR/temp1 > $BSCRIPT_DIR/tablespace.lst

#*** create a ksh backup script for each tablespace
for TABLESPACE in `cat $BSCRIPT_DIR/tablespace.lst`
  do
     echo TABLESPACE: $TABLESPACE
	 tblsp_script $TABLESPACE
	   done

	   #*** run each tablspace backup script
	   echo "run tablespace_backup scripts here!!!!!";
	   for TABLESPACE in `cat $BSCRIPT_DIR/tablespace.lst`
	   do
	     sleep 10;
	     $BSCRIPT_DIR/$TABLESPACE\_bkupx.ksh
  done
  wait;
  echo "TABLESPACE BACKUPS COMPLETE";
return 0;
}



function tblsp_script
{
echo TABLESPACE: $1
echo "************ TBLSP_SCRIPT **********************"
print "
set heading off
set feedback off
set linesize 100
set pagesize 200
spool $BSCRIPT_DIR/alter_tblsp_$1ex.sql 
col tablespace_name noprint
col dummy noprint
select 1 dummy, a.tablespace_name, 'alter tablespace ' || a.tablespace_name || ' begin backup;'
from dba_tablespaces a
where tablespace_name='$1'
  union
  select 2 dummy, b.tablespace_name, '' || b.file_name
  from dba_data_files b
  where tablespace_name='$1'
    union
    select 3 dummy, a.tablespace_name, 'alter tablespace ' || a.tablespace_name || ' end backup;'
    from dba_tablespaces a
    where tablespace_name='$1'
    order by 2, 1;
spool off;
" > $BSCRIPT_DIR/alter_tblsp.sql

sqlplus -s system/$PASS<<EOF
@$BSCRIPT_DIR/alter_tblsp
exit;
EOF

print "
chmod u+x $env_file; #briefly give execute permission
. $env_file;
chmod u-x $env_file;

 

function backup_db_files
{
  [[ \$# -eq 0 ]] && print \" Null file name ignored....\" && return 0
  prepare_err_file;
  dumpto=/dev/null
 [[ -n \$LOG ]] && dumpto=\$LOG
  echo \$*
  print \$* >> \$BSCRIPT_DIR/restore.lst;
## Backup to disk compressed
  #fname=`basename \$*`
  gzip < \$* > $BDB_DIR/`basename \$*`.gz
  #dsmc inc \$*  > \$dumpto 2>&1
  #       dsmc inc -quiet $*
  #check_err_file;
  if [[ \$? -ne 0 ]]
  then
    print
    print \"The requested backup returned errors...........\"
    print \"Please check the dsm errorlog entries listed below:\"
    print
    cat \$DSM_LOG/dsmerror.log.extra
    print
  if [[ -n \$mail_file ]];
  then
    print >> \$mail_file
    cat \$DSM_LOG/dsmerror.log.extra >> \$mail_file
    print >> \$mail_file

  fi
  return 1
  fi
}
function check_dsm
{
if [[ -z \$DSM_CONFIG || -z \$DSM_LOG ]];
then
print \"Undefined DSM environment variables\"
exit
fi
}

function check_err_file
{
lines_before=`wc -l \$DSM_LOG/dsmerror.log.original|awk '{print \$1}'`
lines_after=`wc -l \$DSM_LOG/dsmerror.log|awk '{print \$1}'`
if [[ \$lines_before -ne \$lines_after ]];
then
  new_lines=\$((\$lines_after - \$lines_before))
  tail -\$new_lines \$DSM_LOG/dsmerror.log > \$DSM_LOG/dsmerror.log.extra
  return 1
fi
}

function mail_errors
{
if [[ -n \$mail_file && -n \$mail_list ]];
then
  if [[ -s \$mail_file ]];
  then
    print \"subject: \$sid_l hot backup problems on \$host\" > \$mail_file.tmp
    print >> \$mail_file.tmp
    cat \$mail_file >> \$mail_file.tmp
    mail \$mail_list < \$mail_file.tmp


ftpend=\`date "+%m/%d %H:%M"\`

stat="Failed"

cat >\$ftpFile<<_E
SERVER: \$server
CUID: gardener
SID: \$ORACLE_SID
START TIME: \$ftpstart
END TIME: \$ftpend
DBMS: oracle
STATUS: \$stat
TYPE: Hot
DEST: adsm
TSM_SVR:
TSM_NODE:
CLUSTER: \$CLUSTER
DBSIZEGB: \$DBSIZEGB
_E

ftp -in toolsdbdb.qintra.com<<_E
user toolsusr TE15n_sDy
cd dms/incoming/backup_reports
lcd /home/oraclerm/support/reports
mput \${ftp_name_start}*
bye
_E

rm -f /home/oraclerm/support/reports/\${ftp_name_start}*
rm -f /home/oraclerm/support/reports/${ftp_name_start}*

  fi
fi
}

function prepare_err_file
{
   check_dsm;
   if [[ ! -a \$DSM_LOG/dsmerror.log ]];
   then
      touch \$DSM_LOG/dsmerror.log
   fi
   rm -f \$DSM_LOG/dsmerror.log.extra
   cp \$DSM_LOG/dsmerror.log \$DSM_LOG/dsmerror.log.original
}

function obtain_lock 
{
found1=0;
x=0; 
while [[ \$found1 -eq 0 ]]
do
  for dsmc_session in \`ps -ef | grep dsmc | awk '{ print \$2 }'\` 
  do 
    let \"x = x + 1\";
  done
   let \"x = x - 1\"; 
  if [[ \$x -lt $num_locks ]]
    then
      found1=1;
      break;
    else 
      sleep 20;
    fi
    x=0;
done
} " > $BSCRIPT_DIR/_bkup.ksh

cp $BSCRIPT_DIR/_bkup.ksh $BSCRIPT_DIR/$1_bkupx.ksh
chmod 755 $BSCRIPT_DIR/$1_bkupx.ksh

print "
cat $BSCRIPT_DIR/alter_tblsp_$1ex.sql | while read FILENAME
   do
  if [[ -z \$FILENAME ]]; then continue
	   fi

	   if [[ \${FILENAME%%alter*} != \$FILENAME ]];
	   then
 		   print \$FILENAME > \$DSM_LOG/sqlplus.tmp
		   sqlplus -s system/$PASS < \$DSM_LOG/sqlplus.tmp
	   continue

	   else
#		   obtain_lock; 
		   echo Backup of \$FILENAME IN PROGRESS; 
		   backup_db_files \$FILENAME
	           if [[ \$? -ne 0 ]]
	           then
	             print "Backup of \$FILENAME FAILED " 
	           else
		     print "Backup of \$FILENAME COMPLETE "
		   fi
  fi
  done 
" >> $BSCRIPT_DIR/$1_bkupx.ksh  
 return 1;
}

function clean_child_processes
{
ps -ef | awk  '/bkupx/ {printf "kill -9 %s\n",$2}' > $BSCRIPT_DIR/child_processes.ksh
chmod 755 $BSCRIPT_DIR/child_processes.ksh
$BSCRIPT_DIR/child_processes.ksh > $BSCRIPT_DIR/child_process.log
rm $BSCRIPT_DIR/child_processes.ksh
return 1;
}

function backup_scriptdir 
{
ls $BSCRIPT_DIR | grep -v "dsme*"  > $BSCRIPT_DIR/file_list;   # 6/24/2002
file_list=`cat $BSCRIPT_DIR/file_list`                         # 6/24/2002

if [[ -f $BSCRIPT_DIR/restore_scr.lst ]]
then 
 rm $BSCRIPT_DIR/restore_scr.lst
fi

touch $BSCRIPT_DIR/restore_scr.lst;

for file1 in $file_list
do
  backup_files $BSCRIPT_DIR/$file1;
  if [[ $? -eq 0 ]]
  then
    print " Backup of $BSCRIPT_DIR/$file1 COMPLETE "
    print "$BSCRIPT_DIR/$file1" >> $BSCRIPT_DIR/restore_scr.lst
  else
    print " Backup of $BSCRIPT_DIR/$file1 Failed "
    return -1;
  fi
done
return 0;
}

function check_dsm
{
if [[ -z $DSM_CONFIG || -z $DSM_LOG ]];
then
print "Undefined DSM environment variables"
exit
fi
}

function check_err_file
{
lines_before=`wc -l $DSM_LOG/dsmerror.log.original|awk '{print $1}'`
lines_after=`wc -l $DSM_LOG/dsmerror.log|awk '{print $1}'`
if [[ $lines_before -ne $lines_after ]];
then
  new_lines=$(($lines_after - $lines_before))
  tail -$new_lines $DSM_LOG/dsmerror.log > $DSM_LOG/dsmerror.log.extra
  return 1
fi
}

function mail_errors
{
if [[ -n $mail_file && -n $mail_list ]];
then
  if [[ -s $mail_file ]];
  then
    print "subject: $sid_l hot backup problems on $host" > $mail_file.tmp
    print >> $mail_file.tmp
    cat $mail_file >> $mail_file.tmp
    mail $mail_list < $mail_file.tmp
  fi
fi
}

function prepare_err_file
{
   check_dsm;
   if [[ ! -a $DSM_LOG/dsmerror.log ]];
   then
      touch $DSM_LOG/dsmerror.log
   fi
   rm -f $DSM_LOG/dsmerror.log.extra
   cp $DSM_LOG/dsmerror.log $DSM_LOG/dsmerror.log.original
}

function backup_files
{
  [[ $# -eq 0 ]] && print " Null file name ignored...." && return 0
  prepare_err_file;
  dumpto=/dev/null
 [[ -n $LOG ]] && dumpto=$LOG
  echo $*
  print $* >> $BSCRIPT_DIR/restore.lst;  
  dsmc inc $*  > $dumpto 2>&1
  #       dsmc inc -quiet $*
  check_err_file;
  if [[ $? -ne 0 ]]
  then
    print
    print "The requested backup returned errors..........."
    print "Please check the dsm errorlog entries listed below:"
    print
    cat $DSM_LOG/dsmerror.log.extra
    print
  if [[ -n $mail_file ]];
  then
    print >> $mail_file
    cat $DSM_LOG/dsmerror.log.extra >> $mail_file
    print >> $mail_file
  fi
  return 1
  fi
}

function insert_same_day
{
sqlplus -s /nolog<<!
conn bkuplog/bkuplog@dbs1;
set echo on;
set feedback on;
set verify on;
insert into backups
(
bkup_id, start_time, end_time, duration, sid, hostname, sessions, dbsize, execution_date, type
)
values
(
sq_backups.nextval,
to_date('$S_DAY-$S_MON-$S_YR $S_HH:$S_MM:$S_SS','DD-MON-YYYY HH24:MI:SS'),
to_date('$E_DAY-$E_MON-$E_YR $E_HH:$E_MM:$E_SS','DD-MON-YYYY HH24:MI:SS'),
(($E_HH*3600+$E_MM*60+$E_SS*1)-($S_HH*3600+$S_MM*60+$S_SS*1))/60,
'$SID',
'$host',
$num_locks,
$dbsize,
sysdate,
'$backup_type');
commit;
!
}

function insert_diff_day
{
sqlplus -s /nolog<<!
conn bkuplog/bkuplog@dbs1;
set echo on;
set feedback on;
set verify on;
insert into backups
(
bkup_id, start_time, end_time, duration, sid, hostname, sessions, dbsize, execution_date, type
)
values
(
sq_backups.nextval,
to_date('$S_DAY-$S_MON-$S_YR $S_HH:$S_MM:$S_SS','DD-MON-YYYY HH24:MI:SS'),
to_date('$E_DAY-$E_MON-$E_YR $E_HH:$E_MM:$E_SS','DD-MON-YYYY HH24:MI:SS'),
(86400-($S_HH*3600+$S_MM*60+$S_SS*1)+($E_HH*3600+$E_MM*60+$E_SS*1))/60,
'$SID',
'$host',
$num_locks,
$dbsize,
sysdate,
'$backup_type');
commit;
!
}

# Jay April 21, 2014
# Changed backup to write compressed (gzip) db files to disk.
# This function will pickup those files and write to TSM.
function backup_db_flatfiles
{
ls $BDB_DIR  > $BSCRIPT_DIR/db_file_list;
db_file_list=`cat $BSCRIPT_DIR/db_file_list`  

for file1 in $db_file_list
do
  backup_files $BDB_DIR/$file1;
  if [[ $? -eq 0 ]]
  then
    print " Backup of $BDB_DIR/$file1 COMPLETE "
  else
    print " Backup of $BDB_DIR/$file1 Failed "
    return -1;
  fi
done
return 0;
}

#******* MAIN SECTION *****************
init $1;
if [[ $? -ne 0 ]]
then
  echo "ERROR: init Failed";
  print "ERROR: init Failed" > $mail_file;
  mail_errors;
  return -1;
fi
backup_initora;
if [[ $? -ne 0 ]]
then 
  echo "ERROR: backup_initora Failed"; 
  echo "ERROR: backup_initora Failed" >> $mail_file;
  mail_errors;
  return -1;
fi

backup_controlfile;
if [[ $? -ne 0 ]]
then
  echo "ERROR: backup_controlfile Failed";
  echo "ERROR: backup_controlfile Failed" >> $mail_file;
  mail_errors;         #      wlm 06-10-2002
  return -1;           #      wlm 06-10-2002
fi

#backup_redologs;       #      wlm 06-13-2002
#jay#if [[ $? -ne 0 ]]
#jay#then
#jay#  echo "ERROR: backup_redologs Failed";
#jay#  echo "ERROR: backup_redologs Failed" >> $mail_file;
#  mail_errors; 
#  return -1;
#jay#fi

#backup_archivelogs;
#if [[ $? -ne 0 ]]
#then
#  echo "ERROR: backup_archivelogs Failed";
#  echo "ERROR: backup_archivelogs Failed" >> $mail_file; 
#  mail_errors;   
#  return -1;
#fi

echo "Backup_tablespaces Started"
echo "Backup_tablespaces Started" >> $mail_file
backup_tablespaces;
if [[ $? -ne 0 ]]
then
  echo "ERROR: backup_tablespaces Failed";
  echo "ERROR: backup_tablespaces Failed" >> $mail_file;
  mail_errors;
  return -1;
fi

ls -l $BDB_DIR >> $mail_file

echo "Copy of db files to TSM Started"
echo "Copy of db files to TSM Started" >> $mail_file
backup_db_flatfiles;
if [[ $? -ne 0 ]]
then
  echo "ERROR: backup_db_flatfiles Failed";
  echo "ERROR: backup_db_flatfiles Failed" >> $mail_file;
  mail_errors;
  return -1;
fi

echo "Copy of script dir to TSM Started"
echo "Copy of script dir to TSM Started" >> $mail_file
backup_scriptdir;
if [[ $? -ne 0 ]]
then
  echo "ERROR: backup_scriptdir Failed";
  echo "ERROR: backup_scriptdir Failed" >> $mail_file;
  mail_errors; 
  return -1;
fi

# Jay - 9/17/14 - Get controlfile after the backup.
backup_controlfile;
if [[ $? -ne 0 ]]
then
  echo "ERROR: backup_controlfile Failed";
  echo "ERROR: backup_controlfile Failed" >> $mail_file;
  mail_errors;         #      wlm 06-10-2002
  return -1;           #      wlm 06-10-2002
fi


END_TIME=`date`; 

# Jay this was putting errors in the alter log, since tbs are not in backup mode.
#sqlplus  /nolog<<EOF
#connect system/$PASS;
#set pagesize 999;
#set termout off;
#set verify on;
#set feedback on;
#1 select 'alter tablespace '||tablespace_name||' end backup;'
#2 from dba_tablespaces
#spool $HOME/temp/ts$SID.sql;
#/
#spool off;
#@$HOME/temp/ts$SID.sql;
#commit;
#alter system switch logfile;
#commit;
#EOF

# MOVE THE BACKUP LOG INFO TO BACKUPS TABLE IN DBS1...
S_YR=`echo $BEGIN_TIME | awk '{print $6}' | cut -d : -f 1` ; #YEAR
S_MON=`echo $BEGIN_TIME | awk '{print $2}' | cut -d : -f 1` ; #MONTH
S_DAY=`echo $BEGIN_TIME | awk '{print $3}' | cut -d : -f 1` ; #DAY
S_HH=`echo $BEGIN_TIME | awk '{print $4}' | cut -d : -f 1` ; #HOUR
S_MM=`echo $BEGIN_TIME | awk '{print $4}' | cut -d : -f 2` ; #MINUTE
S_SS=`echo $BEGIN_TIME | awk '{print $4}' | cut -d : -f 3` ; #SECOND
E_YR=`echo $END_TIME | awk '{print $6}' | cut -d : -f 1` ; #YEAR
E_MON=`echo $END_TIME | awk '{print $2}' | cut -d : -f 1` ; #MONTH
E_DAY=`echo $END_TIME | awk '{print $3}' | cut -d : -f 1` ; #DAY
E_HH=`echo $END_TIME | awk '{print $4}' | cut -d : -f 1` ; #HOUR
E_MM=`echo $END_TIME | awk '{print $4}' | cut -d : -f 2` ; #MINUTE
E_SS=`echo $END_TIME | awk '{print $4}' | cut -d : -f 3` ; #SECOND

sqlplus -s /nolog<<EOF
conn system/$PASS
set pagesize 0;
set feedback off;
set verify off;
set echo off;
spool $HOME/scripts/size1.txt;
select to_char(sum(bytes),'999999999999999')
from dba_data_files;
spool off;
exit;
EOF

export dbsize=`cat $HOME/scripts/size1.txt`;

#if [ "${E_DAY}" = "${S_DAY}" ];  then
#     insert_same_day;
#fi
#if [ "${E_DAY}" -gt "${S_DAY}" ]; then
#     insert_diff_day;
#fi

ftpend=`date "+%m/%d %H:%M"`


if [[ -s $mail_file ]] ; then
    stat="Failed"
    else
     stat="Successful"
fi



cat >$ftpFile<<_E
SERVER: $server
CUID: gardener
SID: $ORACLE_SID
START TIME: $ftpstart
END TIME: $ftpend
DBMS: oracle
STATUS: $stat
TYPE: Hot
DEST: adsm
TSM_SVR:
TSM_NODE:
CLUSTER: $CLUSTER
DBSIZEGB: $DBSIZEGB
_E

ftp -in toolsdbdb.qintra.com<< _E
   user toolsusr TE15n_sDy
   cd dms/incoming/backup_reports
  lcd /home/oraclerm/support/reports
   mput ${ftpFile}
   bye
_E

printf "\n\n";
echo "HOT BACKUP OF $SID on $host";
echo "===========================";
echo "";
echo "START:  $BEGIN_TIME";
echo "COMPLETE:$END_TIME";
mailx -s "RMAN Backup Log Homegrown Script" lburau@us.ibm.com  < $HOME/scripts/$sid_l/logs/RMAN_hot_backup.log
#jay#mailx -s "RMAN Backup Log 10_3_142_1" it-database-services@glovia.com  < $HOME/scripts/$sid_l/logs/RMAN_hot_backup.log
#mail_errors;

return 0;
